import Foundation
import AppKit
import SwiftUI
import SortyFileSystem

// MARK: - Actions
extension AIProviderSettingsView {
    func testConnection() {
        HapticFeedbackManager.shared.tap()
        connectionSuccessResetTask?.cancel()
        connectionSuccessResetTask = nil
        connectionTestTask?.cancel()
        connectionTestTask = nil
        isTestingConnection = true
        testConnectionStatus = nil
        testConnectionDetails = nil
        isDetailsExpanded = false
        isInternetAccessBlocked = false
        hasCopiedConnectionError = false
        let testedConfig = viewModel.config
        let testID = UUID()
        connectionTestID = testID
        let shouldAnimate = !reduceMotion

        connectionTestTask = Task {
            do {
                try await viewModel.testConnection()
                await MainActor.run {
                    guard connectionTestID == testID, viewModel.config == testedConfig else { return }
                    HapticFeedbackManager.shared.success()
                    withAnimation(
                        shouldAnimate ? .spring(response: 0.4, dampingFraction: 0.7) : nil
                    ) {
                        testConnectionStatus = "Success: Connection test passed"
                        testConnectionDetails = nil
                    }
                    clearSetupRepairIfProviderIsUsable(testedConfig: testedConfig)
                    scheduleConnectionSuccessReset()
                }
            } catch let decodingError as DecodingError {
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
                await MainActor.run {
                    guard connectionTestID == testID, viewModel.config == testedConfig else { return }
                    HapticFeedbackManager.shared.error()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        testConnectionStatus = "Error: Invalid response format"
                        testConnectionDetails = "The API endpoint may be incorrect or the service returned unexpected data.\n\nDetails: \(context)"
                    }
                }
            } catch {
                await MainActor.run {
                    guard connectionTestID == testID, viewModel.config == testedConfig else { return }
                    HapticFeedbackManager.shared.error()
                    var details: String? = nil
                    if let aiError = error as? AIClientError {
                        details = aiError.failureReason
                        isInternetAccessBlocked = aiError.isInternetAccessBlocked
                    } else {
                        details = (error as NSError).localizedFailureReason ?? (error as NSError).localizedRecoverySuggestion
                    }

                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        if isInternetAccessBlocked {
                            testConnectionStatus = """
                            Error: Sorty can’t connect to \(testedConfig.provider.displayName) while Block Internet Connections is on.
                            """
                        } else {
                            testConnectionStatus = "Error: \(error.userFacingMessage)"
                        }
                        testConnectionDetails = details
                    }
                }
            }
            await MainActor.run {
                guard connectionTestID == testID else { return }
                connectionTestID = nil
                isTestingConnection = false
                connectionTestTask = nil
            }
        }
    }

    @MainActor
    func resetConnectionTestState() {
        connectionTestID = nil
        connectionTestTask?.cancel()
        connectionTestTask = nil
        connectionSuccessResetTask?.cancel()
        connectionSuccessResetTask = nil
        isTestingConnection = false
        testConnectionStatus = nil
        testConnectionDetails = nil
        isDetailsExpanded = false
        isInternetAccessBlocked = false
        hasCopiedConnectionError = false
        isHoveringCopyError = false
    }

    @MainActor
    func scheduleConnectionSuccessReset() {
        connectionSuccessResetTask?.cancel()
        connectionSuccessResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            HapticFeedbackManager.shared.selection()
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.78)) {
                testConnectionStatus = nil
                testConnectionDetails = nil
                isDetailsExpanded = false
                isInternetAccessBlocked = false
                hasCopiedConnectionError = false
            }
            connectionSuccessResetTask = nil
        }
    }

    @MainActor
    func clearSetupRepairIfProviderIsUsable(testedConfig: AIConfig) {
        guard viewModel.config == testedConfig else { return }

        let providerStatus = OnboardingSetupValidator.providerStatus(
            context: ProviderSetupContext(
                config: testedConfig,
                isCodexAuthenticated: codexAuth.isAuthenticated,
                isCodexInstalled: codexAuth.isCodexInstalled,
                isAppleFoundationModelAvailable: viewModel.isAppleModelAvailable,
                appleFoundationModelStatus: viewModel.appleModelStatus
            )
        )
        guard providerStatus.isReady else { return }

        appState.clearSetupRepairState()
    }

    func autoVerifyCodexSignInLoop() async {
        // Bounded exponential backoff (2s, 4s, 8s, 16s, then 30s cap,
        // ~10 tries) instead of an unbounded fixed 2s poll that keeps
        // process spawns churning while the panel sits open.
        var attempt = 0
        while !Task.isCancelled {
            let becameAuthenticated = await MainActor.run {
                verifyCodexSignInStatus()
            }

            if becameAuthenticated {
                await MainActor.run {
                    handleCodexDeviceAuthSuccess()
                }
            }

            let shouldContinue = await MainActor.run {
                viewModel.config.provider == .openAI
                    && viewModel.config.authMethod(for: .openAI) == .accountSignIn
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
    @discardableResult
    func verifyCodexSignInStatus() -> Bool {
        let wasAuthenticated = codexAuth.isAuthenticated
        codexAuth.checkStatus()
        if codexAuth.isAuthenticated && !wasAuthenticated {
            viewModel.updateAvailableModels(force: true)
            return true
        }
        return false
    }

    @MainActor
    func startCodexDeviceAuth() {
        HapticFeedbackManager.shared.tap()
        codexTerminalButtonState = .activating
        codexAuth.startDeviceAuth()

        if codexAuth.authError == nil {
            codexTerminalButtonState = .success
        } else {
            codexTerminalButtonState = .failure
            HapticFeedbackManager.shared.error()
        }

        scheduleCodexTerminalButtonReset()
    }

    @MainActor
    func openChatGPTSecuritySettings() {
        HapticFeedbackManager.shared.tap()
        let targetToggle = "Enable device code authorization for Codex"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(targetToggle, forType: .string)

        if let url = URL(string: "https://chatgpt.com/#settings/Security") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    func openCodexDeviceAuthorization() {
        HapticFeedbackManager.shared.tap()
        let url = codexAuth.deviceAuthSession?.verificationURL
            ?? URL(string: "https://auth.openai.com/activate")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    func copyCodexDeviceCode() {
        guard let code = codexAuth.deviceAuthSession?.userCode else { return }
        deviceCodeCopyFeedback.copy(code, duration: .milliseconds(1250),
            animation: reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.72),
            resetAnimation: reduceMotion ? nil : .easeOut(duration: 0.18))
    }

    @MainActor
    func scheduleCodexTerminalButtonReset() {
        codexTerminalResetTask?.cancel()
        codexTerminalResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            guard codexAuth.deviceAuthSession?.status != .authorized else { return }
            codexTerminalButtonState = .idle
            codexTerminalResetTask = nil
        }
    }

    @MainActor
    func handleCodexDeviceAuthSuccess() {
        guard isShowingCodexDeviceAuth else { return }

        codexTerminalButtonState = .success
        viewModel.updateAvailableModels(force: true)
        HapticFeedbackManager.shared.success()

        codexDeviceAuthDismissTask?.cancel()
        codexDeviceAuthDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            guard codexAuth.isAuthenticated || codexAuth.deviceAuthSession?.status == .authorized else { return }
            isShowingCodexDeviceAuth = false
            codexDeviceAuthDismissTask = nil
        }
    }
}
