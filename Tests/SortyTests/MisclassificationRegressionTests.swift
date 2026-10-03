import XCTest
import SortyQualitySupport

/// Reviewed corpus expectations catch semantic swaps such as filing Acme under Globex.
final class MisclassificationRegressionTests: XCTestCase {
    func testAcmeFiledAsGlobexSurfacesAsExpectationMismatch() {
        let corpus = [
            OrganizationQualityCorpusCase(
                id: "acme-into-globex",
                description: "Acme invoice filed under the Globex vendor folder",
                decisions: [
                    OrganizationQualityDecision(
                        sourcePath: "Inbox/acme-invoice-may.pdf",
                        expectedDestination: "Finance/Invoices/Acme",
                        observedDestination: "Finance/Invoices/Globex",
                        placementOutcome: .rejected
                    ),
                    OrganizationQualityDecision(
                        sourcePath: "Inbox/globex-invoice-may.pdf",
                        expectedDestination: "Finance/Invoices/Globex",
                        observedDestination: "Finance/Invoices/Globex",
                        placementOutcome: .accepted
                    ),
                ]
            ),
        ]

        let report = OrganizationQualityEvaluator.evaluate(corpus)

        XCTAssertEqual(report.placementExpectationMatchRate ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(report.placementAcceptanceRate ?? -1, 0.5, accuracy: 0.0001)
    }

    /// Bank statement absorbed into Invoices *and* renamed as an invoice
    /// violates both placement and the protected-name rule.
    func testStatementRenamedIntoInvoicesViolatesPlacementAndProtectedName() {
        let corpus = [
            OrganizationQualityCorpusCase(
                id: "statement-into-invoices",
                description: "Bank statement filed as an invoice and renamed",
                decisions: [
                    OrganizationQualityDecision(
                        sourcePath: "Inbox/bank_statement_may_2026.pdf",
                        expectedDestination: "Finance/Statements",
                        mustKeepOriginalName: true,
                        observedDestination: "Finance/Invoices",
                        placementOutcome: .rejected,
                        observedRename: "2026-05 Invoice.pdf",
                        renameOutcome: .rejected
                    ),
                ]
            ),
        ]

        let report = OrganizationQualityEvaluator.evaluate(corpus)

        XCTAssertEqual(report.placementExpectationMatchRate ?? 1, 0)
        XCTAssertEqual(report.protectedNamePreservationRate ?? 1, 0)
    }

    /// Picnic photo merged into Screenshots: one accepted misplacement out of
    /// two decisions keeps the acceptance rate honest instead of binary.
    func testPicnicMergedIntoScreenshotsLowersAcceptanceRate() {
        let corpus = [
            OrganizationQualityCorpusCase(
                id: "picnic-into-screenshots",
                description: "Personal photo merged into the screenshots folder",
                decisions: [
                    OrganizationQualityDecision(
                        sourcePath: "Downloads/picnic-2026-06-14.jpg",
                        expectedDestination: "Photos/Personal",
                        observedDestination: "Media/Screenshots",
                        placementOutcome: .edited
                    ),
                    OrganizationQualityDecision(
                        sourcePath: "Downloads/Screenshot 2026-05-31.png",
                        expectedDestination: "Media/Screenshots",
                        observedDestination: "Media/Screenshots",
                        placementOutcome: .accepted
                    ),
                ]
            ),
        ]

        let report = OrganizationQualityEvaluator.evaluate(corpus)

        XCTAssertEqual(report.placementAcceptanceRate ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(report.placementExpectationMatchRate ?? -1, 0.5, accuracy: 0.0001)
    }
}
