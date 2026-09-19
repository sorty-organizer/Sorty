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
    @State private var hasAppeared = false
    @State private var permissionStates: [PermissionType: PermissionState] = [:]
    @State private var selectedEducationPermission: PermissionType?
    @State private var isFullDiskAccessConfirmationPresented = false
    @State private var fullDiskAccessSourceFrameInScreen: CGRect?
    @State private var didOpenFullDiskAccessSettings = false
    @State private var isShowingMissingAutomationRecovery = false
    @State private var pendingRemovalPermission: PermissionType?
    @State private var removalFailureMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                .opacity(hasAppeared ? 1 : 0)
                .offset(x: hasAppeared ? 0 : -20)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.8).delay(0.1),
                    value: hasAppeared
                )

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
            .opacity(hasAppeared ? 1 : 0)
            .offset(x: hasAppeared ? 0 : 18)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.86).delay(0.12), value: hasAppeared)
        }
        .onAppear {
            hasAppeared = true
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

enum PermissionType: String, CaseIterable, Identifiable, Sendable {
    case filesAndFolders = "Files & Folders"
    case fullDiskAccess = "Full Disk Access"
    case automation = "Automation"
    case notifications = "Notifications"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .filesAndFolders: return "folder.fill"
        case .fullDiskAccess: return "lock.open.fill"
        case .automation: return "gearshape.2.fill"
        case .notifications: return "bell.fill"
        }
    }

    var description: String {
        switch self {
        case .filesAndFolders: return "Choose a folder so Sorty can organize files"
        case .fullDiskAccess: return "Optional for protected folders; may relaunch Sorty"
        case .automation: return "Read Finder selections for Finder Integration"
        case .notifications: return "Get notified when organization completes"
        }
    }

    func description(for state: PermissionState) -> String {
        if self == .fullDiskAccess, state == .restartRequired {
            return "Full Disk Access is on. Restart Sorty to use it."
        }

        return description
    }

    var color: Color {
        switch self {
        case .filesAndFolders: return .blue
        case .fullDiskAccess: return .green
        case .automation: return .orange
        case .notifications: return .purple
        }
    }

    var educationTitle: String {
        switch self {
        case .filesAndFolders:
            return "Files & Folders"
        case .fullDiskAccess:
            return "Full Disk Access"
        case .automation:
            return "Finder Automation"
        case .notifications:
            return "Notifications"
        }
    }

    var educationDescription: String {
        switch self {
        case .filesAndFolders:
            return "Lets Sorty access folders you explicitly choose with the macOS picker. This is required before Sorty can scan and organize files."
        case .fullDiskAccess:
            return "Lets Sorty organize protected folders you explicitly choose, such as Desktop, Documents, Downloads, or external locations macOS protects. macOS may relaunch Sorty after this is enabled, so it is usually better to finish onboarding first."
        case .automation:
            return "Lets Sorty read the current Finder selection for Finder Integration actions. Sorty only asks when you use Finder-driven workflows."
        case .notifications:
            return "Lets Sorty send completion and error alerts through macOS Notification Center. In-app HUD alerts still work without it."
        }
    }

    var educationActionTitle: String {
        switch self {
        case .filesAndFolders:
            return "Choose Folder"
        case .fullDiskAccess:
            return "Review Restart Note"
        case .automation:
            return "Enable Finder Automation"
        case .notifications:
            return "Enable Notifications"
        }
    }

    var compactActionTitle: String {
        switch self {
        case .filesAndFolders:
            return "Choose Folder"
        case .fullDiskAccess:
            return "Review"
        case .automation:
            return "Enable"
        case .notifications:
            return "Enable"
        }
    }
}

enum PermissionState: Sendable, Equatable {
    case unknown
    case pending
    case granted
    case restartRequired
    case denied

    var title: String {
        switch self {
        case .unknown: return "Not granted"
        case .pending: return "Check Settings"
        case .granted: return "Granted"
        case .restartRequired: return "Restart Sorty"
        case .denied: return "Needs Attention"
        }
    }

    func title(for type: PermissionType) -> String {
        guard self == .pending else { return title }

        switch type {
        case .filesAndFolders:
            return "Choosing Folder"
        case .fullDiskAccess:
            return "Finish in Settings"
        case .automation:
            return "Requesting"
        case .notifications:
            return "Enabling"
        }
    }

    var symbol: String {
        switch self {
        case .unknown: return "circle"
        case .pending: return "arrow.clockwise"
        case .granted: return "checkmark"
        case .restartRequired: return "arrow.clockwise"
        case .denied: return "exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .unknown: return .secondary
        case .pending: return .orange
        case .granted: return .green
        case .restartRequired: return .blue
        case .denied: return .red
        }
    }
}

struct PermissionRow: View {
    @SortyHotReload private var hotReload
    let type: PermissionType
    let state: PermissionState
    let isRequired: Bool
    let onExplain: () -> Void
    let onRequest: (CGRect?) -> Void
    let removePermissionTitle: String
    let onRemovePermission: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @State private var grantFlash = false
    @State private var grantAnimationTrigger = 0

    init(
        type: PermissionType,
        state: PermissionState,
        isRequired: Bool,
        onExplain: @escaping () -> Void,
        onRequest: @escaping (CGRect?) -> Void,
        removePermissionTitle: String = "Remove Permission…",
        onRemovePermission: (() -> Void)? = nil
    ) {
        self.type = type
        self.state = state
        self.isRequired = isRequired
        self.onExplain = onExplain
        self.onRequest = onRequest
        self.removePermissionTitle = removePermissionTitle
        self.onRemovePermission = onRemovePermission
    }

    var body: some View {
        HStack(spacing: 14) {
            permissionIcon

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(LocalizedStringKey(type.rawValue))
                        .font(.headline)

                    if isRequired {
                        Text("Required")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(SortyDesignSystem.Colors.resolvedAccent.opacity(0.12), in: Capsule(style: .continuous))
                    }
                }

                Text(type.description(for: state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            trailingControl
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(rowFill)
        )
        .systemLiquidGlassBackground(cornerRadius: 14, interactive: false)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(rowStroke, lineWidth: state == .granted || grantFlash ? 1.2 : 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.12 : 0.05), radius: isHovering ? 12 : 7, x: 0, y: isHovering ? 6 : 3)
        .scaleEffect(grantFlash ? 1.012 : (isHovering ? 1.006 : 1))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: state)
        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86), value: isHovering)
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.82), value: grantFlash)
        .onHover { hovering in
            isHovering = hovering
        }
        .onChange(of: state) { _, newState in
            guard newState == .granted || newState == .restartRequired else { return }
            grantAnimationTrigger += 1
            playApprovalAnimation()
        }
        .contextMenu {
            if canRemovePermission, let onRemovePermission {
                Button(role: .destructive) {
                    HapticFeedbackManager.shared.tap()
                    onRemovePermission()
                } label: {
                    Label(LocalizedStringKey(removePermissionTitle), systemImage: "minus.circle")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var canRemovePermission: Bool {
        state == .granted || state == .restartRequired
    }

    private var iconTint: Color {
        state == .granted || state == .restartRequired ? state.tint : type.color
    }

    private var rowFill: Color {
        if state == .granted {
            return Color.green.opacity(colorScheme == .dark ? 0.12 : 0.08)
        }

        return Color(nsColor: .controlBackgroundColor)
            .opacity(colorScheme == .dark ? (isHovering ? 0.82 : 0.68) : (isHovering ? 0.94 : 0.82))
    }

    private var rowStroke: Color {
        if grantFlash || state == .granted {
            return Color.green.opacity(grantFlash ? 0.72 : 0.34)
        }

        if isHovering {
            return type.color.opacity(0.30)
        }

        return Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08)
    }

    private var permissionIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(iconTint.opacity(state == .granted ? 0.18 : 0.13))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(iconTint.opacity(state == .granted ? 0.28 : 0.18), lineWidth: 1)
                }

            PermissionAnimatedIcon(
                type: type,
                state: state,
                grantAnimationTrigger: grantAnimationTrigger,
                size: 19
            )
                .foregroundStyle(iconTint)
        }
        .frame(width: 46, height: 46)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch state {
        case .granted, .pending, .restartRequired:
            statusChip
        case .denied:
            PermissionActionButton(title: deniedActionTitle, style: .bordered, action: onRequest)
                .fixedSize()
        case .unknown:
            HStack(spacing: 8) {
                Button {
                    HapticFeedbackManager.shared.tap()
                    onExplain()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        HapticFeedbackManager.shared.selection()
                    }
                }
                .help("Show what Sorty asks for")
                .accessibilityLabel("Learn about \(type.rawValue)")

                PermissionActionButton(
                    title: type.compactActionTitle,
                    style: isRequired ? .primary : .bordered,
                    action: onRequest
                )
                .fixedSize()
            }
        }
    }

    private var deniedActionTitle: String {
        switch type {
        case .automation:
            return "Try Again"
        case .notifications:
            return "Enable in Settings"
        default:
            return type.compactActionTitle
        }
    }

    private var statusChip: some View {
        HStack(spacing: 6) {
            Image(systemName: state.symbol)
                .font(.system(size: 11, weight: .bold))
                .symbolReplaceTransition(animationValue: state)
            Text(state.title(for: type))
                .font(.caption.weight(.semibold))
                .numericTextTransition(animationValue: state)
        }
        .foregroundStyle(state.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(state.tint.opacity(0.12), in: Capsule(style: .continuous))
        .accessibilityLabel(state.title(for: type))
    }

    private func playApprovalAnimation() {
        HapticFeedbackManager.shared.success()
        guard !reduceMotion else { return }

        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
            grantFlash = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            withAnimation(.easeOut(duration: 0.24)) {
                grantFlash = false
            }
        }
    }
}

struct PermissionEducationView: View {
    @SortyHotReload private var hotReload
    let pages: [PermissionType]
    let onFinish: () -> Void
    @State private var currentPage = 0

    private var page: PermissionType {
        pages[min(currentPage, max(pages.count - 1, 0))]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            educationPage(page)
                .id(page.id)
                .transition(.opacity.combined(with: .scale(scale: 1.01)))

            if pages.count > 1 {
                pageIndicator
                    .padding(.bottom, 8)
            }
        }
        .systemLiquidGlassPopover(cornerRadius: 18)
        .animation(.easeOut(duration: 0.18), value: currentPage)
    }

    private func educationPage(_ permission: PermissionType) -> some View {
        VStack(spacing: 0) {
            permissionHero(permission)
                .frame(width: 640, height: 360)

            VStack(spacing: 8) {
                Text(permission.educationTitle)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(permission.educationDescription)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)

                HStack(spacing: 10) {
                    if currentPage > 0 {
                        Button {
                            currentPage -= 1
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .buttonStyle(.sortySecondary(size: .regular))
                    }

                    Button {
                        if currentPage == pages.count - 1 {
                            onFinish()
                        } else {
                            currentPage += 1
                        }
                    } label: {
                        Label(currentPage == pages.count - 1 ? "Done" : "Continue", systemImage: currentPage == pages.count - 1 ? "checkmark" : "chevron.right")
                            .symbolReplaceTransition(animationValue: currentPage)
                    }
                    .buttonStyle(.sortyPrimary(size: .regular))
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 10)
            }
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .frame(width: 640)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func permissionHero(_ permission: PermissionType) -> some View {
        if let resourceName = permission.demoVideoResourceName {
            PermissionDemoVideoView(permission: permission, resourceName: resourceName)
        } else {
            permissionExplanationHero(permission)
        }
    }

    private func permissionExplanationHero(_ permission: PermissionType) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .controlBackgroundColor),
                    permission.color.opacity(0.22),
                    Color(nsColor: .windowBackgroundColor),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 14) {
                Image(systemName: permission.icon)
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.86))

                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(permission.color)
                    Text(permission.educationTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.82))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.08))
                .clipShape(Capsule(style: .continuous))
            }
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 7) {
            ForEach(pages.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == currentPage ? Color.primary.opacity(0.82) : Color.secondary.opacity(0.28))
                    .frame(width: index == currentPage ? 22 : 7, height: 7)
            }
        }
        .accessibilityLabel("Page \(currentPage + 1) of \(pages.count)")
    }
}

struct AutomationPermissionRecoveryView: View {
    @SortyHotReload private var hotReload
    let onFinish: () -> Void
    private let resetCommand = "tccutil reset AppleEvents com.sorty.app"
    @State private var hasCopiedResetCommand = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Sorty isn't listed", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)

            Text(
                "macOS did not register Sorty's request to control Finder. The Automation pane cannot add it manually."
            )
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("1. Quit Sorty.")
                Text("2. Run this in Terminal:")
                HStack(spacing: 8) {
                    Text(resetCommand)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)

                    Spacer(minLength: 0)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(resetCommand, forType: .string)
                        HapticFeedbackManager.shared.success()

                        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72)) {
                            hasCopiedResetCommand = true
                        }

                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.5))
                            guard !Task.isCancelled else { return }
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                hasCopiedResetCommand = false
                            }
                        }
                    } label: {
                        Image(systemName: hasCopiedResetCommand ? "checkmark" : "doc.on.doc")
                            .symbolReplaceTransition(animationValue: hasCopiedResetCommand)
                            .symbolEffect(.bounce, value: hasCopiedResetCommand)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy repair command")
                    .accessibilityLabel("Copy repair command")
                    .accessibilityHint("Copies the Terminal command to restore the Automation permission entry")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("3. Reopen Sorty and choose Enable again.")
            }
            .font(.body)

            HStack {
                Spacer()

                Button("Done") {
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

private struct PermissionDemoVideoView: View {
    @SortyHotReload private var hotReload
    let permission: PermissionType
    let resourceName: String

    var body: some View {
        ZStack {
            Color.black

            if let videoURL {
                LoopingPermissionVideoView(url: videoURL)
            } else {
                permissionDemoFallback
            }
        }
        .accessibilityLabel("\(permission.educationTitle) permission demo video")
    }

    private var videoURL: URL? {
        SortyResources.bundle.url(forResource: resourceName, withExtension: "mp4")
    }

    private var permissionDemoFallback: some View {
        VStack(spacing: 14) {
            Image(systemName: permission.icon)
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))

            Text(permission.educationTitle)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.10))
                .clipShape(Capsule(style: .continuous))
        }
    }
}

private extension PermissionType {
    var demoVideoResourceName: String? {
        switch self {
        case .filesAndFolders:
            return "files-and-folders-demo"
        case .fullDiskAccess:
            return "full-disk-access-demo"
        case .automation:
            return "automation-demo"
        case .notifications:
            return nil
        }
    }
}

private struct LoopingPermissionVideoView: NSViewRepresentable {
    @SortyHotReload private var hotReload
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.configure(url: url, playerView: view)
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        context.coordinator.configure(url: url, playerView: nsView)
    }

    static func dismantleNSView(_ nsView: PlayerLayerView, coordinator: Coordinator) {
        coordinator.stop()
        nsView.playerLayer.player = nil
    }

    @MainActor
    final class Coordinator {
        private var currentURL: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private weak var playerView: PlayerLayerView?
        private var observers: [NSObjectProtocol] = []

        func configure(url: URL, playerView: PlayerLayerView) {
            self.playerView = playerView
            let playerLayer = playerView.playerLayer
            if currentURL == url, let player {
                if playerLayer.player !== player {
                    playerLayer.player = player
                }
                return
            }

            let queuePlayer = AVQueuePlayer()
            queuePlayer.isMuted = true
            queuePlayer.actionAtItemEnd = .none

            let item = AVPlayerItem(url: url)
            looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
            player = queuePlayer
            currentURL = url
            playerLayer.player = queuePlayer
            queuePlayer.play()
            installActivityObserversIfNeeded()
        }

        func stop() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
            player?.pause()
            player?.removeAllItems()
            player = nil
            looper = nil
            currentURL = nil
        }

        private func installActivityObserversIfNeeded() {
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.player?.pause() }
                },
                center.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        guard self?.playerView?.window?.isVisible == true else { return }
                        self?.player?.play()
                    }
                }
            ]
        }
    }
}

private final class PlayerLayerView: NSView {
    override var wantsUpdateLayer: Bool { true }

    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private struct PermissionActionButton: View {
    @SortyHotReload private var hotReload
    enum Style {
        case primary
        case bordered
    }

    let title: String
    let style: Style
    let action: (CGRect?) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frameInScreen: CGRect = .zero
    @State private var isHovering = false

    var body: some View {
        Button {
            action(frameInScreen.isEmpty ? nil : frameInScreen.integral)
        } label: {
            Text(LocalizedStringKey(title))
                .frame(minWidth: style == .primary ? 74 : 96)
        }
        .buttonStyle(buttonStyle)
        .onboardingBeamBorder(variant: style == .primary ? .standard : .info, active: isHovering)
        .contentShape(Capsule())
        .background(
            ScreenFrameReader(frameInScreen: $frameInScreen)
                .allowsHitTesting(false)
        )
        .scaleEffect(isHovering && !reduceMotion ? 1.015 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            if hovering && !isHovering {
                HapticFeedbackManager.shared.selection()
            }
            isHovering = hovering
        }
        .accessibilityLabel(title)
    }

    private var buttonStyle: SortyPrimaryButtonStyle {
        switch style {
        case .primary:
            return .init(size: .small)
        case .bordered:
            return .init(isSecondary: true, size: .small)
        }
    }
}

// MARK: - Preview

#Preview {
    PermissionsStepView(hasRequiredPermissions: .constant(false))
}
