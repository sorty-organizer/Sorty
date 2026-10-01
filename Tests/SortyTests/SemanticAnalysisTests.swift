//
//  SemanticAnalysisTests.swift
//  Sorty
//
//  Tests for Semantic Content Analysis, Smart Renaming, and Semantic Duplicate Detection
//

import XCTest
@testable import SortyLib
@testable import SortyCore
@testable import SortyFS
@testable import SortyAI
@testable import SortyModels

// MARK: - Content Metadata Tests

class ContentMetadataTests: XCTestCase {

    func testContentMetadataIsEmpty() {
        let emptyMetadata = ContentMetadata()
        XCTAssertTrue(emptyMetadata.isEmpty)

        let metadataWithText = ContentMetadata(textPreview: "Hello world")
        XCTAssertFalse(metadataWithText.isEmpty)

        let metadataWithOCR = ContentMetadata(ocrText: "Scanned text")
        XCTAssertFalse(metadataWithOCR.isEmpty)

        let metadataWithEXIF = ContentMetadata(exifData: ["camera": "iPhone 15"])
        XCTAssertFalse(metadataWithEXIF.isEmpty)
    }

    func testContentMetadataSummary() {
        let metadata = ContentMetadata(
            textPreview: "This is a test document",
            documentTitle: "Test Document",
            pageCount: 5
        )

        let summary = metadata.summary
        XCTAssertTrue(summary.contains("Title:"))
        XCTAssertTrue(summary.contains("Test Document"))
        XCTAssertTrue(summary.contains("5 pages"))
    }

    func testContentMetadataWithOCR() {
        let metadata = ContentMetadata(
            ocrText: "Internal Revenue Service Tax Return 2023",
            ocrConfidence: 0.95,
            detectedKeywords: ["tax", "irs"]
        )

        let summary = metadata.summary
        XCTAssertTrue(summary.contains("OCR:"))
        XCTAssertTrue(summary.contains("Detected:"))
    }

    func testAllTextContent() {
        let metadata = ContentMetadata(
            textPreview: "Document content",
            ocrText: "OCR content"
        )

        let allText = metadata.allTextContent
        XCTAssertNotNil(allText)
        XCTAssertTrue(allText!.contains("Document content"))
        XCTAssertTrue(allText!.contains("OCR content"))
    }
}

// MARK: - OCR Result Tests

class OCRResultTests: XCTestCase {

    func testOCRResultDetectedKeywords() {
        let taxText = "Internal Revenue Service Tax Return Form 1040"
        let result = OCRResult(text: taxText, confidence: 0.95)

        let keywords = result.detectedKeywords
        XCTAssertTrue(keywords.contains("tax"))
        XCTAssertTrue(keywords.contains("revenue"))
        XCTAssertTrue(keywords.contains("service"))
    }



    func testOCRResultIsEmpty() {
        let emptyResult = OCRResult(text: "   \n\t  ", confidence: 0.5)
        XCTAssertTrue(emptyResult.isEmpty)

        let validResult = OCRResult(text: "Some text", confidence: 0.8)
        XCTAssertFalse(validResult.isEmpty)
    }
}

// MARK: - Smart Renaming Tests

class SmartRenamingTests: XCTestCase {

    func testFileRenameMappingHasRename() {
        let file = FileItem(path: "/test/IMG_001.jpg", name: "IMG_001", extension: "jpg")

        let mappingWithRename = FileRenameMapping(
            originalFile: file,
            suggestedName: "2024-01-15_Photo_Beach.jpg",
            renameReason: "Added date and description"
        )
        XCTAssertTrue(mappingWithRename.hasRename)
        XCTAssertEqual(mappingWithRename.finalFilename, "2024-01-15_Photo_Beach.jpg")

        let mappingWithoutRename = FileRenameMapping(originalFile: file)
        XCTAssertFalse(mappingWithoutRename.hasRename)
        XCTAssertEqual(mappingWithoutRename.finalFilename, "IMG_001.jpg")
    }

    func testFolderSuggestionRenameCount() {
        let file1 = FileItem(path: "/test/IMG_001.jpg", name: "IMG_001", extension: "jpg")
        let file2 = FileItem(path: "/test/IMG_002.jpg", name: "IMG_002", extension: "jpg")
        let file3 = FileItem(path: "/test/document.pdf", name: "document", extension: "pdf")

        let renameMappings = [
            FileRenameMapping(originalFile: file1, suggestedName: "2024-01-15_Beach.jpg"),
            FileRenameMapping(originalFile: file2, suggestedName: "2024-01-15_Sunset.jpg"),
            FileRenameMapping(originalFile: file3) // No rename
        ]

        let suggestion = FolderSuggestion(
            folderName: "Photos",
            files: [file1, file2, file3],
            fileRenameMappings: renameMappings
        )

        XCTAssertEqual(suggestion.renameCount, 2)
    }

    func testFolderSuggestionRenameMapping() {
        let file = FileItem(path: "/test/doc.pdf", name: "doc", extension: "pdf")
        let mapping = FileRenameMapping(
            originalFile: file,
            suggestedName: "2024-01-Invoice.pdf",
            renameReason: "Added date prefix"
        )

        let suggestion = FolderSuggestion(
            folderName: "Invoices",
            files: [file],
            fileRenameMappings: [mapping]
        )

        let foundMapping = suggestion.renameMapping(for: file)
        XCTAssertNotNil(foundMapping)
        XCTAssertEqual(foundMapping?.suggestedName, "2024-01-Invoice.pdf")
    }

    func testFilesWithFinalNames() {
        let file1 = FileItem(path: "/test/a.txt", name: "a", extension: "txt")
        let file2 = FileItem(path: "/test/b.txt", name: "b", extension: "txt")

        let suggestion = FolderSuggestion(
            folderName: "Docs",
            files: [file1, file2],
            fileRenameMappings: [
                FileRenameMapping(originalFile: file1, suggestedName: "renamed_a.txt")
            ]
        )

        let filesWithNames = suggestion.filesWithFinalNames
        XCTAssertEqual(filesWithNames.count, 2)

        let renamedFile = filesWithNames.first { $0.file.id == file1.id }
        XCTAssertEqual(renamedFile?.finalName, "renamed_a.txt")

        let unchangedFile = filesWithNames.first { $0.file.id == file2.id }
        XCTAssertEqual(unchangedFile?.finalName, "b.txt")
    }
}

// MARK: - Semantic Duplicate Detection Tests

class SemanticDuplicateTests: XCTestCase {

    func testSemanticDuplicateGroupPotentialSavings() {
        let file1 = FileItem(path: "/test/photo1.jpg", name: "photo1", extension: "jpg", size: 1000000)
        let file2 = FileItem(path: "/test/photo2.jpg", name: "photo2", extension: "jpg", size: 800000)
        let file3 = FileItem(path: "/test/photo3.jpg", name: "photo3", extension: "jpg", size: 600000)

        let group = SemanticDuplicateGroup(
            groupType: .burstPhotos,
            files: [file1, file2, file3],
            similarity: 0.95
        )

        // Savings = total - largest file = 800000 + 600000 = 1400000
        XCTAssertEqual(group.potentialSavings, 1400000)
        XCTAssertEqual(group.totalSize, 2400000)
    }

    func testDuplicateRecommendationDescription() {
        let fileId = UUID()

        let keepHighest = SemanticDuplicateGroup.DuplicateRecommendation.keepHighestResolution(fileId: fileId)
        XCTAssertTrue(keepHighest.description.contains("highest resolution"))

        let keepNewest = SemanticDuplicateGroup.DuplicateRecommendation.keepNewest(fileId: fileId)
        XCTAssertTrue(keepNewest.description.contains("most recent"))

        let archive = SemanticDuplicateGroup.DuplicateRecommendation.archiveOlderVersions(keepId: fileId, archiveIds: [])
        XCTAssertTrue(archive.description.contains("Archive"))

        let manual = SemanticDuplicateGroup.DuplicateRecommendation.manualReview
        XCTAssertTrue(manual.description.contains("manual"))
    }

    func testSemanticThresholdMapsToHammingDistance() {
        XCTAssertEqual(SemanticDuplicateDetector.hammingThreshold(for: 1.0), 0)
        XCTAssertEqual(SemanticDuplicateDetector.hammingThreshold(for: 0.9), 6)
        XCTAssertEqual(SemanticDuplicateDetector.hammingThreshold(for: 0.7), 19)
    }

    func testSemanticThresholdClampingInHammingMapping() {
        XCTAssertEqual(SemanticDuplicateDetector.hammingThreshold(for: 2.0), 0)
        XCTAssertEqual(SemanticDuplicateDetector.hammingThreshold(for: 0.1), 19)
    }

    func testSimilarityForHammingDistance() {
        XCTAssertEqual(SemanticDuplicateDetector.similarityForHammingDistance(0), 1.0)
        XCTAssertEqual(SemanticDuplicateDetector.similarityForHammingDistance(6), 0.90625, accuracy: 0.0001)
        XCTAssertEqual(SemanticDuplicateDetector.similarityForHammingDistance(64), 0.0)
    }

    func testSimilarityPercentage() {
        let group = SemanticDuplicateGroup(
            groupType: .nearIdenticalImages,
            files: [],
            similarity: 0.857
        )

        XCTAssertEqual(group.similarityPercentage, "86%")
    }

    func testSemanticDetectorMergesOverlappingEvidence() async {
        let baseDate = Date()
        let files = [
            FileItem(
                path: "/test/IMG_1001.jpg",
                name: "IMG_1001",
                extension: "jpg",
                size: 1_000_000,
                creationDate: baseDate,
                contentFingerprint: String(repeating: "0", count: 64),
                imageWidth: 4_000,
                imageHeight: 3_000
            ),
            FileItem(
                path: "/test/IMG_1002.jpg",
                name: "IMG_1002",
                extension: "jpg",
                size: 1_100_000,
                creationDate: baseDate.addingTimeInterval(1),
                contentFingerprint: String(repeating: "0", count: 64),
                imageWidth: 4_000,
                imageHeight: 3_000
            ),
            FileItem(
                path: "/test/IMG_1003.jpg",
                name: "IMG_1003",
                extension: "jpg",
                size: 500_000,
                creationDate: baseDate.addingTimeInterval(2),
                contentFingerprint: String(repeating: "0", count: 64),
                imageWidth: 2_000,
                imageHeight: 1_500
            )
        ]

        let detector = SemanticDuplicateDetector(similarityThreshold: 0.90)
        let groups = await detector.findSemanticDuplicates(in: files)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].files.map(\.id)), Set(files.map(\.id)))
    }

    func testSemanticDetectorBuildsTransitiveImageGroups() async {
        let files = [
            FileItem(
                path: "/test/a.jpg",
                name: "a",
                extension: "jpg",
                size: 100,
                contentFingerprint: String(repeating: "0", count: 64)
            ),
            FileItem(
                path: "/test/b.jpg",
                name: "b",
                extension: "jpg",
                size: 100,
                contentFingerprint: String(repeating: "0", count: 60) + String(repeating: "1", count: 4)
            ),
            FileItem(
                path: "/test/c.jpg",
                name: "c",
                extension: "jpg",
                size: 100,
                contentFingerprint: String(repeating: "0", count: 56) + String(repeating: "1", count: 8)
            )
        ]

        let detector = SemanticDuplicateDetector(similarityThreshold: 0.90)
        let groups = await detector.findSemanticDuplicates(in: files)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].files.map(\.id)), Set(files.map(\.id)))
    }

    func testBurstDetectionDoesNotGroupUnrelatedSameSecondImages() async {
        let baseDate = Date()
        let files = [
            FileItem(
                path: "/test/receipt.jpg",
                name: "receipt",
                extension: "jpg",
                size: 1_000_000,
                creationDate: baseDate,
                imageWidth: 4_000,
                imageHeight: 3_000
            ),
            FileItem(
                path: "/test/screenshot.jpg",
                name: "screenshot",
                extension: "jpg",
                size: 1_000_000,
                creationDate: baseDate.addingTimeInterval(1),
                imageWidth: 4_000,
                imageHeight: 3_000
            )
        ]

        let detector = SemanticDuplicateDetector(similarityThreshold: 0.90)
        let groups = await detector.findSemanticDuplicates(in: files)

        XCTAssertTrue(groups.isEmpty)
    }

    func testDocumentVersionDetectionIgnoresMeaningfulBareNumbers() async {
        let files = [
            FileItem(path: "/test/tax-return-2024.pdf", name: "tax-return-2024", extension: "pdf"),
            FileItem(path: "/test/tax-return-2025.pdf", name: "tax-return-2025", extension: "pdf")
        ]

        let detector = SemanticDuplicateDetector(similarityThreshold: 0.90)
        let groups = await detector.findSemanticDuplicates(in: files)

        XCTAssertTrue(groups.isEmpty)
    }

    func testDocumentVersionDetectionGroupsExplicitVersions() async {
        let files = [
            FileItem(path: "/test/proposal-v1.pdf", name: "proposal-v1", extension: "pdf"),
            FileItem(path: "/test/proposal-v2.pdf", name: "proposal-v2", extension: "pdf")
        ]

        let detector = SemanticDuplicateDetector(similarityThreshold: 0.90)
        let groups = await detector.findSemanticDuplicates(in: files)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].groupType, .documentVersions)
        XCTAssertEqual(Set(groups[0].files.map(\.id)), Set(files.map(\.id)))
    }

    func testResolutionVariantsRequireVisualSimilarity() async {
        let files = [
            FileItem(
                path: "/test/banner-large.jpg",
                name: "banner-large",
                extension: "jpg",
                size: 2_000,
                contentFingerprint: String(repeating: "0", count: 64),
                imageWidth: 2_000,
                imageHeight: 1_000
            ),
            FileItem(
                path: "/test/banner-small.jpg",
                name: "banner-small",
                extension: "jpg",
                size: 1_000,
                contentFingerprint: String(repeating: "1", count: 64),
                imageWidth: 1_000,
                imageHeight: 500
            )
        ]

        let detector = SemanticDuplicateDetector(similarityThreshold: 0.90)
        let groups = await detector.findSemanticDuplicates(in: files)

        XCTAssertTrue(groups.isEmpty)
    }

    func testResolutionVariantsKeepDifferentSizedCopiesTogether() async {
        let fingerprint = String(repeating: "0", count: 64)
        let files = [
            FileItem(
                path: "/test/banner-large.jpg",
                name: "banner-large",
                extension: "jpg",
                size: 2_000,
                contentFingerprint: fingerprint,
                imageWidth: 2_000,
                imageHeight: 1_000
            ),
            FileItem(
                path: "/test/banner-small.jpg",
                name: "banner-small",
                extension: "jpg",
                size: 1_000,
                contentFingerprint: fingerprint,
                imageWidth: 1_000,
                imageHeight: 500
            )
        ]

        let detector = SemanticDuplicateDetector(similarityThreshold: 0.90)
        let groups = await detector.findSemanticDuplicates(in: files)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].groupType, .resolutionVariants)
        XCTAssertEqual(Set(groups[0].files.map(\.id)), Set(files.map(\.id)))
    }

    func testTextSimilarityNormalizesPunctuationAndSmallEdits() {
        let first = "Quarterly revenue increased by 18 percent, while operating costs stayed flat."
        let second = "Quarterly revenue increased by 18 percent while operating costs remained flat."

        XCTAssertGreaterThan(SemanticDuplicateDetector.textSimilarity(first, second), 0.80)
    }

    func testTextSimilarityUsesWordOrderToRejectSharedVocabulary() {
        let first = "Alice approved the payment after Bob reviewed the invoice."
        let second = "Bob approved the invoice after Alice reviewed the payment."

        XCTAssertLessThan(SemanticDuplicateDetector.textSimilarity(first, second), 0.90)
    }
}

// MARK: - FileItem Semantic Extensions Tests

class FileItemSemanticTests: XCTestCase {

    func testHasSemanticContent() {
        let fileWithOCR = FileItem(
            path: "/test/image.jpg",
            name: "image",
            extension: "jpg",
            ocrText: "Some recognized text"
        )
        XCTAssertTrue(fileWithOCR.hasSemanticContent)

        let fileWithMetadata = FileItem(
            path: "/test/doc.pdf",
            name: "doc",
            extension: "pdf",
            contentMetadata: ContentMetadata(textPreview: "Document text")
        )
        XCTAssertTrue(fileWithMetadata.hasSemanticContent)

        let fileWithMetadataOCR = FileItem(
            path: "/test/scan.jpg",
            name: "scan",
            extension: "jpg",
            contentMetadata: ContentMetadata(ocrText: "Invoice #123")
        )
        XCTAssertTrue(fileWithMetadataOCR.hasSemanticContent)

        let fileWithoutContent = FileItem(
            path: "/test/empty.txt",
            name: "empty",
            extension: "txt"
        )
        XCTAssertFalse(fileWithoutContent.hasSemanticContent)
    }

    func testSemanticTextContent() {
        let file = FileItem(
            path: "/test/doc.pdf",
            name: "doc",
            extension: "pdf",
            contentMetadata: ContentMetadata(
                textPreview: "Document content",
                documentTitle: "Important Document",
                keywords: ["finance", "report"]
            ),
            ocrText: "OCR extracted text"
        )

        let semanticContent = file.semanticTextContent
        XCTAssertNotNil(semanticContent)
        XCTAssertTrue(semanticContent!.contains("OCR:"))
        XCTAssertTrue(semanticContent!.contains("Title:"))
        XCTAssertTrue(semanticContent!.contains("Keywords:"))

        let metadataOCRFile = FileItem(
            path: "/test/scan.jpg",
            name: "scan",
            extension: "jpg",
            contentMetadata: ContentMetadata(
                ocrText: "Invoice 2026",
                detectedKeywords: ["invoice", "2026"]
            )
        )

        let metadataOCRContent = metadataOCRFile.semanticTextContent
        XCTAssertNotNil(metadataOCRContent)
        XCTAssertTrue(metadataOCRContent!.contains("OCR: Invoice 2026"))
        XCTAssertTrue(metadataOCRContent!.contains("Detected: invoice, 2026"))
    }

    func testResolutionString() {
        let fileWithDimensions = FileItem(
            path: "/test/photo.jpg",
            name: "photo",
            extension: "jpg",
            imageWidth: 1920,
            imageHeight: 1080
        )
        XCTAssertEqual(fileWithDimensions.resolutionString, "1920x1080")
        XCTAssertEqual(fileWithDimensions.totalPixels, 2073600)

        let fileWithoutDimensions = FileItem(
            path: "/test/doc.pdf",
            name: "doc",
            extension: "pdf"
        )
        XCTAssertNil(fileWithoutDimensions.resolutionString)
        XCTAssertNil(fileWithoutDimensions.totalPixels)
    }

    func testFinalDisplayName() {
        let file = FileItem(
            path: "/test/IMG_001.jpg",
            name: "IMG_001",
            extension: "jpg",
            suggestedFilename: "2024-01-15_Beach.jpg"
        )
        XCTAssertEqual(file.finalDisplayName, "2024-01-15_Beach.jpg")

        let fileWithoutSuggestion = FileItem(
            path: "/test/photo.jpg",
            name: "photo",
            extension: "jpg"
        )
        XCTAssertEqual(fileWithoutSuggestion.finalDisplayName, "photo.jpg")
    }
}

// MARK: - Response Parser Smart Renaming Tests

class ResponseParserSmartRenamingTests: XCTestCase {

    func testParseResponseWithSmartRenaming() throws {
        let jsonString = """
        {
            "folders": [
                {
                    "name": "Invoices",
                    "description": "Invoice documents",
                    "files": [
                        {
                            "filename": "doc1.pdf",
                            "suggested_name": "2024-01-15_Invoice_Google.pdf",
                            "rename_reason": "Added date and vendor"
                        },
                        "doc2.pdf"
                    ],
                    "reasoning": "Grouped invoices together"
                }
            ],
            "unorganized": []
        }
        """

        let originalFiles = [
            FileItem(path: "/test/doc1.pdf", name: "doc1", extension: "pdf"),
            FileItem(path: "/test/doc2.pdf", name: "doc2", extension: "pdf")
        ]

        let plan = try ResponseParser.parseResponse(jsonString, originalFiles: originalFiles, mode: .organizeAndRename)

        XCTAssertEqual(plan.suggestions.count, 1)

        let folder = plan.suggestions[0]
        XCTAssertEqual(folder.folderName, "Invoices")
        XCTAssertEqual(folder.files.count, 2)
        XCTAssertEqual(folder.renameCount, 1)

        // Check rename mapping
        let renamedFile = originalFiles[0]
        let mapping = folder.renameMapping(for: renamedFile)
        XCTAssertNotNil(mapping)
        XCTAssertEqual(mapping?.suggestedName, "2024-01-15_Invoice_Google.pdf")
        XCTAssertEqual(mapping?.renameReason, "Added date and vendor")
    }

    func testParseResponseWithSimpleFileList() throws {
        let jsonString = """
        {
            "folders": [
                {
                    "name": "Documents",
                    "files": ["file1.txt", "file2.txt"]
                }
            ]
        }
        """

        let originalFiles = [
            FileItem(path: "/test/file1.txt", name: "file1", extension: "txt"),
            FileItem(path: "/test/file2.txt", name: "file2", extension: "txt")
        ]

        let plan = try ResponseParser.parseResponse(jsonString, originalFiles: originalFiles)

        XCTAssertEqual(plan.suggestions.count, 1)
        XCTAssertEqual(plan.suggestions[0].files.count, 2)
        XCTAssertEqual(plan.suggestions[0].renameCount, 0)
    }

    func testParseResponseWithSemanticTags() throws {
        let jsonString = """
        {
            "folders": [
                {
                    "name": "Tax Documents",
                    "files": ["tax_return.pdf"],
                    "semantic_tags": ["tax", "irs", "2023"],
                    "confidence": 0.95
                }
            ]
        }
        """

        let originalFiles = [
            FileItem(path: "/test/tax_return.pdf", name: "tax_return", extension: "pdf")
        ]

        let plan = try ResponseParser.parseResponse(jsonString, originalFiles: originalFiles)

        let folder = plan.suggestions[0]
        XCTAssertEqual(folder.semanticTags, ["tax", "irs", "2023"])
        XCTAssertEqual(folder.confidenceScore, 0.95)
    }
}

// MARK: - VisionAnalyzer Tests (Integration)

class VisionAnalyzerTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory = tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        
    }

    func testGetImageDimensions() async {
        // Create a simple test image
        let analyzer = VisionAnalyzer()

        // Test with non-existent file
        let nonExistentURL = tempDirectory.appendingPathComponent("nonexistent.jpg")
        let dimensions = await analyzer.getImageDimensions(at: nonExistentURL)
        XCTAssertNil(dimensions)
    }

    func testAnalyzeNonImageFile() async {
        let analyzer = VisionAnalyzer()

        // Create a text file
        let textFileURL = tempDirectory.appendingPathComponent("test.txt")
        try? "This is not an image".write(to: textFileURL, atomically: true, encoding: .utf8)

        let result = await analyzer.analyzeImage(at: textFileURL)
        XCTAssertNil(result) // Should return nil for non-image files
    }
}

// MARK: - Exclusion Rules Tests for New Features

class ExclusionRulesExtendedTests: XCTestCase {

    func testFileTypeCategoryMatching() {
        let imageRule = ExclusionRule(
            type: .fileType,
            pattern: "",
            fileTypeCategory: .images
        )

        let jpgFile = FileItem(path: "/test/photo.jpg", name: "photo", extension: "jpg")
        let pdfFile = FileItem(path: "/test/doc.pdf", name: "doc", extension: "pdf")

        XCTAssertTrue(imageRule.matches(jpgFile))
        XCTAssertFalse(imageRule.matches(pdfFile))
    }

    func testHiddenFilesRule() {
        let hiddenRule = ExclusionRule(type: .hiddenFiles, pattern: "")

        let hiddenFile = FileItem(path: "/test/.hidden", name: ".hidden", extension: "")
        let normalFile = FileItem(path: "/test/normal.txt", name: "normal", extension: "txt")
        let deepHidden = FileItem(path: "/test/.folder/file.txt", name: "file", extension: "txt")

        XCTAssertTrue(hiddenRule.matches(hiddenFile))
        XCTAssertFalse(hiddenRule.matches(normalFile))
        XCTAssertTrue(hiddenRule.matches(deepHidden))
    }

    func testSystemFilesRule() {
        let systemRule = ExclusionRule(type: .systemFiles, pattern: "")

        let dsStore = FileItem(path: "/test/.DS_Store", name: ".DS_Store", extension: "")
        let thumbs = FileItem(path: "/test/Thumbs.db", name: "Thumbs", extension: "db")
        let normalFile = FileItem(path: "/test/normal.txt", name: "normal", extension: "txt")

        XCTAssertTrue(systemRule.matches(dsStore))
        XCTAssertTrue(systemRule.matches(thumbs))
        XCTAssertFalse(systemRule.matches(normalFile))
    }

    func testModificationDateRule() {
        let oldFilesRule = ExclusionRule(
            type: .modificationDate,
            pattern: "",
            numericValue: 30,
            comparisonGreater: true // Older than 30 days
        )

        let oldFile = FileItem(
            path: "/test/old.txt",
            name: "old",
            extension: "txt",
            creationDate: Date().addingTimeInterval(-60 * 86400) // 60 days ago
        )

        let newFile = FileItem(
            path: "/test/new.txt",
            name: "new",
            extension: "txt",
            creationDate: Date().addingTimeInterval(-5 * 86400) // 5 days ago
        )

        XCTAssertTrue(oldFilesRule.matches(oldFile))
        XCTAssertFalse(oldFilesRule.matches(newFile))
    }

    func testNegatedRule() {
        let onlyPDFsRule = ExclusionRule(
            type: .fileExtension,
            pattern: "pdf",
            negated: true // Exclude files that are NOT PDFs
        )

        let pdfFile = FileItem(path: "/test/doc.pdf", name: "doc", extension: "pdf")
        let txtFile = FileItem(path: "/test/doc.txt", name: "doc", extension: "txt")

        XCTAssertFalse(onlyPDFsRule.matches(pdfFile)) // PDF should NOT be excluded
        XCTAssertTrue(onlyPDFsRule.matches(txtFile)) // TXT should be excluded
    }

    func testCaseSensitiveRule() {
        let caseSensitiveRule = ExclusionRule(
            type: .fileName,
            pattern: "README",
            caseSensitive: true
        )

        let exactMatch = FileItem(path: "/test/README.md", name: "README", extension: "md")
        let lowercaseMatch = FileItem(path: "/test/readme.md", name: "readme", extension: "md")

        XCTAssertTrue(caseSensitiveRule.matches(exactMatch))
        XCTAssertFalse(caseSensitiveRule.matches(lowercaseMatch))
    }

    @MainActor
    func testDefaultRulesIncludeDeveloperExclusions() async {
        let suiteName = "default-rules-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = ExclusionRulesManager(userDefaults: defaults)
        await manager.loadPersistedState()
        let hasNodeModulesRule = manager.rules.contains {
            $0.type == .folderName && $0.pattern == "node_modules"
        }
        XCTAssertTrue(hasNodeModulesRule)
    }
}

// MARK: - File Type Category Tests

class FileTypeCategoryTests: XCTestCase {

    func testImageExtensions() {
        let imageCategory = FileTypeCategory.images
        XCTAssertTrue(imageCategory.extensions.contains("jpg"))
        XCTAssertTrue(imageCategory.extensions.contains("png"))
        XCTAssertTrue(imageCategory.extensions.contains("heic"))
        XCTAssertFalse(imageCategory.extensions.contains("pdf"))
    }

    func testDocumentExtensions() {
        let docCategory = FileTypeCategory.documents
        XCTAssertTrue(docCategory.extensions.contains("pdf"))
        XCTAssertTrue(docCategory.extensions.contains("docx"))
        XCTAssertTrue(docCategory.extensions.contains("txt"))
        XCTAssertFalse(docCategory.extensions.contains("mp4"))
    }

    func testCodeExtensions() {
        let codeCategory = FileTypeCategory.code
        XCTAssertTrue(codeCategory.extensions.contains("swift"))
        XCTAssertTrue(codeCategory.extensions.contains("py"))
        XCTAssertTrue(codeCategory.extensions.contains("js"))
        XCTAssertFalse(codeCategory.extensions.contains("jpg"))
    }
}

// MARK: - Test-only helpers (moved from VisionAnalyzer.swift)

private extension OCRResult {
    var detectedKeywords: [String] {
        detectKeywords(using: [])
    }
}
