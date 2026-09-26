//
//  OrganizeView.swift
//  Sorty
//
//  Main organization workflow view with improved layout
//  Enhanced with micro-animations, haptic feedback, and state transitions
//

import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum ErrorViewTestRoute: String {
    case credentials = "sorty-error-preview://credentials"
    case network = "sorty-error-preview://network"
    case permissions = "sorty-error-preview://permissions"
    case generic = "sorty-error-preview://generic"

    init?(instructions: String) {
        let normalized = instructions
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.init(rawValue: normalized)
    }

    var error: Error {
        let message: String
        switch self {
        case .credentials:
            message = "Authentication failed because the API key is missing or invalid."
        case .network:
            message = "The network request timed out. Check your internet connection and try again."
        case .permissions:
            message = "Sorty doesn't have permission to access this folder."
        case .generic:
            message = "Sorty couldn't turn the model response into an organization plan."
        }

        return NSError(
            domain: "com.sorty.app.error-preview",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

struct OrganizeView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var organizer: FolderOrganizer
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var customPersonaStore: CustomPersonaStore
    @EnvironmentObject var codexAuth: CodexCLIAuthManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var copilotAuth = GitHubCopilotAuthManager.shared
    @StateObject private var steeringManager = SteeringPromptManager.shared

    @State private var previousState: OrganizationState?
    @State private var showSmarterRetryModelPicker = false
    @State private var showSavedPromptsSheet = false
    @State private var isReturningToStart = false
    @State private var isShowingReturnToStartContent = false
    @State private var keepsDirectorySelectionVisibleAfterReturn = false
    @State private var workflowContentIsVisible = false
    @State private var directorySelectionIsPresented = true
    @State private var workflowEntranceTask: Task<Void, Never>?
    @State private var showsCompletionContent = false
    @State private var liveOrganizationStartedAt: Date?
    @State private var keepsLiveOrganizationVisible = false
    @State private var readyPreviewHandoffTask: Task<Void, Never>?
    @State private var errorViewTestRoute: ErrorViewTestRoute?

    // Just long enough for the first file flight to land before PreviewView
    // replaces the live stage. Kept short: the live stage must never make the
    // user wait for a plan that is already ready.
    private let minimumLiveOrganizationPresentation: TimeInterval = 1.2

    var body: some View {
        ZStack {
            DirectorySelectionView(
                selectedDirectory: $appState.selectedDirectory,
                startsVisible: keepsDirectorySelectionVisibleAfterReturn,
                isPresented: directorySelectionIsPresented
            )
            .opacity(workflowContentIsVisible ? 0 : 1)
            .offset(x: reduceMotion || !workflowContentIsVisible ? 0 : -10)
            .allowsHitTesting(!workflowContentIsVisible)
            .accessibilityHidden(workflowContentIsVisible)

            if let directory = appState.selectedDirectory {
                VStack(spacing: 0) {
                    // Header with selected directory
                    DirectoryHeader(
                        url: directory,
                        mode: settingsViewModel.config.mode,
                        onBack: {
                            HapticFeedbackManager.shared.tap()
                            switch organizer.state {
                            case .scanning, .organizing, .ready, .applying, .completed:
                                returnToStartAfterCancellation()
                            default:
                                returnToDirectorySelection()
                            }
                        },
                        onClear: {
                            HapticFeedbackManager.shared.tap()
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            panel.message = "Select a directory to organize"
                            panel.prompt = "Select"
                            if panel.runModal() == .OK, let url = panel.url {
                                withAnimation(.pageTransition) {
                                    organizer.reset()
                                    appState.selectedDirectory = url
                                }
                                HapticFeedbackManager.shared.success()
                            }
                        }
                    )

                    // Main content area with animated transitions.
                    ZStack {
                        WorkflowGradientBackground()
                            .opacity(persistentWorkflowGradientOpacity)
                            .animation(
                                persistentWorkflowGradientAnimation,
                                value: persistentWorkflowGradientOpacity
                            )
                            .allowsHitTesting(false)

                        stateContent
                            .environment(\.workflowGradientHidden, true)
                            .opacity(stateContentOpacity)
                            .transition(.opacity)

                        if isShowingReturnToStartContent {
                            returnToStartContent
                                .environment(\.workflowGradientHidden, true)
                                .opacity(returnToStartContentOpacity)
                                .scaleEffect(returnToStartContentScale)
                                .offset(y: returnToStartContentOffset)
                                .transition(.identity)
                        }
                    }
                }
                .opacity(workflowContentIsVisible ? 1 : 0)
                .offset(x: reduceMotion || workflowContentIsVisible ? 0 : 12)
                .allowsHitTesting(workflowContentIsVisible)
                .accessibilityHidden(!workflowContentIsVisible)
            }
        }
        .navigationTitle(settingsViewModel.config.mode.workflowTitle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Organization workflow")
        .accessibilityHint("Select a folder and configure options")
        .onAppear {
            directorySelectionIsPresented = appState.selectedDirectory == nil
            settingsViewModel.config.enableStreaming = true
            organizer.setLiveInsightsEnabled(true)
            presentSteeringPromptsIfRequested()
            presentWorkflowContentIfNeeded()
        }
        .onChange(of: appState.shouldPresentSteeringPrompts) { _, _ in
            presentSteeringPromptsIfRequested()
        }
        .onChange(of: settingsViewModel.config.provider) { oldValue, newValue in
            if organizer.aiClient != nil {
                configureOrganizer()
            }
        }
        .onChange(of: organizer.state) { oldValue, newValue in
            handleStateChange(to: newValue)
        }
        .onChange(of: appState.selectedDirectory) { oldValue, newValue in
            errorViewTestRoute = nil
            if newValue != nil {
                keepsDirectorySelectionVisibleAfterReturn = false
                presentWorkflowContentIfNeeded()
            } else {
                workflowEntranceTask?.cancel()
                workflowContentIsVisible = false
                directorySelectionIsPresented = true
            }
            // Prewarm AI connection when user selects a folder
            if newValue != nil {
                Task {
                    await prewarmAIConnection()
                }
            }
        }
        .modelSelectionOverlay(
            isPresented: $showSmarterRetryModelPicker,
            currentProvider: settingsViewModel.config.provider,
            currentModel: settingsViewModel.config.model,
            contextMessage: "Select a stronger model to retry this failed organization attempt. Your selection also becomes the active model for future runs.",
            selectionActionTitle: "Retry with Model",
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
                retryWithSelectedModel(provider: provider, model: model)
            },
            isSubscriptionSelected: settingsViewModel.config.authMethod(for: settingsViewModel.config.provider) == .accountSignIn
        )
        .sheet(isPresented: $showSavedPromptsSheet) {
            SavedPromptsSheet(
                steeringManager: steeringManager,
                settingsConfig: settingsViewModel.config,
                onApplyPrompt: { prompt in
                    organizer.customInstructions = prompt
                    showSavedPromptsSheet = false
                    HapticFeedbackManager.shared.tap()
                }
            )
        }
        .onDisappear {
            directorySelectionIsPresented = false
            workflowEntranceTask?.cancel()
            readyPreviewHandoffTask?.cancel()
            readyPreviewHandoffTask = nil
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        stateContentInner
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
    }

    private var persistentWorkflowGradientOpacity: Double {
        guard appState.selectedDirectory != nil else { return 0 }
        return 1
    }

    private var persistentWorkflowGradientAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.08) : .easeInOut(duration: 0.22)
    }

    private var workflowNavigationAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.1)
            : .spring(response: 0.38, dampingFraction: 0.86)
    }

    private var stateContentOpacity: Double {
        if isReturningToStart { return 0 }
        return 1
    }

    private var returnToStartContentOpacity: Double {
        isReturningToStart ? 1 : 0
    }

    private var returnToStartContentScale: CGFloat {
        1
    }

    private var returnToStartContentOffset: CGFloat {
        0
    }

    private var returnToStartContent: some View {
        ReadyToOrganizeView(onStart: startOrganization, startsVisible: true)
    }

    @ViewBuilder
    private var stateContentInner: some View {
        if shouldShowCompletionView {
            completionHandoffContent
        } else {
            stateContentSwitch
        }
    }

    @ViewBuilder
    private var completionHandoffContent: some View {
        ZStack {
            if let plan = organizer.currentPlan {
                PreviewView(
                    plan: plan,
                    baseURL: appState.selectedDirectory ?? URL(fileURLWithPath: "/"),
                    onReturnToStart: returnToStartAfterCancellation
                )
                .opacity(isCompletionContentVisible ? 0 : 1)
                .blur(radius: completionPreviewBlur)
                .scaleEffect(isCompletionContentVisible && !reduceMotion ? 0.992 : 1)
                .allowsHitTesting(!isCompletionContentVisible)

                OrganizationCompleteView(
                    stats: plan.generationStats,
                    totalFiles: plan.suggestions.reduce(0) { $0 + $1.totalFileCount },
                    totalFolders: plan.suggestions.count,
                    renameCount: plan.suggestions.reduce(0) { $0 + $1.renameCount },
                    mode: settingsViewModel.config.mode,
                    directoryURL: appState.selectedDirectory ?? URL(fileURLWithPath: "/"),
                    onReturnToStart: returnToStartAfterCancellation
                )
                .opacity(isCompletionContentVisible ? 1 : 0)
                .scaleEffect(isCompletionContentVisible || reduceMotion ? 1 : 0.985)
                .offset(y: isCompletionContentVisible || reduceMotion ? 0 : 10)
                .allowsHitTesting(isCompletionContentVisible)
            } else {
                OrganizationCompleteView(
                    stats: nil,
                    totalFiles: 0,
                    totalFolders: 0,
                    renameCount: 0,
                    mode: settingsViewModel.config.mode,
                    directoryURL: appState.selectedDirectory ?? URL(fileURLWithPath: "/"),
                    onReturnToStart: returnToStartAfterCancellation
                )
            }
        }
        .animation(completionHandoffAnimation, value: showsCompletionContent)
    }

    private var completionPreviewBlur: CGFloat {
        isCompletionContentVisible && !reduceMotion ? 2 : 0
    }

    private var completionHandoffAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.42)
    }

    private var shouldShowCompletionView: Bool {
        if case .completed = organizer.state { return true }
        return organizer.pinsCompletionView || showsCompletionContent
    }

    private var isCompletionContentVisible: Bool {
        if case .completed = organizer.state { return true }
        return organizer.pinsCompletionView || showsCompletionContent
    }

    @ViewBuilder
    private var stateContentSwitch: some View {
        if let errorViewTestRoute {
            ErrorView(
                error: errorViewTestRoute.error,
                onCancel: dismissErrorViewTestRoute,
                onRetry: dismissErrorViewTestRoute,
                onRetryWithSmarterModel: dismissErrorViewTestRoute,
                onGrantPermission: dismissErrorViewTestRoute
            )
        } else {
            organizerStateContent
        }
    }

    @ViewBuilder
    private var organizerStateContent: some View {
        switch organizer.state {
        case .idle:
            if needsSetupRepair {
                SetupRepairGateView(
                    message: activeSetupRepairMessage ?? "Finish setting up your provider before organizing files.",
                    onStart: startOrganization,
                    onOpenSettings: {
                        HapticFeedbackManager.shared.selection()
                        appState.startSetupRepair(
                            message: activeSetupRepairMessage ?? "Finish setting up your provider before organizing files.",
                            navigateToSettings: true
                        )
                    }
                )
            } else {
                ReadyToOrganizeView(
                    onStart: startOrganization,
                    startsVisible: true
                )
            }
        case .scanning, .organizing, .applying:
            AnalysisView(
                onReturnToStart: returnToStartAfterCancellation,
                onLiveOrganizationStarted: noteLiveOrganizationStarted
            )
        case .ready:
            if keepsLiveOrganizationVisible {
                AnalysisView(
                    onReturnToStart: returnToStartAfterCancellation,
                    onLiveOrganizationStarted: noteLiveOrganizationStarted
                )
            } else if let plan = organizer.currentPlan {
                PreviewView(
                    plan: plan,
                    baseURL: appState.selectedDirectory!,
                    onReturnToStart: returnToStartAfterCancellation,
                    onApplyStarted: beginCompletionHandoff
                )
            } else {
                PreviewHandoffView(mode: settingsViewModel.config.mode)
            }
        case .completed:
            completionHandoffContent
        case .error(let error):
            ErrorView(
                error: error,
                canResume: organizer.canResumeOrganization,
                onResume: {
                    Task {
                        try? await organizer.resumeOrganization()
                    }
                },
                onCancel: returnToDirectorySelection,
                onRetry: {
                    HapticFeedbackManager.shared.tap()
                    withAnimation(.pageTransition) {
                        organizer.reset()
                    }
                },
                onRetryWithSmarterModel: {
                    showSmarterRetryModelPicker = true
                },
                onGrantPermission: grantFolderPermissionAndContinue
            )
        }
    }

    private var returnToStartExitAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.08) : .easeInOut(duration: 0.18)
    }

    private func returnToStartAfterCancellation() {
        guard !isReturningToStart else { return }

        if case .completed = organizer.state {
            returnToDirectorySelection()
            return
        }

        isShowingReturnToStartContent = true
        organizer.prepareForReturnToStartTransition()

        withAnimation(returnToStartExitAnimation, completionCriteria: .logicallyComplete) {
            isReturningToStart = true
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                organizer.cancel()
                showsCompletionContent = false
                keepsDirectorySelectionVisibleAfterReturn = false
                isShowingReturnToStartContent = false
                isReturningToStart = false
            }
        }
    }

    private func returnToDirectorySelection() {
        guard !isReturningToStart else { return }

        workflowEntranceTask?.cancel()
        keepsDirectorySelectionVisibleAfterReturn = true
        directorySelectionIsPresented = true
        errorViewTestRoute = nil

        withAnimation(workflowNavigationAnimation, completionCriteria: .logicallyComplete) {
            isReturningToStart = true
            workflowContentIsVisible = false
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                organizer.pinsCompletionView = false
                organizer.reset()
                appState.selectedDirectory = nil
                showsCompletionContent = false
                isShowingReturnToStartContent = false
                isReturningToStart = false
            }
        }
    }

    private func presentWorkflowContentIfNeeded() {
        guard appState.selectedDirectory != nil else { return }

        workflowEntranceTask?.cancel()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            workflowContentIsVisible = false
        }

        workflowEntranceTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, appState.selectedDirectory != nil else { return }
            withAnimation(workflowNavigationAnimation, completionCriteria: .logicallyComplete) {
                workflowContentIsVisible = true
            } completion: {
                guard appState.selectedDirectory != nil else { return }
                directorySelectionIsPresented = false
            }
        }
    }

    private func handleStateChange(to newState: OrganizationState) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            switch newState {
            case .completed:
                HapticFeedbackManager.shared.success()
                beginCompletionHandoff()
            case .error:
                showsCompletionContent = false
                HapticFeedbackManager.shared.error()
            case .ready:
                showsCompletionContent = false
                HapticFeedbackManager.shared.success()
            case .scanning, .organizing:
                showsCompletionContent = false
                HapticFeedbackManager.shared.selection()
            default:
                break
            }
        }

        switch newState {
        case .ready:
            scheduleReadyPreviewHandoff()
        case .completed, .error, .idle:
            resetLiveOrganizationPresentation()
        default:
            break
        }

        previousState = newState
    }

    private func noteLiveOrganizationStarted() {
        guard !reduceMotion, liveOrganizationStartedAt == nil else { return }

        // If the plan is already ready when the first live suggestions parse,
        // the response effectively arrived at once (non-streaming provider or
        // a final throttled flush). There is nothing live to show, so go
        // straight to the preview instead of replaying a fake animation.
        if organizer.state == .ready {
            resetLiveOrganizationPresentation()
            return
        }

        liveOrganizationStartedAt = Date()
        keepsLiveOrganizationVisible = true
    }

    private func scheduleReadyPreviewHandoff() {
        guard !reduceMotion,
              keepsLiveOrganizationVisible,
              let liveOrganizationStartedAt else {
            resetLiveOrganizationPresentation()
            return
        }

        let elapsed = Date().timeIntervalSince(liveOrganizationStartedAt)
        let remaining = minimumLiveOrganizationPresentation - elapsed
        guard remaining > 0 else {
            finishLiveOrganizationPresentation()
            return
        }

        readyPreviewHandoffTask?.cancel()
        readyPreviewHandoffTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, organizer.state == .ready else { return }
            finishLiveOrganizationPresentation()
        }
    }

    private func finishLiveOrganizationPresentation() {
        readyPreviewHandoffTask?.cancel()
        readyPreviewHandoffTask = nil
        liveOrganizationStartedAt = nil
        withAnimation(.smooth(duration: 0.34)) {
            keepsLiveOrganizationVisible = false
        }
    }

    private func resetLiveOrganizationPresentation() {
        readyPreviewHandoffTask?.cancel()
        readyPreviewHandoffTask = nil
        liveOrganizationStartedAt = nil
        keepsLiveOrganizationVisible = false
    }

    private func beginCompletionHandoff() {
        guard !showsCompletionContent else { return }

        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.42)) {
            showsCompletionContent = true
        }
    }

    private func configureOrganizer() {
        Task {
            do {
                var config = settingsViewModel.config
                config.enableStreaming = true
                try await organizer.configure(with: config)
            } catch is CancellationError {
                return
            } catch {
                organizer.state = .error(error)
            }
        }
    }

    private func startOrganization() {
        guard let directory = appState.selectedDirectory else { return }
        if let testRoute = ErrorViewTestRoute(instructions: organizer.customInstructions) {
            resetLiveOrganizationPresentation()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                errorViewTestRoute = testRoute
            }
            HapticFeedbackManager.shared.error()
            return
        }
        HapticFeedbackManager.shared.tap()
        resetLiveOrganizationPresentation()

        Task {
            do {
                if needsSetupRepair {
                    try await verifyProviderForOrganization()
                }
                try await appState.prepareForManualOrganization(at: directory)
                try await organizer.organize(directory: directory)
            } catch is CancellationError {
                return
            } catch {
                if appState.requiresSetupRepair {
                    HapticFeedbackManager.shared.error()
                    return
                }
                organizer.state = .error(error)
            }
        }
    }

    /// A persisted repair flag is only a prompt to revalidate. The network
    /// check runs after the user starts an organization, never during launch.
    private func verifyProviderForOrganization() async throws {
        let testedConfig = settingsViewModel.config
        do {
            try await settingsViewModel.testConnection()
            guard settingsViewModel.config == testedConfig else {
                throw CancellationError()
            }
            appState.clearSetupRepairState()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard settingsViewModel.config == testedConfig else {
                throw CancellationError()
            }
            appState.startSetupRepair(
                message: "Sorty could not verify \(testedConfig.provider.displayName): \(error.localizedDescription)"
            )
            throw error
        }
    }

    private func grantFolderPermissionAndContinue() {
        guard let directory = appState.selectedDirectory else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = directory.deletingLastPathComponent()
        panel.nameFieldStringValue = directory.lastPathComponent
        panel.message = "Select \(directory.lastPathComponent) to grant Sorty access and continue organizing."
        panel.prompt = "Grant Access"

        guard panel.runModal() == .OK, let authorizedDirectory = panel.url else { return }

        // User-picked via NSOpenPanel: validate, hold a balanced temporary
        // session while the bookmark is minted in didSet, then release it.
        // Long-lived access comes from bookmark resolution at organize time.
        guard case .success(let validated) = IncomingPathValidator.validatedDirectoryURL(for: authorizedDirectory.path) else {
            DebugLogger.log("Rejected panel directory: \(authorizedDirectory.path)")
            return
        }
        let didStart = validated.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                validated.stopAccessingSecurityScopedResource()
            }
        }
        appState.selectedDirectory = validated
        withAnimation(.pageTransition) {
            organizer.reset()
        }
        HapticFeedbackManager.shared.success()
        startOrganization()
    }

    private func dismissErrorViewTestRoute() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            errorViewTestRoute = nil
        }
    }

    private func retryWithSelectedModel(provider: AIProvider, model: String) {
        Task {
            do {
                settingsViewModel.config.provider = provider
                settingsViewModel.config.model = model
                try await organizer.configure(with: settingsViewModel.config)
                try await organizer.regenerateWithModel(provider: provider, model: model)
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    organizer.state = .error(error)
                }
            }
        }
    }
    
    private func prewarmAIConnection() async {
        let provider = settingsViewModel.config.provider
        let config = settingsViewModel.config
        await AISessionManager.shared.prewarm(provider: provider, config: config)
    }

    private func presentSteeringPromptsIfRequested() {
        guard appState.shouldPresentSteeringPrompts else { return }
        showSavedPromptsSheet = true
        appState.shouldPresentSteeringPrompts = false
    }

    private var providerSetupStatus: ProviderSetupStatus {
        OnboardingSetupValidator.providerStatus(
            context: ProviderSetupContext(
                config: settingsViewModel.config,
                isGitHubCopilotAuthenticated: copilotAuth.isAuthenticated,
                isCodexAuthenticated: codexAuth.isAuthenticated,
                isCodexInstalled: codexAuth.isCodexInstalled,
                isAppleFoundationModelAvailable: settingsViewModel.isAppleModelAvailable,
                appleFoundationModelStatus: settingsViewModel.appleModelStatus
            )
        )
    }

    private var needsSetupRepair: Bool {
        if appState.requiresSetupRepair {
            return true
        }
        guard isProviderStateReadyForValidation else { return false }
        return !providerSetupStatus.isReady
    }

    private var activeSetupRepairMessage: String? {
        if appState.requiresSetupRepair {
            return appState.setupRepairMessage ?? providerSetupStatus.message
        }
        guard isProviderStateReadyForValidation else { return nil }
        if !providerSetupStatus.isReady {
            return providerSetupStatus.message
        }
        return nil
    }

    private var isProviderStateReadyForValidation: Bool {
        settingsViewModel.hasLoadedPersistedState &&
            !settingsViewModel.isConfiguredCredentialHydrating &&
            isCodexStatusResolvedForValidation
    }

    /// The Codex CLI probe resolves asynchronously after launch. Until it has,
    /// the validator would mistake the initial `isCodexInstalled == false` for
    /// a missing setup and flash the repair HUD on every restart.
    private var isCodexStatusResolvedForValidation: Bool {
        let config = settingsViewModel.config
        guard config.provider == .openAI,
              ProviderAuthResolver.effectiveAuthMethod(for: .openAI, config: config) == .accountSignIn
        else { return true }
        return codexAuth.hasResolvedStatus
    }

}

// MARK: - Directory Header

struct DirectoryHeader: View {
    @SortyHotReload private var hotReload
    let url: URL
    let mode: OrganizationMode
    let onBack: () -> Void
    let onClear: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringPath = false

    var body: some View {
        HStack(spacing: 12) {
            GlassyBackButton(action: onBack)
                .padding(.trailing, 4)

            Button(action: revealSelectedDirectory) {
                FolderThumbnailView(url: url, size: CGSize(width: 32, height: 32))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reveal \(url.lastPathComponent) in Finder")
            .accessibilityLabel("Reveal \(url.lastPathComponent) in Finder") // [VERIFY] confirm label matches intent

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Image(systemName: mode.iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .symbolReplaceTransition(animationValue: mode)
                        .accessibilityHidden(true)

                    Text(mode.workflowTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .numericTextTransition(animationValue: mode)
                }
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button(action: revealSelectedDirectory) {
                    HStack(spacing: 5) {
                        PrivacySensitivePathText(path: url.deletingLastPathComponent().path)
                            .lineLimit(1)

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 10)
                            .opacity(isHoveringPath ? 1 : 0)
                            .offset(
                                x: reduceMotion || isHoveringPath ? 0 : -3,
                                y: reduceMotion || isHoveringPath ? 0 : 3
                            )
                            .scaleEffect(reduceMotion || isHoveringPath ? 1 : 0.75)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Reveal \(url.lastPathComponent) in Finder")
                .accessibilityLabel("Reveal \(url.lastPathComponent) in Finder") // [VERIFY] confirm label matches intent
                .animation(
                    reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82),
                    value: isHoveringPath
                )
                .onHover { hovering in
                    isHoveringPath = hovering
                }
            }

            Spacer()

            Button {
                onClear()
            } label: {
                Label("Change Folder", systemImage: "folder.badge.gearshape")
            }
            .buttonStyle(.sortyBordered(size: .small))
            .accessibilityIdentifier("ChangeFolderButton")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func revealSelectedDirectory() {
        HapticFeedbackManager.shared.tap()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }
}

private struct HeaderBlurReplaceModifier: ViewModifier {
    let radius: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: radius)
            .opacity(opacity)
    }
}

private extension AnyTransition {
    static var headerBlurReplace: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: HeaderBlurReplaceModifier(radius: 7, opacity: 0),
                identity: HeaderBlurReplaceModifier(radius: 0, opacity: 1)
            ),
            removal: .modifier(
                active: HeaderBlurReplaceModifier(radius: 5, opacity: 0),
                identity: HeaderBlurReplaceModifier(radius: 0, opacity: 1)
            )
        )
    }
}

private struct SetupRepairGateView: View {
    @SortyHotReload private var hotReload
    let message: String
    let onStart: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            Text("Finish Provider Setup")
                .font(.title3.weight(.semibold))

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 10) {
                Button("Open Provider Settings", action: onOpenSettings)
                    .buttonStyle(.sortyBordered)
                    .accessibilityIdentifier("OpenProviderSettingsForRepairButton")

                Button("Try Organizing", action: onStart)
                    .buttonStyle(.sortyProminent)
                    .accessibilityIdentifier("RetryOrganizationForRepairButton")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

// MARK: - Preview handoff

private struct PreviewHandoffView: View {
    @SortyHotReload private var hotReload
    let mode: OrganizationMode
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 48, height: 48)

                Image(systemName: mode == .renameOnly ? "text.badge.checkmark" : "checkmark.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .symbolReplaceTransition(animationValue: mode)
                    .scaleEffect(appeared ? 1 : 0.88)
            }

            Text(mode == .renameOnly ? "Preparing name preview" : "Preparing preview")
                .font(.subheadline.weight(.semibold))
                .numericTextTransition(animationValue: mode)

            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary.opacity(0.32))
                        .frame(width: 5, height: 5)
                        .modifier(PreviewHandoffDot(delay: Double(index) * 0.14))
                }
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(appeared ? 1 : 0)
        .animation(.smooth(duration: 0.28), value: appeared)
        .onAppear { appeared = true }
    }
}

private struct PreviewHandoffDot: ViewModifier {
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var isWindowVisible = true

    private var dotPaused: Bool {
        reduceMotion || !isWindowVisible || controlActiveState == .inactive
            || scenePhase != .active
    }

    func body(content: Content) -> some View {
        Group {
            if reduceMotion {
                content
                    .scaleEffect(1)
                    .opacity(0.6)
            } else {
                SwiftUI.TimelineView(
                    .animation(minimumInterval: 1.0 / 15.0, paused: dotPaused)
                ) { timeline in
                    // Shared clock: each dot offsets the same 1.16s pulse
                    // cycle instead of owning a repeatForever transaction.
                    let cycle = 1.16
                    let elapsed = timeline.date.timeIntervalSinceReferenceDate + delay
                    let progress = dotPaused ? 0.5 : CGFloat((elapsed / cycle).truncatingRemainder(dividingBy: 1))
                    let eased = progress * progress * (3 - 2 * progress)
                    content
                        .scaleEffect(0.78 + eased * 0.44)
                        .opacity(0.35 + eased * 0.53)
                }
            }
        }
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
    }
}

// MARK: - Compact Storage Location Row

struct CompactStorageLocationRow: View {
    @SortyHotReload private var hotReload
    let location: StorageLocation
    @EnvironmentObject var storageLocationsManager: StorageLocationsManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingConfig = false
    @State private var showReauthorizePicker = false
    @State private var isHoveringPath = false

    private var needsAttention: Bool {
        !location.exists || location.accessStatus == .lost
    }

    private var statusHelp: String? {
        if !location.exists { return "Folder not found" }
        if location.accessStatus == .lost { return "Access to this folder was lost. Grant access again." }
        if location.accessStatus == .stale { return "Access is being refreshed automatically" }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: location.isEnabled ? "externaldrive.fill" : "externaldrive")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.blue)
                    .symbolReplaceTransition(animationValue: location.isEnabled)

                if needsAttention {
                    Image(systemName: !location.exists ? "exclamationmark.triangle.fill" : "lock.slash.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(!location.exists ? .red : .orange)
                        .symbolReplaceTransition(animationValue: location.exists)
                        .offset(x: 5, y: 4)
                        .accessibilityHidden(true)
                }
            }
            .help(statusHelp ?? "")

            VStack(alignment: .leading, spacing: 2) {
                Text(location.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(location.isEnabled ? .primary : .secondary)

                Button {
                    HapticFeedbackManager.shared.tap()
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: location.path)
                } label: {
                    HStack(spacing: 5) {
                        PrivacySensitivePathText(path: location.path, revealOnClick: false)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 10)
                            .opacity(isHoveringPath ? 1 : 0)
                            .offset(
                                x: reduceMotion || isHoveringPath ? 0 : -3,
                                y: reduceMotion || isHoveringPath ? 0 : 3
                            )
                            .scaleEffect(reduceMotion || isHoveringPath ? 1 : 0.75)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("Reveal \(location.name) in Finder")
                .accessibilityLabel("Reveal \(location.name) in Finder")
                .animation(
                    reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82),
                    value: isHoveringPath
                )
                .onHover { hovering in
                    isHoveringPath = hovering
                }
            }

            Spacer()

            if location.accessStatus == .lost {
                Button("Grant Access") {
                    HapticFeedbackManager.shared.tap()
                    showReauthorizePicker = true
                }
                .font(.caption2)
                .buttonStyle(.sortyBordered)
                .controlSize(.mini)
                .help("Re-select this folder to restore access")
                .accessibilityLabel("Grant access to \(location.name)")
            }

            HStack(spacing: 6) {
                Button {
                    HapticFeedbackManager.shared.tap()
                    showingConfig = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.sortyBordered)
                .controlSize(.mini)
                .help("Customize \(location.name)")
                .accessibilityLabel("Customize \(location.name)")

                Button(role: .destructive) {
                    HapticFeedbackManager.shared.tap()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        storageLocationsManager.removeLocation(location)
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.sortyBordered)
                .controlSize(.mini)
                .help("Remove \(location.name)")
                .accessibilityLabel("Remove \(location.name)")
            }

            Toggle("", isOn: Binding(
                get: { location.isEnabled },
                set: { _ in
                    HapticFeedbackManager.shared.selection()
                    storageLocationsManager.toggleEnabled(for: location)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityLabel("Enable \(location.name)")
            .accessibilityValue(location.isEnabled ? "On" : "Off")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.05))
        )
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: location.path)
            }
            Button("Customize...") {
                showingConfig = true
            }
            Divider()
            Button("Remove", role: .destructive) {
                HapticFeedbackManager.shared.tap()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    storageLocationsManager.removeLocation(location)
                }
            }
        }
        .sheet(isPresented: $showingConfig) {
            StorageLocationConfigView(location: location)
                .modalBounce()
        }
        .fileImporter(
            isPresented: $showReauthorizePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                storageLocationsManager.reauthorizeLocation(location, with: url)
            }
        }
    }
}

// MARK: - Storage Locations Info Popover

struct StorageLocationsInfoPopover: View {
    @SortyHotReload private var hotReload
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("How Storage Locations Work", systemImage: "externaldrive")
                .font(.subheadline)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 10) {
                InfoRow(icon: "arrow.right.circle", text: "Files can be moved TO enabled locations during organization")
                InfoRow(icon: "xmark.circle", text: "Files already inside a location will NOT be reorganized")
                InfoRow(icon: "brain", text: "Sorty matches files using each location's description — customize it to steer results")
                InfoRow(icon: "externaldrive.fill.badge.icloud", text: "Local, cloud, and external drive folders are all supported")
                InfoRow(icon: "checkmark.shield", text: "Folder access is checked automatically; Sorty asks only if it needs you to re-grant access")
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

#if DEBUG
// MARK: - Previews

@MainActor
private enum OrganizePreviewObjects {
    static var idleOrganizer: FolderOrganizer {
        let organizer = FolderOrganizer()
        organizer.state = .idle
        return organizer
    }
    
    static var scanningOrganizer: FolderOrganizer {
        let organizer = FolderOrganizer()
        organizer.state = .scanning
        organizer.progress = 0.35
        organizer.organizationStage = "Scanning files..."
        return organizer
    }
    
    static var readyOrganizer: FolderOrganizer {
        let organizer = FolderOrganizer()
        organizer.state = .ready
        organizer.currentPlan = PreviewMocks.makeOrganizationPlan()
        return organizer
    }
    
    static var errorOrganizer: FolderOrganizer {
        let organizer = FolderOrganizer()
        organizer.state = .error(NSError(domain: "Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection failed. Please check your API key."]))
        return organizer
    }
    
    static var readyAppState: AppState {
        let state = AppState()
        state.hasCompletedOnboarding = true
        state.selectedDirectory = URL(fileURLWithPath: "/Users/user/Downloads")
        return state
    }
}

#Preview("Organize View - Idle") {
    let codexAuthManager = CodexCLIAuthManager()

    OrganizeView()
        .environmentObject(OrganizePreviewObjects.idleOrganizer)
        .environmentObject(SettingsViewModel.preview)
        .environmentObject(AppState.preview)
        .environmentObject(PersonaManager.preview)
        .environmentObject(CustomPersonaStore.preview)
        .environmentObject(LearningsManager.preview)
        .environmentObject(codexAuthManager)
        .environmentObject(MenuBarController())
        .frame(width: 900, height: 600)
}

#Preview("Organize View - Scanning") {
    let codexAuthManager = CodexCLIAuthManager()

    OrganizeView()
        .environmentObject(OrganizePreviewObjects.scanningOrganizer)
        .environmentObject(SettingsViewModel.preview)
        .environmentObject(AppState.preview)
        .environmentObject(PersonaManager.preview)
        .environmentObject(CustomPersonaStore.preview)
        .environmentObject(LearningsManager.preview)
        .environmentObject(codexAuthManager)
        .environmentObject(MenuBarController())
        .frame(width: 900, height: 600)
}

#Preview("Organize View - Ready") {
    let codexAuthManager = CodexCLIAuthManager()

    OrganizeView()
        .environmentObject(OrganizePreviewObjects.readyOrganizer)
        .environmentObject(SettingsViewModel.preview)
        .environmentObject(OrganizePreviewObjects.readyAppState)
        .environmentObject(PersonaManager.preview)
        .environmentObject(CustomPersonaStore.preview)
        .environmentObject(LearningsManager.preview)
        .environmentObject(codexAuthManager)
        .environmentObject(MenuBarController())
        .frame(width: 900, height: 700)
}

#Preview("Organize View - Error") {
    let codexAuthManager = CodexCLIAuthManager()

    OrganizeView()
        .environmentObject(OrganizePreviewObjects.errorOrganizer)
        .environmentObject(SettingsViewModel.preview)
        .environmentObject(AppState.preview)
        .environmentObject(PersonaManager.preview)
        .environmentObject(CustomPersonaStore.preview)
        .environmentObject(LearningsManager.preview)
        .environmentObject(codexAuthManager)
        .environmentObject(MenuBarController())
        .frame(width: 900, height: 600)
}

#endif
