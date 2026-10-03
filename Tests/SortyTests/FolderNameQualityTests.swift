import Foundation
import XCTest
@testable import SortyOrganizer
import SortyModels

/// Quality-gate tests for folder-name validation: expanded vague tokens,
/// depth-scaled mixed-type detection, small-batch unorganized thresholds,
/// and folder-component sanitization flags.
final class FolderNameQualityTests: XCTestCase {
    func testProjectShapeWarningsDoNotRejectCoherentPlacements() {
        let projectFiles = [file("proposal.pdf"), file("budget.xlsx"), file("mockup.png"), file("demo.mov")]
        let invoices = (1...60).map { file("invoice-\($0).pdf") }
        let plan = OrganizationPlan(suggestions: [
            folder("Client Proposal", files: projectFiles),
            folder("Invoices", files: invoices),
            folder("New Research Project", files: [file("research.pdf")]),
        ])
        let assessment = PlanQualityEvaluator.assess(plan, existingFolderPaths: [])
        XCTAssertEqual(assessment.score, 100)
        XCTAssertTrue(assessment.uncertainFileIDs.isEmpty)
        XCTAssertTrue(PlanQualityEvaluator.retryInstructions(for: assessment).isEmpty)
    }

    func testFlagsExpandedVagueTokensCaseInsensitively() {
        // Each name is assessed alone so duplicate-name detection cannot
        // contaminate the result ("sorted" vs "unsorted" are near-duplicates).
        let names = [
            "Things", "SORTED", "organized", "Unsorted",
            "Folder", "New Folder", "misc-files", "archive-dump",
        ]
        for name in names {
            let plan = OrganizationPlan(suggestions: [
                folder(name, files: [file("a.pdf"), file("b.pdf")]),
            ])

            let assessment = PlanQualityEvaluator.assess(plan, existingFolderPaths: [])

            XCTAssertEqual(assessment.issues.count, 1, "Expected only a vague-name issue for \(name)")
            XCTAssertEqual(assessment.issues.first?.kind, .vagueOrSingleFileFolder)
            XCTAssertEqual(assessment.issues.first?.folderPaths, [name])
        }
    }

    func testDocumentsAndDataAreOnlyVagueWhenNested() {
        let topLevel = OrganizationPlan(suggestions: [
            folder("Documents", files: [file("a.pdf"), file("b.pdf"), file("c.pdf")]),
            folder("Data", files: [file("a.csv"), file("b.csv"), file("c.csv")]),
        ])

        let topAssessment = PlanQualityEvaluator.assess(topLevel, existingFolderPaths: [])

        XCTAssertTrue(topAssessment.issues.isEmpty, "Top-level Documents/Data mirror a legitimate location")
        XCTAssertTrue(topAssessment.passes)

        let nested = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "Projects",
                files: [],
                subfolders: [
                    folder("Documents", files: [file("a.pdf"), file("b.pdf"), file("c.pdf")]),
                    folder("Invoices", files: [file("d.pdf"), file("e.pdf"), file("f.pdf")]),
                ],
                reasoning: "Shared project container"
            ),
        ])

        let nestedAssessment = PlanQualityEvaluator.assess(nested, existingFolderPaths: [])
        let vaguePaths = Set(nestedAssessment.issues
            .filter { $0.kind == .vagueOrSingleFileFolder }
            .flatMap(\.folderPaths))

        XCTAssertEqual(vaguePaths, ["Projects/Documents"])
    }

    func testTopLevelFilesIsStillVague() {
        let plan = OrganizationPlan(suggestions: [
            folder("Files", files: [file("a.pdf"), file("b.pdf"), file("c.pdf")]),
        ])

        let assessment = PlanQualityEvaluator.assess(plan, existingFolderPaths: [])

        XCTAssertTrue(assessment.issues.contains { $0.kind == .vagueOrSingleFileFolder })
    }

    func testMixedTypesFlaggedAtAllDepthsWithScaledThreshold() {
        let mixedFour = [file("a.pdf"), file("b.jpg"), file("c.mov"), file("d.csv")]
        let mixedFive = mixedFour + [file("e.txt")]
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "Projects",
                files: [],
                subfolders: [
                    folder("MediaMix", files: mixedFive),
                    folder("SmallMix", files: mixedFour),
                ],
                reasoning: "Shared project container"
            ),
            folder("TopMix", files: mixedFour),
        ])

        let assessment = PlanQualityEvaluator.assess(plan, existingFolderPaths: [])
        let mixedPaths = Set(assessment.issues
            .filter { $0.kind == .mixedFileTypes }
            .flatMap(\.folderPaths))

        // Depth 1 fires at 4 files; nested folders need 5; the "Projects"
        // container itself is exempt because its subfolders separate purposes.
        XCTAssertEqual(mixedPaths, ["Projects/MediaMix", "TopMix"])
    }

    func testSmallBatchUnorganizedThreshold() {
        // 5 assigned + 3 unorganized = 8 total: count >= 3 flags it.
        var plan = OrganizationPlan(
            suggestions: [folder("Invoices", files: (1...5).map { file("assigned-\($0).txt") })],
            unorganizedFiles: (1...3).map { file("loose-\($0).txt") }
        )
        XCTAssertTrue(PlanQualityEvaluator.assess(plan, existingFolderPaths: []).issues
            .contains { $0.kind == .excessiveUnorganizedFiles })

        // 6 assigned + 2 unorganized = 8 total: below count and ratio bars.
        plan = OrganizationPlan(
            suggestions: [folder("Invoices", files: (1...6).map { file("assigned-\($0).txt") })],
            unorganizedFiles: (1...2).map { file("loose-\($0).txt") }
        )
        let quiet = PlanQualityEvaluator.assess(plan, existingFolderPaths: [])
        XCTAssertFalse(quiet.issues.contains { $0.kind == .excessiveUnorganizedFiles })
        XCTAssertTrue(quiet.passes)

        // 4 assigned + 2 unorganized = 6 total: 33% ratio flags it.
        plan = OrganizationPlan(
            suggestions: [folder("Invoices", files: (1...4).map { file("assigned-\($0).txt") })],
            unorganizedFiles: (1...2).map { file("loose-\($0).txt") }
        )
        XCTAssertTrue(PlanQualityEvaluator.assess(plan, existingFolderPaths: []).issues
            .contains { $0.kind == .excessiveUnorganizedFiles })
    }

    func testInvalidFolderNamesAreFlaggedForRetry() {
        let badNames = [
            " spaced ",
            "trailing.",
            ".hidden",
            "bad:name",
            "a//b",
            ".",
            "..",
            "",
            "   ",
            "with\ttab",
            String(repeating: "x", count: 300),
        ]
        for name in badNames {
            let plan = OrganizationPlan(suggestions: [
                folder(name, files: [file("a.pdf"), file("b.pdf")]),
            ])

            let assessment = PlanQualityEvaluator.assess(plan, existingFolderPaths: [])

            XCTAssertEqual(
                assessment.issues.filter { $0.kind == .invalidFolderName }.count, 1,
                "Expected exactly one invalid-name issue for \(name.debugDescription)"
            )
            XCTAssertTrue(
                PlanQualityEvaluator.retryInstructions(for: assessment).contains("unusable name"),
                "Retry instructions should explain the unusable name \(name.debugDescription)"
            )
        }

        let good = OrganizationPlan(suggestions: [
            folder("Invoices-2026", files: [file("a.pdf"), file("b.pdf")]),
        ])
        let goodAssessment = PlanQualityEvaluator.assess(good, existingFolderPaths: [])
        XCTAssertFalse(goodAssessment.issues.contains { $0.kind == .invalidFolderName })
        XCTAssertTrue(goodAssessment.passes)
    }

    func testFolderComponentValidationHelper() {
        XCTAssertTrue(FilenameNormalizer.invalidFolderNameComponents(in: "Invoices").isEmpty)
        XCTAssertTrue(FilenameNormalizer.invalidFolderNameComponents(in: "/Absolute/Path").isEmpty)
        XCTAssertTrue(FilenameNormalizer.invalidFolderNameComponents(in: "Docs/").isEmpty)

        XCTAssertEqual(FilenameNormalizer.invalidFolderNameComponents(in: "a//b").count, 1)
        XCTAssertEqual(FilenameNormalizer.invalidFolderNameComponents(in: ".").count, 1)
        XCTAssertEqual(FilenameNormalizer.invalidFolderNameComponents(in: "..").count, 1)

        // Per-component whitespace is reported per offending component.
        let spaced = FilenameNormalizer.invalidFolderNameComponents(in: "ok / spaced ")
        XCTAssertEqual(spaced.count, 2)

        XCTAssertFalse(FilenameNormalizer.invalidFolderNameComponents(in: "a:b").isEmpty)
    }

    // MARK: - Helpers

    private func folder(_ name: String, files: [FileItem]) -> FolderSuggestion {
        FolderSuggestion(folderName: name, files: files, reasoning: "Shared test category")
    }

    private func file(_ name: String) -> FileItem {
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        return FileItem(
            path: url.path,
            name: url.deletingPathExtension().lastPathComponent,
            extension: url.pathExtension
        )
    }
}
