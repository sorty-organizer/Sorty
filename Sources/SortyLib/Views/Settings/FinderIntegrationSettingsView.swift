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
    @State private var isHoveringExtensions = false

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
            .animatedAppearance(delay: 0.05)

            SettingsCard(title: "Finder extension", icon: "puzzlepiece.extension", color: .cyan) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: statusIcon)
                            .font(.title3)
                            .foregroundStyle(isOn ? Color.green : Color.secondary)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(statusTitle)
                                .font(.subheadline.weight(.semibold))
                            if !isOn {
                                Text(statusDetail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Finder extension: \(statusTitle)")
                    .accessibilityIdentifier("FinderIntegrationStatus")

                    if setupState != nil && !isOn && setupState != .unavailable {
                        Button {
                            HapticFeedbackManager.shared.tap()
                            ExtensionCommunication.openFinderExtensionSettings()
                        } label: {
                            Label("Open macOS Extensions", systemImage: isHoveringExtensions ? "arrow.up.right" : "gearshape")
                                .contentTransition(.symbolEffect(.replace))
                                .transaction { transaction in
                                    if reduceMotion {
                                        transaction.disablesAnimations = true
                                    }
                                }
                        }
                        .buttonStyle(.sortySecondary(size: .regular))
                        .onHover { hovering in
                            if hovering && !isHoveringExtensions {
                                HapticFeedbackManager.shared.selection()
                            }
                            withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
                                isHoveringExtensions = hovering
                            }
                        }
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
            .animatedAppearance(delay: 0.1)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: setupState)
        .task(id: refreshGeneration) {
            setupState = nil
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

    // On reflects macOS enablement; Finder loads the extension as needed.
    private var isOn: Bool {
        setupState == .enabled || setupState == .registered
    }

    private var statusIcon: String {
        if setupState == nil { return "clock" }
        return isOn ? "checkmark.circle.fill" : "circle"
    }

    private var statusTitle: String {
        if setupState == nil { return "Checking…" }
        return isOn ? "On" : "Off"
    }

    private var statusDetail: String {
        switch setupState {
        case nil:
            "Sorty is checking and repairing Finder setup."
        case .enabled, .registered:
            ""
        case .needsEnable:
            "Turn on Sorty in macOS Extensions. This page updates when you return."
        case .pending:
            "Sorty couldn't finish setup automatically. Open macOS Extensions to enable it."
        case .unavailable:
            "Install the latest Sorty app to restore the Finder extension."
        }
    }
}

#Preview {
    FinderIntegrationSettingsView()
        .frame(width: 500)
}
