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
    @ObservedObject private var analytics = AnalyticsManager.shared
    @AppStorage("privacyModeEnabled") private var privacyModeEnabled = true
    @AppStorage(NetworkPrivacyPolicy.internetPrivacyModeKey) private var internetPrivacyModeEnabled = false

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
    @State private var permissionRefreshGeneration = 0
    @State private var permissionRefreshTask: Task<Void, Never>?

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

    private var analyticsEnabled: Binding<Bool> {
        Binding(
            get: { analytics.consent == .granted && !internetPrivacyModeEnabled },
            set: { analytics.setConsent($0 ? .granted : .denied) }
        )
    }

    private var analyticsDescription: String {
        if internetPrivacyModeEnabled {
            return "Off while Block Internet Connections is on"
        }
        return "Share anonymous feature usage and sanitized reliability data; never file names, paths, contents, prompts, or AI responses"
    }

    /// Sorty's own privacy switches, shown above the macOS permissions they complement.
    private var privacySection: some View {
        SettingsCard(title: "Privacy", icon: "lock.shield", color: .green) {
            VStack(spacing: 12) {
                SettingsToggle(
                    isOn: $privacyModeEnabled,
                    title: "Privacy Mode",
                    description: "Mask usernames, paths, API keys, and raw AI details in the interface",
                    focusTarget: .privacyMode
                )
                .accessibilityIdentifier("PrivacyModeToggle")

                Divider()

                SettingsToggle(
                    isOn: $internetPrivacyModeEnabled,
                    title: "Block Internet Connections",
                    description: "Allow only localhost requests for local models and offline workflows",
                    focusTarget: .privacyBlockInternet
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
                    focusTarget: .privacyAnalytics
                )
                .disabled(internetPrivacyModeEnabled)
                .animation(.easeInOut(duration: 0.2), value: internetPrivacyModeEnabled)
                .accessibilityIdentifier("AnonymousAnalyticsToggle")
            }
        }
        .settingsFocusable(.privacySettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            privacySection

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
                            refreshPermissions()
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
            // The Finder Automation probe is a synchronous TCC round trip on the
            // main actor; let the page transition finish before running it.
            try? await Task.sleep(for: .milliseconds(SettingsPageTransition.settleMilliseconds))
            guard !Task.isCancelled else { return }
            refreshPermissions(animateNewGrants: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .onDisappear {
            permissionRefreshGeneration += 1
            permissionRefreshTask?.cancel()
            permissionRefreshTask = nil
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
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
            .foregroundStyle(.primary)
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
                .font(.system(size: 11, weight: .medium))
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

    private func refreshPermissions(animateNewGrants: Bool = true) {
        permissionRefreshGeneration += 1
        let generation = permissionRefreshGeneration
        permissionRefreshTask?.cancel()
        permissionRefreshTask = Task { @MainActor in
            async let hasFullDiskAccess = Task.detached(priority: .utility) {
                FullDiskAccessProbe.isGranted()
            }.value

            automationManager.checkPermissions(enableChecksIfNeeded: true)
            await notificationManager.checkNotificationPermission()
            let isFullDiskAccessGranted = await hasFullDiskAccess
            let isFilesAndFoldersAccessGranted = await appState.hasFilesAndFoldersPermissionAsync()
            guard !Task.isCancelled, generation == permissionRefreshGeneration else { return }

            updatePermissionState(
                isFilesAndFoldersAccessGranted ? .granted : .unknown,
                for: .filesAndFolders,
                animateGrant: animateNewGrants
            )
            updatePermissionState(
                fullDiskAccessState(canReadProtectedLocation: isFullDiskAccessGranted),
                for: .fullDiskAccess,
                animateGrant: animateNewGrants
            )
            updatePermissionState(
                permissionState(for: automationManager.automationStatus),
                for: .automation,
                animateGrant: animateNewGrants
            )
            updatePermissionState(
                notificationState(for: notificationManager.notificationPermissionStatus),
                for: .notifications,
                animateGrant: animateNewGrants
            )
            permissionRefreshTask = nil
        }
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
                // Only balance access this session actually started.
                appState.releaseSelectedDirectoryAccess()
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


#Preview {
    PermissionsSettingsView()
        .environmentObject(AppState())
        .environmentObject(AutomationManager())
        .padding(24)
        .frame(width: 700, height: 700)
}
