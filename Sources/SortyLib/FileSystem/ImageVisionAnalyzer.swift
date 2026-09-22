//
//  ImageVisionAnalyzer.swift
//  Sorty
//
//  Handles image preprocessing for AI Multimodal (Vision) analysis.
//  Resizes images and converts to Base64 for API consumption.
//

import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import PDFKit

public final class ImageVisionAnalyzer: Sendable {
    private let maxDimension: CGFloat = 1024.0
    private let compressionQuality: CGFloat = 0.8
    private let maxConcurrentPreparations = 4

    private static let cacheLock = NSLock()
    private static let maximumCachedFileCount = 96
    private static let maximumCacheSize = 64 * 1024 * 1024
    private static let maximumCacheAge: TimeInterval = 14 * 24 * 60 * 60

    private static var visionCacheDirectory: URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Sorty")
            .appendingPathComponent("VisionCache", isDirectory: true)
    }

    public init() {}
    
    /// Prepares an image for AI Vision analysis
    /// - Parameter url: Local URL of the image
    /// - Returns: Base64 encoded JPEG data if successful
    public func prepareImageForVision(at url: URL) async -> Data? {
        await prepareImageForVision(at: url, pruneAfterWrite: true)
    }

    private func prepareImageForVision(at url: URL, pruneAfterWrite: Bool) async -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            DebugLogger.log("ImageVisionAnalyzer: file not found at \(url.path)")
            return nil
        }

        return await Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil }

            if let cached = self.cachedImageData(for: url) {
                return cached
            }

            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                DebugLogger.log("ImageVisionAnalyzer: failed to create image source for \(url.lastPathComponent)")
                return nil
            }

            // Downsample while decoding so very large source images never need a
            // full-resolution bitmap in memory before being reduced for upload.
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(self.maxDimension),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let preparedImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions as CFDictionary
            ) else {
                DebugLogger.log("ImageVisionAnalyzer: failed to downsample \(url.lastPathComponent)")
                return nil
            }

            guard !Task.isCancelled else { return nil }
            guard let jpegData = self.convertToJPEG(preparedImage) else {
                DebugLogger.log("ImageVisionAnalyzer: failed to convert image to JPEG \(url.lastPathComponent)")
                return nil
            }

            self.persistCache(jpegData, for: url, pruneAfterWrite: pruneAfterWrite)
            return jpegData
        }.value
    }
    
    /// Prepares multiple images in parallel and reports each completed attempt.
    public func prepareImagesForVision(
        urls: [URL],
        progress: (@Sendable (_ completed: Int, _ total: Int) async -> Void)? = nil
    ) async -> [URL: Data] {
        let uniqueURLs = Array(Set(urls))
        let total = uniqueURLs.count

        return await withTaskGroup(of: (URL, Data?).self) { group in
            var iterator = uniqueURLs.makeIterator()
            for _ in 0..<min(maxConcurrentPreparations, total) {
                guard let url = iterator.next() else { break }
                group.addTask {
                    let data = await self.prepareImageForVision(at: url, pruneAfterWrite: false)
                    return (url, data)
                }
            }
            
            var completed = 0
            var results: [URL: Data] = [:]
            for await (url, data) in group {
                if let data = data {
                    results[url] = data
                }

                completed += 1
                await progress?(completed, total)

                if let nextURL = iterator.next(), !Task.isCancelled {
                    group.addTask {
                        let data = await self.prepareImageForVision(at: nextURL, pruneAfterWrite: false)
                        return (nextURL, data)
                    }
                }
            }
            self.pruneCacheAfterBatch()
            return results
        }
    }

    /// Prepares supported files for multimodal analysis.
    /// Images are resized/compressed, while PDFs are rendered into per-page JPEG assets.
    public func prepareFilesForVision(
        files: [FileItem],
        baseDirectoryURL: URL? = nil,
        pdfPageLimit: Int = 2,
        progress: (@Sendable (_ completed: Int, _ total: Int) async -> Void)? = nil
    ) async -> [String: Data] {
        let results = await withTaskGroup(of: [String: Data].self) { group in
            var iterator = files.makeIterator()
            for _ in 0..<min(maxConcurrentPreparations, files.count) {
                guard let file = iterator.next() else { break }
                group.addTask {
                    await self.prepareFileForVision(
                        file,
                        baseDirectoryURL: baseDirectoryURL,
                        pdfPageLimit: pdfPageLimit
                    )
                }
            }

            var results: [String: Data] = [:]
            var completed = 0
            for await partial in group {
                results.merge(partial) { _, new in new }
                completed += 1
                await progress?(completed, files.count)

                if let nextFile = iterator.next(), !Task.isCancelled {
                    group.addTask {
                        await self.prepareFileForVision(
                            nextFile,
                            baseDirectoryURL: baseDirectoryURL,
                            pdfPageLimit: pdfPageLimit
                        )
                    }
                }
            }
            return results
        }
        pruneCacheAfterBatch()
        return results
    }

    private func prepareFileForVision(
        _ file: FileItem,
        baseDirectoryURL: URL?,
        pdfPageLimit: Int
    ) async -> [String: Data] {
        guard let url = file.url else { return [:] }

        let ext = file.extension.lowercased()
        let attachmentName = attachmentLabel(for: file, baseDirectoryURL: baseDirectoryURL)
        if ["jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "bmp", "gif"].contains(ext),
           let data = await prepareImageForVision(at: url, pruneAfterWrite: false) {
            return [attachmentName: data]
        }

        if ext == "pdf" {
            return await preparePDFForVision(
                at: url,
                displayName: attachmentName,
                maxPages: pdfPageLimit
            )
        }

        return [:]
    }

    private func attachmentLabel(for file: FileItem, baseDirectoryURL: URL?) -> String {
        guard let baseDirectoryURL else {
            return file.displayName
        }

        let filePath = file.path
        let basePath = baseDirectoryURL.path
        let resolvedFilePath = URL(fileURLWithPath: filePath).resolvingSymlinksInPath().path
        let resolvedBasePath = baseDirectoryURL.resolvingSymlinksInPath().path

        if resolvedFilePath.hasPrefix(resolvedBasePath + "/") {
            return String(resolvedFilePath.dropFirst(resolvedBasePath.count + 1))
        }
        if filePath.hasPrefix(basePath + "/") {
            return String(filePath.dropFirst(basePath.count + 1))
        }

        return file.displayName
    }

    public static func clearSharedCache() {
        guard let directory = visionCacheDirectory else { return }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        try? FileManager.default.removeItem(at: directory)
    }
    
    private func convertToJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        
        return data as Data
    }

    private func preparePDFForVision(
        at url: URL,
        displayName: String,
        maxPages: Int
    ) async -> [String: Data] {
        await Task.detached(priority: .utility) {
            guard let document = PDFDocument(url: url) else {
                DebugLogger.log("ImageVisionAnalyzer: failed to open PDF \(url.lastPathComponent)")
                return [:]
            }

            let pagesToRender = min(document.pageCount, maxPages)
            guard pagesToRender > 0 else {
                return [:]
            }

            var rendered: [String: Data] = [:]
            for pageIndex in 0..<pagesToRender {
                guard let page = document.page(at: pageIndex),
                      let image = self.renderPDFPage(page),
                      let jpegData = self.convertToJPEG(image) else {
                    continue
                }
                rendered["\(displayName) [Page \(pageIndex + 1)]"] = jpegData
            }

            return rendered
        }.value
    }

    private func renderPDFPage(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let scale = min(maxDimension / max(bounds.width, bounds.height), 2.0)
        let renderSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )

        guard let context = CGContext(
            data: nil,
            width: Int(renderSize.width),
            height: Int(renderSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: renderSize))
        context.saveGState()
        context.translateBy(x: 0, y: renderSize.height)
        context.scaleBy(x: scale, y: -scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        return context.makeImage()
    }

    private func cachedImageData(for url: URL) -> Data? {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }

        guard let cacheURL = cacheFileURL(for: url),
              FileManager.default.fileExists(atPath: cacheURL.path),
              let data = try? Data(contentsOf: cacheURL) else {
            return nil
        }
        return data
    }

    private func persistCache(_ data: Data, for url: URL, pruneAfterWrite: Bool) {
        guard let cacheURL = cacheFileURL(for: url),
              let cacheDirectory = Self.visionCacheDirectory else {
            return
        }

        do {
            if !FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            }
            // File I/O runs outside the lock; only the prune pass below holds it.
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            DebugLogger.log("ImageVisionAnalyzer: failed to write cache for \(url.lastPathComponent) (\(error.localizedDescription))")
            return
        }
        if pruneAfterWrite {
            Self.cacheLock.lock()
            defer { Self.cacheLock.unlock() }
            Self.pruneCache(in: cacheDirectory, preserving: cacheURL)
        }
    }

    private func pruneCacheAfterBatch() {
        guard let cacheDirectory = Self.visionCacheDirectory else { return }
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        Self.pruneCache(in: cacheDirectory, preserving: nil)
    }

    private static func pruneCache(in directory: URL, preserving preservedURL: URL?) {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]
        guard let cacheFiles = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let expirationDate = Date().addingTimeInterval(-maximumCacheAge)
        var retained: [(url: URL, modificationDate: Date, size: Int)] = []
        retained.reserveCapacity(cacheFiles.count)
        var expiredRemoved = 0

        for fileURL in cacheFiles {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                continue
            }

            let modificationDate = values.contentModificationDate ?? .distantPast
            if fileURL != preservedURL, modificationDate < expirationDate {
                try? FileManager.default.removeItem(at: fileURL)
                expiredRemoved += 1
                continue
            }

            retained.append((fileURL, modificationDate, values.fileSize ?? 0))
        }

        // Fast path: within count and size budgets with nothing expired, skip
        // the sort and second pass entirely.
        let retainedSize = retained.reduce(0) { $0 + $1.size }
        guard expiredRemoved > 0
            || retained.count > maximumCachedFileCount
            || retainedSize > maximumCacheSize else {
            return
        }

        retained.sort { $0.modificationDate > $1.modificationDate }
        var retainedSize = 0
        for (index, file) in retained.enumerated() {
            retainedSize += file.size
            let exceedsCount = index >= maximumCachedFileCount
            let exceedsSize = retainedSize > maximumCacheSize
            if file.url != preservedURL, exceedsCount || exceedsSize {
                try? FileManager.default.removeItem(at: file.url)
            }
        }
    }

    private func cacheFileURL(for url: URL) -> URL? {
        guard let key = cacheKey(for: url),
              let directory = Self.visionCacheDirectory else {
            return nil
        }
        return directory.appendingPathComponent("\(key).jpg")
    }

    private func cacheKey(for url: URL) -> String? {
        do {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modTime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            let fileSize = values.fileSize ?? 0
            let input = "\(url.path)|\(modTime)|\(fileSize)"
            let digest = SHA256.hash(data: Data(input.utf8))
            return digest.compactMap { String(format: "%02x", $0) }.joined()
        } catch {
            DebugLogger.log("ImageVisionAnalyzer: failed to compute cache key for \(url.lastPathComponent) (\(error.localizedDescription))")
            return nil
        }
    }
}
