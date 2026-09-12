//
//  AppCommands.swift
//  Sorty
//
//  Comprehensive menu bar commands with keyboard shortcuts
//

import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

// MARK: - App Commands

public struct AppStateFocusedKey: FocusedValueKey {
    public typealias Value = AppState
}

public struct OrganizerFocusedKey: FocusedValueKey {
    public typealias Value = FolderOrganizer
}

public extension FocusedValues {
    var appState: AppState? {
        get { self[AppStateFocusedKey.self] }
        set { self[AppStateFocusedKey.self] = newValue }
    }

    var organizer: FolderOrganizer? {
        get { self[OrganizerFocusedKey.self] }
        set { self[OrganizerFocusedKey.self] = newValue }
    }
}

public struct SortyCommands: Commands {
    @FocusedValue(\.appState) private var appState

    private var sidebarItems: [SidebarNavigationItem] {
        SidebarNavigationItem.mainItems
    }

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Sorty", systemImage: "info.circle") {
                appState?.showAbout()
            }
            .disabled(appState == nil)
            
            Button("Check for Updates...", systemImage: "arrow.triangle.2.circlepath") {
                appState?.checkForUpdatesInteractive()
            }
            .disabled(appState == nil)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings...", systemImage: "gearshape") {
                appState?.openSettingsWindow()
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(appState == nil)
        }

        // Replace default New/Open with custom commands
        CommandGroup(replacing: .newItem) {
            Button("New Session", systemImage: "plus.square") {
                appState?.resetSession()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(appState == nil)

            Button("Open Directory...", systemImage: "folder") {
                appState?.currentView = .organize
                appState?.showDirectoryPicker = true
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(appState == nil)

            Divider()

            Button("Export Results...", systemImage: "square.and.arrow.up") {
                appState?.exportResults()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!(appState?.hasResults ?? false))
        }

        // Edit menu additions
        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Select All Files", systemImage: "checkmark.circle") {
                appState?.selectAllFiles()
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(!(appState?.hasFiles ?? false))
        }

        // View menu - use CommandGroup to add to existing View menu, not create a new one
        CommandGroup(replacing: .sidebar) {
            Button((appState?.showingSidebar ?? true) ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left") {
                appState?.showingSidebar.toggle()
            }
            .keyboardShortcut("\\", modifiers: .command)
            .disabled(appState == nil)
        }
        
        // Navigation commands added to View menu
        CommandGroup(after: .sidebar) {
            Divider()
            
            // Main Views section
            Text("Navigation")
                .font(.caption)

            ForEach(Array(sidebarItems.prefix(9).enumerated()), id: \.element.id) { index, item in
                Button(item.title, systemImage: item.systemImage) {
                    appState?.currentView = item.view
                }
                .keyboardShortcut(Self.commandKeyEquivalent(for: index), modifiers: .command)
                .disabled(appState == nil)
            }
        }

        // Organize menu
        CommandMenu("Organize") {
            Button("Start Organization", systemImage: "play.circle") {
                appState?.startOrganization()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!(appState?.canStartOrganization ?? false))

            Button("Regenerate Organization", systemImage: "arrow.clockwise") {
                appState?.regenerateOrganization()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!(appState?.hasCurrentPlan ?? false))

            Divider()

            Button("Apply Changes", systemImage: "checkmark.circle.fill") {
                appState?.applyChanges()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!(appState?.canApply ?? false))

            Button("Preview Changes", systemImage: "eye") {
                appState?.previewChanges()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!(appState?.hasCurrentPlan ?? false))

            Divider()

            Button("Cancel", systemImage: "xmark.circle") {
                appState?.cancelOperation()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(!(appState?.isOperationInProgress ?? false))
        }

        // Learnings menu
        CommandMenu("Learnings") {
            Button("Open Dashboard", systemImage: "chart.bar") {
                appState?.currentView = .learnings
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(appState == nil)
            
            Divider()
            
            Button(
                (appState?.isLearningPaused ?? false) ? "Resume Learning" : "Pause Learning",
                systemImage: (appState?.isLearningPaused ?? false) ? "play.circle" : "pause.circle"
            ) {
                appState?.toggleLearning()
            }
            .disabled(appState == nil)
            
            Button("Export Learning Profile...", systemImage: "square.and.arrow.up") {
                appState?.exportLearningsProfile()
            }
            .disabled(appState == nil)
            
            Button("Import Learning Profile...", systemImage: "square.and.arrow.down") {
                appState?.importLearningsProfile()
            }
            .disabled(appState == nil)
        }

        // History menu
        CommandMenu("History") {
            Button("Open History", systemImage: "clock") {
                appState?.currentView = .history
            }
            .disabled(appState == nil)

            Divider()

            Menu("Export History", systemImage: "square.and.arrow.up") {
                Button("As CSV") {
                    appState?.exportHistory(format: .csv)
                }

                Button("As JSON") {
                    appState?.exportHistory(format: .json)
                }
            }
            .disabled(appState == nil)

            Button("Import History", systemImage: "square.and.arrow.down") {
                appState?.importHistory()
            }
            .disabled(appState == nil)

            Divider()

            Button("Clear History", systemImage: "trash") {
                appState?.clearHistoryWithConfirmation()
            }
            .disabled(appState == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Accreditations", systemImage: "rosette") {
                appState?.showAccreditations(entryPoint: .help)
            }
                .keyboardShortcut("©", modifiers: .command)
                .disabled(appState == nil)

            Button("Internet Access Policy", systemImage: "network") {
                appState?.showInternetAccessPolicy()
            }
            .keyboardShortcut("🌐", modifiers: .command)
            .disabled(appState == nil)

            Divider()

            Button("Sorty Help", systemImage: "questionmark.circle") {
                appState?.showHelp()
            }
            .keyboardShortcut("?", modifiers: .command)
            .disabled(appState == nil)
            
            Link(destination: URL(string: "https://github.com/shirishpothi/Sorty/blob/main/HELP.md")!) { Label("Documentation", systemImage: "book") }
            
            Link(destination: URL(string: "https://github.com/shirishpothi/Sorty/issues")!) { Label("Report Issue", systemImage: "ladybug") }

            if FeatureFlags.supportDeveloperEnabled {
                Link(destination: URL(string: "https://github.com/sponsors/shirishpothi")!) { Label("Support the Developer", systemImage: "heart") }
            }
            
            Divider()
            
            Button("Restart Onboarding...", systemImage: "sparkles") {
                appState?.showOnboarding()
            }
            .disabled(appState == nil)
            
            Button("Delete All Usage Data...", systemImage: "trash") {
                appState?.requestDeleteUsageDataConfirmation()
            }
            .disabled(appState == nil)
            
            Divider()
            
            Link(destination: URL(string: "https://github.com/shirishpothi/Sorty")!) { Label("GitHub Repository", systemImage: "chevron.left.forwardslash.chevron.right") }

            Button("Uninstall Sorty...", systemImage: "trash") {
                appState?.requestUninstallConfirmation()
            }
            .disabled(appState == nil)

            Divider()

            Button("Thank you for using Sorty", systemImage: "heart.fill") {
                appState?.showThanksForUsingSorty()
            }
            .keyboardShortcut("♥", modifiers: .command)
            .disabled(appState == nil)
        }
    }

    private static func commandKeyEquivalent(for index: Int) -> KeyEquivalent {
        KeyEquivalent(Character("\(index + 1)"))
    }
}

@MainActor
private final class HelpMenuHoverHapticsController: NSObject, NSMenuDelegate {
    private let center: NotificationCenter
    private let targetItemTitle = "Thank you for using Sorty"
    private var didFireForCurrentMenuOpen = false

    init(center: NotificationCenter = .default) {
        self.center = center
        super.init()

        installDelegateOnHelpMenuIfNeeded()

        center.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(handleMenuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
    }

    @objc private func handleDidBecomeActive() {
        installDelegateOnHelpMenuIfNeeded()
    }

    @objc private func handleMenuDidBeginTracking(_ notification: Notification) {
        guard
            let menu = notification.object as? NSMenu,
            menu.item(withTitle: targetItemTitle) != nil
        else { return }

        installDelegate(on: menu)
        didFireForCurrentMenuOpen = false
    }

    func menuWillOpen(_ menu: NSMenu) {
        didFireForCurrentMenuOpen = false
    }

    func menuDidClose(_ menu: NSMenu) {
        didFireForCurrentMenuOpen = false
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard item?.title == targetItemTitle else { return }
        guard didFireForCurrentMenuOpen == false else { return }

        didFireForCurrentMenuOpen = true
        HapticFeedbackManager.shared.selection()
    }

    private func installDelegateOnHelpMenuIfNeeded() {
        let mainMenu = NSApplication.shared.mainMenu
        guard let mainMenu else { return }

        for menu in allMenus(in: mainMenu) where menu.item(withTitle: targetItemTitle) != nil {
            installDelegate(on: menu)
        }
    }

    private func installDelegate(on menu: NSMenu) {
        if menu.delegate == nil || (menu.delegate as AnyObject?) === self {
            menu.delegate = self
        }
    }

    private func allMenus(in rootMenu: NSMenu) -> [NSMenu] {
        var menus: [NSMenu] = [rootMenu]
        for item in rootMenu.items {
            if let submenu = item.submenu {
                menus.append(contentsOf: allMenus(in: submenu))
            }
        }
        return menus
    }
}

// MARK: - App State

@MainActor
public class AppState: ObservableObject {
    private static let requiredOnboardingVersion = "1.2.0"
    private static let completedOnboardingVersionKey = "completedOnboardingVersion"
    public enum PersonaGeneratorPresentationContext: String, Identifiable {
        case onboarding
        case settings

        public var id: String { rawValue }
    }

    public enum HistoryExportFormat {
        case csv
        case json

        var fileExtension: String {
            switch self {
            case .csv:
                return "csv"
            case .json:
                return "json"
            }
        }
    }

    private static let requiresSetupRepairKey = "requiresSetupRepair"
    private static let setupRepairMessageKey = "setupRepairMessage"
    private static let filesAndFoldersPermissionBookmarkKey = "filesAndFoldersPermissionBookmark"
    private let userDefaults: UserDefaults
    private let sensitiveActionSecurityManager = SecurityManager.shared
    public let windowSessionID: UUID

    @Published public var currentView: AppView = .organize
    @Published public private(set) var navigationReturnRoute: NavigationReturnRoute?
    @Published public var showingSidebar: Bool = true
    @Published public var showDirectoryPicker: Bool = false
    public var hasPresentedReadyToOrganize = false
    @Published public var selectedDirectory: URL? {
        didSet {
            if let url = selectedDirectory {
                selectedDirectoryBookmark = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                // Remember a bare folder selection so a restart forced by
                // macOS (e.g. enabling Full Disk Access) restores the folder
                // even before analysis ever ran. Richer snapshots win: the
                // organizer skips this when a run or plan is already active.
                organizer?.persistSelectedDirectoryForRestart(url)
            } else {
                selectedDirectoryBookmark = nil
            }
        }
    }
    /// Security-scoped bookmark for the currently selected directory within this window session.
    public private(set) var selectedDirectoryBookmark: Data?
    /// Persistent security-scoped bookmark for the folder selected in Files & Folders settings.
    @Published public private(set) var filesAndFoldersPermissionBookmark: Data?
    @Published public var updateManager: SparkleUpdateManager
    @Published public var selectedSettingsSection: SettingsCategory?
    @Published public var settingsFocusTarget: SettingsFocusTarget?
    @Published public var personaGeneratorPresentationContext:
        PersonaGeneratorPresentationContext?
    @Published public var duplicateManager = DuplicateDetectionManager()
    @Published public var duplicateSettings = DuplicateSettingsManager()
    @Published public var duplicateSelectedDirectory: URL?
    @Published public var duplicateSelectedGroup: UnifiedDuplicateGroup?
    @Published public var debugMode: Bool = false
    @Published public var lastOrganizedDirectory: URL?
    @Published public var navigatedFromSettings: Bool = false
    @Published public var showDeleteUsageDataConfirmation: Bool = false
    /// True while `deleteUsageData()` is running. The blocking portion runs off
    /// the main actor, so views use this for busy affordances instead of assuming
    /// the call completes synchronously.
    @Published public private(set) var isDeletingUsageData = false
    @Published public var pendingDuplicatesHandoff: DuplicatesHandoff?
    @Published public var highlightedWatchedFolderID: UUID?
    @Published public var highlightedExclusionRuleID: UUID?
    @Published public var showsFinderWorkflowPicker = false
    @Published public var pendingNotificationActionRequest: PendingNotificationActionRequest?
    @Published public var pendingHistoryEntryID: UUID?
    @Published public var requiresSetupRepair: Bool {
        didSet {
            userDefaults.set(requiresSetupRepair, forKey: Self.requiresSetupRepairKey)
        }
    }
    @Published public var setupRepairMessage: String? {
        didSet {
            if let setupRepairMessage, !setupRepairMessage.isEmpty {
                userDefaults.set(setupRepairMessage, forKey: Self.setupRepairMessageKey)
            } else {
                userDefaults.removeObject(forKey: Self.setupRepairMessageKey)
            }
        }
    }
    
    /// Trigger update check with visible UI feedback.
    /// In debug builds this rebuilds and relaunches from source via `make now`.
    /// In release builds it uses Sparkle's native UI.
    public func checkForUpdatesInteractive() {
        #if DEBUG
        DevRebuilder.shared.rebuild()
        #else
        updateManager.checkForUpdates()
        #endif
    }
    
    @Published public var hasCompletedOnboarding: Bool {
        didSet {
            userDefaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
        }
    }
    @Published public private(set) var isRestartingOnboarding = false
    @Published public var shouldPresentSteeringPrompts = false

    // State derived from FolderOrganizer
    public weak var organizer: FolderOrganizer?
    public var calibrateAction: ((WatchedFolder) -> Void)?
    public var prepareManualOrganizationAction: ((URL) async -> Void)?

    public func prepareForManualOrganization(at directory: URL) async {
        await prepareManualOrganizationAction?(directory)
    }
    
    // Window controllers - retained to prevent use-after-free crashes
    // These MUST be retained to keep windows alive during animations
    private var aboutWindowController: NSWindowController?
    private var accreditationsWindowController: NSWindowController?
    private var internetAccessPolicyWindowController: NSWindowController?
    private var thanksWindowController: NSWindowController?
    private let helpMenuHoverHapticsController = HelpMenuHoverHapticsController()

    public enum AppView: Hashable, Sendable {
        case settings
        case organize
        case history
        case duplicates
        case exclusions
        case watchedFolders
        case learnings
    }

    public struct NavigationReturnRoute: Equatable, Sendable {
        public let destination: AppView
        public let returnView: AppView
    }

    public enum AccreditationsEntryPoint: Sendable {
        case about
        case help
    }

    public enum InternetAccessPolicyEntryPoint: Sendable {
        case about
        case appMenu
    }

    public struct DuplicatesHandoff: Equatable, Sendable {
        public let id: UUID
        public let directory: URL?
        public let filePaths: [String]
        public let autoStart: Bool

        public init(
            id: UUID = UUID(),
            directory: URL?,
            filePaths: [String] = [],
            autoStart: Bool
        ) {
            self.id = id
            self.directory = directory
            self.filePaths = filePaths
            self.autoStart = autoStart
        }
    }

    public struct PendingNotificationActionRequest: Identifiable, Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case applyConfirmation
            case redoWithModelConfirmation
        }

        public let id: UUID
        public let kind: Kind
        public let folderPath: String?
        public let notificationType: String?

        public init(
            id: UUID = UUID(),
            kind: Kind,
            folderPath: String? = nil,
            notificationType: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.folderPath = folderPath
            self.notificationType = notificationType
        }
    }

    public init(
        windowSessionID: UUID = UUID(),
        updateManager: SparkleUpdateManager = SparkleUpdateManager(),
        userDefaults: UserDefaults = .standard,
        currentVersion: String = BuildInfo.version
    ) {
        self.windowSessionID = windowSessionID
        self.updateManager = updateManager
        self.userDefaults = userDefaults
        self.filesAndFoldersPermissionBookmark = userDefaults.data(
            forKey: Self.filesAndFoldersPermissionBookmarkKey
        )

        // Onboarding completion is the source of truth. `lastLaunchedVersion`
        // can be written by a launch that never completed onboarding, so it
        // must not force-skip setup on the next run.
        let onboardingCompleted = userDefaults.bool(forKey: "hasCompletedOnboarding")
        let completedOnboardingVersion = userDefaults.string(forKey: Self.completedOnboardingVersionKey)
        let requiresSetupRepair = userDefaults.bool(forKey: Self.requiresSetupRepairKey)
        let setupRepairMessage = userDefaults.string(forKey: Self.setupRepairMessageKey)

        let mustRepeatOnboarding = currentVersion == Self.requiredOnboardingVersion
            && completedOnboardingVersion != Self.requiredOnboardingVersion
        self.hasCompletedOnboarding = onboardingCompleted && !mustRepeatOnboarding
        self.requiresSetupRepair = requiresSetupRepair
        self.setupRepairMessage = setupRepairMessage
        
        // Always store current version for future launches
        userDefaults.set(currentVersion, forKey: "lastLaunchedVersion")
    }

    public func recordOnboardingCompletion() {
        hasCompletedOnboarding = true
        let currentVersion = userDefaults.string(forKey: "lastLaunchedVersion") ?? BuildInfo.version
        userDefaults.set(currentVersion, forKey: Self.completedOnboardingVersionKey)
    }

    public var hasResults: Bool {
        organizer?.currentPlan != nil && organizer?.state == .completed
    }

    public var hasFiles: Bool {
        organizer?.currentPlan != nil
    }

    public var canStartOrganization: Bool {
        selectedDirectory != nil && (organizer?.state == .idle || organizer?.state == .completed)
    }

    /// Records a folder selected through the Files & Folders picker so its grant survives
    /// later status refreshes and app launches. This is intentionally separate from the
    /// current workflow directory, which is scoped to one window session.
    @discardableResult
    public func grantFilesAndFoldersPermission(for url: URL) -> Bool {
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return false
        }

        filesAndFoldersPermissionBookmark = bookmark
        userDefaults.set(bookmark, forKey: Self.filesAndFoldersPermissionBookmarkKey)
        return hasFilesAndFoldersPermission()
    }

    /// Resolves the saved grant and proves that Sorty can still read the chosen directory.
    /// Resolving a bookmark does not make it the active workflow folder.
    public func hasFilesAndFoldersPermission() -> Bool {
        guard let bookmark = filesAndFoldersPermissionBookmark else { return false }

        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            revokeFilesAndFoldersPermission()
            return false
        }

        // A bookmark can still resolve after access has been revoked or the folder has become
        // unavailable. Exercise a non-mutating directory read before reporting this as granted.
        let didStartAccessing = resolved.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                resolved.stopAccessingSecurityScopedResource()
            }
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: resolved.path),
              (try? FileManager.default.contentsOfDirectory(
                  at: resolved,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )) != nil else {
            return false
        }

        if isStale,
           let refreshedBookmark = try? resolved.bookmarkData(
               options: .withSecurityScope,
               includingResourceValuesForKeys: nil,
               relativeTo: nil
           ) {
            filesAndFoldersPermissionBookmark = refreshedBookmark
            userDefaults.set(refreshedBookmark, forKey: Self.filesAndFoldersPermissionBookmarkKey)
        }

        return true
    }

    public func revokeFilesAndFoldersPermission() {
        filesAndFoldersPermissionBookmark = nil
        userDefaults.removeObject(forKey: Self.filesAndFoldersPermissionBookmarkKey)
    }

    public var hasCurrentPlan: Bool {
        organizer?.currentPlan != nil
    }

    public var canApply: Bool {
        organizer?.state == .ready
    }

    public var isOperationInProgress: Bool {
        guard let state = organizer?.state else { return false }
        switch state {
        case .scanning, .organizing, .applying:
            return true
        default:
            return false
        }
    }

    /// Resolve the security-scoped bookmark for the selected directory.
    /// Returns a URL with active security scope, or falls back to the stored URL.
    public func resolveSelectedDirectoryWithAccess() -> URL? {
        if let bookmark = selectedDirectoryBookmark {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                _ = resolved.startAccessingSecurityScopedResource()
                if isStale {
                    selectedDirectoryBookmark = try? resolved.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                }
                return resolved
            }
        }
        return selectedDirectory
    }

    public func resetSession() {
        selectedDirectory = nil
        organizer?.reset()
    }

    public func handoffToDuplicates(
        directory: URL?,
        filePaths: [String] = [],
        autoStart: Bool = true
    ) {
        let normalizedDirectory = directory?.standardizedFileURL ?? selectedDirectory?.standardizedFileURL
        let normalizedFilePaths = Self.normalizedFilePaths(filePaths)
        if let normalizedDirectory {
            selectedDirectory = normalizedDirectory
        }
        pendingDuplicatesHandoff = DuplicatesHandoff(
            directory: normalizedDirectory,
            filePaths: normalizedFilePaths,
            autoStart: autoStart
        )
        openRelatedView(.duplicates)
    }

    public func handoffToDuplicates(
        forFilePaths filePaths: [String],
        preferredDirectory: URL? = nil,
        autoStart: Bool = true
    ) {
        let normalizedFilePaths = Self.normalizedFilePaths(filePaths)
        let pathDerivedDirectory = Self.commonParentDirectory(forFilePaths: normalizedFilePaths)
        let targetDirectory = preferredDirectory?.standardizedFileURL ?? pathDerivedDirectory
        handoffToDuplicates(
            directory: targetDirectory,
            filePaths: normalizedFilePaths,
            autoStart: autoStart
        )
    }

    private static func commonParentDirectory(forFilePaths filePaths: [String]) -> URL? {
        let directories = filePaths
            .map { URL(fileURLWithPath: $0).standardizedFileURL.deletingLastPathComponent() }

        guard let firstDirectory = directories.first else { return nil }
        var commonComponents = firstDirectory.pathComponents

        for directory in directories.dropFirst() {
            let components = directory.pathComponents
            var index = 0
            while index < commonComponents.count && index < components.count && commonComponents[index] == components[index] {
                index += 1
            }
            commonComponents = Array(commonComponents.prefix(index))
            if commonComponents.isEmpty {
                break
            }
        }

        guard !commonComponents.isEmpty else { return firstDirectory }
        let commonPath = NSString.path(withComponents: commonComponents)
        return URL(fileURLWithPath: commonPath, isDirectory: true).standardizedFileURL
    }

    private static func normalizedFilePaths(_ filePaths: [String]) -> [String] {
        var seenPaths: Set<String> = []
        var normalizedPaths: [String] = []

        for path in filePaths {
            let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            if seenPaths.insert(normalizedPath).inserted {
                normalizedPaths.append(normalizedPath)
            }
        }

        return normalizedPaths
    }

    public func queueNotificationActionRequest(
        _ kind: PendingNotificationActionRequest.Kind,
        folderPath: String? = nil,
        notificationType: String? = nil
    ) {
        pendingNotificationActionRequest = PendingNotificationActionRequest(
            kind: kind,
            folderPath: folderPath,
            notificationType: notificationType
        )
    }

    public func clearNotificationActionRequest(id: UUID? = nil) {
        guard let id else {
            pendingNotificationActionRequest = nil
            return
        }

        if pendingNotificationActionRequest?.id == id {
            pendingNotificationActionRequest = nil
        }
    }
    
    /// Show the onboarding flow again (for revisiting setup)
    public func showOnboarding() {
        // Replace the root before onboarding configures the shared window.
        // Suppress the root crossfade while it changes that shared window.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            clearSetupRepairState()
            isRestartingOnboarding = true
            hasCompletedOnboarding = false
        }
    }

    public func openProviderSettingsForRepair() {
        openSettingsWindow(section: .provider)
        navigatedFromSettings = false
    }

    public func openSettingsWindow(
        section: SettingsCategory? = nil,
        focusTarget: SettingsFocusTarget? = nil
    ) {
        let destinationSection = focusTarget?.category ?? section
        if selectedSettingsSection != destinationSection {
            selectedSettingsSection = destinationSection
        }
        if settingsFocusTarget != focusTarget {
            settingsFocusTarget = focusTarget
        }
        // Switching Settings sections does not navigate the app's root page.
        if currentView != .settings {
            withAnimation(.pageTransition) {
                currentView = .settings
            }
        }
        if selectedSettingsSection == .provider {
            NotificationManager.shared.dismissHUD(identifier: "setup-repair")
        } else if requiresSetupRepair, let message = setupRepairMessage {
            presentSetupRepairHUD(message: message)
        }
    }

    /// Opens a related app page while preserving the page that launched it.
    public func openRelatedView(_ destination: AppView) {
        guard destination != currentView else { return }
        navigationReturnRoute = NavigationReturnRoute(
            destination: destination,
            returnView: currentView
        )
        withAnimation(.pageTransition) {
            currentView = destination
        }
    }

    public func clearNavigationReturnRoute() {
        navigationReturnRoute = nil
    }

    public func startSetupRepair(message: String, navigateToSettings: Bool = false) {
        requiresSetupRepair = true
        setupRepairMessage = message
        if navigateToSettings {
            openProviderSettingsForRepair()
            return
        }
        presentSetupRepairHUD(message: message)
    }

    public func presentSetupRepairHUD(message: String) {
        guard !(currentView == .settings && selectedSettingsSection == .provider) else {
            NotificationManager.shared.dismissHUD(identifier: "setup-repair")
            return
        }
        NotificationManager.shared.showHUDInfo(
            title: "Setup Repair Needed",
            message: message,
            icon: "wrench.and.screwdriver.fill",
            iconColor: .orange,
            identifier: "setup-repair",
            isPersistent: true,
            actions: [
                HUDNotificationAction(
                    title: "Open Provider Settings",
                    systemImage: "gearshape"
                ) { [weak self] in
                    HapticFeedbackManager.shared.selection()
                    self?.openProviderSettingsForRepair()
                }
            ]
        )
    }

    public func clearSetupRepairState() {
        requiresSetupRepair = false
        setupRepairMessage = nil
        NotificationManager.shared.dismissHUD(identifier: "setup-repair")
    }
    
    public func exportResults() {
        guard let plan = organizer?.currentPlan else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText, .json, .html]
        panel.nameFieldStringValue = "organization_results_\(Date().formatted(date: .numeric, time: .omitted).replacingOccurrences(of: "/", with: "-"))"
        panel.message = "Export Organization Results"
        panel.canSelectHiddenExtension = true
        
        // Add accessory view for format selection
        let formatPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 30), pullsDown: false)
        formatPopup.addItems(withTitles: ["CSV (Spreadsheet)", "JSON (Machine-readable)", "HTML (Report)"])
        panel.accessoryView = formatPopup

        if panel.runModal() == .OK, let url = panel.url {
            let selectedFormat = formatPopup.indexOfSelectedItem
            
            do {
                let content: String
                var finalURL = url
                
                switch selectedFormat {
                case 0: // CSV
                    content = generateCSV(from: plan)
                    if !finalURL.pathExtension.lowercased().contains("csv") {
                        finalURL = finalURL.deletingPathExtension().appendingPathExtension("csv")
                    }
                case 1: // JSON
                    content = generateJSON(from: plan)
                    if !finalURL.pathExtension.lowercased().contains("json") {
                        finalURL = finalURL.deletingPathExtension().appendingPathExtension("json")
                    }
                case 2: // HTML
                    content = generateHTML(from: plan)
                    if !finalURL.pathExtension.lowercased().contains("html") {
                        finalURL = finalURL.deletingPathExtension().appendingPathExtension("html")
                    }
                default:
                    content = generateCSV(from: plan)
                }
                
                try content.write(to: finalURL, atomically: true, encoding: .utf8)
                HapticFeedbackManager.shared.success()
                
                // Open the exported file
                NSWorkspace.shared.open(finalURL)
            } catch {
                DebugLogger.log("Failed to export results: \(error)")
                HapticFeedbackManager.shared.error()
            }
        }
    }

    public func exportHistory(format: HistoryExportFormat) {
        guard let historyStore = organizer?.history, !historyStore.entries.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .csv ? [.commaSeparatedText] : [.json]
        panel.nameFieldStringValue = "sorty-history.\(format.fileExtension)"
        panel.title = "Export History"
        panel.message = "Choose where to save your history export"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { @MainActor in
            var history: [OrganizationHistoryEntry] = []
            history.reserveCapacity(historyStore.entries.count)
            for entry in historyStore.entries {
                history.append(await historyStore.details(for: entry))
            }
            do {
                let content: String
                switch format {
                case .csv:
                    content = generateHistoryCSV(from: history)
                case .json:
                    content = try generateHistoryJSON(from: history)
                }
                try content.write(to: url, atomically: true, encoding: .utf8)
                HapticFeedbackManager.shared.success()
            } catch {
                DebugLogger.log("Failed to export history: \(error.localizedDescription)")
                HapticFeedbackManager.shared.error()
                presentHistoryAlert(
                    title: "Export Failed",
                    message: "Sorty couldn't export history. Please try again."
                )
            }
        }
    }

    public func importHistory() {
        guard let historyStore = organizer?.history else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.title = "Import History"
        panel.message = "Choose a history JSON file exported from Sorty"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard resourceValues.isRegularFile == true else {
                throw HistoryImportError.unsupportedFormat
            }
            guard (resourceValues.fileSize ?? 0) <= 25 * 1_024 * 1_024 else {
                throw HistoryImportError.fileTooLarge
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let importedEntries = try decodeHistoryImportEntries(from: data)
            guard !importedEntries.isEmpty else {
                throw HistoryImportError.noEntries
            }

            let result = historyStore.importEntries(importedEntries)
            currentView = .history
            HapticFeedbackManager.shared.success()

            var details = ["Added \(result.added), updated \(result.updated), unchanged \(result.unchanged)."]
            if result.omittedByRetentionLimit > 0 {
                details.append("\(result.omittedByRetentionLimit) malformed entries were omitted.")
            }
            presentHistoryAlert(
                title: "Import Complete",
                message: details.joined(separator: " ")
            )
        } catch {
            DebugLogger.log("Failed to import history: \(error.localizedDescription)")
            HapticFeedbackManager.shared.error()

            presentHistoryAlert(
                title: "Import Failed",
                message: (error as? LocalizedError)?.errorDescription ?? "Sorty couldn't import this file."
            )
        }
    }

    public func clearHistoryWithConfirmation() {
        guard let historyStore = organizer?.history, !historyStore.entries.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear History?"
        alert.informativeText = "This will permanently remove all history entries. This cannot be undone."
        alert.addButton(withTitle: "Clear All History")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            historyStore.clearHistory()
            currentView = .history
            HapticFeedbackManager.shared.success()
        }
    }

    private func generateCSV(from plan: OrganizationPlan) -> String {
        var csv = "Original File,Original Path,New Location,Reasoning,Tags\n"

        func processSuggestion(_ suggestion: FolderSuggestion, parentPath: String) {
            let folderPath = parentPath + "/" + suggestion.folderName
            for file in suggestion.files {
                let originalName = file.displayName
                let originalPath = file.path
                let destination = folderPath + "/" + (suggestion.renameMapping(for: file)?.suggestedName ?? originalName)
                let reasoning = suggestion.reasoning
                let tags = suggestion.semanticTags.joined(separator: "; ")
                
                csv += "\(csvEscape(originalName)),\"\(csvEscape(originalPath))\",\(csvEscape(destination)),\(csvEscape(reasoning)),\"\(csvEscape(tags))\"\n"
            }
            for sub in suggestion.subfolders {
                processSuggestion(sub, parentPath: folderPath)
            }
        }

        for suggestion in plan.suggestions {
            processSuggestion(suggestion, parentPath: "")
        }

        return csv
    }
    
    private func generateJSON(from plan: OrganizationPlan) -> String {
        struct ExportEntry: Codable {
            let originalFile: String
            let originalPath: String
            let destinationPath: String
            let reasoning: String
            let tags: [String]
        }
        
        struct ExportData: Codable {
            let exportDate: String
            let totalFiles: Int
            let totalFolders: Int
            let entries: [ExportEntry]
        }
        
        var entries: [ExportEntry] = []
        var folderCount = 0
        
        func processSuggestion(_ suggestion: FolderSuggestion, parentPath: String) {
            let folderPath = parentPath + "/" + suggestion.folderName
            folderCount += 1
            
            for file in suggestion.files {
                let destination = folderPath + "/" + (suggestion.renameMapping(for: file)?.suggestedName ?? file.displayName)
                entries.append(ExportEntry(
                    originalFile: file.displayName,
                    originalPath: file.path,
                    destinationPath: destination,
                    reasoning: suggestion.reasoning,
                    tags: suggestion.semanticTags
                ))
            }
            for sub in suggestion.subfolders {
                processSuggestion(sub, parentPath: folderPath)
            }
        }
        
        for suggestion in plan.suggestions {
            processSuggestion(suggestion, parentPath: "")
        }
        
        let exportData = ExportData(
            exportDate: ISO8601DateFormatter().string(from: Date()),
            totalFiles: entries.count,
            totalFolders: folderCount,
            entries: entries
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        if let jsonData = try? encoder.encode(exportData),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }
        
        return "{\"error\": \"Failed to encode\"}"
    }
    
    private func generateHTML(from plan: OrganizationPlan) -> String {
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <title>Sorty Export</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 1200px; margin: 0 auto; padding: 20px; background: #f5f5f7; }
                h1 { color: #1d1d1f; margin-bottom: 10px; }
                .meta { color: #6e6e73; margin-bottom: 30px; }
                .folder { background: white; border-radius: 12px; padding: 20px; margin-bottom: 16px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
                .folder-name { font-size: 18px; font-weight: 600; color: #1d1d1f; margin-bottom: 8px; }
                .reasoning { color: #6e6e73; font-size: 14px; margin-bottom: 12px; font-style: italic; }
                .files { font-size: 14px; }
                .file { padding: 8px 0; border-bottom: 1px solid #e5e5e5; display: flex; justify-content: space-between; }
                .file:last-child { border-bottom: none; }
                .file-name { font-weight: 500; }
                .file-path { color: #6e6e73; font-size: 12px; }
                .tag { background: #007aff; color: white; padding: 2px 8px; border-radius: 10px; font-size: 11px; margin-right: 4px; }
            </style>
        </head>
        <body>
            <h1>📁 Sorty Export</h1>
            <p class="meta">Generated on \(Date().formatted(date: .long, time: .shortened))</p>
        """
        
        func processSuggestion(_ suggestion: FolderSuggestion, parentPath: String, depth: Int) {
            let folderPath = parentPath.isEmpty ? suggestion.folderName : parentPath + "/" + suggestion.folderName
            
            html += """
            <div class="folder" style="margin-left: \(depth * 20)px;">
                <div class="folder-name">📂 \(suggestion.folderName)</div>
                <div class="reasoning">\(suggestion.reasoning)</div>
            """
            
            if !suggestion.semanticTags.isEmpty {
                html += "<div class=\"tags\">"
                for tag in suggestion.semanticTags {
                    html += "<span class=\"tag\">\(tag)</span>"
                }
                html += "</div>"
            }
            
            if !suggestion.files.isEmpty {
                html += "<div class=\"files\">"
                for file in suggestion.files {
                    let newName = suggestion.renameMapping(for: file)?.suggestedName
                    html += """
                    <div class="file">
                        <div>
                            <span class="file-name">\(htmlEscape(file.displayName))</span>
                            \(newName != nil ? "<span style='color:#6e6e73;'> → \(htmlEscape(newName!))</span>" : "")
                        </div>
                        <span class="file-path">\(htmlEscape(file.path))</span>
                    </div>
                    """
                }
                html += "</div>"
            }
            
            html += "</div>"
            
            for sub in suggestion.subfolders {
                processSuggestion(sub, parentPath: folderPath, depth: depth + 1)
            }
        }
        
        for suggestion in plan.suggestions {
            processSuggestion(suggestion, parentPath: "", depth: 0)
        }
        
        html += """
        </body>
        </html>
        """
        
        return html
    }

    public func selectAllFiles() {
        // Select all implementation handled by focused view via responder chain
    }

    private enum HistoryImportError: LocalizedError {
        case unsupportedFormat
        case unsupportedSchema(Int)
        case inconsistentArchive
        case fileTooLarge
        case tooManyEntries
        case noEntries

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "This file isn't a supported Sorty history export."
            case .unsupportedSchema(let version):
                return "This history export uses schema version \(version), which this version of Sorty does not support."
            case .inconsistentArchive:
                return "This history export is incomplete or has been modified and cannot be imported safely."
            case .fileTooLarge:
                return "This history file is larger than the 25 MB import limit."
            case .tooManyEntries:
                return "This history file contains more than 10,000 entries and cannot be imported safely."
            case .noEntries:
                return "This history file does not contain any entries."
            }
        }
    }

    private struct HistoryArchiveExport: Codable {
        let schemaVersion: Int
        let exportedAt: String
        let appVersion: String?
        let entryCount: Int?
        let entries: [OrganizationHistoryEntry]
    }

    private struct LegacyHistoryExportEntry: Decodable {
        let id: String?
        let timestamp: String?
        let folderPath: String
        let status: String?
        let source: String?
        let filesOrganized: Int
        let foldersCreated: Int
        let errorMessage: String?

        func toHistoryEntry(dateFormatter: ISO8601DateFormatter) -> OrganizationHistoryEntry {
            let parsedID = id.flatMap(UUID.init(uuidString:)) ?? UUID()
            let parsedTimestamp = timestamp.flatMap { dateFormatter.date(from: $0) } ?? Date()
            let parsedStatus = status.flatMap(OrganizationStatus.init(rawValue:)) ?? .completed
            let parsedSource = source.flatMap(OrganizationEntrySource.init(rawValue:)) ?? .manual

            return OrganizationHistoryEntry(
                id: parsedID,
                timestamp: parsedTimestamp,
                directoryPath: folderPath,
                filesOrganized: filesOrganized,
                foldersCreated: foldersCreated,
                success: parsedStatus == .completed,
                status: parsedStatus,
                errorMessage: errorMessage,
                source: parsedSource
            )
        }
    }

    private func presentHistoryAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func decodeHistoryImportEntries(from data: Data) throws -> [OrganizationHistoryEntry] {
        guard data.count <= 25 * 1_024 * 1_024 else {
            throw HistoryImportError.fileTooLarge
        }
        let decoder = JSONDecoder()

        if let archive = try? decoder.decode(HistoryArchiveExport.self, from: data) {
            guard (1...2).contains(archive.schemaVersion) else {
                throw HistoryImportError.unsupportedSchema(archive.schemaVersion)
            }
            if let entryCount = archive.entryCount, entryCount != archive.entries.count {
                throw HistoryImportError.inconsistentArchive
            }
            guard archive.entries.count <= 10_000 else {
                throw HistoryImportError.tooManyEntries
            }
            return archive.entries
        }

        if let entries = try? decoder.decode([OrganizationHistoryEntry].self, from: data) {
            guard entries.count <= 10_000 else { throw HistoryImportError.tooManyEntries }
            return entries
        }

        if let legacyEntries = try? decoder.decode([LegacyHistoryExportEntry].self, from: data) {
            guard legacyEntries.count <= 10_000 else { throw HistoryImportError.tooManyEntries }
            let dateFormatter = ISO8601DateFormatter()
            return legacyEntries.map { $0.toHistoryEntry(dateFormatter: dateFormatter) }
        }

        throw HistoryImportError.unsupportedFormat
    }

    private func generateHistoryCSV(from entries: [OrganizationHistoryEntry]) -> String {
        var lines: [String] = []
        lines.append("ID,Timestamp,Folder Path,Folder Name,Status,Source,Files Organized,Folders Created,Was Undone,Undo Restored,Undo Failed Files,Duplicates Deleted,Recovered Bytes,Duplicate Cleanup Mode,Plan Suggestions,Recorded Operations,Error Message")

        let dateFormatter = ISO8601DateFormatter()

        for entry in entries {
            let folderName = URL(fileURLWithPath: entry.directoryPath).lastPathComponent
            let undoRestoredCount = entry.undoRestoredCount.map(String.init) ?? ""
            let undoFailedFiles = csvEscape(entry.undoFailedFiles?.joined(separator: " | ") ?? "")
            let duplicatesDeleted = entry.duplicatesDeleted.map(String.init) ?? ""
            let recoveredSpace = entry.recoveredSpace.map(String.init) ?? ""
            let planSuggestionCount = entry.plan.map { String($0.suggestions.count) } ?? ""
            let recordedOperationCount = String(entry.storedOperationCount)
            let errorMessage = csvEscape(entry.errorMessage ?? "")
            let fields: [String] = [
                entry.id.uuidString,
                dateFormatter.string(from: entry.timestamp),
                csvEscape(entry.directoryPath),
                csvEscape(folderName),
                entry.status.rawValue,
                entry.source.rawValue,
                String(entry.filesOrganized),
                String(entry.foldersCreated),
                String(entry.isUndone),
                undoRestoredCount,
                undoFailedFiles,
                duplicatesDeleted,
                recoveredSpace,
                entry.duplicateCleanupMode?.rawValue ?? "",
                planSuggestionCount,
                recordedOperationCount,
                errorMessage
            ]
            let row = fields.joined(separator: ",")
            lines.append(row)
        }

        return lines.joined(separator: "\n")
    }

    private func generateHistoryJSON(from entries: [OrganizationHistoryEntry]) throws -> String {
        let payload = HistoryArchiveExport(
            schemaVersion: 2,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            entryCount: entries.count,
            entries: entries
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public func startOrganization() {
        guard let organizer = organizer, let directory = selectedDirectory else { return }
        Task {
            try? await organizer.organize(directory: directory)
        }
    }

    public func regenerateOrganization() {
        guard let organizer = organizer else { return }
        Task {
            try? await organizer.regeneratePreview()
        }
    }

    public func applyChanges() {
        guard let organizer = organizer, let directory = selectedDirectory else { return }
        Task {
            try? await organizer.apply(at: directory)
        }
    }

    public func previewChanges() {
        // Navigation to preview is handled by view logic
    }

    public func cancelOperation() {
        organizer?.reset()
    }

    public func showHelp() {
        openSettingsWindow(section: .help)
        navigatedFromSettings = true
        HapticFeedbackManager.shared.selection()
    }
    
    // MARK: - Learnings Actions

    private func postWindowScopedNotification(
        _ name: Notification.Name,
        userInfo: [AnyHashable: Any] = [:]
    ) {
        NotificationCenter.default.post(
            name: name,
            object: nil,
            userInfo: MainWindowRouter.scopedUserInfo(userInfo, targetSessionID: windowSessionID)
        )
    }
    
    public func showLearningsStats() {
        currentView = .learnings
        postWindowScopedNotification(.showLearningsStats)
    }
    
    public func pauseLearning() {
        authenticateForSensitiveAction(
            reason: "Authenticate to pause learning and review your learnings controls."
        ) { [weak self] in
            self?.postWindowScopedNotification(.pauseLearning)
        }
    }

    public var isLearningPaused: Bool {
        organizer?.learningsManager?.consentManager.hasConsented == false
    }

    public func toggleLearning() {
        guard isLearningPaused else {
            pauseLearning()
            return
        }

        guard let learningsManager = organizer?.learningsManager else { return }
        Task { @MainActor in
            await learningsManager.grantConsent()
            HapticFeedbackManager.shared.success()
        }
    }
    
    public func exportLearningsProfile() {
        authenticateForSensitiveAction(
            reason: "Authenticate to export your learnings profile."
        ) { [weak self] in
            self?.currentView = .learnings
            self?.postWindowScopedNotification(.exportLearningsProfile)
        }
    }
    
    public func importLearningsProfile() {
        authenticateForSensitiveAction(
            reason: "Authenticate to import a learnings profile."
        ) { [weak self] in
            self?.currentView = .learnings
            self?.postWindowScopedNotification(.importLearningsProfile)
        }
    }

    public func requestDeleteUsageDataConfirmation() {
        authenticateForSensitiveAction(
            reason: "Authenticate to delete all Sorty usage data."
        ) { [weak self] in
            self?.showDeleteUsageDataConfirmation = true
        }
    }

    public func requestUninstallConfirmation() {
        authenticateForSensitiveAction(
            reason: "Authenticate to uninstall Sorty."
        ) { [weak self] in
            self?.presentUninstallConfirmation()
        }
    }

    private func presentUninstallConfirmation() {
        guard SortyUninstaller.canRemoveCurrentApplication() else {
            HapticFeedbackManager.shared.error()
            presentHistoryAlert(
                title: "Sorty Can't Uninstall from This Location",
                message: "macOS won't allow Sorty to delete the app from its current location. Move Sorty to a writable Applications folder and try again."
            )
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall Sorty?"
        alert.informativeText = """
        Sorty will close, delete the app, and remove its settings, history, caches, logs, Keychain credentials, Finder actions, login and background items, notifications, and privacy permissions.

        Files and folders you organized with Sorty won't be changed. This can't be undone.
        """
        alert.addButton(withTitle: "Uninstall Sorty")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        uninstallSorty()
    }

    private func uninstallSorty() {
        let report = SortyUninstaller.run()
        if report.didScheduleApplicationRemoval {
            NotificationCenter.default.post(name: .forceQuitSorty, object: nil)
            NSApp.terminate(nil)
        } else {
            HapticFeedbackManager.shared.error()
            let failedItems = report.blockingFailureDescriptions.joined(separator: ", ")
            let detail = failedItems.isEmpty
                ? "macOS couldn't schedule deletion of the app."
                : "Sorty couldn't remove its \(failedItems)."
            presentHistoryAlert(
                title: "Uninstall Could Not Finish",
                message: "\(detail) The app was not deleted, so you can resolve the issue and try again."
            )
        }
    }
    
    public func deleteUsageData() {
        // Guard re-entrancy: the blocking portion below runs off the main actor.
        guard !isDeletingUsageData else { return }
        isDeletingUsageData = true

        // Strong capture: the UI reset must still run even if the calling view goes away mid-erase.
        Task { @MainActor in
            var deletionFailures: [Error] = []

            AnalyticsManager.shared.resetConsentAndData()
            GitHubCopilotAuthManager.shared.signOut()

            // Keychain and filesystem deletes block; run them off the main actor.
            // Ordering after this point matches the previous synchronous version.
            let blockingFailures = await Task.detached(priority: .userInitiated) {
                var failures: [Error] = []
                if !KeychainManager.deleteAll() {
                    failures.append(UsageDataDeletionError.keychain)
                }
                failures.append(contentsOf: SortyUsageDataEraser.erase())
                return failures
            }.value
            deletionFailures.append(contentsOf: blockingFailures)

            DuplicateRestorationManager.shared.clearAllData()
            SortyWidgetSnapshotStore.clear()

            organizer?.reset()
            duplicateManager.clearResults()
            selectedDirectory = nil
            duplicateSelectedDirectory = nil
            duplicateSelectedGroup = nil
            pendingDuplicatesHandoff = nil
            highlightedWatchedFolderID = nil
            pendingNotificationActionRequest = nil
            lastOrganizedDirectory = nil
            settingsFocusTarget = nil
            requiresSetupRepair = false
            setupRepairMessage = nil

            withAnimation(.spring()) {
                hasCompletedOnboarding = false
            }

            postWindowScopedNotification(.clearLearningsData)
            NotificationCenter.default.post(name: .clearAllUsageData, object: nil)

            userDefaults.dictionaryRepresentation().keys.forEach(userDefaults.removeObject(forKey:))
            UserDefaults(suiteName: SortyWidgetSnapshotStore.appGroupIdentifier)?
                .removePersistentDomain(forName: SortyWidgetSnapshotStore.appGroupIdentifier)

            if let failure = deletionFailures.first {
                HapticFeedbackManager.shared.error()
                NotificationManager.shared.showError(
                    message: "Some Sorty data could not be deleted: \(failure.localizedDescription)",
                    isCritical: true
                )
            } else {
                HapticFeedbackManager.shared.success()
            }
            isDeletingUsageData = false
        }
    }

    private enum UsageDataDeletionError: LocalizedError {
        case keychain

        var errorDescription: String? {
            "Sorty could not remove all Keychain data."
        }
    }

    public func authenticateForSensitiveAction(
        reason: String,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        if !FeatureFlags.sensitiveActionAuthenticationEnabled {
            onSuccess()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let didAuthenticate = await sensitiveActionSecurityManager.authenticateForSensitiveAction(reason: reason)
            guard didAuthenticate else {
                HapticFeedbackManager.shared.error()
                return
            }
            onSuccess()
        }
    }
    
    public func showAbout() {
        // If window already exists and is visible, just bring it to front
        if let existingWindow = aboutWindowController?.window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Create a new About window
        let aboutView = AboutView(openAccreditations: { [weak self] in
            self?.showAccreditations(entryPoint: .about)
        })
        let hostingView = NSHostingView(rootView: aboutView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "About Sorty"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        if #available(macOS 26.0, *) {
            window.backgroundColor = .clear
            window.isOpaque = false
        }
        window.center()
        
        // Retain the window controller to prevent deallocation
        aboutWindowController = NSWindowController(window: window)
        aboutWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func showInternetAccessPolicy(entryPoint: InternetAccessPolicyEntryPoint = .appMenu) {
        let policyView = InternetAccessPolicyView(
            showBackButton: entryPoint == .about,
            onBack: entryPoint == .about ? { [weak self] in
                self?.internetAccessPolicyWindowController?.close()
                self?.showAbout()
                HapticFeedbackManager.shared.selection()
            } : nil
        )
        let hostingView = NSHostingView(rootView: policyView)

        if let existingWindow = internetAccessPolicyWindowController?.window {
            existingWindow.contentView = hostingView
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            HapticFeedbackManager.shared.selection()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "Internet Access Policy"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        if #available(macOS 26.0, *) {
            window.backgroundColor = .clear
            window.isOpaque = false
        }
        window.center()

        internetAccessPolicyWindowController = NSWindowController(window: window)
        internetAccessPolicyWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        HapticFeedbackManager.shared.selection()
    }

    public func showAccreditations(entryPoint: AccreditationsEntryPoint = .help) {
        let accreditationsView = AccreditationsView(
            showBackButton: entryPoint == .about,
            onBack: entryPoint == .about ? { [weak self] in
                self?.accreditationsWindowController?.close()
                self?.showAbout()
                HapticFeedbackManager.shared.selection()
            } : nil
        )
        let hostingView = NSHostingView(rootView: accreditationsView)

        if let existingWindow = accreditationsWindowController?.window {
            existingWindow.contentView = hostingView
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            HapticFeedbackManager.shared.selection()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "Sorty Accreditations"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        if #available(macOS 26.0, *) {
            window.backgroundColor = .clear
            window.isOpaque = false
        }
        window.center()

        accreditationsWindowController = NSWindowController(window: window)
        accreditationsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        HapticFeedbackManager.shared.selection()
    }

    public func showThanksForUsingSorty() {
        // If window already exists and is visible, just bring it to front
        if let existingWindow = thanksWindowController?.window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            HapticFeedbackManager.shared.selection()
            return
        }

        let thanksView = ThanksForUsingSortyView()
        let hostingView = NSHostingView(rootView: thanksView)

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: ThanksForUsingSortyView.preferredWindowWidth,
                height: ThanksForUsingSortyView.preferredWindowHeight
            ),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "Thanks for Using Sorty"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        if #available(macOS 26.0, *) {
            window.backgroundColor = .clear
            window.isOpaque = false
        }
        window.center()

        thanksWindowController = NSWindowController(window: window)
        thanksWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        HapticFeedbackManager.shared.selection()
    }
    
    private func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }

    private func htmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

struct SortyUsageDataEraser {
    struct Locations {
        let applicationSupportDirectory: URL?
        let cachesDirectory: URL?
        let temporaryDirectory: URL
        let appGroupContainer: URL?
    }

    static func erase(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.sorty.app",
        locations: Locations? = nil
    ) -> [Error] {
        let locations = locations ?? defaultLocations(fileManager: fileManager)
        var failures: [Error] = []

        let removableRoots = ownedRoots(
            bundleIdentifier: bundleIdentifier,
            locations: locations
        )
        for root in removableRoots where fileManager.fileExists(atPath: root.path) {
            do {
                try fileManager.removeItem(at: root)
            } catch {
                failures.append(error)
            }
        }

        if let appGroupContainer = locations.appGroupContainer {
            failures.append(contentsOf: removeContents(
                of: appGroupContainer,
                fileManager: fileManager
            ))
        }

        failures.append(contentsOf: removeOwnedTemporaryItems(
            from: locations.temporaryDirectory,
            fileManager: fileManager
        ))
        return failures
    }

    static func ownedRoots(
        bundleIdentifier: String,
        locations: Locations
    ) -> [URL] {
        var roots: [URL] = []

        if let applicationSupportDirectory = locations.applicationSupportDirectory {
            roots.append(applicationSupportDirectory.appendingPathComponent("Sorty", isDirectory: true))
            roots.append(applicationSupportDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true))
        }

        if let cachesDirectory = locations.cachesDirectory {
            roots.append(cachesDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true))
            roots.append(cachesDirectory.appendingPathComponent("Sorty", isDirectory: true))
        }

        var seenPaths = Set<String>()
        return roots.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
    }

    private static func defaultLocations(fileManager: FileManager) -> Locations {
        Locations(
            applicationSupportDirectory: fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first,
            cachesDirectory: fileManager.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first,
            temporaryDirectory: fileManager.temporaryDirectory,
            appGroupContainer: fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: SortyWidgetSnapshotStore.appGroupIdentifier
            )
        )
    }

    private static func removeContents(
        of directory: URL,
        fileManager: FileManager
    ) -> [Error] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        do {
            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).compactMap { item in
                do {
                    try fileManager.removeItem(at: item)
                    return nil
                } catch {
                    return error
                }
            }
        } catch {
            return [error]
        }
    }

    private static func removeOwnedTemporaryItems(
        from directory: URL,
        fileManager: FileManager
    ) -> [Error] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        let prefixes = ["sorty-", "Sorty_", "SortyNotificationIcon-"]
        do {
            let items = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { item in
                prefixes.contains { item.lastPathComponent.hasPrefix($0) }
            }

            return items.compactMap { item in
                do {
                    try fileManager.removeItem(at: item)
                    return nil
                } catch {
                    return error
                }
            }
        } catch {
            return [error]
        }
    }
}
