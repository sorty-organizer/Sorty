import SwiftUI
import SortyFileSystem

// MARK: - Connection
extension ProviderSelectionStepView {
    var readinessInputs: ProviderReadinessInputs {
        ProviderReadinessInputs(
            config: settingsViewModel.config,
            isCodexAuthenticated: codexAuth.isAuthenticated,
            isCodexInstalled: codexAuth.isCodexInstalled,
            isAppleFoundationModelAvailable: settingsViewModel.isAppleModelAvailable,
            appleFoundationModelStatus: settingsViewModel.appleModelStatus
        )
    }

    nonisolated static func resolveReadiness(
        from inputs: ProviderReadinessInputs
    ) -> ProviderReadinessSnapshot {
        let setupStatus = OnboardingSetupValidator.providerStatus(
            context: ProviderSetupContext(
                config: inputs.config,
                isCodexAuthenticated: inputs.isCodexAuthenticated,
                isCodexInstalled: inputs.isCodexInstalled,
                isAppleFoundationModelAvailable: inputs.isAppleFoundationModelAvailable,
                appleFoundationModelStatus: inputs.appleFoundationModelStatus
            )
        )
        let provider = inputs.config.provider
        let canTestConnection: Bool
        switch provider {
        case .appleFoundationModel, .ollama:
            canTestConnection = true
        default:
            canTestConnection = ProviderAuthResolver.hasRequiredCredential(
                for: provider,
                config: inputs.config
            )
        }
        return ProviderReadinessSnapshot(
            setupStatus: setupStatus,
            canTestConnection: canTestConnection
        )
    }

    func selectProvider(_ provider: AIProvider) {
        HapticFeedbackManager.shared.selection()
        commitInputDrafts()
        settingsViewModel.config.provider = provider
        connectionStatus = .idle
        connectionError = nil
    }

    var supportsSubscriptionAuthUI: Bool {
        FeatureFlags.subscriptionAuthEnabled && settingsViewModel.config.provider.supportsSubscriptionAuth
    }

    var selectedAuthMethod: Binding<ProviderAuthMethod> {
        Binding(
            get: { settingsViewModel.config.authMethod(for: settingsViewModel.config.provider) },
            set: { setAuthMethod($0) }
        )
    }

    func setAuthMethod(_ method: ProviderAuthMethod) {
        commitInputDrafts()
        var next = settingsViewModel.config
        let provider = next.provider
        next.setAuthMethod(method, for: provider)
        settingsViewModel.config = next
        HapticFeedbackManager.shared.selection()
        settingsViewModel.updateAvailableModels(force: true)
        scheduleConnectionTest()
        if method == .accountSignIn {
            codexAuth.checkStatus()
        }
    }

    func synchronizeInputDrafts() {
        apiKeyDraft = settingsViewModel.config.apiKey ?? ""
        apiURLDraft = settingsViewModel.config.apiURL
            ?? settingsViewModel.config.provider.defaultAPIURL
            ?? ""
    }

    func scheduleInitialProviderRefresh() {
        taskController.initialProviderRefreshTask?.cancel()
        let provider = settingsViewModel.config.provider
        taskController.initialProviderRefreshTask = Task { @MainActor in
            defer { taskController.initialProviderRefreshTask = nil }
            // Keep process/keychain/model probes off the provider pane's first
            // reveal frames. Existing manager state still renders immediately.
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled,
                  settingsViewModel.config.provider == provider else { return }

            switch provider {
            case .openAI:
                codexAuth.checkStatus()
            case .appleFoundationModel:
                settingsViewModel.refreshAppleModelStatus()
            default:
                break
            }
            taskController.initialProviderRefreshTask = nil
        }
    }

    func scheduleAPIKeyCommit() {
        let normalizedDraft = apiKeyDraft.isEmpty ? nil : apiKeyDraft
        guard normalizedDraft != settingsViewModel.config.apiKey else { return }

        taskController.apiKeyCommitTask?.cancel()
        taskController.apiKeyCommitTask = Task { @MainActor in
            defer { taskController.apiKeyCommitTask = nil }
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            commitAPIKeyDraft()
            taskController.apiKeyCommitTask = nil
        }
    }

    func scheduleAPIURLCommit() {
        let provider = settingsViewModel.config.provider
        guard provider == .openAICompatible || provider == .ollama else { return }
        let normalizedDraft = apiURLDraft.isEmpty ? nil : apiURLDraft
        guard normalizedDraft != settingsViewModel.config.apiURL else { return }

        taskController.apiURLCommitTask?.cancel()
        taskController.apiURLCommitTask = Task { @MainActor in
            defer { taskController.apiURLCommitTask = nil }
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            commitAPIURLDraft()
            taskController.apiURLCommitTask = nil
        }
    }

    func commitAPIKeyDraft() {
        taskController.apiKeyCommitTask?.cancel()
        taskController.apiKeyCommitTask = nil
        let normalizedDraft = apiKeyDraft.isEmpty ? nil : apiKeyDraft
        guard normalizedDraft != settingsViewModel.config.apiKey else { return }
        settingsViewModel.updateAPIKey(apiKeyDraft)
        scheduleConnectionTest()
    }

    func commitAPIURLDraft() {
        taskController.apiURLCommitTask?.cancel()
        taskController.apiURLCommitTask = nil
        let provider = settingsViewModel.config.provider
        guard provider == .openAICompatible || provider == .ollama else { return }
        let normalizedDraft = apiURLDraft.isEmpty ? nil : apiURLDraft
        guard normalizedDraft != settingsViewModel.config.apiURL else { return }
        settingsViewModel.config.apiURL = normalizedDraft
        scheduleConnectionTest()
    }

    func commitInputDrafts() {
        commitAPIKeyDraft()
        commitAPIURLDraft()
    }

    func resetConnectionVerification() {
        taskController.connectionTestID = nil
        taskController.testDebounceTask?.cancel()
        taskController.connectionTestTask?.cancel()
        taskController.testDebounceTask = nil
        taskController.connectionTestTask = nil
        connectionStatus = .idle
        connectionError = nil
    }

    func scheduleConnectionTest() {
        taskController.testDebounceTask?.cancel()
        taskController.connectionTestTask?.cancel()
        taskController.testDebounceTask = nil
        taskController.connectionTestTask = nil
        connectionStatus = .idle

        taskController.testDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
            guard !Task.isCancelled else { return }
            taskController.testDebounceTask = nil
            if readinessSnapshot.canTestConnection {
                testConnection()
            }
        }
    }

    func testConnection() {
        taskController.connectionTestTask?.cancel()
        let testedConfig = settingsViewModel.config
        let testID = UUID()
        taskController.connectionTestID = testID
        connectionStatus = .testing
        connectionError = nil

        taskController.connectionTestTask = Task {
            defer {
                if taskController.connectionTestID == testID {
                    taskController.connectionTestTask = nil
                    taskController.connectionTestID = nil
                }
            }
            do {
                try await settingsViewModel.testConnection()
                guard !Task.isCancelled,
                      taskController.connectionTestID == testID,
                      settingsViewModel.config == testedConfig else { return }
                connectionStatus = .success
                HapticFeedbackManager.shared.success()
            } catch let decodingError as DecodingError {
                guard !Task.isCancelled,
                      taskController.connectionTestID == testID,
                      settingsViewModel.config == testedConfig else { return }
                // Provide a clearer message for JSON decoding errors
                let context: String
                switch decodingError {
                case .dataCorrupted(let ctx):
                    context = ctx.debugDescription
                case .keyNotFound(let key, _):
                    context = "Missing key: \(key.stringValue)"
                case .typeMismatch(let type, _):
                    context = "Type mismatch for: \(type)"
                case .valueNotFound(let type, _):
                    context = "Missing value for: \(type)"
                @unknown default:
                    context = decodingError.localizedDescription
                }
                connectionStatus = .failed
                connectionError = "Invalid response format from server. The API endpoint may be incorrect or the service returned unexpected data. (\(context))"
                HapticFeedbackManager.shared.error()
            } catch {
                guard !Task.isCancelled,
                      taskController.connectionTestID == testID,
                      settingsViewModel.config == testedConfig else { return }
                connectionStatus = .failed
                connectionError = error.userFacingMessage
                HapticFeedbackManager.shared.error()
            }
        }
    }

    @discardableResult
    @MainActor
    func verifyCodexSignInStatus() async -> Bool {
        let wasAuthenticated = codexAuth.isAuthenticated
        await codexAuth.refreshStatus()
        let becameAuthenticated = codexAuth.isAuthenticated && !wasAuthenticated
        if becameAuthenticated {
            settingsViewModel.updateAvailableModels(force: true)
            scheduleConnectionTest()
        }
        return becameAuthenticated
    }

    func autoVerifyCodexSignInLoop() async {
        // Bounded exponential backoff (2s, 4s, 8s, 16s, then 30s cap,
        // ~10 tries) instead of an unbounded fixed 2s poll that keeps
        // process spawns churning while the panel sits open.
        var attempt = 0
        while !Task.isCancelled {
            let becameAuthenticated = await verifyCodexSignInStatus()

            if becameAuthenticated {
                await MainActor.run {
                    codexVerifyButtonState = .success
                    HapticFeedbackManager.shared.success()
                    scheduleCodexVerifyButtonReset()
                }
            }

            let shouldContinue = await MainActor.run {
                settingsViewModel.config.provider == .openAI
                    && settingsViewModel.config.authMethod(for: .openAI) == .accountSignIn
                    && !codexAuth.isAuthenticated
            }
            if !shouldContinue {
                break
            }

            attempt += 1
            guard attempt < 10 else { break }
            let backoffNanoseconds = min(UInt64(2_000_000_000) << (attempt - 1), 30_000_000_000)
            try? await Task.sleep(nanoseconds: backoffNanoseconds)
        }
    }

    @MainActor
    func startCodexTerminalSignIn() {
        HapticFeedbackManager.shared.tap()
        codexTerminalButtonState = .activating
        codexSignInAttempt += 1
        codexAuth.openTerminalWithLogin()

        if codexAuth.authError == nil {
            codexTerminalButtonState = .success
            HapticFeedbackManager.shared.success()
        } else {
            codexTerminalButtonState = .failure
            HapticFeedbackManager.shared.error()
        }

        scheduleCodexTerminalButtonReset()
    }

    @MainActor
    func manuallyVerifyCodexCLI() {
        HapticFeedbackManager.shared.tap()
        codexVerifyButtonState = .activating

        Task { @MainActor in
            let becameAuthenticated = await verifyCodexSignInStatus()
            if codexAuth.isAuthenticated || becameAuthenticated {
                codexVerifyButtonState = .success
                HapticFeedbackManager.shared.success()
                scheduleCodexVerifyButtonReset()
                return
            }

            codexVerifyButtonState = .failure
            HapticFeedbackManager.shared.error()
            if !codexAuth.isCodexInstalled {
                codexAuth.authError = "Codex CLI not found. Install with: npm i -g @openai/codex"
            } else if codexAuth.authError == nil {
                codexAuth.authError = "Auth tokens not found. Run 'codex login' first."
            }
            scheduleCodexVerifyButtonReset()
        }
    }

    @MainActor
    func scheduleCodexTerminalButtonReset() {
        taskController.codexTerminalResetTask?.cancel()
        taskController.codexTerminalResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            codexTerminalButtonState = .idle
            taskController.codexTerminalResetTask = nil
        }
    }

    @MainActor
    func scheduleCodexVerifyButtonReset() {
        taskController.codexVerifyResetTask?.cancel()
        taskController.codexVerifyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            codexVerifyButtonState = .idle
            taskController.codexVerifyResetTask = nil
        }
    }
}
