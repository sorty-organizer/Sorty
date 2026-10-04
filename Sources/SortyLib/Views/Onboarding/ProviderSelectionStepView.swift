//
//  ProviderSelectionStepView.swift
//  Sorty
//
//  AI Provider selection step of the onboarding flow
//

import SwiftUI

private struct ProviderReadinessInputs: Equatable, Sendable {
    let config: AIConfig
    let isCodexAuthenticated: Bool
    let isCodexInstalled: Bool
    let isAppleFoundationModelAvailable: Bool
    let appleFoundationModelStatus: String?
}

private struct ProviderReadinessSnapshot: Equatable, Sendable {
    let setupStatus: ProviderSetupStatus
    let canTestConnection: Bool

    static let initial = ProviderReadinessSnapshot(
        setupStatus: ProviderSetupStatus(
            isReady: false,
            title: "Setup required",
            message: "Choose and configure an AI provider before continuing."
        ),
        canTestConnection: false
    )
}

@MainActor
private final class ProviderSelectionTaskController {
    var initialProviderRefreshTask: Task<Void, Never>?
    var testDebounceTask: Task<Void, Never>?
    var connectionTestTask: Task<Void, Never>?
    var connectionTestID: UUID?
    var codexTerminalResetTask: Task<Void, Never>?
    var codexVerifyResetTask: Task<Void, Never>?
    var apiKeyCommitTask: Task<Void, Never>?
    var apiURLCommitTask: Task<Void, Never>?
}

public struct ProviderSelectionStepView: View {
    @SortyHotReload private var hotReload
    private let onSetupStatusChange: ((ProviderSetupStatus) -> Void)?
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var codexAuth: CodexCLIAuthManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @State private var connectionStatus: ConnectionTestStatus = .idle
    @State private var connectionError: String?
    @State private var taskController = ProviderSelectionTaskController()
    @State private var isShowingAPIKey = false
    @State private var isShowingModelPopover = false
    @State private var codexTerminalButtonState: CodexActionVisualState = .idle
    @State private var codexVerifyButtonState: CodexActionVisualState = .idle
    @State private var codexSignInAttempt = 0
    @State private var apiKeyDraft = ""
    @State private var apiURLDraft = ""
    @State private var readinessSnapshot = ProviderReadinessSnapshot.initial

    enum ConnectionTestStatus: Equatable {
        case idle
        case testing
        case success
        case failed
    }

    public init(onSetupStatusChange: ((ProviderSetupStatus) -> Void)? = nil) {
        self.onSetupStatusChange = onSetupStatusChange
    }

    public var body: some View {
        let setupStatus = readinessSnapshot.setupStatus
        let canTest = readinessSnapshot.canTestConnection

        HStack(spacing: 34) {
            VStack(alignment: .leading, spacing: 22) {
                Spacer()

                VStack(alignment: .leading, spacing: 14) {
                    ProviderLogoView(provider: settingsViewModel.config.provider, size: 54)
                        .padding(12)
                        .systemLiquidGlassBackground(cornerRadius: 18)

                    Text("Choose your AI")
                        .font(.system(size: 28, weight: .bold, design: .rounded))

                    Text("Sorty sends file names and metadata to the provider you pick. File contents stay on your Mac unless you enable Deep Scan.")
                        .sortyTypography(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 12) {
                        PrivacyFeatureRow(icon: "doc.text", text: "File names and metadata sent to selected AI provider")
                        PrivacyFeatureRow(icon: "folder", text: "File contents stay local (unless Deep Scan is enabled)")
                        PrivacyFeatureRow(icon: "arrow.uturn.backward", text: "All changes are reversible")
                        PrivacyFeatureRow(icon: "server.rack", text: "Local and on-device options available")
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: 350)
                .opacity(hasAppeared ? 1 : 0)
                .offset(x: hasAppeared ? 0 : -20)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.8).delay(0.1),
                    value: hasAppeared
                )

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, 72)

            // This pane can exceed the minimum onboarding height for providers
            // with multi-step setup. Keep overflow local to the pane so the
            // whole-step layout still receives a finite height proposal.
            GeometryReader { viewport in
                ScrollView(.vertical) {
                    VStack(spacing: 12) {
                    HStack {
                        Text("Provider")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text(setupStatus.isReady ? "Ready" : "Setup recommended")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(setupStatus.isReady ? .green : .orange)
                            .numericTextTransition(
                                animationValue: setupStatus.isReady
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background((setupStatus.isReady ? Color.green : Color.orange).opacity(0.12), in: Capsule())
                    }
                    .frame(maxWidth: 640)

                    ProviderSelectionGrid(
                        selectedProvider: settingsViewModel.config.provider,
                        onSelect: selectProvider
                    )
                    .equatable()
                    .frame(maxWidth: 640)

                    if settingsViewModel.config.provider != .appleFoundationModel {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 10) {
                                Image(systemName: setupStatus.isReady ? "checkmark.shield.fill" : "key.horizontal.fill")
                                    .foregroundStyle(setupStatus.isReady ? .green : SortyDesignSystem.Colors.resolvedAccent)
                                    .font(.system(size: 16, weight: .semibold))
                                    .symbolReplaceTransition(
                                        animationValue: setupStatus.isReady
                                    )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Configure \(settingsViewModel.config.provider.displayName)")
                                        .font(.subheadline.weight(.semibold))
                                        .numericTextTransition(
                                            animationValue: settingsViewModel.config.provider
                                        )

                                    Text(setupStatus.isReady ? "Ready to organize" : "Add credentials and choose a model")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .numericTextTransition(
                                            animationValue: setupStatus.isReady
                                        )
                                }

                                Spacer()

                            }

                            if settingsViewModel.config.provider == .unavailableProvider {
                                Text(setupStatus.message)
                                    .sortyTypography(.body)
                                    .foregroundStyle(.orange)
                            } else {
                                providerConfigSection
                            }
                        }
                        .padding(16)
                        .systemLiquidGlassBackground(cornerRadius: 14)
                        .frame(maxWidth: 430)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .accessibilityIdentifier("OnboardingProviderConfigurationPanel")
                    }

                        connectionStatusView(canTest: canTest)
                            .frame(maxWidth: 430)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: viewport.size.height, alignment: .center)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.automatic)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.trailing, 72)
            .opacity(hasAppeared ? 1 : 0)
            .offset(x: hasAppeared ? 0 : 20)
            .animation(
                reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.8).delay(0.2),
                value: hasAppeared
            )
            .animation(
                reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7),
                value: settingsViewModel.config.provider
            )
        }
        .onAppear {
            synchronizeInputDrafts()
            hasAppeared = true
            scheduleInitialProviderRefresh()
        }
        .onChange(of: settingsViewModel.config.provider) { _, newProvider in
            taskController.testDebounceTask?.cancel()
            taskController.connectionTestTask?.cancel()
            taskController.testDebounceTask = nil
            taskController.connectionTestTask = nil
            taskController.initialProviderRefreshTask?.cancel()
            taskController.initialProviderRefreshTask = nil
            taskController.apiKeyCommitTask?.cancel()
            taskController.apiURLCommitTask?.cancel()
            taskController.apiKeyCommitTask = nil
            taskController.apiURLCommitTask = nil
            synchronizeInputDrafts()
            if newProvider == .openAI {
                codexAuth.checkStatus()
            }
            if newProvider == .appleFoundationModel {
                settingsViewModel.refreshAppleModelStatus()
            }
        }
        .onChange(of: settingsViewModel.config.openCodeAuthSources) { _, _ in
            resetConnectionVerification()
        }
        .onChange(of: settingsViewModel.config.apiKey) { _, apiKey in
            if settingsViewModel.config.usesConnectedOpenCodeCredentials(for: settingsViewModel.config.provider) {
                resetConnectionVerification()
            } else {
                scheduleConnectionTest()
            }
            guard taskController.apiKeyCommitTask == nil else { return }
            let value = apiKey ?? ""
            if apiKeyDraft != value {
                apiKeyDraft = value
            }
        }
        .onDisappear {
            commitInputDrafts()
            taskController.initialProviderRefreshTask?.cancel()
            taskController.initialProviderRefreshTask = nil
            taskController.apiKeyCommitTask?.cancel()
            taskController.apiKeyCommitTask = nil
            taskController.apiURLCommitTask?.cancel()
            taskController.apiURLCommitTask = nil
            taskController.testDebounceTask?.cancel()
            taskController.testDebounceTask = nil
            taskController.connectionTestTask?.cancel()
            taskController.connectionTestTask = nil
            taskController.codexTerminalResetTask?.cancel()
            taskController.codexTerminalResetTask = nil
            taskController.codexVerifyResetTask?.cancel()
            taskController.codexVerifyResetTask = nil
        }
        .task(id: readinessInputs) {
            let inputs = readinessInputs
            let snapshot = await Task.detached(priority: .utility) {
                Self.resolveReadiness(from: inputs)
            }.value
            guard !Task.isCancelled else { return }
            if readinessSnapshot != snapshot {
                readinessSnapshot = snapshot
            }
            onSetupStatusChange?(snapshot.setupStatus)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Provider Selection Step")
        .modelSelectionOverlay(
            isPresented: $isShowingModelPopover,
            currentProvider: settingsViewModel.config.provider,
            currentModel: settingsViewModel.config.model,
            contextMessage: "Choose the provider and model Sorty will use for organization.",
            reasoningEffortForModel: { provider, model in
                settingsViewModel.config.reasoningEffort(for: provider, model: model)
            },
            onSelectReasoningEffort: { provider, model, effort in
                settingsViewModel.config.setReasoningEffort(effort, for: provider, model: model)
            },
            onSelect: { provider, model, authMethod in
                commitInputDrafts()
                settingsViewModel.config.provider = provider
                settingsViewModel.config.model = model
                if provider == .openAI, supportsSubscriptionAuthUI, let desired = authMethod {
                    if desired != settingsViewModel.config.authMethod(for: .openAI) {
                        setAuthMethod(desired)
                    }
                }
            },
            isSubscriptionSelected: settingsViewModel.config.authMethod(for: settingsViewModel.config.provider) == .accountSignIn
        )
    }

    @ViewBuilder
    private var providerConfigSection: some View {
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
                        .sortyTypography(.body)
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
                        .sortyTypography(.body)
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

    private var selectedModelDisplay: String {
        let provider = settingsViewModel.config.provider
        return settingsViewModel.config.model.isEmpty
            ? provider.defaultModel
            : settingsViewModel.config.model
    }

    @ViewBuilder
    private var apiKeyInputSection: some View {
        HStack {
            Text("API Key")
                .sortyTypography(.body)
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
    private var onboardingCodexCLISection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if codexAuth.isAuthenticated {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signed in via Codex CLI")
                            .sortyTypography(.body)
                            .fontWeight(.medium)
                        if let email = codexAuth.accountEmail {
                            CodexEmailRevealText(value: email)
                        }
                    }

                    Spacer()

                    Button("Sign Out") {
                        codexAuth.signOut()
                        scheduleConnectionTest()
                    }
                    .buttonStyle(.sortyBordered)
                    .controlSize(.small)
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
                    Text("We automatically verify that Codex CLI is installed and auth tokens are present. You can also run a manual verify anytime.")
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

                HStack(spacing: 8) {
                    BouncingSpinner(size: 10, color: .secondary)
                    Text("Automatic verification runs every few seconds while this panel is open.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
        .task(id: codexSignInAttempt) {
            guard codexSignInAttempt > 0 else { return }
            await autoVerifyCodexSignInLoop()
        }
    }

    @ViewBuilder
    private func onboardingCommandBlock(_ command: String) -> some View {
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
    private func connectionStatusView(canTest: Bool) -> some View {
        VStack(spacing: 12) {
            Group {
                switch connectionStatus {
                case .idle:
                    ProviderTestConnectionButton(canTest: canTest, action: testConnection)

                case .testing:
                    HStack(spacing: 8) {
                        BouncingSpinner(size: 14, color: .accentColor)
                        Text("Testing connection...")
                            .sortyTypography(.body)
                            .foregroundStyle(.secondary)
                    }

                case .success:
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Connection successful")
                            .sortyTypography(.body)
                            .foregroundStyle(.green)
                    }

                case .failed:
                    VStack(alignment: .center, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Connection failed")
                                .sortyTypography(.body)
                                .foregroundStyle(.orange)

                            Button("Retry") {
                                testConnection()
                            }
                            .buttonStyle(.sortyBordered)
                            .controlSize(.small)
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

    private var readinessInputs: ProviderReadinessInputs {
        ProviderReadinessInputs(
            config: settingsViewModel.config,
            isCodexAuthenticated: codexAuth.isAuthenticated,
            isCodexInstalled: codexAuth.isCodexInstalled,
            isAppleFoundationModelAvailable: settingsViewModel.isAppleModelAvailable,
            appleFoundationModelStatus: settingsViewModel.appleModelStatus
        )
    }

    nonisolated private static func resolveReadiness(
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

    private func selectProvider(_ provider: AIProvider) {
        HapticFeedbackManager.shared.selection()
        commitInputDrafts()
        settingsViewModel.config.provider = provider
        connectionStatus = .idle
        connectionError = nil
    }

    private var supportsSubscriptionAuthUI: Bool {
        FeatureFlags.subscriptionAuthEnabled && settingsViewModel.config.provider.supportsSubscriptionAuth
    }

    private var selectedAuthMethod: Binding<ProviderAuthMethod> {
        Binding(
            get: { settingsViewModel.config.authMethod(for: settingsViewModel.config.provider) },
            set: { setAuthMethod($0) }
        )
    }

    private func setAuthMethod(_ method: ProviderAuthMethod) {
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

    private func synchronizeInputDrafts() {
        apiKeyDraft = settingsViewModel.config.apiKey ?? ""
        apiURLDraft = settingsViewModel.config.apiURL
            ?? settingsViewModel.config.provider.defaultAPIURL
            ?? ""
    }

    private func scheduleInitialProviderRefresh() {
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

    private func scheduleAPIKeyCommit() {
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

    private func scheduleAPIURLCommit() {
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

    private func commitAPIKeyDraft() {
        taskController.apiKeyCommitTask?.cancel()
        taskController.apiKeyCommitTask = nil
        let normalizedDraft = apiKeyDraft.isEmpty ? nil : apiKeyDraft
        guard normalizedDraft != settingsViewModel.config.apiKey else { return }
        settingsViewModel.updateAPIKey(apiKeyDraft)
        scheduleConnectionTest()
    }

    private func commitAPIURLDraft() {
        taskController.apiURLCommitTask?.cancel()
        taskController.apiURLCommitTask = nil
        let provider = settingsViewModel.config.provider
        guard provider == .openAICompatible || provider == .ollama else { return }
        let normalizedDraft = apiURLDraft.isEmpty ? nil : apiURLDraft
        guard normalizedDraft != settingsViewModel.config.apiURL else { return }
        settingsViewModel.config.apiURL = normalizedDraft
        scheduleConnectionTest()
    }

    private func commitInputDrafts() {
        commitAPIKeyDraft()
        commitAPIURLDraft()
    }

    private func resetConnectionVerification() {
        taskController.connectionTestID = nil
        taskController.testDebounceTask?.cancel()
        taskController.connectionTestTask?.cancel()
        taskController.testDebounceTask = nil
        taskController.connectionTestTask = nil
        connectionStatus = .idle
        connectionError = nil
    }

    private func scheduleConnectionTest() {
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

    private func testConnection() {
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
                connectionError = error.localizedDescription
                HapticFeedbackManager.shared.error()
            }
        }
    }

    @discardableResult
    @MainActor
    private func verifyCodexSignInStatus() async -> Bool {
        let wasAuthenticated = codexAuth.isAuthenticated
        await codexAuth.refreshStatus()
        let becameAuthenticated = codexAuth.isAuthenticated && !wasAuthenticated
        if becameAuthenticated {
            settingsViewModel.updateAvailableModels(force: true)
            scheduleConnectionTest()
        }
        return becameAuthenticated
    }

    private func autoVerifyCodexSignInLoop() async {
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
    private func startCodexTerminalSignIn() {
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
    private func manuallyVerifyCodexCLI() {
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
    private func scheduleCodexTerminalButtonReset() {
        taskController.codexTerminalResetTask?.cancel()
        taskController.codexTerminalResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            codexTerminalButtonState = .idle
            taskController.codexTerminalResetTask = nil
        }
    }

    @MainActor
    private func scheduleCodexVerifyButtonReset() {
        taskController.codexVerifyResetTask?.cancel()
        taskController.codexVerifyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            codexVerifyButtonState = .idle
            taskController.codexVerifyResetTask = nil
        }
    }

}
private struct ProviderTestConnectionButton: View {
    @SortyHotReload private var hotReload
    let canTest: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle.fill")
                Text("Test Connection")
            }
        }
        .buttonStyle(.sortyPrimary)
        .onboardingBeamBorder(
            variant: .featured,
            active: isHovering && canTest,
            isIntensified: isHovering,
            includesInteriorGlow: isHovering
        )
        .debouncedHover($isHovering)
        .disabled(!canTest)
        .opacity(canTest ? 1 : 0.5)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.16),
            value: isHovering
        )
    }
}

/// Hover state with CompletionStepView's 40/90ms debounce: a short enter
/// delay filters sub-40ms swipes that would otherwise flash hover visuals,
/// and a longer leave delay keeps the exit from jittering on edge brushes.
/// Haptics never fire from hover — only from clicks.
struct DebouncedHoverModifier: ViewModifier {
    @Binding var isHovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()
                let delayMs = hovering ? 40 : 90
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(delayMs))
                    guard !Task.isCancelled else { return }
                    if reduceMotion {
                        isHovering = hovering
                    } else {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isHovering = hovering
                        }
                    }
                }
            }
            .onDisappear {
                hoverTask?.cancel()
            }
    }
}

extension View {
    /// Debounced hover shared across onboarding surfaces (40ms enter to
    /// filter swipe-throughs, 90ms leave to settle edge brushes).
    func debouncedHover(_ isHovering: Binding<Bool>) -> some View {
        modifier(DebouncedHoverModifier(isHovering: isHovering))
    }
}

private struct CodexEmailRevealText: View {
    @SortyHotReload private var hotReload
    let value: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Text(value)
            .font(.caption)
            .foregroundStyle(.secondary)
            .blur(radius: FeatureFlags.privacyModeEnabled && !isHovering ? 4 : 0)
            .animation(reduceMotion ? nil : .spring(), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

private struct OnboardingCodexActionButton: View {
    @SortyHotReload private var hotReload
    let idleTitle: String
    let activatingTitle: String
    let successTitle: String
    let failureTitle: String
    let idleSymbol: String
    let state: CodexActionVisualState
    let accessibilityIdentifier: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            CodexActionButtonLabel(
                idleTitle: idleTitle,
                activatingTitle: activatingTitle,
                successTitle: successTitle,
                failureTitle: failureTitle,
                idleSymbol: idleSymbol,
                state: state,
                isHovered: isHovering
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .debouncedHover($isHovering)
    }
}

// MARK: - Supporting Views

/// The provider grid is visually independent from credential drafts and
/// connection status. Equatable isolation keeps its nine glass/logo cards out
/// of API-key keystroke and status-update rebuilds.
private struct ProviderSelectionGrid: View, Equatable {
    @SortyHotReload private var hotReload
    let selectedProvider: AIProvider
    let onSelect: (AIProvider) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectedProvider == rhs.selectedProvider
    }

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(minimum: 10, maximum: .infinity), spacing: 8),
                count: 3
            ),
            spacing: 8
        ) {
            ForEach(AIProvider.userSelectableProviders.filter { $0 != .openCodeGo }, id: \.self) { provider in
                OnboardingProviderRow(
                    provider: provider,
                    selectedProvider: selectedProvider
                ) { selected in
                    onSelect(selected)
                }
            }
        }
    }
}

struct PrivacyFeatureRow: View {
    @SortyHotReload private var hotReload
    let icon: String
    let text: String
    var badge: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .sortyTypography(.body)
                .foregroundStyle(.green)
                .frame(width: 20)

            Text(text)
                .sortyTypography(.body)
                .foregroundStyle(.primary)

            if let badge {
                OnboardingCapsuleBadge(text: badge)
            }
        }
    }
}

struct OnboardingProviderRow: View {
    @SortyHotReload private var hotReload
    @AppStorage(NetworkPrivacyPolicy.internetPrivacyModeKey) private var internetPrivacyModeEnabled = false
    let provider: AIProvider
    let selectedProvider: AIProvider
    let action: (AIProvider) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var isOpenCodeCard: Bool { provider == .openCodeZen }
    // Custom endpoints remain configurable for localhost workflows.
    private var isBlockedByInternetPrivacy: Bool {
        internetPrivacyModeEnabled && ![.appleFoundationModel, .ollama, .openAICompatible].contains(provider)
    }
    private var internetPrivacyExplanation: String {
        "\(provider.selectorTitle) requires an internet connection. Turn off Block Internet Connections in Advanced Settings to use it."
    }
    private var isSelected: Bool {
        selectedProvider == provider || (isOpenCodeCard && selectedProvider == .openCodeGo)
    }
    private var logoProvider: AIProvider {
        isOpenCodeCard && selectedProvider == .openCodeGo ? .openCodeGo : provider
    }

    private var subtitle: String? {
        switch provider {
        case .ollama: return "Local"
        case .appleFoundationModel: return "On-device"
        default: return nil
        }
    }

    private var subtitleColor: Color {
        provider == .ollama ? .green : .blue
    }

    var body: some View {
        Button {
            if provider.isAvailable {
                // The OpenCode card covers both plans: staying on Go keeps Go,
                // otherwise the card selects Zen; plan switching lives in the plan picker.
                action(isOpenCodeCard && selectedProvider == .openCodeGo ? .openCodeGo : provider)
            }
        } label: {
            HStack(spacing: 9) {
                ProviderLogoView(provider: logoProvider, size: 20)
                    .frame(width: 28, height: 28)
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white, SortyDesignSystem.Colors.resolvedAccent)
                                .background(Circle().fill(SortyDesignSystem.Colors.resolvedAccent))
                                .offset(x: 3, y: 3)
                                .transition(.scale.combined(with: .opacity))
                                .accessibilityHidden(true)
                        }
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text(isOpenCodeCard ? "OpenCode" : provider.selectorTitle)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .rounded))
                        .foregroundColor(provider.isAvailable ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)

                    if let subtitle {
                        Text(LocalizedStringKey(subtitle))
                            .font(.caption2)
                            .foregroundStyle(subtitleColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.88)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                if !provider.isAvailable {
                    Text("Unavailable")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .blur(radius: isBlockedByInternetPrivacy ? 2 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isSelected
                        ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.12)
                        : (isHovering ? Color.primary.opacity(0.05) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.45) : Color.clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .opacity(provider.isAvailable ? 1.0 : 0.6)
        .disabled(isBlockedByInternetPrivacy || !provider.isAvailable)
        .onHover { hovering in
            if provider.isAvailable { isHovering = hovering }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
        .accessibilityIdentifier("OnboardingProvider_\(provider.rawValue)")
        .accessibilityHint(isBlockedByInternetPrivacy ? internetPrivacyExplanation : (isOpenCodeCard ? "Selects OpenCode. Switch between the Zen and Go plans in the plan picker." : "Selects \(provider.displayName)."))
        .help(isBlockedByInternetPrivacy ? internetPrivacyExplanation : (isOpenCodeCard ? "Use OpenCode (switch plans in the plan picker)" : "Use \(provider.displayName)"))
        .overlay {
            if isBlockedByInternetPrivacy {
                // Keep the tooltip reachable above the disabled button.
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .help(internetPrivacyExplanation)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    let codexAuthManager = CodexCLIAuthManager()

    ProviderSelectionStepView()
        .environmentObject(SettingsViewModel())
        .environmentObject(codexAuthManager)
}
