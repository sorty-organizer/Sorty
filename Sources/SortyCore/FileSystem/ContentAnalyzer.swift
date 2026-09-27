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

actor SharedContentMetadataCache {
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
    private let maximumByteCost: Int
    private let maximumEntryCount = 10_000
    /// On-disk bound: the LZFSE payload is evicted oldest-first until the
    /// JSON fits, so the cache file cannot grow without bound.
    private static let maximumDiskBytes = 64 * 1024 * 1024
    /// On-disk entries older than this are dropped on load.
    private static let diskEntryTTL: TimeInterval = 7 * 24 * 60 * 60
    private var isDirty = false
    private var loadTask: Task<[Entry]?, Never>?
    private var hasLoaded = false
    private var flushTask: Task<Void, Never>?
    private var generation = 0

    private let diskURL: URL?
    private var legacyDiskURL: URL? {
        diskURL?.deletingPathExtension()
    }

    init(directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("com.sorty.app"), maximumByteCost: Int = 32 * 1024 * 1024) {
        self.diskURL = directory?.appendingPathComponent("content-metadata-cache.json.lzfse")
        self.maximumByteCost = maximumByteCost
    }

    func value(
        for key: Key,
        operation: @escaping @Sendable () async -> ContentMetadata?
    ) async -> ContentMetadata? {
        let currentGeneration = generation
        await loadIfNeeded()
        if var entry = entries[key] {
            entry.lastAccessedAt = Date()
            entries[key] = entry
            return entry.metadata
        }
        if let request = inFlight[key] {
            return await request.task.value
        }

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
        guard isDirty else { return }
        flushTask?.cancel()
        let currentGeneration = generation
        flushTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.flushIfCurrent(currentGeneration)
        }
    }

    func flush() {
        flushTask?.cancel()
        flushTask = nil
        saveToDisk()
    }

    /// Removes every cached entry and the on-disk cache files. Used by the
    /// explicit Settings "Clear Cache" action.
    func clear() {
        resetInMemory()
        hasLoaded = true
        if let diskURL { try? FileManager.default.removeItem(at: diskURL) }
        if let legacyDiskURL { try? FileManager.default.removeItem(at: legacyDiskURL) }
    }

    /// Drops in-memory entries only. The on-disk cache survives and is lazily
    /// reloaded on the next lookup, so memory pressure does not force
    /// expensive re-extraction.
    func clearInMemory() {
        resetInMemory()
        hasLoaded = false
    }

    private func resetInMemory() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        isDirty = false
        flushTask?.cancel()
        flushTask = nil
        for request in inFlight.values { request.task.cancel() }
        inFlight.removeAll()
        entries.removeAll()
        totalByteCost = 0
    }

    private func insert(_ metadata: ContentMetadata, for key: Key) {
        // Cheap size estimate (no per-insert JSON encode): paths, options,
        // and extracted text summed from UTF-8 counts, capped per field.
        let byteCost = Self.estimatedByteCost(key: key, metadata: metadata)
        guard byteCost <= maximumByteCost else { return }
        isDirty = true
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

    /// Cheap in-memory cost estimate for one entry. Encoding every candidate
    /// with JSONEncoder on insert cost more than the extraction it cached, so
    /// the budget is accounted from UTF-8 lengths plus fixed overhead for
    /// dates, numbers, and flags. Each text field is capped so a single huge
    /// preview cannot dominate the accounting.
    private static func estimatedByteCost(key: Key, metadata: ContentMetadata) -> Int {
        let perFieldCap = 64 * 1024
        var bytes = 128 // dates, sizes, page counts, confidence, flags, coding overhead
        bytes += min(key.filePath.utf8.count, perFieldCap)
        for language in key.options.ocrLanguages { bytes += min(language.utf8.count, 64) }
        for keyword in key.options.customOCRKeywords { bytes += min(keyword.utf8.count, 256) }
        if let text = metadata.textPreview { bytes += min(text.utf8.count, perFieldCap) }
        if let title = metadata.documentTitle { bytes += min(title.utf8.count, perFieldCap) }
        if let author = metadata.author { bytes += min(author.utf8.count, perFieldCap) }
        if let ocr = metadata.ocrText { bytes += min(ocr.utf8.count, perFieldCap) }
        for keyword in metadata.keywords ?? [] { bytes += min(keyword.utf8.count, 256) }
        for keyword in metadata.detectedKeywords ?? [] { bytes += min(keyword.utf8.count, 256) }
        if let exif = metadata.exifData {
            for (field, value) in exif {
                bytes += min(field.utf8.count + value.utf8.count, 1024)
            }
        }
        if let media = metadata.mediaInfo {
            for (field, value) in media {
                bytes += min(field.utf8.count + value.utf8.count, 1024)
            }
        }
        return bytes
    }

    /// Single-pass partial selection of the oldest-touched keys. Sorting the
    /// whole table on every trim is O(n log n); this keeps only the `limit`
    /// oldest entries seen and returns them oldest-first.
    private func oldestKeys(limit: Int) -> [Key] {
        var buffer: [(key: Key, accessed: Date)] = []
        buffer.reserveCapacity(min(limit, entries.count))
        var newestInBuffer = Date.distantPast
        var newestIndex = 0
        for (key, entry) in entries {
            let accessed = entry.lastAccessedAt
            if buffer.count < limit {
                buffer.append((key, accessed))
                if accessed >= newestInBuffer {
                    newestInBuffer = accessed
                    newestIndex = buffer.count - 1
                }
            } else if accessed < newestInBuffer {
                buffer[newestIndex] = (key, accessed)
                newestInBuffer = buffer[0].accessed
                newestIndex = 0
                for index in 1..<buffer.count where buffer[index].accessed > newestInBuffer {
                    newestInBuffer = buffer[index].accessed
                    newestIndex = index
                }
            }
        }
        return buffer.sorted { $0.accessed < $1.accessed }.map { $0.key }
    }

    private func removeEntry(for key: Key) {
        if let removed = entries.removeValue(forKey: key) {
            totalByteCost -= removed.byteCost
        }
    }

    private func trimIfNeeded() {
        guard totalByteCost > maximumByteCost || entries.count > maximumEntryCount else { return }
        // Amortized trim: drop to 75% of the budget so the next insert does
        // not immediately re-trim the table.
        let targetByteCost = maximumByteCost * 3 / 4
        let targetEntryCount = entries.count > maximumEntryCount ? maximumEntryCount * 3 / 4 : maximumEntryCount
        // Sampled eviction: resample the oldest-touched candidates instead of
        // sorting the whole table; each pass evicts at least one entry.
        while totalByteCost > targetByteCost || entries.count > targetEntryCount {
            let candidates = oldestKeys(limit: 256)
            guard !candidates.isEmpty else { break }
            let bytesBefore = totalByteCost
            let countBefore = entries.count
            for key in candidates {
                guard totalByteCost > targetByteCost || entries.count > targetEntryCount else { break }
                removeEntry(for: key)
            }
            guard totalByteCost < bytesBefore || entries.count < countBefore else { break }
        }
    }

    private func loadIfNeeded() async {
        guard !hasLoaded else { return }
        let currentGeneration = generation
        if loadTask == nil {
            let diskURL = diskURL
            let legacyDiskURL = legacyDiskURL
            loadTask = Task.detached(priority: .utility) { () -> [Entry]? in
                if let diskURL {
                    if let size = (try? FileManager.default.attributesOfItem(atPath: diskURL.path))?[.size] as? NSNumber,
                       size.intValue > Self.maximumDiskBytes {
                        // Oversized cache file: skip instead of decoding unbounded
                        // input. The next flush rewrites it within the disk bound.
                        return nil
                    }
                    if let data = try? Data(contentsOf: diskURL),
                       let json = try? (data as NSData).decompressed(using: .lzfse),
                       json.length <= Self.maximumDiskBytes,
                       let entries = try? JSONDecoder().decode([Entry].self, from: json as Data) {
                        return entries
                    }
                }
                if let legacyDiskURL,
                   let size = (try? FileManager.default.attributesOfItem(atPath: legacyDiskURL.path))?[.size] as? NSNumber,
                   size.intValue <= Self.maximumDiskBytes,
                   let data = try? Data(contentsOf: legacyDiskURL) {
                    return try? JSONDecoder().decode([Entry].self, from: data)
                }
                return nil
            }
        }
        let decoded = await loadTask?.value
        // All callers await the same read; clear invalidates its result.
        guard generation == currentGeneration, !hasLoaded else { return }
        hasLoaded = true
        loadTask = nil
        let expiration = Date().addingTimeInterval(-Self.diskEntryTTL)
        for entry in (decoded ?? []).sorted(by: { $0.lastAccessedAt > $1.lastAccessedAt }) {
            guard entry.lastAccessedAt >= expiration, entries[entry.key] == nil,
                  entries.count < maximumEntryCount else { continue }
            let byteCost = Self.estimatedByteCost(key: entry.key, metadata: entry.metadata)
            guard byteCost <= maximumByteCost - totalByteCost else { continue }
            entries[entry.key] = Entry(key: entry.key, metadata: entry.metadata,
                                       lastAccessedAt: entry.lastAccessedAt, byteCost: byteCost)
            totalByteCost += byteCost
        }
        // Rewrite once for migration or expiration, but never for a read-only scan.
        if let legacyDiskURL, FileManager.default.fileExists(atPath: legacyDiskURL.path) {
            isDirty = true
        }
        if let decoded, decoded.count != entries.count { isDirty = true }
    }

    private func flushIfCurrent(_ expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        saveToDisk()
        flushTask = nil
    }

    private func saveToDisk() {
        guard isDirty, let diskURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: diskURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Bound the on-disk cache: evict oldest-first until the payload
            // fits 64MB instead of writing an unbounded file.
            var json = try JSONEncoder().encode(Array(entries.values))
            while json.count > Self.maximumDiskBytes, !entries.isEmpty {
                let candidates = oldestKeys(limit: 256)
                guard !candidates.isEmpty else { break }
                let countBefore = entries.count
                for key in candidates {
                    removeEntry(for: key)
                }
                guard entries.count < countBefore else { break }
                json = try JSONEncoder().encode(Array(entries.values))
            }
            guard json.count <= Self.maximumDiskBytes else {
                // Unreachable for an empty manifest, but never write an
                // over-bound payload: drop this save and retry next flush.
                DebugLogger.log("Skipping content cache save: payload exceeds disk bound")
                return
            }
            let compressed = try (json as NSData).compressed(using: .lzfse)
            try (compressed as Data).write(to: diskURL, options: .atomic)
            isDirty = false
            if let legacyDiskURL { try? FileManager.default.removeItem(at: legacyDiskURL) }
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
    /// RTF parsing expands the whole document in memory, so oversized files
    /// are skipped like the other bounded extraction paths.
    private let maximumRTFBytesToMap = 8 * 1024 * 1024
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

    /// Drops in-memory caches to relieve memory pressure. On-disk caches are
    /// intentionally kept: deleting them frees no RAM and forces the next scan
    /// to re-extract every file. The explicit Settings "Clear Cache" action
    /// removes the on-disk caches via `CacheMaintenance.clear()`.
    public func clearCache() async {
        await SharedContentMetadataCache.shared.clearInMemory()
        await visionAnalyzer.clearCache()
    }

    /// Coalesces scan-driven cache writes while preventing an older write from
    /// recreating a cache after `clearCache()`.
    public func scheduleCacheFlush() {
        Task { await SharedContentMetadataCache.shared.scheduleFlush() }
    }

    /// True when the path is a regular file. FIFOs, sockets, and devices are
    /// rejected before any read: opening a FIFO for reading blocks until a
    /// writer appears, which would otherwise stall a deep scan indefinitely.
    private nonisolated static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    /// Analyze a file and extract relevant metadata
    public func analyze(fileURL: URL, enableOCR: Bool = true) async -> ContentMetadata? {
        guard Self.isRegularFile(fileURL) else {
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

    /// Maps a file only when it is small enough; oversized files are skipped
    /// to avoid OOM while parsing.
    private func mappableData(at url: URL, maximumBytes: Int) -> Data? {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
           size.int64Value > Int64(maximumBytes) {
            return nil
        }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Returns the archive bytes only when the ZIP is small enough to map
    /// safely; oversized archives are skipped to avoid OOM.
    private func mappableZipData(at url: URL) -> Data? {
        mappableData(at: url, maximumBytes: maximumZipBytesToMap)
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

    /// Extracts `<t>` element text with any namespace prefix (for example
    /// `<a:t>` on slides). Spreadsheet shared strings, worksheet inline
    /// strings, and presentation slides use these tags, which the
    /// Word-specific `<w:t>` extractor above would miss. `<v>` values are
    /// skipped because worksheet cells store shared-string indices there.
    private func extractTextFromXMLTextElements(_ xml: String, maximumLength: Int) -> String {
        guard maximumLength > 0 else { return "" }
        let pattern = "<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?t(?:\\s[^>]*)?>([^<]+)</(?:[A-Za-z_][A-Za-z0-9_.-]*:)?t>"
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
            let value = xml[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            if !text.isEmpty {
                text.append(" ")
            }
            text.append(contentsOf: value.prefix(maximumLength - text.count))
            if text.count >= maximumLength {
                stop.pointee = true
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Plain Text Extraction

    private func extractTextContent(from url: URL) -> ContentMetadata? {
        guard Self.isRegularFile(url) else { return nil }

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
        guard let data = mappableData(at: url, maximumBytes: maximumRTFBytesToMap) else {
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

        // Shared strings hold most cell text; worksheets add inline strings in
        // plain <t> elements, not Word's <w:t>.
        return extractZipXMLContent(from: url, matchers: [
            { $0 == "xl/sharedStrings.xml" },
            { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
        ])
    }

    private func extractPPTXContent(from url: URL) async -> ContentMetadata? {
        if let metadata = extractSpotlightMetadata(from: url) {
            return metadata
        }

        // Slide text lives in <a:t> nodes. Layouts and masters are skipped
        // because they repeat the same placeholder text on every slide.
        return extractZipXMLContent(from: url, matchers: [
            { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
        ])
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

    /// Extracts text from Office Open XML archives by trying each matcher in
    /// order, so primary content (shared strings, slides) claims the character
    /// budget before secondary files.
    private func extractZipXMLContent(from url: URL, matchers: [(String) -> Bool]) -> ContentMetadata? {
        guard let zipData = mappableZipData(at: url) else { return nil }

        let text = extractZipText(
            data: zipData,
            maximumEntryOutputBytes: maxOfficeXMLBytes,
            maximumTotalLength: maxDocumentTextLength,
            matchers: matchers
        )
        guard !text.isEmpty else { return nil }
        return ContentMetadata(textPreview: String(text.prefix(maxDocumentTextLength)))
    }

    // MARK: - Native ZIP Reading

    private struct ZipEntry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// Walks the ZIP central directory and returns its entries. The archive is
    /// already size-bounded by `mappableZipData`, so this stays cheap.
    private func zipEntries(in data: Data) -> [ZipEntry] {
        // ZIP end of central directory signature
        let eocdSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]

        guard data.count > 22 else { return [] }
        var eocdOffset = -1
        let searchStart = max(0, data.count - 65557)

        for i in stride(from: data.count - 22, through: searchStart, by: -1) {
            if data[i] == eocdSignature[0] && data[i+1] == eocdSignature[1] &&
               data[i+2] == eocdSignature[2] && data[i+3] == eocdSignature[3] {
                eocdOffset = i
                break
            }
        }

        guard eocdOffset >= 0 else { return [] }

        // Read central directory offset from EOCD
        let cdOffset = Int(data[eocdOffset + 16]) | (Int(data[eocdOffset + 17]) << 8) |
                       (Int(data[eocdOffset + 18]) << 16) | (Int(data[eocdOffset + 19]) << 24)

        // Iterate through central directory entries
        var pos = cdOffset
        let cdSignature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        var entries: [ZipEntry] = []

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

            entries.append(ZipEntry(
                name: String(data: data[nameStart..<nameEnd], encoding: .utf8) ?? "",
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))

            pos = nameEnd + extraFieldLength + commentLength
        }

        return entries
    }

    /// Reads one central-directory entry, honoring its compression method and
    /// bounding decompressed output.
    private func extractEntryData(
        _ entry: ZipEntry,
        from data: Data,
        maximumOutputBytes: Int
    ) -> Data? {
        let localPos = entry.localHeaderOffset
        guard localPos + 30 < data.count else { return nil }

        let localNameLen = Int(data[localPos + 26]) | (Int(data[localPos + 27]) << 8)
        let localExtraLen = Int(data[localPos + 28]) | (Int(data[localPos + 29]) << 8)
        let dataStart = localPos + 30 + localNameLen + localExtraLen
        let dataEnd = dataStart + entry.compressedSize

        guard dataStart <= dataEnd, dataEnd <= data.count else { return nil }

        let fileData = data[dataStart..<dataEnd]

        if entry.compressionMethod == 0 {
            // Stored (no compression)
            return Data(fileData.prefix(maximumOutputBytes))
        }
        if entry.compressionMethod == 8 {
            // Deflate — use Compression framework
            return decompressDeflate(
                Data(fileData),
                maximumOutputBytes: min(max(entry.uncompressedSize, 1), maximumOutputBytes)
            )
        }

        return nil
    }

    /// Extract a single file from a ZIP archive by name
    private func extractFileFromZip(
        data: Data,
        fileName: String,
        maximumOutputBytes: Int
    ) -> String? {
        guard let entry = zipEntries(in: data).first(where: { $0.name == fileName }),
              let entryData = extractEntryData(entry, from: data, maximumOutputBytes: maximumOutputBytes) else {
            return nil
        }
        return Self.decodeUTF8Prefix(entryData)
    }

    /// Extracts text from every entry matched by `matchers`, in matcher order
    /// so primary content claims the character budget first.
    private func extractZipText(
        data: Data,
        maximumEntryOutputBytes: Int,
        maximumTotalLength: Int,
        matchers: [(String) -> Bool]
    ) -> String {
        let entries = zipEntries(in: data)
        var combined = ""

        for matcher in matchers {
            for entry in entries where matcher(entry.name) {
                guard combined.count < maximumTotalLength else { break }
                guard let entryData = extractEntryData(
                    entry,
                    from: data,
                    maximumOutputBytes: maximumEntryOutputBytes
                ), let xml = Self.decodeUTF8Prefix(entryData) else { continue }

                let text = extractTextFromXMLTextElements(
                    xml,
                    maximumLength: maximumTotalLength - combined.count
                )
                guard !text.isEmpty else { continue }
                if !combined.isEmpty {
                    combined.append(" ")
                }
                combined.append(text)
            }
        }

        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func decodeUTF8Prefix(_ data: Data) -> String? {
        // Truncating valid UTF-8 can split at most one four-byte scalar at the
        // end. Try those boundary trims only; malformed interior bytes fail
        // closed instead of triggering a quadratic byte-by-byte scan.
        for trailingByteCount in 0...min(3, data.count) {
            let prefix = data.prefix(data.count - trailingByteCount)
            if let decoded = String(data: prefix, encoding: .utf8) {
                return decoded
            }
        }
        return data.isEmpty ? "" : nil
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

    /// Decodes text while keeping binary out. Single-byte encodings decode any
    /// byte sequence, so they are gated on a printability check and NUL scan.
    private func decodeText(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        // UTF-16 is trusted only when a byte-order mark proves the encoding;
        // its NUL-heavy bytes must be decoded before the binary gate below.
        if let utf16 = decodeUTF16WithBOM(data) {
            return normalizedText(utf16)
        }

        // NUL bytes mean binary, not text: no common text format contains them
        // (UTF-8 permits NUL, so this must run before any byte decoding).
        guard !data.contains(0) else { return nil }

        // UTF-8, trimming up to three trailing bytes so a multi-byte scalar
        // split by the 256 KB read cap does not force a fallback to a
        // single-byte encoding (which would turn CJK text into mojibake).
        // Only bytes that actually begin an incomplete scalar may be dropped:
        // a CP1252 tail such as 0xE9 ("é") must reach the legacy encodings
        // below with its last character intact.
        for trailingByteCount in 0...min(3, data.count) {
            let prefix = data.prefix(data.count - trailingByteCount)
            guard let decoded = String(data: prefix, encoding: .utf8) else { continue }
            if trailingByteCount > 0 {
                guard Self.isTruncatedUTF8Scalar(data.suffix(trailingByteCount)) else { continue }
                // One dropped byte is ambiguous: CP1252 "é" (0xE9) has the
                // same shape as a cut multi-byte scalar. Trust the trim only
                // when the decoded prefix proves the file is multi-byte UTF-8.
                if trailingByteCount == 1,
                   !decoded.unicodeScalars.contains(where: { $0.value > 0x7F }) {
                    continue
                }
            }
            if let text = normalizedText(decoded) { return text }
        }

        // Legacy single-byte encodings decode almost anything; only accept
        // results that are overwhelmingly printable.
        for encoding in [String.Encoding.windowsCP1252, .isoLatin1] {
            guard let decoded = String(data: data, encoding: encoding),
                  isPlausibleText(decoded) else { continue }
            if let text = normalizedText(decoded) { return text }
        }

        return nil
    }

    /// True when the bytes are the read-cap cut start of a multi-byte UTF-8
    /// scalar: a leading byte followed by only as many continuation bytes as
    /// were read, with the scalar still incomplete. A complete scalar, a bare
    /// ASCII byte, or bytes that cannot continue the lead byte return false.
    private nonisolated static func isTruncatedUTF8Scalar(_ bytes: Data) -> Bool {
        guard let lead = bytes.first else { return false }
        let sequenceLength: Int
        switch lead {
        case 0xC2...0xDF: sequenceLength = 2
        case 0xE0...0xEF: sequenceLength = 3
        case 0xF0...0xF4: sequenceLength = 4
        default: return false
        }
        guard bytes.count < sequenceLength else { return false }
        return bytes.dropFirst().allSatisfy { (0x80...0xBF).contains($0) }
    }

    /// Decodes UTF-16 only when a byte-order mark proves the data is text.
    private func decodeUTF16WithBOM(_ data: Data) -> String? {
        // A UTF-32 BOM starts with a UTF-16 BOM followed by NULs; decoding
        // such data as UTF-16 would produce garbage or NUL-stripped text.
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00])
            || data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return nil
        }

        let encoding: String.Encoding
        if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
        } else {
            return nil
        }

        guard let decoded = String(data: data, encoding: encoding) else { return nil }
        let text = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
        // A BOM alone does not prove the payload is text, so the result must
        // pass the same plausibility gate as the legacy encodings below.
        guard isPlausibleText(text) else { return nil }
        return text
    }

    /// True when the decoded string is mostly printable, so single-byte
    /// decodes of binary data are rejected instead of sent to the AI.
    private func isPlausibleText(_ text: String, maximumSuspiciousRatio: Double = 0.1) -> Bool {
        var scalarCount = 0
        var suspiciousCount = 0

        for scalar in text.unicodeScalars {
            scalarCount += 1
            let value = scalar.value
            let isControl = (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D)
                || (value >= 0x7F && value <= 0x9F)
            if value == 0xFFFD || isControl {
                suspiciousCount += 1
            }
        }

        guard scalarCount > 0 else { return false }
        return Double(suspiciousCount) <= Double(scalarCount) * maximumSuspiciousRatio
    }

    private func normalizedText(_ text: String) -> String? {
        let normalized = text
            .replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

// MARK: - Import for AppKit NSColor/NSImage
import AppKit
