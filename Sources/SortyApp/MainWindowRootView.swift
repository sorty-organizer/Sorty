import AppKit
import SwiftUI
#if canImport(SortyLib)
import SortyLib
#endif

struct MainWindowRootView: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var settingsViewModel: SettingsViewModel
    @ObservedObject private var codexAuth: CodexCLIAuthManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.isAccentPrototypeWindow) private var isAccentPrototypeWindow
    @AppStorage("lastSeenWhatsNewVersion") private var lastSeenWhatsNewVersion = ""
    @AppStorage("lastSeenWhatsNewBuild") private var lastSeenWhatsNewBuild = ""
    @AppStorage("forceShowWhatsNewOnLaunch") private var forceShowWhatsNewOnLaunch = false

    @StateObject private var windowSession: WindowSession
    @ObservedObject private var copilotAuth = GitHubCopilotAuthManager.shared
    @State private var handledLaunchRequestID: UUID?
    @State private var handledUITestDeepLink = false
    @State private var isShowingWhatsNew = false
    @State private var setupRepairTask: Task<Void, Never>?

    let launchRequest: WindowLaunchRequest?
    let coordinator: AppCoordinator?
    private let openAIAuth: SubscriptionAuthManager
    private let personaManager: PersonaManager
    private let customPersonaStore: CustomPersonaStore
    private let watchedFoldersManager: WatchedFoldersManager
    private let storageLocationsManager: StorageLocationsManager
    private let exclusionRules: ExclusionRulesManager
    private let deeplinkHandler: DeeplinkHandler
    private let automationManager: AutomationManager
    private let menuBarController: MenuBarController
    private let extensionListener: ExtensionListener
    private let notificationSettings: NotificationSettingsManager
    private let loginItemManager: LoginItemManager
    private let namingPresetManager: NamingPresetManager
    private let steeringPromptManager: SteeringPromptManager
    private let learningsManager: LearningsManager
    private let startTelemetry: @MainActor () -> Void

    init(
        launchRequest: WindowLaunchRequest?,
        coordinator: AppCoordinator?,
        history: OrganizationHistory,
        updateManager: SparkleUpdateManager,
        settingsViewModel: SettingsViewModel,
        codexAuth: CodexCLIAuthManager,
        personaManager: PersonaManager,
        customPersonaStore: CustomPersonaStore,
        watchedFoldersManager: WatchedFoldersManager,
        storageLocationsManager: StorageLocationsManager,
        exclusionRules: ExclusionRulesManager,
        deeplinkHandler: DeeplinkHandler,
        automationManager: AutomationManager,
        menuBarController: MenuBarController,
        openAIAuth: SubscriptionAuthManager,
        extensionListener: ExtensionListener,
        notificationSettings: NotificationSettingsManager,
        loginItemManager: LoginItemManager,
        namingPresetManager: NamingPresetManager,
        steeringPromptManager: SteeringPromptManager,
        learningsManager: LearningsManager,
        startTelemetry: @escaping @MainActor () -> Void
    ) {
        self.launchRequest = launchRequest
        self.coordinator = coordinator
        self.settingsViewModel = settingsViewModel
        self.codexAuth = codexAuth
        self.personaManager = personaManager
        self.customPersonaStore = customPersonaStore
        self.watchedFoldersManager = watchedFoldersManager
        self.storageLocationsManager = storageLocationsManager
        self.exclusionRules = exclusionRules
        self.deeplinkHandler = deeplinkHandler
        self.automationManager = automationManager
        self.menuBarController = menuBarController
        self.openAIAuth = openAIAuth
        self.extensionListener = extensionListener
        self.notificationSettings = notificationSettings
        self.loginItemManager = loginItemManager
        self.namingPresetManager = namingPresetManager
        self.steeringPromptManager = steeringPromptManager
        self.learningsManager = learningsManager
        self.startTelemetry = startTelemetry
        _windowSession = StateObject(
            wrappedValue: WindowSession(updateManager: updateManager, history: history)
        )
    }

    var body: some View {
        contentWithNotificationRouting
            .onAppear {
                recordLaunchSmokeSuccessIfRequested()
                openAccentPrototypesIfRequested()
            }
            .deleteUsageDataConfirmationAlert(
                isPresented: $windowSession.appState.showDeleteUsageDataConfirmation,
                deleteAction: windowSession.appState.deleteUsageData
            )
            .sheet(isPresented: $isShowingWhatsNew) {
                WhatsNewTourView {
                    markWhatsNewSeen()
                }
            }
    }

    private func recordLaunchSmokeSuccessIfRequested() {
        guard let resultPath = ProcessInfo.processInfo.environment["SORTY_LAUNCH_SMOKE_RESULT"],
              !resultPath.isEmpty else {
            return
        }

        try? Data("main-window-appeared\n".utf8).write(
            to: URL(fileURLWithPath: resultPath),
            options: .atomic
        )
    }

    private func openAccentPrototypesIfRequested() {
        guard ProcessInfo.processInfo.environment["SORTY_ACCENT_PROTOTYPE"] == "1",
              !isAccentPrototypeWindow else {
            return
        }

        ["accent-rose", "accent-indigo", "accent-teal", "accent-emerald", "accent-amber", "accent-violet"]
            .forEach { openWindow(id: $0) }
    }



    private var contentWithNotificationRouting: some View {
        contentWithPrimaryNotificationRouting
            .onReceive(NotificationCenter.default.publisher(for: .requestApplyOrganizationConfirmation)) { notification in
                guard notification.targetsWindowSession(windowSession.id) else { return }
                routeNotificationActionRequest(
                    kind: .applyConfirmation,
                    notification: notification
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestRedoOrganizationWithModelConfirmation)) { notification in
                guard notification.targetsWindowSession(windowSession.id) else { return }
                routeNotificationActionRequest(
                    kind: .redoWithModelConfirmation,
                    notification: notification
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .redoOrganizationWithModel)) { notification in
                guard notification.targetsWindowSession(windowSession.id) else { return }
                withAnimation(navigationAnimation) {
                    if windowSession.appState.selectedDirectory == nil,
                       let currentDirectory = windowSession.organizer.currentDirectory {
                        windowSession.appState.selectedDirectory = currentDirectory
                    }
                    windowSession.appState.currentView = .organize
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                settingsViewModel.forceSave()
                learningsManager.forceSaveSynchronously()
            }
    }

    private var contentWithPrimaryNotificationRouting: some View {
        contentWithLifecycle
            .onReceive(NotificationCenter.default.publisher(for: .routeDeeplinkInMainWindow)) { notification in
                guard notification.targetsWindowSession(windowSession.id),
                      let url = notification.routedDeeplinkURL else {
                    return
                }

                processDeeplink(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .presentSteeringPromptsInMainWindow)) { notification in
                guard notification.targetsWindowSession(windowSession.id) else { return }
                withAnimation(navigationAnimation) {
                    windowSession.appState.currentView = .organize
                }
                windowSession.appState.shouldPresentSteeringPrompts = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .importLearningsProfile)) { notification in
                guard notification.targetsWindowSession(windowSession.id) else { return }
                windowSession.appState.currentView = .learnings
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    learningsManager.showingImportPicker = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .clearLearningsData)) { notification in
                guard notification.targetsWindowSession(windowSession.id) else { return }
                Task { @MainActor in
                    await learningsManager.clearAllData()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showOrganizationDetails)) { notification in
                guard notification.targetsWindowSession(windowSession.id) else { return }
                withAnimation(navigationAnimation) {
                    windowSession.appState.currentView = .history
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showOrganizationPreview)) { notification in
                guard notification.targetsWindowSession(windowSession.id) else { return }
                let folderPath = notification.userInfo?["folderPath"] as? String
                let planID = (notification.userInfo?["planID"] as? String).flatMap(UUID.init(uuidString:))
                let isWatchedReview = notification.userInfo?["isWatchedReview"] as? Bool ?? false
                let isCurrentManualPreview = !isWatchedReview &&
                    windowSession.organizer.state == .ready &&
                    planID != nil &&
                    windowSession.organizer.currentPlan?.id == planID &&
                    folderPath != nil &&
                    windowSession.organizer.currentDirectory?.standardizedFileURL.path == folderPath.map {
                        URL(fileURLWithPath: $0).standardizedFileURL.path
                    }
                let reviewPresentation = isWatchedReview
                    ? coordinator?.presentPendingReview(
                        folderPath: folderPath,
                        planID: planID,
                        sessionID: windowSession.id,
                        in: windowSession.organizer
                    ) ?? .unavailable
                    : .unavailable
                if case .activatedExisting = reviewPresentation {
                    return
                }
                let didPresentReview: Bool
                if case .presented = reviewPresentation {
                    didPresentReview = true
                } else {
                    didPresentReview = false
                }
                withAnimation(navigationAnimation) {
                    if (didPresentReview || isCurrentManualPreview),
                       let currentDirectory = windowSession.organizer.currentDirectory {
                        windowSession.appState.selectedDirectory = currentDirectory
                        windowSession.appState.currentView = .organize
                    } else if isWatchedReview || planID == nil {
                        windowSession.appState.currentView = .watchedFolders
                    } else if windowSession.organizer.currentPlan == nil,
                              !windowSession.organizer.state.isOperationInProgress,
                              let folderPath {
                        windowSession.appState.selectedDirectory = URL(fileURLWithPath: folderPath)
                        windowSession.appState.currentView = .organize
                    } else {
                        windowSession.appState.currentView = .history
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showWatchedFolders)) { notification in
                guard notification.targetsWindowSession(windowSession.id) else { return }
                withAnimation(navigationAnimation) {
                    windowSession.appState.currentView = .watchedFolders
                }
            }
    }

    private var contentWithLifecycle: some View {
        contentWithEnvironment
            .task {
                let calibrate: ((WatchedFolder) -> Void)? = coordinator.map { coord in
                    { folder in coord.calibrateFolder(folder) }
                }
                let sessionID = windowSession.id
                windowSession.appState.prepareManualOrganizationAction = { [weak coordinator] directory in
                    await coordinator?.beginManualOrganization(in: directory, sessionID: sessionID)
                }
                await windowSession.configureIfNeeded(
                    settingsViewModel: settingsViewModel,
                    personaManager: personaManager,
                    customPersonaStore: customPersonaStore,
                    exclusionRules: exclusionRules,
                    storageLocationsManager: storageLocationsManager,
                    learningsManager: learningsManager,
                    automationManager: automationManager,
                    calibrateAction: calibrate,
                    onReady: startTelemetry
                )
                configureUITestPreviewIfNeeded()
                MainWindowRouter.shared.setBusy(
                    windowSession.organizer.state.isOperationInProgress,
                    for: windowSession.id
                )
                updateMenuBarOrganizationActivity()
                updateMenuBarDuplicateActivity()
                scheduleSetupRepairReconciliation()
                processLaunchRequestIfNeeded()
                processUITestDeeplinkIfNeeded()
                presentWhatsNewIfNeeded()
                MainWindowRouter.shared.markReady(sessionID: windowSession.id)
            }
            .onChange(of: coordinator != nil) { _, _ in
                let sessionID = windowSession.id
                windowSession.appState.calibrateAction = coordinator.map { coordinator in
                    { folder in coordinator.calibrateFolder(folder) }
                }
                windowSession.appState.prepareManualOrganizationAction = { [weak coordinator] directory in
                    await coordinator?.beginManualOrganization(in: directory, sessionID: sessionID)
                }
            }
            .onChange(of: launchRequest?.id) { _, _ in
                processLaunchRequestIfNeeded()
            }
            .onChange(of: settingsViewModel.config) { _, newConfig in
                Task { @MainActor in
                    await windowSession.applyConfiguration(newConfig, learningsManager: learningsManager)
                }
                updateMenuBarOrganizationActivity()
                scheduleSetupRepairReconciliation()
            }
            .onChange(of: settingsViewModel.hasLoadedPersistedState) { _, _ in
                scheduleSetupRepairReconciliation()
            }
            .onChange(of: settingsViewModel.isConfiguredCredentialHydrating) { _, _ in
                scheduleSetupRepairReconciliation()
            }
            .onChange(of: windowSession.appState.hasCompletedOnboarding) { wasComplete, isComplete in
                scheduleSetupRepairReconciliation()
                if !wasComplete && isComplete {
                    presentWhatsNewIfNeeded()
                }
            }
            .onChange(of: windowSession.appState.requiresSetupRepair) { _, _ in
                scheduleSetupRepairReconciliation()
            }
            .onChange(of: codexAuth.isAuthenticated) { _, _ in
                scheduleSetupRepairReconciliation()
            }
            .onChange(of: codexAuth.isCodexInstalled) { _, _ in
                scheduleSetupRepairReconciliation()
            }
            .onChange(of: codexAuth.hasResolvedStatus) { _, _ in
                scheduleSetupRepairReconciliation()
            }
            .onChange(of: copilotAuth.isAuthenticated) { _, _ in
                scheduleSetupRepairReconciliation()
            }
            .onChange(of: windowSession.organizer.isAIConfigured) { oldValue, newValue in
                if oldValue == true && newValue == false {
                    watchedFoldersManager.disableAutoOrganizeForAll(
                        reason: "Provider is no longer configured"
                    )
                }
            }
            .onChange(of: windowSession.organizer.state) { _, newState in
                MainWindowRouter.shared.setBusy(
                    newState.isOperationInProgress,
                    for: windowSession.id
                )
                updateMenuBarOrganizationActivity()
                if !newState.isOperationInProgress {
                    coordinator?.finishManualOrganization(sessionID: windowSession.id)
                }
            }
            .onChange(of: windowSession.appState.duplicateManager.isScanning) { _, _ in
                updateMenuBarDuplicateActivity()
            }
            .onOpenURL { url in
                handleExternalDeeplink(url)
            }
            .onDisappear {
                coordinator?.finishManualOrganization(sessionID: windowSession.id)
                menuBarController.setActivity(
                    nil,
                    sourceID: "window.\(windowSession.id.uuidString).organization"
                )
                menuBarController.setActivity(
                    nil,
                    sourceID: "window.\(windowSession.id.uuidString).duplicates"
                )
            }
    }

    private func updateMenuBarOrganizationActivity() {
        menuBarController.updateOrganizationActivity(
            state: windowSession.organizer.state,
            mode: settingsViewModel.config.mode,
            sourceID: "window.\(windowSession.id.uuidString).organization"
        )
    }

    private func updateMenuBarDuplicateActivity() {
        menuBarController.setActivity(
            windowSession.appState.duplicateManager.isScanning ? .duplicateScanning : nil,
            sourceID: "window.\(windowSession.id.uuidString).duplicates"
        )
    }

    private var contentWithEnvironment: some View {
        ContentView()
            .handlesExternalEvents(
                preferring: MainWindowRouter.existingWindowExternalEventMatchers,
                allowing: MainWindowRouter.existingWindowExternalEventMatchers
            )
            .environmentObject(settingsViewModel)
            .environmentObject(windowSession.appState)
            .environmentObject(windowSession.history)
            .environmentObject(personaManager)
            .environmentObject(customPersonaStore)
            .environmentObject(watchedFoldersManager)
            .environmentObject(windowSession.organizer)
            .environmentObject(exclusionRules)
            .environmentObject(extensionListener)
            .environmentObject(deeplinkHandler)
            .environmentObject(learningsManager)
            .environmentObject(storageLocationsManager)
            .environmentObject(automationManager)
            .environmentObject(openAIAuth)
            .environmentObject(codexAuth)
            .environmentObject(notificationSettings)
            .environmentObject(loginItemManager)
            .environmentObject(namingPresetManager)
            .environmentObject(steeringPromptManager)
            .environmentObject(windowSession.appState.duplicateManager)
            .environmentObject(windowSession.appState.duplicateSettings)
            .focusedSceneValue(\.appState, windowSession.appState)
            .focusedSceneValue(\.organizer, windowSession.organizer)
            .background(
                MainWindowSessionTracker(
                    sessionID: windowSession.id,
                    activateOnRegistration: launchRequest != nil
                )
                .frame(width: 0, height: 0)
            )
            .trafficLightInactiveBorders()
            .trafficLightUpdateButton(updateManager: windowSession.appState.updateManager)
    }

    private func processLaunchRequestIfNeeded() {
        guard let launchRequest,
              handledLaunchRequestID != launchRequest.id,
              let url = launchRequest.deeplinkURL else {
            return
        }

        handledLaunchRequestID = launchRequest.id
        processDeeplink(url)
    }

    private func presentWhatsNewIfNeeded() {
        guard !FeatureFlags.harnessMode else { return }
        guard windowSession.appState.hasCompletedOnboarding else { return }
        let currentIdentifier = whatsNewIdentifier()
        guard !currentIdentifier.isEmpty else { return }
        guard forceShowWhatsNewOnLaunch || lastSeenWhatsNewBuild != currentIdentifier else { return }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if forceShowWhatsNewOnLaunch || lastSeenWhatsNewBuild != currentIdentifier {
                isShowingWhatsNew = true
            }
        }
    }

    private func markWhatsNewSeen() {
        let currentVersion = whatsNewVersion()
        let currentIdentifier = whatsNewIdentifier()
        if !currentVersion.isEmpty {
            lastSeenWhatsNewVersion = currentVersion
        }
        if !currentIdentifier.isEmpty {
            lastSeenWhatsNewBuild = currentIdentifier
        }
        forceShowWhatsNewOnLaunch = false
        isShowingWhatsNew = false
    }

    private func whatsNewVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private func whatsNewIdentifier() -> String {
        let version = whatsNewVersion()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if version.isEmpty {
            return build
        }
        if build.isEmpty {
            return version
        }
        return "\(version)-\(build)"
    }

    private func processUITestDeeplinkIfNeeded() {
        guard !handledUITestDeepLink,
              let urlString = ProcessInfo.processInfo.environment["XCUITEST_DEEPLINK"],
              let url = URL(string: urlString) else {
            return
        }

        handledUITestDeepLink = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            processDeeplink(url)
        }
    }

    private func configureUITestPreviewIfNeeded() {
        guard ProcessInfo.processInfo.environment["XCUITEST_SEED_PREVIEW"] == "1" else { return }

        let directory = URL(fileURLWithPath: "/tmp/sorty-accessibility-preview", isDirectory: true)
        windowSession.appState.selectedDirectory = directory
        windowSession.organizer.currentDirectory = directory
        windowSession.organizer.currentPlan = PreviewMocks.makeOrganizationPlan()
        windowSession.organizer.state = .ready
    }

    private func handleExternalDeeplink(_ url: URL) {
        guard ExternalDeeplinkDeduper.shouldHandle(url) else { return }

        if url.isFinderWorkflowDeeplink {
            if MainWindowRouter.shared.routeFinderDeeplink(url) {
                return
            }

            if MainWindowRouter.shared.hasOpenSessions {
                openWindow(value: WindowLaunchRequest(url: url))
                return
            }
        }

        if MainWindowRouter.shared.routeDeeplink(url) {
            return
        }

        processDeeplink(url)
    }

    private func processDeeplink(_ url: URL) {
        let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "source" })?
            .value
        windowSession.appState.showsFinderWorkflowPicker =
            url.host?.lowercased() == "organize" && source == "finder"

        deeplinkHandler.handle(url: url)

        guard let destination = deeplinkHandler.pendingDestination else { return }

        windowSession.handle(
            destination: destination,
            settingsViewModel: settingsViewModel,
            personaManager: personaManager,
            customPersonaStore: customPersonaStore,
            watchedFoldersManager: watchedFoldersManager,
            exclusionRules: exclusionRules,
            storageLocationsManager: storageLocationsManager,
            learningsManager: learningsManager
        )
        deeplinkHandler.clearPending()
    }

    private func routeNotificationActionRequest(
        kind: AppState.PendingNotificationActionRequest.Kind,
        notification: Notification
    ) {
        let folderPath = notification.userInfo?["folderPath"] as? String
        let notificationType = notification.userInfo?["notificationType"] as? String

        withAnimation(navigationAnimation) {
            if let folderPath {
                windowSession.appState.selectedDirectory = URL(fileURLWithPath: folderPath)
            } else if windowSession.appState.selectedDirectory == nil,
                      let currentDirectory = windowSession.organizer.currentDirectory {
                windowSession.appState.selectedDirectory = currentDirectory
            }

            switch kind {
            case .applyConfirmation:
                windowSession.appState.currentView = .organize
            case .redoWithModelConfirmation:
                if notificationType == "previewReady" {
                    windowSession.appState.currentView = .organize
                } else {
                    windowSession.appState.currentView = .history
                }
            }
        }

        windowSession.appState.queueNotificationActionRequest(
            kind,
            folderPath: folderPath,
            notificationType: notificationType
        )
    }

    private var navigationAnimation: Animation? {
        reduceMotion ? nil : .pageTransition
    }

    private var providerSetupContext: ProviderSetupContext {
        ProviderSetupContext(
            config: settingsViewModel.config,
            isGitHubCopilotAuthenticated: copilotAuth.isAuthenticated,
            isCodexAuthenticated: codexAuth.isAuthenticated,
            isCodexInstalled: codexAuth.isCodexInstalled,
            isAppleFoundationModelAvailable: settingsViewModel.isAppleModelAvailable,
            appleFoundationModelStatus: settingsViewModel.appleModelStatus
        )
    }

    /// The Codex CLI probe resolves asynchronously after launch. Until it has,
    /// reconciling would mistake the initial `isCodexInstalled == false` for a
    /// missing setup and persist a bogus repair state on every restart.
    private var isCodexStatusResolvedForValidation: Bool {
        let config = settingsViewModel.config
        guard config.provider == .openAI,
              ProviderAuthResolver.effectiveAuthMethod(for: .openAI, config: config) == .accountSignIn
        else { return true }
        return codexAuth.hasResolvedStatus
    }

    private func scheduleSetupRepairReconciliation() {
        setupRepairTask?.cancel()
        setupRepairTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await reconcileSetupRepairState()
        }
    }

    @MainActor
    private func reconcileSetupRepairState() async {
        let appState = windowSession.appState

        guard appState.hasCompletedOnboarding,
              settingsViewModel.hasLoadedPersistedState,
              !settingsViewModel.isConfiguredCredentialHydrating,
              isCodexStatusResolvedForValidation else { return }

        codexAuth.checkStatus()
        openAIAuth.checkAuthenticationStatus()
        copilotAuth.checkAuthenticationStatus()
        settingsViewModel.refreshAppleModelStatus()

        let providerStatus = OnboardingSetupValidator.providerStatus(context: providerSetupContext)
        if !providerStatus.isReady {
            appState.startSetupRepair(message: providerStatus.message, navigateToSettings: false)
            return
        }

        guard appState.requiresSetupRepair else { return }

        let testedConfig = settingsViewModel.config
        do {
            try await settingsViewModel.testConnection()
            guard settingsViewModel.config == testedConfig else { return }
            appState.clearSetupRepairState()
        } catch {
            guard settingsViewModel.config == testedConfig else { return }
            appState.startSetupRepair(
                message: "Sorty could not verify \(testedConfig.provider.displayName): \(error.localizedDescription)",
                navigateToSettings: false
            )
        }
    }

}

extension EnvironmentValues {
    /// Marks windows that already render a recolored accent prototype, so
    /// they never spawn further prototype windows (which would cascade).
    var isAccentPrototypeWindow: Bool {
        get { self[AccentPrototypeWindowKey.self] }
        set { self[AccentPrototypeWindowKey.self] = newValue }
    }
}

private struct AccentPrototypeWindowKey: EnvironmentKey {
    static let defaultValue = false
}

private extension URL {
    var isFinderWorkflowDeeplink: Bool {
        guard scheme?.lowercased() == "sorty" else { return false }
        switch host?.lowercased() {
        case "organize", "watched", "exclude":
            return true
        default:
            return false
        }
    }
}

private extension View {
    func deleteUsageDataConfirmationAlert(
        isPresented: Binding<Bool>,
        deleteAction: @escaping () -> Void
    ) -> some View {
        alert("Delete All Usage Data?", isPresented: isPresented) {
            Button("Delete", role: .destructive, action: deleteAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all organization history, learnings data, and cached sessions. This action cannot be undone.")
        }
    }
}
