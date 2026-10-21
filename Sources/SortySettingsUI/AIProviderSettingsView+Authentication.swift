import Foundation
import AppKit
import SwiftUI

// MARK: - Authentication
extension AIProviderSettingsView {
    @ViewBuilder
    var openAIAuthenticationSection: some View {
        if supportsSubscriptionAuthUI {
            VStack(alignment: .leading, spacing: 10) {
                ProviderAuthenticationControl(
                    methods: viewModel.config.provider.supportedAuthMethods,
                    selection: selectedAuthMethod
                )
                .frame(maxWidth: .infinity)

                switch viewModel.config.authMethod(for: .openAI) {
                case .apiKey, .manualSessionToken:
                    apiKeySection
                        .transition(authenticationPanelTransition)
                case .accountSignIn:
                    codexSubscriptionSection
                        .transition(authenticationPanelTransition)
                }
            }
        } else {
            apiKeySection
        }
    }

    var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if [.openCodeZen, .openCodeGo].contains(viewModel.config.provider) {
                OpenCodeCredentialLinkView(viewModel: viewModel)
                    .id(viewModel.config.provider)
            }
            if viewModel.config.provider == .ollama {
                // Sorty never stores or sends an Ollama credential, so a key
                // field that silently drops the value would mislead users.
                Text("Ollama runs without an API key. Sorty doesn't send credentials to Ollama, so protect remote servers at the network layer.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !viewModel.config.usesConnectedOpenCodeCredentials(for: viewModel.config.provider) {
                SettingsSecureField(
                    title: "API Key",
                    text: Binding(
                        get: { viewModel.config.apiKey ?? "" },
                        set: { viewModel.updateAPIKey($0) }
                    ),
                    isOptional: !viewModel.config.requiresAPIKey
                )
            }

            if !viewModel.config.usesConnectedOpenCodeCredentials(for: viewModel.config.provider),
               let url = viewModel.config.provider.apiKeyURL {
                HStack(spacing: 4) {
                    Text(viewModel.config.provider == .ollama ? "Find Ollama models at" : "Get your API key from")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .numericTextTransition(
                            animationValue: viewModel.config.provider
                        )
                    Link(destination: url) {
                        Text(viewModel.config.provider.apiKeyLinkLabel)
                            .font(.caption)
                            .underline()
                    }
                    .trackHoveredURL(url)
                }
            } else if !viewModel.config.usesConnectedOpenCodeCredentials(for: viewModel.config.provider) {
                Text(viewModel.config.provider.apiKeyHelpText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    var codexSubscriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if codexAuth.isAuthenticated {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Codex subscription ready")
                            .font(.subheadline.weight(.semibold))
                        Text(codexAuth.accountEmail ?? "Signed in via Codex CLI")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .blur(radius: (FeatureFlags.privacyModeEnabled && !isHoveringCodexEmail) ? 4 : 0)
                            .animation(.spring(), value: isHoveringCodexEmail)
                            .onHover { hovering in
                                isHoveringCodexEmail = hovering
                            }
                    }

                    Spacer()

                    Button("Sign Out") {
                        codexAuth.signOut()
                    }
                    .buttonStyle(.sortyBordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text("Use your ChatGPT subscription for OpenAI inference through Codex CLI device authorization.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    startCodexDeviceAuth()
                    isShowingCodexDeviceAuth = true
                } label: {
                    Label(codexDeviceAuthButtonTitle, systemImage: codexDeviceAuthButtonSymbol)
                }
                .buttonStyle(.sortyBordered)
                .controlSize(.small)
                .accessibilityIdentifier("CodexDeviceAuthButton")
                .onHover { hovering in isHoveringCodexTerminalButton = hovering }

                if !codexAuth.isCodexInstalled {
                    Label("Codex CLI not detected", systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let error = codexAuth.authError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task {
            await autoVerifyCodexSignInLoop()
        }
    }

    var codexDeviceAuthButtonTitle: String {
        switch codexTerminalButtonState {
        case .idle:
            return "Authenticate ChatGPT Subscription"
        case .activating:
            return "Starting Authorization..."
        case .success:
            return "Authorization Started"
        case .failure:
            return "Could Not Start Authorization"
        }
    }

    var codexDeviceAuthButtonSymbol: String {
        switch codexTerminalButtonState {
        case .idle:
            return "person.crop.circle.badge.checkmark"
        case .activating:
            return "arrow.triangle.2.circlepath"
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "xmark.circle.fill"
        }
    }

    var appleConfigSection: some View {
        SettingsCard(title: "Apple Models", icon: "apple.logo", color: .gray) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model")
                            .font(.subheadline)
                        Text("Runs privately on this Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    ModelSelectorCompactButton(
                        provider: .appleFoundationModel,
                        label: selectedModelDisplay,
                        onTap: { showModelPicker = true }
                    )
                    .modelSelectorTriggerBounds()
                }

                if !viewModel.isAppleModelAvailable {
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("On-device model unavailable")
                                .font(.caption)
                                .fontWeight(.medium)
                            Text(viewModel.appleModelStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .numericTextTransition(
                                    animationValue: viewModel.appleModelStatus
                                )
                        }
                    }
                }
            }
        }
        .settingsFocusable(.providerConfiguration)
    }

    var selectedModelDisplay: String {
        viewModel.config.model.isEmpty ? "Choose model" : viewModel.config.model
    }
}
