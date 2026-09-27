import XCTest
@testable import SortyLib
@testable import SortyCore

final class FileLearningsAttributionResolverTests: XCTestCase {
    func testResolveReturnsEmptyWhenSuggestionHasNoRuleAttribution() {
        let file = FileItem(path: "/tmp/report.pdf", name: "report", extension: "pdf", size: 1024)
        let suggestion = FolderSuggestion(folderName: "Reports", files: [file])

        let result = FileLearningsAttributionResolver.resolve(file: file, suggestion: suggestion, profile: LearningsProfile())

        XCTAssertFalse(result.hasContent)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertNil(result.scope)
    }

    func testResolveUsesDirectRuleIDAndEvidence() {
        let file = FileItem(path: "/tmp/report.pdf", name: "report", extension: "pdf", size: 1024)
        let suggestion = FolderSuggestion(folderName: "Reports", files: [file], ruleId: "rule-1")

        let rule = InferredRule(
            id: "rule-1",
            pattern: ".*\\.pdf$",
            template: "Reports/{filename}",
            priority: 80,
            explanation: "PDF files should go in Reports",
            supportCount: 4,
            evidenceIds: ["User moved similar PDFs"],
            evidenceDescription: "User moved similar PDFs"
        )
        let profile = LearningsProfile(inferredRules: [rule])

        let result = FileLearningsAttributionResolver.resolve(file: file, suggestion: suggestion, profile: profile)

        XCTAssertTrue(result.hasContent)
        XCTAssertEqual(result.scope, .fileRuleMatch)
        XCTAssertEqual(result.items.filter { $0.kind == .learnedRule }.count, 1)
        XCTAssertEqual(result.items.filter { $0.kind == .ruleEvidence }.count, 1)
    }

    func testResolveUsesSemanticTagRuleFallback() {
        let file = FileItem(path: "/tmp/notes.txt", name: "notes", extension: "txt", size: 512)
        let suggestion = FolderSuggestion(folderName: "Notes", files: [file], semanticTags: ["rule:rule-2"])

        let rule = InferredRule(
            id: "rule-2",
            pattern: ".*\\.txt$",
            template: "Notes/{filename}",
            priority: 70,
            explanation: "Text notes should stay in Notes"
        )
        let profile = LearningsProfile(inferredRules: [rule])

        let result = FileLearningsAttributionResolver.resolve(file: file, suggestion: suggestion, profile: profile)

        XCTAssertTrue(result.hasContent)
        XCTAssertEqual(result.scope, .fileRuleMatch)
        XCTAssertEqual(result.items.filter { $0.kind == .learnedRule }.count, 1)
    }

    func testResolveUsesOnlyRuleEvidence() {
        let file = FileItem(path: "/tmp/image.png", name: "image", extension: "png", size: 4096)
        let suggestion = FolderSuggestion(folderName: "Images", files: [file], ruleId: "rule-3")

        let rule = InferredRule(
            id: "rule-3",
            pattern: ".*\\.png$",
            template: "Images/{filename}",
            priority: 60,
            explanation: "PNG files should go in Images",
            evidenceDescription: "User moved screenshots into Images"
        )
        let profile = LearningsProfile(inferredRules: [rule])

        let result = FileLearningsAttributionResolver.resolve(file: file, suggestion: suggestion, profile: profile)

        XCTAssertTrue(result.hasContent)
        XCTAssertEqual(result.items.count, 2)
    }

    func testResolveFallsBackToHeuristicRuleMatchingWhenRuleIDIsMissing() {
        let file = FileItem(path: "/tmp/Invoices/receipt-2026.pdf", name: "receipt-2026", extension: "pdf", size: 2048)
        let suggestion = FolderSuggestion(folderName: "Invoices", files: [file])

        let matchingRule = InferredRule(
            id: "rule-pdf",
            pattern: ".*\\.pdf$",
            template: "Invoices/{filename}",
            priority: 85,
            explanation: "PDF receipts are grouped into Invoices",
            isEnabled: true,
            supportCount: 8,
            status: .active
        )

        let nonMatchingRule = InferredRule(
            id: "rule-images",
            pattern: ".*\\.(png|jpg)$",
            template: "Images/{filename}",
            priority: 90,
            explanation: "Images are grouped into Images",
            isEnabled: true,
            supportCount: 12,
            status: .active
        )

        let profile = LearningsProfile(inferredRules: [nonMatchingRule, matchingRule])

        let result = FileLearningsAttributionResolver.resolve(file: file, suggestion: suggestion, profile: profile)

        XCTAssertTrue(result.hasContent)
        XCTAssertEqual(result.rule?.id, "rule-pdf")
        XCTAssertEqual(result.scope, LearningsAttributionScope.fileRuleMatch)
        XCTAssertEqual(result.items.filter { $0.kind == LearningsAttributionKind.learnedRule }.count, 1)
    }
}
