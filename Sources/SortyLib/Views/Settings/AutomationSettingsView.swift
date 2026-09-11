//
//  AutomationSettingsView.swift
//  Sorty
//
//  Settings for automation and watched folder AI configuration
//

import SwiftUI

struct AutomationSettingsView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var viewModel: SettingsViewModel
    @EnvironmentObject var loginItemManager: LoginItemManager

    @AppStorage("keepInBackground") private var keepInBackground = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    
    @State private var useSeparateModel = false
    @State private var selectedProvider: AIProvider = .openAI
    @State private var selectedModel: String = ""
    @State private var showModelPicker = false
    @State private var showAutomationModelInfo = false
    @State private var showBackgroundInfo = false
    @State private var isLoadingSettings = true
    
    var body: some View {
        VStack(spacing: 16) {
            globalModelSection
                .animatedAppearance(delay: 0.05)

            backgroundBehaviorSection
                .animatedAppearance(delay: 0.1)
        }
        .onAppear {
            loadAutomationSettings()
            Task { @MainActor in
                await Task.yield()
                isLoadingSettings = false
            }
        }
    }
    
    private var globalModelSection: some View {
        SettingsCard(title: "Global Automation Model", icon: "cpu.fill", color: .green) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $useSeparateModel) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Use separate model for automation")
                                .font(.subheadline)

                            Button {
                                HapticFeedbackManager.shared.tap()
                                showAutomationModelInfo.toggle()
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("About using a separate automation model")
                            .accessibilityLabel("Separate automation model information")
                            .onHover { hovering in
                                if hovering {
                                    HapticFeedbackManager.shared.selection()
                                }
                            }
                            .popover(isPresented: $showAutomationModelInfo, arrowEdge: .trailing) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Separate Automation Model")
                                        .font(.headline)

                                    Text("The main Organize page keeps using the model selected under AI Provider. For faster, more responsive automation, try a smaller model such as GPT-5.6 Luna (High).")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(14)
                                .frame(width: 300, alignment: .leading)
                                .systemLiquidGlassPopover(cornerRadius: 12)
                            }
                        }

                        Text("Run background tasks with a different AI model")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .settingsFocusableSetting(.automationSeparateModel)
                .onChange(of: useSeparateModel) { _, newValue in
                    if !newValue {
                        viewModel.config.automationProvider = nil
                        viewModel.config.automationModel = nil
                    } else {
                        if selectedModel.isEmpty {
                            selectedModel = selectedProvider.defaultModel
                        }
                        viewModel.config.automationProvider = selectedProvider
                        viewModel.config.automationModel = selectedModel
                    }
                    if !isLoadingSettings {
                        AnalyticsManager.shared.captureSettingChanged(
                            "Use separate model for automation",
                            isEnabled: newValue,
                            section: "automation"
                        )
                    }
                }
                
                if useSeparateModel {
                    Divider()

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automation Model")
                                .font(.subheadline)
                            Text("Overrides the main organization model")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        ModelSelectorCompactButton(
                            provider: selectedProvider,
                            label: selectedModelDisplay,
                            onTap: { showModelPicker = true }
                        )
                        .modelSelectorTriggerBounds()
                    }
                }
            }
        }
        .settingsFocusable(.automationGlobalModel)
        .modelSelectionOverlay(
            isPresented: $showModelPicker,
            currentProvider: selectedProvider,
            currentModel: selectedModel,
            contextMessage: "Choose the provider and model Sorty uses for watched-folder automation.",
            reasoningEffortForModel: { provider, model in
                viewModel.config.reasoningEffort(for: provider, model: model)
            },
            onSelectReasoningEffort: { provider, model, effort in
                viewModel.config.setReasoningEffort(effort, for: provider, model: model)
            },
            onSelect: { provider, model, authMethod in
                if let authMethod {
                    viewModel.config.setAuthMethod(authMethod, for: provider)
                }
                selectedProvider = provider
                selectedModel = model
                viewModel.config.automationProvider = provider
                viewModel.config.automationModel = model
            },
            isSubscriptionSelected: viewModel.config.authMethod(for: selectedProvider) == .accountSignIn
        )
    }

    private var selectedModelDisplay: String {
        selectedModel.isEmpty ? selectedProvider.defaultModel : selectedModel
    }

    private var backgroundBehaviorSection: some View {
        SettingsCard(title: "Background Behavior", icon: "menubar.rectangle", color: .purple) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $launchAtLogin) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at Login")
                                .font(.subheadline)
                            Text("Automatically start Sorty when you log in to macOS")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .settingsFocusableSetting(.automationLaunchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        AnalyticsManager.shared.captureSettingChanged(
                            "Launch at Login",
                            isEnabled: newValue,
                            section: "automation"
                        )
                    }

                    Toggle(isOn: $keepInBackground) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Keep in Background")
                                    .font(.subheadline)

                                Button {
                                    HapticFeedbackManager.shared.tap()
                                    showBackgroundInfo.toggle()
                                } label: {
                                    Image(systemName: "info.circle")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Keep in Background information")
                                .onHover { hovering in
                                    if hovering {
                                        HapticFeedbackManager.shared.selection()
                                    }
                                }
                                .popover(isPresented: $showBackgroundInfo, arrowEdge: .trailing) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text("Background Activity")
                                                .font(.headline)
                                            Spacer()
                                            backgroundStatusBadge
                                        }

                                        Text("Enabling background features registers Sorty as a background activity app in System Settings, allowing it to perform tasks like folder watching reliably. It is recommended to keep this on.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(14)
                                    .frame(width: 280, alignment: .leading)
                                    .systemLiquidGlassPopover(cornerRadius: 12)
                                }
                            }

                            Text("Continue monitoring folders even when all windows are closed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .settingsFocusableSetting(.automationKeepInBackground)
                    .onChange(of: keepInBackground) { _, newValue in
                        AnalyticsManager.shared.captureSettingChanged(
                            "Keep in Background",
                            isEnabled: newValue,
                            section: "automation"
                        )
                    }

                    @AppStorage("hideDockIcon") var hideDockIcon = false
                    Toggle(isOn: $hideDockIcon) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hide Dock Icon")
                                .font(.subheadline)
                            Text("Run as a menu bar app without showing in the Dock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .settingsFocusableSetting(.automationHideDockIcon)
                    .onChange(of: hideDockIcon) { _, newValue in
                        AnalyticsManager.shared.captureSettingChanged(
                            "Hide Dock Icon",
                            isEnabled: newValue,
                            section: "automation"
                        )
                    }
                }

            }
        }
    }

    private var backgroundStatusBadge: some View {
        Label(backgroundStatusTitle, systemImage: loginItemManager.isBackgroundAgentEnabled ? "checkmark.circle.fill" : "circle")
            .font(.caption.weight(.medium))
            .foregroundStyle(loginItemManager.isBackgroundAgentEnabled ? .green : .secondary)
            .symbolReplaceTransition(
                animationValue: loginItemManager.isBackgroundAgentEnabled
            )
            .numericTextTransition(animationValue: backgroundStatusTitle)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((loginItemManager.isBackgroundAgentEnabled ? Color.green : Color.secondary).opacity(0.08))
            .clipShape(Capsule())
            .accessibilityLabel("Background activity status is \(backgroundStatusTitle)")
    }

    private var backgroundStatusTitle: String {
        if loginItemManager.isBackgroundAgentEnabled {
            return "On"
        }

        if keepInBackground, !loginItemManager.agentStatus.isEmpty {
            return loginItemManager.agentStatus
        }

        return "Off"
    }
    
    private func loadAutomationSettings() {
        if let provider = viewModel.config.automationProvider {
            useSeparateModel = true
            selectedProvider = provider
            selectedModel = viewModel.config.automationModel ?? provider.defaultModel
        } else {
            useSeparateModel = false
            selectedProvider = viewModel.config.provider
            selectedModel = viewModel.config.model
        }
    }
}

#Preview {
    AutomationSettingsView()
        .environmentObject(SettingsViewModel.preview)
        .environmentObject(WatchedFoldersManager())
        .environmentObject(AppState())
        .frame(width: 500, height: 600)
}
