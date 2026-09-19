//
//  ContentAnalyzerTests.swift
//  SortyTests
//
//  Comprehensive tests for ContentAnalyzer and ContentMetadata
//

import XCTest
@testable import SortyLib

// MARK: - ContentMetadata Tests (Additional Coverage)

final class ContentMetadataExtendedTests: XCTestCase {
    
    // MARK: - Initialization Tests
    
    func testDefaultInitialization() {
        let metadata = ContentMetadata()
        
        XCTAssertNil(metadata.textPreview)
        XCTAssertNil(metadata.documentTitle)
        XCTAssertNil(metadata.exifData)
        XCTAssertNil(metadata.pageCount)
        XCTAssertNil(metadata.author)
        XCTAssertNil(metadata.creationDate)
        XCTAssertNil(metadata.keywords)
        XCTAssertNil(metadata.ocrText)
        XCTAssertNil(metadata.ocrConfidence)
        XCTAssertNil(metadata.detectedKeywords)
    }
    
    func testCustomInitialization() {
        let date = Date()
        let metadata = ContentMetadata(
            textPreview: "This is a preview",
            documentTitle: "Test Document",
            exifData: ["camera": "iPhone 15", "dateTime": "2024-01-01"],
            pageCount: 5,
            author: "Test Author",
            creationDate: date,
            keywords: ["test", "document"],
            ocrText: "OCR extracted text",
            ocrConfidence: 0.95,
            detectedKeywords: ["invoice", "receipt"]
        )
        
        XCTAssertEqual(metadata.textPreview, "This is a preview")
        XCTAssertEqual(metadata.documentTitle, "Test Document")
        XCTAssertEqual(metadata.exifData?["camera"], "iPhone 15")
        XCTAssertEqual(metadata.pageCount, 5)
        XCTAssertEqual(metadata.author, "Test Author")
        XCTAssertEqual(metadata.creationDate, date)
        XCTAssertEqual(metadata.keywords, ["test", "document"])
        XCTAssertEqual(metadata.ocrText, "OCR extracted text")
        XCTAssertEqual(metadata.ocrConfidence, 0.95)
        XCTAssertEqual(metadata.detectedKeywords, ["invoice", "receipt"])
    }
    
    // MARK: - isEmpty Tests
    
    func testIsEmptyWhenAllNil() {
        let metadata = ContentMetadata()
        XCTAssertTrue(metadata.isEmpty)
    }
    
    func testIsEmptyWithTextPreview() {
        let metadata = ContentMetadata(textPreview: "Some text")
        XCTAssertFalse(metadata.isEmpty)
    }
    
    func testIsEmptyWithDocumentTitle() {
        let metadata = ContentMetadata(documentTitle: "Title")
        XCTAssertFalse(metadata.isEmpty)
    }
    
    func testIsEmptyWithExifData() {
        let metadata = ContentMetadata(exifData: ["camera": "iPhone"])
        XCTAssertFalse(metadata.isEmpty)
    }
    
    func testIsEmptyWithOCRText() {
        let metadata = ContentMetadata(ocrText: "OCR text")
        XCTAssertFalse(metadata.isEmpty)
    }
    
    func testIsNotEmptyWithStructuredMetadataOnly() {
        let metadata = ContentMetadata(
            pageCount: 10,
            author: "Author",
            keywords: ["test"]
        )
        XCTAssertFalse(metadata.isEmpty)
    }
    
    // MARK: - allTextContent Tests
    
    func testAllTextContentWhenEmpty() {
        let metadata = ContentMetadata()
        XCTAssertNil(metadata.allTextContent)
    }
    
    func testAllTextContentWithTextPreviewOnly() {
        let metadata = ContentMetadata(textPreview: "Preview text")
        XCTAssertEqual(metadata.allTextContent, "Preview text")
    }
    
    func testAllTextContentWithOCROnly() {
        let metadata = ContentMetadata(ocrText: "OCR text")
        XCTAssertEqual(metadata.allTextContent, "OCR text")
    }
    
    func testAllTextContentWithBoth() {
        let metadata = ContentMetadata(
            textPreview: "Preview text",
            ocrText: "OCR text"
        )
        XCTAssertEqual(metadata.allTextContent, "Preview text OCR text")
    }
    
    // MARK: - summary Tests
    
    func testSummaryWhenEmpty() {
        let metadata = ContentMetadata()
        XCTAssertEqual(metadata.summary, "")
    }
    
    func testSummaryWithTitle() {
        let metadata = ContentMetadata(documentTitle: "My Document")
        XCTAssertTrue(metadata.summary.contains("Title: \"My Document\""))
    }
    
    func testSummaryWithTextPreview() {
        let metadata = ContentMetadata(textPreview: "This is the content preview")
        XCTAssertTrue(metadata.summary.contains("Content:"))
        XCTAssertTrue(metadata.summary.contains("content preview"))
    }
    
    func testSummaryWithOCR() {
        let metadata = ContentMetadata(ocrText: "OCR extracted text")
        XCTAssertTrue(metadata.summary.contains("OCR:"))
    }
    
    func testSummaryWithDetectedKeywords() {
        let metadata = ContentMetadata(detectedKeywords: ["invoice", "receipt"])
        XCTAssertTrue(metadata.summary.contains("Detected:"))
        XCTAssertTrue(metadata.summary.contains("invoice"))
    }
    
    func testSummaryWithCameraInfo() {
        let metadata = ContentMetadata(exifData: ["camera": "iPhone 15 Pro"])
        XCTAssertTrue(metadata.summary.contains("Camera: iPhone 15 Pro"))
    }
    
    func testSummaryWithDateTime() {
        let metadata = ContentMetadata(exifData: ["dateTime": "2024-01-15 10:30:00"])
        XCTAssertTrue(metadata.summary.contains("Taken:"))
    }
    
    func testSummaryWithPageCount() {
        let metadata = ContentMetadata(pageCount: 42)
        XCTAssertTrue(metadata.summary.contains("42 pages"))
    }
    
    func testSummaryWithMultipleFields() {
        let metadata = ContentMetadata(
            textPreview: "Preview",
            documentTitle: "Title",
            pageCount: 5
        )
        
        let summary = metadata.summary
        XCTAssertTrue(summary.hasPrefix("["))
        XCTAssertTrue(summary.hasSuffix("]"))
        XCTAssertTrue(summary.contains(","))
    }
    
    // MARK: - Codable Tests
    
    func testCodable() throws {
        let original = ContentMetadata(
            textPreview: "Preview",
            documentTitle: "Title",
            exifData: ["camera": "iPhone"],
            pageCount: 10,
            author: "Author",
            creationDate: Date(),
            keywords: ["test"],
            ocrText: "OCR",
            ocrConfidence: 0.9,
            detectedKeywords: ["keyword"]
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ContentMetadata.self, from: data)
        
        XCTAssertEqual(decoded.textPreview, original.textPreview)
        XCTAssertEqual(decoded.documentTitle, original.documentTitle)
        XCTAssertEqual(decoded.exifData, original.exifData)
        XCTAssertEqual(decoded.pageCount, original.pageCount)
        XCTAssertEqual(decoded.author, original.author)
        XCTAssertEqual(decoded.keywords, original.keywords)
        XCTAssertEqual(decoded.ocrText, original.ocrText)
        XCTAssertEqual(decoded.ocrConfidence, original.ocrConfidence)
        XCTAssertEqual(decoded.detectedKeywords, original.detectedKeywords)
    }
    
    // MARK: - Hashable Tests
    
    func testHashable() {
        let metadata1 = ContentMetadata(textPreview: "Same", documentTitle: "Same")
        let metadata2 = ContentMetadata(textPreview: "Same", documentTitle: "Same")
        let metadata3 = ContentMetadata(textPreview: "Different", documentTitle: "Different")
        
        XCTAssertEqual(metadata1.hashValue, metadata2.hashValue)
        XCTAssertNotEqual(metadata1.hashValue, metadata3.hashValue)
    }
    
    func testHashableInSet() {
        var set = Set<ContentMetadata>()
        
        let metadata1 = ContentMetadata(textPreview: "Test")
        let metadata2 = ContentMetadata(textPreview: "Test")
        let metadata3 = ContentMetadata(textPreview: "Other")
        
        set.insert(metadata1)
        set.insert(metadata2)
        set.insert(metadata3)
        
        XCTAssertEqual(set.count, 2) // metadata1 and metadata2 are equal
    }
    
}

// MARK: - ContentAnalyzer Tests

final class ContentAnalyzerTests: XCTestCase {
    
    var tempDirectory: URL!
    
    override func setUp() async throws {
        
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() async throws {
        if let tempDirectory = tempDirectory {
            do {
                try FileManager.default.removeItem(at: tempDirectory)
            } catch {
                XCTFail("Failed to clean up test directory: " + String(describing: error))
            }
        }
        
    }
    
    func testConfigurationDefaults() async {
        let analyzer = ContentAnalyzer()
        
        // Access properties to verify they're accessible
        let enableOCR = await analyzer.enableOCR
        let enableDeepScan = await analyzer.enableDeepDocumentScan
        
        XCTAssertTrue(enableOCR)
        XCTAssertTrue(enableDeepScan)
    }
    
    func testConfigurationModification() async {
        let analyzer = ContentAnalyzer()
        
        await analyzer.setEnableOCR(false)
        await analyzer.setEnableDeepDocumentScan(false)
        
        let enableOCR = await analyzer.enableOCR
        let enableDeepScan = await analyzer.enableDeepDocumentScan
        
        XCTAssertFalse(enableOCR)
        XCTAssertFalse(enableDeepScan)
    }
    
    // MARK: - Analyze Non-Existent File
    
    func testAnalyzeNonExistentFile() async {
        let analyzer = ContentAnalyzer()
        let nonExistentURL = URL(fileURLWithPath: "/path/that/does/not/exist.txt")
        
        let result = await analyzer.analyze(fileURL: nonExistentURL)
        
        XCTAssertNil(result)
    }
    
    // MARK: - Analyze Unsupported File Type
    
    func testAnalyzeUnsupportedFileType() async throws {
        let analyzer = ContentAnalyzer()
        
        let unsupportedFile = tempDirectory.appendingPathComponent("test.xyz")
        try "some content".write(to: unsupportedFile, atomically: true, encoding: .utf8)
        
        let result = await analyzer.analyze(fileURL: unsupportedFile)
        
        XCTAssertNil(result)
    }
    
    // MARK: - Text File Analysis
    
    func testAnalyzeTextFile() async throws {
        let analyzer = ContentAnalyzer()
        
        let textFile = tempDirectory.appendingPathComponent("test.txt")
        let content = "This is a test text file with some content for analysis."
        try content.write(to: textFile, atomically: true, encoding: .utf8)
        
        let result = await analyzer.analyze(fileURL: textFile)
        
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.textPreview, content)
    }
    
    func testAnalyzeMarkdownFile() async throws {
        let analyzer = ContentAnalyzer()
        
        let mdFile = tempDirectory.appendingPathComponent("README.md")
        let content = "# Heading\n\nThis is markdown content."
        try content.write(to: mdFile, atomically: true, encoding: .utf8)
        
        let result = await analyzer.analyze(fileURL: mdFile)
        
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.textPreview?.contains("Heading") ?? false)
    }
    
    func testAnalyzeLargeTextFile() async throws {
        let analyzer = ContentAnalyzer()
        
        let textFile = tempDirectory.appendingPathComponent("large.txt")
        // Create content larger than the analyzer's read/preview limits.
        let content = String(repeating: "A", count: 5000)
        try content.write(to: textFile, atomically: true, encoding: .utf8)
        
        let result = await analyzer.analyze(fileURL: textFile)
        
        XCTAssertNotNil(result)
        // Should be truncated to maxPreviewLength
        XCTAssertLessThanOrEqual(result?.textPreview?.count ?? 0, ContentAnalyzer.defaultTextPreviewLength)
    }
    
    // MARK: - Batch Analysis
    
    func testAnalyzeFilesEmpty() async {
        let analyzer = ContentAnalyzer()
        
        let results = await analyzer.analyzeFiles([])
        
        XCTAssertTrue(results.isEmpty)
    }
    
    func testAnalyzeFilesWithProgress() async throws {
        let analyzer = ContentAnalyzer()
        
        // Create test files
        let file1 = tempDirectory.appendingPathComponent("file1.txt")
        let file2 = tempDirectory.appendingPathComponent("file2.txt")
        
        try "Content 1".write(to: file1, atomically: true, encoding: .utf8)
        try "Content 2".write(to: file2, atomically: true, encoding: .utf8)
        
        // Track that progress handler was called using nonisolated(unsafe) for the @Sendable closure
        nonisolated(unsafe) var progressCalled = false
        nonisolated(unsafe) var lastProgress: (current: Int, total: Int) = (0, 0)
        
        let results = await analyzer.analyzeFiles([file1, file2]) { current, total in
            progressCalled = true
            lastProgress = (current, total)
        }
        
        XCTAssertEqual(results.count, 2)
        XCTAssertNotNil(results[file1])
        XCTAssertNotNil(results[file2])
        
        // Verify progress handler was called and final state is correct
        XCTAssertTrue(progressCalled)
        XCTAssertEqual(lastProgress.current, 2)
        XCTAssertEqual(lastProgress.total, 2)
    }
    
    func testAnalyzeFilesMixedTypes() async throws {
        let analyzer = ContentAnalyzer()
        
        let textFile = tempDirectory.appendingPathComponent("test.txt")
        let unsupportedFile = tempDirectory.appendingPathComponent("test.xyz")
        
        try "Text content".write(to: textFile, atomically: true, encoding: .utf8)
        try "Other content".write(to: unsupportedFile, atomically: true, encoding: .utf8)
        
        let results = await analyzer.analyzeFiles([textFile, unsupportedFile])
        
        // Only supported file should have results
        XCTAssertEqual(results.count, 1)
        XCTAssertNotNil(results[textFile])
        XCTAssertNil(results[unsupportedFile])
    }
    
    // MARK: - OCR Flag Tests
    
    func testAnalyzeWithOCRDisabled() async throws {
        let analyzer = ContentAnalyzer()
        
        let textFile = tempDirectory.appendingPathComponent("test.txt")
        try "Content".write(to: textFile, atomically: true, encoding: .utf8)
        
        let result = await analyzer.analyze(fileURL: textFile, enableOCR: false)
        
        // Text files don't use OCR, but verify the parameter is accepted
        XCTAssertNotNil(result)
    }
}

// MARK: - New Fields Tests (Duration, MediaInfo)

final class ContentMetadataMediaTests: XCTestCase {

    func testDurationAndMediaInfoInitialization() {
        let metadata = ContentMetadata(
            duration: 180.5,
            mediaInfo: ["artist": "Test Artist", "album": "Test Album"]
        )

        XCTAssertEqual(metadata.duration, 180.5)
        XCTAssertEqual(metadata.mediaInfo?["artist"], "Test Artist")
        XCTAssertEqual(metadata.mediaInfo?["album"], "Test Album")
    }

    func testIsEmptyWithMediaInfo() {
        let metadata = ContentMetadata(mediaInfo: ["codec": "AAC"])
        XCTAssertFalse(metadata.isEmpty, "mediaInfo alone should make isEmpty false")
    }

    func testIsEmptyWithDurationOnly() {
        // Duration is meaningful media metadata even without descriptive fields.
        let metadata = ContentMetadata(duration: 60)
        XCTAssertFalse(metadata.isEmpty)
    }

    func testSummaryWithDuration() {
        let metadata = ContentMetadata(
            duration: 195,
            mediaInfo: ["title": "Song"]
        )
        let summary = metadata.summary
        XCTAssertTrue(summary.contains("Duration: 3m 15s"))
        XCTAssertTrue(summary.contains("Track: Song"))
    }

    func testSummaryWithArtist() {
        let metadata = ContentMetadata(
            mediaInfo: ["artist": "Bach"]
        )
        XCTAssertTrue(metadata.summary.contains("Artist: Bach"))
    }

    func testCodableWithMediaFields() throws {
        let original = ContentMetadata(
            duration: 300.0,
            mediaInfo: ["artist": "Mozart", "album": "Requiem"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContentMetadata.self, from: data)

        XCTAssertEqual(decoded.duration, 300.0)
        XCTAssertEqual(decoded.mediaInfo?["artist"], "Mozart")
        XCTAssertEqual(decoded.mediaInfo?["album"], "Requiem")
    }
}

// MARK: - RTF Extraction Tests

final class ContentAnalyzerRTFTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory = tempDirectory {
            do {
                try FileManager.default.removeItem(at: tempDirectory)
            } catch {
                XCTFail("Failed to clean up test directory: " + String(describing: error))
            }
        }
    }

    func testRTFExtractionStripsFormatting() async throws {
        let analyzer = ContentAnalyzer()

        // Create a minimal RTF file
        let rtfContent = #"{\rtf1\ansi Hello World}"#
        let rtfFile = tempDirectory.appendingPathComponent("test.rtf")
        try rtfContent.write(to: rtfFile, atomically: true, encoding: .utf8)

        let result = await analyzer.analyze(fileURL: rtfFile)

        XCTAssertNotNil(result)
        // Should extract clean text, not raw RTF tags
        XCTAssertTrue(result?.textPreview?.contains("Hello World") ?? false)
        XCTAssertFalse(result?.textPreview?.contains("\\rtf1") ?? true)
    }
}

// MARK: - Content Cache Tests

final class ContentAnalyzerCacheTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory = tempDirectory {
            do {
                try FileManager.default.removeItem(at: tempDirectory)
            } catch {
                XCTFail("Failed to clean up test directory: " + String(describing: error))
            }
        }
    }

    func testCacheHitOnReanalyze() async throws {
        let analyzer = ContentAnalyzer()

        let textFile = tempDirectory.appendingPathComponent("cached.txt")
        try "Cache me".write(to: textFile, atomically: true, encoding: .utf8)

        let first = await analyzer.analyze(fileURL: textFile)
        XCTAssertNotNil(first)

        // Second call should hit cache and return same result
        let second = await analyzer.analyze(fileURL: textFile)
        XCTAssertEqual(first?.textPreview, second?.textPreview)
    }

    func testCacheInvalidatedOnModification() async throws {
        let analyzer = ContentAnalyzer()

        let textFile = tempDirectory.appendingPathComponent("mutable.txt")
        try "Original".write(to: textFile, atomically: true, encoding: .utf8)

        let first = await analyzer.analyze(fileURL: textFile)
        XCTAssertEqual(first?.textPreview, "Original")

        // Bump mtime explicitly: 100ms sleeps are flaky on coarse filesystems
        // and can leave the cache thinking the file is unchanged.
        try await Task.sleep(for: .milliseconds(250))
        try "Updated content".write(to: textFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: textFile.path
        )

        let second = await analyzer.analyze(fileURL: textFile)
        XCTAssertEqual(second?.textPreview, "Updated content")
    }

    func testClearCacheRemovesEntries() async throws {
        let analyzer = ContentAnalyzer()

        let textFile = tempDirectory.appendingPathComponent("clearable.txt")
        try "Data".write(to: textFile, atomically: true, encoding: .utf8)

        _ = await analyzer.analyze(fileURL: textFile)
        await analyzer.clearCache()

        // After clearing, next analyze should still work
        let result = await analyzer.analyze(fileURL: textFile)
        XCTAssertNotNil(result)
    }
}

// MARK: - enableDeepDocumentScan Flag Tests

final class ContentAnalyzerDeepScanFlagTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory = tempDirectory {
            do {
                try FileManager.default.removeItem(at: tempDirectory)
            } catch {
                XCTFail("Failed to clean up test directory: " + String(describing: error))
            }
        }
    }

    func testDeepScanDisabledSkipsTextFiles() async throws {
        let analyzer = ContentAnalyzer()
        await analyzer.setEnableDeepDocumentScan(false)

        let textFile = tempDirectory.appendingPathComponent("skip.txt")
        try "Should be skipped".write(to: textFile, atomically: true, encoding: .utf8)

        let result = await analyzer.analyze(fileURL: textFile)
        XCTAssertNil(result, "Text files should be skipped when enableDeepDocumentScan is false")
    }

    func testDeepScanDisabledSkipsRTF() async throws {
        let analyzer = ContentAnalyzer()
        await analyzer.setEnableDeepDocumentScan(false)

        let rtfContent = #"{\rtf1\ansi Skipped}"#
        let rtfFile = tempDirectory.appendingPathComponent("skip.rtf")
        try rtfContent.write(to: rtfFile, atomically: true, encoding: .utf8)

        let result = await analyzer.analyze(fileURL: rtfFile)
        XCTAssertNil(result, "RTF files should be skipped when enableDeepDocumentScan is false")
    }

    func testDeepScanDisabledStillAllowsMediaExtraction() async throws {
        // Media extraction is considered "light" and should still work
        let analyzer = ContentAnalyzer()
        await analyzer.setEnableDeepDocumentScan(false)

        // Can't easily create a real media file, but verify the extension is handled
        let fakeMedia = tempDirectory.appendingPathComponent("test.mp3")
        try Data().write(to: fakeMedia)

        // Will return nil because it's not a valid mp3, but the point is it attempted extraction
        _ = await analyzer.analyze(fileURL: fakeMedia)
        // Just verify no crash
    }
}

// MARK: - OCR Keywords Tests

final class OCRKeywordsTests: XCTestCase {

    func testDefaultKeywordsDetection() {
        let result = OCRResult(
            text: "This is an invoice for payment of $500",
            confidence: 0.9,
            wordCount: 8
        )

        XCTAssertTrue(result.detectKeywords(using: []).contains("invoice"))
        XCTAssertTrue(result.detectKeywords(using: []).contains("payment"))
    }

    func testCustomKeywordsDetection() {
        let result = OCRResult(
            text: "Quarterly budget forecast for engineering team",
            confidence: 0.85,
            wordCount: 6
        )

        let detected = result.detectKeywords(using: ["budget", "forecast", "engineering"])
        XCTAssertTrue(detected.contains("budget"))
        XCTAssertTrue(detected.contains("forecast"))
        XCTAssertTrue(detected.contains("engineering"))
    }

    func testCustomKeywordsDoNotDuplicateDefaults() {
        let result = OCRResult(
            text: "An invoice document",
            confidence: 0.9,
            wordCount: 3
        )

        let detected = result.detectKeywords(using: ["invoice"]) // "invoice" is already a default
        let invoiceCount = detected.filter { $0 == "invoice" }.count
        XCTAssertEqual(invoiceCount, 1, "Should not duplicate default keywords")
    }

}

// MARK: - Prompt Builder Prioritization Tests

final class PromptBuilderPrioritizationTests: XCTestCase {

    func testDeepScannedFilesPrioritizedInPrompt() {
        // Create files where some have content metadata and some don't
        var filesWithMetadata: [FileItem] = []
        var filesWithout: [FileItem] = []

        for i in 0..<30 {
            filesWithMetadata.append(FileItem(
                path: "/test/file\(i).pdf",
                name: "file\(i)",
                extension: "pdf",
                size: 1024,
                contentMetadata: ContentMetadata(textPreview: "Content \(i)")
            ))
        }

        for i in 30..<80 {
            filesWithout.append(FileItem(
                path: "/test/file\(i).pdf",
                name: "file\(i)",
                extension: "pdf",
                size: 1024
            ))
        }

        // Mix them up - put files without metadata first
        let allFiles = filesWithout + filesWithMetadata

        let prompt = PromptBuilder.buildOrganizationPrompt(
            files: allFiles,
            includeContentMetadata: true
        )

        // All 30 files with metadata should appear in the prompt (they're prioritized)
        for i in 0..<30 {
            XCTAssertTrue(prompt.contains("file\(i).pdf"), "File with metadata file\(i) should be in prompt")
        }
    }

    func testWithoutContentMetadataNoSorting() {
        var files: [FileItem] = []
        for i in 0..<60 {
            files.append(FileItem(
                path: "/test/file\(i).pdf",
                name: "file\(i)",
                extension: "pdf",
                size: 1024
            ))
        }

        // When includeContentMetadata is false, no sorting should occur
        let prompt = PromptBuilder.buildOrganizationPrompt(
            files: files,
            includeContentMetadata: false
        )

        // Every file should remain present and preserve the input order.
        let firstFileRange = prompt.range(of: "file0.pdf")
        let lastFileRange = prompt.range(of: "file59.pdf")

        XCTAssertNotNil(firstFileRange)
        XCTAssertNotNil(lastFileRange)
        if let firstFileRange, let lastFileRange {
            XCTAssertLessThan(firstFileRange.lowerBound, lastFileRange.lowerBound)
        }
    }
}

// MARK: - AIConfig Custom OCR Keywords Tests

final class AIConfigOCRKeywordsTests: XCTestCase {

    func testCustomOCRKeywordsDefault() {
        let config = AIConfig.default
        XCTAssertNil(config.customOCRKeywords)
    }

    func testCustomOCRKeywordsSetAndGet() {
        var config = AIConfig.default
        config.customOCRKeywords = ["budget", "forecast", "quarterly"]
        XCTAssertEqual(config.customOCRKeywords, ["budget", "forecast", "quarterly"])
    }

    func testCustomOCRKeywordsCodable() throws {
        var config = AIConfig.default
        config.customOCRKeywords = ["custom1", "custom2"]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AIConfig.self, from: data)

        XCTAssertEqual(decoded.customOCRKeywords, ["custom1", "custom2"])
    }

    func testLimitVisionImagesDefault() {
        let config = AIConfig.default
        XCTAssertTrue(config.limitVisionImages)
        XCTAssertEqual(config.visionBatchSize, 12)
        XCTAssertEqual(config.visionBatchStrategy, .noText)
    }

    func testLegacyVisionDefaultsMigrateToQualityFirstSampling() throws {
        let config = AIConfig(
            limitVisionImages: true,
            visionBatchSize: 5,
            visionBatchStrategy: .firstN
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AIConfig.self, from: data)

        XCTAssertEqual(decoded.visionBatchSize, 12)
        XCTAssertEqual(decoded.visionBatchStrategy, .noText)
    }

    func testVisionAndOCRSettingsCodable() throws {
        var config = AIConfig.default
        config.limitVisionImages = false
        config.visionBatchStrategy = .noText
        config.visionDetailLevel = .high
        config.ocrLanguages = ["en-US", "fr-FR"]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AIConfig.self, from: data)

        XCTAssertFalse(decoded.limitVisionImages)
        XCTAssertEqual(decoded.visionBatchStrategy, .noText)
        XCTAssertEqual(decoded.visionDetailLevel, .high)
        XCTAssertEqual(decoded.ocrLanguages, ["en-US", "fr-FR"])
    }

    func testCopilotDefaultsVisionDetailToLow() {
        let config = AIConfig(provider: .githubCopilot, model: "gpt-4o")
        XCTAssertEqual(config.visionDetailLevel, .low)
        XCTAssertEqual(config.effectiveVisionDetailLevel, .low)
    }
}

// MARK: - Helper Extension for Tests

extension ContentAnalyzer {
    func setEnableOCR(_ value: Bool) {
        enableOCR = value
    }
    
    func setEnableDeepDocumentScan(_ value: Bool) {
        enableDeepDocumentScan = value
    }
}
