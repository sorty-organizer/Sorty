import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Beam

/// Privacy-safe support artifacts: a copyable Markdown summary for issues and a
/// ZIP of logs and diagnostics for deeper investigation.
struct SupportReportsCard: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var viewModel: SettingsViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var reportCopyFeedback = CopyFeedback()
    @State private var diagnosticReportError: String?
    @State private var isGeneratingDiagnosticReport = false

    private var copiedIssueDetails: Bool { reportCopyFeedback.isCopied }

    var body: some View {
        SettingsCard(title: "Reports", icon: "clipboard", color: .blue) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Copy a privacy-safe report containing app and configuration details. It never includes file names, folder paths, prompts, credentials, or AI responses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        SupportDetailChip(label: "App", value: BuildInfo.fullVersion)
                        SupportDetailChip(label: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                        SupportDetailChip(label: "Arch", value: systemArchitecture)
                    }

                    Button {
                        copyIssueDetails()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: copiedIssueDetails ? "checkmark" : "doc.on.doc")
                                .symbolReplaceTransition(animationValue: copiedIssueDetails)

                            Text(copiedIssueDetails ? "Copied Support Report" : "Copy Support Report")
                                .numericTextTransition(animationValue: copiedIssueDetails)
                        }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.sortyProminent(intent: .secondary))
                    .accessibilityIdentifier("CopyIssueDetailsButton")
                    .accessibilityValue(copiedIssueDetails ? "Copied" : "")
                    .onHover { hovering in
                        if hovering {
                            HapticFeedbackManager.shared.selection()
                        }
                    }
                }
                .settingsFocusableSetting(.troubleshootingSupportReport)

                Divider()

                Text("Save a ZIP with recent logs and diagnostics when a bug needs deeper investigation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    generateDiagnosticReport()
                } label: {
                    HStack {
                        if isGeneratingDiagnosticReport {
                            if reduceMotion {
                                Image(systemName: "hourglass")
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Generating…")
                        } else {
                            Image(systemName: "doc.zipper")
                            Text("Generate Diagnostic Report")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.sortyProminent(intent: .secondary))
                .disabled(isGeneratingDiagnosticReport)
                .settingsFocusableSetting(.troubleshootingDiagnosticReport)
                .accessibilityIdentifier("GenerateDiagnosticReportButton")
                .onHover { hovering in
                    if hovering {
                        HapticFeedbackManager.shared.selection()
                    }
                }
            }
        }
        .settingsFocusable(.troubleshootingReports)
        .onDisappear {
            reportCopyFeedback.cancel()
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

    private func generateDiagnosticReport() {
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
    }

    private func copyIssueDetails() {
        reportCopyFeedback.copy(issueDetailsText,
            animation: reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7),
            resetAnimation: reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7),
            haptic: { HapticFeedbackManager.shared.success() })
        AnalyticsManager.shared.captureFeature(
            feature: "support",
            subfeature: "support_report",
            action: "copied",
            outcome: "success"
        )

    }


    private var issueDetailsText: String {
        let processInfo = ProcessInfo.processInfo
        let config = viewModel.config
        let defaults = UserDefaults.standard
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let memory = ByteCountFormatter.string(fromByteCount: Int64(processInfo.physicalMemory), countStyle: .memory)
        return """
        ### What happened
        <!-- Describe what you expected and what Sorty did instead. -->

        ### Environment
        - Sorty: \(BuildInfo.fullVersion)
        - Commit: \(BuildInfo.shortCommit)
        - Bundle ID: \(bundleID)

        ### System
        - macOS: \(processInfo.operatingSystemVersionString)
        - Architecture: \(systemArchitecture)
        - CPU cores: \(processInfo.activeProcessorCount)
        - Memory: \(memory)
        - Locale: \(Locale.current.identifier)

        ### AI Configuration
        - Provider: \(config.provider.displayName)
        - Model: \(config.model.isEmpty ? config.provider.defaultModel : config.model)
        - Auth method: \(config.authMethod(for: config.provider).displayName)
        - API URL configured: \(yesNo(config.apiURL?.isEmpty == false))
        - Requires API key: \(yesNo(config.requiresAPIKey))
        - Mode: \(config.mode.displayName)
        - Deep scan: \(yesNo(config.enableDeepScan))
        - Vision: \(yesNo(config.enableVision))
        - Vision detail: \(config.effectiveVisionDetailLevel.displayName)
        - Images selected for vision: \(config.limitVisionImages ? "\(config.visionBatchStrategy.displayName), max \(config.visionBatchSize)" : "All images")
        - Smart rename: \(yesNo(config.enableSmartRename))
        - Duplicate detection: \(yesNo(config.detectDuplicates))
        - File tagging: \(yesNo(config.enableFileTagging))
        - Strict exclusions: \(yesNo(config.strictExclusions))
        - Streaming: \(yesNo(config.enableStreaming))
        - Decision explanations: \(yesNo(config.enableReasoning))
        - Reasoning effort: \(config.reasoningEffort.displayName)
        - Request timeout: \(Int(config.requestTimeout))s
        - Resource timeout: \(Int(config.resourceTimeout))s

        ### App Settings
        - Privacy mode: \(yesNo(defaults.bool(forKey: "privacyModeEnabled")))
        - Internet privacy mode: \(yesNo(FeatureFlags.internetPrivacyModeEnabled))
        - Menu bar extra: \(yesNo(defaults.object(forKey: "showMenuBarExtra") as? Bool ?? true))
        - Completed onboarding: \(yesNo(defaults.bool(forKey: "hasCompletedOnboarding")))

        """
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private var systemArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

struct SupportDetailChip: View {
    @SortyHotReload private var hotReload
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
