//
//  AnalysisView.swift
//  Sorty
//
//  Real-time organization display with streaming progress
//

import Combine
import SwiftUI
import UniformTypeIdentifiers
import Beam

// MARK: - Analysis Icon Provider

@MainActor
enum AnalysisIconProvider {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 160
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    static func icon(for contentType: UTType) -> NSImage {
        let key = "type:\(contentType.identifier)"
        if let image = cache.object(forKey: key as NSString) {
            return image
        }
        let image = copiedIcon(NSWorkspace.shared.icon(for: contentType))
        image.size = NSSize(width: 32, height: 32)
        cache.setObject(image, forKey: key as NSString, cost: imageCost(image))
        return image
    }

    static func icon(forFileExtension fileExtension: String) -> NSImage {
        let normalizedExtension =
            fileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedExtension.isEmpty else {
            return icon(for: .data)
        }

        let key = "ext:\(normalizedExtension)"
        if let image = cache.object(forKey: key as NSString) {
            return image
        }
        let image = copiedIcon(NSWorkspace.shared.icon(forFileType: normalizedExtension))
        image.size = NSSize(width: 32, height: 32)
        cache.setObject(image, forKey: key as NSString, cost: imageCost(image))
        return image
    }

    /// Copies a shared workspace icon so view recycling never mutates the
    /// shared instance. Falls back to the original on copy failure instead
    /// of trapping on `as!`.
    private static func copiedIcon(_ icon: NSImage) -> NSImage {
        (icon.copy() as? NSImage) ?? icon
    }

    private static func imageCost(_ image: NSImage) -> Int {
        let pixels = max(1, Int(image.size.width * 2 * image.size.height * 2))
        return pixels * 4
    }
}

// MARK: - Unified Refresh Manager

/// Consolidates multiple timers into a single refresh manager to reduce memory overhead
/// and potential retain cycles. Uses the shared RefreshManager for centralized control.
@MainActor
final class AnalysisRefreshManager: ObservableObject {
    @Published var currentFunnyMessage: String = ""
    @Published var funnyMessageOpacity: Double = 0

    private var refreshManager: RefreshManager?
    private weak var organizer: FolderOrganizer?
    private var timerGroup: CoordinatedRefreshGroup?

    private let funnyMessages = [
        "Teaching folders to play nice together...",
        "Convincing files they belong somewhere...",
        "Negotiating peace between PDFs and PNGs...",
        "Whispering sweet nothings to your documents...",
        "Giving your files a well-deserved spa day...",
        "Herding digital cats into folders...",
        "Making your chaos look intentional...",
        "Turning your file salad into a proper meal...",
        "Convincing duplicates to pick a side...",
        "Teaching old files new tricks...",
        "Sorting at the speed of thought...",
        "Giving your desktop a makeover...",
        "Playing matchmaker with your files...",
        "Building tiny digital homes for your data...",
        "Turning file spaghetti into lasagna...",
        "Your files are learning to get along...",
        "Orchestrating a symphony of folders...",
        "Performing file feng shui...",
        "Making Marie Kondo proud...",
        "Alphabetizing... just kidding, we're smarter than that...",
    ]

    private let calmerMessages = [
        "Still working...",
        "Almost there...",
        "Processing your files...",
        "Preparing your preview...",
        "Just a moment longer...",
    ]

    func start(organizer: FolderOrganizer) {
        self.organizer = organizer

        // Set initial values
        currentFunnyMessage = nextStatusMessage()

        withAnimation(.easeIn(duration: 0.5)) {
            funnyMessageOpacity = 1
        }

        // Use the centralized RefreshManager with coordinated group
        refreshManager = RefreshManager()
        timerGroup = refreshManager?.createCoordinatedGroup()

        startRefreshLoop()
    }

    func stop() {
        timerGroup?.cancelAll()
        timerGroup = nil
        refreshManager?.cancelAll()
        refreshManager = nil
        organizer = nil
        currentFunnyMessage = ""
        funnyMessageOpacity = 0
    }

    func pause() {
        timerGroup?.pause()
    }

    func resume() {
        timerGroup?.resume()
    }

    private func startRefreshLoop() {
        // Use async tasks with weak self to prevent retain cycles
        // Funny message cycle: every 5s (reduced from 4s)
        timerGroup?.addTimer(interval: 5.0) { [weak self] in
            Task { [weak self] in
                await self?.cycleFunnyMessage()
            }
        }
    }

    private func cycleFunnyMessage() async {
        guard organizer != nil else { return }
        // Fire only while an organization run is active; the timer itself is
        // started/stopped with the view lifecycle (onAppear/onDisappear).
        guard organizer?.state == .organizing else { return }

        withAnimation(.easeInOut(duration: 0.55)) {
            funnyMessageOpacity = 0
        }

        try? await Task.sleep(nanoseconds: 520_000_000)
        guard organizer != nil else { return }

        let elapsedSeconds = Int(organizer?.elapsedTime ?? 0)
        if elapsedSeconds > 30 {
            currentFunnyMessage = calmerMessages.randomElement() ?? calmerMessages.first ?? "Still working..."
        } else {
            currentFunnyMessage = nextStatusMessage()
        }

        withAnimation(.easeInOut(duration: 0.65)) {
            funnyMessageOpacity = 1
        }
    }

    private func nextStatusMessage() -> String {
        funnyMessages.randomElement() ?? funnyMessages.first ?? "Working..."
    }
}

struct AnalysisView: View {
    @SortyHotReload private var hotReload
    var onReturnToStart: (() -> Void)?
    var onLiveOrganizationStarted: (() -> Void)?

    @EnvironmentObject var organizer: FolderOrganizer
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var learningsManager: LearningsManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("analysis.liveInsightsEnabled") private var liveInsightsEnabled = true
    @AppStorage("analysis.hideTakingLongerHUD") private var hideTakingLongerHUD = false
    @StateObject private var refreshManager = AnalysisRefreshManager()
    @State private var hasAppeared = false
    @State private var showCancelConfirmation = false
    @State private var showFasterModelPicker = false
    @State private var didShowTakingLongerHUD = false
    @State private var pendingModelSwitch: PendingModelSwitch?
    @State private var lastInsightCount = 0
    @State private var lastMessageTier: MessageTier = .none
    @State private var lastInsightPulseAt: Date = .distantPast
    @State private var liveRenameStreamEvents: [RenameStreamEvent] = []
    @State private var hasOrganizeStreamEvents = false
    @State private var liveOrganizingSuggestions: [FolderSuggestion] = []
    @State private var streamPreviewState = LiveStreamPreviewState()
    @State private var isHoveringViewExclusion = false
    @State private var isHoveringChangeFolder = false

    private enum MessageTier {
        case none
        case backgroundTip
        case takingLonger
    }

    private struct PendingModelSwitch: Equatable {
        let provider: AIProvider
        let model: String
        let mode: OrganizationMode

        var restartStage: String {
            let noun = mode == .renameOnly ? "rename analysis" : "analysis"
            return "Restarting \(noun) with \(provider.displayName) (\(model))..."
        }
    }

    private var currentMessageTier: MessageTier {
        let elapsedSeconds = Int(organizer.elapsedTime)
        if elapsedSeconds >= 90 || organizer.showTimeoutMessage {
            return .takingLonger
        } else if elapsedSeconds >= 30 {
            return .backgroundTip
        }
        return .none
    }

    private var isRenameOnlyFlow: Bool {
        settingsViewModel.config.mode == .renameOnly
    }

    private var hasRenameStreamEvents: Bool {
        !liveRenameStreamEvents.isEmpty
    }

    /// Whether the scan found zero files (empty directory or all files excluded)
    private var isEmptyDirectory: Bool {
        if organizer.blockingExclusionRule != nil {
            return true
        }
        let stage = organizer.organizationStage
        return stage.contains("Filtered to 0 files")
            || stage.contains("No files found to organize")
            || (stage.contains("Found 0 files") && !organizer.isStreaming)
    }

    var body: some View {
        WorkflowContainer(currentStep: .analyze) {
            Spacer(minLength: 20)

            if isEmptyDirectory {
                emptyDirectoryView
            } else {
                VStack(spacing: 24) {
                    progressSection
                        .opacity(hasAppeared ? 1 : 0)
                        .scaleEffect(hasAppeared ? 1 : 0.9)
                        .animation(
                            .spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: hasAppeared)

                    tieredNoticeView

                    if isRenameOnlyFlow {
                        if hasRenameStreamEvents {
                            RenameGenerationSequenceView(
                                events: liveRenameStreamEvents
                            )
                                .frame(maxWidth: .infinity)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                    } else if hasOrganizeStreamEvents {
                        OrganizingFlightStageView(
                            suggestions: liveOrganizingSuggestions,
                            prioritizesFilenames: settingsViewModel.config.mode == .organizeAndRename
                        )
                            .frame(maxWidth: .infinity)
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.96)),
                                    removal: .opacity
                                )
                            )
                    } else if isAIAnalysisPhaseActive {
                        aiInsightsView
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                    }

                    analysisActionButtons
                }
                .frame(maxHeight: .infinity)
                .animation(.spring(response: 0.34, dampingFraction: 0.86), value: hasRenameStreamEvents)
                .animation(.spring(response: 0.34, dampingFraction: 0.86), value: hasOrganizeStreamEvents)
            }

            Spacer(minLength: 20)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                hasAppeared = true
            }
            settingsViewModel.config.enableStreaming = true
            liveInsightsEnabled = true
            organizer.setLiveInsightsEnabled(true)
            refreshManager.start(organizer: organizer)
            refreshStreamDerivedState(force: true)
        }
        .onDisappear {
            refreshManager.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshManager.resume()
            } else {
                refreshManager.pause()
            }
        }
        .onChange(of: liveInsightsEnabled) { _, enabled in
            organizer.setLiveInsightsEnabled(enabled)
        }
        .onChange(of: organizer.insightHistory.count) { _, newCount in
            lastInsightCount = newCount
        }
        .onChange(of: currentMessageTier) { oldTier, newTier in
            if oldTier == .none, newTier != .none {
                HapticSequenceManager.shared.playEventPulse()
            }
            if newTier == .takingLonger {
                showTakingLongerHUDIfNeeded()
            } else {
                didShowTakingLongerHUD = false
                NotificationManager.shared.dismissHUD()
            }
        }
        .onChange(of: organizer.organizationStage) { _, newStage in
            guard let pendingModelSwitch else { return }
            guard !newStage.isEmpty, newStage != pendingModelSwitch.restartStage else { return }
            self.pendingModelSwitch = nil
        }
        .onChange(of: organizer.displayStreamingContent) { _, _ in
            refreshStreamDerivedState()
        }
        .onChange(of: organizer.scannedFiles) { _, _ in
            refreshStreamDerivedState(force: true)
        }
        .onChange(of: settingsViewModel.config.mode) { _, _ in
            refreshStreamDerivedState(force: true)
        }
        .modelSelectionOverlay(
            isPresented: $showFasterModelPicker,
            currentProvider: settingsViewModel.config.provider,
            currentModel: settingsViewModel.config.model,
            contextMessage: "Sorty will stop the current attempt and restart analysis from the beginning. The model you choose becomes your active model for future runs.",
            selectionActionTitle: "Restart Analysis",
            isSelectionActionProminent: false,
            reasoningEffortForModel: { provider, model in
                settingsViewModel.config.reasoningEffort(for: provider, model: model)
            },
            onSelectReasoningEffort: { provider, model, effort in
                settingsViewModel.config.setReasoningEffort(effort, for: provider, model: model)
            },
            onSelect: { provider, model, authMethod in
                if let authMethod {
                    settingsViewModel.config.setAuthMethod(authMethod, for: provider)
                }
                handleFasterModelSelection(provider: provider, model: model)
            },
            isSubscriptionSelected: settingsViewModel.config.authMethod(for: settingsViewModel.config.provider) == .accountSignIn
        )
    }

    @ViewBuilder
    private var tieredNoticeView: some View {
        if let pendingModelSwitch {
            modelSwitchNotice(pendingModelSwitch)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    )
                )
        } else {
            switch currentMessageTier {
            case .none:
                EmptyView()
            case .backgroundTip:
                multitaskingHint
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
            case .takingLonger:
                EmptyView()
            }
        }
    }

    private var progressSection: some View {
        StreamingProgressBeam(
            measuredProgress: organizer.measuredWorkProgress,
            overallProgress: organizer.progress,
            stage: organizer.organizationStage,
            elapsedSeconds: Int(organizer.elapsedTime),
            isEstablishingConnection: isEstablishingConnection,
            state: organizer.state,
            matchesInsightsWidth: showsLiveInsightsIsland
        )
    }

    /// True while the AI request phase is running: connecting, preparing
    /// vision images, waiting for the first token, or streaming. Fresh
    /// organize runs only set `isStreaming` once the first chunk arrives,
    /// while the regenerate paths force it at request start; gating the
    /// insights island on this keeps both flows consistent.
    private var isAIAnalysisPhaseActive: Bool {
        organizer.isStreaming || organizer.state == .organizing
    }

    /// Sub-phase shown by the insights island. Prefers the organizer's
    /// published activity; falls back to inference for paths (such as the
    /// provider-switch regenerate) that force `isStreaming` without setting it.
    private var insightIslandActivity: AIAnalysisActivity {
        let activity = organizer.aiAnalysisActivity
        guard activity == .none else { return activity }
        if organizer.isStreaming { return .requesting }
        guard organizer.state == .organizing else { return .none }
        return organizer.displayStreamingContent.isEmpty ? .requesting : .validating
    }

    /// True when the live insights island (`aiInsightsView`) is visible beneath
    /// the progress banner, so the banner can expand to meet its width.
    private var showsLiveInsightsIsland: Bool {
        guard !isRenameOnlyFlow, !hasOrganizeStreamEvents else { return false }
        return isAIAnalysisPhaseActive
    }

    private var stageIndicator: some View {
        AIReasoningStatus(
            state: organizer.state,
            organizationStage: organizer.organizationStage,
            isStreaming: organizer.isStreaming,
            isEstablishingConnection: isEstablishingConnection,
            isRenameOnly: isRenameOnlyFlow,
            funnyMessage: refreshManager.currentFunnyMessage,
            funnyMessageOpacity: refreshManager.funnyMessageOpacity
        )
    }

    private var isEstablishingConnection: Bool {
        if case .organizing = organizer.state {
            let stage = organizer.organizationStage
            let isConnecting = stage.contains("Establishing") || stage.contains("Connecting")
            return isConnecting && !organizer.isStreaming
        }
        return false
    }

    private var multitaskingHint: some View {
        InlineNotice(
            icon: "bell.badge",
            title: "Working in the background",
            message: "Sorty will send a notification when your preview is ready",
            severity: .tip,
            isCentered: true
        )
        .accessibilityLabel("Background processing")
        .accessibilityHint("You will be notified when the preview is ready")
    }

    private func showTakingLongerHUDIfNeeded() {
        guard !hideTakingLongerHUD, !didShowTakingLongerHUD else { return }
        didShowTakingLongerHUD = true

        NotificationManager.shared.showHUDInfo(
            title: "This \(settingsViewModel.config.mode.gerund) run is taking a while",
            message: "Large folders can take 1-3 minutes. You can keep working in other apps.",
            icon: "clock.badge.exclamationmark",
            iconColor: .orange,
            actions: [
                HUDNotificationAction(title: "Try Faster Model", systemImage: "bolt.circle") {
                    HapticFeedbackManager.shared.tap()
                    showFasterModelPicker = true
                    NotificationManager.shared.dismissHUD()
                },
                HUDNotificationAction(title: "Cancel", systemImage: "xmark.circle", role: .destructive) {
                    HapticFeedbackManager.shared.tap()
                    recordCancelledAnalysis()
                    returnToStart()
                    NotificationManager.shared.dismissHUD()
                },
                HUDNotificationAction(title: "Never show again") {
                    hideTakingLongerHUD = true
                    NotificationManager.shared.dismissHUD()
                }
            ]
        )
    }

    // MARK: - Empty Directory View

    private var emptyDirectoryView: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.1))
                    .frame(width: 100, height: 100)

                Image(systemName: "folder.badge.minus")
                    .font(.system(size: 44))
                    .foregroundColor(.orange)
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.9)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: hasAppeared)

            VStack(spacing: 8) {
                Text(emptyDirectoryTitle)
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(emptyDirectoryMessage)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: hasAppeared)

            HStack(spacing: 14) {
                Button {
                    HapticFeedbackManager.shared.tap()
                    recordCancelledAnalysis()
                    returnToStart()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Cancel")
                            .font(.callout.weight(.semibold))
                    }
                }
                .buttonStyle(.tintedPill(.red))
                .accessibilityIdentifier("AnalysisEmptyCancelButton")

                if let blockingRule = organizer.blockingExclusionRule {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        appState.highlightedExclusionRuleID = blockingRule.id
                        appState.openRelatedView(.exclusions)
                    } label: {
                        HStack(spacing: 6) {
                            Image(
                                systemName: isHoveringViewExclusion
                                    ? "arrow.up.right"
                                    : "slider.horizontal.3"
                            )
                                .font(.system(size: 12, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                                .transaction { transaction in
                                    if reduceMotion {
                                        transaction.disablesAnimations = true
                                    }
                                }
                            Text("View Exclusion")
                                .font(.callout.weight(.semibold))
                        }
                    }
                    .buttonStyle(.tintedPill(.indigo))
                    .accessibilityIdentifier("AnalysisEmptyViewExclusionButton")
                    .onHover { hovering in
                        if hovering && !isHoveringViewExclusion {
                            HapticFeedbackManager.shared.selection()
                        }
                        withAnimation(
                            reduceMotion
                                ? nil
                                : .spring(response: 0.24, dampingFraction: 0.82)
                        ) {
                            isHoveringViewExclusion = hovering
                        }
                    }
                }

                Button {
                    HapticFeedbackManager.shared.tap()
                    presentReplacementDirectoryPicker()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Change Folder")
                            .font(.callout.weight(.semibold))
                    }
                }
                .buttonStyle(.tintedPill(.blue))
                .accessibilityIdentifier("AnalysisEmptyChooseFolderButton")
                .onHover { hovering in
                    if hovering && !isHoveringChangeFolder {
                        HapticFeedbackManager.shared.selection()
                    }
                    isHoveringChangeFolder = hovering
                }
            }
            .opacity(hasAppeared ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: hasAppeared)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("No files to \(settingsViewModel.config.mode.actionVerb.lowercased()): This folder is empty or all files were excluded.")
    }

    private var emptyDirectoryTitle: String {
        organizer.blockingExclusionRule == nil
            ? "No Files to \(settingsViewModel.config.mode.actionVerb)"
            : "This Folder Is Excluded"
    }

    private func presentReplacementDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = appState.selectedDirectory?.deletingLastPathComponent()
        panel.message = "Select a directory to \(settingsViewModel.config.mode.actionVerb.lowercased())"
        panel.prompt = "Select"

        guard panel.runModal() == .OK, let directory = panel.url else { return }

        recordCancelledAnalysis()
        withAnimation(.pageTransition) {
            organizer.reset()
            appState.selectedDirectory = directory
        }
        HapticFeedbackManager.shared.success()
    }

    private var emptyDirectoryMessage: String {
        guard let rule = organizer.blockingExclusionRule else {
            return "This folder is empty or all files were excluded by your exclusion rules. Try a different folder or adjust your exclusions."
        }
        return "\(rule.displayDescription) excludes this folder, so Sorty did not inspect or change anything inside it. You can review that exclusion or choose a different folder."
    }

    // MARK: - Analysis Action Buttons

    private var analysisActionButtons: some View {
        HStack(spacing: 12) {
            Button {
                HapticFeedbackManager.shared.tap()
                showCancelConfirmation = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Cancel")
                        .font(.caption.bold())
                }
            }
            .buttonStyle(.tintedPill(.red, size: .small))
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityIdentifier("AnalysisCancelButton")

            Button {
                HapticFeedbackManager.shared.tap()
                showFasterModelPicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Model")
                        .font(.caption.bold())
                }
            }
            .buttonStyle(.tintedPill(.indigo, size: .small))
            .accessibilityIdentifier("AnalysisModelButton")
            .modelSelectorTriggerBounds()
        }
        .opacity(hasAppeared ? 1 : 0)
        .animation(
            .spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: hasAppeared
        )
        .confirmationDialog(
            "Cancel Organization?",
            isPresented: $showCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel Generation", role: .destructive) {
                recordCancelledAnalysis()
                returnToStart()
            }
            Button("Continue", role: .cancel) {}
        } message: {
            Text(
                "This will stop Sorty's analysis and return to the start screen. Your progress will not be saved."
            )
        }
    }

    // MARK: - AI Insights View

    private var liveInsights: (current: String, history: [AIInsight]) {
        (organizer.currentInsight, organizer.insightHistory)
    }

    private var aiInsightsView: some View {
        InsightHistorySection(
            activity: insightIslandActivity,
            insights: liveInsights,
            debugModeEnabled: appState.debugMode,
            streamPreview: organizer.truncatedDisplayStreamingContent,
            liveInsightsEnabled: $liveInsightsEnabled,
            streamingModeEnabled: Binding(
                get: { settingsViewModel.config.enableStreaming },
                set: { newValue in
                    settingsViewModel.config.enableStreaming = newValue
                }
            )
        )
    }

    private func modelSwitchNotice(_ pendingModelSwitch: PendingModelSwitch) -> some View {
        InlineNotice(
            icon: "bolt.fill",
            title: "Switching to \(pendingModelSwitch.provider.displayName) / \(pendingModelSwitch.model)",
            message: "Stopping the current attempt and restarting analysis from the top. This model is now your active selection.",
            severity: .tip,
            isCentered: true
        )
    }

    private func recordCancelledAnalysis() {
        guard let directory = appState.selectedDirectory ?? organizer.currentDirectory else {
            return
        }

        let plan = organizer.currentPlan
        let fileCount = max(plan?.totalFiles ?? 0, organizer.scannedFileCount)
        let proposedFolderCount = plan?.totalFolders ?? 0
        let folderNames = plan?.suggestions.map { $0.folderName }

        learningsManager.recordCancelledOrganization(
            folderPath: directory.path,
            fileCount: fileCount,
            proposedFolderCount: proposedFolderCount,
            instructions: organizer.customInstructions.isEmpty ? nil : organizer.customInstructions,
            stage: organizer.organizationStage.isEmpty ? "analysis" : organizer.organizationStage,
            proposedFolderNames: (folderNames?.isEmpty == false) ? folderNames : nil,
            proposedStructureSummary: nil,
            fileExtensionCounts: nil,
            regenerationCount: plan?.version ?? 0,
            regenerationInstructions: nil,
            aiModel: settingsViewModel.config.model
        )
    }

    private func handleFasterModelSelection(provider: AIProvider, model: String) {
        showFasterModelPicker = false
        pendingModelSwitch = PendingModelSwitch(provider: provider, model: model, mode: settingsViewModel.config.mode)

        Task {
            do {
                settingsViewModel.config.provider = provider
                settingsViewModel.config.model = model
                try await organizer.configure(with: settingsViewModel.config)
                try await organizer.regenerateWithModel(provider: provider, model: model)
            } catch {
                await MainActor.run {
                    pendingModelSwitch = nil
                    organizer.state = .error(error)
                }
            }
        }
    }

    private func returnToStart() {
        if let onReturnToStart {
            onReturnToStart()
        } else {
            withAnimation(.smooth(duration: 0.34)) {
                organizer.reset()
            }
        }
    }

    private func refreshStreamDerivedState(force: Bool = false) {
        let streamText = organizer.displayStreamingContent
        let scannedFileIDs = organizer.scannedFiles.map(\.id)
        if streamPreviewState.scannedFileIDs != scannedFileIDs
            || streamPreviewState.organizeFileLookup.isEmpty && !organizer.scannedFiles.isEmpty {
            streamPreviewState.scannedFileIDs = scannedFileIDs
            streamPreviewState.organizeFileLookup = OrganizingStreamSuggestions.fileLookup(from: organizer.scannedFiles)
            streamPreviewState.renameFileLookup = RenameGenerationSequenceView.fileLookup(from: organizer.scannedFiles)
        }

        let streamReset = !streamText.hasPrefix(streamPreviewState.lastStreamText)
        let modeChanged = streamPreviewState.isRenameOnly != isRenameOnlyFlow
        let addedParseBoundary = streamText.last.map { "\"}],}\n,".contains($0) } ?? true
        streamPreviewState.lastStreamText = streamText
        streamPreviewState.isRenameOnly = isRenameOnlyFlow
        guard force || streamReset || modeChanged || isRenameOnlyFlow || addedParseBoundary else { return }

        if isRenameOnlyFlow {
            let events = RenameGenerationSequenceView.makeEvents(
                from: streamText,
                filesByName: streamPreviewState.renameFileLookup
            )
            if events != liveRenameStreamEvents {
                liveRenameStreamEvents = events
            }
            hasOrganizeStreamEvents = false
            if !liveOrganizingSuggestions.isEmpty {
                liveOrganizingSuggestions = []
            }
        } else {
            if !liveRenameStreamEvents.isEmpty {
                liveRenameStreamEvents = []
            }
            let suggestions = OrganizingStreamSuggestions.parse(
                from: streamText,
                filesByName: streamPreviewState.organizeFileLookup,
                fileIDTable: organizer.streamFileIDTable
            )
            if suggestions.isEmpty {
                // Between request batches the stream buffer clears, so parsed
                // suggestions momentarily vanish. Falling back to the insights
                // island here made the UI ping-pong organization -> insights ->
                // organization; keep the flight stage (with its last folders)
                // until the run actually ends.
                if hasOrganizeStreamEvents,
                   organizer.isStreaming || organizer.state == .organizing {
                    return
                }
                if !liveOrganizingSuggestions.isEmpty {
                    liveOrganizingSuggestions = []
                }
                hasOrganizeStreamEvents = false
            } else {
                let didStartLiveOrganization = !hasOrganizeStreamEvents
                if suggestions != liveOrganizingSuggestions {
                    liveOrganizingSuggestions = suggestions
                }
                hasOrganizeStreamEvents = true
                if didStartLiveOrganization {
                    onLiveOrganizationStarted?()
                }
            }
        }
    }
}

#if DEBUG
#Preview("Analysis View - Scanning") {
    AnalysisView()
        .environmentObject(
            {
                let organizer = FolderOrganizer()
                organizer.state = .scanning
                organizer.progress = 0.45
                organizer.organizationStage = "Scanning files..."
                organizer.elapsedTime = 3.5
                return organizer
            }()
        )
        .environmentObject(AppState.preview)
        .frame(width: 700, height: 500)
}

#Preview("Analysis View - Organizing") {
    AnalysisView()
        .environmentObject(
            {
                let organizer = FolderOrganizer()
                organizer.state = .organizing
                organizer.progress = 0.75
                organizer.organizationStage = "Analyzing with Sorty..."
                organizer.elapsedTime = 8.2
                organizer.isStreaming = true
                organizer.currentInsight = "Creating project folders based on file types"
                return organizer
            }()
        )
        .environmentObject(AppState.preview)
        .frame(width: 700, height: 550)
}

#Preview("Analysis View - Applying") {
    AnalysisView()
        .environmentObject(
            {
                let organizer = FolderOrganizer()
                organizer.state = .applying
                organizer.progress = 0.85
                organizer.organizationStage = "Moving files..."
                organizer.elapsedTime = 12.5
                return organizer
            }()
        )
        .environmentObject(AppState.preview)
        .frame(width: 700, height: 500)
}

#Preview("Analysis View - Long Running") {
    AnalysisView()
        .environmentObject(
            {
                let organizer = FolderOrganizer()
                organizer.state = .organizing
                organizer.progress = 0.65
                organizer.organizationStage = "Processing large folder..."
                organizer.elapsedTime = 65.0
                organizer.showTimeoutMessage = true
                organizer.isStreaming = true
                return organizer
            }()
        )
        .environmentObject(AppState.preview)
        .frame(width: 700, height: 550)
}

#endif
