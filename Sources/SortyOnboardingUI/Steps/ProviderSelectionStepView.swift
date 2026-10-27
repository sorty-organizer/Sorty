//
//  ProviderSelectionStepView.swift
//  Sorty
//
//  AI Provider selection step of the onboarding flow
//

import SwiftUI

struct ProviderReadinessInputs: Equatable, Sendable {
    let config: AIConfig
    let isCodexAuthenticated: Bool
    let isCodexInstalled: Bool
    let isAppleFoundationModelAvailable: Bool
    let appleFoundationModelStatus: String?
}

struct ProviderReadinessSnapshot: Equatable, Sendable {
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
final class ProviderSelectionTaskController {
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
    @SortyHotReload var hotReload
    let onSetupStatusChange: ((ProviderSetupStatus) -> Void)?
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var codexAuth: CodexCLIAuthManager
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var connectionStatus: ConnectionTestStatus = .idle
    @State var connectionError: String?
    @State var taskController = ProviderSelectionTaskController()
    @State var isShowingAPIKey = false
    @State var isShowingModelPopover = false
    @State var codexTerminalButtonState: CodexActionVisualState = .idle
    @State var codexVerifyButtonState: CodexActionVisualState = .idle
    @State var codexSignInAttempt = 0
    /// True only while the post-sign-in verify loop runs, so the spinner never outlives it.
    @State var isAutoVerifyingCodex = false
    @State var apiKeyDraft = ""
    @State var apiURLDraft = ""
    @State var readinessSnapshot = ProviderReadinessSnapshot.initial

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
        providerContent
        .onAppear {
            synchronizeInputDrafts()
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


    private var providerIntroduction: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()

            VStack(alignment: .leading, spacing: 14) {
                ProviderLogoView(provider: settingsViewModel.config.provider, size: 54)
                    .padding(12)
                    .systemLiquidGlassBackground(cornerRadius: 18, interactive: false)

                Text("Choose your AI")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text("Sorty sends file names and metadata to the provider you pick. File contents stay on your Mac unless you enable Deep Scan.")
                    .font(.body)
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

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, 72)
    }

    @ViewBuilder
    private var providerContent: some View {
        let setupStatus = readinessSnapshot.setupStatus
        let canTest = readinessSnapshot.canTestConnection

        HStack(spacing: 34) {
            providerIntroduction
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
                                    .font(.subheadline)
                                    .foregroundStyle(.orange)
                            } else {
                                providerConfigSection
                            }
                        }
                        .padding(16)
                        // A container, not a control: interactive glass here
                        // tracked every pointer move across the form.
                        .systemLiquidGlassBackground(cornerRadius: 14, interactive: false)
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
            .animation(
                reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7),
                value: settingsViewModel.config.provider
            )
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
