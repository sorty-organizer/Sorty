//
//  AnalysisView.swift
//  Sorty
//
//  Real-time organization display with streaming progress
//

import Beam
import Combine
import SwiftUI
import UniformTypeIdentifiers

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
        let image = NSWorkspace.shared.icon(for: contentType).copy() as! NSImage
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
        let image = NSWorkspace.shared.icon(forFileType: normalizedExtension).copy() as! NSImage
        image.size = NSSize(width: 32, height: 32)
        cache.setObject(image, forKey: key as NSString, cost: imageCost(image))
        return image
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

        withAnimation(.easeInOut(duration: 0.55)) {
            funnyMessageOpacity = 0
        }

        try? await Task.sleep(nanoseconds: 520_000_000)
        guard organizer != nil else { return }

        let elapsedSeconds = Int(organizer?.elapsedTime ?? 0)
        if elapsedSeconds > 30 {
            currentFunnyMessage = calmerMessages.randomElement() ?? calmerMessages[0]
        } else {
            currentFunnyMessage = nextStatusMessage()
        }

        withAnimation(.easeInOut(duration: 0.65)) {
            funnyMessageOpacity = 1
        }
    }

    private func nextStatusMessage() -> String {
        funnyMessages.randomElement() ?? funnyMessages[0]
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
            withAnimation {
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

enum OrganizingStreamSuggestions {
    private static let maxParseCharacters = 30_000
    private static let maxVisibleFolders = 5
    private static let maxFilesPerFolder = 12
    // JSON string body: any escaped character or any character that is not a
    // quote or backslash. This correctly handles \\, \", \n, and \uXXXX.
    private static let folderNameRegex = try? NSRegularExpression(
        pattern: #""name"\s*:\s*"((?:\\.|[^"\\])*)""#,
        options: []
    )
    private static let filenameRegex = try? NSRegularExpression(
        pattern: #""filename"\s*:\s*"((?:\\.|[^"\\])*)""#,
        options: []
    )
    private static let suggestedNameRegex = try? NSRegularExpression(
        pattern: #""suggested_name"\s*:\s*"((?:\\.|[^"\\])*)""#,
        options: []
    )
    /// Preferred compact format: `"file_ids":[1,2,3]`. The closing bracket is
    /// optional so partially streamed arrays still parse.
    private static let fileIDsRegex = try? NSRegularExpression(
        pattern: #""file_ids"\s*:\s*\[([^\]]*)(\])?"#,
        options: []
    )
    /// Rename entries in the preferred compact format:
    /// `{"file_id":1,"suggested_name":"Clear Name.ext",...}`.
    private static let renamePairRegex = try? NSRegularExpression(
        pattern: #""file_id"\s*:\s*(\d+)[^{}]*?"suggested_name"\s*:\s*"((?:\\.|[^"\\])*)""#,
        options: []
    )
    /// Legacy organize-only format: `"files":["name.pdf","other.png"]`.
    /// The body excludes braces/brackets so object arrays never match here.
    private static let plainFilesArrayRegex = try? NSRegularExpression(
        pattern: #""files"\s*:\s*\[([^\[\]{}]*)"#,
        options: []
    )
    private static let quotedStringRegex = try? NSRegularExpression(
        pattern: #""((?:\\.|[^"\\])*)""#,
        options: []
    )

    static func parse(
        from streamText: String,
        files: [FileItem],
        fileIDTable: [Int: FileItem] = [:]
    ) -> [FolderSuggestion] {
        parse(from: streamText, filesByName: fileLookup(from: files), fileIDTable: fileIDTable)
    }

    static func parse(
        from streamText: String,
        filesByName: [String: FileItem],
        fileIDTable: [Int: FileItem] = [:]
    ) -> [FolderSuggestion] {
        guard let jsonStart = streamText.firstIndex(of: "{") else { return [] }

        let jsonText = boundedParseText(String(streamText[jsonStart...]))
        let nsText = jsonText as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let folderMatches = folderNameRegex?.matches(in: jsonText, range: fullRange) ?? []
        guard !folderMatches.isEmpty else { return [] }

        var suggestionsByFolder: [String: FolderSuggestion] = [:]
        var orderedFolderNames: [String] = []
        var assignedFileIDs: Set<UUID> = []
        // The folder currently being generated: its name is complete but no
        // file assignments have streamed in yet. Shown as a pending bucket so
        // the stage reflects what the model is doing right now.
        var pendingFolderName: String?

        for index in folderMatches.indices {
            let folderMatch = folderMatches[index]
            guard folderMatch.numberOfRanges > 1 else { continue }

            let folderNameRange = folderMatch.range(at: 1)
            guard folderNameRange.location != NSNotFound else { continue }

            let folderName = displayFolderName(
                decodeJSONString(nsText.substring(with: folderNameRange))
            )
            guard !folderName.isEmpty, folderName != "." else { continue }

            let segmentStart = folderMatch.range.location + folderMatch.range.length
            let segmentEnd = index + 1 < folderMatches.count
                ? folderMatches[index + 1].range.location
                : nsText.length
            guard segmentEnd > segmentStart else { continue }

            let segmentRange = NSRange(location: segmentStart, length: segmentEnd - segmentStart)
            let segment = nsText.substring(with: segmentRange)
            let isLastFolder = index == folderMatches.count - 1
            let mentionsFiles = segment.range(of: #""files""#, options: .caseInsensitive) != nil
                || segment.range(of: #""file_ids""#, options: .caseInsensitive) != nil
            guard mentionsFiles || isLastFolder else { continue }

            let parsedEntries = mentionsFiles
                ? parseFiles(from: segment, filesByName: filesByName, fileIDTable: fileIDTable)
                : []
            guard !parsedEntries.isEmpty else {
                if isLastFolder {
                    pendingFolderName = folderName
                }
                continue
            }

            if suggestionsByFolder[folderName] == nil {
                orderedFolderNames.append(folderName)
                suggestionsByFolder[folderName] = FolderSuggestion(folderName: folderName)
            }

            var suggestion = suggestionsByFolder[folderName] ?? FolderSuggestion(folderName: folderName)
            let existingIDs = Set(suggestion.files.map(\.id))
            let newEntries = parsedEntries.filter {
                !existingIDs.contains($0.file.id) && assignedFileIDs.insert($0.file.id).inserted
            }
            let remainingSlots = max(0, maxFilesPerFolder - suggestion.files.count)
            for entry in newEntries.prefix(remainingSlots) {
                suggestion.files.append(entry.file)
                if let suggestedName = entry.suggestedName, suggestedName != entry.file.displayName {
                    suggestion.fileRenameMappings.append(
                        FileRenameMapping(
                            originalFile: entry.file,
                            suggestedName: suggestedName
                        )
                    )
                }
            }
            suggestionsByFolder[folderName] = suggestion
        }

        var results = orderedFolderNames
            .compactMap { suggestionsByFolder[$0] }
            .filter { !$0.files.isEmpty }
        if let pendingFolderName,
           !results.contains(where: { $0.folderName == pendingFolderName }) {
            results.append(FolderSuggestion(folderName: pendingFolderName))
        }
        return Array(results.suffix(maxVisibleFolders))
    }

    private static func parseFiles(
        from segment: String,
        filesByName: [String: FileItem],
        fileIDTable: [Int: FileItem]
    ) -> [(file: FileItem, suggestedName: String?)] {
        var parsedFiles: [(file: FileItem, suggestedName: String?)] = []
        var seenIDs: Set<UUID> = []

        // Preferred compact format: resolve "file_ids":[1,2] through the
        // request's published ID table.
        if !fileIDTable.isEmpty {
            let renamesByID = renameSuggestionsByFileID(in: segment)
            for id in fileIDValues(in: segment) {
                guard let file = fileIDTable[id], seenIDs.insert(file.id).inserted else { continue }
                parsedFiles.append((file: file, suggestedName: renamesByID[id]))
            }
        }

        // Rename-capable legacy format: objects with "filename" fields.
        let segmentText = segment as NSString
        for object in fileObjectMatches(in: segment, segmentText: segmentText) {
            let filename = firstCapture(regex: filenameRegex, text: object)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !filename.isEmpty else { continue }

            let key = normalizedFileName(filename)
            guard let file = filesByName[key], seenIDs.insert(file.id).inserted else { continue }
            let suggestedName = firstCapture(regex: suggestedNameRegex, text: object)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            parsedFiles.append((file: file, suggestedName: suggestedName.isEmpty ? nil : suggestedName))
        }

        // Organize-only legacy format: "files":["name.pdf","other.png"].
        for filename in plainFileArrayNames(in: segment) {
            let key = normalizedFileName(filename)
            guard let file = filesByName[key], seenIDs.insert(file.id).inserted else { continue }
            parsedFiles.append((file: file, suggestedName: nil))
        }

        return parsedFiles
    }

    /// Extracts integer IDs from `"file_ids":[...]` arrays in the segment.
    /// While the array is still streaming (no closing bracket yet), a trailing
    /// number is dropped because more digits may follow.
    private static func fileIDValues(in segment: String) -> [Int] {
        guard let regex = fileIDsRegex else { return [] }
        let nsSegment = segment as NSString
        let matches = regex.matches(in: segment, range: NSRange(location: 0, length: nsSegment.length))

        var ids: [Int] = []
        for match in matches where match.numberOfRanges > 2 {
            let bodyRange = match.range(at: 1)
            guard bodyRange.location != NSNotFound else { continue }
            let body = nsSegment.substring(with: bodyRange)
            let isClosed = match.range(at: 2).location != NSNotFound && match.range(at: 2).length > 0

            var tokens = body
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if !isClosed, let last = body.unicodeScalars.last, CharacterSet.decimalDigits.contains(last) {
                tokens.removeLast()
            }
            ids.append(contentsOf: tokens.compactMap { Int($0) })
        }
        return ids
    }

    private static func renameSuggestionsByFileID(in segment: String) -> [Int: String] {
        guard let regex = renamePairRegex else { return [:] }
        let nsSegment = segment as NSString
        let matches = regex.matches(in: segment, range: NSRange(location: 0, length: nsSegment.length))

        var renames: [Int: String] = [:]
        for match in matches where match.numberOfRanges > 2 {
            let idRange = match.range(at: 1)
            let nameRange = match.range(at: 2)
            guard idRange.location != NSNotFound, nameRange.location != NSNotFound,
                  let id = Int(nsSegment.substring(with: idRange)) else { continue }
            let name = decodeJSONString(nsSegment.substring(with: nameRange))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                renames[id] = name
            }
        }
        return renames
    }

    /// Filenames from legacy plain-string arrays: `"files":["a.pdf","b.png"]`.
    /// Only complete quoted strings match, so partially streamed names are
    /// skipped until their closing quote arrives.
    private static func plainFileArrayNames(in segment: String) -> [String] {
        guard let arrayRegex = plainFilesArrayRegex, let stringRegex = quotedStringRegex else { return [] }
        let nsSegment = segment as NSString
        let arrayMatches = arrayRegex.matches(in: segment, range: NSRange(location: 0, length: nsSegment.length))

        var names: [String] = []
        for match in arrayMatches where match.numberOfRanges > 1 {
            let bodyRange = match.range(at: 1)
            guard bodyRange.location != NSNotFound else { continue }
            let body = nsSegment.substring(with: bodyRange)
            let nsBody = body as NSString
            let stringMatches = stringRegex.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
            for stringMatch in stringMatches where stringMatch.numberOfRanges > 1 {
                let nameRange = stringMatch.range(at: 1)
                guard nameRange.location != NSNotFound else { continue }
                let name = decodeJSONString(nsBody.substring(with: nameRange))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    names.append(name)
                }
            }
        }
        return names
    }

    private static func fileObjectMatches(in segment: String, segmentText: NSString) -> [String] {
        let objectPattern = #"\{[^{}]*"filename"\s*:\s*"((?:\\.|[^"\\])*)"[^{}]*\}"#
        if let objectRegex = try? NSRegularExpression(pattern: objectPattern, options: []) {
            let objectMatches = objectRegex.matches(
                in: segment,
                range: NSRange(location: 0, length: segmentText.length)
            )
            if !objectMatches.isEmpty {
                return objectMatches.map { segmentText.substring(with: $0.range) }
            }
        }

        let filenameMatches = filenameRegex?.matches(
            in: segment,
            range: NSRange(location: 0, length: segmentText.length)
        ) ?? []
        return filenameMatches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let filenameRange = match.range(at: 1)
            guard filenameRange.location != NSNotFound else { return nil }
            let filename = segmentText.substring(with: filenameRange)
            return #""filename":"\#(filename)""#
        }
    }

    private static func firstCapture(regex: NSRegularExpression?, text: String) -> String {
        guard let regex else { return "" }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
            return ""
        }
        let captureRange = match.range(at: 1)
        guard captureRange.location != NSNotFound else { return "" }
        return decodeJSONString(nsText.substring(with: captureRange))
    }

    private static func boundedParseText(_ text: String) -> String {
        guard text.count > maxParseCharacters else { return text }
        let start = text.index(text.endIndex, offsetBy: -maxParseCharacters)
        return String(text[start...])
    }

    fileprivate static func fileLookup(from files: [FileItem]) -> [String: FileItem] {
        var lookup: [String: FileItem] = [:]
        var ambiguousKeys: Set<String> = []
        lookup.reserveCapacity(files.count)
        for file in files {
            let keys = Set([
                normalizedFileName(file.displayName),
                normalizedFileName(file.path),
                normalizedFileName(file.name)
            ])
            for key in keys where !key.isEmpty {
                if let existing = lookup[key], existing.id != file.id {
                    // Two distinct files share a basename; drop the key rather
                    // than animating an arbitrary one of them.
                    ambiguousKeys.insert(key)
                } else {
                    lookup[key] = file
                }
            }
        }
        for key in ambiguousKeys {
            lookup.removeValue(forKey: key)
        }
        return lookup
    }

    private static func normalizedFileName(_ value: String) -> String {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))

        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        return lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func displayFolderName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("/") || trimmed.contains("\\") else { return trimmed }

        return trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? trimmed
    }

    private static func decodeJSONString(_ value: String) -> String {
        guard let data = "\"\(value)\"".data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data)
        else {
            return value
                .replacingOccurrences(of: #"\""#, with: #"""#)
                .replacingOccurrences(of: #"\\/"#, with: "/")
        }
        return decoded
    }
}

private struct RenameStreamEvent: Identifiable, Equatable {
    let id: String
    let originalName: String
    let suggestedName: String?
    let reason: String?
    let filePath: String?
    let isDirectory: Bool

    var isRevealed: Bool {
        suggestedName?.isEmpty == false
    }
}

private struct LiveStreamPreviewState {
    var scannedFileIDs: [UUID] = []
    var organizeFileLookup: [String: FileItem] = [:]
    var renameFileLookup: [String: FileItem] = [:]
    var lastStreamText = ""
    var isRenameOnly = false
}

private struct RenameGenerationSequenceView: View {
    @SortyHotReload private var hotReload
    let events: [RenameStreamEvent]
    @State private var shouldFollowLatest = true

    private static let maxVisibleRows = 5
    private static let maxParseCharacters = 12_000
    private static let estimatedRowHeight: CGFloat = 44
    private static let rowSpacing: CGFloat = 8
    private static let headerHeight: CGFloat = 20
    private static let sectionSpacing: CGFloat = 14
    private static let verticalPadding: CGFloat = 32
    private static let progressRegex = try? NSRegularExpression(
        pattern: #">>\s*file:\s*(?:renam(?:e|ing)\s+)?([^"\n]+?)(?:\s*(?:->|→)\s*([^"\n]+))?$"#,
        options: [.anchorsMatchLines, .caseInsensitive]
    )
    private static let objectRegex = try? NSRegularExpression(
        pattern: #"\{[^{}]*"filename"\s*:\s*"([^"]+)"[^{}]*\}"#,
        options: []
    )
    private static let filenameRegex = try? NSRegularExpression(
        pattern: #""filename"\s*:\s*"([^"]+)""#,
        options: []
    )
    private static let suggestedNameRegex = try? NSRegularExpression(
        pattern: #""suggested_name"\s*:\s*"([^"]+)""#,
        options: []
    )
    private static let renameReasonRegex = try? NSRegularExpression(
        pattern: #""rename_reason"\s*:\s*"([^"]+)""#,
        options: []
    )

    private var visibleRowCount: Int {
        events.count
    }

    private var rowStackHeight: CGFloat {
        guard visibleRowCount > 0 else { return 0 }
        return CGFloat(visibleRowCount) * Self.estimatedRowHeight
            + CGFloat(max(visibleRowCount - 1, 0)) * Self.rowSpacing
    }

    private var panelHeight: CGFloat {
        Self.headerHeight + Self.sectionSpacing + rowStackHeight + Self.verticalPadding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                renameIcon
                Text("Renaming files")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                            RenameGenerationRow(
                                originalName: event.originalName,
                                suggestedName: event.suggestedName,
                                filePath: event.filePath,
                                isDirectory: event.isDirectory,
                                isActive: activeEventID == event.id,
                                isRevealed: event.isRevealed,
                                isMostRecent: index == events.indices.last
                            )
                            .id(event.id)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                        }
                    }
                    .padding(.vertical, 1)
                }
                .onHover { hovering in
                    shouldFollowLatest = !hovering
                }
                .onChange(of: activeEventID) { _, id in
                    guard shouldFollowLatest, let id else { return }
                    withAnimation(.smooth(duration: 0.24)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            .frame(height: rowStackHeight)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: activeEventID)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: 720)
        .frame(height: panelHeight, alignment: .top)
        .systemLiquidGlassBackground(cornerRadius: 14, interactive: false)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: visibleRowCount)
    }

    @ViewBuilder
    private var renameIcon: some View {
        if #available(macOS 26.0, *) {
            Image(systemName: "pencil.and.scribble")
                .foregroundStyle(.purple)
                .symbolEffect(.drawOn, options: .repeating)
        } else {
            Image(systemName: "pencil.and.scribble")
                .foregroundStyle(.purple)
        }
    }

    private var activeEventID: String? {
        events.last?.id
    }

    static func makeEvents(from streamText: String, files: [FileItem]) -> [RenameStreamEvent] {
        makeEvents(from: streamText, filesByName: fileLookup(from: files))
    }

    static func makeEvents(from streamText: String, filesByName: [String: FileItem]) -> [RenameStreamEvent] {
        let parsed = Self.parseRenameEvents(from: streamText)
        let visibleEvents = Array(parsed.suffix(Self.maxVisibleRows))

        return visibleEvents.map { event in
            guard let file = filesByName[Self.normalizedFileName(event.originalName)] else {
                return event
            }
            return RenameStreamEvent(
                id: event.id,
                originalName: event.originalName,
                suggestedName: event.suggestedName,
                reason: event.reason,
                filePath: file.path,
                isDirectory: file.isDirectory
            )
        }
    }

    private static func parseRenameEvents(from streamText: String) -> [RenameStreamEvent] {
        var eventsByOriginal: [String: RenameStreamEvent] = [:]
        var orderedKeys: [String] = []
        let parseText: String

        if streamText.count > maxParseCharacters {
            let start = streamText.index(streamText.endIndex, offsetBy: -maxParseCharacters)
            parseText = String(streamText[start...])
        } else {
            parseText = streamText
        }

        func upsert(originalName: String, suggestedName: String?, reason: String? = nil) {
            let key = originalName.lowercased()
            if !orderedKeys.contains(key) {
                orderedKeys.append(key)
            }
            let existing = eventsByOriginal[key]
            eventsByOriginal[key] = RenameStreamEvent(
                id: key,
                originalName: originalName,
                suggestedName: suggestedName ?? existing?.suggestedName,
                reason: reason ?? existing?.reason,
                filePath: existing?.filePath,
                isDirectory: existing?.isDirectory ?? false
            )
        }

        for match in Self.matches(regex: progressRegex, text: parseText) {
            let original = (match.indices.contains(1) ? match[1] : "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suggested = (match.indices.contains(2) ? match[2] : "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty, !original.localizedCaseInsensitiveContains("ready to output") else { continue }
            upsert(originalName: original, suggestedName: suggested.isEmpty ? nil : suggested)
        }

        for match in Self.matches(regex: objectRegex, text: parseText) {
            let object = match.first ?? ""
            let original = Self.firstCapture(regex: filenameRegex, text: object)
            let suggested = Self.firstCapture(regex: suggestedNameRegex, text: object)
            let reason = Self.firstCapture(regex: renameReasonRegex, text: object)
            guard !original.isEmpty else { continue }
            upsert(originalName: original, suggestedName: suggested.isEmpty ? original : suggested, reason: reason)
        }

        return orderedKeys.compactMap { eventsByOriginal[$0] }
    }

    fileprivate static func fileLookup(from files: [FileItem]) -> [String: FileItem] {
        var lookup: [String: FileItem] = [:]
        lookup.reserveCapacity(files.count * 3)
        for file in files {
            for key in [
                normalizedFileName(file.displayName),
                normalizedFileName(file.path),
                normalizedFileName(file.name)
            ] where !key.isEmpty {
                lookup[key] = file
            }
        }
        return lookup
    }

    private static func normalizedFileName(_ value: String) -> String {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))

        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        return lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func matches(regex: NSRegularExpression?, text: String) -> [[String]] {
        guard let regex else { return [] }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, range: range).map { result in
            (0..<result.numberOfRanges).map { index in
                let range = result.range(at: index)
                guard range.location != NSNotFound else { return "" }
                return nsText.substring(with: range)
            }
        }
    }

    private static func firstCapture(regex: NSRegularExpression?, text: String) -> String {
        matches(regex: regex, text: text).first.flatMap {
            $0.indices.contains(1) ? $0[1] : nil
        } ?? ""
    }
}

private struct RenameGenerationRow: View {
    @SortyHotReload private var hotReload
    let originalName: String
    let suggestedName: String?
    let filePath: String?
    let isDirectory: Bool
    let isActive: Bool
    let isRevealed: Bool
    let isMostRecent: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var suggestedNameReveal = false

    var body: some View {
        let finalName = suggestedName ?? originalName
        let isUnchanged = isRevealed && finalName == originalName

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                RenameFileIcon(filePath: filePath, isDirectory: isDirectory, isUnchanged: isUnchanged)

                RenameNamePill(
                    text: originalName,
                    isPrimary: false,
                    isStruck: isRevealed && !isUnchanged,
                    isShimmering: isActive && !isRevealed
                )

                RenameShiftIndicator(isActive: isActive, isUnchanged: isUnchanged)

                RenameNamePill(
                    text: isRevealed ? finalName : "Waiting for suggested name...",
                    isPrimary: isRevealed,
                    isStruck: false,
                    showRevealSweep: suggestedNameReveal && isRevealed
                )
                .opacity(isRevealed ? (suggestedNameReveal ? 1 : 0) : 0.62)
                .blur(radius: reduceMotion ? 0 : (isRevealed ? (suggestedNameReveal ? 0 : 4) : 2))
                .offset(x: reduceMotion ? 0 : (suggestedNameReveal ? 0 : -8))
                .scaleEffect(isRevealed ? 1 : 0.985)
                .animation(.easeInOut(duration: 0.18), value: isRevealed)
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: suggestedNameReveal)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.purple.opacity(0.08) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isMostRecent && isRevealed ? Color.purple.opacity(0.24) : .clear, lineWidth: 1)
        )
        .compositingGroup()
        .onAppear {
            revealSuggestedNameIfNeeded()
        }
        .onChange(of: suggestedName) { _, _ in
            revealSuggestedNameIfNeeded()
        }
        .onChange(of: isRevealed) { _, _ in
            revealSuggestedNameIfNeeded()
        }
    }

    private func revealSuggestedNameIfNeeded() {
        guard isRevealed else {
            suggestedNameReveal = false
            return
        }
        guard !reduceMotion else {
            suggestedNameReveal = true
            return
        }

        suggestedNameReveal = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                suggestedNameReveal = true
            }
        }
    }
}

private struct RenameNamePill: View {
    @SortyHotReload private var hotReload
    let text: String
    let isPrimary: Bool
    let isStruck: Bool
    var isShimmering = false
    var showRevealSweep = false

    var body: some View {
        Text(text)
            .font(.caption.weight(isPrimary ? .semibold : .regular))
            .foregroundStyle(isPrimary ? Color.purple : Color.secondary)
            .lineLimit(1)
            .strikethrough(isStruck, color: .secondary)
            .numericTextTransition(
                animationValue: text,
                animation: .easeInOut(duration: 0.28)
            )
            .textShimmer(isLoading: isShimmering, phaseOffset: 0.12, intensity: 1.18)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isPrimary ? Color.purple.opacity(0.08) : Color.secondary.opacity(0.06))
            )
            .overlay(alignment: .leading) {
                if showRevealSweep {
                    RenameGenerationRevealSweep()
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct RenameGenerationRevealSweep: View {
    @SortyHotReload private var hotReload
    @State private var progress: CGFloat = -0.35

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)

            LinearGradient(
                colors: [
                    .clear,
                    .white.opacity(0.22),
                    Color.purple.opacity(0.17),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: max(width * 0.26, 22), height: geometry.size.height * 1.8)
            .blur(radius: 2.2)
            .offset(x: width * progress)
            .blendMode(.plusLighter)
            .onAppear {
                progress = -0.35
                withAnimation(.easeOut(duration: 0.58)) {
                    progress = 1.12
                }
            }
        }
        .clipped()
    }
}

private struct RenameFileIcon: View {
    @SortyHotReload private var hotReload
    let filePath: String?
    let isDirectory: Bool
    let isUnchanged: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let filePath {
                let url = URL(fileURLWithPath: filePath)
                if isDirectory {
                    FolderThumbnailView(url: url, size: CGSize(width: 22, height: 22))
                } else {
                    FileThumbnailView(url: url, size: CGSize(width: 22, height: 22))
                }
            } else {
                AppKitImageView(
                    image: AnalysisIconProvider.icon(for: .data),
                    size: CGSize(width: 22, height: 22),
                    opacity: 0.72
                )
                .frame(width: 22, height: 22)
            }

            Image(systemName: isUnchanged ? "equal.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isUnchanged ? Color.secondary : Color.green)
                .symbolReplaceTransition(animationValue: isUnchanged)
                .background(Circle().fill(Color(NSColor.windowBackgroundColor)))
                .offset(x: 3, y: 3)
        }
        .frame(width: 28, height: 24)
    }
}

private struct RenameShiftIndicator: View {
    @SortyHotReload private var hotReload
    let isActive: Bool
    let isUnchanged: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(Color.secondary.opacity(0.16))
                .frame(width: 16, height: 2)

            Image(systemName: isUnchanged ? "equal" : "arrow.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isUnchanged ? Color.secondary : Color.purple)
                .symbolReplaceTransition(animationValue: isUnchanged)
                .scaleEffect(isActive && pulse ? 1.12 : 1)

            Capsule()
                .fill((isUnchanged ? Color.secondary : Color.purple).opacity(0.18))
                .frame(width: 16, height: 2)
        }
        .frame(width: 56)
        .onAppear {
            guard isActive, !reduceMotion else { return }
            withAnimation(.smooth(duration: 0.5).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onChange(of: isActive) { _, active in
            if active, !reduceMotion {
                withAnimation(.smooth(duration: 0.5).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                withAnimation(.smooth(duration: 0.2)) {
                    pulse = false
                }
            }
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            guard shouldReduceMotion else { return }
            withAnimation(nil) {
                pulse = false
            }
        }
    }
}

/// Mid-organization progress card using Beam's reference playground samples.
private struct StreamingProgressBeam: View {
    @SortyHotReload private var hotReload
    let measuredProgress: MeasuredWorkProgress?
    let overallProgress: Double
    let stage: String
    let elapsedSeconds: Int
    let isEstablishingConnection: Bool
    let state: OrganizationState
    /// When true, the card expands to align with the live insights island below it.
    var matchesInsightsWidth: Bool = false

    @Environment(\.controlActiveState) private var controlActiveState

    /// Compact width used when the banner stands alone (removes empty space).
    private static let collapsedWidth: CGFloat = 440
    /// Width of the live insights island the banner expands to meet.
    private static let expandedWidth: CGFloat = 550
    private var targetWidth: CGFloat {
        matchesInsightsWidth ? Self.expandedWidth : Self.collapsedWidth
    }

    private var isAnimationActive: Bool {
        controlActiveState != .inactive
    }

    private var percent: Int {
        Int((min(max(overallProgress, 0), 1) * 100).rounded())
    }

    private var milestone: Int {
        min(percent / 25, 4)
    }

    private var progressAccessibilityValue: String {
        guard showsDeterminateProgress else {
            return "In progress, stage \(displayedStage)"
        }
        guard let measuredProgress else {
            return "\(percent) percent complete, stage \(displayedStage)"
        }
        return "\(percent) percent, \(measuredProgress.completed) of \(measuredProgress.total) complete, stage \(displayedStage)"
    }

    private var showsDeterminateProgress: Bool {
        if measuredProgress != nil { return true }
        switch state {
        case .ready, .applying, .completed:
            return true
        case .idle, .scanning, .organizing, .error:
            return false
        }
    }

    private var displayedStage: String {
        let trimmed = stage.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return isEstablishingConnection ? "Establishing connection..." : "Working..."
        }
        if case .applying = state {
            return Self.applyingDisplayStage(from: trimmed)
        }
        return trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            progressCard
        }
        .frame(width: targetWidth)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: matchesInsightsWidth)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Organization progress")
        .accessibilityValue(progressAccessibilityValue)
        .accessibilityIdentifier("AnalysisPercentageText")
    }

    // MARK: - Progress card

    private var progressCard: some View {
        ZStack {
            HStack(alignment: .center, spacing: 10) {
                Text(displayedStage)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .numericTextTransition(
                        animationValue: displayedStage,
                        animation: .easeInOut(duration: 0.28)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showsDeterminateProgress {
                    Text("\(percent)%")
                        .monospacedDigit()
                        .numericTextTransition(
                            animationValue: percent,
                            animation: .easeInOut(duration: 0.3)
                        )
                        .milestoneEmptyStateSliver(trigger: milestone)
                        .frame(width: 54, alignment: .trailing)
                } else {
                    MinsangGlassLoader(
                        textChangeTrigger: displayedStage,
                        size: 54,
                        isActive: isAnimationActive
                    )
                        .frame(width: 54, alignment: .trailing)
                }
            }
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .background {
            beamSurface
        }
    }

    private var beamSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.clear)
                .systemLiquidGlassBackground(cornerRadius: 16, interactive: false)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
        .beam(
            .medium,
            palette: .colorful,
            theme: .dark,
            active: isAnimationActive,
            cornerRadius: 16,
            strength: 1.0
        )
        .referenceBeamFallback(cornerRadius: 16, active: true, includesInteriorGlow: true)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func applyingDisplayStage(from stage: String) -> String {
        let lowercased = stage.lowercased()
        if lowercased.hasPrefix("renaming ") || lowercased.hasPrefix("organizing ") {
            return stage
        }
        if lowercased.hasPrefix("moving ") {
            let filename = String(stage.dropFirst("Moving ".count))
            return "Organizing \(filename)"
        }
        if lowercased.hasPrefix("applying changes") {
            return "Organizing files..."
        }
        return stage
    }
}

private extension View {
    func referenceBeamFallback(
        cornerRadius: CGFloat,
        active: Bool,
        includesInteriorGlow: Bool = false
    ) -> some View {
        overlay {
            ReferenceBeamFallback(
                cornerRadius: cornerRadius,
                active: active,
                includesInteriorGlow: includesInteriorGlow
            )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct ReferenceBeamFallback: View {
    @SortyHotReload private var hotReload
    let cornerRadius: CGFloat
    let active: Bool
    let includesInteriorGlow: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    private var shouldAnimate: Bool {
        active && !reduceMotion && controlActiveState != .inactive
    }

    var body: some View {
        SwiftUI.TimelineView(
            .animation(minimumInterval: 1.0 / 20.0, paused: !shouldAnimate)
        ) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = shouldAnimate ? time / 1.96 : 0
            ZStack {
                if includesInteriorGlow {
                    beamInteriorGlow(phase: phase)
                }

                beamStroke(phase: phase)
            }
            .opacity(active ? 0.82 : 0)
            .animation(.easeOut(duration: 0.6), value: active)
        }
    }

    private func beamStroke(phase: TimeInterval) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: .clear, location: 0.08),
                        .init(color: Color(red: 0.08, green: 0.80, blue: 1.0).opacity(0.36), location: 0.16),
                        .init(color: Color(red: 0.92, green: 0.16, blue: 0.58).opacity(0.62), location: 0.25),
                        .init(color: .white.opacity(0.88), location: 0.32),
                        .init(color: Color(red: 1.0, green: 0.34, blue: 0.18).opacity(0.54), location: 0.39),
                        .init(color: Color(red: 0.40, green: 0.20, blue: 1.0).opacity(0.36), location: 0.48),
                        .init(color: .clear, location: 0.58),
                        .init(color: .clear, location: 1.00),
                    ],
                    center: .center,
                    angle: .degrees((phase.truncatingRemainder(dividingBy: 1)) * 360)
                ),
                lineWidth: 1
            )
    }

    private func beamInteriorGlow(phase: TimeInterval) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .inset(by: 3)
            .fill(
                AngularGradient(
                    stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: Color(red: 0.08, green: 0.80, blue: 1.0).opacity(0.10), location: 0.15),
                        .init(color: Color(red: 0.92, green: 0.16, blue: 0.58).opacity(0.20), location: 0.25),
                        .init(color: .white.opacity(0.16), location: 0.32),
                        .init(color: Color(red: 1.0, green: 0.34, blue: 0.18).opacity(0.14), location: 0.40),
                        .init(color: .clear, location: 0.58),
                        .init(color: .clear, location: 1.00),
                    ],
                    center: .center,
                    angle: .degrees((phase.truncatingRemainder(dividingBy: 1)) * 360)
                )
            )
            .blur(radius: 9)
            .mask {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(lineWidth: 22)
                    .blur(radius: 7)
            }
    }
}

private struct AIReasoningStatus: View {
    @SortyHotReload private var hotReload
    let state: OrganizationState
    let organizationStage: String
    let isStreaming: Bool
    let isEstablishingConnection: Bool
    let isRenameOnly: Bool
    let funnyMessage: String
    let funnyMessageOpacity: Double

    private var isAnalyzingStage: Bool {
        let stage = organizationStage.lowercased()
        return stage.contains("analyz") || stage.contains("analys")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            stageIcon
                .font(.system(size: 24))

            VStack(alignment: .leading, spacing: 2) {
                if isEstablishingConnection {
                    HStack(spacing: 6) {
                        Text(organizationStage)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .numericTextTransition(
                                animationValue: organizationStage,
                                animation: .easeInOut(duration: 0.28)
                            )
                            .textShimmer(isLoading: true, phaseOffset: 0.34, intensity: 1.65)

                        LoadingDotsView(dotCount: 3, dotSize: 5, color: .primary)
                    }
                    .transition(.opacity.animation(.spring(response: 0.4, dampingFraction: 0.85)))
                } else {
                    Text(organizationStage)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .numericTextTransition(
                            animationValue: organizationStage,
                            animation: .easeInOut(duration: 0.28)
                        )
                        .textShimmer(isLoading: isAnalyzingStage, phaseOffset: 0.08, intensity: 1.55)
                }

                if !isEstablishingConnection && isStreaming {
                    Text(isRenameOnly ? renameStatusMessage : funnyMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .numericTextTransition(
                            animationValue: isRenameOnly ? renameStatusMessage : funnyMessage,
                            animation: .easeInOut(duration: 0.28)
                        )
                        .textShimmer(isLoading: true, phaseOffset: 0.62, intensity: 1.65)
                        .opacity(funnyMessageOpacity)
                        .offset(y: funnyMessageOpacity > 0.5 ? 0 : 1)
                        .blur(radius: funnyMessageOpacity > 0.5 ? 0 : 0.3)
                        .animation(.easeInOut(duration: 0.6), value: funnyMessageOpacity)
                        .transition(
                            .opacity.animation(.spring(response: 0.4, dampingFraction: 0.85)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current \(isRenameOnly ? "rename" : "organization") stage: \(organizationStage)")
        .accessibilityIdentifier("AnalysisStageInfo")
    }

    private var renameStatusMessage: String {
        if organizationStage.localizedCaseInsensitiveContains("model")
            || organizationStage.localizedCaseInsensitiveContains("provider") {
            return "Asking the model for better names..."
        }
        return "Preparing filename suggestions..."
    }

    @ViewBuilder
    private var stageIcon: some View {
        if case .scanning = state {
            Image(systemName: isRenameOnly ? "text.cursor" : "folder.badge.gearshape")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .symbolReplaceTransition(animationValue: isRenameOnly)
                .accessibilityLabel(isRenameOnly ? "Preparing names" : "Scanning files")
        } else if case .organizing = state {
            if isEstablishingConnection {
                Image(systemName: "network")
                    .foregroundStyle(.orange)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            } else {
                Image(systemName: isRenameOnly ? "textformat" : "sparkles")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .symbolReplaceTransition(animationValue: isRenameOnly)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .accessibilityLabel(isRenameOnly ? "Renaming files" : "Organizing files")
            }
        } else if case .applying = state {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.green)
                .accessibilityLabel("Applying changes")
        }
    }
}

@MainActor
final class AnalysisInsightViewState: ObservableObject {
    @Published var showDebugStream = false
    @Published var isExpanded = true
}

private struct InsightHistorySection: View {
    @SortyHotReload private var hotReload
    let activity: AIAnalysisActivity
    let insights: (current: String, history: [AIInsight])
    let debugModeEnabled: Bool
    let streamPreview: String
    @Binding var liveInsightsEnabled: Bool
    @Binding var streamingModeEnabled: Bool

    @StateObject private var viewState = AnalysisInsightViewState()
    @State private var showPrivacyWarning = false
    @AppStorage("analysis.hideLiveInsightsPrivacyWarning") private var hidePrivacyWarning = false

    private var displayedStreamPreview: String {
        FeatureFlags.privacyModeEnabled
            ? PrivacyPathMasker.redactedText(streamPreview) : streamPreview
    }

    private var isActive: Bool { activity != .none }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewState.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if isActive {
                        Image(systemName: "waveform")
                            .font(.callout)
                            .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                            .symbolEffect(.breathe, options: .repeating)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }

                    Text(headerTitle)
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .numericTextTransition(
                            animationValue: headerTitle,
                            animation: .easeInOut(duration: 0.28)
                        )

                    Spacer()

                    let insightCount = insights.history.count
                    if insightCount > 0 {
                        Text("\(insightCount)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .numericTextTransition(animationValue: insightCount)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(SortyDesignSystem.Colors.resolvedAccent))
                    }

                    if FeatureFlags.privacyModeEnabled && !hidePrivacyWarning {
                        Button {
                            showPrivacyWarning.toggle()
                        } label: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Privacy warning for live AI insights")
                        .accessibilityIdentifier("LiveInsightsPrivacyWarningButton")
                        .popover(isPresented: $showPrivacyWarning, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text("Privacy Warning")
                                        .font(.headline)

                                    Spacer()

                                    Button {
                                        hidePrivacyWarning = true
                                        showPrivacyWarning = false
                                    } label: {
                                        Image(systemName: "xmark")
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                                    .accessibilityLabel("Dismiss privacy warning")
                                    .accessibilityIdentifier("DismissLiveInsightsPrivacyWarningButton")
                                }

                                Text(
                                    "Sorty masks username path segments in streamed text, but model-generated names can still appear before full parsing."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                                Button("Never show again") {
                                    hidePrivacyWarning = true
                                    showPrivacyWarning = false
                                }
                                .accessibilityIdentifier("HideLiveInsightsPrivacyWarningButton")
                            }
                            .padding(12)
                            .frame(width: 280)
                            .systemLiquidGlassPopover(cornerRadius: 12)
                        }
                    }

                    if debugModeEnabled {
                        Button {
                            withAnimation(.spring()) {
                                viewState.showDebugStream.toggle()
                            }
                        } label: {
                            Image(
                                systemName: viewState.showDebugStream ? "terminal.fill" : "terminal"
                            )
                            .font(.caption)
                            .foregroundStyle(
                                viewState.showDebugStream ? SortyDesignSystem.Colors.resolvedAccent : .secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!liveInsightsEnabled)
                        .opacity(liveInsightsEnabled ? 1 : 0.45)
                        .help(
                            liveInsightsEnabled
                                ? "Toggle Streaming Mode preview"
                                : "Enable Live Insights to preview Streaming Mode output")
                    }

                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(viewState.isExpanded ? 0 : -90))
                        .animation(
                            .spring(response: 0.3, dampingFraction: 0.8),
                            value: viewState.isExpanded)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: viewState.isExpanded ? 0 : 16)
                        .fill(
                            LinearGradient(
                                colors: [
                                    SortyDesignSystem.Colors.resolvedAccent.opacity(0.08),
                                    SortyDesignSystem.Colors.resolvedAccent.opacity(0.03),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: viewState.isExpanded ? 0 : 16))

            if viewState.isExpanded {
                LazyVStack(spacing: 14) {
                    liveInsightsPrimaryContent

                    if streamingModeEnabled && liveInsightsEnabled && viewState.showDebugStream
                        && debugModeEnabled
                    {
                        streamingPreview
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: 550)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(NSColor.separatorColor).opacity(0.8), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onChange(of: liveInsightsEnabled) { _, enabled in
            if !enabled {
                viewState.showDebugStream = false
            }
        }
        .onChange(of: streamingModeEnabled) { _, enabled in
            if !enabled {
                streamingModeEnabled = true
                viewState.showDebugStream = false
            } else if isActive && !liveInsightsEnabled {
                liveInsightsEnabled = true
            }
        }
    }

    private var headerTitle: String {
        switch activity {
        case .none: return "Analysis complete"
        case .preparingImages: return "Preparing images..."
        case .requesting: return "Sorty is reasoning..."
        case .validating: return "Finishing up..."
        }
    }

    private var loaderLabel: String {
        switch activity {
        case .preparingImages: return "Preparing images for analysis..."
        case .validating: return "Checking suggestions..."
        case .none, .requesting: return "Receiving AI response..."
        }
    }

    @ViewBuilder
    private var liveInsightsPrimaryContent: some View {
        let currentInsightItem = insights.history.last(where: { $0.text == insights.current })
        if !streamingModeEnabled {
            receivingResponseView
        } else if liveInsightsEnabled, !insights.current.isEmpty {
            currentInsightPill(
                insight: insights.current,
                detail: currentInsightItem,
                fallbackCategory: currentInsightItem?.category
            )
        } else if liveInsightsEnabled, let fallbackInsight = streamFallbackInsight {
            currentInsightPill(
                insight: fallbackInsight,
                detail: nil,
                fallbackCategory: inferredInsightCategory(for: fallbackInsight)
            )
        } else if isActive {
            receivingResponseView
        }

        if streamingModeEnabled && liveInsightsEnabled && insights.history.count > 1 {
            insightHistoryScroller(
                entries: Array(insights.history.dropLast().reversed()),
                markFirstAsLatest: false
            )
        }
    }

    private var receivingResponseView: some View {
        HStack(spacing: 12) {
            ThinkingOrbLoaderView()
                .frame(width: 36, height: 36)

            Text(loaderLabel)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .textSweep()

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(SortyDesignSystem.Colors.resolvedAccent.opacity(0.05))
                .overlay(
                    Capsule()
                        .stroke(SortyDesignSystem.Colors.resolvedAccent.opacity(0.15), lineWidth: 1)
                )
        )
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var streamFallbackInsight: String? {
        let content =
            displayedStreamPreview
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }

        if let assignment = extractJSONAssignmentSnippet(from: content) {
            return assignment
        }

        let plainLine =
            content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reversed()
            .first { line in
                let lower = line.lowercased()
                return line.count >= 12 && !line.contains("{") && !line.contains("}")
                    && !lower.hasPrefix("\"folders\"") && !lower.hasPrefix("\"files\"")
            }

        guard let plainLine else { return nil }
        return plainLine.count > 90 ? String(plainLine.prefix(90)) + "..." : plainLine
    }

    private func extractJSONAssignmentSnippet(from text: String) -> String? {
        let folderPattern = #""name"\s*:\s*"([^"\n]{2,80})""#
        let filePattern = #""([^"\n]{2,140}\.[a-zA-Z0-9]{1,12})""#

        guard
            let folderRegex = try? NSRegularExpression(
                pattern: folderPattern, options: [.caseInsensitive]),
            let fileRegex = try? NSRegularExpression(pattern: filePattern, options: [])
        else {
            return nil
        }

        let folderMatches = folderRegex.matches(
            in: text, options: [], range: NSRange(text.startIndex..., in: text))
        let fileMatches = fileRegex.matches(
            in: text, options: [], range: NSRange(text.startIndex..., in: text))

        guard let folderMatch = folderMatches.last,
            let folderRange = Range(folderMatch.range(at: 1), in: text)
        else {
            return nil
        }

        let folderName = String(text[folderRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLikelyInsightFolderName(folderName) else { return nil }

        if let fileMatch = fileMatches.last,
            let fileRange = Range(fileMatch.range(at: 1), in: text)
        {
            let fileName = URL(fileURLWithPath: String(text[fileRange])).lastPathComponent
            if isLikelyFileName(fileName) {
                return "Assigning \(fileName) to \(folderName)"
            }
        }

        return "Preparing folder \(folderName)"
    }

    private func isLikelyInsightFolderName(_ candidate: String) -> Bool {
        let normalized =
            candidate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?"))
            .lowercased()
        guard normalized.count >= 2, normalized.count <= 80 else { return false }
        guard !normalized.contains("{"), !normalized.contains("}"), !normalized.contains("/") else {
            return false
        }
        guard URL(fileURLWithPath: normalized).pathExtension.isEmpty else { return false }

        let blocked: Set<String> = [
            "a", "an", "and", "as", "at", "by", "for", "from", "gets", "in", "is", "it",
            "name", "of", "on", "or", "that", "the", "this", "to", "with", "folder",
            "folders", "file", "files", "filename", "json", "reasoning", "notes",
            "description", "content", "data", "true", "false", "null",
        ]
        return !blocked.contains(normalized)
    }

    private func isLikelyFileName(_ candidate: String) -> Bool {
        let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 3, normalized.count <= 220 else { return false }
        let ext = URL(fileURLWithPath: normalized).pathExtension
        return !ext.isEmpty
    }

    private func inferredInsightCategory(for text: String) -> AIInsight.Category {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("file:") || mentionedFileExtension(in: text) != nil {
            return .file
        }
        if trimmed.hasPrefix("folder:") || mentionsFolderContext(in: text) {
            return .folder
        }
        if trimmed.hasPrefix("pattern:") { return .pattern }
        if trimmed.hasPrefix("decision:") { return .decision }
        if trimmed.hasPrefix("constraint:") { return .constraint }
        return .general
    }

    private func currentInsightPill(
        insight: String, detail: AIInsight?, fallbackCategory: AIInsight.Category?
    ) -> some View {
        let displayInsight =
            FeatureFlags.privacyModeEnabled ? PrivacyPathMasker.redactedText(insight) : insight

        return HStack(spacing: 12) {
            insightIcon(for: detail, fallbackText: insight, fallbackCategory: fallbackCategory)
                .frame(width: 24, height: 24)

            Text(displayInsight)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .numericTextTransition(
                    animationValue: displayInsight,
                    animation: .easeInOut(duration: 0.28)
                )

            Spacer()

            if isActive {
                Circle()
                    .fill(SortyDesignSystem.Colors.resolvedAccent.opacity(0.4))
                    .frame(width: 6, height: 6)
                    .scaleEffect(isActive ? 1.3 : 1.0)
                    .animation(.default.speed(0.8), value: isActive)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(SortyDesignSystem.Colors.resolvedAccent.opacity(0.08))
                .overlay(
                    Capsule()
                        .stroke(SortyDesignSystem.Colors.resolvedAccent.opacity(0.15), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func insightIcon(
        for insight: AIInsight?, fallbackText: String, fallbackCategory: AIInsight.Category?
    ) -> some View {
        if let filePath = insight?.filePath {
            let url = URL(fileURLWithPath: filePath)
            if url.hasDirectoryPath {
                FolderThumbnailView(url: url, size: CGSize(width: 20, height: 20))
            } else {
                FileThumbnailView(url: url, size: CGSize(width: 20, height: 20))
            }
        } else if let category = insight?.category ?? fallbackCategory {
            if category == .folder {
                AppKitImageView(
                    image: AnalysisIconProvider.icon(for: .folder),
                    size: CGSize(width: 20, height: 20)
                )
                .frame(width: 20, height: 20)
            } else if category == .file {
                if let ext = mentionedFileExtension(in: fallbackText), !ext.isEmpty {
                    AppKitImageView(
                        image: AnalysisIconProvider.icon(forFileExtension: ext),
                        size: CGSize(width: 20, height: 20)
                    )
                    .frame(width: 20, height: 20)
                } else {
                    AppKitImageView(
                        image: AnalysisIconProvider.icon(for: .data),
                        size: CGSize(width: 20, height: 20)
                    )
                    .frame(width: 20, height: 20)
                }
            } else {
                categoryIndicator(for: category)
            }
        } else if let ext = mentionedFileExtension(in: fallbackText), !ext.isEmpty {
            AppKitImageView(
                image: AnalysisIconProvider.icon(forFileExtension: ext),
                size: CGSize(width: 20, height: 20)
            )
            .frame(width: 20, height: 20)
        } else if mentionsFolderContext(in: fallbackText) {
            AppKitImageView(
                image: AnalysisIconProvider.icon(for: .folder),
                size: CGSize(width: 20, height: 20)
            )
            .frame(width: 20, height: 20)
        } else {
            categoryIndicator(for: .general)
        }
    }

    @ViewBuilder
    private func categoryIndicator(for category: AIInsight.Category) -> some View {
        Circle()
            .fill(categoryColor(for: category).opacity(0.28))
            .overlay(
                Circle()
                    .stroke(categoryColor(for: category).opacity(0.55), lineWidth: 1)
            )
            .frame(width: 10, height: 10)
            .padding(6)
    }

    private func categoryColor(for category: AIInsight.Category) -> Color {
        switch category {
        case .file: return .blue
        case .folder: return .orange
        case .constraint: return .yellow
        case .decision: return .green
        case .pattern: return .purple
        case .general: return .secondary
        }
    }

    private func mentionedFileExtension(in text: String) -> String? {
        let pattern = #"(?:\"|')?([A-Za-z0-9_\-\(\) ]+\.([A-Za-z0-9]{1,12}))(?:\"|')?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
            let match = regex.matches(
                in: text, options: [], range: NSRange(text.startIndex..., in: text)
            ).last,
            let extRange = Range(match.range(at: 2), in: text)
        else {
            return nil
        }
        let ext = String(text[extRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ext.isEmpty ? nil : ext
    }

    private func mentionsFolderContext(in text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("folder") || lowered.contains("directory") {
            return true
        }
        return mentionedFileExtension(in: text) != nil && lowered.contains(" to ")
    }

    private func insightHistoryScroller(entries: [AIInsight], markFirstAsLatest: Bool) -> some View
    {
        ScrollView {
            FlowLayout(spacing: 6) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, insight in
                    HStack(spacing: 4) {
                        InsightPill(insight: insight)

                        if markFirstAsLatest, index == 0 {
                            Text("Latest")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(SortyDesignSystem.Colors.resolvedAccent.opacity(0.14))
                                )
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 170)
        .scrollIndicators(.visible)
        .accessibilityIdentifier("LiveInsightsHistoryScroll")
    }

    private var streamingPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.word.spacing")
                    .foregroundStyle(.purple)
                Text("AI Response")
                    .fontWeight(.medium)
            }
            .font(.caption)

            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(displayedStreamPreview)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                            .id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: streamPreview) { _, _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .frame(maxWidth: 550, maxHeight: 180)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
        )
        .accessibilityLabel(
            FeatureFlags.privacyModeEnabled
                ? "AI response preview hidden in Privacy Mode" : "AI response preview")
    }

}

// MARK: - Inline Notice

struct InlineNoticeAction {
    let title: String
    let systemImage: String?
    let action: () -> Void

    init(title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }
}

enum NoticeSeverity {
    case info
    case warning
    case tip

    var color: Color {
        switch self {
        case .info: return .blue
        case .warning: return .orange
        case .tip: return .green
        }
    }

    var defaultIcon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .tip: return "lightbulb.fill"
        }
    }
}

struct InlineNotice: View {
    @SortyHotReload private var hotReload
    let icon: String?
    let title: String
    let message: String?
    let severity: NoticeSeverity
    var actions: [InlineNoticeAction]
    var isCentered: Bool

    init(
        icon: String? = nil,
        title: String,
        message: String? = nil,
        severity: NoticeSeverity = .info,
        actions: [InlineNoticeAction] = [],
        isCentered: Bool = false
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.severity = severity
        self.actions = actions
        self.isCentered = isCentered
    }

    private var effectiveIcon: String {
        icon ?? severity.defaultIcon
    }

    var body: some View {
        VStack(alignment: isCentered ? .center : .leading, spacing: 6) {
            InlineNoticeHeader(
                icon: effectiveIcon,
                title: title,
                color: severity.color,
                isCentered: isCentered
            )

            if let message = message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(isCentered ? .center : .leading)
                    .padding(.leading, isCentered ? 0 : 20)
            }

            if !actions.isEmpty {
                InlineNoticeActions(
                    actions: actions,
                    color: severity.color,
                    isCentered: isCentered
                )
                .padding(.leading, isCentered ? 0 : 20)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: isCentered ? .center : .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(severity.color.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(severity.color.opacity(0.15), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityHint(message ?? "")
    }
}

private struct InlineNoticeHeader: View {
    @SortyHotReload private var hotReload
    let icon: String
    let title: String
    let color: Color
    let isCentered: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isCentered {
                Spacer(minLength: 0)
            }

            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .accessibilityHidden(true)

            Text(LocalizedStringKey(title))
                .font(.caption)
                .fontWeight(.semibold)

            Spacer(minLength: 0)
        }
    }
}

private struct InlineNoticeActions: View {
    @SortyHotReload private var hotReload
    let actions: [InlineNoticeAction]
    let color: Color
    let isCentered: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isCentered {
                Spacer(minLength: 0)
            }

            ForEach(actions.indices, id: \.self) { index in
                InlineNoticeActionButton(action: actions[index], color: color)
            }

            if isCentered {
                Spacer(minLength: 0)
            }
        }
    }
}

private struct InlineNoticeActionButton: View {
    @SortyHotReload private var hotReload
    let action: InlineNoticeAction
    let color: Color

    var body: some View {
        Button(action: action.action) {
            HStack(spacing: 4) {
                if let systemImage = action.systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2)
                }
                Text(action.title)
                    .font(.caption)
                    .fontWeight(.medium)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.12))
        )
    }
}

// MARK: - Insight Pill

struct InsightPill: View {
    @SortyHotReload private var hotReload
    let insight: AIInsight

    private var displayText: String {
        FeatureFlags.privacyModeEnabled
            ? PrivacyPathMasker.redactedText(insight.text) : insight.text
    }

    private var resolvedFinderIcon: NSImage? {
        if insight.category == .folder {
            return AnalysisIconProvider.icon(for: .folder)
        }

        if insight.category == .file {
            let text = insight.text
            if let dotIndex = text.lastIndex(of: ".") {
                let ext =
                    String(text[text.index(after: dotIndex)...])
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces).first ?? ""
                if !ext.isEmpty {
                    return AnalysisIconProvider.icon(forFileExtension: ext)
                }
            }
            return AnalysisIconProvider.icon(for: .data)
        }

        return nil
    }

    private var categoryColor: Color {
        switch insight.category {
        case .file: return .blue
        case .folder: return .orange
        case .constraint: return .yellow
        case .decision: return .green
        case .pattern: return .purple
        case .general: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let filePath = insight.filePath {
                let fileURL = URL(fileURLWithPath: filePath)
                if fileURL.hasDirectoryPath {
                    FolderThumbnailView(url: fileURL, size: CGSize(width: 14, height: 14))
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                } else {
                    FileThumbnailView(url: fileURL, size: CGSize(width: 14, height: 14))
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                }
            } else if let finderIcon = resolvedFinderIcon {
                AppKitImageView(image: finderIcon, size: CGSize(width: 14, height: 14))
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(categoryColor.opacity(0.3))
                    .overlay(
                        Circle().stroke(categoryColor.opacity(0.65), lineWidth: 1)
                    )
                    .frame(width: 8, height: 8)
                    .padding(.horizontal, 3)
                    .accessibilityHidden(true)
            }

            Text(displayText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.1))
        )
    }
}

// MARK: - Flow Layout

public struct FlowLayout: Layout {
    public var spacing: CGFloat = 8

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ())
        -> CGSize
    {
        let result = layoutResult(for: subviews, in: proposal.width ?? 0)
        return CGSize(width: proposal.width ?? 0, height: result.height)
    }

    public func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let result = layoutResult(for: subviews, in: bounds.width)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified)
        }
    }

    private func layoutResult(for subviews: Subviews, in width: CGFloat) -> (
        positions: [CGPoint], height: CGFloat
    ) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x + size.width > width && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }

            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (positions, y + rowHeight)
    }
}

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
