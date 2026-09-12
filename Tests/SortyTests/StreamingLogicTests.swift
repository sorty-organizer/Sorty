//
//  StreamingLogicTests.swift
//  SortyTests
//
//  Tests for FolderOrganizer streaming logic, insight extraction, and progress estimation
//

import Combine
import XCTest
@testable import SortyLib

@MainActor
final class StreamingLogicTests: XCTestCase {
    
    var organizer: FolderOrganizer!
    
    override func setUp() async throws {
        organizer = FolderOrganizer()
    }
    
    override func tearDown() async throws {
        organizer = nil
    }

    private func settleStreamingUpdates() async {
        await organizer.flushStreamingUpdatesForTesting()
    }

    func testBatchUpdatesPublishOnce() {
        var updateCount = 0
        let subscription = organizer.objectWillChange.sink {
            updateCount += 1
        }

        organizer.withBatchUpdates {
            organizer.progress = 0.4
            organizer.organizationStage = "Analyzing files"
            organizer.currentInsight = "Reading filenames"
        }

        XCTAssertEqual(updateCount, 1)
        withExtendedLifetime(subscription) {}
    }

    func testStateTransitionPublishesOnce() {
        var updateCount = 0
        let subscription = organizer.objectWillChange.sink {
            updateCount += 1
        }

        XCTAssertTrue(organizer.transition(to: .scanning))

        XCTAssertEqual(updateCount, 1)
        withExtendedLifetime(subscription) {}
    }
    
    // MARK: - didReceiveChunk Basic Tests
    
    func testFirstChunkSetsStreamingState() async {
        organizer.didReceiveChunk("Hello streaming")
        await settleStreamingUpdates()
        
        XCTAssertTrue(organizer.isStreaming)
        XCTAssertEqual(organizer.streamingContent, "Hello streaming")
        XCTAssertGreaterThanOrEqual(organizer.progress, 0.30)
        XCTAssertLessThanOrEqual(organizer.progress, 0.32)
    }
    
    func testMultipleChunksAccumulate() async {
        organizer.didReceiveChunk("chunk1 ")
        organizer.didReceiveChunk("chunk2 ")
        organizer.didReceiveChunk("chunk3")
        await settleStreamingUpdates()
        
        XCTAssertEqual(organizer.streamingContent, "chunk1 chunk2 chunk3")
    }

    func testLiveInsightsToggleDisablesInsightAndPreviewUpdates() async {
        organizer.setLiveInsightsEnabled(false)
        organizer.didReceiveChunk("creating folder: 'Receipts' for report.pdf")

        XCTAssertTrue(organizer.isStreaming)
        XCTAssertEqual(organizer.streamingContent, "creating folder: 'Receipts' for report.pdf")
        XCTAssertTrue(organizer.currentInsight.isEmpty)
        XCTAssertTrue(organizer.insightHistory.isEmpty)
        XCTAssertTrue(organizer.truncatedDisplayStreamingContent.isEmpty)
    }

    func testLiveInsightsToggleReEnablesBackfillFromCurrentStream() async {
        organizer.setLiveInsightsEnabled(false)
        organizer.didReceiveChunk("creating folder: 'Receipts' for report.pdf")

        organizer.setLiveInsightsEnabled(true)
        await settleStreamingUpdates()

        XCTAssertFalse(organizer.truncatedDisplayStreamingContent.isEmpty)
    }
    
    func testProgressIncreasesWithContentLength() async {
        organizer.scannedFileCount = 10
        
        organizer.didReceiveChunk("x")
        await settleStreamingUpdates()
        let initialProgress = organizer.progress
        
        let longContent = String(repeating: "analyzing files and sorting them into folders. ", count: 50)
        organizer.didReceiveChunk(longContent)
        await settleStreamingUpdates()
        let laterProgress = organizer.progress
        
        XCTAssertGreaterThanOrEqual(laterProgress, initialProgress)
    }
    
    func testProgressDoesNotExceedCap() async {
        organizer.scannedFileCount = 1
        
        let hugeContent = String(repeating: "A", count: 50000)
        organizer.didReceiveChunk(hugeContent)
        await settleStreamingUpdates()
        
        XCTAssertLessThanOrEqual(organizer.progress, 0.82)
    }

    func testStreamingProgressDoesNotAdvanceWithoutNewContent() async {
        organizer.didReceiveChunk("first chunk")
        await settleStreamingUpdates()
        let progressAfterChunk = organizer.progress

        await Task.yield()

        XCTAssertEqual(organizer.progress, progressAfterChunk)
    }

    func testMeasuredWorkProgressUsesConcreteCompletedCount() {
        let progress = MeasuredWorkProgress(completed: 3, total: 12)

        XCTAssertEqual(progress.percentage, 0.25)
    }
    
    func testDidCompleteSetsStreamingFalse() async {
        organizer.didReceiveChunk("some content")
        await settleStreamingUpdates()
        XCTAssertTrue(organizer.isStreaming)
        
        organizer.didComplete(content: "some content")
        XCTAssertFalse(organizer.isStreaming)
    }

    func testDidCompleteStoresFinalPayloadSynchronously() {
        organizer.didComplete(content: "{\"folders\":[]}")

        XCTAssertEqual(organizer.streamingContent, "{\"folders\":[]}")
        XCTAssertFalse(organizer.isStreaming)
    }

    func testLargeStreamRetentionAndPresentationAreBounded() {
        let content = String(repeating: "x", count: 400_000)

        organizer.didComplete(content: content)

        XCTAssertLessThanOrEqual(organizer.streamingContent.count, 256_000)
        XCTAssertLessThanOrEqual(organizer.displayStreamingContent.count, 48_000)
        XCTAssertLessThanOrEqual(organizer.truncatedDisplayStreamingContent.count, 1_003)
    }

    func testChunkRetentionBoundsUTF8BytesWithoutBreakingUnicode() {
        let chunk = String(repeating: "🗂️", count: 50_000)

        organizer.didReceiveChunk(chunk)

        XCTAssertLessThanOrEqual(organizer.streamingContent.utf8.count, 256_000)
        XCTAssertFalse(organizer.streamingContent.contains("�"))
    }

    func testChunkAfterCompletedStreamStartsFreshSession() async {
        organizer.didReceiveChunk("first stream")
        await settleStreamingUpdates()
        organizer.didComplete(content: "first stream")

        organizer.progress = 0.87
        organizer.organizationStage = "Too many folders, retrying..."

        organizer.didReceiveChunk("retry stream")
        await settleStreamingUpdates()

        XCTAssertTrue(organizer.isStreaming)
        XCTAssertEqual(organizer.organizationStage, "Sorty is organizing your files...")
        XCTAssertEqual(organizer.streamingContent, "retry stream")
        XCTAssertLessThan(organizer.progress, 0.5)
    }

    func testCancelClearsStreamingPresentationState() {
        organizer.didReceiveChunk(
            #"{"folders":[{"name":"Archives","files":[{"filename":"old.zip"}]}]}"#
        )

        XCTAssertFalse(organizer.streamingContent.isEmpty)
        XCTAssertFalse(organizer.displayStreamingContent.isEmpty)

        organizer.cancel()

        XCTAssertEqual(organizer.state, .idle)
        XCTAssertTrue(organizer.streamingContent.isEmpty)
        XCTAssertTrue(organizer.displayStreamingContent.isEmpty)
        XCTAssertTrue(organizer.truncatedDisplayStreamingContent.isEmpty)
        XCTAssertFalse(organizer.isStreaming)
    }
    
    // MARK: - Insight Extraction via Streaming
    
    func testFileInsightExtracted() async {
        let content = String(repeating: " ", count: 100) + "analyzing document: 'report.pdf' for organization"
        organizer.didReceiveChunk(content)
        organizer.didReceiveChunk(" more content here to trigger throttle window")
        await settleStreamingUpdates()
        
        let hasFileInsight = organizer.insightHistory.contains { $0.category == .file }
        let currentMentionsFile = organizer.currentInsight.contains("report.pdf")
        
        XCTAssertTrue(hasFileInsight || currentMentionsFile,
                       "Should extract file insight from content mentioning 'report.pdf'")
    }
    
    func testFolderInsightExtracted() async {
        let content = String(repeating: " ", count: 100) + "creating folder: 'Documents' for PDFs"
        organizer.didReceiveChunk(content)
        organizer.didReceiveChunk(" additional content to pass throttle")
        await settleStreamingUpdates()
        
        let hasFolderInsight = organizer.insightHistory.contains { $0.category == .folder }
        let currentMentionsFolder = organizer.currentInsight.contains("Documents")
        
        XCTAssertTrue(hasFolderInsight || currentMentionsFolder,
                       "Should extract folder insight from content mentioning 'Documents'")
    }
    
    func testConstraintInsightExtracted() async {
        let content = String(repeating: " ", count: 100) + "considering: the user prefers flat structure for small projects"
        organizer.didReceiveChunk(content)
        organizer.didReceiveChunk(" more text to allow throttle window to pass")
        await settleStreamingUpdates()
        
        let hasConstraintInsight = organizer.insightHistory.contains { $0.category == .constraint }
        let currentHasText = organizer.currentInsight.contains("flat structure")
        
        XCTAssertTrue(hasConstraintInsight || currentHasText,
                       "Should extract constraint insight")
    }
    
    func testDecisionInsightExtracted() async {
        let content = String(repeating: " ", count: 100) + "will move these files into the Archives directory for safekeeping"
        organizer.didReceiveChunk(content)
        organizer.didReceiveChunk(" more text padding to get past throttle limit")
        await settleStreamingUpdates()
        
        let hasDecisionInsight = organizer.insightHistory.contains { $0.category == .decision }
        let currentHasDecision = organizer.currentInsight.contains("Archives")
        
        XCTAssertTrue(hasDecisionInsight || currentHasDecision,
                       "Should extract decision insight")
    }
    
    func testJSONContentSkippedByGeneralInsight() async {
        let jsonContent = String(repeating: " ", count: 100) +
            """
            {"folders": [{"name": "Images"}]}. This is pure JSON that should be skipped by general insight.
            """
        organizer.didReceiveChunk(jsonContent)
        organizer.didReceiveChunk(" extra padding for throttle")
        await settleStreamingUpdates()
        
        let generalInsights = organizer.insightHistory.filter { $0.category == .general }
        for insight in generalInsights {
            XCTAssertFalse(insight.text.contains("{"), "General insight should not contain JSON braces")
            XCTAssertFalse(insight.text.contains("}"), "General insight should not contain JSON braces")
        }
    }
    
    // MARK: - Insight History Limit
    
    func testInsightHistoryLimitedToFive() async {
        for i in 0..<8 {
            let content = String(repeating: " ", count: 100) +
                "creating folder: 'Folder\(i)' for files number \(i)"
            organizer.streamingContent = ""
            organizer.didReceiveChunk(content)
            organizer.didReceiveChunk(" padding \(i)")
            await settleStreamingUpdates()
        }
        
        XCTAssertLessThanOrEqual(organizer.insightHistory.count, 5,
                                  "Insight history should be limited to 5 entries")
    }
    
    // MARK: - Insights Cache
    
    func testGetCachedInsightsReturnsData() async {
        let content = String(repeating: " ", count: 100) + "analyzing document: 'test.pdf'"
        organizer.didReceiveChunk(content)
        organizer.didReceiveChunk(" more")
        await settleStreamingUpdates()
        
        let cached = organizer.getCachedInsights()
        XCTAssertEqual(cached.current, organizer.currentInsight)
    }
    
    func testInvalidateInsightsCache() {
        organizer.invalidateInsightsCache()
        let cached = organizer.getCachedInsights()
        XCTAssertEqual(cached.current, organizer.currentInsight)
        XCTAssertEqual(cached.history.count, organizer.insightHistory.count)
    }

    func testProgressLineInvalidatesOlderExtractedInsightCache() async {
        let content = String(repeating: " ", count: 100) + "analyzing document: 'test.pdf'"
        organizer.didReceiveChunk(content)
        organizer.didReceiveChunk(" more")
        await settleStreamingUpdates()

        organizer.didReceiveChunk("\n>> decision: Grouping project documents together\n")

        let cached = organizer.getCachedInsights()
        XCTAssertEqual(cached.current, "Grouping project documents together")
        XCTAssertEqual(cached.history.last?.text, "Grouping project documents together")
    }

    func testStreamingDisplayPreservesCharacterBoundariesAndPreviewEllipsis() async {
        let character = "e\u{301}"
        for count in [999, 1_000, 1_001, 48_000, 48_001] {
            organizer = FolderOrganizer()
            let content = String(repeating: character, count: count)
            organizer.didReceiveChunk(content)
            await settleStreamingUpdates()

            XCTAssertEqual(organizer.displayStreamingContent, String(content.suffix(48_000)))
            XCTAssertEqual(
                organizer.truncatedDisplayStreamingContent,
                (count > 1_000 ? "..." : "") + String(content.suffix(1_000))
            )
        }
    }

    func testLongStreamProgressKeepsCapWithAndWithoutLiveInsights() async {
        for insightsEnabled in [true, false] {
            organizer = FolderOrganizer()
            organizer.liveInsightsEnabled = insightsEnabled
            organizer.didReceiveChunk(String(repeating: "x", count: 100_000))
            await settleStreamingUpdates()
            XCTAssertEqual(organizer.progress, 0.80, accuracy: 0.0001)
            organizer.didReceiveChunk("more")
            await settleStreamingUpdates()
            XCTAssertEqual(organizer.progress, 0.80, accuracy: 0.0001)
        }
    }

    func testProgressLineParserRecoversAfterLongIrrelevantLine() {
        organizer.didReceiveChunk(String(repeating: "x", count: 100_000))
        organizer.didReceiveChunk("\n>> decision: Grouping project documents together\n")

        XCTAssertEqual(organizer.currentInsight, "Grouping project documents together")
        XCTAssertEqual(organizer.insightHistory.last?.text, "Grouping project documents together")
    }

    func testProgressLineParserPreservesChunkedPrefixAndContent() {
        organizer.didReceiveChunk("  >")
        organizer.didReceiveChunk("> file: Assigning report.pdf")
        organizer.didReceiveChunk(" to Reports\n")

        XCTAssertEqual(organizer.currentInsight, "Assigning report.pdf to Reports")
        XCTAssertEqual(organizer.insightHistory.last?.category, .file)
    }
    
    // MARK: - Organization Stage Updates
    
    func testOrganizationStageSetOnFirstChunk() async {
        organizer.didReceiveChunk("first chunk of streaming data")
        
        XCTAssertEqual(organizer.organizationStage, "Sorty is organizing your files...")
    }

    func testOrganizationStageUsesRenameOnlyWorkflowOnFirstChunk() async throws {
        try await organizer.configure(with: AIConfig(mode: .renameOnly))

        organizer.didReceiveChunk("first chunk of streaming data")

        XCTAssertEqual(organizer.organizationStage, "Sorty is preparing rename suggestions...")
    }

    func testOrganizationStageUsesOrganizeAndRenameWorkflowOnFirstChunk() async throws {
        try await organizer.configure(with: AIConfig(mode: .organizeAndRename))

        organizer.didReceiveChunk("first chunk of streaming data")

        XCTAssertEqual(organizer.organizationStage, "Sorty is organizing and renaming your files...")
    }

    func testReadyCueCapturedAsGeneralInsight() async {
        organizer.didReceiveChunk(">> general: Ready to output organization structure.\n")

        XCTAssertTrue(
            organizer.insightHistory.contains {
                $0.category == .general && $0.text.contains("Ready to output organization structure")
            }
        )
    }

    func testProgressLineSkipsLowSignalAssignmentFolderNames() async {
        organizer.didReceiveChunk(">> file: Assigning assets2.m4a to name\n")

        XCTAssertFalse(
            organizer.insightHistory.contains { $0.text.contains("assets2.m4a") && $0.text.contains("to name") }
        )
    }

    func testRegenerateWithModelWhileOrganizingRestartsAnalysis() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let fileURL = tempDirectory.appendingPathComponent("notes.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let config = AIConfig(
            provider: .openAI,
            apiURL: "https://api.openai.com",
            apiKey: "test-key",
            model: "gpt-5.4"
        )
        try await organizer.configure(with: config)

        let mockClient = RestartableStreamingMockClient(config: config)
        organizer.setAIClientForTesting(mockClient)

        let initialRun = Task {
            try? await organizer.organize(directory: tempDirectory)
        }

        await mockClient.waitForAnalyzeCallCount(1)

        let initialAnalyzeCount = await mockClient.currentAnalyzeCallCount()
        XCTAssertEqual(initialAnalyzeCount, 1)

        organizer.showTimeoutMessage = true

        try await organizer.regenerateWithModel(provider: .openAI, model: "gpt-5-mini")
        _ = await initialRun.result

        let finalAnalyzeCount = await mockClient.currentAnalyzeCallCount()
        XCTAssertEqual(finalAnalyzeCount, 2)
        XCTAssertEqual(organizer.state, .ready)
        XCTAssertEqual(organizer.organizationStage, "Ready!")
        XCTAssertFalse(organizer.showTimeoutMessage)
        XCTAssertNotNil(organizer.currentPlan)
    }

    // MARK: - OrganizationProgress Struct Tests
    
    func testOrganizationProgressPercentage() {
        let progress = OrganizationProgress(phase: .aiProcessing, current: 50, total: 100, detail: nil)
        XCTAssertEqual(progress.percentage, 0.5)
    }
    
    func testOrganizationProgressZeroTotal() {
        let progress = OrganizationProgress(phase: .scanning, current: 0, total: 0, detail: nil)
        XCTAssertEqual(progress.percentage, 0)
    }
    
    func testOrganizationProgressPhaseWeights() {
        XCTAssertEqual(OrganizationProgress(phase: .scanning, current: 0, total: 1, detail: nil).phaseWeight, 0.15)
        XCTAssertEqual(OrganizationProgress(phase: .aiProcessing, current: 0, total: 1, detail: nil).phaseWeight, 0.50)
        XCTAssertEqual(OrganizationProgress(phase: .complete, current: 0, total: 1, detail: nil).phaseWeight, 1.0)
    }
    
    func testOrganizationProgressPhaseBaseProgress() {
        XCTAssertEqual(OrganizationProgress(phase: .scanning, current: 0, total: 1, detail: nil).phaseBaseProgress, 0.0)
        XCTAssertEqual(OrganizationProgress(phase: .aiProcessing, current: 0, total: 1, detail: nil).phaseBaseProgress, 0.30)
        XCTAssertEqual(OrganizationProgress(phase: .complete, current: 1, total: 1, detail: nil).overallProgress, 1.0)
    }
    
    // MARK: - AIInsight Model Tests
    
    func testAIInsightCreation() {
        let insight = AIInsight(text: "Analyzing report.pdf", category: .file, filePath: "/path/report.pdf")
        XCTAssertEqual(insight.text, "Analyzing report.pdf")
        XCTAssertEqual(insight.category, .file)
        XCTAssertEqual(insight.filePath, "/path/report.pdf")
    }
    
    func testAIInsightCategoryIcons() {
        XCTAssertEqual(AIInsight.Category.file.icon, "doc")
        XCTAssertEqual(AIInsight.Category.folder.icon, "folder")
        XCTAssertEqual(AIInsight.Category.constraint.icon, "exclamationmark.triangle")
        XCTAssertEqual(AIInsight.Category.decision.icon, "arrow.right")
        XCTAssertEqual(AIInsight.Category.general.icon, "brain")
    }
    
    func testAIInsightCategoryColors() {
        XCTAssertEqual(AIInsight.Category.file.color, "blue")
        XCTAssertEqual(AIInsight.Category.folder.color, "orange")
        XCTAssertEqual(AIInsight.Category.constraint.color, "yellow")
        XCTAssertEqual(AIInsight.Category.decision.color, "green")
        XCTAssertEqual(AIInsight.Category.general.color, "secondary")
    }
    
    // MARK: - State Transition Tests
    
    func testValidStateTransitions() {
        XCTAssertTrue(OrganizationState.canTransition(from: .idle, to: .scanning))
        XCTAssertTrue(OrganizationState.canTransition(from: .scanning, to: .organizing))
        XCTAssertTrue(OrganizationState.canTransition(from: .organizing, to: .ready))
        XCTAssertTrue(OrganizationState.canTransition(from: .ready, to: .applying))
        XCTAssertTrue(OrganizationState.canTransition(from: .applying, to: .completed))
    }
    
    func testInvalidStateTransitions() {
        XCTAssertFalse(OrganizationState.canTransition(from: .idle, to: .applying))
        XCTAssertFalse(OrganizationState.canTransition(from: .completed, to: .applying))
        XCTAssertFalse(OrganizationState.canTransition(from: .idle, to: .ready))
    }
    
    func testTransitionMethodUpdatesState() {
        XCTAssertEqual(organizer.state, .idle)
        
        let result = organizer.transition(to: .scanning)
        XCTAssertTrue(result)
        XCTAssertEqual(organizer.state, .scanning)
    }
    
    func testInvalidTransitionDoesNotChangeState() {
        XCTAssertEqual(organizer.state, .idle)
        
        let result = organizer.transition(to: .applying)
        XCTAssertFalse(result)
        XCTAssertEqual(organizer.state, .idle)
    }
    
    func testForceTransitionBypassesValidation() {
        XCTAssertEqual(organizer.state, .idle)
        
        let result = organizer.transition(to: .applying, force: true)
        XCTAssertTrue(result)
        XCTAssertEqual(organizer.state, .applying)
    }
    
    func testResetToIdleState() {
        _ = organizer.transition(to: .scanning)
        XCTAssertEqual(organizer.state, .scanning)
        
        organizer.resetToIdleState()
        XCTAssertEqual(organizer.state, .idle)
    }
}

actor RestartableStreamingMockClient: AIClientProtocol {
    let config: AIConfig
    @MainActor weak var streamingDelegate: StreamingDelegate?
    private(set) var analyzeCallCount = 0
    private let firstCallBlocker = AsyncStream<Void> { _ in }
    private var analyzeCallCountWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(config: AIConfig) {
        self.config = config
    }

    func currentAnalyzeCallCount() -> Int {
        analyzeCallCount
    }

    func waitForAnalyzeCallCount(_ target: Int) async {
        guard analyzeCallCount < target else { return }

        await withCheckedContinuation { continuation in
            analyzeCallCountWaiters.append((target, continuation))
        }
    }

    func analyze(
        files: [FileItem],
        customInstructions: String?,
        personaPrompt: String?,
        temperature: Double?
    ) async throws -> OrganizationPlan {
        analyzeCallCount += 1
        let callNumber = analyzeCallCount
        let readyWaiters = analyzeCallCountWaiters.filter { $0.target <= analyzeCallCount }
        analyzeCallCountWaiters.removeAll { $0.target <= analyzeCallCount }
        readyWaiters.forEach { $0.continuation.resume() }

        if callNumber == 1 {
            for await _ in firstCallBlocker { }
            try Task.checkCancellation()
        }

        return OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Sorted", files: files)],
            notes: "call \(callNumber)"
        )
    }

    func analyzeWithImages(
        files: [FileItem],
        imageData: [String: Data],
        customInstructions: String?,
        personaPrompt: String?,
        temperature: Double?
    ) async throws -> OrganizationPlan {
        try await analyze(
            files: files,
            customInstructions: customInstructions,
            personaPrompt: personaPrompt,
            temperature: temperature
        )
    }

    func generateText(prompt: String, systemPrompt: String?) async throws -> String {
        "ok"
    }

    func checkHealth() async throws {}
}
