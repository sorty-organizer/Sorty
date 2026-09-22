//
//  VisionAnalyzer.swift
//  Sorty
//
//  Semantic Content Analysis using Apple Vision for OCR
//  Extracts text from images for AI-powered organization
//

import AppKit
import CoreImage
import Foundation
import ImageIO
import Vision

/// Result of OCR analysis on an image
public struct OCRResult: Sendable {
    public let text: String
    public let confidence: Float
    public let boundingBoxes: [CGRect]
    public let wordCount: Int

    public init(text: String, confidence: Float, boundingBoxes: [CGRect] = [], wordCount: Int = 0) {
        self.text = text
        self.confidence = confidence
        self.boundingBoxes = boundingBoxes
        self.wordCount = wordCount
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Default keywords for document type detection
    public static let defaultKeywords: [String] = [
        "invoice", "receipt", "tax", "irs", "statement", "bill",
        "contract", "agreement", "report", "memo", "letter",
        "certificate", "license", "passport", "id", "identification",
        "resume", "cv", "application", "form", "prescription",
        "medical", "insurance", "bank", "account", "payment",
        "internal", "revenue", "service"
    ]

    /// Detect keywords using a combined list of default + custom keywords
    public func detectKeywords(using additionalKeywords: [String] = []) -> [String] {
        var allKeywords = Self.defaultKeywords
        for kw in additionalKeywords where !allKeywords.contains(kw.lowercased()) {
            allKeywords.append(kw.lowercased())
        }

        let lowercased = text.lowercased()
        return allKeywords.filter { lowercased.contains($0) }
    }
}

/// Actor that performs OCR analysis using Apple Vision framework
public actor VisionAnalyzer {
    private let maxTextLength = 2000
    private let minimumConfidence: Float = 0.3
    private let maximumCachedResultCount = 256
    private let cacheTrimThreshold = 288
    private let initialOCRMaximumPixelDimension = 2_048
    private let retryOCRMaximumPixelDimension = 4_096
    private let retryConfidenceThreshold: Float = 0.55
    private var recognitionLanguages: [String] = ["en-US"]

    private struct OCRCacheEntry {
        let modificationDate: Date
        let fileSize: Int
        let cachedAt: Date
        let result: OCRResult
    }

    private var ocrCache: [String: OCRCacheEntry] = [:]

    public init() {}

    public func setRecognitionLanguages(_ languages: [String]) {
        let cleaned = languages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        recognitionLanguages = cleaned.isEmpty ? ["en-US"] : Array(Set(cleaned)).sorted()
    }

    public func getRecognitionLanguages() -> [String] {
        recognitionLanguages
    }

    public func clearCache() {
        ocrCache.removeAll()
    }

    /// Perform OCR on an image file
    public func analyzeImage(at url: URL) async -> OCRResult? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        // Check if file is an image
        let imageExtensions = ["jpg", "jpeg", "png", "heic", "tiff", "tif", "bmp", "gif"]
        guard imageExtensions.contains(url.pathExtension.lowercased()) else {
            return nil
        }

        if let cached = lookupCachedResult(for: url) {
            return cached
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = loadCGImage(
                from: source,
                maximumPixelDimension: initialOCRMaximumPixelDimension
              ) else {
            return nil
        }

        let initialResult = await performOCR(on: cgImage, recognitionLevel: .fast)
        var result = initialResult

        if shouldRetryOCR(initialResult),
           imageExceedsInitialPixelBudget(source),
           !Task.isCancelled {
            guard !Task.isCancelled else { return initialResult }
            if let higherResolutionImage = loadCGImage(
                from: source,
                maximumPixelDimension: retryOCRMaximumPixelDimension
            ) {
                // The 4K second pass stays accurate: it runs only when the
                // fast scan pass found too little, and only for images that
                // actually exceed the initial pixel budget.
                result = await performOCR(on: higherResolutionImage, recognitionLevel: .accurate) ?? initialResult
            }
        }

        if let result {
            cacheResult(result, for: url)
        }
        return result
    }

    /// Perform OCR on CGImage data (on-demand path: full accuracy)
    public func analyzeImage(_ cgImage: CGImage) async -> OCRResult? {
        return await performOCR(on: cgImage, recognitionLevel: .accurate)
    }

    // MARK: - Private Methods

    private func loadCGImage(
        from source: CGImageSource,
        maximumPixelDimension: Int
    ) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        )
    }

    private func shouldRetryOCR(_ result: OCRResult?) -> Bool {
        guard let result else { return true }
        return result.confidence < retryConfidenceThreshold || result.wordCount < 3
    }

    private func imageExceedsInitialPixelBudget(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            return false
        }
        return max(width, height) > initialOCRMaximumPixelDimension
    }

    private func performOCR(on cgImage: CGImage, recognitionLevel: VNRequestTextRecognitionLevel) async -> OCRResult? {
        let minimumConfidence = self.minimumConfidence
        let maxTextLength = self.maxTextLength
        let recognitionLanguages = self.recognitionLanguages

        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var didResume = false

            func resumeOnce(_ result: OCRResult?) {
                lock.lock()
                defer { lock.unlock() }

                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: result)
            }

            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    DebugLogger.log("OCR error: \(error.localizedDescription)")
                    resumeOnce(nil)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    resumeOnce(nil)
                    return
                }

                var allText: [String] = []
                var boundingBoxes: [CGRect] = []
                var totalConfidence: Float = 0
                var observationCount = 0

                for observation in observations {
                    guard let topCandidate = observation.topCandidates(1).first else {
                        continue
                    }

                    // Only include text above minimum confidence
                    if topCandidate.confidence >= minimumConfidence {
                        allText.append(topCandidate.string)
                        boundingBoxes.append(observation.boundingBox)
                        totalConfidence += topCandidate.confidence
                        observationCount += 1
                    }
                }

                guard !allText.isEmpty else {
                    resumeOnce(nil)
                    return
                }

                let combinedText = allText.joined(separator: " ")
                let truncatedText = String(combinedText.prefix(maxTextLength))
                let avgConfidence = totalConfidence / Float(max(observationCount, 1))
                let wordCount = combinedText.split(separator: " ").count

                let result = OCRResult(
                    text: truncatedText,
                    confidence: avgConfidence,
                    boundingBoxes: boundingBoxes,
                    wordCount: wordCount
                )

                resumeOnce(result)
            }

            // Scan passes use .fast; only explicit on-demand analysis and the
            // budgeted 4K retry use .accurate.
            request.recognitionLevel = recognitionLevel
            request.usesLanguageCorrection = true
            request.recognitionLanguages = recognitionLanguages

            // Perform the request
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([request])
            } catch {
                DebugLogger.log("Failed to perform OCR: \(error.localizedDescription)")
                resumeOnce(nil)
            }
        }
    }

    /// Extract image dimensions for duplicate comparison
    public func getImageDimensions(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            return nil
        }
        return (width, height)
    }

    /// Generate a perceptual hash for near-duplicate detection
    /// Uses a simplified average hash algorithm
    public func generatePerceptualHash(at url: URL) async -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 64,
                    kCGImageSourceShouldCacheImmediately: false,
                ] as CFDictionary
              ) else {
            return nil
        }

        // Resize to 8x8 and convert to grayscale for hash
        guard let resized = resizeImage(cgImage, to: CGSize(width: 8, height: 8)),
              let grayscale = convertToGrayscale(resized) else {
            return nil
        }

        // Calculate average pixel value
        let pixelData = getPixelValues(from: grayscale)
        guard pixelData.count == 64 else { return nil }

        let average = pixelData.reduce(0, +) / Double(pixelData.count)

        // Generate hash: 1 if pixel > average, 0 otherwise
        var hash = ""
        for pixel in pixelData {
            hash += pixel > average ? "1" : "0"
        }

        // Convert binary to hex for compact storage
        return binaryToHex(hash)
    }

    // MARK: - Image Processing Helpers

    private func resizeImage(_ image: CGImage, to size: CGSize) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )

        context?.interpolationQuality = .low
        context?.draw(image, in: CGRect(origin: .zero, size: size))

        return context?.makeImage()
    }

    private func convertToGrayscale(_ image: CGImage) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )

        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        return context?.makeImage()
    }

    private func getPixelValues(from image: CGImage) -> [Double] {
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return []
        }

        var values: [Double] = []
        let length = CFDataGetLength(data)

        for i in 0..<min(length, 64) {
            values.append(Double(bytes[i]))
        }

        return values
    }

    private func binaryToHex(_ binary: String) -> String {
        var hex = ""
        var index = binary.startIndex

        while index < binary.endIndex {
            let endIndex = binary.index(index, offsetBy: min(4, binary.distance(from: index, to: binary.endIndex)))
            let chunk = String(binary[index..<endIndex])
            if let value = Int(chunk, radix: 2) {
                hex += String(format: "%x", value)
            }
            index = endIndex
        }

        return hex
    }

    private func lookupCachedResult(for url: URL) -> OCRResult? {
        guard let entry = ocrCache[url.path] else { return nil }
        do {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modDate = values.contentModificationDate ?? .distantPast
            let fileSize = values.fileSize ?? 0
            guard entry.modificationDate == modDate, entry.fileSize == fileSize else {
                ocrCache.removeValue(forKey: url.path)
                return nil
            }
            return entry.result
        } catch {
            ocrCache.removeValue(forKey: url.path)
            return nil
        }
    }

    private func cacheResult(_ result: OCRResult, for url: URL) {
        do {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modDate = values.contentModificationDate ?? .distantPast
            let fileSize = values.fileSize ?? 0
            ocrCache[url.path] = OCRCacheEntry(
                modificationDate: modDate,
                fileSize: fileSize,
                cachedAt: Date(),
                result: result
            )
            trimCacheIfNeeded()
        } catch {
            DebugLogger.log("VisionAnalyzer: failed to cache OCR result for \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func trimCacheIfNeeded() {
        guard ocrCache.count > cacheTrimThreshold else { return }

        let overflow = ocrCache.count - maximumCachedResultCount
        let oldestKeys = ocrCache
            .sorted { $0.value.cachedAt < $1.value.cachedAt }
            .prefix(overflow)
            .map(\.key)
        for key in oldestKeys {
            ocrCache.removeValue(forKey: key)
        }
    }
}
