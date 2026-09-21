//
//  SparkleUpdateManager.swift
//  Sorty
//
//  Sparkle framework integration for automatic in-app updates
//

import AppKit
import Combine
import Foundation
import SwiftUI

#if canImport(Sparkle)
import Sparkle
#endif

public enum SparkleUpdateFeed {
    public static let stableAppcastURLString = "https://github.com/sorty-organizer/Sorty/releases/latest/download/appcast-v2.xml"
}

enum SparkleVersionHistoryLink {
    private static let changelogURL = URL(
        string: "https://sorty-organizer.github.io/Sorty/changelog/"
    )!

    static func url(for version: String?) -> URL {
        guard let version else { return changelogURL }

        let versionSlug = version
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")

        guard !versionSlug.isEmpty else { return changelogURL }
        return URL(string: "\(changelogURL.absoluteString)#version-\(versionSlug)") ?? changelogURL
    }
}

struct SparkleTrafficLightSkipStore {
    private static let skippedVersionsKey = "trafficLightSkippedUpdateVersions"
    private static let versionPrefix = "build:"
    private static let displayVersionPrefix = "display:"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func contains(version: String, displayVersion: String) -> Bool {
        skippedVersions.contains(Self.versionPrefix + version)
            || skippedVersions.contains(Self.displayVersionPrefix + displayVersion)
            || skippedVersions.contains(version)
            || skippedVersions.contains(displayVersion)
    }

    func markSkipped(version: String, displayVersion: String) {
        var versions = skippedVersions
        versions.insert(Self.versionPrefix + version)
        versions.insert(Self.displayVersionPrefix + displayVersion)
        save(versions)
    }

    func clearSkipped(version: String, displayVersion: String) {
        var versions = skippedVersions
        versions.remove(Self.versionPrefix + version)
        versions.remove(Self.displayVersionPrefix + displayVersion)
        versions.remove(version)
        versions.remove(displayVersion)
        save(versions)
    }

    func prune(installedVersion: String?, installedDisplayVersion: String?) {
        let comparator = SUStandardVersionComparator.default
        let retained = skippedVersions.filter { storedVersion in
            let installed: String?
            let candidate: String
            if storedVersion.hasPrefix(Self.versionPrefix) {
                candidate = String(storedVersion.dropFirst(Self.versionPrefix.count))
                installed = installedVersion
            } else if storedVersion.hasPrefix(Self.displayVersionPrefix) {
                candidate = String(storedVersion.dropFirst(Self.displayVersionPrefix.count))
                installed = installedDisplayVersion
            } else {
                // Old entries did not record which version field they came from.
                return false
            }
            guard let installed else { return false }
            return comparator.compareVersion(candidate, toVersion: installed) == .orderedDescending
        }
        save(retained)
    }

    private var skippedVersions: Set<String> {
        Set(userDefaults.stringArray(forKey: Self.skippedVersionsKey) ?? [])
    }

    private func save(_ versions: Set<String>) {
        userDefaults.set(versions.sorted(), forKey: Self.skippedVersionsKey)
    }
}

@MainActor
public class SparkleUpdateManager: ObservableObject {

    @Published public var canCheckForUpdates = false
    @Published public var lastCheckDate: Date?
    @Published public var updateState: UpdateState = .idle
    @Published public private(set) var updateChannel: UpdateChannel = .current

    public enum UpdateChannel: String, Equatable {
        case stable
        case nightly

        public static var current: UpdateChannel {
            .stable
        }

        public var displayName: String {
            switch self {
            case .stable:
                return "Stable"
            case .nightly:
                return "Nightly"
            }
        }
    }

    public enum UpdateState: Equatable {
        case idle
        case checking
        case available(version: String, releaseNotes: String?)
        case upToDate
        case error(String)
        case downloading(progress: Double?)
        case readyToInstall
        case installing
        case disabled

        /// True while an update is actively downloading or installing.
        public var isBusyPhase: Bool {
            switch self {
            case .downloading, .installing:
                return true
            default:
                return false
            }
        }
    }

    #if canImport(Sparkle)
    private var updater: SPUUpdater?
    private var updaterDelegate: SparkleUpdaterDelegate?
    private var userDriverDelegate: SparkleUserDriverDelegate?
    private var userDriver: SparkleUserDriver?
    #else
    private var updater: Any?
    private var updaterDelegate: Any?
    private var userDriverDelegate: Any?
    private var userDriver: Any?
    #endif

    // UserDefaults key for persisting last check date
    private static let lastAutoCheckKey = "lastSparkleUpdateCheckDate"
    private var lastObservedUpdateChannel = UpdateChannel.current
    private var hasRequestedLaunchCheck = false
    private var hasInitialized = false
    private var updateChannelRefreshTask: Task<Void, Never>?

    public init() {
        if let savedDate = UserDefaults.standard.object(forKey: Self.lastAutoCheckKey) as? Date {
            self.lastCheckDate = savedDate
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUserDefaultsDidChangeNotification(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(
            self,
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    @objc nonisolated private func handleUserDefaultsDidChangeNotification(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.scheduleUpdateChannelRefresh()
        }
    }

    private func scheduleUpdateChannelRefresh() {
        updateChannelRefreshTask?.cancel()
        updateChannelRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.handleUserDefaultsDidChange()
            self?.updateChannelRefreshTask = nil
        }
    }

    private func handleUserDefaultsDidChange() {
        let currentUpdateChannel = UpdateChannel.current

        if currentUpdateChannel != lastObservedUpdateChannel {
            lastObservedUpdateChannel = currentUpdateChannel
            updateChannel = currentUpdateChannel
            LogManager.shared.log("Sparkle update channel changed to \(currentUpdateChannel.displayName)", category: "SparkleUpdateManager")
        }
    }

    private func initializeIfNeeded() {
        guard !hasInitialized else { return }
        hasInitialized = true

        #if canImport(Sparkle)
        let updaterDelegate = SparkleUpdaterDelegate()
        let userDriverDelegate = SparkleUserDriverDelegate()
        let userDriver = SparkleUserDriver(
            hostBundle: .main,
            delegate: userDriverDelegate
        )
        userDriver.pruneSkippedVersions()
        self.updaterDelegate = updaterDelegate
        self.userDriverDelegate = userDriverDelegate
        self.userDriver = userDriver
        updateChannel = Self.UpdateChannel.current

        updaterDelegate.stateCallback = { [weak self] state in
            if let self,
               case .available = self.updateState,
               case .error = state {
                return
            }
            self?.updateState = state
        }
        userDriver.stateCallback = { [weak self] state in
            self?.updateState = state
        }

        do {
            try initializeSparkle()
        } catch {
            LogManager.shared.log("Sparkle initialization failed (expected during development builds): \(error.localizedDescription)", level: .warning, category: "SparkleUpdateManager")
            updateState = .disabled
        }
        #else
        updateState = .disabled
        #endif
    }

    #if canImport(Sparkle)
    private func initializeSparkle() throws {
        // Check if we have a valid app bundle with SUFeedURL configured
        guard Bundle.main.infoDictionary?["SUFeedURL"] != nil else {
            throw SparkleError.noFeedURLConfigured
        }
        
        LogManager.shared.log("Initializing Sparkle updater controller...", category: "SparkleUpdateManager")

        guard let userDriver, let updaterDelegate else {
            return
        }
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: updaterDelegate
        )
        try updater.start()
        self.updater = updater

        // Bind canCheckForUpdates to the updater's publisher
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    private enum SparkleError: LocalizedError {
        case noFeedURLConfigured

        var errorDescription: String? {
            switch self {
            case .noFeedURLConfigured:
                return "No SUFeedURL configured in Info.plist"
            }
        }
    }
    #endif

    /// Check for updates immediately
    public func checkForUpdates() {
        guard allowInternetUpdateAction() else { return }
        initializeIfNeeded()

        #if canImport(Sparkle)
        guard let updater else {
            LogManager.shared.log("Cannot check for updates - Sparkle is disabled", level: .warning, category: "SparkleUpdateManager")
            return
        }

        if updater.sessionInProgress {
            NSApp.activate(ignoringOtherApps: true)
            userDriver?.showUpdateInFocus()
            return
        }

        updateState = .checking
        updater.checkForUpdates()
        recordCheckDate()
        #else
        LogManager.shared.log("Sparkle is not available in this build", level: .warning, category: "SparkleUpdateManager")
        updateState = .disabled
        #endif
    }

    /// Check for updates in the background (no UI)
    public func checkForUpdatesInBackground() {
        guard allowInternetUpdateAction() else { return }
        initializeIfNeeded()

        #if canImport(Sparkle)
        guard let updater = self.updater as? SPUUpdater else {
            LogManager.shared.log("Cannot check for updates in background - Sparkle is disabled", level: .warning, category: "SparkleUpdateManager")
            return
        }
        guard !updater.sessionInProgress else { return }
        switch updateState {
        case .idle, .upToDate, .error, .disabled:
            updateState = .checking
            updater.checkForUpdatesInBackground()
            recordCheckDate()
        case .checking, .available, .downloading, .readyToInstall, .installing:
            return
        }
        #else
        LogManager.shared.log("Sparkle is not available in this build", level: .warning, category: "SparkleUpdateManager")
        updateState = .disabled
        #endif
    }

    /// Check for updates once per app launch so the title-bar update control does
    /// not depend on the user opening Sparkle's interactive update window first.
    public func checkOnLaunchIfNeeded(minimumInterval: TimeInterval = 0) {
        guard !hasRequestedLaunchCheck else { return }
        hasRequestedLaunchCheck = true
        guard allowInternetUpdateAction() else { return }

        // Check the persisted date before loading and starting Sparkle. A
        // skipped background check should have no framework startup cost.
        if minimumInterval > 0,
           let lastCheck = UserDefaults.standard.object(forKey: Self.lastAutoCheckKey) as? Date {
            let elapsed = Date.now.timeIntervalSince(lastCheck)
            if elapsed < minimumInterval {
                LogManager.shared.log("Skipping auto-update check, last check was \(Int(elapsed / 60)) minutes ago", category: "SparkleUpdateManager")
                return
            }
        }

        initializeIfNeeded()

        // Skip if Sparkle is disabled
        #if canImport(Sparkle)
        guard let updater, updater.automaticallyChecksForUpdates else { return }
        #else
        return
        #endif

        // Skip if already checking
        guard updateState != .checking else { return }

        LogManager.shared.log("Performing automatic update check on launch", category: "SparkleUpdateManager")
        checkForUpdatesInBackground()
    }

    /// Starts downloading the update already discovered by the background check.
    /// Sparkle continues to own download, validation, installation, and relaunch.
    @discardableResult
    public func installAvailableUpdate() -> Bool {
        guard allowInternetUpdateAction() else { return false }
        initializeIfNeeded()

        #if canImport(Sparkle)
        guard let userDriver else { return false }
        return userDriver.installPendingUpdate()
        #else
        return false
        #endif
    }

    /// Brings Sparkle's current download or installation status window forward.
    public func showUpdateInFocus() {
        guard allowInternetUpdateAction() else { return }
        initializeIfNeeded()

        #if canImport(Sparkle)
        NSApp.activate(ignoringOtherApps: true)
        userDriver?.showUpdateInFocus()
        #endif
    }

    private func allowInternetUpdateAction() -> Bool {
        guard !NetworkPrivacyPolicy.isInternetPrivacyModeEnabled else {
            updateState = .error(NetworkPrivacyPolicy.blockedMessage)
            LogManager.shared.log(
                "Skipped update network access because Block Internet Connections is enabled",
                level: .warning,
                category: "SparkleUpdateManager"
            )
            return false
        }

        return true
    }

    private func recordCheckDate() {
        let checkDate = Date.now
        lastCheckDate = checkDate
        UserDefaults.standard.set(checkDate, forKey: Self.lastAutoCheckKey)
    }
}

#if canImport(Sparkle)
// MARK: - Updater Delegate

@MainActor
private class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var stateCallback: ((SparkleUpdateManager.UpdateState) -> Void)?

    nonisolated func updater(
        _ updater: SPUUpdater,
        mayPerform updateCheck: SPUUpdateCheck
    ) throws {
        guard !NetworkPrivacyPolicy.isInternetPrivacyModeEnabled else {
            throw NSError(
                domain: "com.sorty.app.network-privacy",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: NetworkPrivacyPolicy.blockedMessage]
            )
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        guard !NetworkPrivacyPolicy.isInternetPrivacyModeEnabled else {
            throw NSError(
                domain: "com.sorty.app.network-privacy",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: NetworkPrivacyPolicy.blockedMessage]
            )
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        LogManager.shared.log(
            "Sparkle found update: \(item.displayVersionString)",
            category: "SparkleUpdateManager"
        )
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.stateCallback?(.upToDate)
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let message = error.localizedDescription
        
        // Log detailed error information for debugging
        let nsError = error as NSError
        let userInfo = nsError.userInfo
        let underlyingError = userInfo[NSUnderlyingErrorKey] as? Error
        let underlyingMessage = underlyingError?.localizedDescription ?? "None"
        
        LogManager.shared.log("Sparkle update failed: \(message). Underlying: \(underlyingMessage). Code: \(nsError.code)", level: .error, category: "SparkleUpdateManager")
        
        Task { @MainActor in
            self.stateCallback?(.error(message))
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.stateCallback?(.installing)
        }
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        LogManager.shared.log("Application will relaunch after update", category: "SparkleUpdateManager")
    }

    nonisolated func versionComparator(for updater: SPUUpdater) -> SUVersionComparison? {
        return nil // Use default version comparison
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        []
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        nil
    }
}

// MARK: - Traffic-Light User Driver

/// Holds a scheduled update at Sparkle's first user choice so the orange
/// title-bar control can begin the download without showing the full update
/// alert. Once the download begins, Sparkle's standard status UI takes over.
@MainActor
private final class SparkleUserDriver: SPUStandardUserDriver {
    var stateCallback: ((SparkleUpdateManager.UpdateState) -> Void)?

    private let skipStore = SparkleTrafficLightSkipStore()
    private var pendingAppcastItem: SUAppcastItem?
    private var pendingState: SPUUserUpdateState?
    private var pendingReply: ((SPUUserUpdateChoice) -> Void)?
    private var isHoldingScheduledUpdate = false
    private var downloadedBytes: UInt64 = 0
    private var expectedContentLength: UInt64 = 0

    /// Fraction 0...1 when the total size is known, otherwise nil.
    private var downloadProgress: Double? {
        guard expectedContentLength > 0 else { return nil }
        return min(Double(downloadedBytes) / Double(expectedContentLength), 1.0)
    }

    private func publishDownloadProgress() {
        stateCallback?(.downloading(progress: downloadProgress))
    }

    override func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let version = appcastItem.versionString
        let displayVersion = appcastItem.displayVersionString
        let availableState = SparkleUpdateManager.UpdateState.available(
            version: appcastItem.displayVersionString,
            releaseNotes: appcastItem.itemDescription
        )
        let stateAwareReply: (SPUUserUpdateChoice) -> Void = { [weak self] choice in
            switch choice {
            case .install:
                self?.skipStore.clearSkipped(version: version, displayVersion: displayVersion)
                self?.stateCallback?(.downloading(progress: nil))
            case .dismiss:
                self?.skipStore.clearSkipped(version: version, displayVersion: displayVersion)
                self?.stateCallback?(availableState)
            case .skip:
                self?.skipStore.markSkipped(version: version, displayVersion: displayVersion)
                self?.stateCallback?(.idle)
            @unknown default:
                self?.stateCallback?(.idle)
            }
            reply(choice)
        }

        guard !state.userInitiated else {
            stateCallback?(availableState)
            super.showUpdateFound(with: appcastItem, state: state, reply: stateAwareReply)
            return
        }

        guard !skipStore.contains(version: version, displayVersion: displayVersion) else {
            stateAwareReply(.skip)
            return
        }

        stateCallback?(availableState)
        pendingAppcastItem = appcastItem
        pendingState = state
        pendingReply = stateAwareReply
        isHoldingScheduledUpdate = true
    }

    func installPendingUpdate() -> Bool {
        guard let appcastItem = pendingAppcastItem else { return false }

        if appcastItem.isInformationOnlyUpdate {
            presentPendingUpdate()
        } else {
            let reply = pendingReply
            clearPendingUpdate()
            reply?(.install)
        }
        return true
    }

    func pruneSkippedVersions() {
        let installedVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        let installedDisplayVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        skipStore.prune(
            installedVersion: installedVersion,
            installedDisplayVersion: installedDisplayVersion
        )
    }

    override func showUpdateInFocus() {
        if isHoldingScheduledUpdate {
            presentPendingUpdate()
        }
        super.showUpdateInFocus()
    }

    override func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard !isHoldingScheduledUpdate else { return }
        super.showUpdateReleaseNotes(with: downloadData)
    }

    override func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        guard !isHoldingScheduledUpdate else { return }
        super.showUpdateReleaseNotesFailedToDownloadWithError(error)
    }

    override func showDownloadInitiated(cancellation: @escaping () -> Void) {
        downloadedBytes = 0
        expectedContentLength = 0
        stateCallback?(.downloading(progress: nil))
        super.showDownloadInitiated(cancellation: cancellation)
    }

    override func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        self.expectedContentLength = expectedContentLength
        super.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
        publishDownloadProgress()
    }

    override func showDownloadDidReceiveData(ofLength length: UInt64) {
        downloadedBytes += length
        super.showDownloadDidReceiveData(ofLength: length)
        publishDownloadProgress()
    }

    override func showDownloadDidStartExtractingUpdate() {
        stateCallback?(.downloading(progress: nil))
        super.showDownloadDidStartExtractingUpdate()
    }

    override func showExtractionReceivedProgress(_ progress: Double) {
        super.showExtractionReceivedProgress(progress)
        stateCallback?(.downloading(progress: min(max(progress, 0), 1)))
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        stateCallback?(.readyToInstall)
        super.showReady(toInstallAndRelaunch: reply)
    }

    override func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        stateCallback?(.installing)
        super.showInstallingUpdate(
            withApplicationTerminated: applicationTerminated,
            retryTerminatingApplication: retryTerminatingApplication
        )
    }

    override func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        stateCallback?(.error(error.localizedDescription))
        super.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    override func dismissUpdateInstallation() {
        clearPendingUpdate()
        super.dismissUpdateInstallation()
    }

    private func presentPendingUpdate() {
        guard let appcastItem = pendingAppcastItem,
              let state = pendingState,
              let reply = pendingReply else { return }

        clearPendingUpdate()
        super.showUpdateFound(with: appcastItem, state: state, reply: reply)
    }

    private func clearPendingUpdate() {
        pendingAppcastItem = nil
        pendingState = nil
        pendingReply = nil
        isHoldingScheduledUpdate = false
    }
}

// MARK: - User Driver Delegate

private class SparkleUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    func standardUserDriverShowVersionHistory(for _: SUAppcastItem) {
        let installedVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let versionHistoryURL = SparkleVersionHistoryLink.url(for: installedVersion)

        Task { @MainActor in
            NSWorkspace.shared.open(versionHistoryURL)
        }
    }

    func standardUserDriverShouldHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) -> Bool {
        return true // Let Sparkle handle the UI
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        LogManager.shared.log("Sparkle will show update dialog for version \(update.displayVersionString)", category: "SparkleUpdateManager")
    }

    func standardUserDriverShouldHandleUpdateFound(forUpdate update: SUAppcastItem, state: SPUUserUpdateState) -> Bool {
        return true // Let Sparkle handle showing the update found UI
    }

    func standardUserDriverWillHandleUpdateFound(forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        LogManager.shared.log("Sparkle found update: \(update.displayVersionString)", category: "SparkleUpdateManager")
    }
}
#endif
