//
//  FinderIntegrationSettingsView.swift
//  Sorty
//
//  Finder Integration settings section
//

import SwiftUI

struct FinderIntegrationSettingsView: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOrganizeActionInstalled = false
    @State private var isWatchActionInstalled = false
    @State private var isExcludeActionInstalled = false
    @State private var watchActionMessage: String?
    @State private var finderSyncActive = false
    @State private var finderSyncMessage: String?
    @State private var hasCompletedInitialStatusCheck = false
    @State private var isShowingAutomationPermissionInfo = false
    @State private var isShowingMissingAutomationRecovery = false
    @State private var automationSettingsButtonFrameInScreen: CGRect = .zero
    @EnvironmentObject var automationManager: AutomationManager
    
    var body: some View {
        VStack(spacing: 14) {
            SettingsCard(title: "Finder Integration", icon: "folder.badge.gearshape", color: .cyan) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: overallStatusIcon)
                            .font(.title3)
                            .foregroundStyle(overallStatusColor)
                            .frame(width: 16, height: 24)
                            .symbolReplaceTransition(animationValue: overallStatusIcon)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(overallStatusTitle)
                                .font(.subheadline.weight(.semibold))
                                .numericTextTransition(animationValue: overallStatusTitle)
                            Text(overallStatusSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .numericTextTransition(animationValue: overallStatusSubtitle)
                        }

                        Spacer()

                        Button("Check Now") {
                            Task {
                                await refreshIntegrationStatus()
                                refreshFinderContext()
                            }
                        }
                        .buttonStyle(.sortySecondary(size: .regular))
                        .accessibilityIdentifier("FinderIntegrationRefreshButton")
                        .settingsFocusable(
                            .finderCheckStatus,
                            shape: Capsule(style: .continuous),
                            horizontalRingPadding: 4,
                            verticalRingPadding: 4
                        )
                    }

                    Divider()
                        .opacity(0.35)

                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "cursorarrow.click.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16, alignment: .center)
                            .accessibilityHidden(true)
                        Text("In Finder, right-click a folder to use Organize, Watch, or Exclude.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)

                    VStack(spacing: 8) {
                        compactStatusRow(
                            label: "Organize with Sorty",
                            isHealthy: isOrganizeActionInstalled,
                            focusTarget: .finderOrganize
                        )

                        compactStatusRow(
                            label: "Watch with Sorty",
                            isHealthy: isWatchActionInstalled,
                            focusTarget: .finderWatch
                        )

                        compactStatusRow(
                            label: "Exclude from Sorty",
                            isHealthy: isExcludeActionInstalled,
                            focusTarget: .finderExclude
                        )

                        compactStatusRow(
                            label: "Finder extension",
                            isHealthy: finderSyncActive,
                            focusTarget: .finderExtension
                        )

                        compactStatusRow(
                            label: "Automation permission",
                            isHealthy: automationManager.automationStatus.isGranted,
                            focusTarget: .finderAutomationPermission
                        )
                    }
                }
            }
            .settingsFocusable(.finderIntegration)
            .animatedAppearance(delay: 0.03)

            if shouldShowTroubleshooting {
                SettingsCard(title: "Troubleshooting", icon: "wrench.and.screwdriver", color: .purple) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Sorty repairs the Finder menu action automatically where macOS allows it. Use these only if Finder still does not show Sorty actions.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                finderExtensionButton()
                                openExtensionsButton()

                                if !areFinderMenuActionsInstalled {
                                    repairMenuActionsButton()
                                }

                                runFullCheckButton()
                            }

                            VStack(spacing: 8) {
                                finderExtensionButton(expands: true)

                                HStack(spacing: 8) {
                                    openExtensionsButton(expands: true)
                                    runFullCheckButton(expands: true)
                                }

                                if !areFinderMenuActionsInstalled {
                                    repairMenuActionsButton(expands: true)
                                }
                            }
                        }

                        if automationManager.automationStatus != .granted {
                            HStack(spacing: 8) {
                                Button("Open Automation Settings") {
                                    HapticFeedbackManager.shared.tap()
                                    automationManager.openAutomationSettings(
                                        sourceFrameInScreen: automationSettingsButtonFrameInScreen.isEmpty
                                            ? nil
                                            : automationSettingsButtonFrameInScreen.integral,
                                        onMissingApp: {
                                            isShowingMissingAutomationRecovery = true
                                        }
                                    )
                                }
                                .buttonStyle(.sortySecondary(size: .regular))
                                .background(
                                    ScreenFrameReader(frameInScreen: $automationSettingsButtonFrameInScreen)
                                        .allowsHitTesting(false)
                                )

                                Button("Recover Permission") {
                                    HapticFeedbackManager.shared.tap()
                                    automationManager.recoverAutomationState()
                                    refreshFinderContext()
                                }
                                .buttonStyle(.sortySecondary(size: .regular))
                                .accessibilityIdentifier("FinderAutomationRecoverButton")

                                Button {
                                    HapticFeedbackManager.shared.tap()
                                    isShowingAutomationPermissionInfo = true
                                } label: {
                                    Label("Why this is needed", systemImage: "info.circle")
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if let message = finderSyncMessage ?? watchActionMessage {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                    .accessibilityHidden(true)
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .numericTextTransition(animationValue: message)
                            }
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .animatedAppearance(delay: 0.1)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: shouldShowTroubleshooting)
        .task {
            await refreshIntegrationStatus()
            refreshFinderContext()
            hasCompletedInitialStatusCheck = true
        }
        .sheet(isPresented: $isShowingAutomationPermissionInfo) {
            PermissionEducationView(pages: [.automation]) {
                isShowingAutomationPermissionInfo = false
            }
        }
        .sheet(isPresented: $isShowingMissingAutomationRecovery) {
            AutomationPermissionRecoveryView {
                isShowingMissingAutomationRecovery = false
            }
        }
    }

    @ViewBuilder
    private func compactStatusRow(
        label: String,
        isHealthy: Bool,
        focusTarget: SettingsFocusTarget
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: compactStatusIcon(isHealthy: isHealthy))
                .foregroundStyle(compactStatusColor(isHealthy: isHealthy))
                .font(.caption)
                .frame(width: 16, height: 16, alignment: .center)
                .accessibilityHidden(true)
            Text(label)
                .font(.caption.weight(.medium))
            Spacer()
        }
        .settingsFocusableSetting(focusTarget)
        .accessibilityElement(children: .combine)
        .accessibilityValue(compactStatusAccessibilityValue(isHealthy: isHealthy))
    }

    private func compactStatusIcon(isHealthy: Bool) -> String {
        guard hasCompletedInitialStatusCheck else { return "clock.fill" }
        return isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func compactStatusColor(isHealthy: Bool) -> Color {
        guard hasCompletedInitialStatusCheck else { return .secondary }
        return isHealthy ? .green : .orange
    }

    private func compactStatusAccessibilityValue(isHealthy: Bool) -> String {
        guard hasCompletedInitialStatusCheck else { return "checking" }
        return isHealthy ? "ready" : "needs attention"
    }

    private func refreshFinderContext() {
        automationManager.checkPermissions(enableChecksIfNeeded: true)
    }

    private func finderExtensionButton(expands: Bool = false) -> some View {
        Button {
            HapticFeedbackManager.shared.tap()
            Task {
                let repair = await ExtensionCommunication.repairFinderSyncExtensionRegistrationAsync()
                finderSyncActive = await ExtensionCommunication.isFinderSyncExtensionActiveAsync()
                finderSyncMessage = repair.message
                if repair.success {
                    HapticFeedbackManager.shared.success()
                } else {
                    HapticFeedbackManager.shared.error()
                }
            }
        } label: {
            Text(finderSyncActive ? "Repair Extension" : "Activate Extension")
                .fixedSize(horizontal: !expands, vertical: false)
                .frame(maxWidth: expands ? .infinity : nil)
                .numericTextTransition(animationValue: finderSyncActive)
        }
        .buttonStyle(.sortyPrimary(size: .regular))
    }

    private func openExtensionsButton(expands: Bool = false) -> some View {
        Button {
            HapticFeedbackManager.shared.tap()
            ExtensionCommunication.openFinderExtensionSettings()
        } label: {
            Text("Open macOS Extensions")
                .fixedSize(horizontal: !expands, vertical: false)
                .frame(maxWidth: expands ? .infinity : nil)
        }
        .buttonStyle(.sortySecondary(size: .regular))
    }

    private func repairMenuActionsButton(expands: Bool = false) -> some View {
        Button {
            HapticFeedbackManager.shared.tap()
            Task {
                let result = await ExtensionCommunication.ensureQuickActionInstalledAsync(forceRefreshServices: true)
                await refreshIntegrationStatus()
                watchActionMessage = result.message
                if result.installed {
                    HapticFeedbackManager.shared.success()
                } else {
                    HapticFeedbackManager.shared.error()
                }
            }
        } label: {
            Text("Repair Menu Actions")
                .fixedSize(horizontal: !expands, vertical: false)
                .frame(maxWidth: expands ? .infinity : nil)
        }
        .buttonStyle(.sortySecondary(size: .regular))
    }

    private func runFullCheckButton(expands: Bool = false) -> some View {
        Button {
            HapticFeedbackManager.shared.tap()
            Task {
                await refreshIntegrationStatus()
                refreshFinderContext()
            }
        } label: {
            Text("Run Full Check")
                .fixedSize(horizontal: !expands, vertical: false)
                .frame(maxWidth: expands ? .infinity : nil)
        }
        .buttonStyle(.sortySecondary(size: .regular))
    }

    private var shouldShowTroubleshooting: Bool {
        guard hasCompletedInitialStatusCheck else { return false }
        return !areFinderMenuActionsInstalled || !finderSyncActive || !automationManager.automationStatus.isGranted || finderSyncMessage != nil || watchActionMessage != nil
    }

    private var isFullyReady: Bool {
        areFinderMenuActionsInstalled && finderSyncActive && automationManager.automationStatus.isGranted
    }

    private var areFinderMenuActionsInstalled: Bool {
        isOrganizeActionInstalled && isWatchActionInstalled && isExcludeActionInstalled
    }

    private var overallStatusIcon: String {
        guard hasCompletedInitialStatusCheck else { return "clock.fill" }
        if isFullyReady {
            return "checkmark.circle.fill"
        }
        return automationManager.automationStatus == .denied ? "exclamationmark.triangle.fill" : "wrench.and.screwdriver.fill"
    }

    private var overallStatusColor: Color {
        guard hasCompletedInitialStatusCheck else { return .cyan }
        if isFullyReady {
            return .green
        }
        return automationManager.automationStatus == .denied ? .orange : .cyan
    }

    private var overallStatusTitle: String {
        guard hasCompletedInitialStatusCheck else { return "Checking Finder Sync" }
        return isFullyReady ? "Finder actions are ready" : "Sorty is finishing Finder setup"
    }

    private var overallStatusSubtitle: String {
        guard hasCompletedInitialStatusCheck else {
            return "Sorty is checking the Finder menu actions, extension, and Automation permission."
        }
        if isFullyReady {
            return "Use Finder's right-click menu to organize folders, add watched folders, or exclude paths. Sorty will keep checking this setup in the background."
        }

        if automationManager.automationStatus == .denied {
            return "macOS Automation permission is blocking Finder selection. Sorty can repair the rest automatically, but this permission must be re-enabled in System Settings."
        }

        return "Sorty installs and repairs the Finder menu actions automatically. If macOS needs confirmation, the repair options below will take you to the right place."
    }

    private var automationStatusSummary: String {
        switch automationManager.automationStatus {
        case .granted:
            return "Allowed"
        case .denied:
            return "Blocked"
        case .unknown:
            return "Checking"
        }
    }

    private func refreshIntegrationStatus() async {
        _ = await ExtensionCommunication.ensureQuickActionInstalledAsync()
        let status = await ExtensionCommunication.getIntegrationStatusAsync()
        isOrganizeActionInstalled = status.quickActionInstalled
        isWatchActionInstalled = status.quickWatchActionInstalled
        isExcludeActionInstalled = status.quickExcludeActionInstalled
        finderSyncActive = status.finderSyncEnabled
    }
}

#Preview {
    FinderIntegrationSettingsView()
        .frame(width: 500, height: 400)
}
