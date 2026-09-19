import XCTest
import Combine
@testable import SortyLib

// Mock AI Client for testing (analyze-focused).
// NOTE: A second, divergent MockAIClient lives in LLMRuleInducerTests.swift
// for generateText-focused tests (final class, nonisolated config). The two
// are intentionally separate: this actor records analyze batches for
// FolderOrganizer tests, while the other stubs generateText for
// LLMRuleInducer. Unifying would couple unrelated test domains; production
// views now accept an injected (any AIClientProtocol) so both can inject
// without touching AIClientFactory.
actor MockAIClient: AIClientProtocol, @unchecked Sendable {
    let config: AIConfig
    var analyzeHandler: (([FileItem]) async throws -> OrganizationPlan)?
    var indexedAnalyzeHandler: (([FileItem], Int) async throws -> OrganizationPlan)?
    private(set) var analyzedBatchSizes: [Int] = []
    private(set) var analyzedInstructions: [String?] = []
    @MainActor weak var streamingDelegate: StreamingDelegate?

    init(config: AIConfig) {
        self.config = config
    }

    func analyze(files: [FileItem], customInstructions: String?, personaPrompt: String?, temperature: Double?) async throws -> OrganizationPlan {
        analyzedBatchSizes.append(files.count)
        analyzedInstructions.append(customInstructions)
        if let indexedAnalyzeHandler {
            return try await indexedAnalyzeHandler(files, analyzedBatchSizes.count)
        }
        if let handler = analyzeHandler {
            return try await handler(files)
        }
        return OrganizationPlan(suggestions: [], unorganizedFiles: [], notes: "")
    }

    func setHandler(_ handler: @escaping @Sendable ([FileItem]) async throws -> OrganizationPlan) {
        self.analyzeHandler = handler
    }

    func setIndexedHandler(_ handler: @escaping @Sendable ([FileItem], Int) async throws -> OrganizationPlan) {
        indexedAnalyzeHandler = handler
    }

    func currentAnalyzedBatchSizes() -> [Int] {
        analyzedBatchSizes
    }

    func currentAnalyzedInstructions() -> [String?] {
        analyzedInstructions
    }

    func generateText(prompt: String, systemPrompt: String?) async throws -> String {
        return "Mock response"
    }
    
    func checkHealth() async throws {
        // Success by default
    }

    func analyzeWithImages(files: [FileItem], imageData: [String: Data], customInstructions: String?, personaPrompt: String?, temperature: Double?) async throws -> OrganizationPlan {
        return try await analyze(files: files, customInstructions: customInstructions, personaPrompt: personaPrompt, temperature: temperature)
    }
}

// Box for observing mock AI completion across isolation domains in tests.
final class MockCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.withLock { value = true }
    }

    var isSet: Bool {
        lock.withLock { value }
    }
}

class SortyTests: XCTestCase {

    var folderOrganizer: FolderOrganizer!
    var mockClient: MockAIClient!
    var tempDirectory: URL!

    @MainActor
    override func setUp() async throws {
        
        folderOrganizer = FolderOrganizer()
        let config = AIConfig(apiKey: "test-key", model: "test-model")
        mockClient = MockAIClient(config: config)

        // Create a temporary directory for testing
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    @MainActor
    override func tearDown() async throws {
        if let tempDirectory = tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        folderOrganizer = nil
        mockClient = nil
        
    }

    @MainActor
    func testOrganizeFlow() async throws {
        // 1. Setup: Create a dummy file to scan
        let dummyFileURL = tempDirectory.appendingPathComponent("test.txt")
        try "content".write(to: dummyFileURL, atomically: true, encoding: .utf8)

        // 2. Setup: Inject mock client
        folderOrganizer.setAIClientForTesting(mockClient)

        // 3. Setup: Define mock behavior
        await mockClient.setHandler { files in
            // Verify we received the file
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(files.first?.name, "test")

            return OrganizationPlan(
                suggestions: [
                    FolderSuggestion(folderName: "Docs", description: "Text", files: files, subfolders: [], reasoning: "Text")
                ],
                unorganizedFiles: [],
                notes: "Test Plan"
            )
        }

        // 4. Act
        try await folderOrganizer.organize(directory: tempDirectory)

        // 5. Assert
        XCTAssertEqual(folderOrganizer.state, .ready)
        XCTAssertNotNil(folderOrganizer.currentPlan)
        XCTAssertEqual(folderOrganizer.currentPlan?.suggestions.first?.folderName, "Docs")
    }

    @MainActor
    func testLowQualityPlanRetriesOnceWithConcreteDeficiencies() async throws {
        for name in ["one.pdf", "two.jpg", "three.mov", "four.csv", "five.txt"] {
            try Data().write(to: tempDirectory.appendingPathComponent(name))
        }
        folderOrganizer.setAIClientForTesting(mockClient)
        await mockClient.setIndexedHandler { files, requestIndex in
            if requestIndex == 1 {
                return OrganizationPlan(suggestions: [
                    FolderSuggestion(folderName: "Misc", files: Array(files.prefix(4))),
                    FolderSuggestion(folderName: "Other", files: Array(files.suffix(1)))
                ])
            }
            return OrganizationPlan(suggestions: [
                FolderSuggestion(folderName: "Reference Material", files: files)
            ])
        }

        try await folderOrganizer.organize(directory: tempDirectory)

        let instructions = await mockClient.currentAnalyzedInstructions()
        XCTAssertEqual(instructions.count, 2)
        XCTAssertTrue(instructions[1]?.contains("PLAN QUALITY CORRECTION") == true)
        XCTAssertTrue(instructions[1]?.contains("\"Misc\"") == true)
        XCTAssertTrue(instructions[1]?.contains("vague name") == true)
        XCTAssertEqual(folderOrganizer.currentPlan?.qualityAssessment?.didRetry, true)
        XCTAssertEqual(folderOrganizer.currentPlan?.suggestions.map(\.folderName), ["Reference Material"])
    }

    @MainActor
    func testLargeOrganizeFlowUsesBoundedAIBatches() async throws {
        for index in 0..<351 {
            let fileURL = tempDirectory.appendingPathComponent("file-\(index).txt")
            try Data().write(to: fileURL)
        }

        folderOrganizer.setAIClientForTesting(mockClient)
        await mockClient.setHandler { files in
            OrganizationPlan(
                suggestions: [
                    FolderSuggestion(folderName: "Documents", files: files)
                ]
            )
        }

        try await folderOrganizer.organize(directory: tempDirectory)
        let batchSizes = await mockClient.currentAnalyzedBatchSizes()

        XCTAssertEqual(batchSizes, [350, 1])
        XCTAssertEqual(folderOrganizer.currentPlan?.totalFiles, 351)
        XCTAssertEqual(folderOrganizer.currentPlan?.suggestions.count, 1)
    }

    @MainActor
    func testLargeRenameFlowUsesSmallerBoundedAIBatches() async throws {
        for index in 0..<121 {
            let fileURL = tempDirectory.appendingPathComponent("rename-\(index).txt")
            try Data().write(to: fileURL)
        }

        let renameConfig = AIConfig(
            apiKey: "test-key",
            model: "test-model",
            mode: .renameOnly,
            enableDeepScan: false,
            enableVision: false
        )
        let renameClient = MockAIClient(config: renameConfig)
        folderOrganizer.setAIClientForTesting(renameClient)
        await renameClient.setHandler { files in
            OrganizationPlan(
                suggestions: [
                    FolderSuggestion(folderName: "", files: files)
                ]
            )
        }

        try await folderOrganizer.organize(directory: tempDirectory)
        let batchSizes = await renameClient.currentAnalyzedBatchSizes()

        XCTAssertEqual(batchSizes, [120, 1])
        XCTAssertEqual(folderOrganizer.currentPlan?.totalFiles, 121)
    }

    @MainActor
    func testOutputLimitFailureSplitsBatchAndPreservesSuccessfulResults() async throws {
        for index in 0..<16 {
            let fileURL = tempDirectory.appendingPathComponent("adaptive-\(index).txt")
            try Data().write(to: fileURL)
        }

        folderOrganizer.setAIClientForTesting(mockClient)
        await mockClient.setHandler { files in
            if files.count > 8 {
                throw AIClientError.apiError(
                    statusCode: 413,
                    message: "The model reached its output limit."
                )
            }
            return OrganizationPlan(
                suggestions: [
                    FolderSuggestion(folderName: "Documents", files: files)
                ]
            )
        }

        try await folderOrganizer.organize(directory: tempDirectory)
        let batchSizes = await mockClient.currentAnalyzedBatchSizes()

        XCTAssertEqual(batchSizes, [16, 8, 8])
        XCTAssertEqual(folderOrganizer.currentPlan?.totalFiles, 16)
        XCTAssertEqual(folderOrganizer.currentPlan?.suggestions.count, 1)
    }

    @MainActor
    func testTimeoutCanContinueFromLastCompletedBatch() async throws {
        for index in 0..<121 {
            let fileURL = tempDirectory.appendingPathComponent("resume-\(index).txt")
            try Data().write(to: fileURL)
        }

        let renameConfig = AIConfig(
            apiKey: "test-key",
            model: "test-model",
            mode: .renameOnly,
            enableDeepScan: false,
            enableVision: false
        )
        let renameClient = MockAIClient(config: renameConfig)
        let timeoutTracker = ResumeTimeoutTracker()
        folderOrganizer.setAIClientForTesting(renameClient)
        await renameClient.setHandler { files in
            try await timeoutTracker.plan(for: files)
        }

        do {
            try await folderOrganizer.organize(directory: tempDirectory)
            XCTFail("Expected the final batch to time out")
        } catch {
            XCTAssertTrue(folderOrganizer.canResumeOrganization)
        }

        try await folderOrganizer.resumeOrganization()
        let batchSizes = await renameClient.currentAnalyzedBatchSizes()

        XCTAssertEqual(batchSizes, [120, 1, 1])
        XCTAssertEqual(folderOrganizer.currentPlan?.totalFiles, 121)
        XCTAssertEqual(folderOrganizer.state, .ready)
        XCTAssertFalse(folderOrganizer.canResumeOrganization)
    }

    @MainActor
    func testClientNotConfiguredError() async {
        // Ensure client is nil
        folderOrganizer.setAIClientForTesting(nil)

        do {
            try await folderOrganizer.organize(directory: tempDirectory)
            XCTFail("Should throw error")
        } catch {
            XCTAssertEqual(error as? OrganizationError, OrganizationError.clientNotConfigured)
        }
    }

    @MainActor
    func testCancelOrganization() async throws {
        // Setup
        let dummyFileURL = tempDirectory.appendingPathComponent("test.txt")
        try "content".write(to: dummyFileURL, atomically: true, encoding: .utf8)

        folderOrganizer.setAIClientForTesting(mockClient)

        // Setup a slow handler
        await mockClient.setHandler { files in
            try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            return OrganizationPlan(suggestions: [], unorganizedFiles: [], notes: "")
        }

        // Start organization in background
        let task = Task {
            try await folderOrganizer.organize(directory: tempDirectory)
        }

        // Wait a bit then cancel
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        folderOrganizer.cancel()

        // Verify state is idle after cancel
        XCTAssertEqual(folderOrganizer.state, .idle)

        task.cancel()
    }

    @MainActor
    func testCancelRegenerateReturnsToIdleWithoutError() async throws {
        let dummyFileURL = tempDirectory.appendingPathComponent("test.txt")
        try "content".write(to: dummyFileURL, atomically: true, encoding: .utf8)

        folderOrganizer.setAIClientForTesting(mockClient)
        await mockClient.setHandler { files in
            return OrganizationPlan(
                suggestions: [FolderSuggestion(folderName: "Test", files: files)],
                unorganizedFiles: [],
                notes: ""
            )
        }
        try await folderOrganizer.organize(directory: tempDirectory)
        XCTAssertEqual(folderOrganizer.state, .ready)

        let completionFlag = MockCompletionFlag()
        await mockClient.setHandler { files in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            completionFlag.set()
            return OrganizationPlan(suggestions: [], unorganizedFiles: [], notes: "")
        }

        let task = Task {
            try await folderOrganizer.regeneratePreview()
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        folderOrganizer.cancel()

        XCTAssertEqual(folderOrganizer.state, .idle)

        do {
            try await task.value
            XCTFail("Regenerate should throw on cancel")
        } catch is CancellationError {
            // Expected: cancellation surfaces as CancellationError so callers ignore it
        } catch {
            XCTFail("Cancel should throw CancellationError, got \(error)")
        }
        XCTAssertEqual(folderOrganizer.state, .idle)
        // The AI request itself must have been aborted, not left running to
        // completion with its result discarded.
        XCTAssertFalse(completionFlag.isSet, "Cancel should abort the in-flight AI request")
    }

    @MainActor
    func testIsCancellationErrorHelper() {
        XCTAssertTrue(FolderOrganizer.isCancellationError(CancellationError()))
        XCTAssertTrue(FolderOrganizer.isCancellationError(OrganizationError.cancelled))
        XCTAssertTrue(FolderOrganizer.isCancellationError(AIClientError.networkError(CancellationError())))
        XCTAssertTrue(FolderOrganizer.isCancellationError(URLError(.cancelled)))
        XCTAssertFalse(FolderOrganizer.isCancellationError(OrganizationError.noCurrentPlan))
        XCTAssertFalse(FolderOrganizer.isCancellationError(OrganizationError.clientNotConfigured))
    }

    @MainActor
    func testResetClearsState() async throws {
        // Setup some state
        let dummyFileURL = tempDirectory.appendingPathComponent("test.txt")
        try "content".write(to: dummyFileURL, atomically: true, encoding: .utf8)

        folderOrganizer.setAIClientForTesting(mockClient)
        await mockClient.setHandler { files in
            return OrganizationPlan(
                suggestions: [FolderSuggestion(folderName: "Test", files: files)],
                unorganizedFiles: [],
                notes: ""
            )
        }

        try await folderOrganizer.organize(directory: tempDirectory)
        XCTAssertEqual(folderOrganizer.state, .ready)
        XCTAssertNotNil(folderOrganizer.currentPlan)

        // Reset
        folderOrganizer.reset()

        // Verify reset
        XCTAssertEqual(folderOrganizer.state, .idle)
        XCTAssertNil(folderOrganizer.currentPlan)
        XCTAssertEqual(folderOrganizer.progress, 0.0)
    }
    
    @MainActor
    func testOrganizeIntoExistingDirectory() async throws {
        // Setup: Create a file and an existing directory
        let dummyFileURL = tempDirectory.appendingPathComponent("test.txt")
        try "content".write(to: dummyFileURL, atomically: true, encoding: .utf8)
        
        let existingDirURL = tempDirectory.appendingPathComponent("ExistingFolder")
        try FileManager.default.createDirectory(at: existingDirURL, withIntermediateDirectories: true)
        
        folderOrganizer.setAIClientForTesting(mockClient)
        
        // Setup: Mock returns a plan with a folder name that already exists
        await mockClient.setHandler { files in
            return OrganizationPlan(
                suggestions: [
                    FolderSuggestion(
                        folderName: "ExistingFolder",
                        description: "Test folder",
                        files: files,
                        subfolders: [],
                        reasoning: "Test"
                    )
                ],
                unorganizedFiles: [],
                notes: "Test Plan"
            )
        }
        
        // Act: This should NOT throw an error even though ExistingFolder already exists
        try await folderOrganizer.organize(directory: tempDirectory)
        
        // Assert: Organization should succeed
        XCTAssertEqual(folderOrganizer.state, .ready)
        XCTAssertNotNil(folderOrganizer.currentPlan)
        XCTAssertEqual(folderOrganizer.currentPlan?.suggestions.first?.folderName, "ExistingFolder")
    }
    
    @MainActor
    func testRejectOrganizingIntoExistingFile() async throws {
        // Setup: Create test files including one that will conflict with the suggested folder name
        let dummyFileURL = tempDirectory.appendingPathComponent("test.txt")
        try "content".write(to: dummyFileURL, atomically: true, encoding: .utf8)
        
        // Create a file (not directory) with the name we'll suggest as a folder
        let existingFileURL = tempDirectory.appendingPathComponent("ConflictingFile")
        try "existing file content".write(to: existingFileURL, atomically: true, encoding: .utf8)
        
        folderOrganizer.setAIClientForTesting(mockClient)
        
        // Setup: Mock returns a plan with a folder name that conflicts with an existing file
        await mockClient.setHandler { files in
            return OrganizationPlan(
                suggestions: [
                    FolderSuggestion(
                        folderName: "ConflictingFile",
                        description: "Test folder",
                        files: files,
                        subfolders: [],
                        reasoning: "Test"
                    )
                ],
                unorganizedFiles: [],
                notes: "Test Plan"
            )
        }
        
        // Act & Assert: This should throw a validation error because ConflictingFile exists as a file
        do {
            try await folderOrganizer.organize(directory: tempDirectory)
            XCTFail("Should have thrown a validation error")
        } catch let error as ValidationError {
            // Verify it's the correct error type
            if case .pathExists(let path) = error {
                XCTAssertTrue(path.contains("ConflictingFile"))
            } else {
                XCTFail("Wrong validation error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

private actor ResumeTimeoutTracker {
    private var hasTimedOut = false

    func plan(for files: [FileItem]) throws -> OrganizationPlan {
        if files.count == 1, !hasTimedOut {
            hasTimedOut = true
            throw AIClientError.networkError(URLError(.timedOut))
        }
        return OrganizationPlan(
            suggestions: [
                FolderSuggestion(folderName: "", files: files)
            ]
        )
    }
}

final class PlanQualityEvaluatorTests: XCTestCase {
    func testScoresNamedStructuralDeficiencies() {
        let files = [
            file("a.pdf"), file("b.jpg"), file("c.mov"), file("d.csv")
        ]
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(folderName: "Misc", files: files),
            FolderSuggestion(folderName: "Miscs", files: [file("e.txt")])
        ])

        let assessment = PlanQualityEvaluator.assess(
            plan,
            existingFolderPaths: ["Archive/Miscellaneous"]
        )

        XCTAssertFalse(assessment.passes)
        XCTAssertTrue(assessment.issues.contains { $0.kind == .duplicateFolderNames })
        XCTAssertTrue(assessment.issues.contains { $0.kind == .vagueOrSingleFileFolder })
        XCTAssertTrue(assessment.issues.contains { $0.kind == .mixedFileTypes })
    }

    func testFlagsUnnecessaryNestingAndExistingConventionMismatch() {
        let report = file("report.pdf")
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "Projects",
                subfolders: [
                    FolderSuggestion(
                        folderName: "Invoices",
                        subfolders: [FolderSuggestion(folderName: "Reportz", files: [report])]
                    )
                ]
            )
        ])

        let assessment = PlanQualityEvaluator.assess(
            plan,
            existingFolderPaths: ["Projects/Invoices/Reports"]
        )

        XCTAssertTrue(assessment.issues.contains { $0.kind == .unnecessaryNesting })
        XCTAssertTrue(assessment.issues.contains { $0.kind == .existingConventionMismatch })
    }

    func testFlagsFolderWithoutConcreteReviewExplanation() {
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(folderName: "Invoices", files: [file("may.pdf"), file("june.pdf")])
        ])

        let assessment = PlanQualityEvaluator.assess(plan, existingFolderPaths: [])

        XCTAssertTrue(assessment.issues.contains { $0.kind == .missingExplanation })
        XCTAssertTrue(PlanQualityEvaluator.retryInstructions(for: assessment).contains("shared subject"))
    }

    func testExcessiveUnorganizedFilesTriggerQualityRetry() {
        let assigned = (1...10).map { file("assigned-\($0).txt") }
        let unorganized = (1...5).map { file("unorganized-\($0).zip") }
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Documents", files: assigned, reasoning: "Shared documents")],
            unorganizedFiles: unorganized
        )

        let assessment = PlanQualityEvaluator.assess(plan, existingFolderPaths: [])

        XCTAssertFalse(assessment.passes)
        XCTAssertTrue(assessment.issues.contains { $0.kind == .excessiveUnorganizedFiles })
        XCTAssertTrue(PlanQualityEvaluator.retryInstructions(for: assessment).contains("Ambiguity or a standalone role is not enough"))
    }

    func testUnorganizedFilesFolderTriggersQualityRetry() {
        let files = (1...6).map { file("download-\($0).bin") }
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "Unorganized Files",
                files: files,
                reasoning: "Files without a clearer destination"
            )
        ])

        let assessment = PlanQualityEvaluator.assess(plan, existingFolderPaths: [])

        XCTAssertFalse(assessment.passes)
        XCTAssertTrue(assessment.issues.contains { $0.kind == .unorganizedFolderDestination })
        XCTAssertEqual(assessment.uncertainFileIDs, Set(files.map(\.id)))
        XCTAssertTrue(PlanQualityEvaluator.retryInstructions(for: assessment).contains("disguised unorganized bucket"))
    }

    func testLowScoreKeepsStructuralWarningsAndDemotesOnlyFallbackFolderFiles() {
        let certain = file("statement.pdf")
        let uncertain = file("download.bin")
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(folderName: "Bank Statements", files: [certain, file("statement-2.pdf")]),
            FolderSuggestion(folderName: "Unorganized", files: [uncertain])
        ])
        let assessment = PlanQualityAssessment(
            score: 60,
            issues: [
                PlanQualityIssue(
                    kind: .unorganizedFolderDestination,
                    message: "Unorganized is a fallback folder.",
                    folderPaths: ["Unorganized"],
                    fileIDs: [uncertain.id],
                    deduction: 40
                ),
                PlanQualityIssue(
                    kind: .mixedFileTypes,
                    message: "Bank Statements contains several file types.",
                    folderPaths: ["Bank Statements"],
                    fileIDs: [certain.id],
                    deduction: 10
                )
            ],
            didRetry: true
        )

        let reviewed = PlanQualityEvaluator.keepingCertainItems(in: plan, assessment: assessment)

        XCTAssertEqual(reviewed.suggestions.map(\.folderName), ["Bank Statements"])
        XCTAssertEqual(reviewed.unorganizedFiles.map(\.id), [uncertain.id])
        XCTAssertEqual(reviewed.qualityAssessment?.didRetry, true)
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

final class OrganizationQualityEvaluatorTests: XCTestCase {
    func testReportsOutcomesExpectationsAndCalibration() {
        let corpus = [
            OrganizationQualityCorpusCase(
                id: "case-a",
                description: "Representative folder",
                decisions: [
                    OrganizationQualityDecision(
                        sourcePath: "scan.pdf",
                        expectedDestination: "Finance/Invoices",
                        expectedRename: "2026-05-01 Acme Invoice.pdf",
                        observedDestination: "Finance/Invoices",
                        placementOutcome: .accepted,
                        observedRename: "2026-05-01 Acme Invoice.pdf",
                        renameOutcome: .accepted,
                        renameConfidence: 0.9
                    ),
                    OrganizationQualityDecision(
                        sourcePath: "clip.mov",
                        expectedDestination: "Footage",
                        observedDestination: "Media",
                        placementOutcome: .edited
                    ),
                    OrganizationQualityDecision(
                        sourcePath: "Demo.app",
                        mustKeepOriginalName: true,
                        observedRename: "Demo.app"
                    ),
                    OrganizationQualityDecision(
                        sourcePath: "unknown.bin",
                        mustKeepOriginalName: true,
                        shouldRemainUncertain: true,
                        wasSurfacedForReview: true
                    )
                ],
                manualPreviewEdits: 2,
                wasReverted: true
            )
        ]

        let report = OrganizationQualityEvaluator.evaluate(corpus)

        XCTAssertEqual(report.placementAcceptanceRate, 0.5)
        XCTAssertEqual(report.placementExpectationMatchRate ?? -1, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(report.renameAcceptanceRate, 1)
        XCTAssertEqual(report.renameEditRate, 0)
        XCTAssertEqual(report.renameRejectionRate, 0)
        XCTAssertEqual(report.renameExpectationMatchRate, 1)
        XCTAssertEqual(report.protectedNamePreservationRate, 1)
        XCTAssertEqual(report.ambiguousReviewRate, 1)
        XCTAssertEqual(report.revertRate, 1)
        XCTAssertEqual(report.manualPreviewEditsPer100Files, 50)
        XCTAssertEqual(report.calibrationBins.first?.sampleCount, 1)
        XCTAssertEqual(report.calibrationBins.first?.meanConfidence, 0.9)
        XCTAssertEqual(report.calibrationBins.first?.acceptanceRate, 1)
        XCTAssertEqual(report.calibrationError ?? -1, 0.1, accuracy: 0.0001)
    }

    func testEmptyCorpusReportsNoInventedRates() {
        let report = OrganizationQualityEvaluator.evaluate([])

        XCTAssertEqual(report.caseCount, 0)
        XCTAssertEqual(report.fileCount, 0)
        XCTAssertEqual(report.observedCaseCount, 0)
        XCTAssertEqual(report.observedFileCount, 0)
        XCTAssertNil(report.placementAcceptanceRate)
        XCTAssertNil(report.renameAcceptanceRate)
        XCTAssertNil(report.revertRate)
        XCTAssertNil(report.manualPreviewEditsPer100Files)
        XCTAssertNil(report.calibrationError)
        XCTAssertTrue(report.calibrationBins.isEmpty)
    }
}
