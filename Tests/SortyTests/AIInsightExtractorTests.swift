import XCTest
@testable import SortyLib
@testable import SortyCore

final class AIInsightExtractorTests: XCTestCase {
    func testDuplicateFilenameDoesNotPickArbitraryThumbnail() async {
        let extractor = AIInsightExtractor()
        let insight = await extractor.extractInsight(
            from: #"{"folders":[{"name":"Receipts","files":["report.pdf"]}]}"#,
            scannedFilePathLookup: ["report.pdf": ["/tmp/one/report.pdf", "/tmp/two/report.pdf"]],
            currentDirectoryPath: "/tmp"
        )

        XCTAssertNil(insight?.filePath)
    }
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

    func testRejectsLowSignalNoiseInputs() async {
        let extractor = AIInsightExtractor()
        let noiseContents = [
            """
            IMPORTANT: The following patterns are STRICTLY EXCLUDED and must NOT be moved, renamed, or modified.
            """,
            """
            Analyzing category (Documents). limit: <=10. Preferred categories: Documents.
            """,
            """
            They are all .jpg files. We have .m4a too.
            """,
        ]

        for content in noiseContents {
            let insight = await extractor.extractInsight(
                from: content,
                scannedFilePathLookup: [:],
                currentDirectoryPath: nil
            )

            XCTAssertNil(insight, "Noise input should not produce an insight: \(content)")
        }

        let controlInsight = await extractor.extractInsight(
            from: """
            {"folders":[{"name":"Receipts","files":["report.pdf"]}]}
            """,
            scannedFilePathLookup: ["report.pdf": ["/tmp/report.pdf"]],
            currentDirectoryPath: "/tmp"
        )

        XCTAssertNotNil(controlInsight, "Positive control must stay non-nil so the test fails if the extractor dies")
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
