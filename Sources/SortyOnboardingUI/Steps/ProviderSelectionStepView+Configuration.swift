import SwiftUI

// MARK: - Configuration
extension ProviderSelectionStepView {
    @ViewBuilder
    var providerConfigSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if [.openCodeZen, .openCodeGo].contains(settingsViewModel.config.provider) {
                Picker("OpenCode plan", selection: Binding(
                    get: { settingsViewModel.config.provider },
                    set: { selectProvider($0) }
                )) {
                    Label {
                        Text("Zen")
                    } icon: {
                        ProviderLogoView(provider: .openCodeZen, size: 14)
                    }
                    .tag(AIProvider.openCodeZen)
                    Label {
                        Text("Go")
                    } icon: {
                        ProviderLogoView(provider: .openCodeGo, size: 14)
                    }
                    .tag(AIProvider.openCodeGo)
                }
                .pickerStyle(.segmented)
            }

            if settingsViewModel.config.provider == .openAICompatible || settingsViewModel.config.provider == .ollama {
                VStack(alignment: .leading, spacing: 8) {
                    Text("API URL")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    TextField("https://api.example.com", text: $apiURLDraft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiURLDraft) { _, _ in
                        scheduleAPIURLCommit()
                    }
                    .onSubmit(commitAPIURLDraft)

                    Text(settingsViewModel.config.provider == .ollama ?
                         "Default: http://localhost:11434" :
                         "Enter the base URL of your OpenAI-compatible API")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if settingsViewModel.config.provider.typicallyRequiresAPIKey {
                VStack(alignment: .leading, spacing: 8) {
                    if supportsSubscriptionAuthUI {
                        ProviderAuthenticationControl(
                            methods: settingsViewModel.config.provider.supportedAuthMethods,
                            selection: selectedAuthMethod
                        )
                        .frame(maxWidth: .infinity)

                        switch settingsViewModel.config.authMethod(for: settingsViewModel.config.provider) {
                        case .apiKey:
                            apiKeyInputSection
                        case .accountSignIn:
                            onboardingCodexCLISection
                        case .manualSessionToken:
                            apiKeyInputSection
                        }
                    } else {
                        if [.openCodeZen, .openCodeGo].contains(settingsViewModel.config.provider) {
                            OpenCodeCredentialLinkView(viewModel: settingsViewModel, onWillImport: {
                                taskController.apiKeyCommitTask?.cancel()
                                taskController.apiKeyCommitTask = nil
                                commitAPIKeyDraft()
                            })
                            .id(settingsViewModel.config.provider)
                        }
                        if !settingsViewModel.config.usesConnectedOpenCodeCredentials(for: settingsViewModel.config.provider) {
                            apiKeyInputSection
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model")
                        .font(.subheadline)
                    Text("Used for organization")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ModelSelectorCompactButton(
                    provider: settingsViewModel.config.provider,
                    label: selectedModelDisplay
                ) {
                    isShowingModelPopover = true
                }
                .modelSelectorTriggerBounds()
            }
        }
    }

    var selectedModelDisplay: String {
        let provider = settingsViewModel.config.provider
        return settingsViewModel.config.model.isEmpty
            ? provider.defaultModel
            : settingsViewModel.config.model
    }

    @ViewBuilder
    var apiKeyInputSection: some View {
        HStack {
            Text("API Key")
                .font(.subheadline)
                .fontWeight(.medium)

            Spacer()

            if FeatureFlags.privacyModeEnabled {
                Button {
                    isShowingAPIKey.toggle()
                    HapticFeedbackManager.shared.tap()
                } label: {
                    Image(systemName: isShowingAPIKey ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .symbolReplaceTransition(animationValue: isShowingAPIKey)
                }
                .buttonStyle(.plain)
                .help(isShowingAPIKey ? "Hide API Key" : "Show API Key")
            }
        }

        Group {
            if isShowingAPIKey && FeatureFlags.privacyModeEnabled {
                TextField("Enter your API key", text: Binding(
                    get: { apiKeyDraft },
                    set: {
                        apiKeyDraft = $0
                        scheduleAPIKeyCommit()
                    }
                ))
            } else {
                SecureField("Enter your API key", text: Binding(
                    get: { apiKeyDraft },
                    set: {
                        apiKeyDraft = $0
                        scheduleAPIKeyCommit()
                    }
                ))
            }
        }
        .textFieldStyle(.roundedBorder)
        .onSubmit(commitAPIKeyDraft)

        if let url = settingsViewModel.config.provider.apiKeyURL {
            HStack(spacing: 4) {
                Text(settingsViewModel.config.provider == .ollama ? "Find Ollama models at" : "Get your API key at")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .numericTextTransition(
                        animationValue: settingsViewModel.config.provider
                    )

                Link(destination: url) {
                    Text(settingsViewModel.config.provider.apiKeyLinkLabel)
                        .font(.caption)
                        .underline()
                }
                .trackHoveredURL(url)

                Image(systemName: "arrow.up.right.square")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        } else {
            Text(settingsViewModel.config.provider.apiKeyHelpText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    var onboardingCodexCLISection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if codexAuth.isAuthenticated {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signed in via Codex CLI")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        if let email = codexAuth.accountEmail {
                            CodexEmailRevealText(value: email)
                        }
                    }

                    Spacer()

                    Button("Sign Out") {
                        HapticFeedbackManager.shared.tap()
                        codexAuth.signOut()
                        scheduleConnectionTest()
                    }
                    .buttonStyle(.sortySecondary(size: .small))
                }
                .padding(10)
                .background(Color.green.opacity(0.08))
                .cornerRadius(8)
            } else {
                Text("Sign in with your OpenAI account using Codex CLI to enable Codex integration in Sorty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Step 1: Install & sign in")
                        .font(.caption).fontWeight(.semibold)
                    Text("Install Node.js 18+, then:")
                        .font(.caption2).foregroundStyle(.secondary)
                    onboardingCommandBlock("npm i -g @openai/codex")
                    onboardingCommandBlock("codex login")
                }

                OnboardingCodexActionButton(
                    idleTitle: "Open Terminal & Sign In",
                    activatingTitle: "Opening Terminal...",
                    successTitle: "Terminal Opened",
                    failureTitle: "Could Not Open Terminal",
                    idleSymbol: "terminal",
                    state: codexTerminalButtonState,
                    accessibilityIdentifier: "CodexTerminalSignInButton",
                    action: startCodexTerminalSignIn
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Step 2: Verify")
                        .font(.caption).fontWeight(.semibold)
                    Text("After you sign in, Sorty checks for your Codex sign-in automatically. You can also verify now.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                OnboardingCodexActionButton(
                    idleTitle: "Verify Codex CLI",
                    activatingTitle: "Verifying...",
                    successTitle: "Verified",
                    failureTitle: "Verification Failed",
                    idleSymbol: "checkmark.shield",
                    state: codexVerifyButtonState,
                    accessibilityIdentifier: "CodexVerifyButton",
                    action: manuallyVerifyCodexCLI
                )

                if isAutoVerifyingCodex {
                    HStack(spacing: 8) {
                        BouncingSpinner(size: 10, color: .secondary)
                        Text("Waiting for Codex sign-in…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }

                if !codexAuth.isCodexInstalled {
                    Label("Codex CLI not detected", systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let error = codexAuth.authError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isAutoVerifyingCodex)
        .task(id: codexSignInAttempt) {
            // Polling starts only after the Terminal sign-in so an idle panel
            // spawns no `codex login status` processes.
            guard codexSignInAttempt > 0 else { return }
            isAutoVerifyingCodex = true
            await autoVerifyCodexSignInLoop()
            // A retry cancels this run after starting its own; leave its spinner up.
            if !Task.isCancelled {
                isAutoVerifyingCodex = false
            }
        }
    }

    @ViewBuilder
    func onboardingCommandBlock(_ command: String) -> some View {
        HStack {
            Text(command)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                HapticFeedbackManager.shared.tap()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(Color.black.opacity(0.05))
        .cornerRadius(4)
    }

    @ViewBuilder
    func connectionStatusView(canTest: Bool) -> some View {
        VStack(spacing: 12) {
            Group {
                switch connectionStatus {
                case .idle:
                    ProviderTestConnectionButton(canTest: canTest, action: testConnection)

                case .testing:
                    HStack(spacing: 8) {
                        BouncingSpinner(size: 14, color: .accentColor)
                        Text("Testing connection...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                case .success:
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Connection successful")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }

                case .failed:
                    VStack(alignment: .center, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Connection failed")
                                .font(.subheadline)
                                .foregroundStyle(.orange)

                            Button("Retry") {
                                HapticFeedbackManager.shared.tap()
                                testConnection()
                            }
                            .buttonStyle(.sortySecondary(size: .small))
                        }

                        if let error = connectionError {
                            Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        }

                        Text("We strongly recommend fixing this now. You can still continue and configure a provider later in Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .italic()
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .animation(reduceMotion ? nil : .default, value: connectionStatus)
        }
    }
}
