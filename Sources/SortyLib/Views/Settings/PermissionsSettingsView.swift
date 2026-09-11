//
//  PermissionsSettingsView.swift
//  Sorty
//
//  Central place to review and manage macOS permissions used by Sorty
//

import AppKit
import SwiftUI
import UserNotifications

import Permiso

struct PermissionsSettingsView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var automationManager: AutomationManager
    @ObservedObject private var notificationManager = NotificationManager.shared
    @ObservedObject private var notificationSettings = NotificationSettingsManager.shared

    @State private var permissionStates: [PermissionType: PermissionState] = [:]
    @State private var selectedEducationPermission: PermissionType?
    @State private var fullDiskAccessSourceFrameInScreen: CGRect?
    @State private var didOpenFullDiskAccessSettings = false
    @State private var activeAlert: PermissionsSettingsAlert?
    @State private var grantAnimationTriggers: [PermissionType: Int] = [:]
    @State private var refreshStatusAnimationTrigger = 0
    @State private var isHoveringRefreshStatus = false
    @State private var isHoveringOpenPrivacySettings = false
    @State private var isOpeningPrivacySettings = false
    @State private var privacyHoverSettleTask: Task<Void, Never>?
    @State private var privacyOpenResetTask: Task<Void, Never>?
    @State private var isShowingAccessInfo = false
    @State private var hoveredAccessInfoAction: AccessInfoAction?
    @State private var automationPermissionTask: Task<Void, Never>?
    @State private var isShowingMissingAutomationRecovery = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var readyPermissionCount: Int {
        PermissionType.allCases.filter { type in
            let state = permissionStates[type]
            return state == .granted || state == .restartRequired
        }.count
    }

    private var showsOpenPrivacySettingsChevron: Bool {
        isHoveringOpenPrivacySettings || isOpeningPrivacySettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(
                title: "Permission Status",
                icon: "hand.raised.fill",
                color: .blue,
                headerAccessory: {
                    statusSummary
                }
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    PermissionSettingsCard(
                        type: .filesAndFolders,
                        state: permissionStates[.filesAndFolders] ?? .unknown,
                        isRequired: true,
                        isFeatured: true,
                        grantAnimationTrigger: grantAnimationTriggers[.filesAndFolders] ?? 0,
                        onExplain: { selectedEducationPermission = .filesAndFolders },
                        onRequest: { _ in requestFilesAndFoldersPermission() },
                        removePermissionTitle: "Remove Current Folder Access…",
                        onRemovePermission: { activeAlert = .revoke(.filesAndFolders) }
                    )
                    .settingsFocusable(
                        .permissionsFilesAndFolders,
                        shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(
                                .flexible(minimum: 10, maximum: .infinity),
                                spacing: 10
                            ),
                            count: 3
                        ),
                        spacing: 10
                    ) {
                        PermissionSettingsCard(
                            type: .fullDiskAccess,
                            state: permissionStates[.fullDiskAccess] ?? .unknown,
                            isRequired: false,
                            grantAnimationTrigger: grantAnimationTriggers[.fullDiskAccess] ?? 0,
                            onExplain: { selectedEducationPermission = .fullDiskAccess },
                            onRequest: { sourceFrame in
                                fullDiskAccessSourceFrameInScreen = sourceFrame
                                activeAlert = .fullDiskAccessSetup
                            },
                            onRemovePermission: { activeAlert = .revoke(.fullDiskAccess) }
                        )
                        .settingsFocusable(
                            .permissionsFullDiskAccess,
                            shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )

                        PermissionSettingsCard(
                            type: .automation,
                            state: permissionStates[.automation] ?? .unknown,
                            isRequired: false,
                            grantAnimationTrigger: grantAnimationTriggers[.automation] ?? 0,
                            onExplain: { selectedEducationPermission = .automation },
                            onRequest: { requestAutomationPermission(sourceFrameInScreen: $0) },
                            onRemovePermission: { activeAlert = .revoke(.automation) }
                        )
                        .settingsFocusable(
                            .permissionsAutomation,
                            shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )

                        PermissionSettingsCard(
                            type: .notifications,
                            state: permissionStates[.notifications] ?? .unknown,
                            isRequired: false,
                            grantAnimationTrigger: grantAnimationTriggers[.notifications] ?? 0,
                            onExplain: { selectedEducationPermission = .notifications },
                            onRequest: { requestNotificationPermission(sourceFrameInScreen: $0) },
                            removePermissionTitle: "Disable in Sorty",
                            onRemovePermission: { activeAlert = .revoke(.notifications) }
                        )
                        .settingsFocusable(
                            .permissionsNotifications,
                            shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    }

                    Divider()
                        .opacity(0.35)

                    HStack(spacing: 10) {
                        Button {
                            HapticFeedbackManager.shared.tap()
                            refreshStatusAnimationTrigger += 1
                            Task {
                                await refreshPermissions()
                            }
                        } label: {
                            Label {
                                Text("Refresh Status")
                                    .lineLimit(1)
                            } icon: {
                                Image(systemName: "arrow.clockwise")
                                    .symbolEffect(.rotate, options: .speed(1.5), value: refreshStatusAnimationTrigger)
                            }
                        }
                        .buttonStyle(.sortySecondary(size: .regular))
                        .onHover { hovering in
                            if hovering && !isHoveringRefreshStatus {
                                HapticFeedbackManager.shared.selection()
                            }
                            isHoveringRefreshStatus = hovering
                        }

                        Spacer(minLength: 16)

                        Button(action: openPrivacySettings) {
                            Label {
                                Text("Open Privacy & Security")
                                    .lineLimit(1)
                            } icon: {
                                Image(
                                    systemName: showsOpenPrivacySettingsChevron
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
                        .buttonStyle(.sortySecondary(size: .regular))
                        .onHover { hovering in
                            privacyHoverSettleTask?.cancel()
                            privacyHoverSettleTask = nil
                            if hovering {
                                guard !isHoveringOpenPrivacySettings else { return }
                                // Ignore brief passes; leaving cancels the pending hover feedback.
                                privacyHoverSettleTask = Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(120))
                                    guard !Task.isCancelled else { return }
                                    HapticFeedbackManager.shared.selection()
                                    withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
                                        isHoveringOpenPrivacySettings = true
                                    }
                                    privacyHoverSettleTask = nil
                                }
                            } else {
                                withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
                                    isHoveringOpenPrivacySettings = false
                                }
                            }
                        }
                    }
                    .settingsFocusableSetting(.permissionsStatusActions)
                }
            }

            SettingsCard(
                title: "How Sorty Uses Access",
                icon: "lock.shield",
                color: .green,
                headerAccessory: {
                    accessInfoButton
                }
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    permissionNote(
                        icon: "folder.fill",
                        text: "Files & Folders access is granted only for folders you choose in the macOS picker."
                    )
                    permissionNote(
                        icon: "lock.open",
                        text: "Full Disk Access is optional, but it avoids separate access prompts for each folder, making it faster to organize multiple folders."
                    )
                    permissionNote(
                        icon: "hand.raised",
                        text: "You can revoke any system permission at any time in Privacy & Security."
                    )
                }
            }
            .settingsFocusable(.permissionsUsage)
        }
        .task {
            await refreshPermissions(animateNewGrants: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await refreshPermissions()
            }
        }
        .onDisappear {
            automationPermissionTask?.cancel()
            automationPermissionTask = nil
            privacyHoverSettleTask?.cancel()
            privacyHoverSettleTask = nil
            isHoveringOpenPrivacySettings = false
            privacyOpenResetTask?.cancel()
            privacyOpenResetTask = nil
            isOpeningPrivacySettings = false
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
        .alert(item: $activeAlert) { alert in
            permissionAlert(for: alert)
        }
    }

    private var statusSummary: some View {
        HStack(spacing: 3) {
            Text("\(readyPermissionCount)")
                .monospacedDigit()
                .numericTextTransition(animationValue: readyPermissionCount)

            Text("of \(PermissionType.allCases.count) ready")
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(readyPermissionCount == PermissionType.allCases.count ? .green : .secondary)
        .animation(.easeInOut(duration: 0.16), value: readyPermissionCount)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.07), in: Capsule(style: .continuous))
    }

    private var accessInfoButton: some View {
        Button {
            HapticFeedbackManager.shared.tap()
            isShowingAccessInfo.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingAccessInfo, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Privacy you can inspect")
                        .font(.system(size: 13, weight: .bold, design: .rounded))

                    Text("Read our Privacy Policy and Terms of Service, or review Sorty’s source code.")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 7) {
                    accessInfoActionButton(
                        title: "Privacy Policy & Terms",
                        icon: "hand.raised",
                        action: .privacyAndTerms
                    ) {
                        isShowingAccessInfo = false
                        appState.openSettingsWindow(
                            section: .help,
                            focusTarget: .helpLegal
                        )
                    }

                    accessInfoActionButton(
                        title: "Review Source Code",
                        icon: "chevron.left.forwardslash.chevron.right",
                        action: .sourceCode
                    ) {
                        isShowingAccessInfo = false
                        NSWorkspace.shared.open(
                            URL(string: "https://github.com/sorty-organizer/Sorty")!
                        )
                    }
                }
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
            .systemLiquidGlassPopover(cornerRadius: 12)
        }
        .help("Privacy, terms, and source code")
        .accessibilityLabel("How Sorty uses access information")
        .onHover { hovering in
            if hovering {
                HapticFeedbackManager.shared.selection()
            }
        }
    }

    private func accessInfoActionButton(
        title: String,
        icon: String,
        action: AccessInfoAction,
        perform: @escaping () -> Void
    ) -> some View {
        Button {
            HapticFeedbackManager.shared.tap()
            perform()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)

                Text(LocalizedStringKey(title))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))

                Spacer(minLength: 8)

                Image(
                    systemName: hoveredAccessInfoAction == action
                        ? "arrow.up.right"
                        : "chevron.right"
                )
                .font(.system(size: 10, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
            }
            .foregroundStyle(hoveredAccessInfoAction == action ? .primary : .secondary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(
                Color.primary.opacity(hoveredAccessInfoAction == action ? 0.09 : 0.05),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering && hoveredAccessInfoAction != action {
                HapticFeedbackManager.shared.selection()
            }
            withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
                hoveredAccessInfoAction = hovering ? action : nil
            }
        }
        .accessibilityLabel(title)
    }

    private func permissionNote(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 16)
                .accessibilityHidden(true)

            Text(LocalizedStringKey(text))
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func refreshPermissions(animateNewGrants: Bool = true) async {
        async let hasFullDiskAccess = Task.detached(priority: .utility) {
            FullDiskAccessProbe.isGranted()
        }.value

        updatePermissionState(
            filesAndFoldersState,
            for: .filesAndFolders,
            animateGrant: animateNewGrants
        )
        updatePermissionState(
            fullDiskAccessState(canReadProtectedLocation: await hasFullDiskAccess),
            for: .fullDiskAccess,
            animateGrant: animateNewGrants
        )

        automationManager.checkPermissions(enableChecksIfNeeded: true)
        updatePermissionState(
            permissionState(for: automationManager.automationStatus),
            for: .automation,
            animateGrant: animateNewGrants
        )

        await notificationManager.checkNotificationPermission()
        updatePermissionState(
            notificationState(for: notificationManager.notificationPermissionStatus),
            for: .notifications,
            animateGrant: animateNewGrants
        )
    }

    private func updatePermissionState(
        _ newState: PermissionState,
        for type: PermissionType,
        animateGrant: Bool = true
    ) {
        let oldState = permissionStates[type]
        permissionStates[type] = newState

        let wasReady = oldState == .granted || oldState == .restartRequired
        let isReady = newState == .granted || newState == .restartRequired
        guard animateGrant, oldState != nil, !wasReady, isReady else { return }

        grantAnimationTriggers[type] = (grantAnimationTriggers[type] ?? 0) + 1
        HapticFeedbackManager.shared.success()
    }

    private func requestFilesAndFoldersPermission() {
        HapticFeedbackManager.shared.tap()
        updatePermissionState(.pending, for: .filesAndFolders)

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder you want Sorty to organize."
        panel.prompt = "Grant Access"

        guard panel.runModal() == .OK, let url = panel.url else {
            updatePermissionState(filesAndFoldersState, for: .filesAndFolders)
            return
        }

        guard appState.grantFilesAndFoldersPermission(for: url) else {
            updatePermissionState(.unknown, for: .filesAndFolders)
            activeAlert = .failure("Sorty couldn't save access to that folder. Please choose it again.")
            return
        }

        appState.selectedDirectory = url
        updatePermissionState(.granted, for: .filesAndFolders)
    }

    private var filesAndFoldersState: PermissionState {
        appState.hasFilesAndFoldersPermission() ? .granted : .unknown
    }

    private func openFullDiskAccessSettings() {
        HapticFeedbackManager.shared.tap()
        didOpenFullDiskAccessSettings = true
        updatePermissionState(.pending, for: .fullDiskAccess)
        PermisoAssistant.shared.present(
            panel: .fullDiskAccess,
            sourceFrameInScreen: fullDiskAccessSourceFrameInScreen,
            onCancel: {
                Task { @MainActor in
                    let isGranted = await Task.detached(priority: .utility) {
                        FullDiskAccessProbe.isGranted()
                    }.value
                    updatePermissionState(
                        fullDiskAccessState(canReadProtectedLocation: isGranted),
                        for: .fullDiskAccess
                    )
                }
                fullDiskAccessSourceFrameInScreen = nil
            }
        )
    }

    private func requestAutomationPermission(sourceFrameInScreen: CGRect?) {
        HapticFeedbackManager.shared.tap()

        updatePermissionState(.pending, for: .automation)

        automationPermissionTask?.cancel()
        automationPermissionTask = Task { @MainActor in
            await automationManager.requestAutomationPermissionCheck()
            guard !Task.isCancelled else { return }
            updatePermissionState(
                permissionState(for: automationManager.automationStatus),
                for: .automation
            )
            if automationManager.automationStatus == .denied {
                automationManager.openAutomationSettings(
                    sourceFrameInScreen: sourceFrameInScreen,
                    onMissingApp: { isShowingMissingAutomationRecovery = true }
                )
            }
            automationPermissionTask = nil
        }
    }

    private func requestNotificationPermission(sourceFrameInScreen: CGRect?) {
        HapticFeedbackManager.shared.tap()

        Task { @MainActor in
            await notificationManager.checkNotificationPermission()

            if notificationManager.notificationPermissionStatus == .denied {
                updatePermissionState(.denied, for: .notifications)
                openNotificationSettings(sourceFrameInScreen: sourceFrameInScreen)
                return
            }

            updatePermissionState(.pending, for: .notifications)
            let granted = await notificationManager.requestPermission()
            updatePermissionState(
                notificationState(for: notificationManager.notificationPermissionStatus),
                for: .notifications
            )

            if !granted {
                HapticFeedbackManager.shared.error()
                openNotificationSettings(sourceFrameInScreen: sourceFrameInScreen)
            }
        }
    }

    private func permissionAlert(for alert: PermissionsSettingsAlert) -> Alert {
        switch alert {
        case .fullDiskAccessSetup:
            return Alert(
                title: Text("Set up Full Disk Access?"),
                message: Text("Full Disk Access is optional and only needed for protected folders. macOS may relaunch Sorty after you turn it on."),
                primaryButton: .default(Text("Open System Settings")) {
                    openFullDiskAccessSettings()
                },
                secondaryButton: .cancel {
                    fullDiskAccessSourceFrameInScreen = nil
                }
            )

        case .revoke(let type):
            return Alert(
                title: Text(revocationTitle(for: type)),
                message: Text(revocationMessage(for: type)),
                primaryButton: .destructive(Text(revocationButtonTitle(for: type))) {
                    revokePermission(type)
                },
                secondaryButton: .cancel()
            )

        case .failure(let message):
            return Alert(
                title: Text("Permission Couldn’t Be Removed"),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func revocationTitle(for type: PermissionType) -> String {
        switch type {
        case .filesAndFolders:
            return "Remove Current Folder Access?"
        case .fullDiskAccess:
            return "Remove Full Disk Access?"
        case .automation:
            return "Remove Finder Automation?"
        case .notifications:
            return "Disable Notifications in Sorty?"
        }
    }

    private func revocationMessage(for type: PermissionType) -> String {
        switch type {
        case .filesAndFolders:
            return "Sorty will release the currently selected folder and reset its macOS access decisions for protected folders and external volumes. Your files won’t be changed."
        case .fullDiskAccess:
            return "macOS only lets you remove Full Disk Access in Privacy & Security. Turn Sorty off in the Full Disk Access list, then quit and reopen Sorty so the change takes effect."
        case .automation:
            return "Sorty will no longer be able to read Finder selections. macOS will ask again the next time you enable Finder Automation."
        case .notifications:
            return "Sorty will stop sending system notifications and clear its pending and delivered alerts. You can turn them back on in Sorty whenever macOS still allows them."
        }
    }

    private func revocationButtonTitle(for type: PermissionType) -> String {
        switch type {
        case .fullDiskAccess:
            return "Open Full Disk Access"
        case .notifications:
            return "Disable in Sorty"
        default:
            return "Remove Permission"
        }
    }

    private func revokePermission(_ type: PermissionType) {
        if type == .notifications {
            disableSystemNotifications()
            return
        }

        if type == .fullDiskAccess {
            HapticFeedbackManager.shared.tap()
            openFullDiskAccessRemovalSettings()
            return
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.sorty.app"
        Task { @MainActor in
            let result = await SystemPermissionRevoker.revoke(
                type,
                bundleIdentifier: bundleIdentifier
            )

            guard result.succeeded else {
                HapticFeedbackManager.shared.error()
                activeAlert = .failure(result.message)
                return
            }

            switch type {
            case .filesAndFolders:
                if let selectedDirectory = appState.selectedDirectory {
                    selectedDirectory.stopAccessingSecurityScopedResource()
                }
                appState.revokeFilesAndFoldersPermission()
                appState.selectedDirectory = nil
                updatePermissionState(.unknown, for: .filesAndFolders)
                HapticFeedbackManager.shared.success()

            case .fullDiskAccess:
                break

            case .automation:
                automationManager.markAutomationPermissionReset()
                updatePermissionState(.unknown, for: .automation)
                HapticFeedbackManager.shared.success()

            case .notifications:
                break
            }
        }
    }

    private func disableSystemNotifications() {
        notificationSettings.settings.systemNotifications = false

        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeAllPendingNotificationRequests()
        notificationCenter.removeAllDeliveredNotifications()

        HapticFeedbackManager.shared.success()
    }

    private func openFullDiskAccessRemovalSettings() {
        if !NSWorkspace.shared.open(PermisoPanel.fullDiskAccess.settingsURL) {
            NSWorkspace.shared.open(
                URL(fileURLWithPath: "/System/Applications/System Settings.app")
            )
        }
    }

    private func fullDiskAccessState(canReadProtectedLocation: Bool) -> PermissionState {
        if canReadProtectedLocation {
            return didOpenFullDiskAccessSettings ? .restartRequired : .granted
        }

        return didOpenFullDiskAccessSettings ? .denied : .unknown
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
                sourceFrameInScreen: sourceFrameInScreen
            )
            return
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.sorty.app"
        openFirstAvailableSettingsURL([
            "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleIdentifier)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleIdentifier)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ])
    }

    private func openPrivacyAndSecuritySettings() {
        openFirstAvailableSettingsURL([
            "x-apple.systempreferences:com.apple.preference.security",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ])
    }

    private func openPrivacySettings() {
        guard !isOpeningPrivacySettings else { return }

        HapticFeedbackManager.shared.tap()
        privacyOpenResetTask?.cancel()
        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
            isOpeningPrivacySettings = true
        }
        openPrivacyAndSecuritySettings()

        privacyOpenResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.75))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
                isOpeningPrivacySettings = false
            }
        }
    }

    private func openFirstAvailableSettingsURL(_ candidates: [String]) {
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

private struct PermissionSettingsCard: View {
    @SortyHotReload private var hotReload
    let type: PermissionType
    let state: PermissionState
    let isRequired: Bool
    let isFeatured: Bool
    let grantAnimationTrigger: Int
    let onExplain: () -> Void
    let onRequest: (CGRect?) -> Void
    let removePermissionTitle: String
    let onRemovePermission: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var actionFrameInScreen: CGRect = .zero
    @State private var isHovering = false
    @State private var isHoveringRemove = false

    init(
        type: PermissionType,
        state: PermissionState,
        isRequired: Bool,
        isFeatured: Bool = false,
        grantAnimationTrigger: Int,
        onExplain: @escaping () -> Void,
        onRequest: @escaping (CGRect?) -> Void,
        removePermissionTitle: String = "Remove Permission…",
        onRemovePermission: (() -> Void)? = nil
    ) {
        self.type = type
        self.state = state
        self.isRequired = isRequired
        self.isFeatured = isFeatured
        self.grantAnimationTrigger = grantAnimationTrigger
        self.onExplain = onExplain
        self.onRequest = onRequest
        self.removePermissionTitle = removePermissionTitle
        self.onRemovePermission = onRemovePermission
    }

    var body: some View {
        Group {
            if isFeatured {
                HStack(spacing: 14) {
                    permissionIcon

                    VStack(alignment: .leading, spacing: 4) {
                        title

                        permissionDescription
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 16)

                    footer
                }
            } else {
                VStack(spacing: 7) {
                    permissionIcon

                    title

                    permissionDescription

                    Spacer(minLength: 2)

                    footer
                }
            }
        }
        .padding(.horizontal, isFeatured ? 16 : 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: isFeatured ? 76 : 148)
        .background(cardFill)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(cardStroke, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .scaleEffect(isHovering ? 1.006 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isHovering)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78), value: state)
        .onHover { hovering in
            if hovering && !isHovering {
                HapticFeedbackManager.shared.selection()
            }
            isHovering = hovering
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

    private var permissionIcon: some View {
        PermissionAnimatedIcon(
            type: type,
            state: state,
            grantAnimationTrigger: grantAnimationTrigger,
            size: isFeatured ? 27 : 23
        )
            .foregroundStyle(isHovering ? type.color : .secondary)
            .frame(width: isFeatured ? 40 : nil, height: isFeatured ? 40 : 28)
            .accessibilityHidden(true)
    }

    private var title: some View {
        HStack(spacing: 5) {
            Text(LocalizedStringKey(type.rawValue))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .multilineTextAlignment(isFeatured ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)

            if isRequired {
                Text("Required")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.18), in: Capsule(style: .continuous))
                    .systemLiquidGlassBackground(cornerRadius: 999)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.red.opacity(0.38), lineWidth: 0.75)
                    )
            }
        }
    }

    private var permissionDescription: some View {
        Text(type.description(for: state))
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                maxWidth: isFeatured ? 420 : .infinity,
                minHeight: isFeatured ? nil : 26,
                alignment: isFeatured ? .leading : .top
            )
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: state.symbol)
                .font(.system(size: 10, weight: .bold))
                .symbolReplaceTransition(animationValue: state)

            Text(state.title(for: type))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .numericTextTransition(animationValue: state)
        }
        .foregroundStyle(state.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(state.tint.opacity(0.11), in: Capsule(style: .continuous))
        .accessibilityLabel(state.title(for: type))
    }

    @ViewBuilder
    private var footer: some View {
        if canRemovePermission, let onRemovePermission {
            HStack(spacing: 7) {
                statusBadge

                Button {
                    HapticFeedbackManager.shared.tap()
                    onRemovePermission()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isHoveringRemove ? .red : .secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            Color.red.opacity(isHoveringRemove ? 0.12 : 0),
                            in: Circle()
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(removePermissionTitle)
                .accessibilityLabel(removePermissionTitle)
                .onHover { hovering in
                    if hovering && !isHoveringRemove {
                        HapticFeedbackManager.shared.selection()
                    }
                    withAnimation(
                        reduceMotion
                            ? nil
                            : .spring(response: 0.24, dampingFraction: 0.82)
                    ) {
                        isHoveringRemove = hovering
                    }
                }
            }
            .fixedSize()
        } else {
            switch state {
            case .pending:
                statusBadge
                    .frame(height: 24)

            case .granted, .restartRequired:
                EmptyView()

            case .unknown, .denied:
                HStack(spacing: 8) {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        onExplain()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Learn why Sorty uses this permission")
                    .accessibilityLabel("Learn about \(type.rawValue)")

                    Button {
                        HapticFeedbackManager.shared.tap()
                        onRequest(actionFrameInScreen.isEmpty ? nil : actionFrameInScreen.integral)
                    } label: {
                        Text(LocalizedStringKey(actionTitle))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .frame(maxWidth: isFeatured ? 180 : .infinity)
                    }
                    .buttonStyle(.sortySecondary(size: .small, color: type.color))
                    .background(
                        ScreenFrameReader(frameInScreen: $actionFrameInScreen)
                            .allowsHitTesting(false)
                    )
                    .accessibilityLabel(actionTitle)
                }
                .frame(maxWidth: isFeatured ? 220 : .infinity)
            }
        }
    }

    private var actionTitle: String {
        guard state == .denied else { return type.compactActionTitle }

        switch type {
        case .notifications:
            return "Open Settings"
        case .automation:
            return "Try Again"
        default:
            return type.compactActionTitle
        }
    }

    private var canRemovePermission: Bool {
        state == .granted || state == .restartRequired
    }

    private var cardFill: Color {
        isHovering ? type.color.opacity(0.08) : Color.secondary.opacity(0.045)
    }

    private var cardStroke: Color {
        isHovering ? type.color.opacity(0.28) : Color.secondary.opacity(0.09)
    }
}

struct PermissionAnimatedIcon: View {
    @SortyHotReload private var hotReload
    let type: PermissionType
    let state: PermissionState
    let grantAnimationTrigger: Int
    var size: CGFloat = 23

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var folderFlapRotation = 0.0
    @State private var folderBackOpacity = 0.0
    @State private var folderOpenTask: Task<Void, Never>?
    @State private var gearRotation = 0.0
    @State private var bellRotation = 0.0
    @State private var bellRingTask: Task<Void, Never>?

    private var isReady: Bool {
        state == .granted || state == .restartRequired
    }

    @ViewBuilder
    var body: some View {
        Group {
            switch type {
            case .filesAndFolders:
                ZStack {
                    Image(systemName: "folder.fill")
                        .font(.system(size: size, weight: .semibold))
                        .opacity(folderBackOpacity)
                        .scaleEffect(x: 0.96, y: 0.88, anchor: .bottom)
                        .offset(y: -1)

                    Image(systemName: "folder.fill")
                        .font(.system(size: size, weight: .semibold))
                        .rotation3DEffect(
                            .degrees(folderFlapRotation),
                            axis: (x: 1, y: 0, z: 0),
                            anchor: .bottom,
                            perspective: 0.6
                        )
                }
                .frame(width: size * 1.18, height: size * 1.18)

            case .fullDiskAccess:
                Image(systemName: isReady ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: size, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(
                        .bounce,
                        options: .speed(0.9),
                        value: reduceMotion ? 0 : grantAnimationTrigger
                    )
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.68),
                        value: state
                    )

            case .automation:
                ZStack {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: size * 0.65, weight: .semibold))
                        .rotationEffect(.degrees(gearRotation))
                        .offset(x: size * -0.22, y: size * 0.17)

                    Image(systemName: "gearshape.fill")
                        .font(.system(size: size * 0.52, weight: .semibold))
                        .rotationEffect(.degrees(-gearRotation * 1.25))
                        .offset(x: size * 0.26, y: size * -0.22)
                }
                .frame(width: size * 1.18, height: size * 1.18)

            case .notifications:
                Image(systemName: "bell.fill")
                    .font(.system(size: size, weight: .semibold))
                    .rotationEffect(.degrees(bellRotation), anchor: .top)
            }
        }
        .onChange(of: grantAnimationTrigger) { oldValue, newValue in
            guard newValue != oldValue, !reduceMotion else { return }
            playGrantAnimation()
        }
        .onDisappear {
            folderOpenTask?.cancel()
            bellRingTask?.cancel()
        }
    }

    private func playGrantAnimation() {
        switch type {
        case .filesAndFolders:
            openAndCloseFolder()

        case .automation:
            withAnimation(.easeInOut(duration: 0.72)) {
                gearRotation += 360
            }

        case .notifications:
            ringBell()

        case .fullDiskAccess:
            break
        }
    }

    private func openAndCloseFolder() {
        folderOpenTask?.cancel()
        folderOpenTask = Task { @MainActor in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.68)) {
                folderFlapRotation = -42
                folderBackOpacity = 0.48
            }

            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }

            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                folderFlapRotation = 0
                folderBackOpacity = 0
            }
        }
    }

    private func ringBell() {
        bellRingTask?.cancel()
        bellRingTask = Task { @MainActor in
            let swings: [(angle: Double, duration: Double)] = [
                (-19, 0.09),
                (17, 0.12),
                (-13, 0.105),
                (9, 0.095),
                (-5, 0.085),
                (0, 0.11)
            ]

            for swing in swings {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: swing.duration)) {
                    bellRotation = swing.angle
                }
                try? await Task.sleep(for: .seconds(swing.duration))
            }
        }
    }
}

private enum AccessInfoAction: Hashable {
    case privacyAndTerms
    case sourceCode
}

private enum PermissionsSettingsAlert: Identifiable {
    case fullDiskAccessSetup
    case revoke(PermissionType)
    case failure(String)

    var id: String {
        switch self {
        case .fullDiskAccessSetup:
            return "full-disk-access-setup"
        case .revoke(let type):
            return "revoke-\(type.id)"
        case .failure(let message):
            return "failure-\(message)"
        }
    }
}

enum SystemPermissionRevoker {
    typealias Result = TCCPermissionResetter.Result

    static func revoke(
        _ type: PermissionType,
        bundleIdentifier: String
    ) async -> Result {
        let services: [String]
        switch type {
        case .filesAndFolders:
            services = [
                "SystemPolicyDesktopFolder",
                "SystemPolicyDocumentsFolder",
                "SystemPolicyDownloadsFolder",
                "SystemPolicyNetworkVolumes",
                "SystemPolicyRemovableVolumes"
            ]
        case .fullDiskAccess:
            return Result(
                succeeded: false,
                message: "macOS requires Full Disk Access to be removed in System Settings."
            )
        case .automation:
            services = ["AppleEvents"]
        case .notifications:
            return Result(
                succeeded: false,
                message: "macOS requires notification authorization to be changed in System Settings."
            )
        }

        return await TCCPermissionResetter.reset(
            services: services,
            bundleIdentifier: bundleIdentifier
        )
    }
}

#Preview {
    PermissionsSettingsView()
        .environmentObject(AppState())
        .environmentObject(AutomationManager())
        .padding(24)
        .frame(width: 700, height: 700)
}
