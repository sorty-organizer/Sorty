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

public enum OrganizationState: Equatable, Sendable {
    case idle
    case scanning
    case organizing
    case ready
    case applying
    case completed
    case error(Error)

    /// Whether the organizer is actively performing work and should not be interrupted
    public var isOperationInProgress: Bool {
        switch self {
        case .scanning, .organizing, .ready, .applying:
            return true
        case .idle, .completed, .error:
            return false
        }
    }

    public static func == (lhs: OrganizationState, rhs: OrganizationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.scanning, .scanning),
             (.organizing, .organizing),
             (.ready, .ready),
             (.applying, .applying),
             (.completed, .completed):
            return true
        case (.error(let lhsError), .error(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }
    
    /// Returns true if a transition from `from` state to `to` state is valid
    public static func canTransition(from: OrganizationState, to: OrganizationState) -> Bool {
        // Same state is always valid (no-op)
        if from == to {
            return true
        }
        
        // From idle: can go to scanning or error
        if from == .idle {
            switch to {
            case .idle, .scanning, .error:
                return true
            default:
                return false
            }
        }
        
        // From scanning: can go to organizing, idle (cancel), or error
        if from == .scanning {
            switch to {
            case .scanning, .organizing, .idle, .error:
                return true
            default:
                return false
            }
        }
        
        // From organizing: can go to ready, idle (cancel), or error
        if from == .organizing {
            switch to {
            case .organizing, .ready, .idle, .error:
                return true
            default:
                return false
            }
        }
        
        // From ready: can go to applying, idle (cancel), organizing (regenerate), or error
        if from == .ready {
            switch to {
            case .ready, .applying, .idle, .organizing, .error:
                return true
            default:
                return false
            }
        }
        
        // From applying: can go to completed, idle (cancel), or error
        if from == .applying {
            switch to {
            case .applying, .completed, .idle, .error:
                return true
            default:
                return false
            }
        }
        
        // From completed: can only go to idle (reset)
        if from == .completed {
            switch to {
            case .completed, .idle:
                return true
            default:
                return false
            }
        }
        
        // From error: can go to idle (retry/reset), or retry the previous operation
        if case .error = from {
            switch to {
            case .error, .idle, .scanning, .organizing:
                return true
            default:
                return false
            }
        }
        
        return false
    }
    
    /// Human-readable description of the state
    public var description: String {
        switch self {
        case .idle:
            return "Idle"
        case .scanning:
            return "Scanning"
        case .organizing:
            return "Organizing"
        case .ready:
            return "Ready"
        case .applying:
            return "Applying"
        case .completed:
            return "Completed"
        case .error(let error):
            return "Error: \(error.localizedDescription)"
        }
    }
}

public enum OrganizationError: LocalizedError, Equatable {
    case clientNotConfigured
    case automationNotConfigured
    case noCurrentPlan
    case fileMoveFailed(String)
    case cancelled
    case revertAlreadyInProgress(String)

    public var errorDescription: String? {
        switch self {
        case .clientNotConfigured:
            return "AI Client not configured. Please check your settings."
        case .automationNotConfigured:
            return "Automation permission not granted. Please enable it in System Settings > Privacy & Security > Automation."
        case .noCurrentPlan:
            return "No organization plan available to apply."
        case .fileMoveFailed(let details):
            return "Failed to move file: \(details)"
        case .cancelled:
            return "Operation was cancelled."
        case .revertAlreadyInProgress(let path):
            return "A revert is already in progress for \(path)."
        }
    }
}

private actor RevertOperationTracker {
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

/// AI reasoning insight extracted from streaming content
public struct AIInsight: Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let category: Category
    public let timestamp: Date
    public let filePath: String? // Optional path for thumbnails
    
    public enum Category: String, Sendable {
        case file = "File"
        case folder = "Folder"
        case constraint = "Constraint"
        case decision = "Decision"
        case pattern = "Pattern"
        case general = "Analyzing"
        
        public var icon: String {
            switch self {
            case .file: return "doc"
            case .folder: return "folder"
            case .constraint: return "exclamationmark.triangle"
            case .decision: return "arrow.right"
            case .pattern: return "circle.grid.3x3"
            case .general: return "brain"
            }
        }
        
        public var color: String {
            switch self {
            case .file: return "blue"
            case .folder: return "orange"
            case .constraint: return "yellow"
            case .decision: return "green"
            case .pattern: return "purple"
            case .general: return "secondary"
            }
        }
    }
    
    public init(text: String, category: Category, filePath: String? = nil, stableSeed: String? = nil) {
        self.text = text
        self.category = category
        self.timestamp = Date()
        self.filePath = filePath
        self.id = Self.makeStableID(text: text, category: category, filePath: filePath, stableSeed: stableSeed)
    }

    private static func makeStableID(
        text: String,
        category: Category,
        filePath: String?,
        stableSeed: String?
    ) -> String {
        let normalizedText = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedPath = filePath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let normalizedSeed = stableSeed?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        let base = "\(category.rawValue.lowercased())|\(normalizedPath)|\(normalizedText)|\(normalizedSeed)"
        var hash: UInt64 = 1469598103934665603
        for byte in base.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return "insight-\(String(hash, radix: 16))"
    }
}

/// Progress update for real-time UI feedback
public struct OrganizationProgress: Sendable {
    public let phase: Phase
    public let current: Int
    public let total: Int
    public let detail: String?

    public enum Phase: String, Sendable {
        case scanning = "Scanning"
        case analyzing = "Analyzing"
        case aiProcessing = "AI Processing"
        case validating = "Validating"
        case applying = "Applying"
        case complete = "Complete"
    }

    public var percentage: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }

    public var phaseWeight: Double {
        switch phase {
        case .scanning: return 0.15
        case .analyzing: return 0.15
        case .aiProcessing: return 0.50
        case .validating: return 0.10
        case .applying: return 0.10
        case .complete: return 1.0
        }
    }

    public var phaseBaseProgress: Double {
        switch phase {
        case .scanning: return 0.0
        case .analyzing: return 0.15
        case .aiProcessing: return 0.30
        case .validating: return 0.80
        case .applying: return 0.90
        case .complete: return 1.0
        }
    }

    public var overallProgress: Double {
        if phase == .complete { return 1.0 }
        return phaseBaseProgress + (percentage * (phaseWeight - phaseBaseProgress.truncatingRemainder(dividingBy: 1.0)))
    }
}

/// Fine-grained activity inside the AI analysis phase. The coarse
/// `OrganizationState` stays `.organizing` across all of these, so the UI
/// uses this to label live progress accurately (for example, distinguishing
/// local vision image preparation from the network wait for a response).
public enum AIAnalysisActivity: Equatable, Sendable {
    case none
    case preparingImages
    case requesting
    case validating
}

/// Progress backed by a concrete count of completed work items.
public struct MeasuredWorkProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int

    public var percentage: Double {
        guard total > 0 else { return 0 }
        return max(0, min(1, Double(completed) / Double(total)))
    }

    public init(completed: Int, total: Int) {
        self.total = max(0, total)
        self.completed = max(0, min(completed, self.total))
    }
}

public struct VisionAnalysisSummary: Equatable, Sendable {
    public let analyzedCount: Int
    public let totalImageCount: Int
    public let skippedCount: Int
    public let failedCount: Int
    public let warningMessage: String?

    public var hasWarning: Bool {
        warningMessage != nil
    }

    public var summaryText: String {
        var text = "Analyzed \(analyzedCount) of \(totalImageCount) images with Sorty Vision"
        if skippedCount > 0 {
            text += " (\(skippedCount) skipped)"
        }
        if failedCount > 0 {
            text += " (\(failedCount) failed to preprocess)"
        }
        return text
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
    private actor LargeFolderPlanAccumulator {
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

    private struct OrganizationResumeCheckpoint {
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

    private struct PresentationState {
        var state: OrganizationState = .idle
        var progress: Double = 0
        var currentPlan: OrganizationPlan?
        var planHistory: [OrganizationPlan] = []
        var errorMessage: String?
        var pinsCompletionView = false
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

                // Request user attention for any error state
                if case .error = state {
                    NotificationManager.shared.requestAttention()
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
    private var cachedManualSessionDirectoryPath: String?
    private var cachedManualSessionBookmark: Data?
    private var lastManualSessionFingerprintByURL: [URL: Data] = [:]
    private var manualSessionGeneration = 0
    private var restoredManualSessionScopedURL: URL?
    public var progress: Double {
        get { presentationState.progress }
        set { updatePresentation { $0.progress = newValue } }
    }
    public var currentPlan: OrganizationPlan? {
        get { presentationState.currentPlan }
        set { updatePresentation { $0.currentPlan = newValue } }
    }
    private var preparedPlanModeOverride: OrganizationMode?
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
    private var currentRunInstructions = ""
    private var modelExcludedCurrentRun = false
    private var currentRunLearningExcluded: Bool {
        modelExcludedCurrentRun
            || LearningsManager.instructionsExcludeCurrentRun(currentRunInstructions)
    }

    private func handleLearningToolCall(
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

        let destination: DeeplinkDestination
        let actionTitle: String
        let actionIcon: String
        switch concern.reviewTarget {
        case .instructions:
            destination = .organize(path: folderPath, persona: nil, mode: nil, autostart: false)
            actionTitle = "Review Instructions"
            actionIcon = "text.alignleft"
        case .persona:
            destination = .persona(action: nil, prompt: nil, generate: false)
            actionTitle = "Review Persona"
            actionIcon = "person.text.rectangle"
        case .watchedFolder:
            destination = .watched(action: nil, path: folderPath)
            actionTitle = "Review Watched Folder"
            actionIcon = "folder.badge.gearshape"
        }

        NotificationManager.shared.showHUDInfo(
            title: "Learning Is Being Skipped Often",
            message: "Sorty skipped learning for \(concern.excludedRunCount) of the last \(concern.evaluatedRunCount) runs. Review the instructions that triggered it.",
            icon: "exclamationmark.triangle.fill",
            iconColor: .orange,
            identifier: "frequent-learning-exclusions",
            actions: [
                HUDNotificationAction(title: actionTitle, systemImage: actionIcon) {
                    guard let url = DeeplinkHandler.url(for: destination) else { return }
                    _ = MainWindowRouter.shared.routeDeeplink(url)
                }
            ]
        )
    }

    /// When true, callers (such as OrganizeView) should keep showing the OrganizationCompleteView
    /// even if `state` momentarily transitions through `.applying`/`.idle` during an in-place
    /// undo or redo action performed from that screen.
    public var pinsCompletionView: Bool {
        get { presentationState.pinsCompletionView }
        set { updatePresentation { $0.pinsCompletionView = newValue } }
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
    /// ID -> file mapping for the AI request currently streaming. Compact prompts
    /// number files per request batch (1-based), so live-stream consumers must
    /// resolve `file_ids` through this table rather than indexing `scannedFiles`.
    public private(set) var streamFileIDTable: [Int: FileItem] {
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
    public private(set) var measuredWorkProgress: MeasuredWorkProgress? {
        get { presentationState.measuredWorkProgress }
        set { updatePresentation { $0.measuredWorkProgress = newValue } }
    }
    public var visionAnalysisSummary: VisionAnalysisSummary? {
        get { presentationState.visionAnalysisSummary }
        set { updatePresentation { $0.visionAnalysisSummary = newValue } }
    }
    /// What the AI analysis phase is actually doing right now, so the UI can
    /// label the wait accurately. Reset whenever `state` leaves `.organizing`.
    public private(set) var aiAnalysisActivity: AIAnalysisActivity {
        get { presentationState.aiAnalysisActivity }
        set { updatePresentation { $0.aiAnalysisActivity = newValue } }
    }
    
    // Throttle timer for display content updates (prevents layout thrashing)
    private var displayUpdateTask: Task<Void, Never>?
    private var lastDisplayUpdate: Date = .distantPast
    private var retainedStreamingByteCount = 0
    private var streamingContentRevision: UInt64 = 0
    private let displayUpdateInterval: TimeInterval = 0.55 // Slightly slower cadence to reduce dropped frames during generation
    nonisolated private static let streamPreviewCharacterLimit = 1000
    nonisolated private static let streamUIPresentationCharacterLimit = 48_000
    nonisolated private static let streamRetentionByteLimit = 256_000
    nonisolated private static let streamRetentionTrimByteSlack = 32_000
    nonisolated private static let deepScanFileLimit = 2_000
    nonisolated private static let organizeAnalysisBatchSize = 350
    nonisolated private static let renameAnalysisBatchSize = 120
    nonisolated private static let minimumAdaptiveAnalysisBatchSize = 8
    nonisolated private static let previewVersionFileLimit = 20_000
    nonisolated private static let maximumPreparedVisionBytes = 32 * 1_024 * 1_024
    nonisolated private static let assignmentDestinationRegex =
        try? NSRegularExpression(
            pattern: #"\b(?:assigning|moving|mapping)\b.+?\bto\b\s+(.+)$"#,
            options: [.caseInsensitive]
        )
    nonisolated private static let blockedLiveFolderNames: Set<String> = [
        "a", "an", "and", "as", "at", "be", "by", "for", "from", "gets", "in", "into",
        "is", "it", "name", "of", "on", "or", "that", "the", "this", "to", "value",
        "with", "folder", "folders", "file", "files", "filename", "json", "reasoning",
        "notes", "unorganized", "data", "content", "description", "type", "rule_id",
        "semantic_tags", "suggested_name", "rename_reason", "tags", "comment", "true",
        "false", "null", LearningToolCall.excludeCurrentRunToolName
    ]
    nonisolated private static let quotedFileMentionRegex =
        try? NSRegularExpression(
            pattern: #"(?:\"|')([^\"'\n]{2,220}\.[a-zA-Z0-9]{1,12})(?:\"|')"#,
            options: []
        )
    nonisolated private static let bareFileMentionRegex =
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
    private var lastInsightExtraction: Date = .distantPast
    private let insightExtractionInterval: TimeInterval = 0.9 // Lower extraction frequency to cut parser pressure while streaming
    private let insightExtractor = AIInsightExtractor()
    private var insightExtractionTask: Task<Void, Never>?
    
    // Progress line streaming support
    private var progressLineBuffer: String = ""
    private var discardsCurrentProgressLine = false
    private var receivedProgressLines: Bool = false
    private var jsonStartedInStream: Bool = false
    private var progressLineCount: Int = 0
    private let progressLineLimit = 3
    
    // MARK: - AI Insights Cache
    
    /// Cache for pre-computed AI insights to avoid re-parsing during UI rendering
    private var insightsCache: InsightsCache?
    
    /// Structure to hold cached insights data
    private struct InsightsCache {
        let streamingContentHash: Int
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
    private var startTime: Date?
    private var timeoutTask: Task<Void, Never>?
    private var suppressCancellationReset = false
    private var resumeCheckpoint: OrganizationResumeCheckpoint?
    private var preparedVisionAttachmentNames: Set<String> = []
    private var visionPreparationFailureCount = 0
    private var visionPreparationByteLimitSkipCount = 0

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
    
    /// Perform batch updates asynchronously
    @MainActor
    public func withBatchUpdatesAsync(_ updates: () async -> Void) async {
        beginBatchUpdates()
        defer { endBatchUpdates() }
        await updates()
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
        
        // Always allow same state (no-op)
        if currentState == newState {
            state = newState
            return true
        }
        
        // Validate transition
        let isValid = force || OrganizationState.canTransition(from: currentState, to: newState)
        
        if isValid {
            state = newState
            return true
        } else {
            // Log invalid transition attempt
            LogManager.shared.log(
                "Invalid state transition attempted: \(currentState.description) -> \(newState.description)",
                level: .warning,
                category: "FolderOrganizer"
            )
            return false
        }
    }
    
    /// Convenience method to reset to idle state
    @MainActor
    public func resetToIdleState() {
        _ = transition(to: .idle)
    }

    // Track current directory for status checks
    public var currentDirectory: URL? {
        get { presentationState.currentDirectory }
        set { updatePresentation { $0.currentDirectory = newValue } }
    }
    /// The rule that blocked the root folder for the current organization attempt.
    public private(set) var blockingExclusionRule: ExclusionRule? {
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
    private var scannedFilePathLookup: [String: [String]] = [:]
    private let scannedFilesUIPublishLimit = 200

    // CRITICAL: Cancellation token - must be checked frequently
    private var currentTask: Task<Void, Error>?
    private var isCancellationRequested: Bool = false

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
    private var userInitiatedAction: Bool = false

    var scanner = DirectoryScanner()
    public private(set) var aiClient: AIClientProtocol?
    private let fileSystemManager: FileSystemManager
    private var aiConfig: AIConfig?
    private let validator = FileOrganizationValidator.self
    public let history: OrganizationHistory
    public var exclusionRules: ExclusionRulesManager?
    public var personaManager: PersonaManager?
    public var customPersonaStore: CustomPersonaStore?
    public var learningsManager: LearningsManager?
    public var storageLocationsManager: StorageLocationsManager?
    public var automationManager: AutomationManager?

    /// Exclusion enforcer for post-AI validation (lazily initialized)
    private var exclusionEnforcer: ExclusionEnforcer?

    /// Learning observer reference for rule tracking
    public var learningsObserver: ContinuousLearningObserver?
    private let revertOperationTracker = RevertOperationTracker()
    
    private let visionAnalyzer = ImageVisionAnalyzer()
    private let visionImageExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp",
    ]

    #if DEBUG
    private var revertOperationTestHook: (@Sendable () async -> Void)?
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
            let id = ObjectIdentifier(self)
            Task { @MainActor in
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
    #endif

    private func recordPreviewVersion(_ plan: OrganizationPlan) {
        guard plan.totalFiles <= Self.previewVersionFileLimit else {
            planHistory.removeAll(keepingCapacity: false)
            return
        }
        planHistory.append(plan)
        if planHistory.count > Constants.maxPreviewVersions {
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

    // MARK: - StreamingDelegate

    private struct StreamPresentationPayload: Sendable {
        let fullContent: String
        let truncatedContent: String
    }

    nonisolated private static func makeStreamPresentationPayload(from content: String) -> StreamPresentationPayload {
        // Walk only the displayed suffix, rather than counting the entire response
        // before walking it again. String indices preserve composed characters.
        let fullStart = content.index(
            content.endIndex,
            offsetBy: -streamUIPresentationCharacterLimit,
            limitedBy: content.startIndex
        ) ?? content.startIndex
        let fullContent = String(content[fullStart...])
        let previewStart = content.index(
            content.endIndex,
            offsetBy: -streamPreviewCharacterLimit,
            limitedBy: content.startIndex
        ) ?? content.startIndex
        let truncatedContent = (previewStart == content.startIndex ? "" : "...")
            + String(content[previewStart...])
        return StreamPresentationPayload(
            fullContent: fullContent,
            truncatedContent: truncatedContent
        )
    }

    @MainActor
    private func appendRetainedStreamChunk(_ chunk: String) {
        streamingContent += chunk
        retainedStreamingByteCount += chunk.utf8.count
        streamingContentRevision &+= 1
        let trimThreshold = Self.streamRetentionByteLimit + Self.streamRetentionTrimByteSlack
        if retainedStreamingByteCount > trimThreshold {
            streamingContent = Self.retainingUTF8Suffix(
                of: streamingContent,
                maximumByteCount: Self.streamRetentionByteLimit
            )
            retainedStreamingByteCount = streamingContent.utf8.count
        }
    }

    nonisolated private static func retainingUTF8Suffix(
        of content: String,
        maximumByteCount: Int
    ) -> String {
        guard content.utf8.count > maximumByteCount else { return content }
        var suffix = content.utf8.suffix(maximumByteCount)
        while let first = suffix.first, first & 0b1100_0000 == 0b1000_0000 {
            suffix = suffix.dropFirst()
        }
        return String(decoding: suffix, as: UTF8.self)
    }

    nonisolated private static func retainedStreamCompletion(_ content: String) -> String {
        retainingUTF8Suffix(of: content, maximumByteCount: streamRetentionByteLimit)
    }

    @MainActor
    private func scheduleDisplayUpdate(for contentSnapshot: String, force: Bool = false) {
        guard liveInsightsEnabled else { return }

        let now = Date()
        if !force && now.timeIntervalSince(lastDisplayUpdate) < displayUpdateInterval {
            return
        }
        lastDisplayUpdate = now

        let estimatedTotal = estimatedStreamingCharacterTarget()
        // Progress is capped at 80%; characters beyond the target cannot change it.
        let contentLength = progress < 0.80 ? contentSnapshot.prefix(estimatedTotal).count : estimatedTotal
        let expectedRevision = streamingContentRevision

        displayUpdateTask?.cancel()
        displayUpdateTask = Task { @MainActor [weak self] in
            let payload = Self.makeStreamPresentationPayload(from: contentSnapshot)
            guard let self, !Task.isCancelled, !self.isCancellationRequested else { return }
            guard self.streamingContentRevision >= expectedRevision else { return }

            self.withBatchUpdates {
                self.displayStreamingContent = payload.fullContent
                self.truncatedDisplayStreamingContent = payload.truncatedContent
                self.updateProgressFromStreamLength(contentLength, estimatedTotal: estimatedTotal)
            }
        }
    }

    @MainActor
    private func updateProgressFromStreamLength(_ contentLength: Int, estimatedTotal: Int? = nil) {
        let target = estimatedTotal ?? estimatedStreamingCharacterTarget()
        let contentProgress = min(0.80, 0.30 + (Double(contentLength) / Double(target)) * 0.50)
        if progress < contentProgress {
            progress = contentProgress
        }
    }

    @MainActor
    private func syncDisplayContentImmediately() {
        let payload = Self.makeStreamPresentationPayload(from: streamingContent)
        displayStreamingContent = payload.fullContent
        truncatedDisplayStreamingContent = payload.truncatedContent
    }

    @MainActor
    private func clearStreamingDisplayState() {
        displayUpdateTask?.cancel()
        displayUpdateTask = nil
        insightExtractionTask?.cancel()
        insightExtractionTask = nil
        streamingContent = ""
        retainedStreamingByteCount = 0
        streamingContentRevision &+= 1
        displayStreamingContent = ""
        truncatedDisplayStreamingContent = ""
        lastDisplayUpdate = .distantPast
        lastInsightExtraction = .distantPast
        insightsCache = nil
        progressLineBuffer = ""
        discardsCurrentProgressLine = false
        receivedProgressLines = false
        jsonStartedInStream = false
        progressLineCount = 0
    }

    private var analysisStageDescription: String {
        switch aiConfig?.mode {
        case .renameOnly:
            return "Sorty is preparing rename suggestions..."
        case .organizeAndRename:
            return "Sorty is organizing and renaming your files..."
        case .organize, nil:
            return "Sorty is organizing your files..."
        }
    }

    @MainActor
    private func restartPlanGenerationForRetry() {
        clearStreamingDisplayState()
        withBatchUpdates {
            isStreaming = false
            progress = 0.30
            organizationStage = analysisStageDescription
        }
        startTimeoutTimer()
    }

    public func didReceiveChunk(_ chunk: String) {
        guard !isCancellationRequested else { return }

        // If a prior stream already completed, treat this as a brand-new stream session.
        if !isStreaming, !streamingContent.isEmpty {
            clearStreamingDisplayState()
        }
            
        let isFirstChunk = streamingContent.isEmpty
        appendRetainedStreamChunk(chunk)

        if isFirstChunk {
            // Batch all initial state updates together
            withBatchUpdates {
                isStreaming = true
                organizationStage = analysisStageDescription
                progress = 0.30
                if liveInsightsEnabled {
                    syncDisplayContentImmediately()
                }
            }
        }

        if liveInsightsEnabled {
            // Try to extract progress lines from the stream before JSON starts
            if !jsonStartedInStream {
                processProgressLines(from: chunk)
            }

            // Throttle UI-impacting updates to prevent layout thrashing and main actor congestion
            scheduleDisplayUpdate(for: streamingContent)

            // Fall back to regex extractor only if no progress lines were received
            if !receivedProgressLines {
                extractInsightsIfNeeded()
            }
        } else {
            let now = Date()
            if now.timeIntervalSince(lastDisplayUpdate) >= displayUpdateInterval {
                lastDisplayUpdate = now
                if progress < 0.80 {
                    let target = estimatedStreamingCharacterTarget()
                    updateProgressFromStreamLength(streamingContent.prefix(target).count, estimatedTotal: target)
                }
            }
        }
    }
    
    // MARK: - Progress Line Parsing
    
    /// Parse progress lines (>> category: text) from streaming chunks
    @MainActor
    private func processProgressLines(from chunk: String) {
        for fragment in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            if fragment.contains("{") {
                progressLineBuffer = ""
                discardsCurrentProgressLine = true
                jsonStartedInStream = true
                return
            }

            appendProgressLineFragment(fragment)
            guard fragment.endIndex != chunk.endIndex else { continue }
            finishProgressLine()
        }
    }

    @MainActor
    private func appendProgressLineFragment(_ fragment: Substring) {
        guard !discardsCurrentProgressLine else { return }

        var remainder = fragment
        if progressLineBuffer.isEmpty {
            remainder = remainder.drop(while: { $0.isWhitespace })
        }

        if progressLineBuffer.count < 3 {
            let prefixRemainder = remainder.prefix(3 - progressLineBuffer.count)
            progressLineBuffer.append(contentsOf: prefixRemainder)
            remainder = remainder.dropFirst(prefixRemainder.count)
            guard ">> ".hasPrefix(progressLineBuffer) else {
                progressLineBuffer = ""
                discardsCurrentProgressLine = true
                return
            }
        }

        let maximumProgressLineLength = 16 * 1024
        guard progressLineBuffer.count + remainder.count <= maximumProgressLineLength else {
            progressLineBuffer = ""
            discardsCurrentProgressLine = true
            return
        }
        progressLineBuffer.append(contentsOf: remainder)
    }

    @MainActor
    private func finishProgressLine() {
        defer {
            progressLineBuffer = ""
            discardsCurrentProgressLine = false
        }
        guard !discardsCurrentProgressLine else { return }

        let line = progressLineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix(">> "), progressLineCount < progressLineLimit else { return }

        let content = String(line.dropFirst(3))
        guard let insight = parseProgressLine(content) else { return }

        progressLineCount += 1
        receivedProgressLines = true

        withBatchUpdates {
            currentInsight = insight.text
            if let existingIndex = insightHistory.firstIndex(where: { $0.id == insight.id }) {
                insightHistory.remove(at: existingIndex)
            }
            if insightHistory.count >= progressLineLimit {
                insightHistory.removeFirst()
            }
            insightHistory.append(insight)
        }
        insightsCache = nil
    }

    /// Rebuild insight timeline from the already-buffered stream text.
    /// Used when users re-enable Live Insights during an active generation.
    @MainActor
    private func rebuildInsightsFromStreamingSnapshot() {
        let snapshot = streamingContent
        guard !snapshot.isEmpty else {
            withBatchUpdates {
                currentInsight = ""
                insightHistory = []
            }
            progressLineBuffer = ""
            discardsCurrentProgressLine = false
            receivedProgressLines = false
            jsonStartedInStream = false
            progressLineCount = 0
            return
        }

        let rawLines = snapshot.components(separatedBy: .newlines)
        var rebuiltInsights: [AIInsight] = []
        var sawJSON = false
        var trailingPartialBuffer = ""

        for (index, rawLine) in rawLines.enumerated() {
            let isLastLine = index == rawLines.count - 1
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedLine.contains("{") {
                sawJSON = true
                trailingPartialBuffer = ""
                break
            }

            if isLastLine, !snapshot.hasSuffix("\n") {
                trailingPartialBuffer = rawLine
            }

            guard !trimmedLine.isEmpty else { continue }
            guard trimmedLine.hasPrefix(">> "), rebuiltInsights.count < progressLineLimit else { continue }

            let lineContent = String(trimmedLine.dropFirst(3))
            guard let insight = parseProgressLine(lineContent) else { continue }

            if let existingIndex = rebuiltInsights.firstIndex(where: { $0.id == insight.id }) {
                rebuiltInsights.remove(at: existingIndex)
            }
            rebuiltInsights.append(insight)
        }

        progressLineBuffer = ""
        discardsCurrentProgressLine = false
        if !sawJSON {
            appendProgressLineFragment(trailingPartialBuffer[...])
        }
        receivedProgressLines = !rebuiltInsights.isEmpty
        jsonStartedInStream = sawJSON
        progressLineCount = rebuiltInsights.count

        withBatchUpdates {
            currentInsight = rebuiltInsights.last?.text ?? ""
            insightHistory = rebuiltInsights
        }
    }
    
    /// Parse a progress line like "file: Assigning invoice.pdf to Finances" into an AIInsight
    private func parseProgressLine(_ content: String) -> AIInsight? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5 else { return nil }
        
        var category: AIInsight.Category = .general
        var text = trimmed
        
        // Try to extract "category: text" format
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let prefix = String(trimmed[trimmed.startIndex..<colonIndex])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let remainder = String(trimmed[trimmed.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)
            
            switch prefix {
            case "file", "folder", "pattern", "decision", "constraint", "general":
                switch prefix {
                case "file": category = .file
                case "folder": category = .folder
                case "pattern": category = .pattern
                case "decision": category = .decision
                case "constraint": category = .constraint
                default: category = .general
                }
                guard !remainder.isEmpty else { return nil }
                text = remainder
            default:
                category = .general
            }
        }

        if let destination = Self.extractAssignmentDestination(from: text),
           !Self.isLikelyLiveFolderName(destination) {
            return nil
        }
        if category == .file && Self.isLowSignalFileProgressInsight(text) {
            return nil
        }
        let clipped = String(text.prefix(120))
        let resolvedFilePath = (category == .file) ? resolveScannedFilePathForMention(in: text) : nil
        return AIInsight(text: clipped, category: category, filePath: resolvedFilePath, stableSeed: text)
    }

    private func resolveScannedFilePathForMention(in text: String) -> String? {
        guard let fileName = Self.extractMentionedFileName(from: text) else { return nil }
        return Self.resolveScannedFilePath(
            for: fileName,
            scannedFilePathLookup: scannedFilePathLookup,
            currentDirectoryPath: currentDirectory?.path
        )
    }

    nonisolated private static func extractMentionedFileName(from text: String) -> String? {
        if let quotedRegex = quotedFileMentionRegex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = quotedRegex.matches(in: text, options: [], range: range)
            for match in matches.reversed() {
                guard let fileRange = Range(match.range(at: 1), in: text) else { continue }
                let fileName = normalizeCandidateFileName(String(text[fileRange]))
                if isLikelyFileName(fileName) {
                    return URL(fileURLWithPath: fileName).lastPathComponent
                }
            }
        }

        if let bareRegex = bareFileMentionRegex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = bareRegex.matches(in: text, options: [], range: range)
            for match in matches.reversed() {
                guard let fileRange = Range(match.range(at: 1), in: text) else { continue }
                let fileName = normalizeCandidateFileName(String(text[fileRange]))
                if isLikelyFileName(fileName) {
                    return URL(fileURLWithPath: fileName).lastPathComponent
                }
            }
        }

        return nil
    }

    nonisolated private static func resolveScannedFilePath(
        for fileName: String,
        scannedFilePathLookup: [String: [String]],
        currentDirectoryPath: String?
    ) -> String? {
        let key = fileName.lowercased()
        guard let matches = scannedFilePathLookup[key], !matches.isEmpty else { return nil }

        if matches.count == 1 {
            return matches[0]
        }

        if let currentDirectoryPath,
           let preferredPath = matches.first(where: { $0.hasPrefix(currentDirectoryPath + "/") }) {
            return preferredPath
        }

        return matches[0]
    }

    nonisolated private static func normalizeFolderName(_ input: String) -> String {
        input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?"))
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    nonisolated private static func isLikelyLiveFolderName(_ input: String) -> Bool {
        let candidate = normalizeFolderName(input)
        guard candidate.count >= 2, candidate.count <= 80 else { return false }
        guard !candidate.contains("{"), !candidate.contains("}"), !candidate.contains("\"") else { return false }
        guard !candidate.contains("/"), !candidate.contains("\\") else { return false }
        guard URL(fileURLWithPath: candidate).pathExtension.isEmpty else { return false }

        let lower = candidate.lowercased()
        guard !blockedLiveFolderNames.contains(lower) else { return false }
        guard !lower.contains("top-level"),
              !lower.contains("top level"),
              !lower.contains("preferred"),
              !lower.contains("constraint"),
              !lower.contains("response format"),
              !lower.contains("system prompt") else {
            return false
        }
        return true
    }

    nonisolated private static func normalizeCandidateFileName(_ input: String) -> String {
        input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}"))
    }

    nonisolated private static func isLikelyFileName(_ input: String) -> Bool {
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.count <= 220 else { return false }
        let ext = URL(fileURLWithPath: candidate).pathExtension
        return !ext.isEmpty
    }

    nonisolated private static func isLowSignalFileProgressInsight(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return true }

        if lowered.contains("response format") || lowered.contains("json schema") || lowered.contains("system prompt") {
            return true
        }

        if let destination = extractAssignmentDestination(from: text),
           !isLikelyLiveFolderName(destination) {
            return true
        }

        return false
    }

    nonisolated private static func extractAssignmentDestination(from text: String) -> String? {
        guard let regex = assignmentDestinationRegex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let destinationRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let destination = normalizeFolderName(String(text[destinationRange]))
        return destination.isEmpty ? nil : destination
    }

    /// Extract meaningful insights from the streaming AI response
    /// This is throttled and uses caching to avoid performance impact
    private func extractInsightsIfNeeded(force: Bool = false) {
        guard liveInsightsEnabled else { return }

        let now = Date()
        if !force {
            guard now.timeIntervalSince(lastInsightExtraction) >= insightExtractionInterval else { return }
        }
        lastInsightExtraction = now
        
        // Get the last portion of content for analysis
        let content = streamingContent
        guard content.index(content.startIndex, offsetBy: 21, limitedBy: content.endIndex) != nil else { return }
        
        // Check cache first
        let contentHash = content.hashValue
        if let cache = insightsCache, 
           cache.streamingContentHash == contentHash,
           cache.isValid {
            // Use cached insights
            withBatchUpdates {
                self.currentInsight = cache.currentInsight
                self.insightHistory = cache.insights
            }
            return
        }

        let fileLookup = scannedFilePathLookup
        let currentDirectoryPath = currentDirectory?.path

        insightExtractionTask?.cancel()
        insightExtractionTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let insight = await self.insightExtractor.extractInsight(
                from: content,
                scannedFilePathLookup: fileLookup,
                currentDirectoryPath: currentDirectoryPath
            )

            guard !Task.isCancelled,
                  self.liveInsightsEnabled,
                  let insight,
                  insight.text != self.currentInsight else { return }

            self.withBatchUpdates {
                self.currentInsight = insight.text
                if let existingIndex = self.insightHistory.firstIndex(where: { $0.id == insight.id }) {
                    self.insightHistory.remove(at: existingIndex)
                }
                if self.insightHistory.count >= self.progressLineLimit {
                    self.insightHistory.removeFirst()
                }
                self.insightHistory.append(insight)
            }

            self.insightsCache = InsightsCache(
                streamingContentHash: contentHash,
                insights: self.insightHistory,
                currentInsight: insight.text,
                timestamp: Date()
            )
        }
    }
    
    /// Get cached insights if available, otherwise returns current insights
    /// Use this from UI to avoid re-parsing during render
    public func getCachedInsights() -> (current: String, history: [AIInsight]) {
        if let cache = insightsCache, cache.isValid {
            return (cache.currentInsight, cache.insights)
        }
        return (currentInsight, insightHistory)
    }
    
    /// Invalidate the insights cache (call when streaming content significantly changes)
    public func invalidateInsightsCache() {
        insightsCache = nil
    }

    @MainActor
    public func setLiveInsightsEnabled(_ enabled: Bool) {
        guard liveInsightsEnabled != enabled else { return }
        liveInsightsEnabled = enabled

        if enabled {
            if !streamingContent.isEmpty {
                rebuildInsightsFromStreamingSnapshot()
                syncDisplayContentImmediately()
                scheduleDisplayUpdate(for: streamingContent, force: true)
                if !receivedProgressLines {
                    extractInsightsIfNeeded(force: true)
                }
            }
            return
        }

        displayUpdateTask?.cancel()
        displayUpdateTask = nil
        displayStreamingContent = ""
        truncatedDisplayStreamingContent = ""

        insightExtractionTask?.cancel()
        insightExtractionTask = nil
        lastInsightExtraction = .distantPast
        insightsCache = nil
    }
    
    private func estimatedStreamingCharacterTarget() -> Int {
        let fileCount = max(1, scannedFileCount)
        let provider = aiConfig?.provider

        let base = 1200
        let perFile = min(220, max(70, 80 + Int(log2(Double(fileCount) + 1.0) * 14)))
        let complexityBoost = min(2500, fileCount * 18)

        let providerMultiplier: Double
        switch provider {
        case .anthropic:
            providerMultiplier = 1.15
        case .ollama, .openAICompatible:
            providerMultiplier = 1.05
        default:
            providerMultiplier = 1.0
        }

        let estimated = Int(Double(base + (fileCount * perFile) + complexityBoost) * providerMultiplier)
        return min(24_000, max(2_000, estimated))
    }
    
    private func setScannedFiles(_ files: [FileItem]) {
        let publishedFiles = Array(files.prefix(scannedFilesUIPublishLimit))
        scannedFiles = publishedFiles
        scannedFilePathLookup = Dictionary(grouping: publishedFiles, by: { $0.displayName.lowercased() })
            .mapValues { $0.map { $0.path } }
    }
    
    public func didComplete(content: String) {
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The provider returns the parsed plan separately. Keep only a bounded
            // diagnostic tail so streaming, UI, and history do not duplicate an
            // arbitrarily large response.
            streamingContent = Self.retainedStreamCompletion(content)
            retainedStreamingByteCount = streamingContent.utf8.count
            streamingContentRevision &+= 1
            if liveInsightsEnabled {
                syncDisplayContentImmediately()
            }
        }
        isStreaming = false
        organizationStage = aiConfig?.mode == .renameOnly ? "Building rename preview..." : "Building organization plan..."
        stopTimeoutTimer()
    }

    public func didFail(error: Error) {
        isStreaming = false
        errorMessage = userFacingErrorMessage(for: error)
        stopTimeoutTimer()

        // Request user attention for streaming failure
        NotificationManager.shared.requestAttention()
    }

    // MARK: - Timeout Timer

    private func startTimeoutTimer() {
        startTime = Date()
        elapsedTime = 0
        showTimeoutMessage = false

        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            while let self = self, !Task.isCancelled, !self.isCancellationRequested {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled || self.isCancellationRequested { break }

                if let start = self.startTime {
                    self.elapsedTime = Date().timeIntervalSince(start)

                    if self.elapsedTime >= 30 && !self.showTimeoutMessage {
                        self.showTimeoutMessage = true
                    }
                }
            }
        }
    }

    private func stopTimeoutTimer() {
        timeoutTask?.cancel()
        timeoutTask = nil
        startTime = nil
    }

    // MARK: - Main Organization Methods

    /// Start organization - MUST be explicitly called by user action
    public func organize(directory: URL, customPrompt: String? = nil, temperature: Double? = nil) async throws {
        // Guard against auto-start
        guard !isOperationInProgress() else {
            DebugLogger.log("Organization blocked: Already in progress")
            return
        }
        // Never organize with empty/unhydrated exclusion rules.
        await exclusionRules?.loadPersistedState()
        await personaManager?.loadPersistedState()
        await customPersonaStore?.loadPersistedState()
        let reliabilitySpan = ReliabilityManager.shared.startSpan(
            name: "organize",
            operation: "workflow.organize",
            feature: "organize"
        )
        defer { reliabilitySpan?.finish() }

        AnalyticsManager.shared.captureWorkflow(
            workflow: "organize",
            stage: "started",
            outcome: "started",
            properties: [
                "has_custom_instructions": !(customPrompt?.isEmpty ?? true),
                "mode": aiConfig?.mode.rawValue ?? "organize",
            ]
        )

        // Cancel any existing task first
        cancelInternal()
        // Snapshot the intent before analysis starts so a restart forced by
        // macOS (e.g. enabling Full Disk Access) can offer the folder again.
        persistManualSession(directory: directory, plan: nil, stateHint: .interrupted, instructions: customPrompt ?? customInstructions)
        try await runOrganizationTask(directory: directory, customPrompt: customPrompt, temperature: temperature)
    }

    private func runOrganizationTask(
        directory: URL,
        customPrompt: String?,
        temperature: Double?
    ) async throws {
        currentRunInstructions = customPrompt ?? customInstructions
        modelExcludedCurrentRun = false
        withBatchUpdates {
            clearStreamingDisplayState()
            streamFileIDTable = [:]
            isStreaming = false
            showTimeoutMessage = false
            currentInsight = ""
            insightHistory = []
            insightsCache = nil
            isCancellationRequested = false
            userInitiatedAction = true
            visionAnalysisSummary = nil
        }

        currentTask = Task {
            try await performOrganization(
                directory: directory,
                customPrompt: customPrompt,
                temperature: temperature
            )
        }
        defer { currentTask = nil }

        do {
            try await currentTask?.value
        } catch where Self.isCancellationError(error) {
            if suppressCancellationReset {
                suppressCancellationReset = false
                return
            }
            resetToIdle()
        } catch {
            throw error
        }
    }

    private func performOrganization(directory: URL, customPrompt: String?, temperature: Double?) async throws {
        let analyticsStartedAt = Date()
        guard let client = aiClient else {
            let error = OrganizationError.clientNotConfigured
            ReliabilityManager.shared.capture(
                error: error,
                feature: "organize",
                operation: "generate_plan"
            )
            throw error
        }

        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "Organizing folder: \(directory.lastPathComponent)"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        do {
            currentDirectory = directory

            let files = try await scanPhase(directory: directory)

            if files.isEmpty {
                stopTimeoutTimer()

                await MainActor.run {
                    currentPlan = OrganizationPlan(
                        notes: "This folder is empty. Add files and try again."
                    )
                    updateState(.ready, stage: "No files found to organize", progress: 1.0)
                }

                NotificationManager.shared.show(
                    .previewReady(
                        folderName: directory.lastPathComponent,
                        folderPath: directory.path,
                        planID: currentPlan?.id,
                        originSessionID: windowSessionID
                    )
                )
                AnalyticsManager.shared.captureWorkflow(
                    workflow: "organize",
                    stage: "plan_ready",
                    outcome: "empty",
                    properties: AnalyticsManager.durationProperties(
                        Date().timeIntervalSince(analyticsStartedAt)
                    ).merging([
                        "count_bucket": AnalyticsManager.countBucket(0),
                        "result_kind": "empty_directory",
                    ]) { current, _ in current }
                )

                return
            }

            let (filesWithHashes, duplicateContext) = try await duplicateDetectionPhase(files: files)
            let (plan, instructions, personaPrompt, imagePayload) = try await aiAnalysisPhase(
                files: filesWithHashes,
                directory: directory,
                customPrompt: customPrompt,
                temperature: temperature,
                duplicateContext: duplicateContext
            )
            let validatedPlan = try await validationPhase(
                plan: plan,
                files: filesWithHashes,
                directory: directory,
                instructions: instructions,
                personaPrompt: personaPrompt,
                temperature: temperature,
                imagePayload: imagePayload
            )
            handleLearningToolCall(
                from: validatedPlan,
                source: .manual,
                folderPath: directory.path
            )

            try checkCancellation()

            await MainActor.run {
                guard !isCancellationRequested else { return }
                currentPlan = validatedPlan
                resumeCheckpoint = nil
                updateState(.ready, stage: "Ready!", progress: 1.0)
                persistManualSession(directory: directory, plan: validatedPlan, stateHint: .ready, instructions: instructions)
            }

            try checkCancellation()

            NotificationManager.shared.show(
                .previewReady(
                    folderName: directory.lastPathComponent,
                    folderPath: directory.path,
                    planID: validatedPlan.id,
                    originSessionID: windowSessionID
                )
            )

            if let learningsObserver = learningsObserver {
                learningsObserver.startSession(
                    folderPath: directory.path,
                    historyEntryId: nil,
                    learningExcluded: currentRunLearningExcluded
                )
                if !currentRunLearningExcluded {
                    recordPlanRules(plan, observer: learningsObserver)
                }
            }

            AnalyticsManager.shared.captureWorkflow(
                workflow: "organize",
                stage: "plan_ready",
                outcome: "success",
                properties: AnalyticsManager.durationProperties(
                    Date().timeIntervalSince(analyticsStartedAt)
                ).merging([
                    "count_bucket": AnalyticsManager.countBucket(files.count),
                    "result_kind": "organization_plan",
                ]) { current, _ in current }.merging(
                    AnalyticsManager.generationDurationProperties(validatedPlan.generationStats)
                ) { current, _ in current }
            )

        } catch where Self.isCancellationError(error) {
            stopTimeoutTimer()
            resetToIdleUnlessCancellationResetIsSuppressed()
            AnalyticsManager.shared.captureWorkflow(
                workflow: "organize",
                stage: "plan_generation",
                outcome: "cancelled",
                properties: AnalyticsManager.durationProperties(
                    Date().timeIntervalSince(analyticsStartedAt)
                )
            )
            throw CancellationError()
        } catch {
            stopTimeoutTimer()
            handleOrganizationError(error, directory: directory)
            AnalyticsManager.shared.captureWorkflow(
                workflow: "organize",
                stage: "plan_generation",
                outcome: "failed",
                properties: AnalyticsManager.durationProperties(
                    Date().timeIntervalSince(analyticsStartedAt)
                )
            )
            ReliabilityManager.shared.capture(
                error: error,
                feature: "organize",
                operation: "generate_plan"
            )
            throw error
        }
    }

    // MARK: - Organization Phases

    private func scanPhase(directory: URL) async throws -> [FileItem] {
        let usesDeepScan = (aiConfig?.enableDeepScan ?? false)
            && (aiConfig?.provider.supportsDeepScan ?? true)
        let scanStagePrefix = usesDeepScan
            ? "Scanning and analyzing file content"
            : "Fast Mode: scanning file names and folder context"
        updateState(.scanning, stage: "\(scanStagePrefix)...", progress: 0.05)

        try checkCancellation()

        // Set up deep scan progress reporting
        await scanner.setDeepScanProgressCallback { [weak self] current, _ in
            guard current == 1 || current.isMultiple(of: 25) else { return }
            Task { @MainActor in
                self?.deepScanProgress = (current: current, total: 0)
                self?.organizationStage = "Analyzing file content: \(current) files..."
            }
        }
        await scanner.setScanProgressCallback { [weak self] current in
            Task { @MainActor in
                guard let self, !self.isCancellationRequested else { return }
                self.scannedFileCount = current
                self.organizationStage =
                    "\(scanStagePrefix): \(GenerationStats.formatCount(current)) files found..."
            }
        }

        if let keywords = aiConfig?.customOCRKeywords {
            await scanner.setCustomOCRKeywords(keywords)
        }
        await scanner.setOCRLanguages(aiConfig?.ocrLanguages ?? ["en-US"])

        let exclusionMatcher = exclusionRules?.matcherSnapshot()
        blockingExclusionRule = exclusionRules?.blockingRule(forDirectoryAt: directory)
        let filesFound: [FileItem]
        do {
            filesFound = try await scanner.scanDirectory(
                at: directory,
                deepScan: usesDeepScan,
                deepScanFileLimit: Self.deepScanFileLimit,
                exclusionMatcher: exclusionMatcher
            )
        } catch {
            await scanner.setScanProgressCallback(nil)
            await scanner.setDeepScanProgressCallback(nil)
            throw error
        }
        await scanner.setScanProgressCallback(nil)
        await scanner.setDeepScanProgressCallback(nil)
        scannedFileCount = filesFound.count
        setScannedFiles(filesFound)

        deepScanProgress = nil

        // Check if scan was degraded due to memory pressure
        if await scanner.lastScanWasDegraded, let reason = await scanner.degradationReason {
            updateProgress(0.12, stage: "⚠️ \(reason)")
            try? await Task.sleep(for: .seconds(1.5))
        }

        let scanResult = exclusionMatcher?.isEmpty == false
            ? "Found \(filesFound.count) files after exclusions"
            : "Found \(filesFound.count) files"
        let scanResultStage = usesDeepScan
            ? "\(scanResult); content is ready for analysis"
            : "Fast Mode: \(scanResult.lowercased())"
        updateProgress(0.20, stage: scanResultStage)

        try checkCancellation()

        return filesFound
    }

    private func duplicateDetectionPhase(files: [FileItem]) async throws -> ([FileItem], String) {
        guard aiConfig?.detectDuplicates ?? false else {
            detectedDuplicates = []
            return (files, "")
        }

        updateProgress(0.21, stage: "Checking for duplicates...")

        let detector = DuplicateDetector()
        let result = await detector.findExactDuplicates(in: files) { [weak self] completed, total in
            guard let self, total > 0 else { return }
            self.updateProgress(
                0.21,
                stage: "Checking \(completed.formatted()) of \(total.formatted()) duplicate candidates..."
            )
        }
        try checkCancellation()
        let duplicates = result.groups
        await MainActor.run {
            self.detectedDuplicates = duplicates
        }

        return (files, PromptContextHelper.duplicateContext(from: duplicates))
    }

    private func aiAnalysisPhase(
        files: [FileItem],
        directory: URL,
        customPrompt: String?,
        temperature: Double?,
        duplicateContext: String
    ) async throws -> (OrganizationPlan, String, String?, [String: Data]) {
        updateState(.organizing, stage: "Connecting to AI provider...", progress: 0.22)
        await MainActor.run {
            isStreaming = false
            measuredWorkProgress = nil
            aiAnalysisActivity = .requesting
        }

        startTimeoutTimer()

        try checkCancellation()

        let personaPrompt: String? = if let personaManager {
            if let customPersonaStore {
                personaManager.getEffectivePrompt(customStore: customPersonaStore)
            } else {
                personaManager.getPrompt(for: personaManager.selectedPersona)
            }
        } else {
            nil
        }

        let directInstructions = customPrompt ?? customInstructions
        var instructions = PromptBuilder.wrapDirectUserInstructions(directInstructions)
        if let referenceContext = fileReferenceContext(from: directInstructions, in: directory) {
            instructions += "\n\n" + referenceContext
        }
        if !duplicateContext.isEmpty {
            instructions += duplicateContext
        }

        let isRenameOnly = aiConfig?.mode == .renameOnly
        instructions += exclusionInstructions(forRenameOnly: isRenameOnly)

        if let learnedContext = learningsManager?.generatePromptContext(forFolder: directory.path), !learnedContext.isEmpty {
            instructions += "\n\n" + learnedContext
            DebugLogger.log("Injected Learnings context into prompt")
        }

        if !isRenameOnly,
           let modelDirContext = learningsManager?.generateModelDirectoryContext(for: files),
           !modelDirContext.isEmpty {
            instructions += "\n\n" + modelDirContext
            DebugLogger.log("Injected Model Directory reference context into prompt")
        }

        if !isRenameOnly, let directoryManifest = PromptBuilder.buildDirectoryManifestContext(baseDirectoryURL: directory, files: files) {
            instructions += "\n\n" + directoryManifest
            DebugLogger.log("Injected source folder context into prompt")
        }

        if !isRenameOnly, let storageContext = await storageLocationsManager?.generatePromptContext(), !storageContext.isEmpty {
            let sourceDir = StorageLocationPathResolver.canonicalPath(directory.path)
            let enabledLocations = storageLocationsManager?.enabledLocations ?? []

            var sourceDirClause = """
            11. The source directory you are organizing is: "\(sourceDir)".
                CRITICAL: The source directory and storage locations are completely separate filesystem locations.
                To route a file to storage, copy the EXACT path from VALID_STORAGE_PATHS or KNOWN_STORAGE_SUBFOLDERS.
                Do NOT build storage paths by appending folder names to the source directory.
                Non-storage destinations must use short relative names (no leading /).
            """

            if let firstLocation = enabledLocations.first {
                let storagePath = StorageLocationPathResolver.canonicalPath(firstLocation.path)
                let storageName = URL(fileURLWithPath: storagePath).lastPathComponent
                sourceDirClause += """

                ✗ WRONG: "\(sourceDir)/\(storageName)" — this is inside the source, NOT a storage location.
                ✓ RIGHT: "\(storagePath)" — copy the exact path from VALID_STORAGE_PATHS.
                """
            }

            instructions += "\n\n" + storageContext + "\n" + sourceDirClause
            DebugLogger.log("Injected Storage Locations context into prompt")
        }

        if !isRenameOnly, let existingFoldersContext = PromptBuilder.buildExistingFoldersContext(at: directory) {
            instructions += "\n\n" + existingFoldersContext
            DebugLogger.log("Injected Existing Folders context into prompt")
        }

        let imagePayload: [String: Data] = [:]

        let visionEnabled = aiConfig?.enableVision ?? false
        let currentModel = aiConfig?.model ?? ""
        let currentProvider = aiConfig?.provider ?? .openAICompatible
        let modelSupportsVision = ModelCatalog.shared.supportsVision(modelId: currentModel, provider: currentProvider)
        let shouldLimitVisionImages = aiConfig?.limitVisionImages ?? true
        let configuredBatchSize = max(1, aiConfig?.visionBatchSize ?? 12)
        let visionSelectionLimit: Int
        if shouldLimitVisionImages {
            visionSelectionLimit = configuredBatchSize
        } else if files.count > 10_000 {
            visionSelectionLimit = 100
        } else {
            visionSelectionLimit = files.count
        }
        let visionSelection = visionEnabled
            ? boundedVisionSelection(
                from: files,
                batchSize: visionSelectionLimit,
                strategy: aiConfig?.visionBatchStrategy ?? .noText,
                fileBatchSize: shouldLimitVisionImages
                    ? (isRenameOnly ? Self.renameAnalysisBatchSize : Self.organizeAnalysisBatchSize)
                    : nil
            )
            : (selected: [], total: 0)

        if visionSelection.total > 0 && modelSupportsVision {
            let selectedBatch = visionSelection.selected
            let totalImageCount = visionSelection.total
            preparedVisionAttachmentNames.removeAll(keepingCapacity: true)
            visionPreparationFailureCount = 0
            visionPreparationByteLimitSkipCount = 0
            visionAnalysisSummary = VisionAnalysisSummary(
                analyzedCount: 0,
                totalImageCount: totalImageCount,
                skippedCount: max(0, totalImageCount - selectedBatch.count),
                failedCount: 0,
                warningMessage: nil
            )
        } else if visionSelection.total > 0 && !modelSupportsVision {
            let warning = "Vision is enabled but \(currentProvider.displayName) (\(currentModel)) doesn't support multimodal analysis. Results will use text-only analysis."
            visionAnalysisSummary = VisionAnalysisSummary(
                analyzedCount: 0,
                totalImageCount: visionSelection.total,
                skippedCount: visionSelection.total,
                failedCount: 0,
                warningMessage: warning
            )
            DebugLogger.log(warning)
        } else {
            visionAnalysisSummary = nil
        }

        guard let client = aiClient else {
            throw OrganizationError.clientNotConfigured
        }

        let plan = try await analyzeInBoundedBatches(
            files: files,
            client: client,
            imagePayload: imagePayload,
            visionFiles: modelSupportsVision ? visionSelection.selected : [],
            instructions: instructions,
            personaPrompt: personaPrompt,
            temperature: temperature,
            directory: directory
        )

        try checkCancellation()

        stopTimeoutTimer()

        return (plan, instructions, personaPrompt, imagePayload)
    }

    private func analyzeInBoundedBatches(
        files: [FileItem],
        client: AIClientProtocol,
        imagePayload: [String: Data],
        visionFiles: [FileItem] = [],
        instructions: String,
        personaPrompt: String?,
        temperature: Double?,
        modeOverride: OrganizationMode? = nil,
        directory: URL? = nil,
        resuming checkpoint: OrganizationResumeCheckpoint? = nil
    ) async throws -> OrganizationPlan {
        let mode = checkpoint?.mode ?? modeOverride ?? aiConfig?.mode ?? client.config.mode
        let resolvedDirectory = checkpoint?.directory ?? directory ?? currentDirectory
        var completeInstructions = checkpoint?.instructions ?? instructions
        if mode != .renameOnly,
           !completeInstructions.contains("## SOURCE FOLDER CONTEXT"),
           let resolvedDirectory,
           let manifest = PromptBuilder.buildDirectoryManifestContext(
               baseDirectoryURL: resolvedDirectory,
               files: files
           ) {
            completeInstructions += "\n\n" + manifest
        }
        if mode == .renameOnly,
           !completeInstructions.contains("## FINDER-TAGGED FOLDERS IN SCOPE"),
           let resolvedDirectory,
           let finderTagContext = PromptBuilder.buildFinderTaggedFolderContext(
               baseDirectoryURL: resolvedDirectory,
               files: files
           ) {
            completeInstructions += "\n\n" + finderTagContext
        }
        let batchSize = mode == .organize
            ? Self.organizeAnalysisBatchSize
            : Self.renameAnalysisBatchSize
        let batchCount = max(1, (files.count + batchSize - 1) / batchSize)

        aiAnalysisActivity = .requesting

        let analysisStart = Date()
        let accumulator = LargeFolderPlanAccumulator()
        var taxonomy: [String] = []
        var retainedNotes: [String] = []
        var totalResponseTokens = 0
        var totalPromptTokens = 0
        var hasPromptTokenCount = false
        var firstTTFT: TimeInterval?
        var estimatedCost = Decimal.zero
        var hasEstimatedCost = false
        var completedAnalysisBatchCount = 0
        var completedPlans = checkpoint?.completedPlans ?? []

        for completedPlan in completedPlans {
            taxonomy = await accumulator.merge(completedPlan)
            if let stats = completedPlan.generationStats {
                totalResponseTokens += stats.totalTokens
                if let promptTokens = stats.promptTokens {
                    totalPromptTokens += promptTokens
                    hasPromptTokenCount = true
                }
                if firstTTFT == nil {
                    firstTTFT = stats.ttft
                }
                if let cost = stats.estimatedCost {
                    estimatedCost += cost
                    hasEstimatedCost = true
                }
            }
            completedAnalysisBatchCount += 1
        }

        if let resolvedDirectory {
            resumeCheckpoint = OrganizationResumeCheckpoint(
                files: files,
                directory: resolvedDirectory,
                instructions: completeInstructions,
                personaPrompt: personaPrompt,
                imagePayload: imagePayload,
                visionFiles: visionFiles,
                temperature: temperature,
                mode: mode,
                completedPlans: completedPlans,
                nextBatchIndex: checkpoint?.nextBatchIndex ?? 0
            )
        }

        for batchIndex in (checkpoint?.nextBatchIndex ?? 0)..<batchCount {
            try checkCancellation()

            let start = batchIndex * batchSize
            let end = min(start + batchSize, files.count)
            let batch = Array(files[start..<end])
            let completedBeforeRequest = batchIndex
            let phaseProgress = 0.30 + (Double(completedBeforeRequest) / Double(batchCount)) * 0.52
            let suggestionAction = mode == .renameOnly ? "Finding better names" : "Finding the best folders"
            let planningStage = batchCount > 1
                ? "\(suggestionAction) for \(GenerationStats.formatCount(end)) of \(GenerationStats.formatCount(files.count)) files..."
                : "\(suggestionAction) for \(GenerationStats.formatCount(files.count)) files..."
            updateMeasuredProgress(
                completed: completedBeforeRequest,
                total: batchCount,
                estimatedOverallProgress: phaseProgress,
                stage: planningStage
            )

            var batchInstructions = completeInstructions
            if batchCount > 1 {
                batchInstructions += Self.largeFolderBatchContext(
                    batchIndex: batchIndex,
                    batchCount: batchCount,
                    taxonomy: taxonomy,
                    mode: mode
                )
            }

            startTimeoutTimer()
            let batchPlans = try await analyzeBatchAdaptively(
                files: batch,
                client: client,
                imagePayload: imagePayload,
                visionFiles: visionFiles,
                visionBaseDirectory: resolvedDirectory,
                instructions: batchInstructions,
                personaPrompt: personaPrompt,
                temperature: temperature
            )

            try checkCancellation()
            completedAnalysisBatchCount += batchPlans.count

            for batchPlan in batchPlans {
                if let stats = batchPlan.generationStats {
                    totalResponseTokens += stats.totalTokens
                    if let promptTokens = stats.promptTokens {
                        totalPromptTokens += promptTokens
                        hasPromptTokenCount = true
                    }
                    if firstTTFT == nil {
                        firstTTFT = stats.ttft
                    }
                    if let cost = stats.estimatedCost {
                        estimatedCost += cost
                        hasEstimatedCost = true
                    }
                }
                let note = batchPlan.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty, retainedNotes.count < 3, !retainedNotes.contains(note) {
                    retainedNotes.append(note)
                }

                taxonomy = await accumulator.merge(batchPlan)
            }
            completedPlans.append(contentsOf: batchPlans)
            resumeCheckpoint?.completedPlans = completedPlans
            resumeCheckpoint?.nextBatchIndex = batchIndex + 1

            let completed = batchIndex + 1
            let completedProgress = 0.30 + (Double(completed) / Double(batchCount)) * 0.52
            updateMeasuredProgress(
                completed: completed,
                total: batchCount,
                estimatedOverallProgress: completedProgress,
                stage: "Found suggestions for \(GenerationStats.formatCount(end)) of \(GenerationStats.formatCount(files.count)) files"
            )
        }

        var mergedPlan = await accumulator.result()
        let duration = Date().timeIntervalSince(analysisStart)
        let totalFileSize = await Task.detached(priority: .utility) {
            files.reduce(Int64.zero) { partial, file in
                let (sum, overflow) = partial.addingReportingOverflow(file.size)
                return overflow ? Int64.max : sum
            }
        }.value
        let model = client.config.model
        let provider = client.config.provider.displayName
        let summary = batchCount > 1
            ? "Analyzed \(GenerationStats.formatCount(files.count)) files across \(completedAnalysisBatchCount) AI requests."
            : "Analyzed \(GenerationStats.formatCount(files.count)) files."
        mergedPlan.notes = ([summary] + retainedNotes).joined(separator: " ")
        mergedPlan.generationStats = GenerationStats(
            duration: duration,
            tps: duration > 0 ? Double(totalResponseTokens) / duration : 0,
            ttft: firstTTFT ?? 0,
            totalTokens: totalResponseTokens,
            model: model,
            filesScanned: files.count,
            totalFileSize: totalFileSize,
            promptTokens: hasPromptTokenCount ? totalPromptTokens : nil,
            provider: provider,
            estimatedCost: hasEstimatedCost ? estimatedCost : nil
        )
        clearMeasuredProgress(
            estimatedOverallProgress: 0.84,
            stage: mode == .renameOnly ? "Checking name suggestions..." : "Checking organization plan..."
        )
        return mergedPlan
    }

    public func resumeOrganization() async throws {
        guard let checkpoint = resumeCheckpoint,
              let client = aiClient else {
            throw OrganizationError.noCurrentPlan
        }

        cancelInternal()
        isCancellationRequested = false
        clearStreamingDisplayState()
        updateState(
            .organizing,
            stage: "Continuing \(checkpoint.mode.displayName)...",
            progress: 0.30
        )

        currentTask = Task {
            let plan = try await analyzeInBoundedBatches(
                files: checkpoint.files,
                client: client,
                imagePayload: checkpoint.imagePayload,
                visionFiles: checkpoint.visionFiles,
                instructions: checkpoint.instructions,
                personaPrompt: checkpoint.personaPrompt,
                temperature: checkpoint.temperature,
                modeOverride: checkpoint.mode,
                directory: checkpoint.directory,
                resuming: checkpoint
            )
            let validatedPlan = try await validationPhase(
                plan: plan,
                files: checkpoint.files,
                directory: checkpoint.directory,
                instructions: checkpoint.instructions,
                personaPrompt: checkpoint.personaPrompt,
                temperature: checkpoint.temperature,
                imagePayload: checkpoint.imagePayload
            )
            handleLearningToolCall(
                from: validatedPlan,
                source: .manual,
                folderPath: checkpoint.directory.path
            )
            currentPlan = validatedPlan
            resumeCheckpoint = nil
            updateState(.ready, stage: "Ready!", progress: 1.0)
        }
        defer { currentTask = nil }

        do {
            try await currentTask?.value
        } catch where Self.isCancellationError(error) {
            stopTimeoutTimer()
            resetToIdleUnlessCancellationResetIsSuppressed()
            throw CancellationError()
        } catch {
            stopTimeoutTimer()
            handleOrganizationError(error, directory: checkpoint.directory)
            throw error
        }
    }

    nonisolated private static func isTimeoutFailure(_ error: Error) -> Bool {
        if let clientError = error as? AIClientError,
           case .networkError(let underlyingError) = clientError {
            let underlyingNSError = underlyingError as NSError
            if underlyingNSError.domain == NSURLErrorDomain,
               underlyingNSError.code == NSURLErrorTimedOut {
                return true
            }
        }
        let description = error.localizedDescription.lowercased()
        if description.contains("timeout") || description.contains("timed out") {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    private func analyzeBatchAdaptively(
        files: [FileItem],
        client: AIClientProtocol,
        imagePayload: [String: Data],
        visionFiles: [FileItem] = [],
        visionBaseDirectory: URL? = nil,
        instructions: String,
        personaPrompt: String?,
        temperature: Double?
    ) async throws -> [OrganizationPlan] {
        try checkCancellation()

        // Compact prompts number this request's files 1-based; publish the same
        // mapping so the live-stream UI can resolve `file_ids` while streaming.
        streamFileIDTable = Dictionary(
            uniqueKeysWithValues: files.enumerated().map { ($0.offset + 1, $0.element) }
        )

        let fileNames = Set(files.map(visionAttachmentName))
        var batchImages = imagePayload.filter { fileNames.contains($0.key) }
        if batchImages.isEmpty, let visionBaseDirectory {
            let selectedFiles = visionFiles.filter {
                fileNames.contains(visionAttachmentName(for: $0))
            }
            batchImages = try await prepareVisionPayload(
                for: selectedFiles,
                baseDirectory: visionBaseDirectory
            )
        }
        let requestInstructions = batchImages.isEmpty
            ? instructions
            : instructions + "\n\n" + visionPromptInstructions(
                for: batchImages.keys.sorted()
            )

        do {
            let plan: OrganizationPlan
            if batchImages.isEmpty {
                plan = try await client.analyze(
                    files: files,
                    customInstructions: requestInstructions,
                    personaPrompt: personaPrompt,
                    temperature: temperature
                )
            } else {
                plan = try await client.analyzeWithImages(
                    files: files,
                    imageData: batchImages,
                    customInstructions: requestInstructions,
                    personaPrompt: personaPrompt,
                    temperature: temperature
                )
            }
            return [plan]
        } catch {
            try checkCancellation()
            guard Self.shouldSplitAnalysisBatch(after: error, fileCount: files.count) else {
                throw error
            }

            let splitIndex = files.count / 2
            let firstFiles = Array(files[..<splitIndex])
            let secondFiles = Array(files[splitIndex...])
            LogManager.shared.log(
                "Retrying a failed \(files.count)-file AI request as separate requests for \(firstFiles.count) and \(secondFiles.count) files.",
                level: .warning,
                category: "FolderOrganizer"
            )
            organizationStage = "Retrying with fewer files at a time..."

            let recoveryInstructions = instructions + """

            ADAPTIVE RETRY
            - The previous larger request could not produce a complete valid plan.
            - Return a complete plan for only the files in this smaller request.
            """
            let firstPlans = try await analyzeBatchAdaptively(
                files: firstFiles,
                client: client,
                imagePayload: batchImages,
                visionFiles: [],
                visionBaseDirectory: nil,
                instructions: recoveryInstructions,
                personaPrompt: personaPrompt,
                temperature: temperature
            )
            let secondPlans = try await analyzeBatchAdaptively(
                files: secondFiles,
                client: client,
                imagePayload: batchImages,
                visionFiles: [],
                visionBaseDirectory: nil,
                instructions: recoveryInstructions,
                personaPrompt: personaPrompt,
                temperature: temperature
            )
            return firstPlans + secondPlans
        }
    }

    nonisolated private static func shouldSplitAnalysisBatch(
        after error: Error,
        fileCount: Int
    ) -> Bool {
        guard fileCount > minimumAdaptiveAnalysisBatchSize else { return false }

        if let clientError = error as? AIClientError {
            switch clientError {
            case .invalidResponseFormat, .jsonDecodingError:
                return true
            case .apiError(let statusCode, let message):
                if statusCode == 413 {
                    return true
                }
                let description = message.lowercased()
                return description.contains("output limit") ||
                    description.contains("context length") ||
                    description.contains("maximum context") ||
                    description.contains("max_tokens") ||
                    description.contains("too many tokens")
            default:
                break
            }
        }

        let description = error.localizedDescription.lowercased()
        return description.contains("output limit") ||
            description.contains("context length") ||
            description.contains("maximum context") ||
            description.contains("too many tokens")
    }

    nonisolated private static func largeFolderBatchContext(
        batchIndex: Int,
        batchCount: Int,
        taxonomy: [String],
        mode: OrganizationMode
    ) -> String {
        let taxonomyContext: String
        if mode == .renameOnly || taxonomy.isEmpty {
            taxonomyContext = ""
        } else {
            taxonomyContext = """

            Reuse these destination paths from earlier batches whenever they fit:
            \(taxonomy.map { "- \($0)" }.joined(separator: "\n"))
            """
        }

        return """

        LARGE FOLDER BATCH \(batchIndex + 1) OF \(batchCount)
        - This request contains a complete, disjoint batch from one larger folder.
        - File IDs are local to this batch. Include every file in this batch exactly once.
        - Keep decisions consistent across batches and do not invent wrapper folders just because this is a batch.
        - Reuse the same nested folder structure across batches; never alternate between "Parent/Child" and a Parent folder containing Child.
        \(taxonomyContext)
        """
    }

    nonisolated private static func mergeLargeFolderBatch(
        _ incomingPlan: OrganizationPlan,
        into accumulatedPlan: inout OrganizationPlan
    ) {
        let incoming = normalizingDestinationHierarchy(
            in: removingDuplicateAssignments(from: incomingPlan)
        )
        mergeSuggestions(incoming.suggestions, into: &accumulatedPlan.suggestions)
        accumulatedPlan.unorganizedFiles.append(contentsOf: incoming.unorganizedFiles)
        accumulatedPlan.unorganizedDetails.append(contentsOf: incoming.unorganizedDetails)
        if accumulatedPlan.learningToolCall == nil {
            accumulatedPlan.learningToolCall = incoming.learningToolCall
        }
    }

    nonisolated static func normalizingDestinationHierarchy(
        in plan: OrganizationPlan
    ) -> OrganizationPlan {
        var normalized = plan
        normalized.suggestions = []
        mergeSuggestions(plan.suggestions, into: &normalized.suggestions)
        return normalized
    }

    nonisolated private static func removingDuplicateAssignments(
        from plan: OrganizationPlan
    ) -> OrganizationPlan {
        var updated = plan
        var claimedFileIDs: Set<UUID> = []

        func prune(_ folder: FolderSuggestion) -> FolderSuggestion {
            var result = folder
            result.files = folder.files.filter { claimedFileIDs.insert($0.id).inserted }
            let retainedIDs = Set(result.files.map(\.id))
            result.fileRenameMappings = folder.fileRenameMappings.filter {
                retainedIDs.contains($0.originalFile.id)
            }
            result.fileTagMappings = folder.fileTagMappings.filter {
                retainedIDs.contains($0.originalFile.id)
            }
            result.subfolders = folder.subfolders.map(prune)
            return result
        }

        updated.suggestions = plan.suggestions.map(prune)
        updated.unorganizedFiles = plan.unorganizedFiles.filter {
            claimedFileIDs.insert($0.id).inserted
        }
        let unorganizedNames = Set(updated.unorganizedFiles.map(\.displayName))
        updated.unorganizedDetails = plan.unorganizedDetails.filter {
            unorganizedNames.contains($0.filename)
        }
        return updated
    }

    nonisolated private static func mergeSuggestions(
        _ incoming: [FolderSuggestion],
        into existing: inout [FolderSuggestion]
    ) {
        var existingIndexByKey = Dictionary(
            existing.enumerated().map {
                (normalizedDestinationKey($0.element.folderName), $0.offset)
            },
            uniquingKeysWith: { first, _ in first }
        )

        for rawSuggestion in incoming {
            let suggestion = hierarchizedSuggestion(rawSuggestion)
            let key = normalizedDestinationKey(suggestion.folderName)
            if let index = existingIndexByKey[key] {
                existing[index] = mergeFolderSuggestion(suggestion, into: existing[index])
            } else {
                existingIndexByKey[key] = existing.count
                existing.append(suggestion)
            }
        }
    }

    nonisolated private static func hierarchizedSuggestion(
        _ suggestion: FolderSuggestion
    ) -> FolderSuggestion {
        var recursivelyNormalized = suggestion
        recursivelyNormalized.subfolders = []
        mergeSuggestions(suggestion.subfolders, into: &recursivelyNormalized.subfolders)
        guard !suggestion.folderName.hasPrefix("/") else {
            return recursivelyNormalized
        }

        let components = suggestion.folderName
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        guard components.count > 1, let leafName = components.last else {
            return recursivelyNormalized
        }

        var nested = recursivelyNormalized
        nested.folderName = leafName
        for component in components.dropLast().reversed() {
            nested = FolderSuggestion(
                folderName: component,
                subfolders: [nested]
            )
        }
        return nested
    }

    nonisolated private static func mergeFolderSuggestion(
        _ incoming: FolderSuggestion,
        into existing: FolderSuggestion
    ) -> FolderSuggestion {
        var merged = existing
        merged.files.append(contentsOf: incoming.files)
        merged.fileRenameMappings.append(contentsOf: incoming.fileRenameMappings)
        merged.fileTagMappings.append(contentsOf: incoming.fileTagMappings)
        merged.tags = Array(Set(existing.tags).union(incoming.tags)).sorted()
        merged.semanticTags = Array(Set(existing.semanticTags).union(incoming.semanticTags)).sorted()
        if merged.description.isEmpty {
            merged.description = incoming.description
        }
        if merged.reasoning.isEmpty {
            merged.reasoning = incoming.reasoning
        }
        if merged.comment == nil {
            merged.comment = incoming.comment
        }
        if merged.confidenceScore == nil {
            merged.confidenceScore = incoming.confidenceScore
        }
        if merged.ruleId == nil {
            merged.ruleId = incoming.ruleId
        }
        mergeSuggestions(incoming.subfolders, into: &merged.subfolders)
        return merged
    }

    nonisolated private static func normalizedDestinationKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    nonisolated private static func destinationTaxonomy(
        in plan: OrganizationPlan,
        limit: Int
    ) -> [String] {
        var result: [String] = []

        func collect(_ folders: [FolderSuggestion], parent: String?) {
            for folder in folders where result.count < limit {
                let path: String
                if folder.folderName.hasPrefix("/") || parent == nil || parent?.isEmpty == true {
                    path = folder.folderName
                } else {
                    path = "\(parent!)/\(folder.folderName)"
                }
                result.append(String(path.prefix(180)))
                collect(folder.subfolders, parent: path)
            }
        }

        collect(plan.suggestions, parent: nil)
        return result
    }

    private func boundedVisionSelection(
        from files: [FileItem],
        batchSize: Int,
        strategy: VisionBatchStrategy,
        fileBatchSize: Int? = nil
    ) -> (selected: [FileItem], total: Int) {
        if let fileBatchSize, files.count > fileBatchSize {
            var selected: [FileItem] = []
            var total = 0
            for start in stride(from: 0, to: files.count, by: fileBatchSize) {
                let end = min(start + fileBatchSize, files.count)
                let selection = boundedVisionSelection(
                    from: Array(files[start..<end]),
                    batchSize: batchSize,
                    strategy: strategy
                )
                selected.append(contentsOf: selection.selected)
                total += selection.total
            }
            return (selected, total)
        }

        let safeBatchSize = max(1, batchSize)
        var selected: [FileItem] = []
        selected.reserveCapacity(min(safeBatchSize, files.count))
        var total = 0

        func isVisionImage(_ file: FileItem) -> Bool {
            visionImageExtensions.contains(file.extension.lowercased())
        }

        switch strategy {
        case .firstN:
            for file in files where isVisionImage(file) {
                total += 1
                if selected.count < safeBatchSize {
                    selected.append(file)
                }
            }
        case .random:
            for file in files where isVisionImage(file) {
                total += 1
                if selected.count < safeBatchSize {
                    selected.append(file)
                } else {
                    let replacementIndex = Int.random(in: 0..<total)
                    if replacementIndex < safeBatchSize {
                        selected[replacementIndex] = file
                    }
                }
            }
        case .noText:
            for file in files where isVisionImage(file) {
                total += 1
                selected.append(file)
                if selected.count > safeBatchSize * 2 {
                    selected.sort(by: visionPriority)
                    selected.removeLast(selected.count - safeBatchSize)
                }
            }
            selected.sort(by: visionPriority)
            if selected.count > safeBatchSize {
                selected.removeLast(selected.count - safeBatchSize)
            }
        }

        return (selected, total)
    }

    private func prepareVisionPayload(
        for files: [FileItem],
        baseDirectory: URL
    ) async throws -> [String: Data] {
        guard !files.isEmpty else { return [:] }

        aiAnalysisActivity = .preparingImages
        var payload: [String: Data] = [:]
        var preparedByteCount = 0

        for file in files {
            try checkCancellation()
            let prepared = await visionAnalyzer.prepareFilesForVision(
                files: [file],
                baseDirectoryURL: baseDirectory
            )
            if prepared.isEmpty {
                visionPreparationFailureCount += 1
                continue
            }

            for (name, data) in prepared.sorted(by: { $0.key < $1.key }) {
                guard preparedByteCount + data.count <= Self.maximumPreparedVisionBytes else {
                    visionPreparationByteLimitSkipCount += 1
                    continue
                }
                payload[name] = data
                preparedByteCount += data.count
                preparedVisionAttachmentNames.insert(name)
            }
        }

        if let summary = visionAnalysisSummary {
            visionAnalysisSummary = VisionAnalysisSummary(
                analyzedCount: preparedVisionAttachmentNames.count,
                totalImageCount: summary.totalImageCount,
                skippedCount: max(
                    0,
                    summary.totalImageCount
                        - preparedVisionAttachmentNames.count
                        - visionPreparationFailureCount
                ),
                failedCount: visionPreparationFailureCount,
                warningMessage: visionPreparationByteLimitSkipCount > 0
                    ? "Some images were skipped to keep vision memory below 32 MB per request."
                    : nil
            )
        }
        aiAnalysisActivity = .requesting
        DebugLogger.log(
            "Prepared \(payload.count) vision attachments using \(preparedByteCount) bytes for the next AI request"
        )
        return payload
    }

    private func visionPriority(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
                let lhsHasOCR = !(lhs.contentMetadata?.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let rhsHasOCR = !(rhs.contentMetadata?.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                if lhsHasOCR != rhsHasOCR {
                    return !lhsHasOCR
                }
                let lhsDate = lhs.modificationDate ?? lhs.creationDate ?? .distantPast
                let rhsDate = rhs.modificationDate ?? rhs.creationDate ?? .distantPast
                return lhsDate > rhsDate
    }

    private func visionPromptInstructions(for analyzedImageFilenames: [String]) -> String {
        let fileList = analyzedImageFilenames
            .enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        return """

        ## AI VISION CONTEXT
        I've attached \(analyzedImageFilenames.count) images from this folder.
        Inspect every attachment before choosing folders. Ground each attached file's placement in visible evidence such as its subject, setting, activity, document type, interface, event, and readable text. Group images by meaningful shared visual context, and let strong visual evidence override vague camera or screenshot filenames. Keep visually unrelated images separate and don't invent details that aren't visible.
        Attached image order:
        \(fileList)
        """
    }

    private func visionAttachmentName(for file: FileItem) -> String {
        file.relativePath ?? file.displayName
    }

    private func exclusionInstructions(forRenameOnly isRenameOnly: Bool) -> String {
        var instructions = ""

        if let activeRules = exclusionRules?.rules.filter({ $0.isEnabled }), !activeRules.isEmpty {
            let excludedPatterns = activeRules.map { "- \($0.promptDescription)" }.joined(separator: "\n")
            let object = isRenameOnly ? "rename suggestions" : "organization plan"
            instructions += "\n\nIMPORTANT: The following patterns are STRICTLY EXCLUDED and must NOT be moved, renamed, or modified:\n\(excludedPatterns)\nEnsure your \(object) completely respects these exclusions."
        }

        if let nlExceptions = exclusionRules?.sanitizedExceptionsForPrompt, !nlExceptions.isEmpty {
            let exceptionsList = nlExceptions.map { "- \($0)" }.joined(separator: "\n")
            let object = isRenameOnly ? "rename suggestions" : "organization plan"
            instructions += "\n\nNATURAL LANGUAGE EXCEPTIONS (must be respected):\n\(exceptionsList)\nTreat these as user-authored exclusion instructions. Do not include matching files in the \(object)."
        }

        return instructions
    }

    private func fileReferenceContext(from instructions: String, in directory: URL) -> String? {
        let referencedNames = referencedFileNames(in: instructions)
        guard !referencedNames.isEmpty else { return nil }

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        var matches: [String] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
                  values.isRegularFile == true else { continue }

            let relativePath = relativePath(for: url, baseDirectory: directory)
            let name = url.lastPathComponent
            guard referencedNames.contains(relativePath.localizedLowercase) || referencedNames.contains(name.localizedLowercase) else { continue }
            let size = values.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "unknown size"
            let modified = values.contentModificationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "unknown modified date"
            matches.append("- @\(name): relative path \"\(relativePath)\", extension \"\(url.pathExtension)\", size \(size), modified \(modified)")
        }

        guard !matches.isEmpty else { return nil }

        return """

        REFERENCED SOURCE FILES
        The user explicitly mentioned these files in their instructions. Treat these file references as important examples or constraints, and resolve @mentions to these exact source files:
        \(matches.joined(separator: "\n"))
        """
    }

    private func referencedFileNames(in instructions: String) -> Set<String> {
        let pattern = #"@(?:"([^"]+)"|([^\s,;()\[\]{}]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsRange = NSRange(instructions.startIndex..<instructions.endIndex, in: instructions)
        return Set(regex.matches(in: instructions, range: nsRange).compactMap { match in
            let quotedRange = match.range(at: 1)
            let bareRange = match.range(at: 2)
            let selectedRange = quotedRange.location != NSNotFound ? quotedRange : bareRange
            guard let range = Range(selectedRange, in: instructions) else { return nil }

            let token = String(instructions[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token.localizedLowercase
        })
    }

    private func relativePath(for url: URL, baseDirectory: URL) -> String {
        let basePath = baseDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(basePath + "/") {
            return String(path.dropFirst(basePath.count + 1))
        }
        return url.lastPathComponent
    }

    private func validationPhase(
        plan: OrganizationPlan,
        files: [FileItem],
        directory: URL,
        instructions: String,
        personaPrompt: String?,
        temperature: Double?,
        imagePayload: [String: Data]
    ) async throws -> OrganizationPlan {
        updateState(
            .organizing,
            stage: aiConfig?.mode == .renameOnly ? "Checking name suggestions..." : "Checking organization plan...",
            progress: 0.85
        )
        await MainActor.run {
            isStreaming = false
            aiAnalysisActivity = .validating
        }

        guard let client = aiClient else {
            throw OrganizationError.clientNotConfigured
        }

        let allowedLocations = storageLocationsManager?.enabledLocations ?? []
        let hierarchyNormalizedPlan = Self.normalizingDestinationHierarchy(in: plan)
        let normalizedInputPlan = normalizeStorageDestinations(
            in: hierarchyNormalizedPlan,
            allowedLocations: allowedLocations,
            sourceDirectoryURL: directory
        )

        var validatedPlanFromRetry: OrganizationPlan? = nil
        do {
            try validator.validate(
                normalizedInputPlan,
                at: directory,
                allowedStorageLocations: allowedLocations,
                mode: aiConfig?.mode ?? .organize
            )
        } catch let validationError as ValidationError {
            if let retryPlan = await retryWithValidationEnhancement(
                files: files,
                client: client,
                validationError: validationError,
                directory: directory,
                instructions: instructions,
                personaPrompt: personaPrompt,
                temperature: temperature,
                imagePayload: imagePayload,
                allowedStorageLocations: allowedLocations
            ) {
                validatedPlanFromRetry = retryPlan
            } else {
                throw validationError
            }
        }

        var planAfterValidation = validatedPlanFromRetry ?? normalizedInputPlan

        if aiConfig?.mode != .renameOnly {
            let existingFolderPaths = PlanQualityEvaluator.existingFolderPaths(at: directory)
            let initialAssessment = PlanQualityEvaluator.assess(
                planAfterValidation,
                existingFolderPaths: existingFolderPaths
            )
            if !initialAssessment.passes {
                if let retryPlan = await retryForPlanQuality(
                    files: files,
                    client: client,
                    assessment: initialAssessment,
                    directory: directory,
                    instructions: instructions,
                    personaPrompt: personaPrompt,
                    temperature: temperature,
                    imagePayload: imagePayload,
                    allowedStorageLocations: allowedLocations
                ) {
                    planAfterValidation = retryPlan
                }

                let rescoredPlan = PlanQualityEvaluator.assess(
                    planAfterValidation,
                    existingFolderPaths: existingFolderPaths
                )
                let retryAssessment = PlanQualityAssessment(
                    score: rescoredPlan.score,
                    issues: rescoredPlan.issues,
                    didRetry: true
                )
                planAfterValidation = PlanQualityEvaluator.keepingCertainItems(
                    in: planAfterValidation,
                    assessment: retryAssessment
                )
            } else {
                planAfterValidation.qualityAssessment = initialAssessment
            }
        }

        try checkCancellation()

        var validatedPlan = planAfterValidation
        if let exclusionRules = exclusionRules {
            let enforcer = ExclusionEnforcer(exclusionManager: exclusionRules)
            self.exclusionEnforcer = enforcer

            let validationResult = enforcer.validate(planAfterValidation)

            if validationResult.hasViolations {
                LogManager.shared.log("Exclusion violations detected: \(validationResult.violationCount) files", category: "FolderOrganizer")

                if let retryPlan = await retryWithExclusionEnhancement(
                    files: files,
                    client: client,
                    violations: validationResult.violations,
                    instructions: instructions,
                    personaPrompt: personaPrompt,
                    temperature: temperature,
                    imagePayload: imagePayload
                ) {
                    let retryValidation = enforcer.validate(retryPlan)
                    if retryValidation.hasViolations {
                        LogManager.shared.log("Retry still has \(retryValidation.violationCount) violations, stripping", category: "FolderOrganizer")
                        validatedPlan = retryValidation.cleanedPlan ?? retryPlan
                    } else {
                        validatedPlan = retryPlan
                    }
                } else {
                    validatedPlan = validationResult.cleanedPlan ?? planAfterValidation
                }
            }
        }

        return normalizeRenameSuggestions(in: applyRenameRuleConfiguration(to: validatedPlan))
    }

    private func applyRenameRuleConfiguration(
        to plan: OrganizationPlan,
        config suppliedConfig: AIConfig? = nil
    ) -> OrganizationPlan {
        guard let config = suppliedConfig ?? aiConfig else { return plan }
        guard config.mode == .renameOnly || config.mode == .organizeAndRename else { return plan }
        guard !config.renameRules.isEmpty else { return plan }

        var updatedPlan = plan
        updatedPlan.suggestions = updatedPlan.suggestions.map {
            applyRenameRules(in: $0, rules: config.renameRules, mode: config.renameRuleMode)
        }
        return updatedPlan
    }

    private func normalizeRenameSuggestions(
        in plan: OrganizationPlan,
        config suppliedConfig: AIConfig? = nil
    ) -> OrganizationPlan {
        guard let config = suppliedConfig ?? aiConfig else { return plan }
        guard config.mode == .renameOnly || config.mode == .organizeAndRename else { return plan }

        var updatedPlan = plan
        updatedPlan.suggestions = updatedPlan.suggestions.map {
            normalizeRenameSuggestions(in: $0, options: config.renameNamingOptions)
        }
        return updatedPlan
    }

    private func normalizeRenameSuggestions(
        in folder: FolderSuggestion,
        options: RenameNamingOptions
    ) -> FolderSuggestion {
        var updated = folder
        var existingNames = Set(updated.files.map(\.displayName))

        for index in updated.fileRenameMappings.indices {
            let mapping = updated.fileRenameMappings[index]
            guard mapping.hasRename, let suggestedName = mapping.suggestedName else { continue }
            guard let normalized = FilenameNormalizer.normalize(
                suggestedName,
                originalFilename: mapping.originalFile.displayName,
                options: options
            ) else {
                updated.fileRenameMappings[index].suggestedName = nil
                continue
            }

            existingNames.remove(mapping.originalFile.displayName)
            let uniqueName = FilenameNormalizer.uniqued(normalized, against: &existingNames)
            updated.fileRenameMappings[index].suggestedName =
                uniqueName == mapping.originalFile.displayName ? nil : uniqueName
        }

        updated.subfolders = updated.subfolders.map {
            normalizeRenameSuggestions(in: $0, options: options)
        }
        return updated
    }

    private func applyRenameRules(
        in folder: FolderSuggestion,
        rules: [RenameRule],
        mode: RenameRuleApplicationMode
    ) -> FolderSuggestion {
        var updated = folder
        var mappingIndices = Dictionary(
            updated.fileRenameMappings.enumerated().map {
                ($0.element.originalFile.id, $0.offset)
            },
            uniquingKeysWith: { _, latest in latest }
        )

        func updateRename(
            for file: FileItem,
            newName: String?,
            reason: String?
        ) {
            let sanitizedName: String?
            if let newName, !newName.isEmpty {
                sanitizedName = FilenameSanitizer.sanitize(
                    newName,
                    preservingExtension: file.extension,
                    enforceExtension: true
                ).sanitizedName
            } else {
                sanitizedName = nil
            }
            let finalName = sanitizedName == file.displayName ? nil : sanitizedName

            if let index = mappingIndices[file.id] {
                updated.fileRenameMappings[index].suggestedName = finalName
                updated.fileRenameMappings[index].isSelected = finalName != nil
                if let reason {
                    updated.fileRenameMappings[index].renameReason = reason
                }
            } else if finalName != nil {
                mappingIndices[file.id] = updated.fileRenameMappings.count
                updated.fileRenameMappings.append(FileRenameMapping(
                    originalFile: file,
                    suggestedName: finalName,
                    renameReason: reason
                ))
            }
        }

        for file in updated.files {
            let existing = mappingIndices[file.id].map { updated.fileRenameMappings[$0] }
            let transformed = RenameRuleEngine.applyRules(to: file.displayName, rules: rules)
            let sanitization = FilenameSanitizer.sanitize(
                transformed,
                preservingExtension: file.extension,
                enforceExtension: true
            )
            let ruleCandidate = sanitization.sanitizedName
            let shouldUseRule = ruleCandidate != nil && ruleCandidate != file.displayName

            switch mode {
            case .rulesOnly:
                if let ruleCandidate, shouldUseRule {
                    updateRename(for: file, newName: ruleCandidate, reason: "Applied custom rename rule")
                } else {
                    updateRename(for: file, newName: nil, reason: nil)
                }
            case .beforeAI:
                if existing?.hasRename == true {
                    continue
                }
                if let ruleCandidate, shouldUseRule {
                    updateRename(for: file, newName: ruleCandidate, reason: "Applied custom rename rule")
                }
            }
        }

        updated.subfolders = updated.subfolders.map {
            applyRenameRules(in: $0, rules: rules, mode: mode)
        }
        return updated
    }

    private func normalizeStorageDestinations(
        in plan: OrganizationPlan,
        allowedLocations: [StorageLocation],
        sourceDirectoryURL: URL? = nil
    ) -> OrganizationPlan {
        if !allowedLocations.isEmpty {
            let originalFolders = plan.suggestions.map(\.folderName)
            DebugLogger.log("[StorageNorm] Before normalization — folders: \(originalFolders)")
            DebugLogger.log("[StorageNorm] Allowed locations: \(allowedLocations.map { "\($0.name) → \($0.path)" })")
            if let srcDir = sourceDirectoryURL {
                DebugLogger.log("[StorageNorm] Source directory: \(srcDir.path)")
            }
        }

        let normalizedPlan = StorageDestinationNormalizer.normalize(
            plan: plan,
            allowedStorageLocations: allowedLocations,
            sourceDirectoryURL: sourceDirectoryURL
        )

        if normalizedPlan != plan {
            let changedFolders = zip(plan.suggestions, normalizedPlan.suggestions)
                .filter { $0.0.folderName != $0.1.folderName }
                .map { "\"\($0.0.folderName)\" → \"\($0.1.folderName)\"" }
            LogManager.shared.log(
                "Normalized storage destination aliases: \(changedFolders.joined(separator: ", "))",
                category: "FolderOrganizer"
            )
            DebugLogger.log("[StorageNorm] After normalization — changed: \(changedFolders)")
        } else if !allowedLocations.isEmpty {
            DebugLogger.log("[StorageNorm] No changes after normalization")
        }

        return normalizedPlan
    }

    private func resolvePlanFolderURL(folderName: String, baseURL: URL) -> URL {
        if let absoluteURL = StorageLocationPathResolver.absoluteURL(from: folderName) {
            return absoluteURL
        }
        return baseURL.appendingPathComponent(folderName, isDirectory: true)
    }

    // MARK: - Cancellation

    /// Cancel any ongoing operation - RELIABLE cancellation
    public func cancel(source: OrganizationEntrySource = .manual) {
        DebugLogger.log("Cancel requested by user")
        AnalyticsManager.shared.captureWorkflow(
            workflow: "organize",
            stage: "cancel_requested",
            outcome: "cancelled",
            properties: ["entry_source": source.rawValue]
        )
        AISessionManager.shared.clearErrors()
        cancelInternal()
        resetToIdle(source: source)
    }

    /// Stop live work immediately while a caller owns the visual return-to-start transition.
    /// The caller should finish the cancellation with `cancel()` after the outgoing view has faded.
    public func prepareForReturnToStartTransition() {
        guard state == .scanning || state == .organizing || state == .applying else { return }
        DebugLogger.log("Preparing return-to-start cancellation")
        AISessionManager.shared.clearErrors()
        suppressCancellationReset = true
        cancelInternal()
        isStreaming = false
    }

    private func cancelInternal() {
        isCancellationRequested = true
        currentTask?.cancel()
        currentTask = nil
        displayUpdateTask?.cancel()
        displayUpdateTask = nil
        insightExtractionTask?.cancel()
        insightExtractionTask = nil
        stopTimeoutTimer()
    }

    private func cancelCurrentOperationForRestart() async {
        suppressCancellationReset = true
        isCancellationRequested = true

        let taskToCancel = currentTask
        currentTask?.cancel()
        currentTask = nil
        displayUpdateTask?.cancel()
        displayUpdateTask = nil
        insightExtractionTask?.cancel()
        insightExtractionTask = nil
        stopTimeoutTimer()

        _ = await taskToCancel?.result
        suppressCancellationReset = false
    }

    private func checkCancellation() throws {
        if isCancellationRequested || Task.isCancelled {
            throw CancellationError()
        }
    }

    private func isOperationInProgress() -> Bool {
        switch state {
        case .scanning, .organizing, .applying:
            return true
        default:
            return false
        }
    }

    private func resetToIdle(source: OrganizationEntrySource = .manual) {
        // Record cancellation in history if we were in a meaningful state
        if state == .organizing || state == .ready {
            if let directory = currentDirectory {
                let cancelledEntry = OrganizationHistoryEntry(
                    directoryPath: directory.path,
                    filesOrganized: 0,
                    foldersCreated: 0,
                    plan: currentPlan,
                    success: false,
                    status: .cancelled,
                    errorMessage: "User cancelled the operation",
                    rawAIResponse: streamingContent.isEmpty ? nil : streamingContent,
                    source: source
                )
                history.addEntry(cancelledEntry)

                // Record to learnings with available context (avoiding expensive directory re-scans)
                let fileCount = max(scannedFileCount, currentPlan?.totalFiles ?? 0)
                let proposedFolders = currentPlan?.suggestions.count ?? 0
                let folderNames = currentPlan?.suggestions.map { $0.folderName }
                
                if !currentRunLearningExcluded {
                    learningsManager?.recordCancelledOrganization(
                        folderPath: directory.path,
                        fileCount: fileCount,
                        proposedFolderCount: proposedFolders,
                        instructions: customInstructions.isEmpty ? nil : customInstructions,
                        stage: organizationStage.isEmpty ? "analysis" : organizationStage,
                        proposedFolderNames: folderNames,
                        proposedStructureSummary: nil,
                        fileExtensionCounts: nil,
                        regenerationCount: currentPlan?.version ?? 0,
                        regenerationInstructions: nil,
                        aiModel: aiConfig?.model
                    )
                }
            }
        }

        clearStreamingDisplayState()
        currentInsight = ""
        insightHistory = []
        insightsCache = nil
        transition(to: .idle, force: true)
        organizationStage = "" // Clear instead of "Organization cancelled" to avoid "doing too much"
        isStreaming = false
        measuredWorkProgress = nil
        // A cancelled run must not resurrect after a restart.
        clearPersistedManualSession()
    }

    private func resetToIdleUnlessCancellationResetIsSuppressed(source: OrganizationEntrySource = .manual) {
        guard !suppressCancellationReset else { return }
        resetToIdle(source: source)
    }

    @MainActor
    private func handleOrganizationError(_ error: Error, directory: URL, source: OrganizationEntrySource = .manual) {
        // Don't record history or show UI for cancellation errors
        if Self.isCancellationError(error) {
            resetToIdleUnlessCancellationResetIsSuppressed(source: source)
            return
        }

        let displayMessage = userFacingErrorMessage(for: error)
        let failedEntry = OrganizationHistoryEntry(
            directoryPath: directory.path,
            filesOrganized: 0,
            foldersCreated: 0,
            plan: nil,
            success: false,
            status: .failed,
            errorMessage: displayMessage,
            rawAIResponse: streamingContent.isEmpty ? nil : streamingContent,
            source: source
        )
        history.addEntry(failedEntry)

        transition(to: .error(error), force: true)
        errorMessage = displayMessage
        measuredWorkProgress = nil
        
        // Show error notification
        NotificationManager.shared.showError(
            message: displayMessage,
            folderPath: currentDirectory?.path,
            isCritical: true
        )
    }

    @MainActor
    private func userFacingErrorMessage(for error: Error) -> String {
        if let clientError = error as? AIClientError {
            return clientError.failureReason ?? clientError.errorDescription ?? clientError.localizedDescription
        }
        if let localized = error as? LocalizedError {
            if let reason = localized.failureReason, !reason.isEmpty {
                return reason
            }
            if let description = localized.errorDescription, !description.isEmpty {
                return description
            }
        }
        return error.localizedDescription
    }

    // MARK: - Exclusion Retry
    
    /// Retry AI call with enhanced exclusion prompt after violations
    private func retryWithExclusionEnhancement(
        files: [FileItem],
        client: AIClientProtocol,
        violations: [ExclusionViolation],
        instructions: String,
        personaPrompt: String?,
        temperature: Double?,
        imagePayload: [String: Data]
    ) async -> OrganizationPlan? {
        guard let enforcer = exclusionEnforcer else { return nil }
        
        LogManager.shared.log("Retrying with enhanced exclusion prompt", category: "FolderOrganizer")
        restartPlanGenerationForRetry()
        
        // Generate enhanced prompt with violation details
        let enhancedPrompt = instructions + enforcer.generateRetryPromptEnhancement(for: violations)
        
        do {
            defer { stopTimeoutTimer() }
            let retryPlan = try await analyzeInBoundedBatches(
                files: files,
                client: client,
                imagePayload: imagePayload,
                instructions: enhancedPrompt,
                personaPrompt: personaPrompt,
                temperature: temperature
            )
            return retryPlan
        } catch {
            LogManager.shared.log("Exclusion retry failed: \(error.localizedDescription)", category: "FolderOrganizer")
            return nil
        }
    }
    
    private func retryWithValidationEnhancement(
        files: [FileItem],
        client: AIClientProtocol,
        validationError: ValidationError,
        directory: URL,
        instructions: String,
        personaPrompt: String?,
        temperature: Double?,
        imagePayload: [String: Data],
        allowedStorageLocations: [StorageLocation]
    ) async -> OrganizationPlan? {
        let enhancement: String
        switch validationError {
        case .pathExists(let path):
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            LogManager.shared.log("Retrying: path exists conflict (\(fileName))", category: "FolderOrganizer")
            enhancement = """
            
            CRITICAL CORRECTION REQUIRED:
            You suggested a folder named "\(fileName)", but a FILE with that exact name already exists in the directory.
            You MUST NOT use "\(fileName)" as a folder name.
            Choose a different folder name that does not conflict with existing files. For example, add a suffix like "\(fileName) Files" or use a different category name.
            """
        case .invalidStorageLocation(let path):
            LogManager.shared.log("Retrying: invalid storage location (\(path))", category: "FolderOrganizer")
            let allowedList: String
            if allowedStorageLocations.isEmpty {
                allowedList = "- No storage locations are currently enabled. Use only relative folder names."
            } else {
                allowedList = allowedStorageLocations
                    .map { "  - \($0.path) (\($0.name))" }
                    .joined(separator: "\n")
            }

            enhancement = """
            
            CRITICAL CORRECTION REQUIRED:
            You used an invalid storage location path: "\(path)".
            If you choose a storage destination, the folder name MUST be an absolute path within one of these approved storage roots:
            \(allowedList)
            You may use a root path itself or a subfolder inside that root (for example: /Archive/Excel Sheets).
            Never use relative placeholders like "storage" or "storage/anything".
            If none of the approved roots fit, organize files with relative folders under the source directory instead.
            """
        default:
            return nil
        }

        restartPlanGenerationForRetry()
        
        let enhancedPrompt = instructions + enhancement
        
        do {
            defer { stopTimeoutTimer() }
            let retryPlan = try await analyzeInBoundedBatches(
                files: files,
                client: client,
                imagePayload: imagePayload,
                instructions: enhancedPrompt,
                personaPrompt: personaPrompt,
                temperature: temperature
            )
            
            let normalizedRetryPlan = normalizeStorageDestinations(in: retryPlan, allowedLocations: allowedStorageLocations, sourceDirectoryURL: directory)

            // Validate the retry plan
            try validator.validate(
                normalizedRetryPlan,
                at: directory,
                allowedStorageLocations: allowedStorageLocations,
                mode: aiConfig?.mode ?? .organize
            )
            LogManager.shared.log("Validation retry succeeded", category: "FolderOrganizer")
            return normalizedRetryPlan
        } catch {
            LogManager.shared.log("Validation retry failed: \(error.localizedDescription)", category: "FolderOrganizer")
            return nil
        }
    }

    private func retryForPlanQuality(
        files: [FileItem],
        client: AIClientProtocol,
        assessment: PlanQualityAssessment,
        directory: URL,
        instructions: String,
        personaPrompt: String?,
        temperature: Double?,
        imagePayload: [String: Data],
        allowedStorageLocations: [StorageLocation]
    ) async -> OrganizationPlan? {
        let deficiencies = PlanQualityEvaluator.retryInstructions(for: assessment)
        let enhancedPrompt = instructions + """


        PLAN QUALITY CORRECTION
        The first plan scored \(assessment.score)/100. Fix every problem below before returning a replacement plan:
        \(deficiencies)

        Keep coherent placements unchanged. Do not force an ambiguous file into a weak category. Leave it unorganized instead.
        """

        restartPlanGenerationForRetry()
        do {
            defer { stopTimeoutTimer() }
            let retryPlan = try await analyzeInBoundedBatches(
                files: files,
                client: client,
                imagePayload: imagePayload,
                instructions: enhancedPrompt,
                personaPrompt: personaPrompt,
                temperature: temperature
            )
            let hierarchyNormalized = Self.normalizingDestinationHierarchy(in: retryPlan)
            let storageNormalized = normalizeStorageDestinations(
                in: hierarchyNormalized,
                allowedLocations: allowedStorageLocations,
                sourceDirectoryURL: directory
            )
            try validator.validate(
                storageNormalized,
                at: directory,
                allowedStorageLocations: allowedStorageLocations,
                mode: aiConfig?.mode ?? .organize
            )
            LogManager.shared.log(
                "Retried a plan that scored \(assessment.score)/100 with \(assessment.issues.count) structural issues",
                category: "FolderOrganizer"
            )
            return storageNormalized
        } catch {
            LogManager.shared.log(
                "Plan quality retry failed: \(error.localizedDescription)",
                category: "FolderOrganizer"
            )
            return nil
        }
    }
    
    // MARK: - State Updates with Progress

    @MainActor
    private func updateState(_ newState: OrganizationState, stage: String, progress: Double) {
        guard !isCancellationRequested else { return }
        
        // Validate state transition
        let didTransition = transition(to: newState)
        guard didTransition else { return }
        
        // Update other properties
        organizationStage = stage
        self.progress = progress
    }

    @MainActor
    private func updateProgress(_ progress: Double, stage: String? = nil) {
        guard !isCancellationRequested else { return }
        if let stage = stage {
            // Batch when updating both progress and stage
            withBatchUpdates {
                self.progress = progress
                self.organizationStage = stage
            }
        } else {
            self.progress = progress
        }
    }

    @MainActor
    private func updateMeasuredProgress(
        completed: Int,
        total: Int,
        estimatedOverallProgress: Double,
        stage: String
    ) {
        guard !isCancellationRequested else { return }
        withBatchUpdates {
            progress = estimatedOverallProgress
            organizationStage = stage
            measuredWorkProgress = MeasuredWorkProgress(completed: completed, total: total)
        }
    }

    @MainActor
    private func clearMeasuredProgress(estimatedOverallProgress: Double, stage: String) {
        guard !isCancellationRequested else { return }
        withBatchUpdates {
            progress = estimatedOverallProgress
            organizationStage = stage
            measuredWorkProgress = nil
        }
    }

    // MARK: - Incremental Organization (for watched folders)

    public func organizeIncremental(
        directory: URL,
        specificFiles: [String]? = nil,
        customPrompt: String? = nil,
        temperature: Double? = nil,
        providerOverride: AIProvider? = nil,
        modelOverride: String? = nil,
        mode: OrganizationMode = .organize,
        historySource: OrganizationEntrySource = .manual,
        autoApply: Bool = true
    ) async throws {
        guard !isOperationInProgress() else {
            DebugLogger.log("Incremental organization blocked: Already in progress")
            return
        }

        await exclusionRules?.loadPersistedState()
        await personaManager?.loadPersistedState()
        await customPersonaStore?.loadPersistedState()

        cancelInternal()
        isCancellationRequested = false
        currentRunInstructions = customPrompt ?? customInstructions
        modelExcludedCurrentRun = false

        currentTask = Task {
            try await performIncrementalOrganization(
                directory: directory,
                specificFiles: specificFiles,
                customPrompt: customPrompt,
                temperature: temperature,
                providerOverride: providerOverride,
                modelOverride: modelOverride,
                mode: mode,
                historySource: historySource,
                autoApply: autoApply
            )
        }
        defer { currentTask = nil }

        do {
            try await currentTask?.value
        } catch where Self.isCancellationError(error) {
            resetToIdleUnlessCancellationResetIsSuppressed(source: historySource)
        }
    }

    private func performIncrementalOrganization(
        directory: URL,
        specificFiles: [String]?,
        customPrompt: String?,
        temperature: Double?,
        providerOverride: AIProvider? = nil,
        modelOverride: String? = nil,
        mode: OrganizationMode,
        historySource: OrganizationEntrySource = .manual,
        autoApply: Bool
    ) async throws {
        AnalyticsManager.shared.captureWorkflow(
            workflow: "organize",
            stage: "started",
            outcome: "started",
            properties: [
                "entry_source": historySource.rawValue,
                "has_custom_instructions": !(customPrompt?.isEmpty ?? true),
                "mode": mode.rawValue,
            ]
        )

        // Build a client for this run so watched-folder action choices never mutate
        // or inherit the main Organize page's selected mode.
        guard let defaultClient = aiClient else {
            throw OrganizationError.clientNotConfigured
        }

        var operationConfig = aiConfig ?? defaultClient.config
        operationConfig.mode = mode
        operationConfig.enableSmartRename = mode != .organize

        let client: AIClientProtocol
        if let providerOverride, let modelOverride {
            operationConfig.provider = providerOverride
            operationConfig.model = modelOverride
            operationConfig.requiresAPIKey = providerOverride.typicallyRequiresAPIKey
            operationConfig.apiKey = nil
            if providerOverride.typicallyRequiresAPIKey,
               let apiKey = KeychainManager.get(key: providerOverride.keychainKey) {
                operationConfig.apiKey = apiKey
            }
            operationConfig.apiURL = providerOverride.defaultAPIURL
            client = try AIClientFactory.createClient(config: operationConfig)
        } else if defaultClient.config.mode == operationConfig.mode,
                  defaultClient.config.enableSmartRename == operationConfig.enableSmartRename {
            client = defaultClient
        } else {
            client = try AIClientFactory.createClient(config: operationConfig)
        }

        currentDirectory = directory

        let exclusionMatcher = exclusionRules?.matcherSnapshot()
        var files: [FileItem] = []
        
        if let specificFiles = specificFiles {
            // Processing specific files
            updateState(.scanning, stage: "Scanning \(specificFiles.count) new files...", progress: 0.1)
            try checkCancellation()
            
            // Enable deep scan for small batches
            let shouldDeepScan = (aiConfig?.enableDeepScan ?? false) && specificFiles.count <= 20
            
            // map file names to FileItems
            // We assume specificFiles are filenames or relative paths
            for filename in specificFiles {
                let fileURL = directory.appendingPathComponent(filename)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
                    continue
                }

                if isDirectory.boolValue {
                    if let nestedFiles = try? await scanner.scanDirectory(
                        at: fileURL,
                        relativeTo: directory,
                        deepScan: shouldDeepScan,
                        exclusionMatcher: exclusionMatcher
                    ) {
                        files.append(contentsOf: nestedFiles)
                    }
                } else if let item = try? await scanner.scanFile(
                    at: fileURL,
                    relativeTo: directory,
                    deepScan: shouldDeepScan,
                    exclusionMatcher: exclusionMatcher
                ) {
                    files.append(item)
                }
            }
            files = Array(Set(files))
            setScannedFiles(files)
        } else {
            // Fallback to scanning root
            updateState(.scanning, stage: "Scanning for new files...", progress: 0.1)
            try checkCancellation()
            
            let allFiles = try await scanner.scanDirectory(
                at: directory,
                exclusionMatcher: exclusionMatcher
            )
            
            // Filter: Only top-level files (no folders, no deep scan) for incremental drop
            files = allFiles.filter {
                let relativePath = $0.path.replacingOccurrences(of: directory.path + "/", with: "")
                return !relativePath.contains("/") // Only files in root
            }
            setScannedFiles(files)
        }

        if files.isEmpty {
            await MainActor.run {
                transition(to: .idle, force: true)
                organizationStage = "No new files to organize"
            }
            return
        }

        updateState(.organizing, stage: "Organizing \(files.count) new files...", progress: 0.3)
        await MainActor.run {
            isStreaming = true
        }

        startTimeoutTimer()

        do {
            try checkCancellation()

            let existingFolderContext = PromptBuilder.buildExistingFoldersContext(at: directory)
                ?? "No descendant folders currently exist."
            let contextPrompt: String
            switch mode {
            case .organize:
                contextPrompt = """
                \(existingFolderContext)

                RULES for Organization:
                1. You MUST prioritize placing files into these existing descendant paths if they are relevant, regardless of path depth.
                2. Do NOT create new folders unless the file is completely unrelated to any existing folder.
                3. If a file does not fit well into any existing folder, you may leave it in the root (do not move it).
                4. This is a "Smart Drop" operation: maintain the existing structure and keep every original filename.
                """
            case .organizeAndRename:
                contextPrompt = """
                \(existingFolderContext)

                RULES for Organization and Renaming:
                1. Prioritize placing files into these existing descendant paths when they are relevant, regardless of path depth.
                2. Do not create new folders unless a file is unrelated to the existing structure.
                3. Improve unclear filenames when the available evidence supports a better name.
                4. Preserve clear filenames and maintain the existing structure instead of reinventing it.
                """
            case .renameOnly:
                contextPrompt = """
                RULES for Renaming:
                1. Keep every file in its current folder.
                2. Improve unclear filenames only when the available evidence supports a better name.
                3. Preserve filenames that are already clear and useful.
                """
            }

            let prompt = PromptBuilder.wrapDirectUserInstructions(customPrompt ?? customInstructions) + "\n\n" + contextPrompt
            
            // Add Learnings context
            var finalPrompt = prompt
            if let learnedContext = learningsManager?.generatePromptContext(forFolder: directory.path),
               !learnedContext.isEmpty {
                finalPrompt += "\n\n" + learnedContext
            }

            if mode != .renameOnly,
               let modelDirContext = learningsManager?.generateModelDirectoryContext(for: files),
               !modelDirContext.isEmpty {
                finalPrompt += "\n\n" + modelDirContext
            }
            
            // Add Storage Locations context
            if mode != .renameOnly,
               let storageContext = await storageLocationsManager?.generatePromptContext(),
               !storageContext.isEmpty {
                finalPrompt += "\n\n" + storageContext
            }
            finalPrompt += exclusionInstructions(forRenameOnly: mode == .renameOnly)
            
            let personaPrompt = personaManager?.getPrompt(for: personaManager?.selectedPersona ?? .general)

            let plan = try await analyzeInBoundedBatches(
                files: files,
                client: client,
                imagePayload: [:],
                instructions: finalPrompt,
                personaPrompt: personaPrompt,
                temperature: temperature,
                modeOverride: mode
            )

            stopTimeoutTimer()

            try checkCancellation()

            await MainActor.run {
                isStreaming = false
                currentPlan = normalizeRenameSuggestions(
                    in: applyRenameRuleConfiguration(to: plan, config: operationConfig),
                    config: operationConfig
                )
            }

            // Validate plan before auto-apply (with a targeted retry for common validation failures)
            let allowedLocations = storageLocationsManager?.enabledLocations ?? []
            var planAfterValidation = normalizeStorageDestinations(in: plan, allowedLocations: allowedLocations, sourceDirectoryURL: directory)
            planAfterValidation = OrganizationModePlanEnforcer.enforce(
                planAfterValidation,
                mode: mode,
                baseURL: directory
            )
            do {
                try validator.validate(
                    planAfterValidation,
                    at: directory,
                    allowedStorageLocations: allowedLocations,
                    mode: mode
                )
            } catch let validationError as ValidationError {
                if let retryPlan = await retryWithValidationEnhancement(
                    files: files,
                    client: client,
                    validationError: validationError,
                    directory: directory,
                    instructions: finalPrompt,
                    personaPrompt: personaPrompt,
                    temperature: temperature,
                    imagePayload: [:],
                    allowedStorageLocations: allowedLocations
                ) {
                    planAfterValidation = OrganizationModePlanEnforcer.enforce(
                        retryPlan,
                        mode: mode,
                        baseURL: directory
                    )
                } else {
                    throw validationError
                }
            }

            // Post-AI exclusion validation
            var validatedPlan = planAfterValidation
            if let exclusionRules = exclusionRules {
                let enforcer = ExclusionEnforcer(exclusionManager: exclusionRules)
                let validationResult = enforcer.validate(planAfterValidation)
                if validationResult.hasViolations {
                    LogManager.shared.log("Exclusion violations in incremental plan: \(validationResult.violationCount)", category: "FolderOrganizer")
                    validatedPlan = validationResult.cleanedPlan ?? planAfterValidation
                }
            }

            handleLearningToolCall(
                from: validatedPlan,
                source: historySource,
                folderPath: directory.path
            )

            await MainActor.run {
                currentPlan = normalizeRenameSuggestions(
                    in: applyRenameRuleConfiguration(to: validatedPlan, config: operationConfig),
                    config: operationConfig
                )
            }

            guard autoApply else {
                await MainActor.run {
                    preparedPlanModeOverride = mode
                    updateState(.ready, stage: "Ready for review", progress: 1.0)
                }
                return
            }

            // Auto-apply for incremental (same task so outer cancel keeps working)
            try await performApply(
                at: directory,
                dryRun: false,
                enableTagging: operationConfig.enableFileTagging,
                source: historySource,
                modeOverride: mode
            )

        } catch {
            stopTimeoutTimer()
            handleOrganizationError(error, directory: directory, source: historySource)
            throw error
        }
    }

    // MARK: - Organize Selected Files from Finder

    /// Organize only the files currently selected in Finder
    /// This uses Automation permission to get the selection from Finder
    /// - Parameters:
    ///   - customPrompt: Optional custom instructions for the AI
    ///   - temperature: Optional temperature override for AI generation
    /// - Returns: The number of files organized, or nil if no selection available
    @discardableResult
    public func organizeSelectedFiles(customPrompt: String? = nil, temperature: Double? = nil) async throws -> Int {
        guard let automationManager = automationManager else {
            throw OrganizationError.automationNotConfigured
        }

        await exclusionRules?.loadPersistedState()
        await personaManager?.loadPersistedState()
        await customPersonaStore?.loadPersistedState()

        currentRunInstructions = customPrompt ?? customInstructions
        modelExcludedCurrentRun = false

        // Check if we have automation permission
        guard automationManager.automationStatus == .granted else {
            throw NSError(domain: "Sorty", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Automation permission not granted. Please enable it in System Settings to organize selected files."
            ])
        }

        // Get the selected files from Finder
        guard let selectedFiles = await FinderAutomation.getSelectedFiles(), !selectedFiles.isEmpty else {
            await MainActor.run {
                transition(to: .idle, force: true)
                organizationStage = "No files selected in Finder"
            }
            return 0
        }

        // Get the directory of the first selected file (assume all are in same folder)
        let firstFile = selectedFiles[0]
        let directory = firstFile.deletingLastPathComponent()

        // Convert URLs to FileItems
        let exclusionMatcher = exclusionRules?.matcherSnapshot()
        var files: [FileItem] = []
        for url in selectedFiles {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                if let nestedFiles = try? await scanner.scanDirectory(
                    at: url,
                    relativeTo: directory,
                    deepScan: aiConfig?.enableDeepScan ?? false,
                    deepScanFileLimit: Self.deepScanFileLimit,
                    exclusionMatcher: exclusionMatcher
                ) {
                    files.append(contentsOf: nestedFiles)
                }
            } else if let item = try? await scanner.scanFile(
                at: url,
                relativeTo: directory,
                deepScan: aiConfig?.enableDeepScan ?? false,
                exclusionMatcher: exclusionMatcher
            ) {
                files.append(item)
            }
        }
        setScannedFiles(files)

        guard !files.isEmpty else {
            await MainActor.run {
                transition(to: .idle, force: true)
                organizationStage = exclusionMatcher?.isEmpty == false
                    ? "All selected files are excluded by your rules"
                    : "No files found to organize"
            }
            return 0
        }

        // Set the current directory
        currentDirectory = directory

        // Start the organization process
        guard !isOperationInProgress() else {
            DebugLogger.log("Selected files organization blocked: Already in progress")
            return 0
        }

        cancelInternal()
        isCancellationRequested = false
        userInitiatedAction = true

        currentTask = Task {
            try await performOrganizationOfSelectedFiles(
                directory: directory,
                files: files,
                customPrompt: customPrompt,
                temperature: temperature
            )
        }
        defer { currentTask = nil }

        do {
            try await currentTask?.value
            return files.count
        } catch where Self.isCancellationError(error) {
            resetToIdleUnlessCancellationResetIsSuppressed()
            return 0
        }
    }

    private func performOrganizationOfSelectedFiles(
        directory: URL,
        files: [FileItem],
        customPrompt: String?,
        temperature: Double?
    ) async throws {
        guard let client = aiClient else {
            throw OrganizationError.clientNotConfigured
        }

        updateState(.organizing, stage: "Analyzing \(files.count) selected files...", progress: 0.3)
        await MainActor.run {
            isStreaming = true
        }

        startTimeoutTimer()

        do {
            try checkCancellation()

            // Get existing folders to use as context
            let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            let existingFolders = contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
                .map { $0.lastPathComponent }
                .filter { !$0.hasPrefix(".") }

            let contextPrompt = """
            SELECTED FILES ONLY: You are organizing only the files currently selected in Finder.

            Existing folders in this directory: \(existingFolders.joined(separator: ", ")).

            RULES for Selected File Organization:
            1. Prioritize placing files into existing folders if relevant.
            2. Only create new folders if the files don't fit existing structure.
            3. Files that don't fit anywhere can remain in the root.
            4. Focus only on the selected files - do not touch other files in the folder.
            """

            let prompt = PromptBuilder.wrapDirectUserInstructions(customPrompt ?? customInstructions) + "\n\n" + contextPrompt

            // Add Learnings context
            var finalPrompt = prompt
            if let learnedContext = learningsManager?.generatePromptContext(forFolder: directory.path), !learnedContext.isEmpty {
                finalPrompt += "\n\n" + learnedContext
            }

            if let modelDirContext = learningsManager?.generateModelDirectoryContext(for: files),
               !modelDirContext.isEmpty {
                finalPrompt += "\n\n" + modelDirContext
            }

            // Add Storage Locations context
            if let storageContext = await storageLocationsManager?.generatePromptContext(), !storageContext.isEmpty {
                finalPrompt += "\n\n" + storageContext
            }
            finalPrompt += exclusionInstructions(forRenameOnly: aiConfig?.mode == .renameOnly)

            let personaPrompt = personaManager?.getPrompt(for: personaManager?.selectedPersona ?? .general)

            let plan = try await analyzeInBoundedBatches(
                files: files,
                client: client,
                imagePayload: [:],
                instructions: finalPrompt,
                personaPrompt: personaPrompt,
                temperature: temperature
            )

            stopTimeoutTimer()

            try checkCancellation()

            await MainActor.run {
                isStreaming = false
                currentPlan = normalizeRenameSuggestions(in: applyRenameRuleConfiguration(to: plan))
            }

            // Validate selected-files plan before apply.
            let allowedLocations = storageLocationsManager?.enabledLocations ?? []
            var validatedPlan = normalizeStorageDestinations(in: plan, allowedLocations: allowedLocations, sourceDirectoryURL: directory)
            do {
                try validator.validate(
                    validatedPlan,
                    at: directory,
                    allowedStorageLocations: allowedLocations
                )
            } catch let validationError as ValidationError {
                if let retryPlan = await retryWithValidationEnhancement(
                    files: files,
                    client: client,
                    validationError: validationError,
                    directory: directory,
                    instructions: finalPrompt,
                    personaPrompt: personaPrompt,
                    temperature: temperature,
                    imagePayload: [:],
                    allowedStorageLocations: allowedLocations
                ) {
                    validatedPlan = retryPlan
                    await MainActor.run {
                        currentPlan = normalizeRenameSuggestions(in: applyRenameRuleConfiguration(to: retryPlan))
                    }
                } else {
                    throw validationError
                }
            }

            handleLearningToolCall(
                from: validatedPlan,
                source: .manual,
                folderPath: directory.path
            )

            await MainActor.run {
                currentPlan = normalizeRenameSuggestions(in: applyRenameRuleConfiguration(to: validatedPlan))
            }

            // Apply the organization (same task so outer cancel keeps working)
            try await performApply(at: directory, dryRun: false, enableTagging: aiConfig?.enableFileTagging ?? true)

        } catch {
            stopTimeoutTimer()
            handleOrganizationError(error, directory: directory)
            throw error
        }
    }

    // MARK: - Apply Organization

    public func apply(
        at baseURL: URL,
        dryRun: Bool = false,
        enableTagging: Bool = true,
        source: OrganizationEntrySource = .manual,
        modeOverride: OrganizationMode? = nil
    ) async throws {
        guard currentPlan != nil else {
            throw OrganizationError.noCurrentPlan
        }
        // Run the apply inside the tracked task so cancel() aborts the
        // file moves (FileSystemManager polls Task cancellation per file).
        cancelInternal()
        isCancellationRequested = false
        currentTask = Task {
            try await performApply(
                at: baseURL,
                dryRun: dryRun,
                enableTagging: enableTagging,
                source: source,
                modeOverride: modeOverride
            )
        }
        defer { currentTask = nil }
        do {
            try await currentTask?.value
        } catch where Self.isCancellationError(error) {
            if suppressCancellationReset {
                suppressCancellationReset = false
                throw CancellationError()
            }
            resetToIdle(source: source)
            throw CancellationError()
        }
    }

    private func performApply(
        at baseURL: URL,
        dryRun: Bool = false,
        enableTagging: Bool = true,
        source: OrganizationEntrySource = .manual,
        modeOverride: OrganizationMode? = nil
    ) async throws {
        guard let currentPlan else {
            throw OrganizationError.noCurrentPlan
        }
        let reliabilitySpan = ReliabilityManager.shared.startSpan(
            name: "apply_plan",
            operation: "workflow.apply",
            feature: "organize"
        )
        defer { reliabilitySpan?.finish() }
        let analyticsStartedAt = Date()
        AnalyticsManager.shared.captureWorkflow(
            workflow: "organize",
            stage: "apply_started",
            outcome: "started",
            properties: [
                "count_bucket": AnalyticsManager.countBucket(currentPlan.totalFiles),
                "entry_source": source.rawValue,
                "mode": (modeOverride ?? preparedPlanModeOverride ?? aiConfig?.mode ?? .organize).rawValue,
            ]
        )

        // Note: the public apply() wrapper resets the cancellation flag for
        // standalone applies. Don't reset it here so a cancel requested while
        // an incremental/selected-files run is in flight stays visible.
        try checkCancellation()

        // Re-validate at apply time to protect all entry points, including regenerated previews.
        var operationConfig = aiConfig ?? aiClient?.config
        let requestedMode = modeOverride ?? preparedPlanModeOverride
        if let requestedMode {
            operationConfig?.mode = requestedMode
            operationConfig?.enableSmartRename = requestedMode != .organize
        }

        let operationMode = requestedMode ?? operationConfig?.mode ?? .organize

        let allowedLocations = storageLocationsManager?.enabledLocations ?? []
        let normalizedPlan = normalizeStorageDestinations(in: currentPlan, allowedLocations: allowedLocations, sourceDirectoryURL: baseURL)
        let normalizedRenamePlan = normalizeRenameSuggestions(
            in: applyRenameRuleConfiguration(to: normalizedPlan, config: operationConfig),
            config: operationConfig
        )
        let planToApply = OrganizationModePlanEnforcer.enforce(
            normalizedRenamePlan,
            mode: operationMode,
            baseURL: baseURL
        )
        self.currentPlan = planToApply
        try validator.validate(
            planToApply,
            at: baseURL,
            allowedStorageLocations: allowedLocations,
            mode: operationMode
        )

        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "Applying organization to: \(baseURL.lastPathComponent)"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        updateState(.applying, stage: "Applying changes to your files...", progress: 0.0)
        // A restart mid-apply must not resurrect a stale ready preview; the
        // interrupted marker restores the folder without auto-reapplying.
        persistManualSession(directory: baseURL, plan: nil, stateHint: .interrupted, instructions: currentRunInstructions)
        
        // Start learning session for rule tracking
        if let learningsObserver = learningsObserver {
            learningsObserver.startSession(
                folderPath: baseURL.path,
                historyEntryId: nil,
                learningExcluded: currentRunLearningExcluded
            )
        }

        var completedOperationsBeforeHistory: [FileSystemManager.FileOperation] = []

        do {
            let operations = try await fileSystemManager.applyOrganization(
                planToApply,
                at: baseURL, 
                dryRun: dryRun, 
                enableTagging: enableTagging,
                strictExclusions: aiConfig?.strictExclusions ?? true,
                exclusionManager: exclusionRules,
                progress: { [weak self] percent, message in
                    Task { @MainActor in
                        self?.progress = min(percent, 1.0)
                        self?.organizationStage = message
                    }
                }
            )
            completedOperationsBeforeHistory = operations

            try checkCancellation()
            
            // Track rule applications for learning feedback
            if let learningsObserver = learningsObserver, !dryRun, !currentRunLearningExcluded {
                // Pre-start the session so rule applications can be recorded
                learningsObserver.startSession(folderPath: baseURL.path, historyEntryId: nil, operations: operations)
                recordRuleApplications(for: planToApply, operations: operations, observer: learningsObserver)
            }

            if !dryRun, !currentRunLearningExcluded, !planHistory.isEmpty {
                let rejectedPlans = planHistory
                let evidence = await Task.detached(priority: .utility) {
                    PlanPreferenceDiffer.compare(
                        rejectedPlans: rejectedPlans,
                        acceptedPlan: planToApply,
                        folderPath: baseURL.path
                    )
                }.value
                if let evidence {
                    learningsManager?.recordRegenerationPreferenceEvidence(evidence)
                }
            }

            let historyEntry = OrganizationHistoryEntry(
                directoryPath: baseURL.path,
                filesOrganized: planToApply.totalFiles,
                foldersCreated: planToApply.totalFolders,
                plan: planToApply,
                success: true,
                status: .completed,
                rawAIResponse: streamingContent.isEmpty ? nil : streamingContent,
                operations: operations,
                source: source
            )

            await MainActor.run {
                history.addEntry(historyEntry)
                organizationStage = "Complete!"
                progress = 1.0
                transition(to: .completed)
                persistManualSession(directory: baseURL, plan: planToApply, stateHint: .completed, instructions: currentRunInstructions)
            }

            NotificationCenter.default.post(
                name: .organizationDidFinish,
                object: nil,
                userInfo: [
                    "url": baseURL,
                    "entry": historyEntry,
                    "operations": operations,
                    "learningExcluded": currentRunLearningExcluded,
                ]
            )
            
            // End learning session
            if let learningsObserver = learningsObserver {
                learningsObserver.endSession()
            }

            // Auto-reveal in Finder is opt-in.
            let shouldAutoRevealInFinder = automationManager?.autoSelectOrganizedFolders ?? false

            if let automationManager = automationManager, automationManager.automationStatus == .granted {
                automationManager.refreshFinder(at: baseURL)

                if shouldAutoRevealInFinder {
                    let folderURLs = planToApply.suggestions.map { resolvePlanFolderURL(folderName: $0.folderName, baseURL: baseURL) }
                    automationManager.selectOrganizedFolders(folderURLs: folderURLs)
                }
            } else if shouldAutoRevealInFinder {
                let folderURLs = planToApply.suggestions.compactMap { suggestion -> URL? in
                    let url = resolvePlanFolderURL(folderName: suggestion.folderName, baseURL: baseURL)
                    return FileManager.default.fileExists(atPath: url.path) ? url : nil
                }
                if !folderURLs.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(folderURLs)
                }
            }

            AnalyticsManager.shared.captureWorkflow(
                workflow: "organize",
                stage: "applied",
                outcome: "success",
                properties: AnalyticsManager.durationProperties(
                    Date().timeIntervalSince(analyticsStartedAt)
                ).merging([
                    "count_bucket": AnalyticsManager.countBucket(operations.count),
                    "entry_source": source.rawValue,
                    "mode": operationMode.rawValue,
                ]) { current, _ in current }
            )

        } catch where Self.isCancellationError(error) {
            AnalyticsManager.shared.captureWorkflow(
                workflow: "organize",
                stage: "apply",
                outcome: "cancelled",
                properties: AnalyticsManager.durationProperties(
                    Date().timeIntervalSince(analyticsStartedAt)
                ).merging([
                    "count_bucket": AnalyticsManager.countBucket(completedOperationsBeforeHistory.count),
                    "entry_source": source.rawValue,
                    "mode": operationMode.rawValue,
                ]) { current, _ in current }
            )
            resetToIdleUnlessCancellationResetIsSuppressed(source: source)
            throw CancellationError()
        } catch {
            let partialOperations: [FileSystemManager.FileOperation]?
            if case FileSystemError.partialApplyFailure(let operations, _) = error {
                partialOperations = operations.isEmpty ? nil : operations
            } else if !completedOperationsBeforeHistory.isEmpty {
                partialOperations = completedOperationsBeforeHistory
            } else {
                partialOperations = nil
            }

            let failedEntry = OrganizationHistoryEntry(
                directoryPath: baseURL.path,
                filesOrganized: partialOperations?.filter { $0.type == .moveFile || $0.type == .renameFile }.count ?? 0,
                foldersCreated: partialOperations?.filter { $0.type == .createFolder }.count ?? 0,
                plan: planToApply,
                success: false,
                status: partialOperations == nil ? .failed : .partiallyUndone,
                errorMessage: error.localizedDescription,
                rawAIResponse: streamingContent.isEmpty ? nil : streamingContent,
                operations: partialOperations,
                source: source
            )

            await MainActor.run {
                history.addEntry(failedEntry)
            }

            AnalyticsManager.shared.captureWorkflow(
                workflow: "organize",
                stage: "apply",
                outcome: partialOperations == nil ? "failed" : "partially_completed",
                properties: AnalyticsManager.durationProperties(
                    Date().timeIntervalSince(analyticsStartedAt)
                ).merging([
                    "count_bucket": AnalyticsManager.countBucket(partialOperations?.count ?? 0),
                    "entry_source": source.rawValue,
                    "mode": operationMode.rawValue,
                ]) { current, _ in current }
            )
            ReliabilityManager.shared.capture(
                error: error,
                feature: "organize",
                operation: "apply_plan",
                recoverable: partialOperations == nil
            )
            throw error
        }
    }

    @MainActor
    public func redoOrganization(from entry: OrganizationHistoryEntry) async throws {
        let entry = await history.details(for: entry)
        guard let plan = entry.plan else {
            throw OrganizationError.noCurrentPlan
        }
        let baseURL = currentDirectory ?? URL(fileURLWithPath: entry.directoryPath)
        currentDirectory = baseURL
        currentPlan = plan

        updateState(.applying, stage: "Re-applying organization...", progress: 0.3)

        do {
            try await apply(at: baseURL, dryRun: false, enableTagging: aiConfig?.enableFileTagging ?? true)
            
            if entry.isUndone {
                var updatedEntry = entry
                updatedEntry.isUndone = false
                updatedEntry.status = .completed
                history.updateEntry(updatedEntry)
            }
            
            await MainActor.run {
                organizationStage = "Redo complete"
                progress = 1.0
                transition(to: .completed)
            }
        } catch {
            await MainActor.run {
                transition(to: .error(error), force: true)
                errorMessage = error.localizedDescription
            }
            throw error
        }
    }

    /// Generate organization plan with a specific provider
    /// Returns a plan without updating the organizer's state
    private func generatePlanWithProvider(
        files: [FileItem],
        provider: AIProvider,
        model: String? = nil,
        customInstructions: String? = nil
    ) async throws -> OrganizationPlan {
        var tempConfig = aiConfig ?? AIConfig.default
        tempConfig.provider = provider
        tempConfig.model = model ?? provider.defaultModel
        
        let isSameProvider = aiConfig?.provider == provider
        let hasCustomURL = !(aiConfig?.apiURL ?? "").isEmpty
        
        if !isSameProvider || !hasCustomURL {
            tempConfig.apiURL = provider.defaultAPIURL
        }
        
        let tempClient = try AIClientFactory.createClient(config: tempConfig)
        
        let personaPrompt = personaManager?.getPrompt(for: personaManager?.selectedPersona ?? .general)
        
        let isRenameOnly = tempConfig.mode == .renameOnly
        var instructions = PromptBuilder.wrapDirectUserInstructions(customInstructions ?? self.customInstructions)
        if let learnedContext = learningsManager?.generatePromptContext(forFolder: currentDirectory?.path), !learnedContext.isEmpty {
            instructions += "\n\n" + learnedContext
        }
        if !isRenameOnly,
           let modelDirContext = learningsManager?.generateModelDirectoryContext(for: files),
           !modelDirContext.isEmpty {
            instructions += "\n\n" + modelDirContext
        }
        if !isRenameOnly, let storageContext = await storageLocationsManager?.generatePromptContext(), !storageContext.isEmpty {
            instructions += "\n\n" + storageContext
        }
        instructions += exclusionInstructions(forRenameOnly: isRenameOnly)
        
        let plan = try await analyzeInBoundedBatches(
            files: files,
            client: tempClient,
            imagePayload: [:],
            instructions: instructions,
            personaPrompt: personaPrompt,
            temperature: nil,
            modeOverride: tempConfig.mode
        )
        
        return plan
    }

    /// Get files from current plan for regeneration
    public func getFilesFromCurrentPlan() -> [FileItem] {
        guard let currentPlan = currentPlan else { return [] }
        
        var allFiles: [FileItem] = []
        func collectFiles(_ suggestion: FolderSuggestion) {
            allFiles.append(contentsOf: suggestion.files)
            for subfolder in suggestion.subfolders {
                collectFiles(subfolder)
            }
        }
        for suggestion in currentPlan.suggestions {
            collectFiles(suggestion)
        }
        allFiles.append(contentsOf: currentPlan.unorganizedFiles)
        
        return allFiles
    }
    
    /// Record which files were moved by which inferred rules (for learning feedback)
    private func recordRuleApplications(for plan: OrganizationPlan, operations: [FileSystemManager.FileOperation], observer: ContinuousLearningObserver) {
        learningsManager?.loadProfileIfNeededForCollection()
        let activeRules = learningsManager?.getActiveRules() ?? []
        guard !activeRules.isEmpty else { return }
        let compiledRules = activeRules.compactMap { rule -> (id: String, regex: NSRegularExpression)? in
            guard let regex = try? NSRegularExpression(
                pattern: rule.pattern,
                options: .caseInsensitive
            ) else {
                return nil
            }
            return (rule.id, regex)
        }
        
        // Build a map of filename to ruleId from the plan suggestions
        var fileToRuleMap: [String: String] = [:]
        
        func traverseSuggestions(_ suggestions: [FolderSuggestion]) {
            for suggestion in suggestions {
                for file in suggestion.files {
                    if let ruleId = suggestion.ruleId {
                        fileToRuleMap[file.displayName] = ruleId
                    }
                }
                traverseSuggestions(suggestion.subfolders)
            }
        }
        
        traverseSuggestions(plan.suggestions)
        
        for operation in operations {
            guard operation.type == .moveFile || operation.type == .renameFile else { continue }
            guard let destPath = operation.destinationPath else { continue }
            
            let fileName = URL(fileURLWithPath: operation.sourcePath).lastPathComponent
            
            // Priority 1: Use specific rule mapping from the AI plan if available
            if let ruleId = fileToRuleMap[fileName] {
                observer.recordRuleApplication(destinationPath: destPath, ruleId: ruleId)
                continue
            }
            
            // Priority 2: Try to match the rule's regex pattern against the filename (heuristic backup)
            let range = NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)
            for rule in compiledRules {
                if rule.regex.firstMatch(in: fileName, options: [], range: range) != nil {
                    observer.recordRuleApplication(destinationPath: destPath, ruleId: rule.id)
                    break
                }
            }
        }
    }
    
    /// Regenerate preview with a specific provider
    public func regenerateWithProvider(_ provider: AIProvider) async throws {
        AnalyticsManager.shared.captureWorkflow(
            workflow: "regenerate",
            stage: "started",
            outcome: "started",
            properties: ["variant": "provider"]
        )
        let files = getFilesFromCurrentPlan()
        guard !files.isEmpty else {
            throw OrganizationError.noCurrentPlan
        }

        guard !isOperationInProgress() else {
            return
        }

        // Run inside the tracked task so cancel() aborts the AI request
        // instead of letting it keep generating a response nobody will use.
        cancelInternal()
        isCancellationRequested = false
        currentTask = Task {
            try await performRegenerateWithProvider(provider, files: files)
        }
        defer { currentTask = nil }
        do {
            try await currentTask?.value
        } catch where Self.isCancellationError(error) {
            if suppressCancellationReset {
                suppressCancellationReset = false
                throw CancellationError()
            }
            resetToIdle()
            throw CancellationError()
        }
    }

    private func performRegenerateWithProvider(_ provider: AIProvider, files: [FileItem]) async throws {
        var files = files
        let reliabilitySpan = ReliabilityManager.shared.startSpan(
            name: "regenerate_preview",
            operation: "workflow.regenerate",
            feature: "organize"
        )
        defer { reliabilitySpan?.finish() }

        if let exclusionRules = exclusionRules {
            files = exclusionRules.filterFiles(files)
        }

        // Reset streaming state
        await MainActor.run {
            clearStreamingDisplayState()
            isStreaming = false
            showTimeoutMessage = false
            currentInsight = ""
            insightHistory = []
            insightsCache = nil
        }

        let providerStage = aiConfig?.mode == .renameOnly
            ? "Getting new names from \(provider.displayName)..."
            : "Getting a new plan from \(provider.displayName)..."
        updateState(.organizing, stage: providerStage, progress: 0.3)

        do {
            var newPlan = try await generatePlanWithProvider(files: files, provider: provider)
            newPlan.version = (currentPlan?.version ?? 0) + 1
            
            if let exclusionRules = exclusionRules {
                let enforcer = ExclusionEnforcer(exclusionManager: exclusionRules)
                let validationResult = enforcer.validate(newPlan)
                if validationResult.hasViolations {
                    LogManager.shared.log("Exclusion violations in regenerated preview: \(validationResult.violationCount)", category: "FolderOrganizer")
                    newPlan = validationResult.cleanedPlan ?? newPlan
                }
            }

            handleLearningToolCall(
                from: newPlan,
                source: .manual,
                folderPath: currentDirectory?.path ?? ""
            )
            
            try checkCancellation()
            
            await MainActor.run {
                guard !isCancellationRequested else { return }
                isStreaming = false
                organizationStage = "Ready!"
                progress = 1.0
                if let existingPlan = self.currentPlan {
                    self.recordPreviewVersion(existingPlan)
                }
                self.currentPlan = normalizeRenameSuggestions(in: applyRenameRuleConfiguration(to: newPlan))
                transition(to: .ready)
            }
            AnalyticsManager.shared.captureWorkflow(
                workflow: "regenerate",
                stage: "plan_ready",
                outcome: "success",
                properties: ["variant": "provider"]
            )
        } catch where Self.isCancellationError(error) {
            await MainActor.run {
                isStreaming = false
                if !suppressCancellationReset {
                    resetToIdle()
                }
            }
            throw CancellationError()
        } catch {
            await MainActor.run {
                transition(to: .error(error), force: true)
                errorMessage = error.localizedDescription
            }
            AnalyticsManager.shared.captureWorkflow(
                workflow: "regenerate",
                stage: "plan_generation",
                outcome: "failed",
                properties: ["variant": "provider"]
            )
            ReliabilityManager.shared.capture(
                error: error,
                feature: "organize",
                operation: "regenerate_with_provider"
            )
            throw error
        }
    }

    /// Regenerate preview with a specific provider and model
    public func regenerateWithModel(provider: AIProvider, model: String) async throws {
        AnalyticsManager.shared.captureWorkflow(
            workflow: "regenerate",
            stage: "started",
            outcome: "started",
            properties: ["variant": "model"]
        )
        if state == .scanning || state == .organizing {
            guard let directory = currentDirectory else {
                throw OrganizationError.noCurrentPlan
            }

            await cancelCurrentOperationForRestart()

            withBatchUpdates {
                clearStreamingDisplayState()
                isStreaming = false
                showTimeoutMessage = false
                currentInsight = ""
                insightHistory = []
                insightsCache = nil
                errorMessage = nil
                elapsedTime = 0
                let noun = aiConfig?.mode == .renameOnly ? "rename analysis" : "analysis"
                organizationStage = "Restarting \(noun) with \(provider.displayName) (\(model))..."
                progress = 0.08
            }

            try await runOrganizationTask(directory: directory, customPrompt: nil, temperature: nil)
            return
        }

        var files = getFilesFromCurrentPlan()

        if files.isEmpty, let directory = currentDirectory {
            files = try await scanPhase(directory: directory)
        }

        guard !files.isEmpty else {
            throw OrganizationError.noCurrentPlan
        }

        guard !isOperationInProgress() else {
            return
        }

        // Run inside the tracked task so cancel() aborts the AI request
        // instead of letting it keep generating a response nobody will use.
        cancelInternal()
        isCancellationRequested = false
        currentTask = Task {
            try await performRegenerateWithModel(provider: provider, model: model, files: files)
        }
        defer { currentTask = nil }
        do {
            try await currentTask?.value
        } catch where Self.isCancellationError(error) {
            if suppressCancellationReset {
                suppressCancellationReset = false
                throw CancellationError()
            }
            resetToIdle()
            throw CancellationError()
        }
    }

    private func performRegenerateWithModel(provider: AIProvider, model: String, files: [FileItem]) async throws {
        var files = files
        if let exclusionRules = exclusionRules {
            files = exclusionRules.filterFiles(files)
        }

        // Reset streaming state
        await MainActor.run {
            clearStreamingDisplayState()
            isStreaming = false
            showTimeoutMessage = false
            currentInsight = ""
            insightHistory = []
            insightsCache = nil
        }

        let modelStage = aiConfig?.mode == .renameOnly
            ? "Getting new names from \(provider.displayName) (\(model))..."
            : "Getting a new plan from \(provider.displayName) (\(model))..."
        updateState(.organizing, stage: modelStage, progress: 0.3)
        await MainActor.run {
            isStreaming = true
        }

        startTimeoutTimer()

        do {
            var newPlan = try await generatePlanWithProvider(files: files, provider: provider, model: model)
            newPlan.version = (currentPlan?.version ?? 0) + 1
            
            if let exclusionRules = exclusionRules {
                let enforcer = ExclusionEnforcer(exclusionManager: exclusionRules)
                let validationResult = enforcer.validate(newPlan)
                if validationResult.hasViolations {
                    LogManager.shared.log("Exclusion violations in regenerated preview: \(validationResult.violationCount)", category: "FolderOrganizer")
                    newPlan = validationResult.cleanedPlan ?? newPlan
                }
            }
            
            try checkCancellation()
            
            stopTimeoutTimer()
            
            await MainActor.run {
                guard !isCancellationRequested else { return }
                isStreaming = false
                organizationStage = "Ready!"
                progress = 1.0
                if let existingPlan = self.currentPlan {
                    self.recordPreviewVersion(existingPlan)
                }
                self.currentPlan = normalizeRenameSuggestions(in: applyRenameRuleConfiguration(to: newPlan))
                transition(to: .ready)
            }
            AnalyticsManager.shared.captureWorkflow(
                workflow: "regenerate",
                stage: "plan_ready",
                outcome: "success",
                properties: ["variant": "model"]
            )
        } catch where Self.isCancellationError(error) {
            stopTimeoutTimer()
            await MainActor.run {
                isStreaming = false
                if !suppressCancellationReset {
                    resetToIdle()
                }
            }
            throw CancellationError()
        } catch {
            stopTimeoutTimer()
            await MainActor.run {
                transition(to: .error(error), force: true)
                errorMessage = error.localizedDescription
            }
            AnalyticsManager.shared.captureWorkflow(
                workflow: "regenerate",
                stage: "plan_generation",
                outcome: "failed",
                properties: ["variant": "model"]
            )
            ReliabilityManager.shared.capture(
                error: error,
                feature: "organize",
                operation: "regenerate_with_model"
            )
            throw error
        }
    }

    // MARK: - Regenerate Preview

    public func regeneratePreview() async throws {
        AnalyticsManager.shared.captureWorkflow(
            workflow: "regenerate",
            stage: "started",
            outcome: "started",
            properties: ["variant": "same_configuration"]
        )
        guard let basePlan = currentPlan else {
            throw OrganizationError.noCurrentPlan
        }

        guard !isOperationInProgress() else {
            return
        }

        // Get original files from the current plan
        var allFiles: [FileItem] = []
        func collectFiles(_ suggestion: FolderSuggestion) {
            allFiles.append(contentsOf: suggestion.files)
            for subfolder in suggestion.subfolders {
                collectFiles(subfolder)
            }
        }
        for suggestion in basePlan.suggestions {
            collectFiles(suggestion)
        }
        allFiles.append(contentsOf: basePlan.unorganizedFiles)

        if let exclusionRules = exclusionRules {
            allFiles = exclusionRules.filterFiles(allFiles)
        }

        // Run inside the tracked task so cancel() aborts the AI request
        // instead of letting it keep generating a response nobody will use.
        cancelInternal()
        isCancellationRequested = false
        currentTask = Task {
            try await performRegeneratePreview(allFiles: allFiles, basePlan: basePlan)
        }
        defer { currentTask = nil }
        do {
            try await currentTask?.value
        } catch where Self.isCancellationError(error) {
            if suppressCancellationReset {
                suppressCancellationReset = false
                throw CancellationError()
            }
            resetToIdle()
            throw CancellationError()
        }
    }

    private func performRegeneratePreview(allFiles: [FileItem], basePlan: OrganizationPlan) async throws {
        let currentPlan = basePlan
        var allFiles = allFiles

        // Reset streaming state
        await MainActor.run {
            clearStreamingDisplayState()
            isStreaming = false
            showTimeoutMessage = false
            currentInsight = ""
            insightHistory = []
            insightsCache = nil
        }

        let isRenameOnly = aiConfig?.mode == .renameOnly
        updateState(
            .organizing,
            stage: isRenameOnly ? "Generating new filename suggestions..." : "Generating a new organization plan...",
            progress: 0.3
        )
        await MainActor.run {
            isStreaming = true
        }

        startTimeoutTimer()

        do {
            guard let client = aiClient else {
                throw OrganizationError.clientNotConfigured
            }

            try checkCancellation()

            // Log the previous attempt as skipped/superseded
            if let directory = currentDirectory, !currentRunLearningExcluded {
                let skippedEntry = OrganizationHistoryEntry(
                    directoryPath: directory.path,
                    filesOrganized: 0,
                    foldersCreated: 0,
                    plan: currentPlan,
                    success: false,
                    status: .skipped,
                    errorMessage: isRenameOnly ? "User requested different filename suggestions" : "User requested different organization",
                    rawAIResponse: streamingContent.isEmpty ? nil : streamingContent
                )
                history.addEntry(skippedEntry)
            }

            // Generate new plan
            let personaPrompt = personaManager?.getPrompt(for: personaManager?.selectedPersona ?? .general)
            
            var instructions = PromptBuilder.wrapDirectUserInstructions(customInstructions)
            if let learnedContext = learningsManager?.generatePromptContext(forFolder: currentDirectory?.path), !learnedContext.isEmpty {
                instructions += "\n\n" + learnedContext
            }

            if !isRenameOnly,
               let modelDirContext = learningsManager?.generateModelDirectoryContext(for: allFiles),
               !modelDirContext.isEmpty {
                instructions += "\n\n" + modelDirContext
            }
            
            // Add Storage Locations context
            if !isRenameOnly, let storageContext = await storageLocationsManager?.generatePromptContext(), !storageContext.isEmpty {
                instructions += "\n\n" + storageContext
            }
            instructions += exclusionInstructions(forRenameOnly: isRenameOnly)
            
            var newPlan = try await analyzeInBoundedBatches(
                files: allFiles,
                client: client,
                imagePayload: [:],
                instructions: instructions,
                personaPrompt: personaPrompt,
                temperature: nil
            )
            newPlan.version = (currentPlan.version) + 1
            
            if let exclusionRules = exclusionRules {
                let enforcer = ExclusionEnforcer(exclusionManager: exclusionRules)
                let validationResult = enforcer.validate(newPlan)
                if validationResult.hasViolations {
                    LogManager.shared.log("Exclusion violations in regenerated preview: \(validationResult.violationCount)", category: "FolderOrganizer")
                    newPlan = validationResult.cleanedPlan ?? newPlan
                }
            }

            handleLearningToolCall(
                from: newPlan,
                source: .manual,
                folderPath: currentDirectory?.path ?? ""
            )

            if let directory = currentDirectory, !currentRunLearningExcluded {
                let summary = currentPlan.suggestions
                    .map { "\($0.folderName) (\($0.files.count) files)" }
                    .joined(separator: ", ")
                learningsManager?.recordRegeneratedOrganization(
                    folderPath: directory.path,
                    previousPlanSummary: summary,
                    guidingInstruction: customInstructions,
                    regenerationCount: currentPlan.version
                )
                learningsManager?.recordGuidingInstruction(
                    customInstructions,
                    for: directory.path,
                    fileCount: allFiles.count
                )
            }

            stopTimeoutTimer()

            try checkCancellation()

            await MainActor.run {
                guard !isCancellationRequested else { return }
                isStreaming = false
                organizationStage = "Ready!"
                progress = 1.0
                if let existingPlan = self.currentPlan {
                    self.recordPreviewVersion(existingPlan)
                }
                self.currentPlan = normalizeRenameSuggestions(in: applyRenameRuleConfiguration(to: newPlan))
                transition(to: .ready)
            }
            AnalyticsManager.shared.captureWorkflow(
                workflow: "regenerate",
                stage: "plan_ready",
                outcome: "success",
                properties: ["variant": "same_configuration"]
            )

        } catch where Self.isCancellationError(error) {
            stopTimeoutTimer()
            await MainActor.run {
                isStreaming = false
                if !suppressCancellationReset {
                    resetToIdle()
                }
            }
            throw CancellationError()
        } catch {
            stopTimeoutTimer()

            // Record failed attempt
            if let directory = currentDirectory {
                let failedEntry = OrganizationHistoryEntry(
                    directoryPath: directory.path,
                    filesOrganized: 0,
                    foldersCreated: 0,
                    plan: nil,
                    success: false,
                    status: .failed,
                    errorMessage: error.localizedDescription,
                    rawAIResponse: streamingContent.isEmpty ? nil : streamingContent
                )
                history.addEntry(failedEntry)
            }

            AnalyticsManager.shared.captureWorkflow(
                workflow: "regenerate",
                stage: "plan_generation",
                outcome: "failed",
                properties: ["variant": "same_configuration"]
            )
            ReliabilityManager.shared.capture(
                error: error,
                feature: "organize",
                operation: "regenerate_preview"
            )
            throw error
        }
    }

    // MARK: - Multi-State Undo/Redo

    private func normalizedRevertPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func retainedOperations(
        from operations: [FileSystemManager.FileOperation]?,
        retryableFailedOperationIDs: [UUID]
    ) -> [FileSystemManager.FileOperation]? {
        guard let operations, !operations.isEmpty else {
            return nil
        }

        let failedIDs = Set(retryableFailedOperationIDs)
        guard !failedIDs.isEmpty else {
            return nil
        }

        let remaining = operations.filter { failedIDs.contains($0.id) }
        return remaining.isEmpty ? nil : remaining
    }

    private func withRevertGuard<T>(
        entryIDs: [UUID],
        path: String,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        let normalizedPath = normalizedRevertPath(path)
        let didAcquire = await revertOperationTracker.begin(entryIDs: entryIDs, path: normalizedPath)
        guard didAcquire else {
            throw OrganizationError.revertAlreadyInProgress(normalizedPath)
        }

        #if DEBUG
        if let revertOperationTestHook {
            await revertOperationTestHook()
        }
        #endif

        do {
            let result = try await operation()
            await revertOperationTracker.end(entryIDs: entryIDs, path: normalizedPath)
            return result
        } catch {
            await revertOperationTracker.end(entryIDs: entryIDs, path: normalizedPath)
            throw error
        }
    }

    @discardableResult
    private func performUndoHistoryEntry(
        _ entry: OrganizationHistoryEntry,
        shouldPostNotification: Bool
    ) async throws -> FileSystemManager.RestoreResult {
        guard let operations = entry.operations, !operations.isEmpty, !entry.isUndone else {
            return FileSystemManager.RestoreResult(successfulOperations: 0, missingFiles: [])
        }

        updateState(.applying, stage: "Verifying files before undo...", progress: 0.1)

        let moveOps = operations.filter { $0.type == .moveFile || $0.type == .renameFile }
        var preCheckMissing: [String] = []
        for op in moveOps {
            if let dest = op.destinationPath, !FileManager.default.fileExists(atPath: dest) {
                let filename = URL(fileURLWithPath: dest).lastPathComponent
                preCheckMissing.append(filename)
                DebugLogger.log("Pre-check: file missing at \(dest)")
            }
        }

        if !preCheckMissing.isEmpty {
            let totalMoves = moveOps.count
            DebugLogger.log("Pre-check: \(preCheckMissing.count)/\(totalMoves) files missing before undo")
        }

        updateProgress(0.3, stage: "Undoing changes...")

        do {
            let result = try await fileSystemManager.reverseOperations(operations)

            var updatedEntry = entry
            let remainingOperations = retainedOperations(
                from: updatedEntry.operations,
                retryableFailedOperationIDs: result.retryableFailedOperationIDs
            )

            updatedEntry.operations = remainingOperations
            updatedEntry.isUndone = !result.hasIssues && remainingOperations == nil
            updatedEntry.undoRestoredCount = (entry.undoRestoredCount ?? 0) + result.successfulOperations
            updatedEntry.undoFailedFiles = result.hasIssues ? result.missingFiles : nil
            updatedEntry.status = remainingOperations == nil && !result.hasIssues ? .undo : .partiallyUndone

            history.updateEntry(updatedEntry)

            await MainActor.run {
                if result.hasIssues, !result.missingFiles.isEmpty {
                    organizationStage = "Undo complete: \(result.successfulOperations) restored, \(result.missingFiles.count) couldn't be found"
                } else if result.hasIssues {
                    organizationStage = "Undo complete: \(result.successfulOperations) restored"
                } else {
                    organizationStage = "Undo complete"
                }
                progress = 1.0
                transition(to: .idle, force: true)
            }

            if shouldPostNotification {
                NotificationCenter.default.post(
                    name: .organizationDidRevert,
                    object: nil,
                    userInfo: [
                        "url": URL(fileURLWithPath: entry.directoryPath),
                        "entry": updatedEntry,
                        "restoreResult": result
                    ]
                )
            }

            return result

        } catch {
            await MainActor.run {
                transition(to: .error(error), force: true)
                errorMessage = error.localizedDescription
            }
            throw error
        }
    }

    /// Undoes a specific historical session
    /// Pre-checks file existence, recovers from per-file errors, and tracks partial success
    @discardableResult
    public func undoHistoryEntry(_ entry: OrganizationHistoryEntry) async throws -> FileSystemManager.RestoreResult {
        let entry = await history.details(for: entry)
        let reliabilitySpan = ReliabilityManager.shared.startSpan(
            name: "undo_organization",
            operation: "workflow.undo",
            feature: "history"
        )
        defer { reliabilitySpan?.finish() }
        AnalyticsManager.shared.captureWorkflow(
            workflow: "undo",
            stage: "started",
            outcome: "started"
        )
        do {
            let result = try await withRevertGuard(entryIDs: [entry.id], path: entry.directoryPath) {
                try await self.performUndoHistoryEntry(entry, shouldPostNotification: true)
            }
            AnalyticsManager.shared.captureWorkflow(
                workflow: "undo",
                stage: "completed",
                outcome: result.hasIssues ? "partially_completed" : "success",
                properties: [
                    "count_bucket": AnalyticsManager.countBucket(result.successfulOperations),
                ]
            )
            return result
        } catch {
            AnalyticsManager.shared.captureWorkflow(
                workflow: "undo",
                stage: "restore",
                outcome: "failed"
            )
            ReliabilityManager.shared.capture(
                error: error,
                feature: "history",
                operation: "undo_organization"
            )
            throw error
        }
    }

    /// Restores to a previous state by undoing all intermediate sessions
    /// Returns a combined RestoreResult with totals from all undone entries
    @discardableResult
    public func restoreToState(targetEntry: OrganizationHistoryEntry) async throws -> FileSystemManager.RestoreResult {
        // Find all sessions on the same path that are after this one and not undone
        let path = targetEntry.directoryPath
        let entriesToUndo = history.entries.filter {
            $0.directoryPath == path &&
            $0.timestamp > targetEntry.timestamp &&
            !$0.isUndone &&
            ($0.status == .completed || $0.status == .partiallyUndone) &&
            $0.storedOperationCount > 0
        }.sorted { $0.timestamp > $1.timestamp } // Undo most recent first

        return try await withRevertGuard(
            entryIDs: entriesToUndo.map(\.id),
            path: path
        ) {
            self.updateState(.applying, stage: "Rolling back states...", progress: 0.1)

            let total = Double(max(entriesToUndo.count, 1))
            var combinedSuccessCount = 0
            var combinedMissingFiles: [String] = []
            var combinedRetryableFailures: [UUID] = []

            for (index, entry) in entriesToUndo.enumerated() {
                let entry = await self.history.details(for: entry)
                self.updateProgress(Double(index) / total, stage: "Undoing session from \(entry.timestamp.formatted())...")

                let result = try await self.performUndoHistoryEntry(entry, shouldPostNotification: true)
                combinedSuccessCount += result.successfulOperations
                combinedMissingFiles.append(contentsOf: result.missingFiles)
                combinedRetryableFailures.append(contentsOf: result.retryableFailedOperationIDs)
            }

            let combinedResult = FileSystemManager.RestoreResult(
                successfulOperations: combinedSuccessCount,
                missingFiles: combinedMissingFiles,
                retryableFailedOperationIDs: combinedRetryableFailures
            )

            await MainActor.run { [self] in
                self.organizationStage = combinedResult.hasIssues ? "Restoration complete (some files skipped)" : "Restoration complete"
                self.progress = 1.0
                self.transition(to: .idle, force: true)
            }

            return combinedResult
        }
    }

    /// Undoes a single file operation within a history entry
    @discardableResult
    public func undoSingleOperation(from entry: OrganizationHistoryEntry, operation: FileSystemManager.FileOperation) async throws -> FileSystemManager.RestoreResult {
        let detailedEntry = await history.details(for: entry)
        let currentOperation = detailedEntry.operations?.first { $0.id == operation.id } ?? operation
        return try await withRevertGuard(entryIDs: [detailedEntry.id], path: detailedEntry.directoryPath) {
            let siblingOperations = (detailedEntry.operations ?? []).filter { $0.id != currentOperation.id }
            let result = try await self.fileSystemManager.restoreSingleOperation(
                currentOperation,
                protectedSiblingOperations: siblingOperations
            )

            await MainActor.run {
                var updatedEntry = detailedEntry
                let shouldRetainOperation = result.retryableFailedOperationIDs.contains(currentOperation.id)
                if !shouldRetainOperation {
                    updatedEntry.operations?.removeAll { $0.id == currentOperation.id }
                    if updatedEntry.operations?.isEmpty == true {
                        updatedEntry.operations = nil
                    }
                }

                let fullyUndone = updatedEntry.operations == nil && !result.hasIssues
                updatedEntry.isUndone = fullyUndone
                updatedEntry.status = fullyUndone ? .undo : .partiallyUndone
                updatedEntry.undoRestoredCount = (detailedEntry.undoRestoredCount ?? 0) + result.successfulOperations
                updatedEntry.undoFailedFiles = result.hasIssues ? result.missingFiles : nil

                self.history.updateEntry(updatedEntry)
            }

            return result
        }
    }

    // MARK: - Reset

    public func reset() {
        cancelInternal()
        preparedPlanModeOverride = nil
        
        // Clear transient AI session errors on manual reset
        AISessionManager.shared.clearErrors()

        // Batch all reset operations into a single UI update cycle
        withBatchUpdates {
            pinsCompletionView = false
            transition(to: .idle, force: true)
            progress = 0.0
            currentPlan = nil
            planHistory = []
            errorMessage = nil
            clearStreamingDisplayState()
            organizationStage = ""
            isStreaming = false
            showTimeoutMessage = false
            elapsedTime = 0
            currentDirectory = nil
            blockingExclusionRule = nil
            scannedFileCount = 0
            scannedFiles = []
            detectedDuplicates = []
            measuredWorkProgress = nil
            visionAnalysisSummary = nil
            resumeCheckpoint = nil
            // Keep isCancellationRequested=true so late chunks/callbacks from the
            // cancelled run keep dropping. The next operation resets it to false.
            userInitiatedAction = false
            
            // Clear AI insights and cache
            insightExtractionTask?.cancel()
            insightExtractionTask = nil
            currentInsight = ""
            insightHistory = []
            lastInsightExtraction = .distantPast
            insightsCache = nil
        }
        clearPersistedManualSession()
    }

    // MARK: - Manual session restore (Full Disk Access restart)

    /// Why a manual session was snapshotted. Selected/interrupted runs
    /// restore the folder without a plan; ready/completed runs restore the plan.
    public enum ManualSessionStateHint: String, Codable, Sendable {
        case selected
        case interrupted
        case ready
        case completed
    }

    private struct PersistedManualSession: Codable, Sendable {
        var directoryPath: String
        var directoryBookmark: Data?
        var customInstructions: String
        var plan: OrganizationPlan?
        var stateHint: ManualSessionStateHint
        var savedAt: Date
    }

    private struct ManualSessionRestoreResult: Sendable {
        let snapshot: PersistedManualSession
        let directory: URL
        let scopedBookmarkURL: URL?
    }

    static func defaultManualSessionURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sorty", isDirectory: true)
            .appendingPathComponent("ManualSession.json")
    }

    private func resolvedManualSessionURL(_ explicit: URL? = nil) -> URL? {
        explicit ?? manualSessionURLForTesting ?? Self.defaultManualSessionURL()
    }

    /// Snapshots the manual session for restart recovery. Writes stay on the
    /// main actor per the startup contract; each call replaces the previous
    /// snapshot so the file always reflects the latest user-visible state.
    public func persistManualSession(
        directory: URL,
        plan: OrganizationPlan?,
        stateHint: ManualSessionStateHint,
        instructions: String,
        url: URL? = nil
    ) {
        guard isManualSessionPersistenceEnabled else { return }
        let targetURL = resolvedManualSessionURL(url)
        guard let targetURL else { return }
        let directoryPath = directory.standardizedFileURL.path
        let bookmark: Data?
        if cachedManualSessionDirectoryPath == directoryPath {
            bookmark = cachedManualSessionBookmark
        } else {
            bookmark = try? directory.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            cachedManualSessionDirectoryPath = directoryPath
            cachedManualSessionBookmark = bookmark
        }
        let snapshot = PersistedManualSession(
            directoryPath: directoryPath,
            directoryBookmark: bookmark,
            customInstructions: instructions,
            plan: plan,
            stateHint: stateHint,
            savedAt: Date()
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var fingerprintSnapshot = snapshot
            fingerprintSnapshot.savedAt = .distantPast
            let fingerprint = try encoder.encode(fingerprintSnapshot)
            if lastManualSessionFingerprintByURL[targetURL] == fingerprint,
               FileManager.default.fileExists(atPath: targetURL.path) {
                return
            }
            manualSessionGeneration &+= 1
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(snapshot)
            try data.write(to: targetURL, options: .atomic)
            lastManualSessionFingerprintByURL[targetURL] = fingerprint
        } catch {
            print("FolderOrganizer: Failed to persist manual session: \(error)")
        }
    }

    /// Records a folder selection before analysis starts. Skips when a richer
    /// snapshot (in-progress run or ready plan) is already active so restoring
    /// cannot clobber it back to a bare selection.
    public func persistSelectedDirectoryForRestart(_ url: URL, sessionURL: URL? = nil) {
        guard isManualSessionPersistenceEnabled,
              state == .idle,
              currentPlan == nil else { return }
        persistManualSession(directory: url, plan: nil, stateHint: .selected, instructions: customInstructions, url: sessionURL)
    }

    public func clearPersistedManualSession(url: URL? = nil) {
        guard isManualSessionPersistenceEnabled else { return }
        let targetURL = resolvedManualSessionURL(url)
        guard let targetURL else { return }
        manualSessionGeneration &+= 1
        restoredManualSessionScopedURL?.stopAccessingSecurityScopedResource()
        restoredManualSessionScopedURL = nil
        try? FileManager.default.removeItem(at: targetURL)
        lastManualSessionFingerprintByURL.removeValue(forKey: targetURL)
    }

    /// Restores the snapshotted folder (and ready/completed plan when present).
    /// Reads and decodes off the main actor; published state mutates on it.
    /// Returns the restored directory so the caller can reselect it.
    @discardableResult
    public func restorePersistedManualSession(sessionURL: URL? = nil) async -> URL? {
        guard isManualSessionPersistenceEnabled else { return nil }
        guard state == .idle, currentDirectory == nil, currentPlan == nil else { return nil }
        let targetURL = resolvedManualSessionURL(sessionURL)
        guard let targetURL else { return nil }
        let generation = manualSessionGeneration
        let result: ManualSessionRestoreResult? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: targetURL) else { return nil }
            guard let snapshot = try? JSONDecoder().decode(PersistedManualSession.self, from: data) else {
                return nil
            }
            var resolved: URL?
            var scopedBookmarkURL: URL?
            if let bookmark = snapshot.directoryBookmark {
                var isStale = false
                if let bookmarkURL = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    if bookmarkURL.startAccessingSecurityScopedResource() {
                        scopedBookmarkURL = bookmarkURL
                    }
                    resolved = bookmarkURL.standardizedFileURL
                }
            }
            let directory = resolved
                ?? URL(fileURLWithPath: snapshot.directoryPath).standardizedFileURL
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                scopedBookmarkURL?.stopAccessingSecurityScopedResource()
                try? FileManager.default.removeItem(at: targetURL)
                return nil
            }
            return ManualSessionRestoreResult(
                snapshot: snapshot,
                directory: directory,
                scopedBookmarkURL: scopedBookmarkURL
            )
        }.value
        guard let result else { return nil }
        guard generation == manualSessionGeneration,
              state == .idle,
              currentDirectory == nil,
              currentPlan == nil,
              resolvedManualSessionURL(sessionURL) == targetURL else {
            result.scopedBookmarkURL?.stopAccessingSecurityScopedResource()
            return nil
        }
        let snapshot = result.snapshot
        let directory = result.directory
        restoredManualSessionScopedURL?.stopAccessingSecurityScopedResource()
        restoredManualSessionScopedURL = result.scopedBookmarkURL
        customInstructions = snapshot.customInstructions
        currentDirectory = directory
        switch snapshot.stateHint {
        case .ready:
            guard let plan = snapshot.plan else { return directory }
            currentPlan = plan
            progress = 1.0
            transition(to: .ready, force: true)
            organizationStage = "Ready!"
        case .completed:
            guard let plan = snapshot.plan else { return directory }
            currentPlan = plan
            progress = 1.0
            transition(to: .completed, force: true)
            organizationStage = "Complete!"
        case .selected, .interrupted:
            break
        }
        return directory
    }

    public func loadPreparedIncrementalPlan(
        _ plan: OrganizationPlan,
        directory: URL,
        mode: OrganizationMode
    ) {
        cancelInternal()
        isCancellationRequested = false
        currentDirectory = directory
        currentPlan = plan
        preparedPlanModeOverride = mode
        transition(to: .ready, force: true)
        organizationStage = "Ready for review"
        progress = 1
    }
    private func recordPlanRules(_ plan: OrganizationPlan, observer: ContinuousLearningObserver) {
        // Recursively record rules
        let rootPath = currentDirectory?.path ?? ""
        
        func processSuggestion(_ suggestion: FolderSuggestion, currentPath: String) {
            let folderPath = (currentPath as NSString).appendingPathComponent(suggestion.folderName)
            
            // Record rules for files in this folder
            for _ in suggestion.files {
                let destinationPath = folderPath // Approximate destination path for the file
                
                // If the suggestion has a rule ID (from Learnings analysis), record it
                if let ruleId = suggestion.semanticTags.first(where: { $0.hasPrefix("rule:") })?.replacingOccurrences(of: "rule:", with: "") {
                    observer.recordRuleApplication(destinationPath: destinationPath, ruleId: ruleId)
                }
            }
            
            // Recurse
            for subfolder in suggestion.subfolders {
                processSuggestion(subfolder, currentPath: folderPath)
            }
        }
        
        for suggestion in plan.suggestions {
            processSuggestion(suggestion, currentPath: rootPath)
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
