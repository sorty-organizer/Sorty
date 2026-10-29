//
//  FolderOrganizer.swift
//  Sorty
//
//  Main orchestrator for organization workflow with streaming support
//  Fixed: Auto-start prevention, reliable cancellation, and accurate progress tracking
//

import Foundation
import SwiftUI
import Combine
import SortyLearnings
import SortyFileSystem
import SortyModels
import SortyAI
import SortyFS

actor RevertOperationTracker {
    private var activeEntryIDs: Set<UUID> = []
    private var activePaths: Set<String> = []

    func begin(entryIDs: [UUID], path: String) -> Bool {
        let normalizedIDs = Set(entryIDs)
        guard activePaths.contains(path) == false,
              activeEntryIDs.isDisjoint(with: normalizedIDs) else {
            return false
        }

        activePaths.insert(path)
        activeEntryIDs.formUnion(normalizedIDs)
        return true
    }

    func end(entryIDs: [UUID], path: String) {
        activePaths.remove(path)
        for id in entryIDs {
            activeEntryIDs.remove(id)
        }
    }
}

@MainActor
public final class RunningOrganizationActivity: ObservableObject {
    @Published public fileprivate(set) var count = 0

    public var isRunning: Bool {
        count > 0
    }
}

@MainActor
public class FolderOrganizer: ObservableObject, StreamingDelegate {
    private static let maxPreviewVersions = 5
    actor LargeFolderPlanAccumulator {
        private var plan: OrganizationPlan

        init(plan: OrganizationPlan = OrganizationPlan()) {
            self.plan = plan
        }

        func merge(_ incoming: OrganizationPlan) -> [String] {
            FolderOrganizer.mergeLargeFolderBatch(incoming, into: &plan)
            return FolderOrganizer.destinationTaxonomy(in: plan, limit: 80)
        }

        func result() -> OrganizationPlan {
            plan
        }
    }

    /// Coalesces per-file apply progress before it schedules a main-actor update.
    final class ApplyProgressThrottle: @unchecked Sendable {
        private let lock = NSLock()
        private var lastReportedPercent: Double = -1

        nonisolated func shouldReport(percent: Double) -> Bool {
            lock.withLock {
                guard percent >= 1.0 || lastReportedPercent < 0
                    || percent - lastReportedPercent >= 0.01 else { return false }
                lastReportedPercent = percent
                return true
            }
        }
    }

    struct OrganizationResumeCheckpoint {
        let files: [FileItem]
        let directory: URL
        let instructions: String
        let personaPrompt: String?
        let imagePayload: [String: Data]
        let visionFiles: [FileItem]
        let temperature: Double?
        let mode: OrganizationMode
        var completedPlans: [OrganizationPlan]
        var nextBatchIndex: Int
    }

    private static var runningOrganizerIDs: Set<ObjectIdentifier> = []
    @MainActor public static let runningActivity = RunningOrganizationActivity()

    public static var runningOrganizationCount: Int {
        runningOrganizerIDs.count
    }

    public static var hasRunningOrganizations: Bool {
        !runningOrganizerIDs.isEmpty
    }

    private nonisolated static func isTrackedRunningState(_ state: OrganizationState) -> Bool {
        switch state {
        case .scanning, .organizing, .applying:
            return true
        case .idle, .ready, .completed, .error:
            return false
        }
    }

    private var isRegisteredAsRunningOrganizer = false

    struct PresentationState {
        var state: OrganizationState = .idle
        var progress: Double = 0
        var currentPlan: OrganizationPlan?
        var planHistory: [OrganizationPlan] = []
        var errorMessage: String?
        var pinsCompletionView = false
        var completionFailureAction: CompletionFailureAction?
        var completionFailureEntry: OrganizationHistoryEntry?
        var displayStreamingContent = ""
        var truncatedDisplayStreamingContent = ""
        var streamFileIDTable: [Int: FileItem] = [:]
        var organizationStage = ""
        var isStreaming = false
        var measuredWorkProgress: MeasuredWorkProgress?
        var visionAnalysisSummary: VisionAnalysisSummary?
        var aiAnalysisActivity: AIAnalysisActivity = .none
        var currentInsight = ""
        var insightHistory: [AIInsight] = []
        var elapsedTime: TimeInterval = 0
        var showTimeoutMessage = false
        var currentDirectory: URL?
        var blockingExclusionRule: ExclusionRule?
        var detectedDuplicates: [DuplicateGroup] = []
        var scannedFiles: [FileItem] = []
    }

    private var presentationState = PresentationState()
    private var batchUpdateDepth = 0
    private let stateSubject = CurrentValueSubject<OrganizationState, Never>(.idle)

    public var statePublisher: AnyPublisher<OrganizationState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    public var state: OrganizationState {
        get { presentationState.state }
        set {
            withBatchUpdates {
                let oldValue = presentationState.state
                updatePresentation { $0.state = newValue }

                // Request user attention for any error state, and drop the
                // completion pin so a stale pin cannot keep masking the error UI
                // (e.g. a menu apply from history while the window view is
                // unmounted). A fresh .ready is a new review, so it unpins too.
                if case .error = newValue {
                    OrganizerServices.attentionRequester()
                    pinsCompletionView = false
                } else {
                    // Leaving .error ends the completion view's failure
                    // presentation, so a remount cannot restore a stale card.
                    completionFailureAction = nil
                    completionFailureEntry = nil
                    if case .ready = newValue {
                        pinsCompletionView = false
                    }
                }

                if state != .organizing {
                    aiAnalysisActivity = .none
                }

                syncRunningOrganizationRegistrationIfNeeded(from: oldValue, to: state)
                stateSubject.send(state)
            }
        }
    }
    public var windowSessionID: UUID?
    /// When true, the organizer snapshots its manual session (selected folder,
    /// in-progress marker, ready/completed plan) so a restart forced by macOS
    /// — for example after enabling Full Disk Access — can pick up where the
    /// user left off. The automation organizer leaves this off so watched-folder
    /// work keeps using WatcherPendingWork.json instead of clobbering this file.
    public var isManualSessionPersistenceEnabled = false
    /// Test hook: when set, manual-session reads/writes use this URL instead
    /// of Application Support so tests never touch real user state.
    public var manualSessionURLForTesting: URL?
    var cachedManualSessionDirectoryPath: String?
    var cachedManualSessionBookmark: Data?
    var lastManualSessionFingerprintByURL: [URL: Data] = [:]
    var manualSessionGeneration = 0
    var restoredManualSessionScopedURL: URL?
    public var progress: Double {
        get { presentationState.progress }
        set { updatePresentation { $0.progress = newValue } }
    }
    public var currentPlan: OrganizationPlan? {
        get { presentationState.currentPlan }
        set {
            if newValue?.id != presentationState.currentPlan?.id {
                currentPlanBaseURL = newValue == nil ? nil : currentDirectory?.standardizedFileURL
                // A replaced plan must not inherit a watched-review mode
                // override that belonged to the previous plan.
                preparedPlanModeOverride = nil
            }
            updatePresentation { $0.currentPlan = newValue }
        }
    }
    var currentPlanBaseURL: URL?
    var preparedPlanModeOverride: OrganizationMode?
    public var planHistory: [OrganizationPlan] {
        get { presentationState.planHistory }
        set { updatePresentation { $0.planHistory = newValue } }
    }
    public var errorMessage: String? {
        get { presentationState.errorMessage }
        set { updatePresentation { $0.errorMessage = newValue } }
    }
    @Published public var customInstructions: String = "" {
        didSet {
            currentRunInstructions = customInstructions
        }
    }
    var currentRunInstructions = ""
    var modelExcludedCurrentRun = false
    var currentRunLearningExcluded: Bool {
        modelExcludedCurrentRun
            || LearningsManager.instructionsExcludeCurrentRun(currentRunInstructions)
    }

    func handleLearningToolCall(
        from plan: OrganizationPlan,
        source: OrganizationEntrySource,
        folderPath: String
    ) {
        let toolCall = plan.learningToolCall
        let wasExcluded = toolCall?.excludesCurrentRun == true
        let reviewTarget: LearningExclusionReviewTarget

        if source == .watchedFolder {
            reviewTarget = .watchedFolder
        } else if toolCall?.source == "persona" {
            reviewTarget = .persona
        } else {
            reviewTarget = .instructions
        }

        if wasExcluded {
            modelExcludedCurrentRun = true
            learningsObserver?.excludeCurrentRun(folderPath: folderPath)
        }

        guard let concern = LearningExclusionMonitor.shared.recordDecision(
            wasExcluded: wasExcluded,
            reviewTarget: reviewTarget
        ) else { return }

        OrganizerServices.learningConcernReporter(concern, folderPath)
    }

    /// When true, callers (such as OrganizeView) should keep showing the OrganizationCompleteView
    /// even if `state` momentarily transitions through `.applying`/`.idle` during an in-place
    /// undo or redo action performed from that screen.
    public var pinsCompletionView: Bool {
        get { presentationState.pinsCompletionView }
        set { updatePresentation { $0.pinsCompletionView = newValue } }
    }

    /// The undo/redo retry that produced the completion view's current failure
    /// card. Stored on the organizer instead of only in the view so remounting
    /// `OrganizationCompleteView` (for example after visiting History) still
    /// shows the failure and its retry button. Cleared automatically when the
    /// organizer leaves `.error` for a running/`.ready` state.
    public enum CompletionFailureAction: String, Sendable {
        case undo
        case redo
    }

    public var completionFailureAction: CompletionFailureAction? {
        get { presentationState.completionFailureAction }
        set { updatePresentation { $0.completionFailureAction = newValue } }
    }

    /// The history entry a failed completion-card redo was retrying, kept so
    /// the retry still targets the same entry after the view remounts.
    public var completionFailureEntry: OrganizationHistoryEntry? {
        get { presentationState.completionFailureEntry }
        set { updatePresentation { $0.completionFailureEntry = newValue } }
    }
    
    // Proactive AI Validation
    @Published public var isAIConfigured: Bool = false

    // Streaming support
    /// Internal backing storage for streaming content (not @Published to avoid high-frequency redraws)
    public var streamingContent: String = ""
    public var displayStreamingContent: String {
        get { presentationState.displayStreamingContent }
        set { updatePresentation { $0.displayStreamingContent = newValue } }
    }
    public var truncatedDisplayStreamingContent: String {
        get { presentationState.truncatedDisplayStreamingContent }
        set { updatePresentation { $0.truncatedDisplayStreamingContent = newValue } }
    }
    /// ID -> file mapping for the batch currently shown in the live stream.
    public internal(set) var streamFileIDTable: [Int: FileItem] {
        get { presentationState.streamFileIDTable }
        set { updatePresentation { $0.streamFileIDTable = newValue } }
    }
    public var organizationStage: String {
        get { presentationState.organizationStage }
        set { updatePresentation { $0.organizationStage = newValue } }
    }
    public var isStreaming: Bool {
        get { presentationState.isStreaming }
        set { updatePresentation { $0.isStreaming = newValue } }
    }
    @Published public var liveInsightsEnabled: Bool = true
    @Published public var deepScanProgress: (current: Int, total: Int)?
    public internal(set) var measuredWorkProgress: MeasuredWorkProgress? {
        get { presentationState.measuredWorkProgress }
        set { updatePresentation { $0.measuredWorkProgress = newValue } }
    }
    public var visionAnalysisSummary: VisionAnalysisSummary? {
        get { presentationState.visionAnalysisSummary }
        set { updatePresentation { $0.visionAnalysisSummary = newValue } }
    }
    /// What the AI analysis phase is actually doing right now, so the UI can
    /// label the wait accurately. Reset whenever `state` leaves `.organizing`.
    public internal(set) var aiAnalysisActivity: AIAnalysisActivity {
        get { presentationState.aiAnalysisActivity }
        set { updatePresentation { $0.aiAnalysisActivity = newValue } }
    }
    
    // Throttle timer for display content updates (prevents layout thrashing)
    var displayUpdateTask: Task<Void, Never>?
    var lastDisplayUpdate: Date = .distantPast
    var retainedStreamingByteCount = 0
    var streamingContentRevision: UInt64 = 0
    var batchStreamChannels: [Int: BatchStreamChannel] = [:]
    var visibleBatchStreamIndex: Int?
    let displayUpdateInterval: TimeInterval = 0.55 // Slightly slower cadence to reduce dropped frames during generation
    nonisolated static let streamPreviewCharacterLimit = 1000
    nonisolated static let streamUIPresentationCharacterLimit = 48_000
    nonisolated static let streamRetentionByteLimit = 256_000
    nonisolated static let streamRetentionTrimByteSlack = 32_000
    nonisolated static let deepScanFileLimit = 2_000
    nonisolated static let organizeAnalysisBatchSize = 350
    nonisolated static let renameAnalysisBatchSize = 120
    nonisolated static let analysisBatchConcurrency = 2
    nonisolated static let minimumAdaptiveAnalysisBatchSize = 8
    nonisolated private static let previewVersionFileLimit = 20_000
    nonisolated static let maximumPreparedVisionBytes = 32 * 1_024 * 1_024
    nonisolated static let assignmentDestinationRegex =
        try? NSRegularExpression(
            pattern: #"\b(?:assigning|moving|mapping)\b.+?\bto\b\s+(.+)$"#,
            options: [.caseInsensitive]
        )
    nonisolated static let blockedLiveFolderNames: Set<String> = [
        "a", "an", "and", "as", "at", "be", "by", "for", "from", "gets", "in", "into",
        "is", "it", "name", "of", "on", "or", "that", "the", "this", "to", "value",
        "with", "folder", "folders", "file", "files", "filename", "json", "reasoning",
        "notes", "unorganized", "data", "content", "description", "type", "rule_id",
        "semantic_tags", "suggested_name", "rename_reason", "tags", "comment", "true",
        "false", "null", LearningToolCall.excludeCurrentRunToolName
    ]
    nonisolated static let quotedFileMentionRegex =
        try? NSRegularExpression(
            pattern: #"(?:\"|')([^\"'\n]{2,220}\.[a-zA-Z0-9]{1,12})(?:\"|')"#,
            options: []
        )
    nonisolated static let bareFileMentionRegex =
        try? NSRegularExpression(
            pattern: #"\b([A-Za-z0-9_\-\(\)]+\.[a-zA-Z0-9]{1,12})\b"#,
            options: []
        )
    
    // AI reasoning insights - extracted from streaming content
    public var currentInsight: String {
        get { presentationState.currentInsight }
        set { updatePresentation { $0.currentInsight = newValue } }
    }
    public var insightHistory: [AIInsight] {
        get { presentationState.insightHistory }
        set { updatePresentation { $0.insightHistory = newValue } }
    }
    var lastInsightExtraction: Date = .distantPast
    let insightExtractionInterval: TimeInterval = 0.9 // Lower extraction frequency to cut parser pressure while streaming
    let insightExtractor = AIInsightExtractor()
    var insightExtractionTask: Task<Void, Never>?
    
    // Progress line streaming support
    var progressLineBuffer: String = ""
    var discardsCurrentProgressLine = false
    var receivedProgressLines: Bool = false
    var jsonStartedInStream: Bool = false
    var progressLineCount: Int = 0
    let progressLineLimit = 3
    
    // MARK: - AI Insights Cache
    
    /// Cache for pre-computed AI insights to avoid re-parsing during UI rendering
    var insightsCache: InsightsCache?
    
    /// Structure to hold cached insights data
    struct InsightsCache {
        let streamingContentRevision: UInt64
        let retainedStreamingByteCount: Int
        let insights: [AIInsight]
        let currentInsight: String
        let timestamp: Date
        
        var isValid: Bool {
            Date().timeIntervalSince(timestamp) < 2.0 // Cache valid for 2 seconds
        }
    }

    // Timeout messaging
    public var elapsedTime: TimeInterval {
        get { presentationState.elapsedTime }
        set { updatePresentation { $0.elapsedTime = newValue } }
    }
    public var showTimeoutMessage: Bool {
        get { presentationState.showTimeoutMessage }
        set { updatePresentation { $0.showTimeoutMessage = newValue } }
    }
    var startTime: Date?
    var timeoutTask: Task<Void, Never>?
    var suppressCancellationReset = false
    var resumeCheckpoint: OrganizationResumeCheckpoint?
    /// Counts validation/quality/exclusion retries in the current run so each
    /// one backs off with a bounded, jittered delay instead of hot-looping
    /// the provider with full-prompt resends.
    var retryAttemptCount = 0
    var preparedVisionAttachmentNames: Set<String> = []
    var visionPreparationFailureCount = 0
    var visionPreparationByteLimitSkipCount = 0

    public var canResumeOrganization: Bool {
        guard resumeCheckpoint != nil,
              case .error(let error) = state else { return false }
        return Self.isTimeoutFailure(error)
    }
    
    // MARK: - Batch Update Mechanism
    
    /// Publishes one invalidation for a related set of presentation changes.
    @MainActor
    public func withBatchUpdates(_ updates: () -> Void) {
        beginBatchUpdates()
        defer { endBatchUpdates() }
        updates()
    }
    
    private func updatePresentation(_ update: (inout PresentationState) -> Void) {
        if batchUpdateDepth == 0 {
            objectWillChange.send()
        }
        update(&presentationState)
    }

    private func beginBatchUpdates() {
        if batchUpdateDepth == 0 {
            objectWillChange.send()
        }
        batchUpdateDepth += 1
    }

    private func endBatchUpdates() {
        batchUpdateDepth -= 1
    }
    
    // MARK: - State Transition Validation
    
    /// Validates and performs a state transition
    /// - Parameters:
    ///   - newState: The target state to transition to
    ///   - force: If true, bypasses validation (use with caution)
    /// - Returns: True if the transition was successful
    @MainActor
    @discardableResult
    public func transition(to newState: OrganizationState, force: Bool = false) -> Bool {
        let currentState = state

        // Re-entrant apply is a no-op rejection, not a successful transition,
        // so a second apply() cannot restart file moves via updateState.
        if currentState == .applying, newState == .applying, !force {
            return false
        }

        // Always allow same state (no-op)
        if currentState == newState {
            state = newState
            return true
        }
        
        // Validate transition
        let isValid = force || OrganizationState.canTransition(from: currentState, to: newState)
        
        if isValid {
            // Bug reports attach recent error lines, so record where the
            // workflow was and the error's type and code, not just its text.
            if case .error(let error) = newState {
                let nsError = error as NSError
                OrganizerServices.log(
                    "Organizer failed while \(currentState.stageName): \(type(of: error)) \(nsError.domain) code \(nsError.code): \(error.localizedDescription)",
                    level: .error,
                    category: "FolderOrganizer"
                )
            }
            state = newState
            return true
        } else {
            // Log invalid transition attempt
            OrganizerServices.log(
                "Invalid state transition attempted: \(currentState.description) -> \(newState.description)",
                level: .warning,
                category: "FolderOrganizer"
            )
            return false
        }
    }
    
    // Track current directory for status checks
    public var currentDirectory: URL? {
        get { presentationState.currentDirectory }
        set { updatePresentation { $0.currentDirectory = newValue } }
    }
    /// The rule that blocked the root folder for the current organization attempt.
    public internal(set) var blockingExclusionRule: ExclusionRule? {
        get { presentationState.blockingExclusionRule }
        set { updatePresentation { $0.blockingExclusionRule = newValue } }
    }
    
    // Track detected duplicates for the current session
    public var detectedDuplicates: [DuplicateGroup] {
        get { presentationState.detectedDuplicates }
        set { updatePresentation { $0.detectedDuplicates = newValue } }
    }
    
    // Track file count for better progress estimation
    public var scannedFileCount: Int = 0
    public var scannedFiles: [FileItem] {
        get { presentationState.scannedFiles }
        set { updatePresentation { $0.scannedFiles = newValue } }
    }
    var scannedFilePathLookup: [String: [String]] = [:]
    let scannedFilesUIPublishLimit = 200

    /// Full scan results backing lookups, insights, and thumbnails.
    /// `scannedFiles` publishes only a bounded slice for UI; this keeps every
    /// scanned file so streaming resolution and thumbnails keep working past
    /// the UI cap (deep scan up to `deepScanFileLimit`).
    public internal(set) var allScannedFiles: [FileItem] = []

    // CRITICAL: Cancellation token - must be checked frequently
    var currentTask: Task<Void, Error>?
    var isCancellationRequested: Bool = false

    /// Monotonic token for the currently claimed run. Every tracked run
    /// (`organize`, `resumeOrganization`, `organizeIncremental`,
    /// `apply`, and the regenerate wrappers) claims
    /// it synchronously before its first await because the state guard is
    /// still false while that call loads persisted state; without it a second
    /// start could cancel this run and then clobber its task/state on exit.
    /// Only the current token may clear `currentTask` or reset state.
    var activeOrganizeRunToken: UInt64?
    private var organizeRunTokenCounter: UInt64 = 0

    /// Set by performApply once it has recorded a failure/partial history entry,
    /// so the enclosing incremental/selected-file catch does not record the
    /// same failure a second time via handleOrganizationError.
    var performApplyRecordedFailure = false

    func claimOrganizeRun(stealing: Bool = false) -> UInt64? {
        guard stealing || activeOrganizeRunToken == nil else { return nil }
        organizeRunTokenCounter &+= 1
        activeOrganizeRunToken = organizeRunTokenCounter
        return organizeRunTokenCounter
    }

    func isCurrentOrganizeRun(_ token: UInt64) -> Bool {
        activeOrganizeRunToken == token
    }

    /// A superseded run may neither reset the winner nor leave a suppression
    /// flag that would mute a later legitimate cancellation.
    func checkCancellationRunOwnership(_ token: UInt64) throws {
        guard isCurrentOrganizeRun(token) else {
            suppressCancellationReset = false
            throw CancellationError()
        }
    }

    /// Keep cleanup at the caller's exit; only the owning run may clear its task.
    func clearTask(ifOwnedBy token: UInt64) {
        if isCurrentOrganizeRun(token) {
            currentTask = nil
        }
    }

    func releaseOrganizeRun(_ token: UInt64) {
        guard activeOrganizeRunToken == token else { return }
        activeOrganizeRunToken = nil
    }

    func consumePerformApplyFailureRecording() -> Bool {
        defer { performApplyRecordedFailure = false }
        return performApplyRecordedFailure
    }

    /// Single place that decides whether an error means "user cancelled".
    /// Covers structured cancellation (CancellationError, OrganizationError.cancelled,
    /// AIClientError.isCancellation, NSURLErrorCancelled) and stringly-typed
    /// cancellations from URLSession / AI providers.
    nonisolated public static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? OrganizationError) == .cancelled { return true }
        if let clientError = error as? AIClientError, clientError.isCancellation { return true }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return true }
        let description = error.localizedDescription.lowercased()
        return description.contains("cancelled") || description.contains("canceled")
    }

    // Prevent auto-start by tracking explicit user actions
    var userInitiatedAction: Bool = false

    var scanner = DirectoryScanner()
    public private(set) var aiClient: AIClientProtocol?
    let fileSystemManager: FileSystemManager
    var aiConfig: AIConfig?
    let validator = FileOrganizationValidator.self
    public let history: OrganizationHistory
    public var exclusionRules: ExclusionRulesManager?
    public var personaManager: PersonaManager?
    public var customPersonaStore: CustomPersonaStore?
    public var learningsManager: LearningsManager?
    public var storageLocationsManager: StorageLocationsManager?
    public var automationManager: (any OrganizerAutomation)?

    /// Exclusion enforcer for post-AI validation (lazily initialized)
    var exclusionEnforcer: ExclusionEnforcer?

    /// Learning observer reference for rule tracking
    public var learningsObserver: ContinuousLearningObserver?
    let revertOperationTracker = RevertOperationTracker()
    
    let visionAnalyzer = ImageVisionAnalyzer()
    let visionImageExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp",
    ]

    #if DEBUG
    var revertOperationTestHook: (@Sendable () async -> Void)?
    var batchClientFactoryForTesting: (@Sendable (AIConfig, Int) async throws -> AIClientProtocol)?
    #endif
    
    public init(
        history: OrganizationHistory = OrganizationHistory(),
        fileSystemManager: FileSystemManager = FileSystemManager()
    ) {
        self.history = history
        self.fileSystemManager = fileSystemManager
        syncRunningOrganizationRegistrationIfNeeded(from: .idle, to: state)
    }

    deinit {
        if isRegisteredAsRunningOrganizer {
            // Capture only the identifier so the cleanup Task never retains self
            // from deinit; it hops to the main actor to mutate shared state.
            let id = ObjectIdentifier(self)
            Task { @MainActor [id] in
                Self.runningOrganizerIDs.remove(id)
                Self.runningActivity.count = Self.runningOrganizationCount
            }
        }
    }

    @MainActor
    private func syncRunningOrganizationRegistrationIfNeeded(from oldState: OrganizationState, to newState: OrganizationState) {
        let wasTracked = Self.isTrackedRunningState(oldState)
        let shouldTrack = Self.isTrackedRunningState(newState)
        guard wasTracked != shouldTrack else { return }

        let id = ObjectIdentifier(self)
        if shouldTrack {
            Self.runningOrganizerIDs.insert(id)
            isRegisteredAsRunningOrganizer = true
        } else {
            Self.runningOrganizerIDs.remove(id)
            isRegisteredAsRunningOrganizer = false
        }

        Self.runningActivity.count = Self.runningOrganizationCount
    }

    #if DEBUG
    /// Test-only method to inject a mock AI client for unit testing
    public func setAIClientForTesting(_ client: AIClientProtocol?) {
        self.aiClient = client
        if client != nil {
            self.isAIConfigured = true
        }
    }

    func setBatchClientFactoryForTesting(
        _ factory: (@Sendable (AIConfig, Int) async throws -> AIClientProtocol)?
    ) {
        batchClientFactoryForTesting = factory
    }

    func flushStreamingUpdatesForTesting() async {
        scheduleDisplayUpdate(for: streamingContent, force: true)
        extractInsightsIfNeeded(force: true)

        let pendingDisplayUpdate = displayUpdateTask
        let pendingInsightExtraction = insightExtractionTask
        await pendingDisplayUpdate?.value
        await pendingInsightExtraction?.value
    }

    func setRevertOperationHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        revertOperationTestHook = hook
    }

    /// Test-only hook awaited after file moves complete and before the
    /// post-move cancellation check, so tests can cancel deterministically
    /// between the two and exercise the partial-cancel history path.
    var postMoveTestHook: (@Sendable () async -> Void)?

    func setPostMoveCancellationCheckHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        postMoveTestHook = hook
    }
    #endif

    func recordPreviewVersion(_ plan: OrganizationPlan) {
        // Oversized plans are skipped without wiping existing preview history;
        // wiping silently destroys undo context for regeneration preferences.
        guard plan.totalFiles <= Self.previewVersionFileLimit else {
            OrganizerServices.log(
                "Skipping preview history for \(plan.totalFiles) files (limit \(Self.previewVersionFileLimit)); preserving \(planHistory.count) existing versions",
                level: .warning,
                category: "FolderOrganizer"
            )
            return
        }
        planHistory.append(plan)
        if planHistory.count > Self.maxPreviewVersions {
            planHistory.removeFirst()
        }
    }

    public func configure(with config: AIConfig) async throws {
        // Views re-run configuration on every appear; skip the client rebuild
        // when the active configuration already matches.
        if isAIConfigured, aiClient != nil, aiConfig == config {
            return
        }
        do {
            var client = try AIClientFactory.createClient(config: config)

            // Set up streaming delegate
            client.streamingDelegate = self

            self.aiClient = client
            self.aiConfig = config
            await scanner.setOCRLanguages(config.ocrLanguages)
            
            await MainActor.run {
                self.isAIConfigured = true
            }
        } catch {
            self.aiClient = nil
            self.aiConfig = config
            await MainActor.run {
                self.isAIConfigured = false
            }
            throw error
        }
    }
}

// MARK: - Finder Refresh
extension FolderOrganizer {
    nonisolated private func refreshFinder(at url: URL) {
        DispatchQueue.main.async {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
