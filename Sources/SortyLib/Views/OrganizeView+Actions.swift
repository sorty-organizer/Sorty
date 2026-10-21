import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Actions
extension OrganizeView {
    var returnToStartExitAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.08) : .easeInOut(duration: 0.18)
    }

    func returnToStartAfterCancellation() {
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

    func returnToDirectorySelection() {
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

    func presentWorkflowContentIfNeeded() {
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

    func handleStateChange(to newState: OrganizationState) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            switch newState {
            case .completed:
                HapticFeedbackManager.shared.success()
                beginCompletionHandoff()
            case .error:
                organizer.pinsCompletionView = false
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

    func noteLiveOrganizationStarted() {
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

    func scheduleReadyPreviewHandoff() {
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

    func finishLiveOrganizationPresentation() {
        readyPreviewHandoffTask?.cancel()
        readyPreviewHandoffTask = nil
        liveOrganizationStartedAt = nil
        withAnimation(.smooth(duration: 0.34)) {
            keepsLiveOrganizationVisible = false
        }
    }

    func resetLiveOrganizationPresentation() {
        readyPreviewHandoffTask?.cancel()
        readyPreviewHandoffTask = nil
        liveOrganizationStartedAt = nil
        keepsLiveOrganizationVisible = false
    }

    func beginCompletionHandoff() {
        guard !showsCompletionContent else { return }

        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.42)) {
            showsCompletionContent = true
        }
    }

    func configureOrganizer() {
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

    func startOrganization() {
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
    func verifyProviderForOrganization() async throws {
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

    func grantFolderPermissionAndContinue() {
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

    func dismissErrorViewTestRoute() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            errorViewTestRoute = nil
        }
    }

    func retryWithSelectedModel(provider: AIProvider, model: String) {
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
    
    func prewarmAIConnection() async {
        await settingsViewModel.refreshOpenCodeCredentials()
        let provider = settingsViewModel.config.provider
        let config = settingsViewModel.config
        await AISessionManager.shared.prewarm(provider: provider, config: config)
    }

    func presentSteeringPromptsIfRequested() {
        guard appState.shouldPresentSteeringPrompts else { return }
        showSavedPromptsSheet = true
        appState.shouldPresentSteeringPrompts = false
    }

    var providerSetupStatus: ProviderSetupStatus {
        OnboardingSetupValidator.providerStatus(
            context: ProviderSetupContext(
                config: settingsViewModel.config,
                isCodexAuthenticated: codexAuth.isAuthenticated,
                isCodexInstalled: codexAuth.isCodexInstalled,
                isAppleFoundationModelAvailable: settingsViewModel.isAppleModelAvailable,
                appleFoundationModelStatus: settingsViewModel.appleModelStatus
            )
        )
    }

    var needsSetupRepair: Bool {
        if appState.requiresSetupRepair {
            return true
        }
        guard isProviderStateReadyForValidation else { return false }
        return !providerSetupStatus.isReady
    }

    var activeSetupRepairMessage: String? {
        if appState.requiresSetupRepair {
            return appState.setupRepairMessage ?? providerSetupStatus.message
        }
        guard isProviderStateReadyForValidation else { return nil }
        if !providerSetupStatus.isReady {
            return providerSetupStatus.message
        }
        return nil
    }

    var isProviderStateReadyForValidation: Bool {
        settingsViewModel.hasLoadedPersistedState &&
            !settingsViewModel.isConfiguredCredentialHydrating &&
            isCodexStatusResolvedForValidation
    }

    /// The Codex CLI probe resolves asynchronously after launch. Until it has,
    /// the validator would mistake the initial `isCodexInstalled == false` for
    /// a missing setup and flash the repair HUD on every restart.
    var isCodexStatusResolvedForValidation: Bool {
        let config = settingsViewModel.config
        guard config.provider == .openAI,
              ProviderAuthResolver.effectiveAuthMethod(for: .openAI, config: config) == .accountSignIn
        else { return true }
        return codexAuth.hasResolvedStatus
    }
}
