import XCTest
@testable import SortyOrganizer
@testable import SortyModels

/// Cross-batch coherence goldens: near-duplicate top-level folders from
/// disjoint batches merge into one before validation, and quarantined
/// subsets round-trip through the targeted retry helpers without drops.
final class BatchMergeTests: XCTestCase {
    private func file(_ name: String) -> FileItem {
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        return FileItem(
            path: url.path,
            name: url.deletingPathExtension().lastPathComponent,
            extension: url.pathExtension
        )
    }

    private func folder(_ name: String, files: [FileItem]) -> FolderSuggestion {
        FolderSuggestion(folderName: name, files: files, reasoning: "Shared test category")
    }

    // MARK: - Near-duplicate top-level merge

    /// Invoice/Invoices/INV0ICES collapse into one folder; every file
    /// survives and the merge is noted in plan notes.
    func testInvoiceVariantsMergeIntoOneFolder() {
        let plan = OrganizationPlan(suggestions: [
            folder("Invoice", files: [file("acme-may.pdf")]),
            folder("Invoices", files: [file("acme-june.pdf"), file("globex-may.pdf")]),
            folder("INV0ICES", files: [file("globex-june.pdf")]),
        ])

        let merged = FolderOrganizer.mergingNearDuplicateTopLevelFolders(in: plan)

        XCTAssertEqual(merged.suggestions.count, 1)
        XCTAssertEqual(merged.totalFiles, plan.totalFiles)
        XCTAssertEqual(
            Set(merged.suggestions[0].files.map(\.displayName)),
            Set(["acme-may.pdf", "acme-june.pdf", "globex-may.pdf", "globex-june.pdf"])
        )
        XCTAssertTrue(merged.notes.contains("Merged near-duplicate folders"))
        XCTAssertTrue(merged.notes.contains("Invoice"))
    }

    /// Case-fold equality merges without any edit-distance help.
    func testCaseFoldMergesExactNames() {
        XCTAssertTrue(FolderOrganizer.nearDuplicateFolderNames("CLOUD INVOICES", "Cloud Invoices"))

        let plan = OrganizationPlan(suggestions: [
            folder("CLOUD INVOICES", files: [file("a.pdf")]),
            folder("Cloud Invoices", files: [file("b.pdf")]),
        ])

        let merged = FolderOrganizer.mergingNearDuplicateTopLevelFolders(in: plan)

        XCTAssertEqual(merged.suggestions.count, 1)
        XCTAssertEqual(merged.totalFiles, 2)
    }

    /// Distinct destinations survive the merge untouched.
    func testDistinctNamesArePreserved() {
        let plan = OrganizationPlan(suggestions: [
            folder("Reports", files: [file("q1.pdf")]),
            folder("Photos", files: [file("picnic.jpg")]),
        ])

        let merged = FolderOrganizer.mergingNearDuplicateTopLevelFolders(in: plan)

        XCTAssertEqual(merged.suggestions.count, 2)
        XCTAssertEqual(merged.suggestions.map(\.folderName), ["Reports", "Photos"])
        XCTAssertTrue(merged.notes.isEmpty)
    }

    /// Canonical choice is deterministic: most files wins; ties break by
    /// smallest normalized key.
    func testCanonicalChoiceIsDeterministic() {
        let plan = OrganizationPlan(suggestions: [
            folder("Invoice", files: [file("a.pdf")]),
            folder("Invoices", files: [file("b.pdf"), file("c.pdf")]),
        ])

        let merged = FolderOrganizer.mergingNearDuplicateTopLevelFolders(in: plan)

        XCTAssertEqual(merged.suggestions.count, 1)
        XCTAssertEqual(merged.suggestions[0].folderName, "Invoices")
        XCTAssertEqual(merged.totalFiles, 3)
    }

    /// Only top-level folders merge: same-named subfolders under different
    /// parents keep their boundaries.
    func testNestedDuplicatesKeepBoundaries() {
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "Projects",
                files: [],
                subfolders: [folder("Docs", files: [file("a.pdf")])],
                reasoning: "Shared project container"
            ),
            FolderSuggestion(
                folderName: "Archive",
                files: [],
                subfolders: [folder("Docs", files: [file("b.pdf")])],
                reasoning: "Archived container"
            ),
        ])

        let merged = FolderOrganizer.mergingNearDuplicateTopLevelFolders(in: plan)

        XCTAssertEqual(merged.suggestions.count, 2)
        XCTAssertEqual(merged.totalFiles, 2)
    }

    /// Single-folder and empty plans pass through unchanged.
    func testSingleFolderPlanPassesThrough() {
        let single = OrganizationPlan(suggestions: [folder("Invoices", files: [file("a.pdf")])])
        XCTAssertEqual(
            FolderOrganizer.mergingNearDuplicateTopLevelFolders(in: single).suggestions.count,
            1
        )
        XCTAssertTrue(
            FolderOrganizer.mergingNearDuplicateTopLevelFolders(in: OrganizationPlan()).suggestions.isEmpty
        )
    }

    // MARK: - Targeted quarantined-subset retry helpers

    /// Only files stamped with the quarantine marker become retry
    /// candidates; pre-existing unorganized files stay out.
    func testQuarantinedRetryCandidatesSelectsOnlyMarkedFiles() {
        let quarantined = file("vague-scan.pdf")
        let preexisting = file("already-loose.txt")
        let plan = OrganizationPlan(
            suggestions: [folder("Invoices", files: [file("acme-may.pdf")])],
            unorganizedFiles: [quarantined, preexisting],
            unorganizedDetails: [
                UnorganizedFile(
                    filename: quarantined.displayName,
                    reason: "Sorty could not place this file confidently after checking the folder structure twice."
                ),
                UnorganizedFile(
                    filename: preexisting.displayName,
                    reason: "Unmapped: AI response did not assign this file; kept unorganized for review."
                ),
            ]
        )

        let candidates = FolderOrganizer.quarantinedRetryCandidates(in: plan)

        XCTAssertEqual(candidates.map(\.id), [quarantined.id])
    }

    /// The targeted prompt embeds full per-file evidence with no compaction.
    func testTargetedRetryInstructionsEmbedFullMetadata() {
        let candidate = file("vague-scan.pdf")
        let instructions = FolderOrganizer.targetedRetryInstructions(
            base: "Base instructions.",
            files: [candidate]
        )

        XCTAssertTrue(instructions.hasPrefix("Base instructions."))
        XCTAssertTrue(instructions.contains("QUARANTINED FILES ONLY"))
        XCTAssertTrue(instructions.contains("vague-scan.pdf"))
        XCTAssertTrue(instructions.contains("pdf"))
    }

    /// Merging a targeted retry back rescues placed candidates, keeps the
    /// rest quarantined, and never drops files.
    func testMergingTargetedRetryRescuesPlacedCandidates() {
        let rescued = file("rescued.pdf")
        let stranded = file("stranded.pdf")
        let quarantined = OrganizationPlan(
            suggestions: [],
            unorganizedFiles: [rescued, stranded],
            unorganizedDetails: [
                UnorganizedFile(filename: rescued.displayName, reason: "Sorty could not place this file confidently."),
                UnorganizedFile(filename: stranded.displayName, reason: "Sorty could not place this file confidently."),
            ]
        )
        let retry = OrganizationPlan(suggestions: [
            folder("Receipts", files: [rescued]),
        ])

        let merged = FolderOrganizer.mergingTargetedRetry(
            retry,
            into: quarantined,
            candidates: [rescued, stranded]
        )

        XCTAssertEqual(merged.suggestions.map(\.folderName), ["Receipts"])
        XCTAssertEqual(merged.unorganizedFiles.map(\.id), [stranded.id])
        XCTAssertEqual(merged.totalFiles, 2)
        XCTAssertTrue(merged.notes.contains("Targeted retry placed 1 of 2"))
    }

    /// A retry that places nothing leaves the quarantine untouched.
    func testMergingEmptyRetryKeepsQuarantine() {
        let stranded = file("stranded.pdf")
        let quarantined = OrganizationPlan(
            suggestions: [],
            unorganizedFiles: [stranded],
            unorganizedDetails: [
                UnorganizedFile(filename: stranded.displayName, reason: "Sorty could not place this file confidently."),
            ]
        )

        let merged = FolderOrganizer.mergingTargetedRetry(
            OrganizationPlan(),
            into: quarantined,
            candidates: [stranded]
        )

        XCTAssertTrue(merged.suggestions.isEmpty)
        XCTAssertEqual(merged.unorganizedFiles.map(\.id), [stranded.id])
    }
}
