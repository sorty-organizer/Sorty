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
            configureOrganizer()
            presentSteeringPromptsIfRequested()
            presentWorkflowContentIfNeeded()
        }
        .onChange(of: appState.shouldPresentSteeringPrompts) { _, _ in
            presentSteeringPromptsIfRequested()
        }
        .onChange(of: settingsViewModel.config.provider) { oldValue, newValue in
            configureOrganizer()
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
        .onAppear {
            updateSetupRepairHUD()
        }
        .onChange(of: activeSetupRepairMessage) {
            updateSetupRepairHUD()
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
        guard !needsSetupRepair else {
            HapticFeedbackManager.shared.error()
            appState.startSetupRepair(
                message: activeSetupRepairMessage ?? "Finish setting up your provider before organizing files."
            )
            return
        }

        HapticFeedbackManager.shared.tap()
        resetLiveOrganizationPresentation()



        Task {
            do {
                await appState.prepareForManualOrganization(at: directory)
                try await organizer.organize(directory: directory)
            } catch is CancellationError {
                return
            } catch {
                organizer.state = .error(error)
            }
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

        _ = authorizedDirectory.startAccessingSecurityScopedResource()
        appState.selectedDirectory = authorizedDirectory
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
        guard isProviderStateReadyForValidation else { return false }
        return appState.requiresSetupRepair || !providerSetupStatus.isReady
    }

    private var activeSetupRepairMessage: String? {
        guard isProviderStateReadyForValidation else { return nil }
        if appState.requiresSetupRepair {
            return appState.setupRepairMessage ?? providerSetupStatus.message
        }
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

    private func updateSetupRepairHUD() {
        guard let message = activeSetupRepairMessage else {
            NotificationManager.shared.dismissHUD(identifier: "setup-repair")
            return
        }

        appState.presentSetupRepairHUD(message: message)
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

            Button("Open Provider Settings", action: onOpenSettings)
                .buttonStyle(.sortyProminent)
                .accessibilityIdentifier("OpenProviderSettingsForRepairButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

// MARK: - Ready to Organize View

struct ReadyToOrganizeView: View {
    @SortyHotReload private var hotReload
    let onStart: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var organizer: FolderOrganizer
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var storageLocationsManager: StorageLocationsManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var automationManager: AutomationManager
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var customPersonaStore: CustomPersonaStore
    @StateObject private var sessionManager = AISessionManager.shared
    @StateObject private var steeringManager = SteeringPromptManager.shared
    @State private var hasAppeared = false
    @State private var isTextFieldFocused = false
    @State private var showStorageLocations = false
    @State private var showingFolderPicker = false
    @State private var suggestedLocationName: String? = nil
    @State private var addStorageLocationErrorMessage: String?
    @State private var showSavePromptDialog = false
    @State private var savePromptName = ""
    @State private var isImprovingPrompt = false
    @State private var showImprovePromptRequest = false
    @State private var improvePromptRequestMessage = ""
    @State private var showSavedPromptsSheet = false
    @State private var showStorageLocationsInfo = false
    @State private var referenceableFiles: [InstructionFileReference] = []
    @State private var instructionSelection: NSRange = NSRange(location: 0, length: 0)
    @State private var referenceRefreshTask: Task<Void, Never>?
    @State private var startCTACompression: CGFloat = 0

    init(onStart: @escaping () -> Void, startsVisible: Bool = false) {
        self.onStart = onStart
        _hasAppeared = State(initialValue: startsVisible)
    }

    private var mode: OrganizationMode {
        settingsViewModel.config.mode
    }

    private var instructionSuggestions: [String] {
        InstructionSuggestionCatalog.suggestions(
            for: mode,
            personaManager: personaManager,
            customPersonaStore: customPersonaStore
        )
    }

    private var isConnecting: Bool {
        sessionManager.prewarmingProvider != nil
    }

    private var selectedStorageLocationCount: Int {
        storageLocationsManager.locations.filter(\.isEnabled).count
    }

    private var unavailableSelectedStorageLocationCount: Int {
        max(0, selectedStorageLocationCount - storageLocationsManager.enabledLocations.count)
    }

    private var storageLocationSummaryID: String {
        if selectedStorageLocationCount > 0 {
            return unavailableSelectedStorageLocationCount > 0
                ? "selected-unavailable"
                : "selected-available"
        }

        return storageLocationsManager.locations.isEmpty ? "unconfigured" : "inactive"
    }

    private var storageLocationSummaryTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.94, anchor: .leading))
    }

    private var storageLocationTitle: String {
        selectedStorageLocationCount == 1 ? "Storage Location" : "Storage Locations"
    }

    private var storageLocationSelectionTint: Color {
        unavailableSelectedStorageLocationCount > 0 ? .orange : .green
    }

    private var storageLocationsVerticalPadding: CGFloat {
        if showStorageLocations {
            return 10
        }

        return storageLocationsManager.locations.isEmpty ? 4 : 6
    }

    private var storageLocationListIDs: [StorageLocation.ID] {
        storageLocationsManager.locations.map(\.id)
    }

    private var storageLocationInsertionAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.32, dampingFraction: 0.84)
    }

    private var storageLocationRowTransition: AnyTransition {
        .opacity
    }

    private var addStorageLocationErrorIsPresented: Binding<Bool> {
        Binding(
            get: { addStorageLocationErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    addStorageLocationErrorMessage = nil
                }
            }
        )
    }

    var body: some View {
        WorkflowContainer(currentStep: .configure) {
            // Compact header
            VStack(spacing: 16) {
                iconSection
                ReadyToOrganizeTitle(
                    mode: mode,
                    showsWorkflowPicker: appState.showsFinderWorkflowPicker,
                    onSelectMode: selectWorkflow
                )
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.96)
            .offset(y: hasAppeared ? 0 : 8)
            .animation(reduceMotion ? nil : .smooth(duration: 0.45).delay(0.04), value: hasAppeared)

            // Instructions card
            WorkflowCard(title: "Instructions", icon: "text.bubble") {
                instructionsContent
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 10)
            .animation(reduceMotion ? nil : .smooth(duration: 0.45).delay(0.10), value: hasAppeared)

            if mode != .renameOnly {
                WorkflowCard(verticalPadding: storageLocationsVerticalPadding) {
                    storageLocationsContent
                }
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 10)
                .animation(reduceMotion ? nil : .smooth(duration: 0.45).delay(0.16), value: hasAppeared)
            }

            ReadyToOrganizeStartButton(
                mode: mode,
                isConnecting: isConnecting,
                hasAppeared: hasAppeared,
                reduceMotion: reduceMotion,
                compression: startCTACompression,
                onStart: runStartCTAAnimation
            )

            ReadyToOrganizeKeyboardHint(
                actionVerb: mode.actionVerb,
                isConnecting: isConnecting,
                hasAppeared: hasAppeared,
                reduceMotion: reduceMotion
            )

            // Connection status indicator
            connectionStatusView
                .opacity(hasAppeared ? 1 : 0)
                .animation(reduceMotion ? nil : .smooth(duration: 0.45).delay(0.32), value: hasAppeared)
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderImport(result)
        }
        .alert(
            "Couldn't Add Storage Location",
            isPresented: addStorageLocationErrorIsPresented
        ) {
            Button("OK", role: .cancel) {
                addStorageLocationErrorMessage = nil
            }
        } message: {
            Text(addStorageLocationErrorMessage ?? "Please try selecting the folder again.")
        }
        .onAppear(perform: prepareForDisplay)
        .onChange(of: appState.selectedDirectory) { _, _ in
            scheduleReferenceableFilesRefresh()
        }
        .onDisappear(perform: stopReferenceRefresh)
    }

    private func handleFolderImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                HapticFeedbackManager.shared.success()
                do {
                    try withAnimation(storageLocationInsertionAnimation) {
                        try storageLocationsManager.addLocation(
                            url: url,
                            customName: suggestedLocationName
                        )
                    }
                } catch {
                    HapticFeedbackManager.shared.error()
                    addStorageLocationErrorMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            HapticFeedbackManager.shared.error()
            addStorageLocationErrorMessage = error.localizedDescription
        }
        suggestedLocationName = nil
    }

    private func prepareForDisplay() {
        scheduleReferenceableFilesRefresh()
        Task { await storageLocationsManager.refreshAccessStatus() }

        guard !hasAppeared else { return }
        guard !appState.hasPresentedReadyToOrganize else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                hasAppeared = true
            }
            return
        }

        appState.hasPresentedReadyToOrganize = true
        hasAppeared = true
    }

    private func stopReferenceRefresh() {
        referenceRefreshTask?.cancel()
        referenceRefreshTask = nil
    }

    private func runStartCTAAnimation() {
        HapticFeedbackManager.shared.tap()
        guard !reduceMotion else {
            onStart()
            return
        }

        withAnimation(.spring(response: 0.18, dampingFraction: 0.56)) {
            startCTACompression = 1
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(70))
            onStart()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                startCTACompression = 0
            }
        }
    }

    private func selectWorkflow(_ selectedMode: OrganizationMode) {
        guard selectedMode != mode else { return }
        HapticFeedbackManager.shared.selection()
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6)) {
            if selectedMode != .organize {
                settingsViewModel.config.enableSmartRename = true
            }
            settingsViewModel.config.mode = selectedMode
        }
    }

    private func toggleStorageLocations() {
        HapticFeedbackManager.shared.selection()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            showStorageLocations.toggle()
        }
    }

    private var storageLocationsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                Button(action: toggleStorageLocations) {
                    HStack(spacing: 6) {
                        Image(systemName: selectedStorageLocationCount > 0 ? "externaldrive.fill" : "externaldrive")
                            .font(.system(size: 12))
                            .foregroundStyle(
                                selectedStorageLocationCount > 0
                                    ? Color.accentColor
                                    : Color.secondary
                            )
                            .symbolReplaceTransition(
                                animationValue: selectedStorageLocationCount > 0
                            )
                            .frame(width: 22, height: 22)
                            .background {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.32))
                                    .frame(width: 18, height: 18)
                                    .blur(radius: 5)
                                    .opacity(selectedStorageLocationCount > 0 ? 1 : 0)
                            }

                        Text(storageLocationTitle)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .numericTextTransition(
                                animationValue: storageLocationTitle,
                                animation: .easeInOut(duration: 0.28)
                            )
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showStorageLocations ? "Hide organization locations" : "Show organization locations")
                .accessibilityLabel(showStorageLocations ? "Hide storage locations" : "Show storage locations")
                .accessibilityHint("Expand to manage local, cloud, and external organization locations")
                .accessibilityValue(showStorageLocations ? "Expanded" : "Collapsed")

                Button {
                    HapticFeedbackManager.shared.tap()
                    showStorageLocationsInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 44)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        HapticFeedbackManager.shared.selection()
                    }
                }
                .popover(isPresented: $showStorageLocationsInfo, arrowEdge: .bottom) {
                    StorageLocationsInfoPopover()
                        .systemLiquidGlassPopover(cornerRadius: 12)
                }
                .help("How storage locations work")
                .accessibilityLabel("About storage locations")
                .accessibilityIdentifier("StorageLocationsInfoButton")

                Button(action: toggleStorageLocations) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 8)

                        storageLocationSelectionSummary
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showStorageLocations ? "Hide organization locations" : "Show organization locations")
                .accessibilityLabel(showStorageLocations ? "Hide storage locations" : "Show storage locations")

                Button(action: toggleStorageLocations) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showStorageLocations ? 180 : 0))
                        .animation(
                            reduceMotion ? nil : .smooth(duration: 0.28),
                            value: showStorageLocations
                        )
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showStorageLocations ? "Hide organization locations" : "Show organization locations")
                .accessibilityLabel(showStorageLocations ? "Collapse storage locations" : "Expand storage locations")
                .accessibilityIdentifier("StorageLocationsDisclosureButton")
            }
            
            if showStorageLocations {
                VStack(alignment: .leading, spacing: 10) {
                    if !storageLocationsManager.locations.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(storageLocationsManager.locations) { location in
                                CompactStorageLocationRow(location: location)
                                    .transition(storageLocationRowTransition)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .animation(storageLocationInsertionAnimation, value: storageLocationListIDs)
                    }
                    
                    HStack(alignment: .center, spacing: 14) {
                        if storageLocationsManager.locations.isEmpty {
                            Spacer()
                        }

                        Button {
                            HapticFeedbackManager.shared.tap()
                            suggestedLocationName = nil
                            showingFolderPicker = true
                        } label: {
                            Label {
                                Text("Add Custom Location")
                            } icon: {
                                Image(systemName: "plus")
                                    .rotationEffect(.degrees(showingFolderPicker ? 45 : 0))
                                    .animation(
                                        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72),
                                        value: showingFolderPicker
                                    )
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.sortyBordered)
                        .controlSize(.small)
                        .help("Add a folder that Sorty can organize with")
                        .accessibilityHint("Opens the folder picker to add an organization location")

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(
                        storageLocationInsertionAnimation,
                        value: storageLocationsManager.locations.isEmpty
                    )
                    .padding(.top, 2)
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var storageLocationSelectionSummary: some View {
        ZStack(alignment: .trailing) {
            Group {
                if selectedStorageLocationCount > 0 {
                    HStack(spacing: 8) {
                        Text("\(selectedStorageLocationCount) selected")
                            .font(.caption)
                            .foregroundStyle(storageLocationSelectionTint)
                            .numericTextTransition(animationValue: selectedStorageLocationCount)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .systemLiquidGlassBackground(cornerRadius: 999)

                        if unavailableSelectedStorageLocationCount > 0 {
                            Text("\(unavailableSelectedStorageLocationCount) unavailable")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .numericTextTransition(
                                    animationValue: unavailableSelectedStorageLocationCount
                                )
                        }
                    }
                } else if !storageLocationsManager.locations.isEmpty {
                    Text("No active locations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No locations configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .id(storageLocationSummaryID)
            .transition(storageLocationSummaryTransition)
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.26, dampingFraction: 0.86),
            value: storageLocationSummaryID
        )
        .accessibilityElement(children: .combine)
    }
    
    @ViewBuilder
    private var iconSection: some View {
        if let image = SortyResources.image(named: "ReadyToOrganizeIcon") {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .clipShape(Circle())
                .accessibilityLabel("Sorty is ready to \(mode.actionVerb.lowercased())")
        } else {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 104, height: 104)
                .accessibilityLabel("Sorty is ready to \(mode.actionVerb.lowercased())")
        }
    }
    
    @ViewBuilder
    private var connectionStatusView: some View {
        HStack(spacing: 6) {
            if sessionManager.prewarmingProvider != nil {
                SortyGradientCircularLoader(size: 12, lineWidth: 2.2)
                    .frame(width: 12, height: 12)
                Text("Connecting to \(settingsViewModel.config.provider.displayName)...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if sessionManager.isPrewarmed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text("Connected to \(settingsViewModel.config.provider.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let error = sessionManager.prewarmError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("Connection warning: \(error.prefix(40))...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(height: 16)
        .help("Current AI connection state")
        .accessibilityLabel("Connection status")
        .accessibilityHint("Shows whether Sorty can reach the selected AI provider")
    }
    
    private var instructionsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            let mention = activeFileMention

            ZStack(alignment: .topLeading) {
                if isImprovingPrompt {
                    HStack {
                        Spacer()
                        SortyGradientCircularLoader(size: 13, lineWidth: 2.4)
                        Text("Improving...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 20)
                } else {
                    RotatingInstructionSuggestionEditor(
                        text: $organizer.customInstructions,
                        isFocused: $isTextFieldFocused,
                        selectedRange: $instructionSelection,
                        suggestions: instructionSuggestions,
                        onSubmit: onStart
                    )
                }
            }
            .frame(minHeight: 60, maxHeight: 80)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)

                FocusedInstructionBeamBorder(active: isTextFieldFocused)
            }
            .accessibilityIdentifier("CustomInstructionsTextField")
            .accessibilityLabel("Additional instructions for \(mode.gerund)")
            .accessibilityHint(
                organizer.customInstructions.isEmpty
                    ? "Press Tab to use the suggested instruction, Command+Enter to start \(mode.gerund), or Enter for a new line"
                    : "Press Command+Enter to start \(mode.gerund), or Enter for a new line"
            )
            .overlay(alignment: .bottomLeading) {
                if let mention, shouldShowReferencePicker(for: mention) {
                    InstructionFileReferencePicker(
                        matches: referenceMatches(for: mention.query),
                        query: mention.query,
                        onSelect: { reference in
                            insertReference(reference, replacing: mention)
                        }
                    )
                    .offset(y: 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
                    .zIndex(4)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: mention?.query)

            HStack(alignment: .center, spacing: 0) {
                // Improve with AI button
                if !organizer.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        Task { await improvePromptWithAI() }
                    } label: {
                        Label("Improve", systemImage: "wand.and.stars")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.teal)
                    .disabled(isImprovingPrompt)
                    .help("Improve instructions with Sorty")
                    .accessibilityHint("Rewrites your prompt to be clearer and more specific")
                    .alert("Sorty needs more detail", isPresented: $showImprovePromptRequest) {
                        Button("Edit Instructions") {
                            isTextFieldFocused = true
                        }
                    } message: {
                        Text("\(improvePromptRequestMessage)\n\nEdit the instructions above, then click Improve again.")
                    }
                }

                // Save prompt button
                if !organizer.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        savePromptName = ""
                        showSavePromptDialog.toggle()
                    } label: {
                        Label("Save", systemImage: "bookmark")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .help("Save current instructions for reuse")
                    .accessibilityHint("Stores this prompt in your saved prompts list")
                    .popover(isPresented: $showSavePromptDialog) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Save Prompt")
                                .font(.headline)

                            TextField("Prompt name", text: $savePromptName)
                                .textFieldStyle(.roundedBorder)

                            if steeringManager.hasPrompt(named: savePromptName) {
                                Text("A prompt with this name already exists.")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }

                            HStack {
                                Button("Cancel") {
                                    showSavePromptDialog = false
                                }
                                .buttonStyle(.sortyBordered)

                                Spacer()

                                Button("Save") {
                                    let prompt = SavedSteeringPrompt(
                                        name: savePromptName.isEmpty ? "Untitled" : savePromptName,
                                        prompt: organizer.customInstructions
                                    )
                                    steeringManager.addPrompt(prompt)
                                    showSavePromptDialog = false
                                    HapticFeedbackManager.shared.success()
                                }
                                .buttonStyle(.sortyProminent)
                                .disabled(
                                    savePromptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        || steeringManager.hasPrompt(named: savePromptName)
                                )
                            }
                        }
                        .padding(16)
                        .frame(width: 280)
                        .foregroundStyle(.primary)
                        .systemLiquidGlassPopover(cornerRadius: 12)
                    }
                }

                // Manage saved prompts button
                Button {
                    showSavedPromptsSheet.toggle()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)
                            .accessibilityHidden(true)

                        Text(
                            steeringManager.prompts.isEmpty
                                ? "Saved Prompts"
                                : "Saved Prompts (\(steeringManager.prompts.count))"
                        )
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .systemLiquidGlassBackground(cornerRadius: 12)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                Color.accentColor.opacity(0.18),
                                lineWidth: 1
                            )
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Open your saved instruction prompts")
                .accessibilityHint("View, edit, and apply saved prompts")

                Spacer()

                CompactPersonaPicker()
            }
            .font(.caption2)
            .foregroundStyle(.quaternary)
        }
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
    }

    private func improvePromptWithAI() async {
        let original = organizer.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return }
        isImprovingPrompt = true
        defer { isImprovingPrompt = false }

        do {
            let client = try AIClientFactory.createClient(config: settingsViewModel.config)
            let outcome = try await ImproveInstructionsTool.run(
                client: client,
                originalInstructions: original,
                workflow: mode.gerund
            )

            switch outcome {
            case .replacement(let improved):
                organizer.customInstructions = improved
                showImprovePromptRequest = false
                HapticFeedbackManager.shared.success()
            case .needsUserInput(let message):
                improvePromptRequestMessage = message
                showImprovePromptRequest = true
                HapticFeedbackManager.shared.selection()
            }
        } catch {
            HapticFeedbackManager.shared.error()
        }
    }

    private var activeFileMention: InstructionMentionQuery? {
        InstructionMentionQuery.active(in: organizer.customInstructions, selectedRange: instructionSelection)
    }

    private func shouldShowReferencePicker(for mention: InstructionMentionQuery) -> Bool {
        isTextFieldFocused && !mention.query.isEmpty && !referenceMatches(for: mention.query).isEmpty
    }

    private func referenceMatches(for query: String) -> [InstructionFileReference] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let matches: [InstructionFileReference]

        if normalizedQuery.isEmpty {
            matches = Array(referenceableFiles.prefix(8))
        } else {
            let prefixMatches = referenceableFiles.filter {
                $0.name.localizedLowercase.hasPrefix(normalizedQuery)
            }
            let containedMatches = referenceableFiles.filter {
                !$0.name.localizedLowercase.hasPrefix(normalizedQuery) &&
                $0.name.localizedLowercase.localizedStandardContains(normalizedQuery)
            }
            matches = Array((prefixMatches + containedMatches).prefix(8))
        }

        return matches
    }

    private func insertReference(_ reference: InstructionFileReference, replacing mention: InstructionMentionQuery) {
        var instructions = organizer.customInstructions

        let replacement = "@\(reference.displayToken)"
        instructions.replaceSubrange(mention.range, with: replacement)
        organizer.customInstructions = instructions
        instructionSelection = NSRange(location: mention.nsRange.location + (replacement as NSString).length, length: 0)
        HapticFeedbackManager.shared.selection()
    }

    private func scheduleReferenceableFilesRefresh() {
        referenceRefreshTask?.cancel()

        guard let directory = appState.selectedDirectory else {
            referenceableFiles = []
            return
        }

        referenceRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }

            let files = await Self.loadReferenceableFiles(in: directory)
            guard !Task.isCancelled else { return }
            referenceableFiles = files
            referenceRefreshTask = nil
        }
    }

    private nonisolated static func loadReferenceableFiles(in directory: URL) async -> [InstructionFileReference] {
        await Task.detached(priority: .utility) {
            referenceableFiles(in: directory)
        }.value
    }

    private nonisolated static func referenceableFiles(in directory: URL) -> [InstructionFileReference] {
        guard !Task.isCancelled else { return [] }

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: options
        ) else {
            return []
        }

        var files: [InstructionFileReference] = []
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { return [] }
            guard files.count < 400 else { break }
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
                  values.isRegularFile == true else { continue }

            files.append(
                InstructionFileReference(
                    url: url,
                    baseDirectory: directory,
                    fileSize: values.fileSize
                )
            )
        }

        return files.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

private struct InstructionMentionQuery: Equatable {
    let range: Range<String.Index>
    let nsRange: NSRange
    let query: String

    static func active(in text: String, selectedRange: NSRange) -> InstructionMentionQuery? {
        guard selectedRange.length == 0 else { return nil }
        guard selectedRange.location <= (text as NSString).length else { return nil }
        let cursor = String.Index(utf16Offset: selectedRange.location, in: text)
        let prefix = text[..<cursor]
        guard let atIndex = prefix.lastIndex(of: "@") else { return nil }
        let afterAt = text.index(after: atIndex)
        let query = String(text[afterAt..<cursor])

        guard !query.contains(where: \.isNewline) else { return nil }
        guard query.rangeOfCharacter(from: CharacterSet(charactersIn: ",;()[]{}")) == nil else { return nil }
        guard query.count <= 80 else { return nil }
        if let characterBeforeAt = text[..<atIndex].last,
           !characterBeforeAt.isWhitespace,
           !",;([{".contains(characterBeforeAt) {
            return nil
        }

        let range = atIndex..<cursor
        return InstructionMentionQuery(
            range: range,
            nsRange: NSRange(range, in: text),
            query: query
        )
    }
}

private struct InstructionFileReference: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let name: String
    let relativePath: String
    let fileSize: Int?

    init(url: URL, baseDirectory: URL, fileSize: Int?) {
        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.fileSize = fileSize

        let basePath = baseDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(basePath + "/") {
            self.relativePath = String(path.dropFirst(basePath.count + 1))
        } else {
            self.relativePath = url.lastPathComponent
        }
    }

    var displayToken: String {
        let token = relativePath
        return token.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;()[]{}"))) == nil ? token : "\"\(token)\""
    }

    var subtitle: String {
        let folder = URL(fileURLWithPath: relativePath).deletingLastPathComponent().path
        if folder == "." || folder == "/" || folder.isEmpty {
            return formattedSize
        }
        return "\(folder) • \(formattedSize)"
    }

    private var formattedSize: String {
        guard let fileSize else { return "File" }
        return ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }
}

private struct InstructionFileReferencePicker: View {
    @SortyHotReload private var hotReload
    let matches: [InstructionFileReference]
    let query: String
    let onSelect: (InstructionFileReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "at")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)
                Text("Reference a file")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("↩ to insert")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            ForEach(matches) { reference in
                Button {
                    onSelect(reference)
                } label: {
                    HStack(spacing: 10) {
                        FileThumbnailView(url: reference.url, size: CGSize(width: 24, height: 24))
                            .frame(width: 24, height: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            highlightedName(reference.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)

                            Text(reference.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        if !reference.url.pathExtension.isEmpty {
                            Text(".\(reference.url.pathExtension)")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.teal.opacity(0.12), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reference \(reference.name)")
                .accessibilityHint("Adds this file reference to the instructions")
            }
        }
        .padding(6)
        .frame(width: 360)
        .systemLiquidGlassPopover(cornerRadius: 12)
        .shadow(color: .black.opacity(0.14), radius: 18, x: 0, y: 10)
    }

    private func highlightedName(_ name: String) -> Text {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty,
              let range = name.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(name)
        }

        let prefix = String(name[..<range.lowerBound])
        let match = String(name[range])
        let suffix = String(name[range.upperBound...])
        return Text(prefix) + Text(match).foregroundStyle(.teal) + Text(suffix)
    }
}

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
    @State private var isOn = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isOn ? 1.22 : 0.78)
            .opacity(isOn ? 0.88 : 0.35)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.58).repeatForever().delay(delay)) {
                    isOn = true
                }
            }
            .onChange(of: reduceMotion) { _, shouldReduceMotion in
                guard shouldReduceMotion else { return }
                withAnimation(nil) {
                    isOn = false
                }
            }
    }
}

// MARK: - Saved Prompts Sheet

struct SavedPromptsSheet: View {
    @SortyHotReload private var hotReload
    @ObservedObject var steeringManager: SteeringPromptManager
    let settingsConfig: AIConfig
    let onApplyPrompt: (String) -> Void

    @State private var editingSession: SavedPromptEditingSession?
    @State private var isEmptyStateVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    init(
        steeringManager: SteeringPromptManager,
        settingsConfig: AIConfig,
        onApplyPrompt: @escaping (String) -> Void
    ) {
        self.steeringManager = steeringManager
        self.settingsConfig = settingsConfig
        self.onApplyPrompt = onApplyPrompt
        _isEmptyStateVisible = State(initialValue: steeringManager.prompts.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Saved Prompts")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    closeSheet()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close saved prompts")
            }
            .padding(20)

            Divider()

            ZStack {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(savedPromptRows) { row in
                            SavedPromptListRow(
                                row: row,
                                editingSession: editingSession?.prompt.id == row.id
                                    ? editingSession
                                    : nil,
                                steeringManager: steeringManager,
                                settingsConfig: settingsConfig,
                                showsPinControls: showsPinControls,
                                onAction: handleRowAction,
                                onCancelEditing: cancelEditing,
                                onSaveEditing: saveEditingPrompt
                            )
                            .transition(savedPromptTransition)
                        }

                        if let editingSession, editingSession.isDraft {
                            SavedPromptEditorCard(
                                session: editingSession,
                                steeringManager: steeringManager,
                                settingsConfig: settingsConfig,
                                onCancel: cancelEditing,
                                onSave: saveEditingPrompt
                            )
                            .transition(savedPromptTransition)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .scrollIndicators(.visible)

                if isEmptyStateVisible && editingSession?.isDraft != true {
                    VStack(spacing: 16) {
                        Spacer()

                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.1))
                                .frame(width: 72, height: 72)

                            Image(systemName: "text.badge.plus")
                                .font(.title)
                                .foregroundStyle(Color.accentColor)
                                .symbolRenderingMode(.hierarchical)
                                .accessibilityHidden(true)
                        }

                        VStack(spacing: 6) {
                            Text("No saved prompts yet")
                                .font(.headline)

                            Text("Save your instructions from the organize view to reuse them.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 300)
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96)),
                            removal: .opacity.combined(with: .scale(scale: 1.02))
                        )
                    )
                }
            }

            Divider()

            // Footer
            HStack {
                Button("Add New Prompt") {
                    addNewPrompt()
                }
                .buttonStyle(.sortyBordered)
                .disabled(editingSession != nil)

                Spacer()

                Button("Done") {
                    closeSheet()
                }
                .buttonStyle(.sortyProminent)
                .keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .frame(width: 520, height: 500)
        .onChange(of: steeringManager.prompts.isEmpty) { _, isEmpty in
            if isEmpty {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24).delay(0.16)) {
                    isEmptyStateVisible = true
                }
            } else {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                    isEmptyStateVisible = false
                }
            }
        }
    }

    private var showsPinControls: Bool {
        steeringManager.prompts.count > 10
    }

    private var savedPromptRows: [SavedPromptRowContent] {
        let rows = steeringManager.prompts.map(SavedPromptRowContent.init)
        guard showsPinControls else { return rows }
        return rows.filter(\.isPinned) + rows.filter { !$0.isPinned }
    }

    private var savedPromptTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.97, anchor: .top))
                .combined(with: .offset(y: -6)),
            removal: .opacity
                .combined(with: .scale(scale: 0.97, anchor: .top))
                .combined(with: .offset(y: -6))
        )
    }

    private func addNewPrompt() {
        guard editingSession == nil else { return }

        var name = "New Prompt"
        var suffix = 2
        while steeringManager.hasPrompt(named: name) {
            name = "New Prompt \(suffix)"
            suffix += 1
        }

        let newPrompt = SavedSteeringPrompt(name: name, prompt: "")
        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82)) {
            editingSession = SavedPromptEditingSession(prompt: newPrompt, isDraft: true)
            isEmptyStateVisible = false
        }
        HapticFeedbackManager.shared.tap()
    }

    private func closeSheet() {
        let didSaveDraft = saveDraftIfNeeded(editingSession)
        editingSession = nil
        dismiss()
        if didSaveDraft {
            HapticFeedbackManager.shared.success()
        }
    }

    @discardableResult
    private func saveDraftIfNeeded(_ session: SavedPromptEditingSession?) -> Bool {
        guard let session, session.isDraft else { return false }
        guard !session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        var prompt = session.prompt
        prompt.name = session.name
        prompt.prompt = session.text
        return steeringManager.addPrompt(prompt)
    }

    private func cancelEditing(_ session: SavedPromptEditingSession) {
        var didSaveDraft = false
        withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.9)) {
            didSaveDraft = saveDraftIfNeeded(session)
            editingSession = nil
            if steeringManager.prompts.isEmpty {
                isEmptyStateVisible = true
            }
        }
        if didSaveDraft {
            HapticFeedbackManager.shared.success()
        }
    }

    private func saveEditingPrompt(_ session: SavedPromptEditingSession) {
        var prompt = session.prompt
        prompt.name = session.name
        prompt.prompt = session.text

        var didSave = false
        withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.9)) {
            didSave = session.isDraft
                ? steeringManager.addPrompt(prompt)
                : steeringManager.updatePrompt(prompt)
            if didSave {
                editingSession = nil
            }
        }
        guard didSave else { return }
        HapticFeedbackManager.shared.success()
    }

    private func handleRowAction(_ action: SavedPromptRowAction) {
        switch action {
        case .use(let id):
            guard let prompt = steeringManager.prompt(id: id) else { return }
            onApplyPrompt(prompt.prompt)
        case .edit(let id):
            beginEditing(id: id)
        case .togglePin(let id):
            togglePin(id: id)
        case .delete(let id):
            deletePrompt(id: id)
        }
    }

    private func beginEditing(id: UUID) {
        guard let prompt = steeringManager.prompt(id: id) else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.9)) {
            editingSession = SavedPromptEditingSession(prompt: prompt)
        }
    }

    private func togglePin(id: UUID) {
        guard showsPinControls, let prompt = steeringManager.prompt(id: id) else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.9)) {
            steeringManager.setPinned(!prompt.isPinned, id: id)
        }
        HapticFeedbackManager.shared.selection()
    }

    private func deletePrompt(id: UUID) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
            steeringManager.deletePrompt(id: id)
        }
        HapticFeedbackManager.shared.tap()
    }
}

@MainActor
private final class SavedPromptEditingSession: ObservableObject {
    let prompt: SavedSteeringPrompt
    let isDraft: Bool

    @Published var name: String
    @Published var text: String
    @Published var isImproving = false
    @Published var showImprovePromptRequest = false
    @Published var improvePromptRequestMessage = ""

    init(prompt: SavedSteeringPrompt, isDraft: Bool = false) {
        self.prompt = prompt
        self.isDraft = isDraft
        name = prompt.name
        text = prompt.prompt
    }
}

private struct SavedPromptRowContent: Identifiable, Equatable {
    let id: UUID
    let name: String
    let preview: String
    let isPinned: Bool

    init(prompt: SavedSteeringPrompt) {
        id = prompt.id
        name = Self.bounded(prompt.name, maximumCharacterCount: 120)
        preview = Self.bounded(prompt.prompt, maximumCharacterCount: 360)
        isPinned = prompt.isPinned
    }

    private static func bounded(_ text: String, maximumCharacterCount: Int) -> String {
        guard let endIndex = text.index(
            text.startIndex,
            offsetBy: maximumCharacterCount,
            limitedBy: text.endIndex
        ), endIndex != text.endIndex else {
            return text
        }

        return String(text[..<endIndex]) + "…"
    }
}

private enum SavedPromptRowAction {
    case use(UUID)
    case edit(UUID)
    case togglePin(UUID)
    case delete(UUID)
}

private struct SavedPromptListRow: View {
    @SortyHotReload private var hotReload
    let row: SavedPromptRowContent
    let editingSession: SavedPromptEditingSession?
    let steeringManager: SteeringPromptManager
    let settingsConfig: AIConfig
    let showsPinControls: Bool
    let onAction: (SavedPromptRowAction) -> Void
    let onCancelEditing: (SavedPromptEditingSession) -> Void
    let onSaveEditing: (SavedPromptEditingSession) -> Void

    var body: some View {
        Group {
            if let editingSession {
                SavedPromptEditorCard(
                    session: editingSession,
                    steeringManager: steeringManager,
                    settingsConfig: settingsConfig,
                    onCancel: onCancelEditing,
                    onSave: onSaveEditing
                )
            } else {
                SavedPromptDisplayCard(
                    row: row,
                    showsPinControls: showsPinControls,
                    onAction: onAction
                )
            }
        }
    }
}

private struct SavedPromptDisplayCard: View {
    @SortyHotReload private var hotReload
    let row: SavedPromptRowContent
    let showsPinControls: Bool
    let onAction: (SavedPromptRowAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if showsPinControls && row.isPinned {
                        Label("Pinned", systemImage: "pin.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                }

                Text(verbatim: row.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
            }

            HStack(spacing: 8) {
                Button("Use") {
                    onAction(.use(row.id))
                }
                .buttonStyle(SavedPromptRowButtonStyle(isProminent: true))

                Button("Edit") {
                    onAction(.edit(row.id))
                }
                .buttonStyle(SavedPromptRowButtonStyle())

                if showsPinControls {
                    Button(row.isPinned ? "Unpin" : "Pin") {
                        onAction(.togglePin(row.id))
                    }
                    .buttonStyle(SavedPromptRowButtonStyle())
                }

                Spacer()

                Button(role: .destructive) {
                    onAction(.delete(row.id))
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(SavedPromptRowButtonStyle())
                .accessibilityLabel("Delete \(row.name)")
            }
        }
        .savedPromptCardSurface()
    }
}

private struct SavedPromptRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        let isDestructive = configuration.role == .destructive
        let foregroundColor: Color = if isProminent {
            .white
        } else if isDestructive {
            SortyDesignSystem.Colors.error
        } else {
            .primary
        }

        configuration.label
            .font(.caption.weight(isProminent ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        isProminent
                            ? Color.accentColor.opacity(configuration.isPressed ? 0.78 : 0.9)
                            : Color(NSColor.controlBackgroundColor).opacity(configuration.isPressed ? 0.7 : 0.42)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isProminent
                            ? Color.white.opacity(0.24)
                            : foregroundColor.opacity(0.22),
                        lineWidth: 1
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.52)
            .animation(
                reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82),
                value: configuration.isPressed
            )
    }
}

private struct SavedPromptEditorCard: View {
    @SortyHotReload private var hotReload
    @ObservedObject var session: SavedPromptEditingSession
    let steeringManager: SteeringPromptManager
    let settingsConfig: AIConfig
    let onCancel: (SavedPromptEditingSession) -> Void
    let onSave: (SavedPromptEditingSession) -> Void

    @FocusState private var isEditTextFocused: Bool
    @State private var improveTask: Task<Void, Never>?

    var body: some View {
        let hasDuplicateName = steeringManager.hasPrompt(
            named: session.name,
            excluding: session.prompt.id
        )

        VStack(alignment: .leading, spacing: 12) {
            TextField("Prompt name", text: $session.name)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline.weight(.medium))

            if hasDuplicateName {
                Text("A prompt with this name already exists.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            TextEditor(text: $session.text)
                .font(.body)
                .focused($isEditTextFocused)
                .frame(minHeight: 100, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )

            HStack(spacing: 8) {
                Button {
                    startImprovingInstructions()
                } label: {
                    if session.isImproving {
                        SortyGradientCircularLoader(size: 12, lineWidth: 2.2)
                    } else {
                        Label("Improve with Sorty", systemImage: "wand.and.stars")
                    }
                }
                .buttonStyle(.sortyBordered)
                .controlSize(.small)
                .disabled(
                    session.text.trimmingCharacters(in: .whitespaces).isEmpty
                        || session.isImproving
                )
                .alert(
                    "Sorty needs more detail",
                    isPresented: $session.showImprovePromptRequest
                ) {
                    Button("Edit Instructions") {
                        isEditTextFocused = true
                    }
                } message: {
                    Text(
                        "\(session.improvePromptRequestMessage)\n\nEdit the instructions above, then click Improve again."
                    )
                }

                Spacer()

                Button("Cancel") {
                    onCancel(session)
                }
                .controlSize(.small)

                Button("Save") {
                    onSave(session)
                }
                .buttonStyle(.sortyProminent)
                .controlSize(.small)
                .disabled(
                    session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || hasDuplicateName
                )
            }
        }
        .savedPromptCardSurface()
        .onDisappear {
            improveTask?.cancel()
        }
    }

    private func startImprovingInstructions() {
        improveTask?.cancel()
        improveTask = Task {
            await improveInstructions()
        }
    }

    private func improveInstructions() async {
        let original = session.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return }
        session.isImproving = true
        defer { session.isImproving = false }

        do {
            try Task.checkCancellation()
            let client = try AIClientFactory.createClient(config: settingsConfig)
            let outcome = try await ImproveInstructionsTool.run(
                client: client,
                originalInstructions: original,
                workflow: "organization"
            )
            try Task.checkCancellation()

            switch outcome {
            case .replacement(let replacement):
                session.text = replacement
                session.showImprovePromptRequest = false
                HapticFeedbackManager.shared.success()
            case .needsUserInput(let message):
                session.improvePromptRequestMessage = message
                session.showImprovePromptRequest = true
                HapticFeedbackManager.shared.tap()
            }
        } catch is CancellationError {
            return
        } catch {
            HapticFeedbackManager.shared.error()
        }
    }
}

private extension View {
    func savedPromptCardSurface() -> some View {
        padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
            )
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

// MARK: - Error View

struct ErrorView: View {
    @SortyHotReload private var hotReload
    let error: Error
    var canResume = false
    var onResume: () -> Void = {}
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRetryWithSmarterModel: () -> Void
    let onGrantPermission: () -> Void

    private enum ErrorActionFeedback {
        case cancel
        case retry
        case settings
        case grantPermission
        case copy
        case helpSupport
    }

    @State private var showRetryOptions = false
    @State private var showCopiedFeedback = false
    @State private var isHoveringCancel = false
    @State private var isHoveringHelpSupport = false
    @State private var isHoveringSettings = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var activeActionFeedback: ErrorActionFeedback?
    @State private var actionFeedbackResetTask: Task<Void, Never>?
    @State private var retryAnimationTrigger = 0
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    private enum ErrorCategory: Equatable {
        case internetPrivacy
        case apiKey
        case network
        case permissions
        case generic
    }
    
    private var category: ErrorCategory {
        let description = error.localizedDescription.lowercased()
        if let aiError = error as? AIClientError, aiError.isInternetAccessBlocked {
            return .internetPrivacy
        }
        if description.contains("block internet connections")
            || description.contains("internet access is blocked") {
            return .internetPrivacy
        }
        if description.contains("api key") || description.contains("unauthorized") || description.contains("authentication") {
            return .apiKey
        }
        if description.contains("network") || description.contains("internet") || description.contains("offline") || isTimeoutError {
            return .network
        }
        if description.contains("permission") || description.contains("access") || description.contains("sandbox") {
            return .permissions
        }
        return .generic
    }

    private var isTimeoutError: Bool {
        let description = error.localizedDescription.lowercased()
        return description.contains("timeout") || description.contains("timed out")
    }
    
    private var errorIcon: String {
        switch category {
        case .internetPrivacy:
            return "network.slash"
        case .apiKey:
            return "key.fill"
        case .network:
            return "wifi.exclamationmark"
        case .permissions:
            return "lock.trianglebadge.exclamationmark"
        case .generic:
            return "exclamationmark.triangle.fill"
        }
    }
    
    private var errorTitle: String {
        switch category {
        case .internetPrivacy:
            return "Internet Access Blocked"
        case .apiKey:
            return "AI Credentials Required"
        case .network:
            return "Connection Problem"
        case .permissions:
            return "Permission Required"
        case .generic:
            return "Something Went Wrong"
        }
    }
    
    private var recoveryText: String {
        switch category {
        case .internetPrivacy:
            return "Sorty stopped the request before it reached your AI provider. Turn off Block Internet Connections in Advanced Settings, then retry."
        case .apiKey:
            return "Check your provider and API key in Settings, then retry."
        case .network:
            if isTimeoutError {
                return "If your connection is stable, a slower provider may need more time."
            }
            return "Check your internet connection and provider availability, then retry."
        case .permissions:
            return "Grant file access for this folder and try again."
        case .generic:
            if planGenerationFailureCode == "PATH_CONFLICT" {
                return "Sorty found duplicate destination folders in the generated plan. Retry and Sorty will rebuild the plan without moving any files."
            }
            return "Choose a smarter model, then retry."
        }
    }

    private var showsSettingsChevron: Bool {
        isHoveringSettings || activeActionFeedback == .settings
    }

    private var showsCancelCircle: Bool {
        isHoveringCancel || activeActionFeedback == .cancel
    }

    private var showsHelpSupportChevron: Bool {
        isHoveringHelpSupport || activeActionFeedback == .helpSupport
    }

    private var privacySafeSupportDetails: String {
        """
        Sorty Error Report

        Error: \(errorTitle)
        Category: \(privacySafeCategoryName)
        \(privacySafeErrorCodeLine)
        Summary: \(privacySafeErrorSummary)
        Suggested action: \(privacySafeSuggestedAction)
        Workflow: \(settingsViewModel.config.mode.displayName)
        Provider: \(settingsViewModel.config.provider.displayName)
        Sorty: \(BuildInfo.fullVersion)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
    }

    private var privacySafeCategoryName: String {
        switch category {
        case .internetPrivacy:
            return "Internet privacy"
        case .apiKey:
            return "AI credentials"
        case .network:
            return "Network connection"
        case .permissions:
            return "File permissions"
        case .generic:
            return "Plan generation"
        }
    }

    private var privacySafeErrorSummary: String {
        switch category {
        case .internetPrivacy:
            return "Sorty blocked the request locally before it reached the selected AI provider."
        case .apiKey:
            return "Sorty couldn't authenticate with the selected AI provider."
        case .network:
            if isTimeoutError {
                return "The selected AI provider didn't respond before the request timeout."
            }
            return "Sorty couldn't reach the selected AI provider."
        case .permissions:
            return "Sorty couldn't access a required folder."
        case .generic:
            switch planGenerationFailureCode {
            case "OUTPUT_LIMIT":
                return "The selected model couldn't finish a complete organization plan within its output limit."
            case "INVALID_PLAN":
                return "The selected model returned a response that Sorty couldn't convert into a complete organization plan."
            case "PATH_CONFLICT":
                return "Sorty found two generated folders that resolve to the same destination path."
            default:
                return "Sorty couldn't create an organization plan."
            }
        }
    }

    private var privacySafeSuggestedAction: String {
        switch category {
        case .internetPrivacy:
            return "Open Advanced Settings, turn off Block Internet Connections, then retry."
        case .apiKey:
            return "Check the selected provider and its API key in Settings, then retry."
        case .network:
            if isTimeoutError {
                return "Check the internet connection, then review timeout settings before retrying."
            }
            return "Check the internet connection and provider availability, then retry."
        case .permissions:
            return "Grant access to the required folder, then retry."
        case .generic:
            if planGenerationFailureCode == "OUTPUT_LIMIT" {
                return "Retry to let Sorty process fewer files at a time, or choose a model with a larger output limit."
            }
            if planGenerationFailureCode == "INVALID_PLAN" {
                return "Retry to let Sorty process fewer files at a time. If it still fails, choose a more capable model."
            }
            if planGenerationFailureCode == "PATH_CONFLICT" {
                return "Retry to rebuild and merge duplicate destinations safely. No files were moved."
            }
            return "Choose a smarter model and retry. If it still fails, simplify Instructions or Persona, then review Learnings, workflow, and organization rules."
        }
    }

    private var privacySafeErrorCodeLine: String {
        if category == .internetPrivacy {
            return "Code: \(AIClientError.internetAccessBlockedCode)"
        }
        guard let planGenerationFailureCode else { return "" }
        return "Code: \(planGenerationFailureCode)"
    }

    private var planGenerationFailureCode: String? {
        guard category == .generic else { return nil }
        if let validationError = error as? ValidationError,
           case .pathConflict = validationError {
            return "PATH_CONFLICT"
        }
        if let clientError = error as? AIClientError {
            switch clientError {
            case .invalidResponseFormat, .jsonDecodingError:
                return "INVALID_PLAN"
            case .apiError(let statusCode, let message):
                let description = message.lowercased()
                if statusCode == 413 ||
                    description.contains("output limit") ||
                    description.contains("context length") ||
                    description.contains("maximum context") ||
                    description.contains("max_tokens") ||
                    description.contains("too many tokens") {
                    return "OUTPUT_LIMIT"
                }
            default:
                break
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.1))
                    .frame(width: 100, height: 100)

                Image(systemName: errorIcon)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.red)
                    .animatedEmptyStateIcon(tint: .red)
            }

            VStack(spacing: 8) {
                Text(errorTitle)
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(error.localizedDescription)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)

                recoveryGuidance
            }

            HStack(spacing: 12) {
                if canResume && category == .network && isTimeoutError {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        onResume()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Continue \(settingsViewModel.config.mode.displayName)")
                                .font(.caption.bold())
                        }
                    }
                    .buttonStyle(.tintedPill(.accentColor, size: .small))
                    .help("Continue from the last completed part of this organization")
                    .accessibilityIdentifier("ErrorContinueOrganizationButton")
                }

                Button {
                    HapticFeedbackManager.shared.tap()
                    animateActionFeedback(.cancel)
                    onCancel()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showsCancelCircle ? "xmark.circle.fill" : "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .transaction { transaction in
                                if reduceMotion {
                                    transaction.disablesAnimations = true
                                }
                            }
                        Text("Cancel")
                            .font(.caption.bold())
                    }
                }
                .buttonStyle(.tintedPill(.red, size: .small))
                .scaleEffect(activeActionFeedback == .cancel ? 1.04 : 1.0)
                .help("Return to folder selection")
                .accessibilityIdentifier("ErrorBackToFolderPickerButton")
                .onHover { hovering in
                    withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
                        isHoveringCancel = hovering
                    }
                }

                Button {
                    HapticFeedbackManager.shared.tap()
                    animateActionFeedback(.retry)
                    if !reduceMotion {
                        retryAnimationTrigger += 1
                    }
                    showRetryOptions = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .symbolEffect(.rotate, options: .speed(1.5), value: retryAnimationTrigger)
                        Text("Retry")
                            .font(.caption.bold())
                    }
                }
                .buttonStyle(.tintedPill(.accentColor, size: .small))
                .scaleEffect(activeActionFeedback == .retry ? 1.04 : 1.0)
                .help("Choose how to retry this organization")
                .accessibilityIdentifier("ErrorTryAgainButton")
                .modelSelectorTriggerBounds()
                .onHover { hovering in
                    if hovering && !reduceMotion {
                        retryAnimationTrigger += 1
                    }
                }

                if category == .network && isTimeoutError {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        animateActionFeedback(.settings)
                        appState.openSettingsWindow(
                            section: .advanced,
                            focusTarget: .advancedTimeouts
                        )
                        appState.navigatedFromSettings = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 10, weight: .semibold))
                                .symbolEffect(.bounce, value: activeActionFeedback == .settings)
                            Text("Timeout Settings")
                                .font(.caption.bold())
                        }
                    }
                    .buttonStyle(.tintedPill(.indigo, size: .small))
                    .scaleEffect(activeActionFeedback == .settings ? 1.04 : 1.0)
                    .help("Open Advanced Settings and focus the timeout controls")
                    .accessibilityHint("Opens the request and resource timeout controls")
                    .accessibilityIdentifier("ErrorOpenTimeoutSettingsButton")
                }

                if category == .internetPrivacy {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        animateActionFeedback(.settings)
                        appState.openSettingsWindow(
                            section: .advanced,
                            focusTarget: .advancedInternetPrivacy
                        )
                        appState.navigatedFromSettings = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showsSettingsChevron ? "arrow.up.right" : "network")
                                .font(.system(size: 10, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                                .transaction { transaction in
                                    if reduceMotion {
                                        transaction.disablesAnimations = true
                                    }
                                }
                            Text("Internet Settings")
                                .font(.caption.bold())
                        }
                    }
                    .buttonStyle(.tintedPill(.indigo, size: .small))
                    .scaleEffect(activeActionFeedback == .settings ? 1.04 : 1.0)
                    .help("Open Advanced Settings and focus Block Internet Connections")
                    .accessibilityHint(
                        "Opens the setting that prevents Sorty from contacting cloud providers"
                    )
                    .accessibilityIdentifier("ErrorOpenInternetSettingsButton")
                    .onHover { hovering in
                        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
                            isHoveringSettings = hovering
                        }
                    }
                }

                if category == .apiKey {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        animateActionFeedback(.settings)
                        appState.openSettingsWindow(section: .provider)
                        appState.navigatedFromSettings = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showsSettingsChevron ? "arrow.up.right" : "gearshape")
                                .font(.system(size: 10, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                                .transaction { transaction in
                                    if reduceMotion {
                                        transaction.disablesAnimations = true
                                    }
                                }
                            Text("Settings")
                                .font(.caption.bold())
                        }
                    }
                    .buttonStyle(.tintedPill(.indigo, size: .small))
                    .scaleEffect(activeActionFeedback == .settings ? 1.04 : 1.0)
                    .help("Open Settings to resolve this issue")
                    .accessibilityIdentifier("ErrorOpenSettingsButton")
                    .onHover { hovering in
                        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
                            isHoveringSettings = hovering
                        }
                    }
                }

                if category == .permissions {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        animateActionFeedback(.grantPermission)
                        onGrantPermission()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 10, weight: .semibold))
                                .symbolEffect(
                                    .bounce,
                                    value: activeActionFeedback == .grantPermission
                                )
                            Text("Grant Permission")
                                .font(.caption.bold())
                        }
                    }
                    .buttonStyle(.tintedPill(.indigo, size: .small))
                    .scaleEffect(activeActionFeedback == .grantPermission ? 1.04 : 1.0)
                    .help("Grant access to this folder and continue organizing")
                    .accessibilityHint(
                        "Opens the folder picker, then continues organization after access is granted"
                    )
                    .accessibilityIdentifier("ErrorGrantPermissionButton")

                    Button {
                        HapticFeedbackManager.shared.tap()
                        animateActionFeedback(.settings)
                        appState.openSettingsWindow(section: .permissions)
                        appState.navigatedFromSettings = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .symbolEffect(
                                    .bounce,
                                    value: activeActionFeedback == .settings
                                )
                            Text("Permissions")
                                .font(.caption.bold())
                        }
                    }
                    .buttonStyle(.tintedPill(.purple, size: .small))
                    .scaleEffect(activeActionFeedback == .settings ? 1.04 : 1.0)
                    .help("Review all permissions in Sorty Settings")
                    .accessibilityHint(
                        "Opens the Permissions page at the permission status overview"
                    )
                    .accessibilityIdentifier("ErrorOpenPermissionsButton")
                }

                if category == .generic {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        animateActionFeedback(.helpSupport)
                        appState.openSettingsWindow(section: .help)
                        appState.navigatedFromSettings = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(
                                systemName: showsHelpSupportChevron
                                    ? "arrow.up.right"
                                    : "questionmark.circle.fill"
                            )
                                .font(.system(size: 10, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                                .transaction { transaction in
                                    if reduceMotion {
                                        transaction.disablesAnimations = true
                                    }
                                }
                            Text("Help & Support")
                                .font(.caption.bold())
                        }
                    }
                    .buttonStyle(.tintedPill(.green, size: .small))
                    .scaleEffect(activeActionFeedback == .helpSupport ? 1.04 : 1.0)
                    .help("Open Help & Support")
                    .accessibilityHint("Opens the Help and Support settings page")
                    .accessibilityIdentifier("ErrorHelpSupportButton")
                    .onHover { hovering in
                        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
                            isHoveringHelpSupport = hovering
                        }
                    }
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(privacySafeSupportDetails, forType: .string)
                    HapticFeedbackManager.shared.selection()
                    animateActionFeedback(.copy)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                        showCopiedFeedback = true
                    }
                    copyResetTask?.cancel()
                    copyResetTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                            showCopiedFeedback = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showCopiedFeedback ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                            .symbolReplaceTransition(animationValue: showCopiedFeedback)
                            .symbolEffect(.bounce, value: activeActionFeedback == .copy)
                        Text(showCopiedFeedback ? "Copied" : "Copy")
                            .font(.caption.bold())
                            .numericTextTransition(animationValue: showCopiedFeedback)
                    }
                }
                .buttonStyle(.tintedPill(.orange, size: .small))
                .scaleEffect(showCopiedFeedback || activeActionFeedback == .copy ? 1.04 : 1.0)
                .help("Copy a privacy-safe error report for support")
                .accessibilityHint(
                    "Copies diagnostics without private file, instruction, prompt, or credential data"
                )
                .accessibilityIdentifier("ErrorCopyDetailsButton")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .confirmationDialog(
            "Retry Options",
            isPresented: $showRetryOptions,
            titleVisibility: .visible
        ) {
            Button("Choose Smarter Model") {
                HapticFeedbackManager.shared.tap()
                onRetryWithSmarterModel()
            }

            Button("Retry with Current Model") {
                HapticFeedbackManager.shared.tap()
                onRetry()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A stronger model is more likely to return the structured plan Sorty needs.")
        }
    }

    @ViewBuilder
    private var recoveryGuidance: some View {
        if category == .generic {
            VStack(spacing: 6) {
                Text(recoveryText)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Text("If it still fails, simplify your Instructions or Persona, then review Learnings, workflow, and organization rules.")

                Text("Still stuck? Copy the details and open Help & Support.")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)
        } else {
            Text(recoveryText)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
        }
    }

    private func animateActionFeedback(_ action: ErrorActionFeedback) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
            activeActionFeedback = action
        }

        actionFeedbackResetTask?.cancel()
        actionFeedbackResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 240_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                activeActionFeedback = nil
            }
        }
    }
}

struct FocusedInstructionBeamBorder: View {
    @SortyHotReload private var hotReload
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SwiftUI.TimelineView(.animation(paused: reduceMotion || !active)) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate / 1.96

            RoundedRectangle(cornerRadius: 10, style: .continuous)
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
                    lineWidth: 1.2
                )
                .opacity(active ? 0.95 : 0)
                .animation(.easeOut(duration: 0.2), value: active)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Custom Text Editor with Enter to Submit

/// A TextEditor that treats Cmd+Enter as submit and Enter as new line
private struct RotatingInstructionSuggestionEditor: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var selectedRange: NSRange
    let suggestions: [String]
    let onSubmit: () -> Void

    @State private var suggestionIndex = 0

    private var currentSuggestion: String {
        suggestions[suggestionIndex % suggestions.count]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SubmittableTextEditor(
                text: $text,
                isFocused: $isFocused,
                selectedRange: $selectedRange,
                onAcceptSuggestion: acceptCurrentSuggestion,
                onSubmit: onSubmit
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 2)

            if text.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Text(currentSuggestion)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .numericTextTransition(animationValue: suggestionIndex)

                    Spacer(minLength: 0)

                    Text("Tab")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Color.secondary.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .accessibilityHidden(true)
                }
                .padding(.leading, 18)
                .padding(.trailing, 10)
                .padding(.vertical, 9)
                .allowsHitTesting(false)
            }
        }
        .task(id: suggestions) {
            suggestionIndex = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3.5))
                guard !Task.isCancelled else { return }
                suggestionIndex = (suggestionIndex + 1) % suggestions.count
            }
        }
    }

    private func acceptCurrentSuggestion() -> Bool {
        guard text.isEmpty else { return false }
        text = currentSuggestion
        selectedRange = NSRange(location: (currentSuggestion as NSString).length, length: 0)
        HapticFeedbackManager.shared.selection()
        return true
    }
}

struct SubmittableTextEditor: NSViewRepresentable {
    @SortyHotReload private var hotReload
    @Binding var text: String
    var isFocused: Binding<Bool>?
    var selectedRange: Binding<NSRange>?
    var onAcceptSuggestion: (() -> Bool)?
    var onSubmit: () -> Void

    init(
        text: Binding<String>,
        isFocused: Binding<Bool>? = nil,
        selectedRange: Binding<NSRange>? = nil,
        onAcceptSuggestion: (() -> Bool)? = nil,
        onSubmit: @escaping () -> Void
    ) {
        self._text = text
        self.isFocused = isFocused
        self.selectedRange = selectedRange
        self.onAcceptSuggestion = onAcceptSuggestion
        self.onSubmit = onSubmit
    }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        
        textView.delegate = context.coordinator
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 7)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        context.coordinator.selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: textView,
            queue: .main
        ) { [weak textView, weak coordinator = context.coordinator] _ in
            guard let textView, let coordinator else { return }
            coordinator.updateFocusState(for: textView)
            coordinator.updateSelectedRange(from: textView)
        }
        
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak textView, weak coordinator = context.coordinator] event in
            guard let tv = textView else { return event }

            DispatchQueue.main.async {
                coordinator?.updateFocusState(for: tv)
            }

            guard event.type == .keyDown else { return event }
            guard tv.window?.firstResponder === tv else { return event }
            
            let isReturn = event.keyCode == 36
            let isTab = event.keyCode == 48
            let hasCommand = event.modifierFlags.contains(.command)
            let hasTabModifier = !event.modifierFlags
                .intersection([.command, .option, .control, .shift])
                .isEmpty
            
            if isReturn && hasCommand {
                context.coordinator.onSubmit()
                return nil
            }

            if isTab, !hasTabModifier, context.coordinator.onAcceptSuggestion?() == true {
                return nil
            }
            
            return event
        }
        context.coordinator.eventMonitor = monitor
        
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        
        if textView.string != text {
            let selectedRanges = selectedRange.map { [NSValue(range: $0.wrappedValue)] } ?? textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        } else if let selectedRange,
                  textView.selectedRange() != selectedRange.wrappedValue,
                  selectedRange.wrappedValue.location + selectedRange.wrappedValue.length <= (textView.string as NSString).length {
            textView.setSelectedRange(selectedRange.wrappedValue)
        }
        
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onAcceptSuggestion = onAcceptSuggestion
        context.coordinator.isFocused = isFocused
        context.coordinator.selectedRange = selectedRange

        context.coordinator.updateFocusState(for: textView)
        context.coordinator.updateSelectedRange(from: textView)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: isFocused,
            selectedRange: selectedRange,
            onAcceptSuggestion: onAcceptSuggestion,
            onSubmit: onSubmit
        )
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>?
        var selectedRange: Binding<NSRange>?
        var onAcceptSuggestion: (() -> Bool)?
        var onSubmit: () -> Void
        var eventMonitor: Any?
        var selectionObserver: NSObjectProtocol?
        
        init(
            text: Binding<String>,
            isFocused: Binding<Bool>?,
            selectedRange: Binding<NSRange>?,
            onAcceptSuggestion: (() -> Bool)?,
            onSubmit: @escaping () -> Void
        ) {
            self.text = text
            self.isFocused = isFocused
            self.selectedRange = selectedRange
            self.onAcceptSuggestion = onAcceptSuggestion
            self.onSubmit = onSubmit
        }
        
        deinit {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            updateSelectedRange(from: textView)
        }

        func textDidBeginEditing(_ notification: Notification) {
            isFocused?.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isFocused?.wrappedValue = false
        }

        func updateFocusState(for textView: NSTextView) {
            guard let isFocused else { return }
            let currentlyFocused = textView.window?.firstResponder === textView
            if isFocused.wrappedValue != currentlyFocused {
                isFocused.wrappedValue = currentlyFocused
            }
        }

        func updateSelectedRange(from textView: NSTextView) {
            guard let selectedRange else { return }
            let currentRange = textView.selectedRange()
            if selectedRange.wrappedValue != currentRange {
                selectedRange.wrappedValue = currentRange
            }
        }
    }
}

enum InstructionSuggestionCatalog {
    @MainActor
    static func suggestions(
        for mode: OrganizationMode,
        personaManager: PersonaManager,
        customPersonaStore: CustomPersonaStore
    ) -> [String] {
        let personaSuggestions: [String]
        if let personaID = personaManager.selectedCustomPersonaId,
           let persona = customPersonaStore.customPersonas.first(where: { $0.id == personaID }) {
            personaSuggestions = persona.instructionSuggestions.suggestions(for: mode)
        } else {
            personaSuggestions = []
        }

        var seen = Set<String>()
        return (personaSuggestions + genericSuggestions(for: mode)).filter {
            seen.insert($0).inserted
        }
    }

    private static func genericSuggestions(for mode: OrganizationMode) -> [String] {
        switch mode {
        case .organize:
            return [
                "Use no more than 6 top-level folders and keep the hierarchy two levels deep.",
                "Group files by project, then by year; keep loose files in General.",
                "Separate RAW photos from edited images, then group both by event.",
                "Keep recent work in Active, and move completed projects into an Archive by year.",
                "Keep files with the same project or client name together, regardless of file type.",
                "Put ambiguous files in Review instead of guessing where they belong.",
            ]
        case .organizeAndRename:
            return [
                "Use no more than 6 top-level folders, group by client, and put confirmed dates first.",
                "Group by project in a two-level hierarchy, then rename files with clear dates.",
                "Separate invoices by client, then rename them with the date and vendor.",
                "Keep source files beside their exports, and add Final only when the content confirms it.",
                "Archive completed projects by year, and preserve version numbers when renaming files.",
                "Put ambiguous files in Review, and rename them only from confirmed metadata.",
            ]
        case .renameOnly:
            return [
                "Put dates first, use natural words, and preserve the original file extension.",
                "Rename invoices with the date, vendor, and invoice number.",
                "Use consistent names with spaces, and keep existing version numbers.",
                "Use YYYY-MM-DD for confirmed dates, and leave uncertain dates out.",
                "Remove filler such as copy, untitled, and repeated final labels.",
                "Keep paired RAW and sidecar files on the same base name.",
            ]
        }
    }
}

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
