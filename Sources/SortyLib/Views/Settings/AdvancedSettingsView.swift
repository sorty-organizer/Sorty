//
//  AdvancedSettingsView.swift
//  Sorty
//
//  Advanced settings section
//

import SwiftUI
import UniformTypeIdentifiers

struct AdvancedSettingsView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var viewModel: SettingsViewModel
    @EnvironmentObject var automationManager: AutomationManager
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("privacyModeEnabled") private var privacyModeEnabled = true
    @AppStorage(NetworkPrivacyPolicy.internetPrivacyModeKey) private var internetPrivacyModeEnabled = false
    @ObservedObject private var analytics = AnalyticsManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var diagnosticReportError: String?
    @State private var isGeneratingDiagnosticReport = false

    private var analyticsEnabled: Binding<Bool> {
        Binding(
            get: { analytics.consent == .granted },
            set: { analytics.setConsent($0 ? .granted : .denied) }
        )
    }

    private var analyticsDescription: String {
        if analytics.consent == .granted, internetPrivacyModeEnabled {
            return "Allowed, but paused while Block Internet Connections is on"
        }
        return "Share anonymous feature usage and sanitized reliability data; never file names, paths, contents, prompts, or AI responses"
    }
    
    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Menu Bar", icon: "menubar.rectangle", color: .blue) {
                SettingsToggle(
                    isOn: $showMenuBarExtra,
                    title: "Show Menu Bar Icon",
                    description: "Display Sorty icon in the menu bar for quick access",
                    focusTarget: .advancedMenuBar
                )
            }
            .animatedAppearance(delay: 0.0)

            SettingsCard(
                title: "Finder Workflow",
                icon: "folder.badge.gearshape",
                color: .mint
            ) {
                SettingsToggle(
                    isOn: $automationManager.autoSelectOrganizedFolders,
                    title: "Automatically reveal organized folders",
                    description: "Open Finder and highlight newly organized folders after each completed run",
                    focusTarget: .advancedFinderWorkflow
                )
                .accessibilityIdentifier("FinderAutoRevealToggle")
            }
            .animatedAppearance(delay: 0.03)

            SettingsCard(title: "Privacy", icon: "lock.shield", color: .green) {
                VStack(spacing: 12) {
                    SettingsToggle(
                        isOn: $privacyModeEnabled,
                        title: "Privacy Mode",
                        description: "Mask usernames, paths, API keys, and raw AI details in the interface",
                        focusTarget: .advancedPrivacyMode
                    )
                    .accessibilityIdentifier("PrivacyModeToggle")

                    Divider()

                    SettingsToggle(
                        isOn: $internetPrivacyModeEnabled,
                        title: "Block Internet Connections",
                        description: "Allow only localhost requests for local models and offline workflows",
                        focusTarget: .advancedInternetPrivacy
                    )
                    .accessibilityIdentifier("InternetPrivacyModeToggle")
                    .onChange(of: internetPrivacyModeEnabled) { _, isEnabled in
                        analytics.networkPrivacyDidChange(isEnabled: isEnabled)
                    }

                    Divider()

                    SettingsToggle(
                        isOn: analyticsEnabled,
                        title: "Share Anonymous Analytics",
                        description: analyticsDescription,
                        focusTarget: .advancedAnalytics
                    )
                    .accessibilityIdentifier("AnonymousAnalyticsToggle")
                }
            }
            .animatedAppearance(delay: 0.04)
            
            SettingsCard(title: "Timeouts", icon: "clock", color: .orange) {
                VStack(spacing: 16) {
                    TimeoutSliderRow(
                        title: "Request Timeout",
                        description: "Time to wait for initial response",
                        value: $viewModel.config.requestTimeout,
                        sliderMin: 30,
                        defaultMax: 600,
                        step: 10,
                        focusTarget: .advancedRequestTimeout
                    )

                    Divider()

                    TimeoutSliderRow(
                        title: "Resource Timeout",
                        description: "Maximum total request duration",
                        value: $viewModel.config.resourceTimeout,
                        sliderMin: 60,
                        defaultMax: 1800,
                        step: 60,
                        focusTarget: .advancedResourceTimeout
                    )
                }
            }
            .settingsFocusable(.advancedTimeouts)
            .animatedAppearance(delay: 0.1)
            
            SettingsCard(title: "Developer", icon: "hammer", color: .gray) {
                VStack(spacing: 12) {
                    SettingsToggle(
                        isOn: $viewModel.config.showStatsForNerds,
                        title: "Stats for Nerds",
                        description: "Show live AI metrics — tokens, throughput, timing, and cost — in preview, results, and history",
                        focusTarget: .advancedStats
                    )
                    
                    Divider()
                    
                    Button {
                        HapticFeedbackManager.shared.tap()
                        let panel = NSSavePanel()
                        panel.title = "Save Diagnostic Report"
                        panel.nameFieldStringValue = "Sorty-Diagnostic.zip"
                        panel.allowedContentTypes = [.zip]
                        panel.canCreateDirectories = true
                        guard panel.runModal() == .OK, let destination = panel.url else { return }
                        guard !isGeneratingDiagnosticReport else { return }
                        isGeneratingDiagnosticReport = true
                        Task { @MainActor in
                            defer { isGeneratingDiagnosticReport = false }
                            do {
                                _ = try await LogManager.shared.generateDiagnosticReport(
                                    config: viewModel.config,
                                    at: destination
                                )
                                HapticFeedbackManager.shared.success()
                                AnalyticsManager.shared.captureFeature(
                                    feature: "support",
                                    subfeature: "diagnostic_report",
                                    action: "generated",
                                    outcome: "success"
                                )
                                NSWorkspace.shared.activateFileViewerSelecting([destination])
                            } catch {
                                HapticFeedbackManager.shared.error()
                                diagnosticReportError = error.localizedDescription
                            }
                        }
                    } label: {
                        HStack {
                            if isGeneratingDiagnosticReport {
                                if reduceMotion {
                                    Image(systemName: "hourglass")
                                    Text("Generating…")
                                } else {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Generating…")
                                }
                            } else {
                                Image(systemName: "doc.zipper")
                                Text("Generate Diagnostic Report")
                            }
                        }
                    }
                    .buttonStyle(.sortyProminent(intent: .destructive))
                    .disabled(isGeneratingDiagnosticReport)
                    .settingsFocusableSetting(.advancedErrorLogs)
                    .accessibilityIdentifier("GenerateDiagnosticReportButton")
                    .onHover { hovering in
                        if hovering {
                            HapticFeedbackManager.shared.selection()
                        }
                    }
                }
            }
            .settingsFocusable(.advancedDeveloper)
            .animatedAppearance(delay: 0.15)
        }
        .alert(
            "Couldn’t Generate Report",
            isPresented: Binding(
                get: { diagnosticReportError != nil },
                set: { if !$0 { diagnosticReportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(diagnosticReportError ?? "")
        }
    }
}

// MARK: - Timeout Slider with Editable Maximum

private struct TimeoutSliderRow: View {
    @SortyHotReload private var hotReload
    let title: String
    let description: String
    @Binding var value: TimeInterval
    let sliderMin: Double
    let defaultMax: Double
    let step: Double
    let focusTarget: SettingsFocusTarget

    @State private var editingMax = false
    @State private var maxText = ""
    @State private var customMax: Double?
    @FocusState private var maxFieldFocused: Bool
    
    private var effectiveMax: Double {
        if let customMax, customMax > sliderMin { return customMax }
        return max(defaultMax, value)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(LocalizedStringKey(title))
                    .font(.subheadline)
                Spacer()
                Text("\(Int(value))s")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
                    .numericTextTransition(animationValue: value)
            }
            
            HStack(spacing: 8) {
                NoTickSlider(value: $value, in: sliderMin...effectiveMax, step: step)
                
                if editingMax {
                    TextField("Max", text: $maxText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .font(.subheadline.monospacedDigit())
                        .focused($maxFieldFocused)
                        .onSubmit { commitMax() }
                        .onAppear {
                            maxText = "\(Int(effectiveMax))"
                            maxFieldFocused = true
                        }
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            editingMax = true
                        }
                    } label: {
                        Text("\(Int(effectiveMax))s")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .numericTextTransition(animationValue: effectiveMax)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Click to set custom maximum")
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                            HapticFeedbackManager.shared.selection()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
            }
            
            Text(LocalizedStringKey(description))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .settingsFocusableSetting(focusTarget)
    }
    
    private func commitMax() {
        if let parsed = Double(maxText), parsed >= sliderMin {
            let rounded = (parsed / step).rounded() * step
            withAnimation(.easeInOut(duration: 0.15)) {
                customMax = rounded
                if value > rounded { value = rounded }
            }
            HapticFeedbackManager.shared.success()
        }
        withAnimation(.easeInOut(duration: 0.15)) {
            editingMax = false
        }
    }
}

#Preview {
    AdvancedSettingsView()
        .environmentObject(SettingsViewModel())
        .environmentObject(AutomationManager())
        .frame(width: 500, height: 500)
}
