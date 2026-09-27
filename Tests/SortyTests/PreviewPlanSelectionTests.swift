import XCTest
@testable import SortyLib
@testable import SortyCore

final class PreviewPlanSelectionTests: XCTestCase {
    @MainActor
    func testHistoricalVersionIsThePlanSelectedForApply() {
        let current = OrganizationPlan(suggestions: [], unorganizedFiles: [], notes: "current")
        let historical = OrganizationPlan(suggestions: [], unorganizedFiles: [], notes: "historical")

        let selected = PreviewView.planForApply(
            editablePlan: current,
            history: [historical],
            viewingHistoryIndex: 0
        )

        XCTAssertEqual(selected.notes, "historical")
    }

    @MainActor
    func testCurrentEditableVersionIsSelectedWhenHistoryIsNotVisible() {
        let current = OrganizationPlan(suggestions: [], unorganizedFiles: [], notes: "current")
        let historical = OrganizationPlan(suggestions: [], unorganizedFiles: [], notes: "historical")

        let selected = PreviewView.planForApply(
            editablePlan: current,
            history: [historical],
            viewingHistoryIndex: nil
        )

        XCTAssertEqual(selected.notes, "current")
    }

    func testPlanDiffReportsMoveRenameAndTagChanges() {
        let file = FileItem(path: "/tmp/report.pdf", name: "report", extension: "pdf")
        let oldFolder = FolderSuggestion(folderName: "Inbox", files: [file])
        let newFolder = FolderSuggestion(
            folderName: "Reports",
            files: [file],
            fileRenameMappings: [
                FileRenameMapping(originalFile: file, suggestedName: "annual-report.pdf", isSelected: true)
            ],
            fileTagMappings: [
                FileTagMapping(originalFile: file, tags: ["Work"])
            ]
        )

        let diff = OrganizationPlanDiff(
            from: OrganizationPlan(suggestions: [oldFolder]),
            to: OrganizationPlan(suggestions: [newFolder]),
            fromLabel: "Preview 1",
            toLabel: "Preview 2"
        )

        XCTAssertEqual(Set(diff.changes.map(\.kind)), [.moved, .renamed, .tags])
        XCTAssertEqual(diff.changes(for: .moved).first?.before, "Inbox")
        XCTAssertEqual(diff.changes(for: .moved).first?.after, "Reports")
        XCTAssertEqual(diff.changes(for: .renamed).first?.after, "annual-report.pdf")
    }

    func testPlanDiffReportsOrganizedAndUnorganizedFiles() {
        let file = FileItem(path: "/tmp/photo.jpg", name: "photo", extension: "jpg")
        let oldPlan = OrganizationPlan(unorganizedFiles: [file])
        let newPlan = OrganizationPlan(suggestions: [FolderSuggestion(folderName: "Photos", files: [file])])

        let organized = OrganizationPlanDiff(
            from: oldPlan,
            to: newPlan,
            fromLabel: "Preview 1",
            toLabel: "Preview 2"
        )
        let unorganized = OrganizationPlanDiff(
            from: newPlan,
            to: oldPlan,
            fromLabel: "Preview 2",
            toLabel: "Edited"
        )

        XCTAssertEqual(organized.changes.map(\.kind), [.organized])
        XCTAssertEqual(unorganized.changes.map(\.kind), [.unorganized])
    }
}
