import XCTest
@testable import SortyCore

final class BugReportLogScrubTests: XCTestCase {
    func testScrubRemovesQuotedNamesAndBareFileNames() {
        let scrubbed = LogManager.scrubForReport(
            "Move failed: The file “Tax Return 2025.pdf” couldn’t be saved in “Finance”. Retried budget.xlsx (code 516)"
        )
        XCTAssertFalse(scrubbed.contains("Tax Return"))
        XCTAssertFalse(scrubbed.contains("Finance"))
        XCTAssertFalse(scrubbed.contains("budget"))
        XCTAssertTrue(scrubbed.contains("code 516"))
    }

    func testScrubKeepsIdentifierContextAndDropsFreeText() {
        let scrubbed = LogManager.scrubForReport(
            #"Request failed | Context: {"provider":"openai","status":429,"file":"notes.txt","detail":"Folder Taxes"}"#
        )
        XCTAssertTrue(scrubbed.contains(#""provider":"openai""#))
        XCTAssertTrue(scrubbed.contains(#""status":429"#))
        XCTAssertFalse(scrubbed.contains("notes"))
        XCTAssertFalse(scrubbed.contains("Taxes"))
    }

    func testRecentIssuesKeepsOnlyRecentWarningsAndAbove() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let recent = formatter.string(from: now.addingTimeInterval(-60))
        let old = formatter.string(from: now.addingTimeInterval(-3_600))
        try """
        [\(old)] [ERROR] [Organizer] old failure
        [\(recent)] [INFO] [Organizer] routine step
        [\(recent)] [ERROR] [Organizer] HTTP 429 from provider
        """.write(to: directory.appendingPathComponent("sorty.log"), atomically: true, encoding: .utf8)

        let excerpt = LogManager.recentIssues(in: directory, now: now)
        XCTAssertTrue(excerpt.contains("HTTP 429 from provider"))
        XCTAssertFalse(excerpt.contains("old failure"))
        XCTAssertFalse(excerpt.contains("routine step"))
    }
}
