import XCTest
@testable import SortyLib
@testable import SortyModels

/// Runtime rename calibration goldens: low-confidence renames require
/// explicit user opt-in, opt-ins survive calibration, and preview review
/// surfaces the riskiest renames first.
final class OrganizationQualityRenameCalibrationTests: XCTestCase {
    private func file(_ name: String) -> FileItem {
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        return FileItem(
            path: url.path,
            name: url.deletingPathExtension().lastPathComponent,
            extension: url.pathExtension
        )
    }

    private func mapping(
        _ name: String,
        suggested: String,
        confidence: Double?,
        isSelected: Bool? = nil
    ) -> FileRenameMapping {
        FileRenameMapping(
            originalFile: file(name),
            suggestedName: suggested,
            renameReason: "Content evidence for the clearer name",
            renameConfidence: confidence,
            isSelected: isSelected
        )
    }

    /// Low-confidence renames calibrate to an explicit opt-out: the preview
    /// toggle renders OFF and apply skips them until the user opts in.
    func testLowConfidenceRenameRequiresExplicitOptIn() {
        let low = file("scan.pdf")
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "Invoices",
                files: [low],
                fileRenameMappings: [mapping("scan.pdf", suggested: "Acme Invoice.pdf", confidence: 0.2)]
            ),
        ])

        let calibrated = plan.calibratingRenameSelection()
        let result = try? XCTUnwrap(calibrated.suggestions.first?.fileRenameMappings.first)

        XCTAssertEqual(result?.isSelected, false)
        XCTAssertFalse(result?.shouldApplyRename ?? true)
        XCTAssertTrue(result?.isAutoSkippedForLowConfidence ?? false)
    }

    /// Medium-confidence renames also stay off until opted in.
    func testMediumConfidenceRenameStaysOffUntilOptIn() {
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "Invoices",
                files: [file("scan.pdf")],
                fileRenameMappings: [mapping("scan.pdf", suggested: "Possible Invoice.pdf", confidence: 0.6)]
            ),
        ])

        let calibrated = plan.calibratingRenameSelection()
        let result = try? XCTUnwrap(calibrated.suggestions.first?.fileRenameMappings.first)

        XCTAssertEqual(result?.isSelected, false)
        XCTAssertFalse(result?.shouldApplyRename ?? true)
    }

    /// An explicit user opt-in survives calibration — even for low
    /// confidence. Opt-in means apply.
    func testExplicitOptInSurvivesCalibration() {
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "Invoices",
                files: [file("export.pdf")],
                fileRenameMappings: [
                    mapping("export.pdf", suggested: "Client Export.pdf", confidence: 0.2, isSelected: true)
                ]
            ),
        ])

        let calibrated = plan.calibratingRenameSelection()
        let result = try? XCTUnwrap(calibrated.suggestions.first?.fileRenameMappings.first)

        XCTAssertEqual(result?.isSelected, true)
        XCTAssertTrue(result?.shouldApplyRename ?? false)
    }

    /// High-confidence renames keep their default-apply behavior.
    func testHighConfidenceRenameKeepsDefaultApply() {
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "Photos",
                files: [file("IMG_1842.jpg")],
                fileRenameMappings: [mapping("IMG_1842.jpg", suggested: "Harbor Sunset.jpg", confidence: 0.9)]
            ),
        ])

        let calibrated = plan.calibratingRenameSelection()
        let result = try? XCTUnwrap(calibrated.suggestions.first?.fileRenameMappings.first)

        XCTAssertNil(result?.isSelected)
        XCTAssertTrue(result?.shouldApplyRename ?? false)
    }

    /// Calibration sorts mappings by confidence ascending so the riskiest
    /// suggestion reviews first.
    func testCalibrationSortsMappingsByConfidence() {
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "Mixed",
                files: [file("a.pdf"), file("b.pdf"), file("c.pdf")],
                fileRenameMappings: [
                    mapping("a.pdf", suggested: "Alpha.pdf", confidence: 0.9),
                    mapping("b.pdf", suggested: "Beta.pdf", confidence: 0.1),
                    mapping("c.pdf", suggested: "Gamma.pdf", confidence: 0.5),
                ]
            ),
        ])

        let calibrated = plan.calibratingRenameSelection()
        let confidences = calibrated.suggestions.first?.fileRenameMappings.map { $0.renameConfidence ?? 1.0 }

        XCTAssertEqual(confidences ?? [], [0.1, 0.5, 0.9])
    }

    /// The preview flag list surfaces the riskiest rename first.
    func testFlaggableRenamesSortByConfidenceAscending() {
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "Mixed",
                files: [file("a.pdf"), file("b.pdf"), file("c.pdf")],
                fileRenameMappings: [
                    mapping("a.pdf", suggested: "Alpha.pdf", confidence: 0.6),
                    mapping("b.pdf", suggested: "Beta.pdf", confidence: 0.1),
                    mapping("c.pdf", suggested: "Gamma.pdf", confidence: 0.9),
                ]
            ),
        ])

        let flagged = PreviewPlanInsights.flaggableRenames(in: plan)

        // High-confidence stays quiet; the flagged pair sorts riskiest-first.
        XCTAssertEqual(flagged.map { $0.mapping.originalFile.displayName }, ["b.pdf", "a.pdf"])
    }
}
