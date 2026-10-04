//
//  NotificationPermissionCard.swift
//  Sorty
//
//  Notification permission status card component
//

import AppKit
import SwiftUI
import UserNotifications

import Permiso

struct NotificationPermissionCard: View {
    @SortyHotReload private var hotReload
    @ObservedObject private var notificationManager = NotificationManager.shared
    @State private var isRequestingPermission = false
    @State private var isShowingPermissionInfo = false
    @State private var isHoveringMacOSSettings = false
    @State private var isOpeningMacOSSettings = false
    @State private var settingsButtonFrameInScreen: CGRect = .zero

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsMacOSSettingsChevron: Bool {
        isHoveringMacOSSettings || isOpeningMacOSSettings
    }
    
    private var statusInfo: (icon: String, color: Color, title: String, description: String) {
        switch notificationManager.notificationPermissionStatus {
        case .authorized:
            return ("checkmark.circle.fill", .green, "Authorized", "macOS allows Sorty to send notifications")
        case .denied:
            return ("xmark.circle.fill", .red, "Denied", "Open System Settings to enable notifications")
        case .provisional:
            return ("bell.badge.circle.fill", .orange, "Provisional", "Notifications delivered quietly")
        case .notDetermined:
            return ("questionmark.circle.fill", .secondary, "Not Set", "Request permission to enable system notifications")
        @unknown default:
            return ("questionmark.circle.fill", .secondary, "Unknown", "Unable to determine permission status")
        }
    }
    
    var body: some View {
        SettingsCard(title: "macOS Notification Permission", icon: "bell.badge.circle", color: .cyan) {
            VStack(alignment: .leading, spacing: 12) {
                // Status indicator
                HStack(spacing: 12) {
                    Image(systemName: statusInfo.icon)
                        .font(.title2)
                        .foregroundStyle(statusInfo.color)
                        .symbolReplaceTransition(animationValue: statusInfo.icon)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(statusInfo.title))
                            .font(.subheadline.weight(.medium))
                            .numericTextTransition(animationValue: statusInfo.title)
                        Text(LocalizedStringKey(statusInfo.description))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .numericTextTransition(animationValue: statusInfo.description)
                    }
                    
                    Spacer()

                    if notificationManager.notificationPermissionStatus != .authorized {
                        Button {
                            HapticFeedbackManager.shared.tap()
                            isShowingPermissionInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Show what Sorty asks for")
                        .accessibilityLabel("Notification permission information")
                        .onHover { hovering in
                            if hovering {
                                HapticFeedbackManager.shared.selection()
                            }
                        }
                    }
                    
                    // Action button based on status
                    switch notificationManager.notificationPermissionStatus {
                    case .notDetermined:
                        Button {
                            requestPermission()
                        } label: {
                            HStack(spacing: 4) {
                                if isRequestingPermission {
                                    SortyGradientCircularLoader(size: 12, lineWidth: 2.2)
                                } else {
                                    Image(systemName: "bell.badge")
                                }
                                Text("Enable")
                            }
                        }
                        .buttonStyle(.sortyProminent)
                        .disabled(isRequestingPermission)
                        .background(
                            ScreenFrameReader(frameInScreen: $settingsButtonFrameInScreen)
                                .allowsHitTesting(false)
                        )
                        
                    case .denied:
                        Button {
                            openSystemSettings(
                                sourceFrameInScreen: settingsButtonFrameInScreen.isEmpty
                                    ? nil
                                    : settingsButtonFrameInScreen.integral
                            )
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "gear")
                                Text("Open Settings")
                            }
                        }
                        .buttonStyle(.sortyBordered)
                        .background(
                            ScreenFrameReader(frameInScreen: $settingsButtonFrameInScreen)
                                .allowsHitTesting(false)
                        )
                        
                    case .authorized, .provisional:
                        Button {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
                                isOpeningMacOSSettings = true
                            }
                            openSystemSettings()

                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(0.35))
                                withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
                                    isOpeningMacOSSettings = false
                                }
                            }
                        } label: {
                            Label {
                                Text("macOS Settings")
                            } icon: {
                                Image(
                                    systemName: showsMacOSSettingsChevron
                                        ? "arrow.up.right"
                                        : "gearshape"
                                )
                                .contentTransition(.symbolEffect(.replace))
                                .transaction { transaction in
                                    if reduceMotion {
                                        transaction.disablesAnimations = true
                                    }
                                }
                            }
                        }
                        .buttonStyle(.sortyBordered)
                        .controlSize(.small)
                        .help("Open macOS notification settings")
                        .onHover { hovering in
                            withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
                                isHoveringMacOSSettings = hovering
                            }
                        }
                        
                    default:
                        EmptyView()
                    }
                }
                
                // Note about HUD notifications
                if notificationManager.notificationPermissionStatus != .authorized {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                        Text("In-app HUD notifications work regardless of this setting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await notificationManager.checkNotificationPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await notificationManager.checkNotificationPermission()
            }
        }
        .sheet(isPresented: $isShowingPermissionInfo) {
            PermissionEducationView(pages: [.notifications]) {
                isShowingPermissionInfo = false
            }
        }
    }
    
    private func requestPermission() {
        HapticFeedbackManager.shared.tap()
        isRequestingPermission = true
        Task {
            let granted = await notificationManager.requestPermission()
            await notificationManager.checkNotificationPermission()

            await MainActor.run {
                isRequestingPermission = false
                let status = notificationManager.notificationPermissionStatus
                if granted || status == .authorized || status == .provisional {
                    HapticFeedbackManager.shared.success()
                } else {
                    HapticFeedbackManager.shared.error()
                    openSystemSettings(
                        sourceFrameInScreen: settingsButtonFrameInScreen.isEmpty
                            ? nil
                            : settingsButtonFrameInScreen.integral,
                        dismissAfterGrant: true
                    )
                }
            }
        }
    }
    
    private func openSystemSettings(
        sourceFrameInScreen: CGRect? = nil,
        dismissAfterGrant: Bool = false
    ) {
        if let sourceFrameInScreen, !sourceFrameInScreen.isEmpty {
            PermisoAssistant.shared.present(
                panel: .notifications,
                sourceFrameInScreen: sourceFrameInScreen,
                onPermissionGranted: dismissAfterGrant ? {
                    Task { @MainActor in
                        await notificationManager.checkNotificationPermission()
                        HapticFeedbackManager.shared.success()
                    }
                } : nil
            )
            return
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.sorty.app"
        let candidateURLs = [
            "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleIdentifier)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleIdentifier)",
            "x-apple.systempreferences:com.apple.preference.notifications",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ]

        for urlString in candidateURLs {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                return
            }
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

#Preview {
    NotificationPermissionCard()
        .frame(width: 400, height: 150)
}
