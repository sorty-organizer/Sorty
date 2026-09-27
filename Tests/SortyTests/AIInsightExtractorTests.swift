import XCTest
@testable import SortyLib
@testable import SortyCore

final class AIInsightExtractorTests: XCTestCase {
    func testExtractsJSONFileAssignmentInsight() async {
        let extractor = AIInsightExtractor()
        let content = """
        {"folders":[{"name":"Receipts","files":["report.pdf"]}]}
        """
        let lookup = ["report.pdf": ["/tmp/report.pdf"]]

        let insight = await extractor.extractInsight(
            from: content,
            scannedFilePathLookup: lookup,
            currentDirectoryPath: "/tmp"
        )

        XCTAssertEqual(insight?.category, .file)
        XCTAssertEqual(insight?.filePath, "/tmp/report.pdf")
        XCTAssertTrue(insight?.text.contains("report.pdf") == true)
        XCTAssertTrue(insight?.text.contains("Receipts") == true)
    }

    func testExtractsJSONFolderInsightDuringPartialResponse() async {
        let extractor = AIInsightExtractor()
        let content = """
        {"folders":[{"name":"Legal","files":[
        """

        let insight = await extractor.extractInsight(
            from: content,
            scannedFilePathLookup: [:],
            currentDirectoryPath: nil
        )

        XCTAssertEqual(insight?.category, .folder)
        XCTAssertTrue(insight?.text.contains("Legal") == true)
    }

    func testExtractsJSONReasoningInsight() async {
        let extractor = AIInsightExtractor()
        let content = """
        {"reasoning":"Grouping records by quarter keeps project reports easy to locate for audits."}
        """

        let insight = await extractor.extractInsight(
            from: content,
            scannedFilePathLookup: [:],
            currentDirectoryPath: nil
        )

        XCTAssertEqual(insight?.category, .decision)
        XCTAssertTrue(insight?.text.contains("Grouping records by quarter") == true)
    }

    func testSkipsPromptNoiseConstraints() async {
        let extractor = AIInsightExtractor()
        let content = """
        IMPORTANT: The following patterns are STRICTLY EXCLUDED and must NOT be moved, renamed, or modified.
        """

        let insight = await extractor.extractInsight(
            from: content,
            scannedFilePathLookup: [:],
            currentDirectoryPath: nil
        )

        XCTAssertNil(insight)
    }

    func testDoesNotProduceCategoryLimitInsight() async {
        let extractor = AIInsightExtractor()
        let content = """
        Analyzing category (Documents). limit: <=10. Preferred categories: Documents.
        """

        let insight = await extractor.extractInsight(
            from: content,
            scannedFilePathLookup: [:],
            currentDirectoryPath: nil
        )

        XCTAssertNil(insight)
    }

    func testKnownFileAndFolderMentionProducesAssignmentInsight() async {
        let extractor = AIInsightExtractor()
        let content = """
        This suggests it's a manual. Maybe Manuals folder. Getting Started_1.tns fits there.
        """
        let lookup = ["getting started_1.tns": ["/tmp/Getting Started_1.tns"]]

        let insight = await extractor.extractInsight(
            from: content,
            scannedFilePathLookup: lookup,
            currentDirectoryPath: "/tmp"
        )

        XCTAssertEqual(insight?.category, .file)
        XCTAssertEqual(insight?.filePath, "/tmp/Getting Started_1.tns")
        XCTAssertEqual(insight?.text, "Assigning Getting Started_1.tns to Manuals")
    }

    func testKnownFileWithoutFolderMentionFallsBackToAnalyzingInsight() async {
        let extractor = AIInsightExtractor()
        let content = """
        Inspecting file Getting Started_1.tns to decide where it belongs.
        """
        let lookup = ["getting started_1.tns": ["/tmp/Getting Started_1.tns"]]

        let insight = await extractor.extractInsight(
            from: content,
            scannedFilePathLookup: lookup,
            currentDirectoryPath: "/tmp"
        )

        XCTAssertEqual(insight?.category, .file)
        XCTAssertEqual(insight?.filePath, "/tmp/Getting Started_1.tns")
        XCTAssertEqual(insight?.text, "Analyzing Getting Started_1.tns")
    }

    func testRejectsNaturalLanguageExtensionPhrases() async {
        let extractor = AIInsightExtractor()
        let content = """
        They are all .jpg files. We have .m4a too.
        """

        let insight = await extractor.extractInsight(
            from: content,
            scannedFilePathLookup: [:],
            currentDirectoryPath: nil
        )

        XCTAssertNil(insight)
    }

    func testSkipsGenericFolderNameAssignments() async {
        let extractor = AIInsightExtractor()
        let content = """
        {"folders":[{"name":"name","files":[{"filename":"assets2.m4a"}]}]}
        """
        let lookup = ["assets2.m4a": ["/tmp/assets2.m4a"]]

        let insight = await extractor.extractInsight(
            from: content,
            scannedFilePathLookup: lookup,
            currentDirectoryPath: "/tmp"
        )

        XCTAssertFalse(insight?.text.contains("to name") ?? false)
    }

    func testLearningToolCallNeverAppearsAsStreamingFolder() async {
        let extractor = AIInsightExtractor()
        let content = """
        {"learning_action":{"name":"exclude_current_run_from_learning","reason":"The user requested this run not be learned from"
        """

        let insight = await extractor.extractInsight(
            from: content,
            scannedFilePathLookup: [:],
            currentDirectoryPath: nil
        )

        XCTAssertNotEqual(insight?.category, .folder)
        XCTAssertFalse(insight?.text.contains(LearningToolCall.excludeCurrentRunToolName) ?? false)
    }
}
