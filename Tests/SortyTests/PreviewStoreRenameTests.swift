import Combine
import XCTest
@testable import SortyLib
@testable import SortyCore
@testable import SortyLearnings

@MainActor
final class PreviewStoreRenameTests: XCTestCase {

    private func makeFile(_ name: String, ext: String = "txt", folder: String = "/tmp") -> FileItem {
        FileItem(
            path: "\(folder)/\(name).\(ext)",
            name: name,
            extension: ext,
            size: 100,
            isDirectory: false
        )
    }

    func testUpdateRenameSanitizesAndPersists() {
        let file = makeFile("draft")
        let folder = FolderSuggestion(folderName: "Docs", files: [file])
        let plan = OrganizationPlan(suggestions: [folder], unorganizedFiles: [], notes: "")
        let store = PreviewStore(plan: plan)

        store.updateRename(fileID: file.id, folderID: folder.id, newName: "  final:name.pdf  ")

        let mapping = store.plan.suggestions[0].renameMapping(for: file)
        XCTAssertEqual(mapping?.suggestedName, "final-name.txt")
    }

    func testUpdateRenameAllowsDuplicateTargetFilenames() {
        let fileA = makeFile("a")
        let fileB = makeFile("b")
        var folder = FolderSuggestion(folderName: "Docs", files: [fileA, fileB])
        folder.updateRename(for: fileA, newName: "invoice.txt")
        let plan = OrganizationPlan(suggestions: [folder], unorganizedFiles: [], notes: "")
        let store = PreviewStore(plan: plan)

        store.updateRename(fileID: fileB.id, folderID: folder.id, newName: "invoice.txt")

        let mapping = store.plan.suggestions[0].renameMapping(for: fileB)
        XCTAssertEqual(mapping?.suggestedName, "invoice.txt")
    }

    func testUpdateRenameNoOpDoesNotCreateMapping() {
        let file = makeFile("notes")
        let folder = FolderSuggestion(folderName: "Docs", files: [file])
        let plan = OrganizationPlan(suggestions: [folder], unorganizedFiles: [], notes: "")
        let store = PreviewStore(plan: plan)

        store.updateRename(fileID: file.id, folderID: folder.id, newName: "notes.txt")
        XCTAssertNil(store.plan.suggestions[0].renameMapping(for: file))
    }

    func testRejectRenameClearsSuggestion() {
        let file = makeFile("draft")
        var folder = FolderSuggestion(folderName: "Docs", files: [file])
        folder.updateRename(for: file, newName: "final.txt", reason: "Cleaner")
        let plan = OrganizationPlan(suggestions: [folder], unorganizedFiles: [], notes: "")
        let store = PreviewStore(plan: plan)

        store.rejectRename(fileID: file.id, folderID: folder.id)

        let mapping = store.plan.suggestions[0].renameMapping(for: file)
        XCTAssertNotNil(mapping)
        XCTAssertFalse(mapping?.hasRename ?? true)
        XCTAssertNil(mapping?.suggestedName)
    }

    func testPerFileRejectAndReapplyRenames() {
        let fileA = makeFile("draft_a")
        let fileB = makeFile("draft_b")
        var folder = FolderSuggestion(folderName: "Docs", files: [fileA, fileB])
        folder.updateRename(for: fileA, newName: "final_a.txt", reason: "A")
        folder.updateRename(for: fileB, newName: "final_b.txt", reason: "B")
        let plan = OrganizationPlan(suggestions: [folder], unorganizedFiles: [], notes: "")
        let store = PreviewStore(plan: plan)

        store.rejectRename(fileID: fileA.id, folderID: folder.id)
        store.rejectRename(fileID: fileB.id, folderID: folder.id)
        XCTAssertFalse(store.plan.suggestions[0].renameMapping(for: fileA)?.hasRename ?? true)
        XCTAssertFalse(store.plan.suggestions[0].renameMapping(for: fileB)?.hasRename ?? true)

        store.updateRename(fileID: fileA.id, folderID: folder.id, newName: "final_a.txt")
        store.updateRename(fileID: fileB.id, folderID: folder.id, newName: "final_b.txt")
        XCTAssertEqual(store.plan.suggestions[0].renameMapping(for: fileA)?.suggestedName, "final_a.txt")
        XCTAssertEqual(store.plan.suggestions[0].renameMapping(for: fileB)?.suggestedName, "final_b.txt")
    }

    func testLowConfidenceSkipFlagPropagatesThroughPreviewStore() {
        let file = makeFile("image", ext: "jpg")
        let mapping = FileRenameMapping(
            originalFile: file,
            suggestedName: "Possible Sunset.jpg",
            renameReason: "AI unsure",
            renameConfidence: 0.2
        )
        let folder = FolderSuggestion(folderName: "Photos", files: [file], fileRenameMappings: [mapping])
        let plan = OrganizationPlan(suggestions: [folder], unorganizedFiles: [], notes: "")
        let store = PreviewStore(plan: plan)

        let persistedMapping = store.plan.suggestions[0].renameMapping(for: file)
        XCTAssertTrue(persistedMapping?.isAutoSkippedForLowConfidence ?? false)
        XCTAssertTrue(persistedMapping?.hasRename ?? false)
        XCTAssertEqual(persistedMapping?.finalFilename, file.displayName)
    }

    func testConfidenceBandsControlDefaultSelection() {
        let file = makeFile("invoice", ext: "pdf")
        let low = FileRenameMapping(
            originalFile: file,
            suggestedName: "2026-05 Vendor Invoice.pdf",
            renameReason: "Possible date and vendor",
            renameConfidence: 0.2
        )
        let medium = FileRenameMapping(
            originalFile: file,
            suggestedName: "2026-05 Vendor Invoice.pdf",
            renameReason: "Title contains invoice",
            renameConfidence: 0.6
        )
        let high = FileRenameMapping(
            originalFile: file,
            suggestedName: "2026-05 Vendor Invoice.pdf",
            renameReason: "Title and body match",
            renameConfidence: 0.9
        )

        XCTAssertEqual(low.confidenceBand, .low)
        XCTAssertFalse(low.shouldApplyRename)
        XCTAssertEqual(medium.confidenceBand, .medium)
        XCTAssertFalse(medium.shouldApplyRename)
        XCTAssertEqual(high.confidenceBand, .high)
        XCTAssertTrue(high.shouldApplyRename)
    }

    func testUserCanOptInToMediumConfidenceRename() {
        let file = makeFile("invoice", ext: "pdf")
        let mapping = FileRenameMapping(
            originalFile: file,
            suggestedName: "2026-05 Vendor Invoice.pdf",
            renameReason: "Title contains invoice",
            renameConfidence: 0.6
        )
        let folder = FolderSuggestion(
            folderName: "Invoices",
            files: [file],
            fileRenameMappings: [mapping]
        )
        let store = PreviewStore(plan: OrganizationPlan(suggestions: [folder]))

        store.setRenameSelected(fileID: file.id, folderID: folder.id, isSelected: true)

        let selected = store.plan.suggestions[0].renameMapping(for: file)
        XCTAssertTrue(selected?.shouldApplyRename ?? false)
        XCTAssertEqual(selected?.finalFilename, "2026-05 Vendor Invoice.pdf")
    }

    func testPlacementRejectionWeakensAttributedRuleOnly() async {
        let suiteName = "PreviewStoreRenameTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = LearningsManager(userDefaults: defaults)
        // Seed a profile before consent so rule setup is deterministic
        // (matches LearningsManagerTests pattern; load may no-op in tests).
        manager.currentProfile = LearningsProfile()
        await manager.grantConsent()
        let usedRule = InferredRule(
            id: "footage-rule",
            pattern: ".*\\.mov$",
            template: "Footage/{filename}",
            explanation: "MOV files belong in Footage"
        )
        let unrelatedRule = InferredRule(
            id: "pdf-rule",
            pattern: ".*\\.pdf$",
            template: "Documents/{filename}",
            explanation: "PDF files belong in Documents"
        )
        manager.currentProfile?.inferredRules = [usedRule, unrelatedRule]
        let file = makeFile("clip", ext: "mov")
        let folder = FolderSuggestion(folderName: "Footage", files: [file], ruleId: usedRule.id)
        let store = PreviewStore(plan: OrganizationPlan(suggestions: [folder]))
        store.learningsManager = manager

        store.moveFileToUnorganized(fileID: file.id)

        XCTAssertEqual(manager.currentProfile?.inferredRules.first { $0.id == usedRule.id }?.failureCount, 1)
        XCTAssertEqual(manager.currentProfile?.inferredRules.first { $0.id == unrelatedRule.id }?.failureCount, 0)
    }

    func testLargePlanStartsCollapsedAndBoundsExpandedRows() {
        let files = (0..<3_000).map { index in
            makeFile("file-\(index)")
        }
        let mappings = files.map { file in
            FileRenameMapping(
                originalFile: file,
                suggestedName: "renamed-\(file.displayName)"
            )
        }
        let folder = FolderSuggestion(
            folderName: "Documents",
            files: files,
            fileRenameMappings: mappings
        )
        let store = PreviewStore(plan: OrganizationPlan(suggestions: [folder]))

        XCTAssertEqual(store.flattenedRows.count, 1)
        XCTAssertTrue(store.renameMappings.isEmpty)

        store.toggleFolder(id: folder.id.uuidString)

        XCTAssertEqual(store.flattenedRows.count, 502)
        XCTAssertEqual(store.renameMappings.count, 500)
        guard case .remainingFiles(let count) = store.flattenedRows.last?.type else {
            return XCTFail("Expected a bounded remainder row")
        }
        XCTAssertEqual(count, 2_500)
    }

    func testLargeUnorganizedSectionBoundsRows() {
        let files = (0..<3_000).map { index in
            makeFile("unorganized-\(index)")
        }
        let store = PreviewStore(plan: OrganizationPlan(unorganizedFiles: files))

        XCTAssertEqual(store.flattenedRows.count, 1)

        store.toggleFolder(id: PreviewStore.unorganizedSectionID)

        XCTAssertEqual(store.flattenedRows.count, 502)
        guard case .remainingFiles(let count) = store.flattenedRows.last?.type else {
            return XCTFail("Expected a bounded remainder row")
        }
        XCTAssertEqual(count, 2_500)
    }

    func testFileRowIdentitySurvivesEarlierFileRemoval() {
        let first = makeFile("first")
        let second = makeFile("second")
        let third = makeFile("third")
        let folderID = UUID()
        let planID = UUID()
        let folder = FolderSuggestion(id: folderID, folderName: "Documents", files: [first, second, third])
        let store = PreviewStore(plan: OrganizationPlan(id: planID, suggestions: [folder]))

        let originalSecondID = store.flattenedRows.first { row in
            if case .file(let file, _) = row.type { return file.id == second.id }
            return false
        }?.id

        let updatedFolder = FolderSuggestion(id: folderID, folderName: "Documents", files: [second, third])
        store.updatePlan(OrganizationPlan(id: planID, suggestions: [updatedFolder], version: 2))

        let updatedSecondID = store.flattenedRows.first { row in
            if case .file(let file, _) = row.type { return file.id == second.id }
            return false
        }?.id
        XCTAssertEqual(originalSecondID, updatedSecondID)
    }

    func testUnorganizedRowIdentitySurvivesEarlierFileRemoval() {
        let first = makeFile("first")
        let second = makeFile("second")
        let third = makeFile("third")
        let planID = UUID()
        let store = PreviewStore(plan: OrganizationPlan(id: planID, unorganizedFiles: [first, second, third]))

        let originalSecondID = store.flattenedRows.first { row in
            if case .unorganizedFile(let file) = row.type { return file.id == second.id }
            return false
        }?.id

        store.updatePlan(OrganizationPlan(id: planID, unorganizedFiles: [second, third], version: 2))

        let updatedSecondID = store.flattenedRows.first { row in
            if case .unorganizedFile(let file) = row.type { return file.id == second.id }
            return false
        }?.id
        XCTAssertEqual(originalSecondID, updatedSecondID)
    }

    func testMoveDestinationsRefreshWhenPlanRevisionChanges() {
        let planID = UUID()
        let firstFolder = FolderSuggestion(folderName: "Documents")
        let store = PreviewStore(plan: OrganizationPlan(id: planID, suggestions: [firstFolder]))

        XCTAssertEqual(store.moveDestinations.map(\.name), ["Documents"])

        let child = FolderSuggestion(folderName: "Invoices")
        let revisedFolder = FolderSuggestion(
            id: firstFolder.id,
            folderName: "Documents",
            subfolders: [child]
        )
        store.updatePlan(OrganizationPlan(id: planID, suggestions: [revisedFolder], version: 2))

        XCTAssertEqual(store.moveDestinations.map(\.name), ["Documents", "Documents/Invoices"])
    }

    func testExactPlanUpdateDoesNotPublishOrRebuildRows() {
        let folder = FolderSuggestion(folderName: "Documents")
        let plan = OrganizationPlan(suggestions: [folder])
        let store = PreviewStore(plan: plan)
        let originalRows = store.flattenedRows
        var publicationCount = 0
        let observation = store.objectWillChange.sink {
            publicationCount += 1
        }

        store.updatePlan(plan)

        XCTAssertEqual(store.flattenedRows, originalRows)
        XCTAssertEqual(publicationCount, 0)
        withExtendedLifetime(observation) {}
    }
}
