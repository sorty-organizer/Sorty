//
//  PermissionsStepView.swift
//  Sorty
//
//  Permissions step of the onboarding flow
//

import AppKit
import AVFoundation
import SwiftUI
import UserNotifications

import Permiso

public struct PermissionsStepView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject private var automationManager: AutomationManager
    @EnvironmentObject private var appState: AppState
    private let assumeFilesPermissionForUITestsKey = "uitestAssumeFilesAndFoldersPermission"
    @Binding var hasRequiredPermissions: Bool
    @State private var permissionStates: [PermissionType: PermissionState] = [:]
    @State private var selectedEducationPermission: PermissionType?
    @State private var isFullDiskAccessConfirmationPresented = false
    @State private var fullDiskAccessSourceFrameInScreen: CGRect?
    @State private var didOpenFullDiskAccessSettings = false
    @State private var isShowingMissingAutomationRecovery = false
    @State private var pendingRemovalPermission: PermissionType?
    @State private var removalFailureMessage: String?
    private let notificationManager = NotificationManager.shared
    @State private var taskController = PermissionsTaskController()

    public init(hasRequiredPermissions: Binding<Bool>) {
        self._hasRequiredPermissions = hasRequiredPermissions
    }

    public var body: some View {
        HStack(spacing: 36) {
            VStack(alignment: .leading, spacing: 22) {
                Spacer()

                VStack(alignment: .leading, spacing: 14) {
                    OnboardingIconSliver(
                        systemName: "hand.raised.fill",
                        color: .blue,
                        fontSize: 44
                    )

                    Text("Permissions")
                        .font(.system(size: 28, weight: .bold, design: .rounded))

                    Text(
                        "Sorty needs Files & Folders access before organizing. Grant optional permissions now if you want Finder actions, broader folder access, or system notifications."
                    )
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 12) {
                        PrivacyFeatureRow(icon: "folder.fill", text: "Files & Folders is required")
                        PrivacyFeatureRow(icon: "lock.open", text: "Full Disk Access is optional")
                        PrivacyFeatureRow(icon: "gearshape.2", text: "Finder Automation is optional")
                        PrivacyFeatureRow(icon: "bell", text: "Notifications are optional")
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: 350)

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, 72)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Grant Access")
                            .font(.title3.weight(.semibold))

                        Text("Choose a folder so Sorty knows where to organize your files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("\(grantedPermissionCount) of \(PermissionType.allCases.count) granted")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(grantedPermissionCount == PermissionType.allCases.count ? .green : .secondary)
                        .numericTextTransition(animationValue: grantedPermissionCount)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.07), in: Capsule(style: .continuous))
                }

                PermissionRow(
                    type: .filesAndFolders,
                    state: permissionStates[.filesAndFolders] ?? .unknown,
                    isRequired: true,
                    onExplain: { selectedEducationPermission = .filesAndFolders },
                    onRequest: { requestPermission(.filesAndFolders, sourceFrameInScreen: $0) },
                    onRemovePermission: { pendingRemovalPermission = .filesAndFolders }
                )

                Text("Optional")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                VStack(spacing: 10) {
                    PermissionRow(
                        type: .fullDiskAccess,
                        state: permissionStates[.fullDiskAccess] ?? .unknown,
                        isRequired: false,
                        onExplain: { selectedEducationPermission = .fullDiskAccess },
                        onRequest: { requestPermission(.fullDiskAccess, sourceFrameInScreen: $0) },
                        onRemovePermission: { pendingRemovalPermission = .fullDiskAccess }
                    )

                    PermissionRow(
                        type: .automation,
                        state: permissionStates[.automation] ?? .unknown,
                        isRequired: false,
                        onExplain: { selectedEducationPermission = .automation },
                        onRequest: { requestPermission(.automation, sourceFrameInScreen: $0) },
                        onRemovePermission: { pendingRemovalPermission = .automation }
                    )

                    PermissionRow(
                        type: .notifications,
                        state: permissionStates[.notifications] ?? .unknown,
                        isRequired: false,
                        onExplain: { selectedEducationPermission = .notifications },
                        onRequest: { requestPermission(.notifications, sourceFrameInScreen: $0) },
                        onRemovePermission: { pendingRemovalPermission = .notifications }
                    )
                }
            }
            .frame(maxWidth: 430)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.trailing, 72)
        }
        .task {
            checkPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissions()
        }
        .onDisappear {
            taskController.permissionRefreshTask?.cancel()
            taskController.permissionRefreshTask = nil
            taskController.automationPermissionTask?.cancel()
            taskController.automationPermissionTask = nil
            taskController.isPermissionRefreshPending = false
        }
        .sheet(item: $selectedEducationPermission) { permission in
            PermissionEducationView(pages: [permission]) {
                selectedEducationPermission = nil
            }
        }
        .sheet(isPresented: $isShowingMissingAutomationRecovery) {
            AutomationPermissionRecoveryView {
                isShowingMissingAutomationRecovery = false
            }
        }
        .alert("Set up Full Disk Access?", isPresented: $isFullDiskAccessConfirmationPresented) {
            Button("Skip for Now", role: .cancel) {
                permissionStates[.fullDiskAccess] = .unknown
                fullDiskAccessSourceFrameInScreen = nil
                didOpenFullDiskAccessSettings = false
            }

            Button("Open System Settings") {
                openFullDiskAccessSettings()
            }
        } message: {
            Text("Full Disk Access is optional and only needed for protected folders. macOS may relaunch Sorty after you turn it on, so it is safe to finish onboarding first and enable this later in Settings.")
        }
        .confirmationDialog(
            removalTitle,
            isPresented: removalConfirmationBinding,
            titleVisibility: .visible
        ) {
            if let permission = pendingRemovalPermission {
                Button(removalActionTitle(for: permission), role: .destructive) {
                    removePermission(permission)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRemovalPermission = nil
            }
        } message: {
            if let permission = pendingRemovalPermission {
                Text(removalMessage(for: permission))
            }
        }
        .alert(
            "Permission Couldn’t Be Removed",
            isPresented: Binding(
                get: { removalFailureMessage != nil },
                set: { if !$0 { removalFailureMessage = nil } }
            )
        ) {
            Button("OK") {
                removalFailureMessage = nil
            }
        } message: {
            Text(removalFailureMessage ?? "Please try again.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permissions Step")
    }

    private func checkPermissions() {
        let assumesFilesPermission = UserDefaults.standard.bool(
            forKey: assumeFilesPermissionForUITestsKey
        )
        if assumesFilesPermission,
           !hasRequiredPermissions {
            hasRequiredPermissions = true
        }

        if taskController.permissionRefreshTask != nil {
            taskController.isPermissionRefreshPending = true
            return
        }
        let didOpenFullDiskAccessSettings = didOpenFullDiskAccessSettings
        taskController.permissionRefreshTask = Task { @MainActor in
            async let canReadProtectedLocation = Task.detached(priority: .utility) {
                FullDiskAccessProbe.isGranted()
            }.value
            await notificationManager.checkNotificationPermission()
            let hasProtectedLocationAccess = await canReadProtectedLocation
            guard !Task.isCancelled else { return }

            let shouldRefreshAgain = taskController.isPermissionRefreshPending
            taskController.isPermissionRefreshPending = false
            taskController.permissionRefreshTask = nil

            if shouldRefreshAgain {
                checkPermissions()
                return
            }

            automationManager.checkPermissions(enableChecksIfNeeded: false)
            let hasVerifiedFilesAccess = assumesFilesPermission
                || appState.hasFilesAndFoldersPermission()
            hasRequiredPermissions = hasVerifiedFilesAccess
            let automationState = permissionState(for: automationManager.automationStatus)
            let refreshedStates: [PermissionType: PermissionState] = [
                .filesAndFolders: hasVerifiedFilesAccess ? .granted : .unknown,
                .fullDiskAccess: fullDiskAccessState(
                    canReadProtectedLocation: hasProtectedLocationAccess,
                    didOpenSettings: didOpenFullDiskAccessSettings
                ),
                .automation: automationState,
                .notifications: notificationState(
                    for: notificationManager.notificationPermissionStatus
                )
            ]

            if permissionStates != refreshedStates {
                permissionStates = refreshedStates
            }
        }
    }

    private var grantedPermissionCount: Int {
        PermissionType.allCases.filter { permissionStates[$0] == .granted }.count
    }

    private func requestPermission(_ type: PermissionType, sourceFrameInScreen: CGRect?) {
        HapticFeedbackManager.shared.tap()

        switch type {
        case .filesAndFolders:
            requestFilesAndFoldersPermission()

        case .fullDiskAccess:
            fullDiskAccessSourceFrameInScreen = sourceFrameInScreen
            isFullDiskAccessConfirmationPresented = true

        case .automation:
            permissionStates[.automation] = .pending

            taskController.automationPermissionTask?.cancel()
            taskController.automationPermissionTask = Task { @MainActor in
                await automationManager.requestAutomationPermissionCheck()
                guard !Task.isCancelled else { return }
                permissionStates[.automation] = permissionState(
                    for: automationManager.automationStatus
                )
                if automationManager.automationStatus == .denied {
                    automationManager.openAutomationSettings(
                        sourceFrameInScreen: sourceFrameInScreen,
                        onMissingApp: { isShowingMissingAutomationRecovery = true }
                    )
                }
                taskController.automationPermissionTask = nil
            }

        case .notifications:
            Task { @MainActor in
                await notificationManager.checkNotificationPermission()

                if notificationManager.notificationPermissionStatus == .denied {
                    permissionStates[.notifications] = .denied
                    openNotificationSettings(sourceFrameInScreen: sourceFrameInScreen)
                    return
                }

                permissionStates[.notifications] = .pending

                let granted = await notificationManager.requestPermission()
                permissionStates[.notifications] = notificationState(
                    for: notificationManager.notificationPermissionStatus
                )

                if granted {
                    HapticFeedbackManager.shared.success()
                } else {
                    HapticFeedbackManager.shared.error()
                    openNotificationSettings(sourceFrameInScreen: sourceFrameInScreen)
                }
            }
        }
    }

    private func openFullDiskAccessSettings() {
        didOpenFullDiskAccessSettings = true
        permissionStates[.fullDiskAccess] = .pending
        PermisoAssistant.shared.present(
            panel: .fullDiskAccess,
            sourceFrameInScreen: fullDiskAccessSourceFrameInScreen,
            onCancel: {
                fullDiskAccessSourceFrameInScreen = nil
                checkPermissions()
            }
        )
    }

    private func fullDiskAccessState(
        canReadProtectedLocation: Bool,
        didOpenSettings: Bool
    ) -> PermissionState {
        if canReadProtectedLocation {
            return didOpenSettings ? .restartRequired : .granted
        }

        return didOpenSettings ? .denied : .unknown
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingRemovalPermission != nil },
            set: { if !$0 { pendingRemovalPermission = nil } }
        )
    }

    private var removalTitle: String {
        guard let permission = pendingRemovalPermission else {
            return "Remove Permission?"
        }

        switch permission {
        case .filesAndFolders:
            return "Remove Current Folder Access?"
        case .fullDiskAccess:
            return "Remove Full Disk Access?"
        case .automation:
            return "Remove Finder Automation?"
        case .notifications:
            return "Disable System Notifications?"
        }
    }

    private func removalActionTitle(for permission: PermissionType) -> String {
        switch permission {
        case .fullDiskAccess:
            return "Open Full Disk Access"
        case .notifications:
            return "Disable in Sorty"
        case .filesAndFolders, .automation:
            return "Remove Permission"
        }
    }

    private func removalMessage(for permission: PermissionType) -> String {
        switch permission {
        case .filesAndFolders:
            return "Sorty will forget the saved folder grant. Your files won’t be changed."
        case .fullDiskAccess:
            return "macOS only lets you remove Full Disk Access in Privacy & Security. Turn Sorty off there, then reopen Sorty."
        case .automation:
            return "Sorty will reset its permission to control Finder. macOS will ask again next time you enable it."
        case .notifications:
            return "Sorty will stop system notifications and clear any queued or delivered alerts. You can turn them back on in Sorty whenever macOS still allows them."
        }
    }

    private func removePermission(_ permission: PermissionType) {
        pendingRemovalPermission = nil

        switch permission {
        case .fullDiskAccess:
            didOpenFullDiskAccessSettings = true
            permissionStates[.fullDiskAccess] = .pending
            if !NSWorkspace.shared.open(PermisoPanel.fullDiskAccess.settingsURL) {
                NSWorkspace.shared.open(
                    URL(fileURLWithPath: "/System/Applications/System Settings.app")
                )
            }

        case .notifications:
            NotificationSettingsManager.shared.settings.systemNotifications = false
            let notificationCenter = UNUserNotificationCenter.current()
            notificationCenter.removeAllPendingNotificationRequests()
            notificationCenter.removeAllDeliveredNotifications()
            HapticFeedbackManager.shared.success()

        case .filesAndFolders, .automation:
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.sorty.app"
            Task { @MainActor in
                let result = await SystemPermissionRevoker.revoke(
                    permission,
                    bundleIdentifier: bundleIdentifier
                )
                guard result.succeeded else {
                    HapticFeedbackManager.shared.error()
                    removalFailureMessage = result.message
                    return
                }

                if permission == .filesAndFolders {
                    // Only balance access this session actually started.
                    appState.releaseSelectedDirectoryAccess()
                    appState.revokeFilesAndFoldersPermission()
                    appState.selectedDirectory = nil
                    hasRequiredPermissions = false
                    permissionStates[.filesAndFolders] = .unknown
                } else {
                    automationManager.markAutomationPermissionReset()
                    permissionStates[.automation] = .unknown
                }
                HapticFeedbackManager.shared.success()
            }
        }
    }

    private func permissionState(for status: PermissionStatus) -> PermissionState {
        switch status {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .unknown:
            return .unknown
        }
    }

    private func notificationState(for status: UNAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized, .provisional:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    private func openNotificationSettings(sourceFrameInScreen: CGRect? = nil) {
        if let sourceFrameInScreen, !sourceFrameInScreen.isEmpty {
            PermisoAssistant.shared.present(
                panel: .notifications,
                sourceFrameInScreen: sourceFrameInScreen,
                onPermissionGranted: {
                    Task { @MainActor in
                        await notificationManager.checkNotificationPermission()
                        permissionStates[.notifications] = .granted
                        HapticFeedbackManager.shared.success()
                    }
                }
            )
            return
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.sorty.app"
        let candidateURLs = [
            "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleIdentifier)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleIdentifier)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ]

        for urlString in candidateURLs {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                return
            }
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func requestFilesAndFoldersPermission() {
        permissionStates[.filesAndFolders] = .pending

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose any folder you want Sorty to organize."
        panel.prompt = "Grant Access"

        if panel.runModal() == .OK,
           let url = panel.url,
           appState.grantFilesAndFoldersPermission(for: url) {
            hasRequiredPermissions = true
            permissionStates[.filesAndFolders] = .granted
            HapticFeedbackManager.shared.success()
        } else {
            hasRequiredPermissions = false
            permissionStates[.filesAndFolders] = .unknown
        }
    }
}

// MARK: - Supporting Types

@MainActor
private final class PermissionsTaskController {
    var permissionRefreshTask: Task<Void, Never>?
    var automationPermissionTask: Task<Void, Never>?
    var isPermissionRefreshPending = false
}






// MARK: - Preview

#Preview {
    PermissionsStepView(hasRequiredPermissions: .constant(false))
}
