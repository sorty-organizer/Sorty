//
//  SortyApp.swift
//  Sorty
//
//  Created on macOS
//

import Darwin
import SwiftUI

#if canImport(SortyLib)
    import SortyLib
#endif

@MainActor
private final class ApplicationRemovalMonitor {
    private let originalApplicationURL: URL
    private let fileDescriptor: Int32
    private let onMovedToTrash: @MainActor @Sendable (URL?) -> Bool
    private var source: DispatchSourceFileSystemObject?
    private var hasHandledRemoval = false

    init?(onMovedToTrash: @escaping @MainActor @Sendable (URL?) -> Bool) {
        let applicationURL = Bundle.main.bundleURL.standardizedFileURL
        let descriptor = open(applicationURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        originalApplicationURL = applicationURL
        fileDescriptor = descriptor
        self.onMovedToTrash = onMovedToTrash
    }

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.handleFileSystemEvent()
            }
        }
        source.setCancelHandler { [fileDescriptor] in
            close(fileDescriptor)
        }
        self.source = source
        source.resume()
    }

    private func handleFileSystemEvent() {
        guard !hasHandledRemoval,
              !FileManager.default.fileExists(atPath: originalApplicationURL.path) else {
            return
        }

        hasHandledRemoval = onMovedToTrash(currentPathForOpenApplicationBundle())
    }

    private func currentPathForOpenApplicationBundle() -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fileDescriptor, F_GETPATH, &buffer) == 0 else { return nil }
        let path = String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
    }
}

@MainActor
private final class BuildAutoCloseMonitor {
    private let fileDescriptor: Int32
    private let onRequest: @MainActor @Sendable () -> Void
    private var source: DispatchSourceFileSystemObject?

    init?(containerURL: URL, onRequest: @escaping @MainActor @Sendable () -> Void) {
        let descriptor = open(containerURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        fileDescriptor = descriptor
        self.onRequest = onRequest
    }

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.onRequest()
            }
        }
        source.setCancelHandler { [fileDescriptor] in
            close(fileDescriptor)
        }
        self.source = source
        source.resume()
    }
}

@MainActor
class SortyAppDelegate: NSObject, NSApplicationDelegate {
    private static let confirmQuitWhileOrganizingKey = "confirmQuitWhileOrganizing"
    private static let buildAutoCloseRequestFileName = ".build-auto-close-request"
    private static let appGroupIdentifier = "group.com.sorty.app"
    @MainActor static var forceQuit = false
    private var recoveryWindowController: NSWindowController?
    private var applicationRemovalMonitor: ApplicationRemovalMonitor?
    private var buildAutoCloseMonitor: BuildAutoCloseMonitor?
    private var buildAutoCloseContainerURL: URL?
    private var cacheEvictionTask: Task<Void, Never>?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private let launchStartedAt = Date()
    private var applicationObservers: [NSObjectProtocol] = []

    var launchDuration: TimeInterval {
        Date().timeIntervalSince(launchStartedAt)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if canImport(SortyLib)
            _ = NotificationManager.shared
        #endif
        ApplicationMover.offerToMoveToApplicationsIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applicationRemovalMonitor = ApplicationRemovalMonitor { [weak self] movedApplicationURL in
            self?.finishExternalUninstall(movedApplicationURL: movedApplicationURL) ?? false
        }
        applicationRemovalMonitor?.start()
        configureBuildAutoCloseMonitor()
    }

    override init() {
        super.init()
        configureMemoryPressureEviction()
        applicationObservers.append(NotificationCenter.default.addObserver(
            forName: .forceQuitSorty,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                SortyAppDelegate.forceQuit = true
            }
        })
        applicationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleCacheEviction()
            }
        })
        applicationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cacheEvictionTask?.cancel()
                self?.cacheEvictionTask = nil
            }
        })
    }

    /// Watches the app-group container for a build-script quit request. The
    /// container lookup talks to the container manager and can stall for tens
    /// of milliseconds, so it runs off the main thread after launch instead of
    /// inside the delegate initializer.
    private func configureBuildAutoCloseMonitor() {
        let appGroupIdentifier = Self.appGroupIdentifier
        Task { @MainActor [weak self] in
            let containerURL = await Task.detached(priority: .utility) {
                FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: appGroupIdentifier
                )
            }.value
            guard let self, let containerURL else { return }

            self.buildAutoCloseContainerURL = containerURL
            self.buildAutoCloseMonitor = BuildAutoCloseMonitor(containerURL: containerURL) { [weak self] in
                self?.finishBuildRequestedQuitIfSafe()
            }
            self.buildAutoCloseMonitor?.start()
            self.finishBuildRequestedQuitIfSafe()
        }
    }

    private func configureMemoryPressureEviction() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.clearImageCaches()
            }
        }
        memoryPressureSource = source
        source.resume()
    }

    private func scheduleCacheEviction() {
        cacheEvictionTask?.cancel()
        cacheEvictionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
            guard !NSApp.isActive else { return }
            self?.clearImageCaches()
            self?.cacheEvictionTask = nil
        }
    }

    private func clearImageCaches() {
        cacheEvictionTask?.cancel()
        cacheEvictionTask = nil
        FileThumbnailProvider.shared.clearCache()
        SortyResources.clearImageCache()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.forceQuit {
            Self.forceQuit = false
            return .terminateNow
        }

        #if canImport(SortyLib)
            guard shouldWarnBeforeQuitForActiveAutomation,
                let warningContext = quitWarningContext
            else {
                return .terminateNow
            }

            return presentQuitWarning(for: warningContext)
        #else
            return .terminateNow
        #endif
    }

    private func finishExternalUninstall(movedApplicationURL: URL?) -> Bool {
        #if canImport(SortyLib)
            guard let report = SortyUninstaller.runAfterExternalApplicationRemoval(
                movedApplicationURL: movedApplicationURL
            ) else { return false }
            if report.didScheduleApplicationRemoval {
                Self.forceQuit = true
                NSApp.terminate(nil)
                return true
            }

            let failedItems = report.blockingFailureDescriptions.joined(separator: ", ")
            let detail = failedItems.isEmpty
                ? "macOS couldn't finish removing Sorty."
                : "Sorty couldn't remove its \(failedItems)."
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Sorty Could Not Finish Uninstalling"
            alert.informativeText = "\(detail) Restore Sorty from Trash, reopen it, and use Help > Uninstall Sorty."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return true
        #else
            return false
        #endif
    }

    #if canImport(SortyLib)
        /// Lets a local build dismiss an app-modal picker once no organization is active.
        /// Real organization work remains protected by the normal quit warning.
        private func finishBuildRequestedQuitIfSafe() {
            guard shouldAllowBuildRequestedQuit,
                !FolderOrganizer.hasRunningOrganizations
            else {
                return
            }

            NSApp.abortModal()
            NSApp.terminate(nil)
        }

        private enum QuitWarningContext {
            case runningActivities(Int)
            case watchedFolders(Int)
        }

        private var shouldWarnBeforeQuitForActiveAutomation: Bool {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: Self.confirmQuitWhileOrganizingKey) == nil {
                return true
            }
            return defaults.bool(forKey: Self.confirmQuitWhileOrganizingKey)
        }

        private var shouldAllowBuildRequestedQuit: Bool {
            guard let containerURL = buildAutoCloseContainerURL else { return false }

            return FileManager.default.fileExists(
                atPath: containerURL.appendingPathComponent(Self.buildAutoCloseRequestFileName).path
            )
        }

        private var quitWarningContext: QuitWarningContext? {
            if shouldAllowBuildRequestedQuit && !FolderOrganizer.hasRunningOrganizations {
                return nil
            }

            if FolderOrganizer.hasRunningOrganizations {
                return .runningActivities(FolderOrganizer.runningOrganizationCount)
            }

            guard shouldContinueRunningWhenLastWindowCloses else {
                return nil
            }

            let watchedCount = activeWatchedAutoOrganizeFolderCount
            guard watchedCount > 0 else {
                return nil
            }

            return .watchedFolders(watchedCount)
        }

        private var activeWatchedAutoOrganizeFolderCount: Int {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "activeWatchedFolderCount") != nil {
                return defaults.integer(forKey: "activeWatchedFolderCount")
            }

            guard let data = UserDefaults.standard.data(forKey: "watchedFolders"),
                let folders = try? JSONDecoder().decode([WatchedFolder].self, from: data)
            else {
                return 0
            }

            return folders.filter(\.isEnabled).count
        }

        private var shouldContinueRunningWhenLastWindowCloses: Bool {
            let defaults = UserDefaults.standard
            let keepInBackground = defaults.bool(forKey: "keepInBackground")
            let showMenuBarExtra = defaults.bool(forKey: "showMenuBarExtra")
            return keepInBackground || showMenuBarExtra
        }

        private func presentQuitWarning(for context: QuitWarningContext)
            -> NSApplication.TerminateReply
        {
            let alert = NSAlert()
            let backgroundHint =
                shouldContinueRunningWhenLastWindowCloses
                ? " To keep automation running, close the window instead of quitting."
                : ""

            alert.alertStyle = .warning
            switch context {
            case .runningActivities(let runningCount):
                let areIs = runningCount == 1 ? "is" : "are"
                let noun = runningCount == 1 ? "activity" : "activities"
                let activitySummary =
                    runningCount == 1
                    ? "An organize, rename, or watched-folder activity is"
                    : "\(runningCount) organize, rename, or watched-folder activities are"
                alert.messageText = "Quit Sorty while \(noun) \(areIs) running?"
                alert.informativeText =
                    "\(activitySummary) still in progress. Quitting now will interrupt active work and stop watched-folder automations until Sorty is reopened.\(backgroundHint)"

            case .watchedFolders(let watchedCount):
                let areIs = watchedCount == 1 ? "is" : "are"
                let noun = watchedCount == 1 ? "watched folder" : "watched folders"
                alert.messageText = "Quit Sorty and stop watched-folder automation?"
                alert.informativeText =
                    "\(watchedCount) \(noun) \(areIs) currently active for auto-organization. Quitting now will stop monitoring until Sorty is reopened.\(backgroundHint)"
            }

            alert.addButton(withTitle: "Quit Sorty")
            alert.addButton(withTitle: "Cancel")

            let dontAskAgainCheckbox = NSButton(
                checkboxWithTitle: "Don't ask again before quitting during activity",
                target: nil,
                action: nil
            )
            dontAskAgainCheckbox.state = .off
            alert.accessoryView = dontAskAgainCheckbox

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if dontAskAgainCheckbox.state == .on {
                    UserDefaults.standard.set(false, forKey: Self.confirmQuitWhileOrganizingKey)
                }
                return .terminateNow
            }

            return .terminateCancel
        }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let keepInBackground = UserDefaults.standard.bool(forKey: "keepInBackground")
        let showMenuBarExtra = UserDefaults.standard.bool(forKey: "showMenuBarExtra")

        return !keepInBackground && !showMenuBarExtra
    }

    @MainActor
    func updateActivationPolicy(hideDockIcon: Bool) {
        if hideDockIcon {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func presentRecoveryWindow<Content: View>(rootView: Content) {
        guard recoveryWindowController == nil else {
            recoveryWindowController?.showWindow(nil)
            return
        }

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sorty"
        window.contentViewController = hostingController
        window.center()

        let controller = NSWindowController(window: window)
        recoveryWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func scheduleRecoveryWindow(rootView: @escaping @MainActor () -> AnyView) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            let hasMainWindow = NSApplication.shared.windows.contains { window in
                window.canBecomeMain && (window.isVisible || window.isMiniaturized)
            }
            guard !hasMainWindow else { return }
            presentRecoveryWindow(rootView: rootView())
        }
    }
}

@MainActor
private enum ApplicationMover {
    private static let applicationsPath = "/Applications"
    private static let suggestionIdentifier = "move-to-applications"
    private static let suggestionDismissalKey = "hasDismissedMoveToApplicationsSuggestion"

    static func offerToMoveToApplicationsIfNeeded() {
        let sourceURL = originalBundleURL()
        #if DEBUG
            // Do not nag when launching directly from the build output. A copied
            // debug app should behave like a distributed app.
            //   SORTY_FORCE_MOVE_SUGGESTION=1 make dev
            let forceForTesting =
                ProcessInfo.processInfo.environment["SORTY_FORCE_MOVE_SUGGESTION"] == "1"
                || UserDefaults.standard.bool(forKey: "forceMoveToApplicationsSuggestion")
            if !forceForTesting, isDevelopmentBuildLocation(sourceURL) {
                NSLog("SortyMove: skipping suggestion (development build location)")
                return
            }
        #endif
        if ProcessInfo.processInfo.arguments.contains("--release-launch-smoke-test") {
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            return
        }
        if UserDefaults.standard.bool(forKey: suggestionDismissalKey) {
            NSLog("SortyMove: skipping suggestion (dismissed)")
            return
        }
        let bundlePath = sourceURL.path
        guard !isInApplicationsFolder(sourceURL) else {
            NSLog("SortyMove: skipping suggestion (already in Applications: %@)", bundlePath)
            return
        }
        NSLog("SortyMove: scheduling suggestion for %@", bundlePath)

        // Let the main window and HUD overlay appear before suggesting.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if UserDefaults.standard.bool(forKey: suggestionDismissalKey) {
                return
            }
            guard !isInApplicationsFolder(originalBundleURL()) else { return }
            NSLog("SortyMove: showing suggestion HUD")
            suggestMoveToApplications()
        }
    }

    private static func isDevelopmentBuildLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path.contains("/DerivedData/") || path.contains("/.build/") {
            return true
        }

        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
        return path.hasPrefix(repositoryURL.path + "/")
    }

    private static func suggestMoveToApplications() {
        #if canImport(SortyLib)
            let sourceURL = originalBundleURL()
            NotificationManager.shared.showHUDInfo(
                title: "Move Sorty to Applications?",
                message:
                    "Sorty runs fine from here, but moving it to Applications keeps updates and Finder features reliable.",
                icon: "folder.fill.badge.plus",
                iconColor: .blue,
                identifier: suggestionIdentifier,
                isPersistent: true,
                actions: [
                    HUDNotificationAction(
                        title: "Move to Applications",
                        systemImage: "arrow.down.app.fill"
                    ) {
                        HapticFeedbackManager.shared.success()
                        NotificationManager.shared.dismissHUD(identifier: suggestionIdentifier)
                        moveAndRelaunch(from: sourceURL)
                    },
                    HUDNotificationAction(
                        title: "Not Now",
                        systemImage: "clock"
                    ) {
                        HapticFeedbackManager.shared.tap()
                        NotificationManager.shared.dismissHUD(identifier: suggestionIdentifier)
                    },
                    HUDNotificationAction(title: "Don't Ask Again") {
                        HapticFeedbackManager.shared.selection()
                        UserDefaults.standard.set(true, forKey: suggestionDismissalKey)
                        NotificationManager.shared.dismissHUD(identifier: suggestionIdentifier)
                    },
                ]
            )
        #endif
    }

    private static func isInApplicationsFolder(_ url: URL) -> Bool {
        let path = url.path
        if path.hasPrefix(applicationsPath + "/") { return true }
        let userApplicationsPath = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .path
        return path.hasPrefix(userApplicationsPath + "/")
    }

    /// Returns the app's real on-disk location, resolving Gatekeeper app
    /// translocation back to the original path when necessary.
    private static func originalBundleURL() -> URL {
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard bundleURL.path.contains("/AppTranslocation/") else { return bundleURL }

        guard
            let handle = dlopen(
                "/System/Library/Frameworks/Security.framework/Security",
                RTLD_LAZY
            )
        else {
            return bundleURL
        }
        defer { dlclose(handle) }

        typealias CreateOriginalPath = @convention(c) (
            CFURL,
            UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> Unmanaged<CFURL>?
        guard let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else {
            return bundleURL
        }
        let createOriginalPath = unsafeBitCast(symbol, to: CreateOriginalPath.self)
        guard let original = createOriginalPath(bundleURL as CFURL, nil)?.takeRetainedValue() else {
            return bundleURL
        }
        return (original as URL).resolvingSymlinksInPath()
    }

    private static func moveAndRelaunch(from sourceURL: URL) {
        let destinationURL = URL(fileURLWithPath: applicationsPath, isDirectory: true)
            .appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
        // Move instead of copying so the downloaded app is not left behind,
        // then strip quarantine so the installed app launches without
        // Gatekeeper translocation (which would re-trigger this prompt).
        let script = """
        set sourcePath to \(appleScriptString(sourceURL.path))
        set destinationPath to \(appleScriptString(destinationURL.path))
        do shell script "/bin/rm -rf " & quoted form of destinationPath & " && /bin/mv " & quoted form of sourcePath & " " & quoted form of destinationPath & " && (/usr/bin/xattr -dr com.apple.quarantine " & quoted form of destinationPath & " || /usr/bin/true)" with administrator privileges
        """

        var error: NSDictionary?
        guard NSAppleScript(source: script)?.executeAndReturnError(&error) != nil else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Sorty couldn’t be moved"
            alert.informativeText = error?[NSAppleScript.errorMessage] as? String
                ?? "Move Sorty to Applications in Finder, then reopen it."
            alert.runModal()
            return
        }

        relaunch(at: destinationURL)
        quitImmediately()
    }

    /// Waits for this instance to exit, then opens the moved copy. Opening
    /// while the old instance is still running would just re-activate it.
    private static func relaunch(at destinationURL: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let quotedPath =
            "'" + destinationURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; "
                + "/usr/bin/open \(quotedPath)",
        ]
        try? process.run()
    }

    private static func quitImmediately() {
        SortyAppDelegate.forceQuit = true
        NSApplication.shared.terminate(nil)
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

@main
struct SortyApp: App {
    @NSApplicationDelegateAdaptor(SortyAppDelegate.self) private var appDelegate
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("keepInBackground") private var keepInBackground = false
    @AppStorage("hideDockIcon") private var hideDockIcon = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("finderIntegrationEnabled") private var finderIntegrationEnabled = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @StateObject private var settingsViewModel: SettingsViewModel
    @StateObject private var personaManager: PersonaManager
    @StateObject private var customPersonaStore: CustomPersonaStore
    @StateObject private var watchedFoldersManager: WatchedFoldersManager
    @StateObject private var storageLocationsManager: StorageLocationsManager
    @StateObject private var exclusionRules: ExclusionRulesManager
    @StateObject private var extensionListener: ExtensionListener
    @StateObject private var deeplinkHandler: DeeplinkHandler
    @StateObject private var learningsManager: LearningsManager
    @StateObject private var automationManager: AutomationManager
    @StateObject private var openAIAuthManager: SubscriptionAuthManager
    @StateObject private var codexAuthManager: CodexCLIAuthManager
    @StateObject private var notificationSettings: NotificationSettingsManager
    @StateObject private var loginItemManager: LoginItemManager
    @StateObject private var namingPresetManager: NamingPresetManager
    @StateObject private var steeringPromptManager: SteeringPromptManager
    @StateObject private var menuBarController: MenuBarController
    @StateObject private var updateManager: SparkleUpdateManager
    @StateObject private var organizationHistory: OrganizationHistory
    @State private var automationOrganizer: FolderOrganizer?

    @State private var coordinator: AppCoordinator?
    @State private var hasConfiguredGlobals = false
    @State private var hasConfiguredOperationalServices = false
    @State private var operationalServicesTask: Task<Void, Never>?

    private let widgetSyncManager = SortyWidgetSyncManager.shared

    /// Times a manager construction during launch; logs anything over 1ms in debug builds.
    private static func timedLaunchInit<T>(_ name: StaticString, _ make: () -> T) -> T {
        #if DEBUG
            let start = CFAbsoluteTimeGetCurrent()
            let value = make()
            let elapsedMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if elapsedMS > 1 {
                NSLog("SortyLaunch: %@ init took %.1fms", "\(name)", elapsedMS)
            }
            return value
        #else
            return make()
        #endif
    }

    init() {
        let launchInitStart = CFAbsoluteTimeGetCurrent()
        _settingsViewModel = StateObject(wrappedValue: Self.timedLaunchInit("SettingsViewModel") { SettingsViewModel() })
        _personaManager = StateObject(wrappedValue: Self.timedLaunchInit("PersonaManager") { PersonaManager() })
        _customPersonaStore = StateObject(wrappedValue: Self.timedLaunchInit("CustomPersonaStore") { CustomPersonaStore() })
        _watchedFoldersManager = StateObject(wrappedValue: Self.timedLaunchInit("WatchedFoldersManager") { WatchedFoldersManager() })
        _storageLocationsManager = StateObject(wrappedValue: Self.timedLaunchInit("StorageLocationsManager") { StorageLocationsManager() })
        _exclusionRules = StateObject(wrappedValue: Self.timedLaunchInit("ExclusionRulesManager") { ExclusionRulesManager() })
        _extensionListener = StateObject(wrappedValue: Self.timedLaunchInit("ExtensionListener") { ExtensionListener() })
        _deeplinkHandler = StateObject(wrappedValue: Self.timedLaunchInit("DeeplinkHandler") { DeeplinkHandler.shared })
        _learningsManager = StateObject(wrappedValue: Self.timedLaunchInit("LearningsManager") { LearningsManager() })
        _automationManager = StateObject(wrappedValue: Self.timedLaunchInit("AutomationManager") { AutomationManager() })
        _notificationSettings = StateObject(wrappedValue: Self.timedLaunchInit("NotificationSettingsManager") { NotificationSettingsManager.shared })
        _loginItemManager = StateObject(wrappedValue: Self.timedLaunchInit("LoginItemManager") { LoginItemManager.shared })
        _namingPresetManager = StateObject(wrappedValue: Self.timedLaunchInit("NamingPresetManager") { NamingPresetManager.shared })
        _steeringPromptManager = StateObject(wrappedValue: Self.timedLaunchInit("SteeringPromptManager") { SteeringPromptManager.shared })
        _menuBarController = StateObject(wrappedValue: Self.timedLaunchInit("MenuBarController") { MenuBarController() })
        _updateManager = StateObject(wrappedValue: Self.timedLaunchInit("SparkleUpdateManager") { SparkleUpdateManager() })

        let organizationHistory = Self.timedLaunchInit("OrganizationHistory") { OrganizationHistory() }
        _organizationHistory = StateObject(wrappedValue: organizationHistory)

        let codexAuthManager = Self.timedLaunchInit("CodexCLIAuthManager") { CodexCLIAuthManager() }
        _codexAuthManager = StateObject(wrappedValue: codexAuthManager)
        _openAIAuthManager = StateObject(
            wrappedValue: Self.timedLaunchInit("SubscriptionAuthManager") {
                SubscriptionAuthManager(provider: .openAI, codexAuthManager: codexAuthManager)
            }
        )

        UserDefaults.standard.register(defaults: [
            "showMenuBarExtra": true,
            "keepInBackground": false,
            "hideDockIcon": false,
            "launchAtLogin": false,
            "confirmQuitWhileOrganizing": true,
            "finderIntegrationEnabled": true,
        ])

        SortyUninstaller.discardLegacyRequest()

        configureUITestStateIfNeeded()

        #if DEBUG
            NSLog(
                "SortyLaunch: SortyApp.init total %.1fms",
                (CFAbsoluteTimeGetCurrent() - launchInitStart) * 1000)
        #endif
    }

    @SceneBuilder
    var body: some Scene {
        productionScenes
        accentPrototypeScenes

        MenuBarExtra(
            isInserted: Binding(
                get: { showMenuBarExtra || keepInBackground },
                set: { showMenuBarExtra = $0 }
            )
        ) {
            MenuBarView()
                .tint(SortyDesignSystem.Colors.resolvedAccent)
                .accentColor(SortyDesignSystem.Colors.resolvedAccent)
                .environmentObject(watchedFoldersManager)
                .environmentObject(loginItemManager)
                .environmentObject(notificationSettings)
                .environmentObject(menuBarController)
                .task {
                    await configureGlobalsIfNeeded()
                }
        } label: {
            MenuBarLabel(controller: menuBarController)
        }
        .menuBarExtraStyle(.window)
    }

    @SceneBuilder
    private var productionScenes: some Scene {
        WindowGroup("Sorty", id: "main") {
            mainWindowContent(launchRequest: .constant(nil))
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1100, height: 750)
        .defaultLaunchBehavior(.presented)

        WindowGroup(for: WindowLaunchRequest.self) { launchRequest in
            mainWindowContent(launchRequest: launchRequest)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1100, height: 750)
        .commands {
            SortyCommands()
        }
    }

    @SceneBuilder
    private var accentPrototypeScenes: some Scene {
        accentPrototypeWindow("Rose", id: "accent-rose", color: Color(red: 0.85, green: 0.235, blue: 0.353))
        accentPrototypeWindow("Indigo", id: "accent-indigo", color: Color(red: 0.31, green: 0.35, blue: 0.80))
        accentPrototypeWindow("Teal", id: "accent-teal", color: Color(red: 0.02, green: 0.50, blue: 0.54))
        accentPrototypeWindow("Emerald", id: "accent-emerald", color: Color(red: 0.08, green: 0.52, blue: 0.35))
        accentPrototypeWindow("Amber", id: "accent-amber", color: Color(red: 0.78, green: 0.40, blue: 0.04))
        accentPrototypeWindow("Violet", id: "accent-violet", color: Color(red: 0.54, green: 0.26, blue: 0.73))
    }

    private func accentPrototypeWindow(_ name: String, id: String, color: Color) -> some Scene {
        WindowGroup("Sorty · \(name)", id: id) {
            // Gating the content (not the scenes) keeps the SceneBuilder
            // body free of conditionals — wrapping six WindowGroups in
            // _ConditionalContent crashes the type checker. Closed prototype
            // windows stay invisible in production: suppressed at launch and
            // never opened without SORTY_ACCENT_PROTOTYPE=1.
            if ProcessInfo.processInfo.environment["SORTY_ACCENT_PROTOTYPE"] == "1" {
                mainWindowContent(launchRequest: .constant(nil), accent: color)
                    .environment(\.isAccentPrototypeWindow, true)
            }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 900, height: 680)
        .defaultLaunchBehavior(.suppressed)
    }

    @ViewBuilder
    private func mainWindowContent(
        launchRequest: Binding<WindowLaunchRequest?>,
        accent: Color? = nil
    ) -> some View {
        mainWindowIntegrationHandlers(
            mainWindowConfigurationHandlers(
                mainWindowRootView(launchRequest: launchRequest, accent: accent)
            )
        )
    }

    private func mainWindowConfigurationHandlers<Content: View>(_ content: Content) -> some View {
        content
            .onAppear {
                appDelegate.scheduleRecoveryWindow {
                    AnyView(mainWindowContent(launchRequest: .constant(nil)))
                }
            }
            .task {
                await configureGlobalsIfNeeded()
            }
            .onChange(of: settingsViewModel.config) { _, newConfig in
                Task { @MainActor in
                    try? await automationOrganizer?.configure(with: newConfig)
                    learningsManager.configure(with: newConfig)
                }
            }
            .onChange(of: hideDockIcon) { _, newValue in
                appDelegate.updateActivationPolicy(hideDockIcon: newValue)
            }
    }

    private func mainWindowIntegrationHandlers<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: finderIntegrationEnabled) { _, newValue in
                if newValue, hasCompletedOnboarding {
                    ExtensionCommunication.beginMonitoringFinderSyncRuntime()
                    Task {
                        _ = await ExtensionCommunication.ensureQuickActionInstalledAsync()
                        await ExtensionCommunication.autoRepairFinderSyncIfNeeded()
                    }
                }
            }
            .onChange(of: hasCompletedOnboarding) { _, isComplete in
                Task {
                    if isComplete {
                        await configureOperationalServicesIfNeeded()
                    }
                    guard isComplete, finderIntegrationEnabled else { return }
                    ExtensionCommunication.beginMonitoringFinderSyncRuntime()
                    _ = await ExtensionCommunication.ensureQuickActionInstalledAsync()
                    await ExtensionCommunication.autoRepairFinderSyncIfNeeded()
                }
            }
            .onChange(of: watchedFoldersManager.activeFolderCount) { _, _ in
                if watchedFoldersManager.activeFolderCount > 0 {
                    Task {
                        await configureOperationalServicesIfNeeded()
                    }
                }
                widgetSyncManager.scheduleSync(
                    watchedFoldersManager: watchedFoldersManager,
                    storageLocationsManager: storageLocationsManager
                )
            }
            .onChange(of: storageLocationsManager.locations) { _, _ in
                widgetSyncManager.scheduleSync(
                    watchedFoldersManager: watchedFoldersManager,
                    storageLocationsManager: storageLocationsManager
                )
            }
    }

    private func mainWindowRootView(
        launchRequest: Binding<WindowLaunchRequest?>,
        accent: Color?
    ) -> some View {
        MainWindowRootView(
            launchRequest: launchRequest.wrappedValue,
            coordinator: coordinator,
            history: organizationHistory,
            updateManager: updateManager,
            settingsViewModel: settingsViewModel,
            codexAuth: codexAuthManager,
            personaManager: personaManager,
            customPersonaStore: customPersonaStore,
            watchedFoldersManager: watchedFoldersManager,
            storageLocationsManager: storageLocationsManager,
            exclusionRules: exclusionRules,
            deeplinkHandler: deeplinkHandler,
            automationManager: automationManager,
            menuBarController: menuBarController,
            openAIAuth: openAIAuthManager,
            extensionListener: extensionListener,
            notificationSettings: notificationSettings,
            loginItemManager: loginItemManager,
            namingPresetManager: namingPresetManager,
            steeringPromptManager: steeringPromptManager,
            learningsManager: learningsManager,
            startTelemetry: {
                ReliabilityManager.shared.startIfAuthorized()
                AnalyticsManager.shared.startIfAuthorized(launchDuration: appDelegate.launchDuration)
                // The Codex CLI probe spawns a subprocess; it waits for the
                // window to be interactive and runs once per launch.
                codexAuthManager.startLaunchProbeIfNeeded()
                if hasConfiguredOperationalServices {
                    ReliabilityManager.shared.finishLaunchSpan()
                }
            }
        )
        .tint(accent ?? SortyDesignSystem.Colors.resolvedAccent)
        .accentColor(accent ?? SortyDesignSystem.Colors.resolvedAccent)
        .environmentObject(settingsViewModel)
        .environmentObject(personaManager)
        .environmentObject(customPersonaStore)
        .environmentObject(watchedFoldersManager)
        .environmentObject(storageLocationsManager)
        .environmentObject(exclusionRules)
        .environmentObject(extensionListener)
        .environmentObject(deeplinkHandler)
        .environmentObject(learningsManager)
        .environmentObject(automationManager)
        .environmentObject(openAIAuthManager)
        .environmentObject(codexAuthManager)
        .environmentObject(notificationSettings)
        .environmentObject(loginItemManager)
        .environmentObject(namingPresetManager)
        .environmentObject(steeringPromptManager)
        .environmentObject(menuBarController)
    }

    @MainActor
    private func configureGlobalsIfNeeded() async {
        guard !hasConfiguredGlobals else { return }
        hasConfiguredGlobals = true

        // Let the first window reach the screen before restoring folders,
        // initializing telemetry, or starting automation.
        await Task.yield()

        // Harness mode: skip heavy initialization for fast iteration
        if FeatureFlags.harnessMode {
            await settingsViewModel.loadPersistedState()
            configureHarnessMode()
            return
        }

        async let settingsLoad: Void = settingsViewModel.loadPersistedState()
        async let watchedFoldersLoad: Void = watchedFoldersManager.loadPersistedState()
        async let exclusionLoad: Void = exclusionRules.loadPersistedState()
        async let personaLoad: Void = personaManager.loadPersistedState()
        async let customPersonaLoad: Void = customPersonaStore.loadPersistedState()
        async let namingPresetLoad: Void = namingPresetManager.loadPersistedState()
        async let steeringPromptLoad: Void = steeringPromptManager.loadPersistedState()
        _ = await (
            settingsLoad,
            watchedFoldersLoad,
            exclusionLoad,
            personaLoad,
            customPersonaLoad,
            namingPresetLoad,
            steeringPromptLoad
        )

        appDelegate.updateActivationPolicy(hideDockIcon: hideDockIcon)
        loginItemManager.startUp()
        syncLoginItemState()

        if hasCompletedOnboarding || watchedFoldersManager.activeFolderCount > 0 {
            Task { await configureOperationalServicesIfNeeded() }
        }

        if ProcessInfo.processInfo.environment["XCUITEST_NOTIFICATION_ACTION"] == "showDetails" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                NotificationCenter.default.post(name: .showOrganizationDetails, object: nil)
            }
        }
    }

    @MainActor
    private func configureOperationalServicesIfNeeded() async {
        guard !hasConfiguredOperationalServices else { return }
        if let operationalServicesTask {
            await operationalServicesTask.value
            return
        }

        let task = Task { @MainActor in
            await configureOperationalServices()
        }
        operationalServicesTask = task
        await task.value
        operationalServicesTask = nil
        hasConfiguredOperationalServices = true
    }

    @MainActor
    private func configureOperationalServices() async {

        async let historyLoad: Void = organizationHistory.loadPersistedState()
        async let storageLocationsLoad: Void = storageLocationsManager.loadPersistedState()
        async let learningsLoad: Void = learningsManager.loadPersistedState()
        _ = await (historyLoad, storageLocationsLoad, learningsLoad)

        await watchedFoldersManager.restoreSecurityScopedAccess()
        await storageLocationsManager.restoreSecurityScopedAccess()
        widgetSyncManager.startIfNeeded(
            watchedFoldersManager: watchedFoldersManager,
            storageLocationsManager: storageLocationsManager
        )

        if hasCompletedOnboarding, finderIntegrationEnabled {
            ExtensionCommunication.beginMonitoringFinderSyncRuntime()
            Task {
                _ = await ExtensionCommunication.ensureQuickActionInstalledAsync()
                await ExtensionCommunication.autoRepairFinderSyncIfNeeded()
            }
        }

        if coordinator == nil {
            let automationOrganizer = FolderOrganizer(history: organizationHistory)
            self.automationOrganizer = automationOrganizer
            coordinator = AppCoordinator(
                organizer: automationOrganizer,
                watchedFoldersManager: watchedFoldersManager,
                learningsManager: learningsManager,
                exclusionRules: exclusionRules
            )
        }

        guard let automationOrganizer else { return }
        automationOrganizer.exclusionRules = exclusionRules
        automationOrganizer.personaManager = personaManager
        automationOrganizer.customPersonaStore = customPersonaStore
        automationOrganizer.storageLocationsManager = storageLocationsManager
        automationOrganizer.learningsManager = learningsManager
        automationOrganizer.automationManager = automationManager

        Task<Void, Never> { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            automationManager.startUp()
            try? await automationOrganizer.configure(with: settingsViewModel.config)
            learningsManager.configure(with: settingsViewModel.config)
            menuBarController.configure(
                settings: settingsViewModel,
                automationOrganizer: automationOrganizer,
                learningsManager: learningsManager
            )
        }
        ReliabilityManager.shared.finishLaunchSpan()
    }

    @MainActor
    private func configureHarnessMode() {
        appDelegate.updateActivationPolicy(hideDockIcon: false)
    }

    @MainActor
    private func syncLoginItemState() {
        loginItemManager.syncServiceRegistration(
            launchAtLogin: launchAtLogin,
            keepInBackground: keepInBackground,
            showMenuBarExtra: showMenuBarExtra
        )
    }

    private func configureUITestStateIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--uitesting") else { return }

        let env = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        let aiConfigKey = "aiConfig"

        defaults.set(
            env["XCUITEST_DISABLE_STORED_PROVIDER_CREDENTIALS"] == "1",
            forKey: "uitestDisableStoredProviderCredentials"
        )
        defaults.set(
            env["XCUITEST_ASSUME_FILES_PERMISSION"] == "1",
            forKey: "uitestAssumeFilesAndFoldersPermission"
        )
        defaults.removeObject(forKey: "uitestProviderHealthCheckFailedOnce")

        if env["XCUITEST_FORCE_MAIN_APP"] == "1" {
            defaults.set(true, forKey: "hasCompletedOnboarding")
            defaults.set(BuildInfo.version, forKey: "completedOnboardingVersion")
            defaults.set(false, forKey: "requiresSetupRepair")
            defaults.set(AnalyticsConsent.denied.rawValue, forKey: AnalyticsManager.consentDefaultsKey)
        }

        if let healthCheckMode = env["XCUITEST_PROVIDER_HEALTHCHECK"], !healthCheckMode.isEmpty {
            defaults.set(healthCheckMode, forKey: "uitestProviderHealthCheckMode")
        } else {
            defaults.removeObject(forKey: "uitestProviderHealthCheckMode")
        }

        if env["XCUITEST_FORCE_ONBOARDING"] == "1" {
            defaults.removeObject(forKey: "lastLaunchedVersion")
            defaults.set(false, forKey: "hasCompletedOnboarding")
            defaults.set(false, forKey: "requiresSetupRepair")
            defaults.removeObject(forKey: "setupRepairMessage")

            var config = AIConfig.default
            config.provider = .openAICompatible
            config.apiKey = nil
            config.apiURL = AIProvider.openAICompatible.defaultAPIURL
            config.requiresAPIKey = true
            if let encoded = try? JSONEncoder().encode(config) {
                defaults.set(encoded, forKey: aiConfigKey)
            }
        }

        if env["XCUITEST_FORCE_SETUP_REPAIR"] == "1" {
            defaults.set(BuildInfo.version, forKey: "lastLaunchedVersion")
            defaults.set(true, forKey: "hasCompletedOnboarding")
            defaults.set(true, forKey: "requiresSetupRepair")
            defaults.set(
                "Finish setting up your provider before organizing files.",
                forKey: "setupRepairMessage"
            )

            var config = AIConfig.default
            config.provider = .openAICompatible
            config.apiKey = nil
            config.apiURL = AIProvider.openAICompatible.defaultAPIURL
            config.requiresAPIKey = true
            if let encoded = try? JSONEncoder().encode(config) {
                defaults.set(encoded, forKey: aiConfigKey)
            }
        }

        if let consentValue = env["XCUITEST_LEARNINGS_CONSENT"] {
            defaults.set(consentValue == "1", forKey: "learnings_consent_granted")
        }

        if let setupCompleteValue = env["XCUITEST_LEARNINGS_SETUP_COMPLETE"] {
            defaults.set(setupCompleteValue == "1", forKey: "learnings_initial_setup_complete")
        }

        if env["XCUITEST_SEED_LEARNINGS_PROFILE"] == "active_rule" {
            defaults.set(true, forKey: "learnings_consent_granted")

            var seededProfile = LearningsProfile()
            seededProfile.consentGranted = true
            seededProfile.sessions = [
                OrganizationSession(
                    id: "ui-seed-session",
                    folderPath: "/tmp",
                    historyEntryId: "ui-seed-history"
                )
            ]
            seededProfile.inferredRules = [
                InferredRule(
                    pattern: ".*\\.pdf$",
                    template: "Documents/{filename}",
                    priority: 80,
                    explanation: "Seeded UI test rule",
                    scope: .folder("/tmp"),
                    status: .active
                )
            ]

            try? LearningsFileManager.save(profile: seededProfile)
        }

        if let historySeed = env["XCUITEST_SEED_HISTORY_ENTRY"] {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
            let historyDirectory = appSupport?.appendingPathComponent(
                "Sorty/History", isDirectory: true)
            let historyURL = historyDirectory?.appendingPathComponent("organization-history.json")
            let backupHistoryURL = historyDirectory?.appendingPathComponent(
                "organization-history.json.bak")

            if let historyDirectory {
                try? FileManager.default.createDirectory(
                    at: historyDirectory, withIntermediateDirectories: true)
            }

            let seededEntries: [OrganizationHistoryEntry]
            if historySeed == "filter_set" {
                seededEntries = [
                    OrganizationHistoryEntry(
                        directoryPath: "/tmp/completed-manual",
                        filesOrganized: 4,
                        foldersCreated: 2,
                        status: .completed,
                        source: .manual
                    ),
                    OrganizationHistoryEntry(
                        directoryPath: "/tmp/failed-manual",
                        filesOrganized: 0,
                        foldersCreated: 0,
                        success: false,
                        status: .failed,
                        source: .manual
                    ),
                    OrganizationHistoryEntry(
                        directoryPath: "/tmp/skipped-manual",
                        filesOrganized: 0,
                        foldersCreated: 0,
                        success: false,
                        status: .skipped,
                        source: .manual
                    ),
                    OrganizationHistoryEntry(
                        directoryPath: "/tmp/cancelled-manual",
                        filesOrganized: 0,
                        foldersCreated: 0,
                        success: false,
                        status: .cancelled,
                        source: .manual
                    ),
                    OrganizationHistoryEntry(
                        directoryPath: "/tmp/completed-watched",
                        filesOrganized: 3,
                        foldersCreated: 1,
                        status: .completed,
                        source: .watchedFolder
                    ),
                ]
            } else {
                seededEntries = [
                    OrganizationHistoryEntry(
                        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
                        timestamp: Date(),
                        directoryPath: "/tmp",
                        filesOrganized: 4,
                        foldersCreated: 2,
                        success: true,
                        status: .completed,
                        source: .manual
                    )
                ]
            }

            if let data = try? JSONEncoder().encode(seededEntries) {
                if let historyURL {
                    try? data.write(to: historyURL)
                }
                if let backupHistoryURL {
                    try? data.write(to: backupHistoryURL)
                }
            }
        }
    }
}
