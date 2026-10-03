import Combine
import XCTest
@testable import SortyLib
@testable import SortyCore
@testable import SortyOrganizer

/// Preview edits re-score plan quality off-main (never a full AI organize),
/// and same-folder filename collisions surface inline uniquified suggestions.
@MainActor
final class PreviewStoreRescoreTests: XCTestCase {
    private func makeFile(_ name: String, ext: String = "txt", folder: String = "/tmp") -> FileItem {
        FileItem(
            path: "\(folder)/\(name).\(ext)",
            name: name,
            extension: ext,
            size: 100,
            isDirectory: false
        )
    }

    /// Polls until the debounced off-main re-score lands (or times out).
    private func waitForAssessment(
        in store: PreviewStore,
        timeout: TimeInterval = 8
    ) async -> PlanQualityAssessment? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let assessment = store.plan.qualityAssessment {
                return assessment
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return store.plan.qualityAssessment
    }

    func testMoveToUnorganizedTriggersQualityRescore() async {
        let files = (1...4).map { makeFile("doc-\($0)", ext: "pdf") }
        let folder = FolderSuggestion(
            folderName: "Documents",
            files: files,
            reasoning: "Shared project documents"
        )
        let store = PreviewStore(plan: OrganizationPlan(suggestions: [folder]))
        XCTAssertNil(store.plan.qualityAssessment)
        store.setExistingFolderPaths([])

        store.moveFileToUnorganized(fileID: files[0].id)

        let assessment = await waitForAssessment(in: store)
        XCTAssertNotNil(assessment, "a preview edit must re-score plan quality")
        let expected = PlanQualityEvaluator.assess(store.plan, existingFolderPaths: [])
        XCTAssertEqual(assessment?.score, expected.score)
        XCTAssertEqual(assessment?.issues.map(\.kind), expected.issues.map(\.kind))
    }

    func testDragDropMoveTriggersQualityRescore() async {
        let file = makeFile("photo", ext: "jpg")
        let inbox = FolderSuggestion(folderName: "Inbox", files: [file], reasoning: "Incoming scans")
        let photos = FolderSuggestion(folderName: "Photos", reasoning: "Image library")
        let store = PreviewStore(plan: OrganizationPlan(suggestions: [inbox, photos]))
        XCTAssertNil(store.plan.qualityAssessment)
        store.setExistingFolderPaths([])

        store.moveFile(fileID: file.id, toFolderID: photos.id)

        let assessment = await waitForAssessment(in: store)
        XCTAssertNotNil(assessment, "drag-drop between folders must re-score plan quality")
        XCTAssertEqual(
            assessment?.score,
            PlanQualityEvaluator.assess(store.plan, existingFolderPaths: []).score
        )
    }

    func testRenameEditTriggersQualityRescore() async {
        let file = makeFile("scan001", ext: "pdf")
        let folder = FolderSuggestion(folderName: "Documents", files: [file], reasoning: "Shared documents")
        let store = PreviewStore(plan: OrganizationPlan(suggestions: [folder]))
        XCTAssertNil(store.plan.qualityAssessment)
        store.setExistingFolderPaths([])

        store.updateRename(fileID: file.id, folderID: folder.id, newName: "2026-01-01 Statement.pdf")

        let assessment = await waitForAssessment(in: store)
        XCTAssertNotNil(assessment, "a rename edit must re-score plan quality")
    }

    func testStaleRescoreNeverOverwritesNewerEdit() async {
        let fileA = makeFile("a")
        let fileB = makeFile("b")
        let folder = FolderSuggestion(folderName: "Documents", files: [fileA, fileB], reasoning: "Shared docs")
        let store = PreviewStore(plan: OrganizationPlan(suggestions: [folder]))
        store.setExistingFolderPaths([])

        // Two rapid edits: the first re-score must not clobber the second.
        store.moveFileToUnorganized(fileID: fileA.id)
        store.moveFileToUnorganized(fileID: fileB.id)

        let assessment = await waitForAssessment(in: store)
        XCTAssertNotNil(assessment)
        XCTAssertEqual(store.plan.unorganizedFiles.count, 2)
        XCTAssertEqual(
            assessment?.score,
            PlanQualityEvaluator.assess(store.plan, existingFolderPaths: []).score
        )
    }
}

@MainActor
final class PreviewStoreCollisionTests: XCTestCase {
    private func makeFile(_ name: String, ext: String = "txt", folder: String = "/tmp") -> FileItem {
        FileItem(
            path: "\(folder)/\(name).\(ext)",
            name: name,
            extension: ext,
            size: 100,
            isDirectory: false
        )
    }

    func testTwoWayCollisionSuggestsUniquifiedName() {
        let lower = makeFile("invoice", ext: "pdf", folder: "/tmp/a")
        let upper = makeFile("INVOICE", ext: "pdf", folder: "/tmp/b")
        let folder = FolderSuggestion(folderName: "Docs", files: [lower, upper])
        let store = PreviewStore(plan: OrganizationPlan(suggestions: [folder]))

        XCTAssertEqual(store.collisionGroups.count, 1)
        let group = store.collisionGroups[0]
        XCTAssertEqual(group.files.count, 2)
        XCTAssertFalse(group.isBlocking, "two-way collisions auto-rename and never block Apply")
        XCTAssertFalse(store.hasBlockingCollisions)

        // Case-insensitive match: the head keeps the name, the other file gets
        // an extension-preserving uniquified suggestion.
        XCTAssertEqual(group.suggestedNames.count, 1)
        let suggested = group.suggestedNames[upper.id] ?? group.suggestedNames[lower.id]
        XCTAssertNotNil(suggested)
        XCTAssertTrue(suggested?.hasSuffix(".pdf") == true)
        XCTAssertTrue(suggested?.contains("_1") == true)
        XCTAssertEqual(store.collisionSuggestions.count, 1)
    }

    func testUniquifiedSuggestionSkipsTakenNames() {
        var taken: Set<String> = ["report.pdf", "report_1.pdf"]
        let suggestion = PreviewPlanInsights.uniquifiedName(for: "report.pdf", takenLowercased: &taken)
        XCTAssertEqual(suggestion, "report_2.pdf")
        XCTAssertTrue(taken.contains("report_2.pdf"))
    }

    func testAcceptCollisionSuggestionResolvesGroup() {
        let fileA = makeFile("note", ext: "txt", folder: "/tmp/a")
        let fileB = makeFile("note", ext: "txt", folder: "/tmp/b")
        let folder = FolderSuggestion(folderName: "Notes", files: [fileA, fileB])
        let store = PreviewStore(plan: OrganizationPlan(suggestions: [folder]))
        XCTAssertEqual(store.collisionGroups.count, 1)

        let suggestion = store.collisionSuggestions[fileB.id] ?? store.collisionSuggestions[fileA.id]
        XCTAssertNotNil(suggestion)
        let targetID = store.collisionSuggestions[fileB.id] != nil ? fileB.id : fileA.id

        let applied = store.acceptCollisionSuggestion(fileID: targetID)
        XCTAssertEqual(applied, suggestion)
        XCTAssertTrue(store.collisionGroups.isEmpty, "accepting the suggestion must clear the collision")
        let mapping = store.plan.suggestions[0].renameMapping(
            for: targetID == fileA.id ? fileA : fileB
        )
        XCTAssertEqual(mapping?.suggestedName, suggestion)
        XCTAssertTrue(mapping?.shouldApplyRename == true)
    }

    func testThreeWayCollisionBlocksApplyAndSurfacesNames() {
        let files = (1...3).map { makeFile("shared", ext: "txt", folder: "/tmp/\($0)") }
        let folder = FolderSuggestion(folderName: "Docs", files: files)
        let store = PreviewStore(plan: OrganizationPlan(suggestions: [folder]))

        XCTAssertEqual(store.collisionGroups.count, 1)
        XCTAssertTrue(store.collisionGroups[0].isBlocking)
        XCTAssertTrue(store.hasBlockingCollisions)
        XCTAssertEqual(store.collisionGroups[0].suggestedNames.count, 2)

        let lines = PreviewPlanInsights.collisionConfirmationLines(groups: store.collisionGroups)
        XCTAssertFalse(lines.isEmpty, "3-way collisions must surface in the apply confirmation")
        XCTAssertTrue(lines.joined(separator: " ").contains("shared.txt"))
        XCTAssertTrue(lines.joined(separator: " ").contains("_1"))
    }

    func testTwoWayCollisionSurfacesAutoRenameLine() {
        let fileA = makeFile("note", ext: "txt", folder: "/tmp/a")
        let fileB = makeFile("note", ext: "txt", folder: "/tmp/b")
        let folder = FolderSuggestion(folderName: "Notes", files: [fileA, fileB])
        let store = PreviewStore(plan: OrganizationPlan(suggestions: [folder]))

        XCTAssertFalse(store.hasBlockingCollisions)
        let lines = PreviewPlanInsights.collisionConfirmationLines(groups: store.collisionGroups)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("auto-rename on apply"))
    }

    func testAcceptAllClearsBlockingCollision() {
        let files = (1...3).map { makeFile("shared", ext: "txt", folder: "/tmp/\($0)") }
        let folder = FolderSuggestion(folderName: "Docs", files: files)
        let store = PreviewStore(plan: OrganizationPlan(suggestions: [folder]))
        XCTAssertTrue(store.hasBlockingCollisions)

        store.acceptAllCollisionSuggestions()

        XCTAssertTrue(store.collisionGroups.isEmpty)
        XCTAssertFalse(store.hasBlockingCollisions)
        let finals = store.plan.suggestions[0].filesWithFinalNames.map(\.finalName)
        XCTAssertEqual(Set(finals.map { $0.lowercased() }).count, 3, "every file must land on a distinct name")
    }
}
