//
//  ContentAnalyzer.swift
//  Sorty
//
//  Extracts content from files for deep scanning (PDF text, EXIF data, DOCX text, OCR)
//

import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import Compression
@preconcurrency import AVFoundation
import CoreServices
import CoreMedia

/// Metadata extracted from file content
public struct ContentMetadata: Codable, Hashable, Sendable {
    public var textPreview: String?          // First ~200 chars of text content
    public var documentTitle: String?         // Title from document metadata
    public var exifData: [String: String]?    // Camera, date, GPS for images
    public var pageCount: Int?               // For documents
    public var author: String?               // Author metadata
    public var creationDate: Date?           // Document creation date
    public var keywords: [String]?           // Keywords/tags if available
    public var ocrText: String?              // OCR extracted text from images
    public var ocrConfidence: Float?         // OCR confidence score
    public var detectedKeywords: [String]?   // Keywords detected in OCR text
    public var duration: TimeInterval?       // Duration in seconds for audio/video
    public var mediaInfo: [String: String]?  // Codec, bitrate, title, artist, album, genre

    public init(
        textPreview: String? = nil,
        documentTitle: String? = nil,
        exifData: [String: String]? = nil,
        pageCount: Int? = nil,
        author: String? = nil,
        creationDate: Date? = nil,
        keywords: [String]? = nil,
        ocrText: String? = nil,
        ocrConfidence: Float? = nil,
        detectedKeywords: [String]? = nil,
        duration: TimeInterval? = nil,
        mediaInfo: [String: String]? = nil
    ) {
        self.textPreview = textPreview
        self.documentTitle = documentTitle
        self.exifData = exifData
        self.pageCount = pageCount
        self.author = author
        self.creationDate = creationDate
        self.keywords = keywords
        self.ocrText = ocrText
        self.ocrConfidence = ocrConfidence
        self.detectedKeywords = detectedKeywords
        self.duration = duration
        self.mediaInfo = mediaInfo
    }

    public var isEmpty: Bool {
        textPreview == nil
            && documentTitle == nil
            && exifData == nil
            && pageCount == nil
            && author == nil
            && creationDate == nil
            && keywords == nil
            && ocrText == nil
            && ocrConfidence == nil
            && detectedKeywords == nil
            && duration == nil
            && mediaInfo == nil
    }

    /// All available text content (document text + OCR)
    public var allTextContent: String? {
        var parts: [String] = []
        if let preview = textPreview { parts.append(preview) }
        if let ocr = ocrText { parts.append(ocr) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Summary for AI prompt
    public var summary: String {
        var parts: [String] = []

        if let title = documentTitle {
            parts.append("Title: \"\(title)\"")
        }
        if let preview = textPreview {
            let trimmed = preview.prefix(500).replacingOccurrences(of: "\n", with: " ")
            parts.append("Content: \"\(trimmed)...\"")
        }
        if let ocr = ocrText {
            let trimmed = ocr.prefix(400).replacingOccurrences(of: "\n", with: " ")
            parts.append("OCR: \"\(trimmed)...\"")
        }
        if let detected = detectedKeywords, !detected.isEmpty {
            parts.append("Detected: \(detected.joined(separator: ", "))")
        }
        if let exif = exifData {
            if let camera = exif["camera"] {
                parts.append("Camera: \(camera)")
            }
            if let date = exif["dateTime"] {
                parts.append("Taken: \(date)")
            }
        }
        if let pages = pageCount {
            parts.append("\(pages) pages")
        }
        if let duration = duration {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            parts.append("Duration: \(minutes)m \(seconds)s")
        }
        if let info = mediaInfo {
            if let artist = info["artist"] {
                parts.append("Artist: \(artist)")
            }
            if let title = info["title"] {
                parts.append("Track: \(title)")
            }
        }

        return parts.isEmpty ? "" : "[\(parts.joined(separator: ", "))]"
    }
}

private actor SharedContentMetadataCache {
    static let shared = SharedContentMetadataCache()

    struct Options: Codable, Hashable, Sendable {
        let performsOCR: Bool
        let performsDeepScan: Bool
        let ocrLanguages: [String]
        let customOCRKeywords: [String]
    }

    struct Key: Codable, Hashable, Sendable {
        let filePath: String
        let modificationDate: Date
        let fileSize: Int64
        let options: Options
    }

    private struct Entry: Codable, Sendable {
        let key: Key
        let metadata: ContentMetadata
        var lastAccessedAt: Date
        let byteCost: Int
    }

    private var entries: [Key: Entry] = [:]
    private struct InFlightRequest {
        let id: UUID
        let task: Task<ContentMetadata?, Never>
    }

    private var inFlight: [Key: InFlightRequest] = [:]
    private var totalByteCost = 0
    private let maximumByteCost = 32 * 1024 * 1024
    private var hasLoaded = false
    private var flushTask: Task<Void, Never>?
    private var generation = 0

    private var diskURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.sorty.app")
            .appendingPathComponent("content-metadata-cache.json")
    }

    func value(
        for key: Key,
        operation: @escaping @Sendable () async -> ContentMetadata?
    ) async -> ContentMetadata? {
        await loadIfNeeded()
        if var entry = entries[key] {
            entry.lastAccessedAt = Date()
            entries[key] = entry
            return entry.metadata
        }
        if let request = inFlight[key] {
            return await request.task.value
        }

        let currentGeneration = generation
        let requestID = UUID()
        let task = Task { await operation() }
        inFlight[key] = InFlightRequest(id: requestID, task: task)
        let result = await task.value
        if inFlight[key]?.id == requestID {
            inFlight[key] = nil
        }
        if let result, generation == currentGeneration {
            insert(result, for: key)
        }
        return result
    }

    func scheduleFlush() {
        flushTask?.cancel()
        let currentGeneration = generation
        flushTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.flushIfCurrent(currentGeneration)
        }
    }

    func flush() {
        saveToDisk()
    }

    func clear() {
        generation &+= 1
        flushTask?.cancel()
        flushTask = nil
        for request in inFlight.values { request.task.cancel() }
        inFlight.removeAll()
        entries.removeAll()
        totalByteCost = 0
        hasLoaded = true
        if let diskURL { try? FileManager.default.removeItem(at: diskURL) }
    }

    private func insert(_ metadata: ContentMetadata, for key: Key) {
        let byteCost = (try? JSONEncoder().encode(metadata).count) ?? 0
        if let previous = entries[key] { totalByteCost -= previous.byteCost }
        entries[key] = Entry(
            key: key,
            metadata: metadata,
            lastAccessedAt: Date(),
            byteCost: byteCost
        )
        totalByteCost += byteCost
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        guard totalByteCost > maximumByteCost else { return }
        // Amortized trim: drop to 75% of the budget so the next insert does
        // not immediately re-sort the whole table.
        let targetByteCost = maximumByteCost * 3 / 4
        for entry in entries.values.sorted(by: { $0.lastAccessedAt < $1.lastAccessedAt }) {
            guard totalByteCost > targetByteCost else { break }
            entries.removeValue(forKey: entry.key)
            totalByteCost -= entry.byteCost
        }
    }

    private func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        // Disk decoding happens off this actor on .utility; only the bounded
        // insert runs here. Data(contentsOf:) must never run on the main actor.
        guard let diskURL else { return }
        guard let decoded = await Task.detached(priority: .utility) { () -> [Entry]? in
            guard let data = try? Data(contentsOf: diskURL) else { return nil }
            return try? JSONDecoder().decode([Entry].self, from: data)
        }.value else { return }
        for entry in decoded.sorted(by: { $0.lastAccessedAt > $1.lastAccessedAt }) {
            guard totalByteCost + entry.byteCost <= maximumByteCost else { continue }
            entries[entry.key] = entry
            totalByteCost += entry.byteCost
        }
    }

    private func flushIfCurrent(_ expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        saveToDisk()
        flushTask = nil
    }

    private func saveToDisk() {
        guard let diskURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: diskURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(Array(entries.values)).write(to: diskURL, options: .atomic)
        } catch {
            DebugLogger.log("Failed to save content cache: \(error)")
        }
    }
}

/// Actor that analyzes file content
public actor ContentAnalyzer {
    static let defaultTextPreviewLength = 1600

    private let maxPreviewLength = ContentAnalyzer.defaultTextPreviewLength
    private let maxTextBytesToRead = 262_144 // 256KB
    private let maxDocumentTextLength = 12_000
    private let maxOfficeXMLBytes = 2 * 1024 * 1024
    /// ZIPs larger than this are skipped (list-only): mapping a whole huge
    /// archive with `Data(contentsOf:)` plus in-memory deflate risks OOM.
    private let maximumZipBytesToMap = 100 * 1024 * 1024
    private let initialPDFPageProbeCount = 3
    private let visionAnalyzer = VisionAnalyzer()

    // Configuration
    public var enableOCR: Bool = true
    public var enableDeepDocumentScan: Bool = true
    public var customOCRKeywords: [String] = []
    public var ocrLanguages: [String] = ["en-US"]

    public func setCustomOCRKeywords(_ keywords: [String]) {
        self.customOCRKeywords = keywords
    }

    public func setOCRLanguages(_ languages: [String]) async {
        let cleaned = languages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.ocrLanguages = cleaned.isEmpty ? ["en-US"] : cleaned
        await visionAnalyzer.setRecognitionLanguages(self.ocrLanguages)
    }

    public init() {}

    /// Clear any cached data to free memory
    public func clearCache() async {
        await SharedContentMetadataCache.shared.clear()
        await visionAnalyzer.clearCache()
        ImageVisionAnalyzer.clearSharedCache()
    }

    /// Coalesces scan-driven cache writes while preventing an older write from
    /// recreating a cache after `clearCache()`.
    public func scheduleCacheFlush() {
        Task { await SharedContentMetadataCache.shared.scheduleFlush() }
    }

    /// Analyze a file and extract relevant metadata
    public func analyze(fileURL: URL, enableOCR: Bool = true) async -> ContentMetadata? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modificationDate = attrs[.modificationDate] as? Date,
              let fileSize = attrs[.size] as? Int64 else { return nil }
        let key = SharedContentMetadataCache.Key(
            filePath: fileURL.path,
            modificationDate: modificationDate,
            fileSize: fileSize,
            options: SharedContentMetadataCache.Options(
                performsOCR: enableOCR,
                performsDeepScan: enableDeepDocumentScan,
                ocrLanguages: ocrLanguages,
                customOCRKeywords: customOCRKeywords
            )
        )
        let options = key.options
        return await SharedContentMetadataCache.shared.value(for: key) { [self] in
            await analyzeUncached(fileURL: fileURL, options: options)
        }
    }

    private func analyzeUncached(fileURL: URL, options: SharedContentMetadataCache.Options) async -> ContentMetadata? {
        if options.performsOCR {
            await visionAnalyzer.setRecognitionLanguages(options.ocrLanguages)
        }

        let ext = fileURL.pathExtension.lowercased()

        let result: ContentMetadata?
        switch ext {
        case "pdf":
            if options.performsDeepScan {
                result = await extractPDFContent(from: fileURL, options: options)
            } else {
                result = extractPDFMetadataOnly(from: fileURL)
            }
        case "jpg", "jpeg", "heic", "png", "tiff", "tif", "bmp", "gif":
            result = await extractImageContent(from: fileURL, options: options)
        case "docx":
            result = options.performsDeepScan ? await extractDOCXContent(from: fileURL) : nil
        case "rtf":
            result = options.performsDeepScan ? extractRTFContent(from: fileURL) : nil
        case "mp3", "mp4", "m4a", "mov", "avi", "mkv", "wav", "aac", "flac", "m4v", "webm":
            result = await extractMediaContent(from: fileURL)
        case "pages", "numbers", "key":
            result = options.performsDeepScan ? extractIWorkContent(from: fileURL) : nil
        case "xlsx":
            result = options.performsDeepScan ? await extractXLSXContent(from: fileURL) : nil
        case "pptx":
            result = options.performsDeepScan ? await extractPPTXContent(from: fileURL) : nil
        default:
            result = options.performsDeepScan && isTextLikeFile(fileURL) ? extractTextContent(from: fileURL) : nil
        }

        return result
    }

    /// Batch analyze multiple files
    public func analyzeFiles(
        _ urls: [URL],
        enableOCR: Bool = true,
        progressHandler: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [URL: ContentMetadata] {
        var results: [URL: ContentMetadata] = [:]
        let total = urls.count

        // Process in batches to limit concurrency
        let batchSize = 4
        for batchStart in stride(from: 0, to: urls.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, urls.count)
            let batch = Array(urls[batchStart..<batchEnd])

            let batchResults = await withTaskGroup(of: (URL, ContentMetadata?).self) { group in
                for url in batch {
                    group.addTask(priority: .utility) {
                        let metadata = await self.analyze(fileURL: url, enableOCR: enableOCR)
                        return (url, metadata)
                    }
                }

                var batchDict: [URL: ContentMetadata] = [:]
                for await (url, metadata) in group {
                    if let metadata = metadata {
                        batchDict[url] = metadata
                    }
                }
                return batchDict
            }

            results.merge(batchResults) { _, new in new }
            progressHandler?(batchEnd, total)

            // Yield for UI updates between batches, and cooperatively every
            // 50 files on .utility so large runs stay cancellable.
            if batchEnd.isMultiple(of: 50) || batchEnd == total {
                await Task.yield()
            }
            guard !Task.isCancelled else { break }
        }

        // Save cache after batch analysis
        await SharedContentMetadataCache.shared.flush()

        return results
    }

    // MARK: - PDF Extraction

    private func extractPDFContent(
        from url: URL,
        options: SharedContentMetadataCache.Options
    ) async -> ContentMetadata? {
        guard let document = PDFDocument(url: url) else {
            return nil
        }

        var metadata = ContentMetadata()

        // Get document attributes
        if let attributes = document.documentAttributes {
            metadata.documentTitle = attributes[PDFDocumentAttribute.titleAttribute] as? String
            metadata.author = attributes[PDFDocumentAttribute.authorAttribute] as? String
            if let keywordsString = attributes[PDFDocumentAttribute.keywordsAttribute] as? String {
                metadata.keywords = keywordsString.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }

        metadata.pageCount = document.pageCount

        var extractedText = ""
        let initialPageCount = min(document.pageCount, initialPDFPageProbeCount)

        for i in 0..<initialPageCount {
            guard !Task.isCancelled else { return nil }
            if let page = document.page(at: i),
               let text = page.string {
                extractedText += text + " "
                if extractedText.count >= maxDocumentTextLength {
                    break
                }
            }
        }

        // Probe OCR before walking the rest of a likely scanned document.
        if extractedText.isEmpty && options.performsOCR, let firstPage = document.page(at: 0) {
            guard !Task.isCancelled else { return nil }
            if let ocrResult = await performOCROnPDFPage(firstPage) {
                metadata.ocrText = ocrResult.text
                metadata.ocrConfidence = ocrResult.confidence
                metadata.detectedKeywords = ocrResult.detectKeywords(using: options.customOCRKeywords)
            }
        }

        // Keep scanning text-backed documents, or PDFs where first-page OCR
        // found nothing, until enough useful context has been collected.
        if !extractedText.isEmpty || metadata.ocrText?.isEmpty != false {
            for i in initialPageCount..<document.pageCount {
                guard !Task.isCancelled else { return nil }
                if let page = document.page(at: i),
                   let text = page.string {
                    extractedText += text + " "
                    if extractedText.count >= maxDocumentTextLength {
                        break
                    }
                }
            }
        }

        if !extractedText.isEmpty {
            metadata.textPreview = String(extractedText.prefix(maxDocumentTextLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return metadata.isEmpty ? nil : metadata
    }

    /// Light PDF extraction: only metadata (title, author, page count), no text extraction
    private func extractPDFMetadataOnly(from url: URL) -> ContentMetadata? {
        guard let document = PDFDocument(url: url) else { return nil }

        var metadata = ContentMetadata()

        if let attributes = document.documentAttributes {
            metadata.documentTitle = attributes[PDFDocumentAttribute.titleAttribute] as? String
            metadata.author = attributes[PDFDocumentAttribute.authorAttribute] as? String
            if let keywordsString = attributes[PDFDocumentAttribute.keywordsAttribute] as? String {
                metadata.keywords = keywordsString.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }

        metadata.pageCount = document.pageCount

        return metadata.isEmpty ? nil : metadata
    }

    private func performOCROnPDFPage(_ page: PDFPage) async -> OCRResult? {
        // Render PDF page to image for OCR
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0 // Higher resolution for better OCR
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: scale, y: scale)

        page.draw(with: .mediaBox, to: context)

        guard let cgImage = context.makeImage() else {
            return nil
        }

        // Use CGImage directly for compatibility with VisionAnalyzer (Sendable)
        return await visionAnalyzer.analyzeImage(cgImage)
    }

    // MARK: - Image Extraction with OCR

    private func extractImageContent(
        from url: URL,
        options: SharedContentMetadataCache.Options
    ) async -> ContentMetadata? {
        var metadata = extractEXIFData(from: url) ?? ContentMetadata()

        // Perform OCR if enabled
        if options.performsOCR {
            if let ocrResult = await visionAnalyzer.analyzeImage(at: url) {
                metadata.ocrText = ocrResult.text
                metadata.ocrConfidence = ocrResult.confidence
                metadata.detectedKeywords = ocrResult.detectKeywords(using: options.customOCRKeywords)
            }
        }

        return metadata.isEmpty ? nil : metadata
    }

    // MARK: - EXIF Extraction

    private func extractEXIFData(from url: URL) -> ContentMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }

        var exifDict: [String: String] = [:]

        // EXIF data
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let dateTime = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                exifDict["dateTime"] = dateTime
            }
            if let fNumber = exif[kCGImagePropertyExifFNumber as String] {
                exifDict["fNumber"] = "f/\(fNumber)"
            }
            if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], let firstISO = iso.first {
                exifDict["iso"] = "ISO \(firstISO)"
            }
        }

        // TIFF data (camera info)
        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            var cameraInfo: [String] = []
            if let make = tiff[kCGImagePropertyTIFFMake as String] as? String {
                cameraInfo.append(make)
            }
            if let model = tiff[kCGImagePropertyTIFFModel as String] as? String {
                cameraInfo.append(model)
            }
            if !cameraInfo.isEmpty {
                exifDict["camera"] = cameraInfo.joined(separator: " ")
            }
        }

        // GPS data
        if let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            if let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
               let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double {
                exifDict["gps"] = String(format: "%.4f, %.4f", lat, lon)
            }
        }

        // Image dimensions
        if let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
           let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
            exifDict["dimensions"] = "\(width)x\(height)"
        }

        guard !exifDict.isEmpty else {
            return nil
        }

        return ContentMetadata(exifData: exifDict)
    }

    // MARK: - DOCX Extraction

    /// Returns the archive bytes only when the file is small enough to map
    /// safely; oversized ZIPs are skipped to avoid OOM.
    private func mappableZipData(at url: URL) -> Data? {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
           size.int64Value > Int64(maximumZipBytesToMap) {
            return nil
        }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func extractDOCXContent(from url: URL) async -> ContentMetadata? {
        guard let zipData = mappableZipData(at: url) else {
            return nil
        }

        guard let xmlString = extractFileFromZip(
            data: zipData,
            fileName: "word/document.xml",
            maximumOutputBytes: maxOfficeXMLBytes
        ) else {
            return nil
        }

        let text = extractTextFromXML(xmlString)
        guard !text.isEmpty else { return nil }

        var metadata = ContentMetadata(textPreview: String(text.prefix(maxDocumentTextLength)))

        // Also try to extract core.xml for metadata
        if let coreXML = extractFileFromZip(
            data: zipData,
            fileName: "docProps/core.xml",
            maximumOutputBytes: 256 * 1024
        ) {
            if let title = extractXMLValue(coreXML, tag: "dc:title") {
                metadata.documentTitle = title
            }
            if let author = extractXMLValue(coreXML, tag: "dc:creator") {
                metadata.author = author
            }
        }

        return metadata
    }

    private func extractTextFromXML(_ xml: String) -> String {
        // Simple regex to extract text between <w:t> tags
        let pattern = "<w:t[^>]*>([^<]+)</w:t>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return ""
        }

        var text = ""
        regex.enumerateMatches(
            in: xml,
            range: NSRange(xml.startIndex..., in: xml)
        ) { match, _, stop in
            guard let match,
                  let range = Range(match.range(at: 1), in: xml) else { return }
            if !text.isEmpty {
                text.append(" ")
            }
            text.append(contentsOf: xml[range].prefix(maxDocumentTextLength - text.count))
            if text.count >= maxDocumentTextLength {
                stop.pointee = true
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Plain Text Extraction

    private func extractTextContent(from url: URL) -> ContentMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: maxTextBytesToRead),
              let text = decodeText(from: data) else {
            return nil
        }

        let preview = String(text.prefix(maxPreviewLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !preview.isEmpty else { return nil }
        return ContentMetadata(textPreview: preview)
    }

    // MARK: - RTF Extraction

    private func extractRTFContent(from url: URL) -> ContentMetadata? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }

        guard let attributedString = NSAttributedString(rtf: data, documentAttributes: nil) else {
            return extractTextContent(from: url)
        }

        let text = attributedString.string
        let preview = String(text.prefix(maxPreviewLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !preview.isEmpty else { return nil }
        return ContentMetadata(textPreview: preview)
    }

    // MARK: - Audio/Video Extraction

    private func extractMediaContent(from url: URL) async -> ContentMetadata? {
        let asset = AVURLAsset(url: url)
        var metadata = ContentMetadata()
        var mediaDict: [String: String] = [:]

        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite && seconds > 0 {
                metadata.duration = seconds
            }
        }

        if let metadataItems = try? await asset.load(.commonMetadata) {
            for item in metadataItems {
                guard let key = item.commonKey?.rawValue,
                      let value = try? await item.load(.stringValue) else { continue }
                switch key {
                case AVMetadataKey.commonKeyTitle.rawValue:
                    metadata.documentTitle = value
                    mediaDict["title"] = value
                case AVMetadataKey.commonKeyArtist.rawValue:
                    metadata.author = value
                    mediaDict["artist"] = value
                case AVMetadataKey.commonKeyAlbumName.rawValue:
                    mediaDict["album"] = value
                case AVMetadataKey.commonKeyType.rawValue:
                    mediaDict["genre"] = value
                case AVMetadataKey.commonKeyCreationDate.rawValue:
                    mediaDict["creationDate"] = value
                default:
                    break
                }
            }
        }

        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
           let firstAudio = audioTracks.first {
            if let formatDescriptions = try? await firstAudio.load(.formatDescriptions),
               let desc = formatDescriptions.first {
                let audioDesc = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
                if let sampleRate = audioDesc?.pointee.mSampleRate {
                    mediaDict["sampleRate"] = "\(Int(sampleRate)) Hz"
                }
            }
        }

        if let videoTracks = try? await asset.loadTracks(withMediaType: .video),
           let firstVideo = videoTracks.first {
            if let naturalSize = try? await firstVideo.load(.naturalSize) {
                mediaDict["resolution"] = "\(Int(naturalSize.width))x\(Int(naturalSize.height))"
            }
        }

        if !mediaDict.isEmpty {
            metadata.mediaInfo = mediaDict
        }

        return metadata.isEmpty ? nil : metadata
    }

    // MARK: - iWork Extraction (Pages, Numbers, Keynote)

    private func extractIWorkContent(from url: URL) -> ContentMetadata? {
        return extractSpotlightMetadata(from: url)
    }

    // MARK: - XLSX/PPTX Extraction

    private func extractXLSXContent(from url: URL) async -> ContentMetadata? {
        if let metadata = extractSpotlightMetadata(from: url) {
            return metadata
        }

        return await extractZipXMLContent(from: url, xmlPath: "xl/workbook.xml")
    }

    private func extractPPTXContent(from url: URL) async -> ContentMetadata? {
        if let metadata = extractSpotlightMetadata(from: url) {
            return metadata
        }

        return await extractZipXMLContent(from: url, xmlPath: "ppt/presentation.xml")
    }

    // MARK: - Shared Helpers

    private func extractSpotlightMetadata(from url: URL) -> ContentMetadata? {
        guard let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else {
            return nil
        }

        var metadata = ContentMetadata()

        let attributes = [
            kMDItemTitle,
            kMDItemAuthors,
            kMDItemNumberOfPages,
            kMDItemTextContent,
            kMDItemKeywords
        ] as [CFString]

        if let attrDict = MDItemCopyAttributes(mdItem, attributes as CFArray) as? [String: Any] {
            if let title = attrDict[kMDItemTitle as String] as? String {
                metadata.documentTitle = title
            }
            if let authors = attrDict[kMDItemAuthors as String] as? [String], let firstAuthor = authors.first {
                metadata.author = firstAuthor
            }
            if let pages = attrDict[kMDItemNumberOfPages as String] as? Int {
                metadata.pageCount = pages
            }
            if let text = attrDict[kMDItemTextContent as String] as? String, !text.isEmpty {
                metadata.textPreview = String(text.prefix(maxDocumentTextLength))
            }
            if let keywords = attrDict[kMDItemKeywords as String] as? [String] {
                metadata.keywords = keywords
            }
        }

        return metadata.isEmpty ? nil : metadata
    }

    private func extractZipXMLContent(from url: URL, xmlPath: String) async -> ContentMetadata? {
        guard let zipData = mappableZipData(at: url),
              let xmlString = extractFileFromZip(
                data: zipData,
                fileName: xmlPath,
                maximumOutputBytes: maxOfficeXMLBytes
              ) else {
            return nil
        }

        let text = extractTextFromXML(xmlString)
        guard !text.isEmpty else { return nil }
        return ContentMetadata(textPreview: String(text.prefix(maxDocumentTextLength)))
    }

    // MARK: - Native ZIP Reading

    /// Extract a single file from a ZIP archive by name
    private func extractFileFromZip(
        data: Data,
        fileName: String,
        maximumOutputBytes: Int
    ) -> String? {
        // ZIP end of central directory signature
        let eocdSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]

        guard data.count > 22 else { return nil }
        var eocdOffset = -1
        let searchStart = max(0, data.count - 65557)

        for i in stride(from: data.count - 22, through: searchStart, by: -1) {
            if data[i] == eocdSignature[0] && data[i+1] == eocdSignature[1] &&
               data[i+2] == eocdSignature[2] && data[i+3] == eocdSignature[3] {
                eocdOffset = i
                break
            }
        }

        guard eocdOffset >= 0 else { return nil }

        // Read central directory offset from EOCD
        let cdOffset = Int(data[eocdOffset + 16]) | (Int(data[eocdOffset + 17]) << 8) |
                       (Int(data[eocdOffset + 18]) << 16) | (Int(data[eocdOffset + 19]) << 24)

        // Iterate through central directory entries
        var pos = cdOffset
        let cdSignature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]

        while pos + 46 < data.count {
            guard data[pos] == cdSignature[0] && data[pos+1] == cdSignature[1] &&
                  data[pos+2] == cdSignature[2] && data[pos+3] == cdSignature[3] else { break }

            let compressionMethod = UInt16(data[pos + 10]) | (UInt16(data[pos + 11]) << 8)
            let compressedSize = Int(data[pos + 20]) | (Int(data[pos + 21]) << 8) |
                                 (Int(data[pos + 22]) << 16) | (Int(data[pos + 23]) << 24)
            let uncompressedSize = Int(data[pos + 24]) | (Int(data[pos + 25]) << 8) |
                                   (Int(data[pos + 26]) << 16) | (Int(data[pos + 27]) << 24)
            let fileNameLength = Int(data[pos + 28]) | (Int(data[pos + 29]) << 8)
            let extraFieldLength = Int(data[pos + 30]) | (Int(data[pos + 31]) << 8)
            let commentLength = Int(data[pos + 32]) | (Int(data[pos + 33]) << 8)
            let localHeaderOffset = Int(data[pos + 42]) | (Int(data[pos + 43]) << 8) |
                                    (Int(data[pos + 44]) << 16) | (Int(data[pos + 45]) << 24)

            let nameStart = pos + 46
            let nameEnd = nameStart + fileNameLength
            guard nameEnd <= data.count else { break }

            let entryName = String(data: data[nameStart..<nameEnd], encoding: .utf8) ?? ""

            if entryName == fileName {
                // Found it — read from local file header
                let localPos = localHeaderOffset
                guard localPos + 30 < data.count else { return nil }

                let localNameLen = Int(data[localPos + 26]) | (Int(data[localPos + 27]) << 8)
                let localExtraLen = Int(data[localPos + 28]) | (Int(data[localPos + 29]) << 8)
                let dataStart = localPos + 30 + localNameLen + localExtraLen
                let dataEnd = dataStart + compressedSize

                guard dataEnd <= data.count else { return nil }

                let fileData = data[dataStart..<dataEnd]

                if compressionMethod == 0 {
                    // Stored (no compression)
                    return String(
                        decoding: fileData.prefix(maximumOutputBytes),
                        as: UTF8.self
                    )
                } else if compressionMethod == 8 {
                    // Deflate — use Compression framework
                    let decompressed = decompressDeflate(
                        Data(fileData),
                        maximumOutputBytes: min(uncompressedSize, maximumOutputBytes)
                    )
                    return decompressed.map { String(decoding: $0, as: UTF8.self) }
                }

                return nil
            }

            pos = nameEnd + extraFieldLength + commentLength
        }

        return nil
    }

    private func decompressDeflate(_ data: Data, maximumOutputBytes: Int) -> Data? {
        let bufferSize = max(1, maximumOutputBytes)
        var decompressed = Data(count: bufferSize)

        let result = decompressed.withUnsafeMutableBytes { destBuffer in
            data.withUnsafeBytes { srcBuffer in
                guard let destPtr = destBuffer.baseAddress,
                      let srcPtr = srcBuffer.baseAddress else { return 0 }
                return compression_decode_buffer(
                    destPtr.assumingMemoryBound(to: UInt8.self),
                    bufferSize,
                    srcPtr.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard result > 0 else { return nil }
        return decompressed.prefix(result)
    }

    private func extractXMLValue(_ xml: String, tag: String) -> String? {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: tag))[^>]*>([^<]+)</\(NSRegularExpression.escapedPattern(for: tag))>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: xml, options: [], range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[range])
    }

    private func isTextLikeFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let textLikeExtensions: Set<String> = [
            "txt", "md", "markdown", "csv", "tsv", "json", "jsonl", "yaml", "yml",
            "xml", "html", "htm", "css", "scss", "js", "jsx", "ts", "tsx",
            "swift", "py", "rb", "go", "rs", "java", "kt", "c", "cc", "cpp",
            "h", "hpp", "m", "mm", "php", "pl", "sh", "zsh", "bash", "fish",
            "toml", "ini", "cfg", "conf", "sql", "log"
        ]
        if textLikeExtensions.contains(ext) {
            return true
        }

        guard let type = UTType(filenameExtension: ext) else {
            return false
        }

        return type.conforms(to: .plainText)
            || type.conforms(to: .sourceCode)
            || type.conforms(to: .script)
            || type.conforms(to: .xml)
            || type.conforms(to: .json)
            || type.conforms(to: .commaSeparatedText)
    }

    private func decodeText(from data: Data) -> String? {
        let candidateEncodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .windowsCP1252,
            .isoLatin1
        ]

        for encoding in candidateEncodings {
            guard let text = String(data: data, encoding: encoding) else {
                continue
            }
            let normalized = text
                .replacingOccurrences(of: "\u{0000}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                return normalized
            }
        }

        return nil
    }
}

// MARK: - Import for AppKit NSColor/NSImage
import AppKit
