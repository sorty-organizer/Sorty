import XCTest
@testable import SortyOrganizer
@testable import SortyModels
import SortyQualitySupport

/// Semantic misclassification goldens.
///
/// PlanQualityEvaluator is deliberately structural: it cannot tell Acme from
/// Globex. These tests pin the two production mechanisms that *do* catch
/// misfiles, so a regression in either one fails loudly instead of silently
/// laundering a wrong-model plan:
///
/// - Structural symptoms of classic misfiles (mixed-type dumping grounds,
///   vague single-file buckets, near-duplicate vendor folders) must raise
///   named PlanQualityEvaluator issues.
/// - Pure semantic swaps with clean structure (Acme invoice filed under
///   Globex, statement renamed into Invoices) must surface as expectation
///   mismatches in the organization-quality corpus evaluator — the layer
///   that records final preview outcomes instead of rewriting expectations
///   to match the model.
/// - Fallback "Unorganized" buckets must demote through keepingCertainItems
///   rather than keeping confidently misfiled items placed.
final class MisclassificationRegressionTests: XCTestCase {
    private func file(_ name: String, ext: String = "") -> FileItem {
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        let fileExtension = ext.isEmpty ? url.pathExtension : ext
        return FileItem(
            path: url.path,
            name: url.deletingPathExtension().lastPathComponent,
            extension: fileExtension
        )
    }

    // MARK: - Structural symptoms of misfiles

    /// Installers dumped into a documents folder mix archives with documents
    /// and spreadsheets: the mixed-type gate must fire.
    func testInstallersDumpedIntoDocumentsFlagsMixedTypes() {
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "Documents",
                files: [
                    file("Arc-1.47.2.dmg"),
                    file("VSCode-darwin-universal.zip"),
                    file("resume-final.pdf"),
                    file("ledger-2026.csv"),
                ],
                reasoning: "Installer archives grouped with career documents"
            ),
        ])

        let assessment = PlanQualityEvaluator.assess(plan, existingFolderPaths: [])

        XCTAssertTrue(
            assessment.issues.contains { $0.kind == .mixedFileTypes },
            "installer archives mixed with documents/spreadsheets must flag mixedFileTypes"
        )
    }

    /// Camera RAW files merged into a screenshots folder mix three type
    /// families (images, vendor RAW, video): the mixed-type gate must fire.
    func testRawPhotosMergedIntoScreenshotsFlagsMixedTypes() {
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "Screenshots",
                files: [
                    file("Screenshot 2026-05-31.png"),
                    file("IMG_1842.PNG"),
                    file("DSC_0042.arw"),
                    file("RPReplay_Final.mov"),
                ],
                reasoning: "Trip screenshots grouped with camera RAW and a screen recording"
            ),
        ])

        let assessment = PlanQualityEvaluator.assess(plan, existingFolderPaths: [])

        XCTAssertTrue(
            assessment.issues.contains { $0.kind == .mixedFileTypes },
            "RAW + screenshots + screen recording must flag mixedFileTypes"
        )
    }

    /// Lone photos swept into vague single-file buckets must trip both the
    /// vague/single-file gate and the missing-explanation gate hard enough
    /// to fail the plan, so the retry pass is forced to place them properly.
    func testPicnicPhotoInVagueSingleFileBucketFails() {
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "Misc",
                files: [file("picnic-2026-06-14.jpg")]
            ),
            FolderSuggestion(
                folderName: "Other",
                files: [file("receipt-88310.pdf")]
            ),
        ])

        let assessment = PlanQualityEvaluator.assess(plan, existingFolderPaths: [])

        XCTAssertFalse(assessment.passes, "vague single-file buckets must not pass")
        XCTAssertEqual(
            assessment.issues.filter { $0.kind == .vagueOrSingleFileFolder }.count,
            2
        )
        XCTAssertTrue(assessment.issues.contains { $0.kind == .missingExplanation })
    }

    /// Near-duplicate vendor folders ("Invoice" vs "Invoices") are the
    /// structural fingerprint of an Acme/Globex-style split: the duplicate
    /// gate must fire so the retry pass can merge them.
    func testNearDuplicateVendorFoldersFlagDuplicates() {
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "Invoice",
                files: [file("acme-may.pdf"), file("acme-june.pdf")],
                reasoning: "Acme invoices share a vendor and date pattern"
            ),
            FolderSuggestion(
                folderName: "Invoices",
                files: [file("globex-may.pdf"), file("globex-june.pdf")],
                reasoning: "Globex invoices share a vendor and date pattern"
            ),
        ])

        let assessment = PlanQualityEvaluator.assess(plan, existingFolderPaths: [])

        XCTAssertTrue(
            assessment.issues.contains { $0.kind == .duplicateFolderNames },
            "near-duplicate invoice folders must flag duplicateFolderNames"
        )
    }

    /// A model-invented "Reportz" next to the existing "Reports" convention
    /// must flag a convention mismatch so the retry reuses the real folder.
    func testConventionMismatchAgainstExistingFolderFlags() {
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "Reportz",
                files: [file("q1.pdf"), file("q2.pdf")],
                reasoning: "Quarterly reports share a subject and cadence"
            ),
        ])

        let assessment = PlanQualityEvaluator.assess(
            plan,
            existingFolderPaths: ["Projects/Invoices/Reports"]
        )

        XCTAssertTrue(
            assessment.issues.contains { $0.kind == .existingConventionMismatch },
            "Reportz next to existing Reports must flag existingConventionMismatch"
        )
    }

    // MARK: - Fallback-bucket demotion

    /// Files a wrong-model plan swept into a disguised "Unorganized" bucket
    /// must be demoted to unorganizedFiles by keepingCertainItems while the
    /// confidently placed folder survives untouched.
    func testFallbackBucketDemotesMisfiledItemsKeepsCertain() {
        let certainA = file("acme-may.pdf")
        let certainB = file("acme-june.pdf")
        let sweptStatement = file("bank_statement_may_2026.pdf")
        let sweptInstaller = file("Arc-1.47.2.dmg")
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "Acme Invoices",
                files: [certainA, certainB],
                reasoning: "Acme invoices share a vendor and monthly cadence"
            ),
            FolderSuggestion(
                folderName: "Unorganized",
                files: [sweptStatement, sweptInstaller],
                reasoning: "Files without a clearer destination"
            ),
        ])

        let assessment = PlanQualityEvaluator.assess(plan, existingFolderPaths: [])
        XCTAssertFalse(assessment.passes, "disguised unorganized bucket must not pass")

        let reviewed = PlanQualityEvaluator.keepingCertainItems(in: plan, assessment: assessment)

        XCTAssertEqual(reviewed.suggestions.map(\.folderName), ["Acme Invoices"])
        XCTAssertEqual(
            Set(reviewed.unorganizedFiles.map(\.id)),
            Set([sweptStatement.id, sweptInstaller.id])
        )
        XCTAssertTrue(reviewed.unorganizedFiles.allSatisfy { $0.id != certainA.id && $0.id != certainB.id })
    }

    // MARK: - Corpus goldens: semantic swaps the structural gates cannot see

    /// Acme invoice observed under a Globex destination with clean structure
    /// passes structural gates — the corpus evaluator must still record the
    /// expectation mismatch so the regression is visible.
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

    // MARK: - Corpus goldens: batch coherence + calibration

    /// Mirror-image vendor swap: Globex invoice filed under Acme. Together
    /// with acme-into-globex this pins both directions of vendor confusion
    /// as expectation mismatches.
    func testGlobexFiledAsAcmeSurfacesAsExpectationMismatch() {
        let corpus = [
            OrganizationQualityCorpusCase(
                id: "globex-into-acme",
                description: "Globex invoice filed under the Acme vendor folder",
                decisions: [
                    OrganizationQualityDecision(
                        sourcePath: "Inbox/globex-invoice-june.pdf",
                        expectedDestination: "Finance/Invoices/Globex",
                        observedDestination: "Finance/Invoices/Acme",
                        placementOutcome: .rejected
                    ),
                    OrganizationQualityDecision(
                        sourcePath: "Inbox/acme-invoice-june.pdf",
                        expectedDestination: "Finance/Invoices/Acme",
                        observedDestination: "Finance/Invoices/Acme",
                        placementOutcome: .accepted
                    ),
                ]
            ),
        ]

        let report = OrganizationQualityEvaluator.evaluate(corpus)

        XCTAssertEqual(report.placementExpectationMatchRate ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(report.placementAcceptanceRate ?? -1, 0.5, accuracy: 0.0001)
    }

    /// Topic confusion: a payment receipt filed as an invoice. Same folder
    /// family, wrong topic — the corpus must record the mismatch even though
    /// the structure looks tidy.
    func testReceiptFiledAsInvoiceSurfacesAsExpectationMismatch() {
        let corpus = [
            OrganizationQualityCorpusCase(
                id: "receipt-into-invoices",
                description: "Payment receipt filed under Invoices instead of Receipts",
                decisions: [
                    OrganizationQualityDecision(
                        sourcePath: "Inbox/acme-receipt-may.pdf",
                        expectedDestination: "Finance/Receipts/Acme",
                        observedDestination: "Finance/Invoices/Acme",
                        placementOutcome: .edited
                    ),
                    OrganizationQualityDecision(
                        sourcePath: "Inbox/acme-invoice-may.pdf",
                        expectedDestination: "Finance/Invoices/Acme",
                        observedDestination: "Finance/Invoices/Acme",
                        placementOutcome: .accepted
                    ),
                ]
            ),
        ]

        let report = OrganizationQualityEvaluator.evaluate(corpus)

        XCTAssertEqual(report.placementExpectationMatchRate ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(report.placementAcceptanceRate ?? -1, 0.5, accuracy: 0.0001)
    }

    /// Oversized single-category dump: six files swept into one Documents
    /// folder when the expectations span invoices, statements, and photos.
    /// None of the six placements match, so both match and acceptance rates
    /// must read 0 rather than hiding behind one tidy folder.
    func testOversizedSingleCategoryDumpSurfacesMismatches() {
        let corpus = [
            OrganizationQualityCorpusCase(
                id: "everything-into-documents",
                description: "Invoices, statements, and photos dumped into one Documents folder",
                decisions: [
                    OrganizationQualityDecision(
                        sourcePath: "Inbox/acme-invoice-may.pdf",
                        expectedDestination: "Finance/Invoices/Acme",
                        observedDestination: "Documents",
                        placementOutcome: .rejected
                    ),
                    OrganizationQualityDecision(
                        sourcePath: "Inbox/globex-invoice-may.pdf",
                        expectedDestination: "Finance/Invoices/Globex",
                        observedDestination: "Documents",
                        placementOutcome: .rejected
                    ),
                    OrganizationQualityDecision(
                        sourcePath: "Inbox/bank_statement_may_2026.pdf",
                        expectedDestination: "Finance/Statements",
                        observedDestination: "Documents",
                        placementOutcome: .rejected
                    ),
                    OrganizationQualityDecision(
                        sourcePath: "Inbox/bank_statement_june_2026.pdf",
                        expectedDestination: "Finance/Statements",
                        observedDestination: "Documents",
                        placementOutcome: .edited
                    ),
                    OrganizationQualityDecision(
                        sourcePath: "Downloads/picnic-2026-06-14.jpg",
                        expectedDestination: "Photos/Personal",
                        observedDestination: "Documents",
                        placementOutcome: .rejected
                    ),
                    OrganizationQualityDecision(
                        sourcePath: "Downloads/Screenshot 2026-05-31.png",
                        expectedDestination: "Media/Screenshots",
                        observedDestination: "Documents",
                        placementOutcome: .rejected
                    ),
                ]
            ),
        ]

        let report = OrganizationQualityEvaluator.evaluate(corpus)

        XCTAssertEqual(report.placementExpectationMatchRate ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(report.placementAcceptanceRate ?? -1, 0, accuracy: 0.0001)
    }

    /// Invented deep nesting: two files that belong in shallow project
    /// folders get buried under an A/B/C/D-style chain. Path comparison is
    /// exact, so both decisions mismatch.
    func testInventedDeepNestingSurfacesMismatch() {
        let corpus = [
            OrganizationQualityCorpusCase(
                id: "invented-deep-nesting",
                description: "Two project files buried under an invented A/B/C/D chain",
                decisions: [
                    OrganizationQualityDecision(
                        sourcePath: "Inbox/alpha-spec.pdf",
                        expectedDestination: "Projects/Alpha",
                        observedDestination: "Projects/Alpha/Docs/Drafts/Final",
                        placementOutcome: .edited
                    ),
                    OrganizationQualityDecision(
                        sourcePath: "Inbox/beta-plan.pdf",
                        expectedDestination: "Projects/Beta",
                        observedDestination: "Projects/Beta/Docs/Drafts/Final",
                        placementOutcome: .rejected
                    ),
                ]
            ),
        ]

        let report = OrganizationQualityEvaluator.evaluate(corpus)

        XCTAssertEqual(report.placementExpectationMatchRate ?? -1, 0, accuracy: 0.0001)
    }

    /// Rename calibration golden: an evidence-backed high-confidence rename
    /// that the user accepts must match expectations exactly, while a
    /// rejected low-confidence rename lands in its calibration bin with a
    /// 0 acceptance rate. Pins the confidence/acceptance contract end to end.
    func testRenameCalibrationGoldensMatchExpectations() {
        let corpus = [
            OrganizationQualityCorpusCase(
                id: "rename-calibration",
                description: "Accepted high-confidence rename plus rejected low-confidence rename",
                decisions: [
                    OrganizationQualityDecision(
                        sourcePath: "Inbox/IMG_1842.jpg",
                        expectedDestination: "Photos/Trips",
                        expectedRename: "Harbor Sunset.jpg",
                        observedDestination: "Photos/Trips",
                        placementOutcome: .accepted,
                        observedRename: "Harbor Sunset.jpg",
                        renameOutcome: .accepted,
                        renameConfidence: 0.9
                    ),
                    OrganizationQualityDecision(
                        sourcePath: "Inbox/scan0007.pdf",
                        expectedDestination: "Finance/Invoices",
                        mustKeepOriginalName: true,
                        observedDestination: "Finance/Invoices",
                        placementOutcome: .accepted,
                        observedRename: "2026-05 Invoice.pdf",
                        renameOutcome: .rejected,
                        renameConfidence: 0.2,
                        wasSurfacedForReview: true
                    ),
                ]
            ),
        ]

        let report = OrganizationQualityEvaluator.evaluate(corpus)

        XCTAssertEqual(report.placementExpectationMatchRate ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(report.renameExpectationMatchRate ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(report.protectedNamePreservationRate ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(report.calibrationBins.count, 2)
        let lowBin = report.calibrationBins.first { $0.lowerBound < 0.3 }
        XCTAssertEqual(lowBin?.acceptanceRate ?? -1, 0, accuracy: 0.0001)
        let highBin = report.calibrationBins.first { $0.lowerBound >= 0.8 }
        XCTAssertEqual(highBin?.acceptanceRate ?? -1, 1, accuracy: 0.0001)
    }
}
