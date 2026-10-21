//
//  AIProviderSettingsView.swift
//  Sorty
//
//  AI Provider settings section
//

import Foundation
import AppKit
import SwiftUI

struct AIProviderSettingsView: View {
    @SortyHotReload var hotReload
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var viewModel: SettingsViewModel
    @EnvironmentObject var codexAuth: CodexCLIAuthManager

    @State var testConnectionStatus: String?
    @State var testConnectionDetails: String?
    @State var isTestingConnection = false
    @State var connectionTestID: UUID?
    @State var hasCopiedCode = false
    @State var hasCopiedConnectionError = false
    @State var showModelPicker = false
    @State var isHoveringUsername = false
    @State var isHoveringCodexEmail = false
    @State var isDetailsExpanded = false
    @State var isInternetAccessBlocked = false
    @State var isHoveringInternetSettings = false
    @State var isHoveringCopyError = false
    @State var isHoveringCodexTerminalButton = false
    @State var codexTerminalButtonState: CodexActionVisualState = .idle
    @State var codexTerminalResetTask: Task<Void, Never>?
    @State var codexDeviceAuthDismissTask: Task<Void, Never>?
    @StateObject var deviceCodeCopyFeedback = CopyFeedback()
    @State var isShowingCodexDeviceAuth = false
    @State var connectionSuccessResetTask: Task<Void, Never>?
    @State var connectionTestTask: Task<Void, Never>?

    var isConnectionSuccessful: Bool {
        testConnectionStatus?.contains("Success") == true
    }

    var isConnectionFailed: Bool {
        guard let status = testConnectionStatus else { return false }
        return !isConnectionSuccessful && !status.isEmpty
    }

    let providerColumns = Array(
        repeating: GridItem(.flexible(minimum: 160), spacing: 10),
        count: 3
    )

    var body: some View {
        deviceAuthPresentation
    }

    var providerSelectionSection: some View {
        SettingsCard(title: "Select Provider", icon: "cpu", color: .purple) {
            LazyVGrid(columns: providerColumns, alignment: .leading, spacing: 10) {
                ForEach(AIProvider.userSelectableProviders.filter { $0 != .openCodeGo }, id: \.self) { provider in
                    AIProviderRow(
                        provider: provider,
                        selectedProvider: viewModel.config.provider,
                        action: selectProvider
                    )
                    .settingsFocusable(
                        .providerChoice(provider),
                        shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
            }
        }
        .settingsFocusable(.providerSelect)
    }

    var sections: some View {
        VStack(spacing: 16) {
            providerSelectionSection

            // Provider-specific configuration
            if viewModel.config.provider == .unavailableProvider {
                SettingsCard(title: "Provider unavailable", icon: "exclamationmark.triangle", color: .orange) {
                    Text("GitHub Copilot was removed. Choose an AI provider to continue.")
                        .foregroundStyle(.secondary)
                }
                .settingsFocusable(.providerConfiguration)
            } else if viewModel.config.provider == .appleFoundationModel {
                appleConfigSection
            } else if [.openAI, .openCodeZen, .openCodeGo, .groq, .openAICompatible, .openRouter, .anthropic, .ollama, .gemini].contains(viewModel.config.provider) {
                apiConfigSection
            }

            // Connection Test
            if [.openAI, .openCodeZen, .openCodeGo, .groq, .openAICompatible, .openRouter, .anthropic, .ollama, .gemini, .appleFoundationModel].contains(viewModel.config.provider) {
                connectionSection
            }
        }
    }

    var modelSelectionPresentation: some View {
        sections
        .onAppear {
            if viewModel.config.provider == .openAI {
                codexAuth.checkStatus()
            }
        }
        .onChange(of: viewModel.config.provider) { _, newProvider in
            NotificationManager.shared.dismissHUD(identifier: "setup-repair")
            if newProvider == .openAI {
                codexAuth.checkStatus()
            }
        }
        .onChange(of: viewModel.config) {
            resetConnectionTestState()
        }
        .modelSelectionOverlay(
            isPresented: $showModelPicker,
            currentProvider: viewModel.config.provider,
            currentModel: viewModel.config.model,
            contextMessage: "Choose the provider and model Sorty uses for organization.",
            reasoningEffortForModel: { provider, model in
                viewModel.config.reasoningEffort(for: provider, model: model)
            },
            onSelectReasoningEffort: { provider, model, effort in
                viewModel.config.setReasoningEffort(effort, for: provider, model: model)
            },
            onSelect: { provider, model, authMethod in
                viewModel.config.provider = provider
                viewModel.config.model = model
                if provider == .openAI, supportsSubscriptionAuthUI, let desired = authMethod {
                    if desired != viewModel.config.authMethod(for: .openAI) {
                        setAuthMethod(desired)
                    }
                }
            },
            isSubscriptionSelected: viewModel.config.authMethod(for: viewModel.config.provider) == .accountSignIn
        )
    }

    var deviceAuthPresentation: some View {
        modelSelectionPresentation
        .sheet(isPresented: $isShowingCodexDeviceAuth) {
            CodexDeviceAuthSheet(
                session: codexAuth.deviceAuthSession,
                isCodexInstalled: codexAuth.isCodexInstalled,
                authError: codexAuth.authError,
                onStart: startCodexDeviceAuth,
                onCancel: {
                    codexDeviceAuthDismissTask?.cancel()
                    codexAuth.cancelDeviceAuth()
                    isShowingCodexDeviceAuth = false
                },
                onOpenSettings: openChatGPTSecuritySettings,
                onOpenDeviceAuthorization: openCodexDeviceAuthorization,
                onCopyCode: copyCodexDeviceCode,
                isCodeCopied: deviceCodeCopyFeedback.isCopied
            )
            .frame(width: 610)
            .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
            .systemLiquidGlassPopover(cornerRadius: 12)
        }
        .onChange(of: codexAuth.isAuthenticated) { _, isAuthenticated in
            guard isAuthenticated, isShowingCodexDeviceAuth else { return }
            handleCodexDeviceAuthSuccess()
        }
        .onChange(of: codexAuth.deviceAuthSession?.status) { _, status in
            guard status == .authorized, isShowingCodexDeviceAuth else { return }
            handleCodexDeviceAuthSuccess()
        }
        .onDisappear {
            // The Codex verify loop is owned by .task and cancels with the
            // view; cancel every other stored task here so none outlive it.
            connectionTestTask?.cancel()
            connectionTestTask = nil
            codexTerminalResetTask?.cancel()
            codexTerminalResetTask = nil
            codexDeviceAuthDismissTask?.cancel()
            codexDeviceAuthDismissTask = nil
            connectionSuccessResetTask?.cancel()
            connectionSuccessResetTask = nil
        }
    }

    var apiConfigSection: some View {
        SettingsCard(title: "API Configuration", icon: "key", color: .orange) {
            VStack(alignment: .leading, spacing: 12) {
                if [.openCodeZen, .openCodeGo].contains(viewModel.config.provider) {
                    HStack(spacing: 12) {
                        Text("OpenCode plan")
                        Spacer()
                        CapsuleSegmentedControl(
                            accessibilityLabel: "OpenCode plan",
                            accessibilityIdentifier: "OpenCodePlanPicker",
                            labels: ["Zen", "Go"],
                            selectedIndex: Binding(
                                get: { viewModel.config.provider == .openCodeGo ? 1 : 0 },
                                set: { index in
                                    let provider: AIProvider = index == 1 ? .openCodeGo : .openCodeZen
                                    guard provider != viewModel.config.provider else { return }
                                    HapticFeedbackManager.shared.selection()
                                    selectProvider(provider)
                                }
                            )
                        )
                        .frame(width: 200)
                    }
                }

                if [.openAICompatible, .ollama].contains(viewModel.config.provider) {
                    SettingsTextField(
                        title: "API URL",
                        text: Binding(
                            get: { viewModel.config.apiURL ?? (viewModel.config.provider == .ollama ? "http://localhost:11434/v1" : "https://api.openai.com") },
                            set: { viewModel.config.apiURL = $0.isEmpty ? nil : $0 }
                        ),
                        placeholder: viewModel.config.provider == .ollama ? "http://localhost:11434/v1" : "https://api.openai.com"
                    )
                }

                if viewModel.config.provider == .openAI {
                    openAIAuthenticationSection
                } else {
                    apiKeySection
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
                        provider: viewModel.config.provider,
                        label: selectedModelDisplay,
                        onTap: { showModelPicker = true }
                    )
                    .modelSelectorTriggerBounds()
                }
            }
        }
        .settingsFocusable(.providerConfiguration)
    }

    var supportsSubscriptionAuthUI: Bool {
        FeatureFlags.subscriptionAuthEnabled && viewModel.config.provider.supportsSubscriptionAuth
    }

    func selectProvider(_ provider: AIProvider) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.85)) {
            viewModel.config.provider = provider
            if let defaultURL = provider.defaultAPIURL {
                viewModel.config.apiURL = defaultURL
            }
            viewModel.config.requiresAPIKey = provider.typicallyRequiresAPIKey
            HapticFeedbackManager.shared.selection()
        }
    }

    var selectedAuthMethod: Binding<ProviderAuthMethod> {
        Binding(
            get: { viewModel.config.authMethod(for: viewModel.config.provider) },
            set: { setAuthMethod($0) }
        )
    }

    func setAuthMethod(_ method: ProviderAuthMethod) {
        var nextConfig = viewModel.config
        let provider = nextConfig.provider
        nextConfig.setAuthMethod(method, for: provider)
        withAnimation(authenticationTransitionAnimation) {
            viewModel.config = nextConfig
        }
        viewModel.updateAvailableModels(force: true)
        HapticFeedbackManager.shared.selection()
    }

    var authenticationTransitionAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.16)
            : .spring(response: 0.4, dampingFraction: 0.82)
    }

    var authenticationPanelTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
    }

}


#Preview {
    let codexAuthManager = CodexCLIAuthManager()
    AIProviderSettingsView()
        .environmentObject(AppState())
        .environmentObject(SettingsViewModel())
        .environmentObject(codexAuthManager)
        .frame(width: 500, height: 600)
}

