//
//  TroubleshootingSettingsView.swift
//  Sorty
//
//  Troubleshooting settings section
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Beam

struct TroubleshootingSettingsView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var viewModel: SettingsViewModel
    @EnvironmentObject var learningsManager: LearningsManager
    @ObservedObject private var analytics = AnalyticsManager.shared
    
    @State private var cacheSize: String = "Calculating..."
    @State private var isClearingCache = false
    @State private var cacheSizeTask: Task<Void, Never>?
    @State private var showingResetConfirmation = false
    @State private var showingDeleteDataConfirmation = false
    @State private var healthChecks: [SupportHealthCheck] = []
    @State private var isRunningHealthCheck = false
    
    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Maintenance", icon: "wrench.and.screwdriver", color: .orange) {
                HStack(spacing: 10) {
                    MaintenanceActionTile(
                        title: "Cache",
                        description: "Clear temporary files and cached app data.",
                        detail: cacheSize,
                        icon: "internaldrive",
                        color: .orange,
                        buttonTitle: isClearingCache ? "Clearing…" : "Clear",
                        buttonIcon: "trash",
                        focusTarget: .troubleshootingCache,
                        isBusy: isClearingCache
                    ) {
                        clearCache()
                    }
                    .accessibilityIdentifier("ClearCacheButton")

                    MaintenanceActionTile(
                        title: "Learnings Data",
                        description: "Delete recorded patterns and personalizations.",
                        detail: nil,
                        icon: "brain.head.profile",
                        color: .purple,
                        buttonTitle: "Delete All",
                        buttonIcon: "trash",
                        focusTarget: .troubleshootingLearnings
                    ) {
                        showingDeleteDataConfirmation = true
                    }

                    MaintenanceActionTile(
                        title: "All Sorty Data",
                        description: "Erase settings, history, learnings, credentials, and caches.",
                        detail: nil,
                        icon: "arrow.counterclockwise",
                        color: .red,
                        buttonTitle: appState.isDeletingUsageData ? "Erasing…" : "Erase All",
                        buttonIcon: "trash",
                        focusTarget: .troubleshootingReset,
                        isBusy: appState.isDeletingUsageData
                    ) {
                        showingResetConfirmation = true
                    }
                    .accessibilityIdentifier("EraseAllDataButton")
                }
            }
            .settingsFocusable(.troubleshootingMaintenance)
            .onAppear {
                calculateCacheSize()
            }
            .onDisappear {
                cacheSizeTask?.cancel()
            }
            .alert("Delete All Learning Data?", isPresented: $showingDeleteDataConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        let didClear = await learningsManager.clearAllData()
                        if didClear {
                            HapticFeedbackManager.shared.success()
                        } else {
                            HapticFeedbackManager.shared.error()
                        }
                    }
                }
            } message: {
                Text("This will permanently delete all your learning data. This cannot be undone.")
            }
            .alert("Erase All Sorty Data?", isPresented: $showingResetConfirmation) {
                Button("Keep Data", role: .cancel) {}
                Button("Erase All Data", role: .destructive) {
                    appState.deleteUsageData()
                }
            } message: {
                Text("This permanently removes Sorty settings, history, learnings, saved credentials, and caches from this Mac. You'll return to onboarding. This cannot be undone.")
            }

            SettingsCard(title: "Support Assistant", icon: "stethoscope", color: .teal) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(healthCheckSummary)
                                .font(.subheadline.weight(.semibold))

                            Text("Sorty checks its configuration and Finder integration locally, then points you to the exact setting that needs attention.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Button {
                            runHealthCheck()
                        } label: {
                            HStack(spacing: 6) {
                                if isRunningHealthCheck {
                                    BouncingSpinner(size: 12, color: .accentColor)
                                } else {
                                    Image(systemName: "waveform.path.ecg")
                                }
                                Text(isRunningHealthCheck ? "Checking" : healthChecks.isEmpty ? "Run Checks" : "Check Again")
                            }
                        }
                        .buttonStyle(.sortyBordered(intent: .info, size: .small))
                        .disabled(isRunningHealthCheck)
                        .accessibilityIdentifier("RunSupportHealthCheckButton")
                    }

                    if isRunningHealthCheck {
                        HStack(spacing: 8) {
                            BouncingSpinner(size: 14, color: .secondary)
                            Text("Checking configuration…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !healthChecks.isEmpty {
                        Divider()

                        VStack(spacing: 8) {
                            ForEach(healthChecks) { check in
                                SupportHealthCheckRow(check: check) {
                                    openSupportDestination(check.destination)
                                }
                            }
                        }
                    }
                }
            }
            .settingsFocusable(.troubleshootingAssistant)
            .task {
                guard healthChecks.isEmpty else { return }
                // Health checks probe Finder; start after the page settles.
                try? await Task.sleep(for: .milliseconds(SettingsPageTransition.settleMilliseconds))
                guard !Task.isCancelled else { return }
                runHealthCheck()
            }

            SupportReportsCard()
        }
    }

    private var healthCheckSummary: String {
        if isRunningHealthCheck {
            return "Checking Sorty…"
        }
        guard !healthChecks.isEmpty else {
            return "Find and fix common problems"
        }
        let attentionCount = healthChecks.filter { $0.status == .needsAttention }.count
        return attentionCount == 0
            ? "Everything checked looks healthy"
            : "\(attentionCount) \(attentionCount == 1 ? "item needs" : "items need") attention"
    }

    private func runHealthCheck() {
        guard !isRunningHealthCheck else { return }
        isRunningHealthCheck = true
        AnalyticsManager.shared.captureFeature(
            feature: "support",
            subfeature: "health_check",
            action: "started",
            outcome: "started"
        )

        Task { @MainActor in
            let finderDiagnostics = await ExtensionCommunication.getFinderSyncDiagnosticsAsync()
            let config = viewModel.config
            var checks: [SupportHealthCheck] = []

            if config.requiresAPIKey,
               config.authMethod(for: config.provider) == .apiKey,
               config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                checks.append(
                    SupportHealthCheck(
                        id: "provider",
                        title: "AI Provider",
                        detail: "\(config.provider.displayName) needs an API key before Sorty can organize files.",
                        status: .needsAttention,
                        actionTitle: "Open Provider",
                        destination: .providerConfiguration
                    )
                )
            } else {
                checks.append(
                    SupportHealthCheck(
                        id: "provider",
                        title: "AI Provider",
                        detail: "\(config.provider.displayName) has the configuration required to make a request.",
                        status: .healthy,
                        actionTitle: nil,
                        destination: nil
                    )
                )
            }

            if FeatureFlags.internetPrivacyModeEnabled,
               config.provider != .ollama,
               config.provider != .appleFoundationModel {
                checks.append(
                    SupportHealthCheck(
                        id: "network",
                        title: "Internet Access",
                        detail: "Block Internet Connections is preventing \(config.provider.displayName) from receiving requests.",
                        status: .needsAttention,
                        actionTitle: "Review Setting",
                        destination: .privacyBlockInternet
                    )
                )
            } else {
                checks.append(
                    SupportHealthCheck(
                        id: "network",
                        title: "Internet Access",
                        detail: FeatureFlags.internetPrivacyModeEnabled
                            ? "Sorty is configured for an offline provider."
                            : "Sorty is allowed to contact the configured provider.",
                        status: .healthy,
                        actionTitle: nil,
                        destination: nil
                    )
                )
            }

            checks.append(
                SupportHealthCheck(
                    id: "finder",
                    title: "Finder Integration",
                    detail: finderDiagnostics.detailMessage,
                    status: finderDiagnostics.isOperational ? .healthy : .needsAttention,
                    actionTitle: finderDiagnostics.isOperational ? nil : "Open Repair",
                    destination: finderDiagnostics.isOperational ? nil : .finderExtension
                )
            )

            let analyticsDetail: String
            let analyticsStatus: SupportHealthStatus
            if analytics.isActive {
                analyticsDetail = "Anonymous reliability analytics are active and can help classify support problems."
                analyticsStatus = .healthy
            } else if analytics.consent == .granted {
                analyticsDetail = "Analytics are allowed but currently paused by an app privacy setting."
                analyticsStatus = .informational
            } else {
                analyticsDetail = "Analytics are off. Local checks and support reports still work normally."
                analyticsStatus = .informational
            }
            checks.append(
                SupportHealthCheck(
                    id: "analytics",
                    title: "Support Context",
                    detail: analyticsDetail,
                    status: analyticsStatus,
                    actionTitle: analytics.isActive ? nil : "Privacy Settings",
                    destination: analytics.isActive ? nil : .privacyAnalytics
                )
            )

            healthChecks = checks
            isRunningHealthCheck = false

            let attentionCount = checks.filter { $0.status == .needsAttention }.count
            AnalyticsManager.shared.captureFeature(
                feature: "support",
                subfeature: "health_check",
                action: "completed",
                outcome: attentionCount == 0 ? "healthy" : "attention_needed",
                properties: [
                    "count_bucket": AnalyticsManager.countBucket(attentionCount),
                ]
            )
        }
    }

    private func openSupportDestination(_ destination: SettingsFocusTarget?) {
        guard let destination else { return }
        AnalyticsManager.shared.captureFeature(
            feature: "support",
            subfeature: "health_check",
            action: "opened_recovery",
            outcome: "success",
            properties: ["selection_kind": destination.rawValue]
        )
        HapticFeedbackManager.shared.tap()
        appState.openSettingsWindow(focusTarget: destination)
    }
    
    private func calculateCacheSize() {
        // Cancel any in-flight scan so a stale result can never overwrite a newer one.
        cacheSizeTask?.cancel()
        let directories = cacheDirectories
        cacheSizeTask = Task.detached(priority: .utility) {
            let size = CacheMaintenance.totalSize(of: directories)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                cacheSize = CacheMaintenance.formatBytes(size)
            }
        }
    }

    private func clearCache() {
        guard !isClearingCache else { return }
        isClearingCache = true
        cacheSizeTask?.cancel()
        cacheSize = "Clearing…"
        HapticFeedbackManager.shared.tap()

        Task {
            // File I/O runs off the main actor so a large cache never freezes Settings.
            let deletionErrors = await Task.detached(priority: .userInitiated) {
                CacheMaintenance.clear()
            }.value

            URLCache.shared.removeAllCachedResponses()
            FileThumbnailProvider.shared.clearCache()
            ImageVisionAnalyzer.clearSharedCache()

            isClearingCache = false
            calculateCacheSize()

            if let error = deletionErrors.first {
                HapticFeedbackManager.shared.error()
                NotificationManager.shared.showError(
                    message: "Some cached data could not be cleared: \(error.localizedDescription)"
                )
            } else {
                HapticFeedbackManager.shared.success()
            }
        }
    }

    private var cacheDirectories: [URL] {
        CacheMaintenance.cacheDirectories()
    }
}


// MARK: - Components





#Preview {
    TroubleshootingSettingsView()
        .environmentObject(SettingsViewModel())
        .environmentObject(NotificationSettingsManager.shared)
        .environmentObject(AppState())
        .environmentObject(LearningsManager())
        .frame(width: 560, height: 300)
}
