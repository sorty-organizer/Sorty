//
//  FinderIntegrationSettingsView.swift
//  Sorty
//
//  Finder actions and macOS extension setup.
//

import AppKit
import SwiftUI

struct FinderIntegrationSettingsView: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var setupState: ExtensionCommunication.FinderSetupState?
    @State private var refreshGeneration = 0

    var body: some View {
        VStack(spacing: 14) {
            SettingsCard(title: "Sorty in Finder", icon: "folder", color: .cyan) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Right-click a folder in Finder to use Sorty without opening the app first.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    actionRow(
                        title: "Organize with Sorty",
                        detail: "Create an organization plan, then review it in Sorty before moving files.",
                        icon: "folder.badge.gearshape",
                        focusTarget: .finderOrganize
                    )
                    actionRow(
                        title: "Watch with Sorty",
                        detail: "Add a folder to Watched Folders to organize new files automatically.",
                        icon: "eye",
                        focusTarget: .finderWatch
                    )
                    actionRow(
                        title: "Exclude from Sorty",
                        detail: "Keep a file or folder out of future organization plans.",
                        icon: "minus.circle",
                        focusTarget: .finderExclude
                    )
                }
            }
            .settingsFocusable(.finderIntegration)

            SettingsCard(title: "Finder extension", icon: "puzzlepiece.extension", color: .cyan) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: statusIcon)
                            .font(.title3)
                            .foregroundStyle(setupState == .enabled ? Color.green : Color.secondary)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(statusTitle)
                                .font(.subheadline.weight(.semibold))
                            Text(statusDetail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("FinderIntegrationStatus")

                    Button("Open macOS Extensions") {
                        HapticFeedbackManager.shared.tap()
                        ExtensionCommunication.openFinderExtensionSettings()
                    }
                    .buttonStyle(.sortySecondary(size: .regular))
                    .accessibilityIdentifier("FinderIntegrationExtensionsButton")
                    .settingsFocusable(
                        .finderExtension,
                        shape: Capsule(style: .continuous),
                        horizontalRingPadding: 4,
                        verticalRingPadding: 4
                    )
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: setupState)
        .task(id: refreshGeneration) {
            let diagnostics = await ExtensionCommunication.prepareFinderIntegrationAsync()
            guard !Task.isCancelled else { return }
            setupState = diagnostics.setupState
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshGeneration += 1
        }
        .onChange(of: setupState) { _, newValue in
            guard newValue != nil else { return }
            AccessibilityNotification.Announcement(statusTitle).post()
        }
    }

    private func actionRow(
        title: String,
        detail: String,
        icon: String,
        focusTarget: SettingsFocusTarget
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.cyan)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsFocusableSetting(focusTarget)
        .accessibilityElement(children: .combine)
    }

    private var statusIcon: String {
        switch setupState {
        case nil: "clock"
        case .enabled: "checkmark.circle.fill"
        case .needsEnable: "puzzlepiece.extension"
        case .unavailable: "info.circle"
        case .pending: "info.circle"
        }
    }

    private var statusTitle: String {
        switch setupState {
        case nil: "Setting up Finder actions"
        case .enabled: "Enabled in Finder"
        case .needsEnable: "Enable Sorty in macOS"
        case .unavailable: "Finder extension unavailable"
        case .pending: "Finder hasn't loaded Sorty yet"
        }
    }

    private var statusDetail: String {
        switch setupState {
        case nil:
            "Sorty is preparing the right-click menu automatically."
        case .enabled:
            "Right-click a folder and look for Sorty. macOS manages whether the extension is enabled."
        case .needsEnable:
            "In System Settings, open General > Login Items & Extensions > Finder and turn on Sorty. This page updates when you return."
        case .pending:
            "Open macOS Extensions to confirm Sorty is enabled. If Finder still shows an older copy of Sorty, reopen Finder after enabling it."
        case .unavailable:
            "This copy of Sorty could not load its Finder extension. Install the latest Sorty app to use it."
        }
    }
}

#Preview {
    FinderIntegrationSettingsView()
        .frame(width: 500)
}
