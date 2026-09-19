//
//  WatchedFolder.swift
//  Sorty
//
//  Model for folders being monitored for automatic organization
//

import Foundation
import Combine

public extension Notification.Name {
    static let autoOrganizeDisabledGlobally = Notification.Name("autoOrganizeDisabledGlobally")
    static let retryWatchedFolderBatch = Notification.Name("retryWatchedFolderBatch")
    static let discardWatchedFolderBatch = Notification.Name("discardWatchedFolderBatch")
    static let discardWatchedFolderReview = Notification.Name("discardWatchedFolderReview")
}

public enum FolderAccessStatus: String, Codable, Sendable {
    case valid
    case stale
    case lost
    case unknown
}

public enum WatchedFolderReauthorizationResult: Sendable {
    case success
    case incorrectFolder
    case bookmarkCreationFailed
}

public enum WatchedFolderActivity: Equatable, Sendable {
    case waitingForStability(fileCount: Int, nextAttemptAt: Date)
    case queued(fileCount: Int, nextAttemptAt: Date)
    case retrying(fileCount: Int, attempt: Int, nextAttemptAt: Date)
    case parked(fileCount: Int)
    case running(fileCount: Int)
    case awaitingReview(fileCount: Int)
}

public enum WatchedFolderApplyPolicy: String, Codable, CaseIterable, Sendable {
    case autoApply
    case notifyAndReview

    public var displayName: String {
        switch self {
        case .autoApply: "Apply Automatically"
        case .notifyAndReview: "Notify and Review"
        }
    }
}

public struct WatchedFolder: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var path: String
    public var name: String
    public var isEnabled: Bool
    public var autoOrganize: Bool
    public var lastTriggered: Date?
    public var triggerDelay: TimeInterval // Seconds to wait after file changes before organizing
    public var snoozedUntil: Date?
    public var customPrompt: String?
    public var temperature: Double?
    public var bookmarkData: Data?
    public var accessStatus: FolderAccessStatus = .unknown
    public var modelOverride: String?           // nil = use global automation model
    public var providerOverride: AIProvider?    // nil = use global automation provider
    /// Optional for backwards-compatible decoding of watched folders saved before action modes existed.
    public var organizationMode: OrganizationMode?
    public var applyPolicy: WatchedFolderApplyPolicy?
    
    public init(
        id: UUID = UUID(),
        path: String,
        name: String? = nil,
        isEnabled: Bool = true,
        autoOrganize: Bool = true,
        lastTriggered: Date? = nil,
        triggerDelay: TimeInterval = 7.0,
        snoozedUntil: Date? = nil,
        customPrompt: String? = nil,
        temperature: Double? = nil,
        bookmarkData: Data? = nil,
        modelOverride: String? = nil,
        providerOverride: AIProvider? = nil,
        organizationMode: OrganizationMode = .organize,
        applyPolicy: WatchedFolderApplyPolicy = .autoApply
    ) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.isEnabled = isEnabled
        self.autoOrganize = autoOrganize
        self.lastTriggered = lastTriggered
        self.triggerDelay = triggerDelay
        self.snoozedUntil = snoozedUntil
        self.customPrompt = customPrompt
        self.temperature = temperature
        self.bookmarkData = bookmarkData
        self.modelOverride = modelOverride
        self.providerOverride = providerOverride
        self.organizationMode = organizationMode
        self.applyPolicy = applyPolicy
    }

    public var effectiveOrganizationMode: OrganizationMode {
        organizationMode ?? .organize
    }

    public var isSnoozed: Bool {
        snoozedUntil.map { $0 > Date() } ?? false
    }

    public var effectiveApplyPolicy: WatchedFolderApplyPolicy {
        applyPolicy ?? .autoApply
    }
    
    public var url: URL {
        URL(fileURLWithPath: path)
    }
}

private struct WatchedFolderExistenceRequest: Sendable {
    let id: UUID
    let path: String
}

private actor WatchedFolderExistenceProbe {
    func statuses(for requests: [WatchedFolderExistenceRequest]) -> [UUID: Bool] {
        var statuses: [UUID: Bool] = [:]
        statuses.reserveCapacity(requests.count)

        for request in requests {
            guard !Task.isCancelled else { break }
            statuses[request.id] = FileManager.default.fileExists(atPath: request.path)
        }
        return statuses
    }
}

/// Manager for persisting watched folders
@MainActor
public class WatchedFoldersManager: ObservableObject {
    @Published public private(set) var folders: [WatchedFolder] = []
    @Published public private(set) var activeFolderCount = 0
    @Published public private(set) var accessIssueFolderCount = 0
    @Published public private(set) var monitoringRevision = 0
    @Published public private(set) var activityByFolder: [UUID: WatchedFolderActivity] = [:]
    @Published public private(set) var folderExistenceByID: [UUID: Bool] = [:]
    @Published public private(set) var hasLoadedPersistedState = false

    private let userDefaults = UserDefaults.standard
    private let persistedDataReader = UserDefaultsDataReader(.standard)
    private let legacyStorageKey = "watchedFolders"
    private let activeCountStorageKey = "activeWatchedFolderCount"
    private let journal = WatchedFolderJournal()
    private let existenceProbe = WatchedFolderExistenceProbe()
    private var activeSecurityScopedURLs: [UUID: URL] = [:]
    private var indexByID: [UUID: Int] = [:]
    private var idByNormalizedPath: [String: UUID] = [:]
    private var existenceRefreshTask: Task<Void, Never>?
    private var loadTask: Task<([WatchedFolder], Bool), Never>?
    private var loadGeneration = 0
    private var restoreTask: Task<Void, Never>?

    private struct BookmarkRestoreSnapshot: Sendable {
        let id: UUID
        let bookmarkData: Data
        let path: String
    }

    private struct BookmarkRestoreResult: Sendable {
        let id: UUID
        let originalBookmark: Data
        let status: FolderAccessStatus
        let newBookmark: Data?
        let resolvedPath: String?
        let url: URL?
        let didAccess: Bool
    }
    
    public init() {
        if userDefaults.object(forKey: activeCountStorageKey) != nil {
            activeFolderCount = userDefaults.integer(forKey: activeCountStorageKey)
        }
        setupNotificationObservers()
    }

    /// Replays the append-only journal off the main actor so its size does not delay the first window.
    public func loadPersistedState() async {
        guard !hasLoadedPersistedState else { return }

        let generation = loadGeneration
        let task: Task<([WatchedFolder], Bool), Never>
        if let loadTask {
            task = loadTask
        } else {
            let journal = journal
            let persistedDataReader = persistedDataReader
            let legacyStorageKey = legacyStorageKey
            task = Task.detached(priority: .userInitiated) {
                if let journalFolders = journal.load() {
                    return (journalFolders, false)
                }
                guard let data = persistedDataReader.data(forKey: legacyStorageKey),
                      let decoded = try? JSONDecoder().decode([WatchedFolder].self, from: data) else {
                    return ([], false)
                }
                return (decoded, journal.replaceAll(with: decoded))
            }
            loadTask = task
        }

        let (persistedFolders, didMigrateLegacyStorage) = await task.value
        guard !hasLoadedPersistedState, generation == loadGeneration else { return }

        let inMemoryByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let persistedIDs = Set(persistedFolders.map(\.id))
        var loadedFolders = persistedFolders.map { inMemoryByID[$0.id] ?? $0 }
        loadedFolders.append(contentsOf: folders.filter { !persistedIDs.contains($0.id) })
        for index in loadedFolders.indices {
            loadedFolders[index].autoOrganize = loadedFolders[index].isEnabled
        }
        folders = loadedFolders
        rebuildIndexes()
        setActiveFolderCount(folders.lazy.filter(\.isEnabled).count)
        accessIssueFolderCount = folders.lazy.filter(Self.hasAccessIssue).count
        hasLoadedPersistedState = true
        loadTask = nil

        if didMigrateLegacyStorage {
            userDefaults.removeObject(forKey: legacyStorageKey)
        }
        refreshFolderExistence()
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addMainActorObserver(forName: .clearAllUsageData, object: nil, queue: .main) { [weak self] in
            self?.clearAll()
        }
    }
    
    public func addFolder(_ folder: WatchedFolder) {
        let normalizedPath = Self.normalizedPath(folder.path)
        guard idByNormalizedPath[normalizedPath] == nil else { return }

        var normalizedFolder = folder
        normalizedFolder.autoOrganize = normalizedFolder.isEnabled
        indexByID[normalizedFolder.id] = folders.count
        idByNormalizedPath[normalizedPath] = normalizedFolder.id
        folders.append(normalizedFolder)
        journal.upsert(normalizedFolder)
        monitoringRevision &+= 1
        if normalizedFolder.isEnabled {
            setActiveFolderCount(activeFolderCount + 1)
        }
        if Self.hasAccessIssue(normalizedFolder) {
            accessIssueFolderCount += 1
        }
        refreshFolderExistence()
        AnalyticsManager.shared.captureFeature(
            feature: "watched_folders",
            subfeature: "folder_management",
            action: "add",
            outcome: "success",
            properties: ["mode": normalizedFolder.effectiveOrganizationMode.rawValue]
        )
    }

    public func clearAll() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        restoreTask?.cancel()
        restoreTask = nil
        hasLoadedPersistedState = true
        stopAllSecurityScopedAccess()
        folders.removeAll()
        activityByFolder.removeAll()
        folderExistenceByID.removeAll()
        indexByID.removeAll()
        idByNormalizedPath.removeAll()
        activeFolderCount = 0
        accessIssueFolderCount = 0
        journal.clear()
        monitoringRevision &+= 1
        userDefaults.removeObject(forKey: legacyStorageKey)
        userDefaults.set(0, forKey: activeCountStorageKey)
    }
    
    public func removeFolder(_ folder: WatchedFolder) {
        stopSecurityScopedAccess(for: folder.id)
        guard let index = indexByID.removeValue(forKey: folder.id) else { return }

        let removedFolder = folders[index]
        idByNormalizedPath.removeValue(forKey: Self.normalizedPath(removedFolder.path))
        let lastIndex = folders.index(before: folders.endIndex)
        if index != lastIndex {
            folders.swapAt(index, lastIndex)
            indexByID[folders[index].id] = index
        }
        folders.removeLast()
        journal.remove(folder.id)
        activityByFolder.removeValue(forKey: folder.id)
        folderExistenceByID.removeValue(forKey: folder.id)
        monitoringRevision &+= 1
        if removedFolder.isEnabled {
            setActiveFolderCount(max(activeFolderCount - 1, 0))
        }
        if Self.hasAccessIssue(removedFolder) {
            accessIssueFolderCount = max(accessIssueFolderCount - 1, 0)
        }
        AnalyticsManager.shared.captureFeature(
            feature: "watched_folders",
            subfeature: "folder_management",
            action: "remove",
            outcome: "success"
        )
    }
    
    public func updateFolder(_ folder: WatchedFolder) {
        updateFolder(folder, affectsMonitoring: true)
    }

    private func updateFolder(_ folder: WatchedFolder, affectsMonitoring: Bool) {
        guard let index = indexByID[folder.id] else { return }

        let oldPath = Self.normalizedPath(folders[index].path)
        let newPath = Self.normalizedPath(folder.path)
        if oldPath != newPath,
           let existingID = idByNormalizedPath[newPath],
           existingID != folder.id {
            return
        }

        let previousFolder = folders[index]
        let wasEnabled = previousFolder.isEnabled
        var normalizedFolder = folder
        normalizedFolder.autoOrganize = normalizedFolder.isEnabled
        guard previousFolder != normalizedFolder else { return }
        folders[index] = normalizedFolder
        idByNormalizedPath.removeValue(forKey: oldPath)
        idByNormalizedPath[newPath] = normalizedFolder.id
        journal.upsert(normalizedFolder)
        if affectsMonitoring {
            monitoringRevision &+= 1
        }
        if wasEnabled != normalizedFolder.isEnabled {
            setActiveFolderCount(activeFolderCount + (normalizedFolder.isEnabled ? 1 : -1))
        }
        let hadAccessIssue = Self.hasAccessIssue(previousFolder)
        let hasAccessIssue = Self.hasAccessIssue(normalizedFolder)
        if hadAccessIssue != hasAccessIssue {
            accessIssueFolderCount += hasAccessIssue ? 1 : -1
        }
        if oldPath != newPath || folderExistenceByID[folder.id] == nil {
            refreshFolderExistence()
        }
    }
    
    public func toggleEnabled(for folder: WatchedFolder) {
        if var updated = self.folder(withID: folder.id) {
            updated.isEnabled.toggle()
            updated.autoOrganize = updated.isEnabled
            updateFolder(updated)
            AnalyticsManager.shared.captureFeature(
                feature: "watched_folders",
                subfeature: "monitoring",
                action: updated.isEnabled ? "enable" : "disable",
                outcome: "success"
            )
        }
    }

    public func snooze(_ folder: WatchedFolder, until: Date?) {
        guard var updated = self.folder(withID: folder.id) else { return }
        updated.snoozedUntil = until
        updateFolder(updated)
    }

    public func setActivity(_ activity: WatchedFolderActivity?, for folderID: UUID) {
        if let activity {
            activityByFolder[folderID] = activity
        } else {
            activityByFolder.removeValue(forKey: folderID)
        }
    }
    
    public func markTriggered(_ folder: WatchedFolder) {
        if var updated = self.folder(withID: folder.id) {
            updated.lastTriggered = Date()
            updateFolder(updated, affectsMonitoring: false)
            AnalyticsManager.shared.captureFeature(
                feature: "watched_folders",
                subfeature: "automatic_organization",
                action: "trigger",
                outcome: "started",
                properties: ["mode": updated.effectiveOrganizationMode.rawValue]
            )
        }
    }
    
    /// Disables auto-organize for all folders when AI provider becomes invalid
    public func disableAutoOrganizeForAll(reason: String) {
        var hasChanges = false
        var updatedFolders = folders
        
        for (index, folder) in folders.enumerated() {
            if folder.isEnabled {
                updatedFolders[index].isEnabled = false
                updatedFolders[index].autoOrganize = false
                hasChanges = true
            }
        }
        
        if hasChanges {
            folders = updatedFolders
            rebuildIndexes()
            journal.disableAll()
            monitoringRevision &+= 1
            setActiveFolderCount(0)
            
            // Post notification for user feedback
            NotificationCenter.default.post(
                name: .autoOrganizeDisabledGlobally,
                object: nil,
                userInfo: ["reason": reason]
            )
        }
    }
    
    /// Restores access to all security-scoped bookmarks off the main actor.
    /// Snapshots identity before leaving, accepts results only for matching items,
    /// and balances every acquisition. Callers await this before automation uses folders.
    public func restoreSecurityScopedAccess() async {
        await loadPersistedState()
        if let restoreTask {
            await restoreTask.value
            return
        }

        let generation = loadGeneration
        let snapshots: [BookmarkRestoreSnapshot] = folders.compactMap { folder in
            guard let bookmarkData = folder.bookmarkData else { return nil }
            return BookmarkRestoreSnapshot(id: folder.id, bookmarkData: bookmarkData, path: folder.path)
        }
        guard !snapshots.isEmpty else { return }

        let task = Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                Self.resolveBookmarks(snapshots)
            }.value
            guard let self else {
                for result in results where result.didAccess {
                    result.url?.stopAccessingSecurityScopedResource()
                }
                return
            }
            self.applyBookmarkRestoreResults(results, generation: generation)
        }
        restoreTask = task
        await task.value
        restoreTask = nil
    }

    private nonisolated static func resolveBookmarks(
        _ snapshots: [BookmarkRestoreSnapshot]
    ) -> [BookmarkRestoreResult] {
        var results: [BookmarkRestoreResult] = []
        results.reserveCapacity(snapshots.count)
        let requiresAccess = SandboxEnvironment.isSandboxed

        for snapshot in snapshots {
            guard !Task.isCancelled else { break }
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: snapshot.bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if !requiresAccess {
                    // Outside the sandbox, stale bookmarks are harmless:
                    // renew opportunistically and report valid so dev builds
                    // do not surface spurious access issues.
                    var newBookmark: Data? = nil
                    if isStale {
                        newBookmark = try? url.bookmarkData(
                            options: .withSecurityScope,
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        )
                    }
                    results.append(
                        BookmarkRestoreResult(
                            id: snapshot.id,
                            originalBookmark: snapshot.bookmarkData,
                            status: .valid,
                            newBookmark: newBookmark,
                            resolvedPath: url.path,
                            url: nil,
                            didAccess: false
                        )
                    )
                    continue
                }

                guard url.startAccessingSecurityScopedResource() else {
                    results.append(
                        BookmarkRestoreResult(
                            id: snapshot.id,
                            originalBookmark: snapshot.bookmarkData,
                            status: .lost,
                            newBookmark: nil,
                            resolvedPath: nil,
                            url: nil,
                            didAccess: false
                        )
                    )
                    continue
                }

                var newBookmark: Data? = nil
                if isStale {
                    newBookmark = try? url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                }
                results.append(
                    BookmarkRestoreResult(
                        id: snapshot.id,
                        originalBookmark: snapshot.bookmarkData,
                        status: isStale ? .stale : .valid,
                        newBookmark: newBookmark,
                        resolvedPath: url.path,
                        url: url,
                        didAccess: true
                    )
                )
            } catch {
                results.append(
                    BookmarkRestoreResult(
                        id: snapshot.id,
                        originalBookmark: snapshot.bookmarkData,
                        status: .lost,
                        newBookmark: nil,
                        resolvedPath: nil,
                        url: nil,
                        didAccess: false
                    )
                )
            }
        }
        return results
    }

    private func applyBookmarkRestoreResults(
        _ results: [BookmarkRestoreResult],
        generation: Int
    ) {
        guard generation == loadGeneration else {
            for result in results where result.didAccess {
                result.url?.stopAccessingSecurityScopedResource()
            }
            return
        }

        var updatedFolders = folders
        var hasChanges = false
        var persistenceIndexes: Set<Int> = []

        for result in results {
            guard let index = indexByID[result.id],
                  updatedFolders.indices.contains(index),
                  updatedFolders[index].id == result.id,
                  updatedFolders[index].bookmarkData == result.originalBookmark else {
                if result.didAccess {
                    result.url?.stopAccessingSecurityScopedResource()
                }
                continue
            }

            let previousPath = updatedFolders[index].path
            stopSecurityScopedAccess(for: result.id)

            if result.status == .lost {
                if updatedFolders[index].accessStatus != .lost {
                    updatedFolders[index].accessStatus = .lost
                    hasChanges = true
                }
                continue
            }

            if result.didAccess, let url = result.url, Self.requiresSecurityScopedAccess {
                activeSecurityScopedURLs[result.id] = url
            }

            if let newBookmark = result.newBookmark {
                updatedFolders[index].bookmarkData = newBookmark
                hasChanges = true
                persistenceIndexes.insert(index)
            }
            if updatedFolders[index].accessStatus != result.status {
                updatedFolders[index].accessStatus = result.status
                hasChanges = true
            }
            if let resolvedPath = result.resolvedPath, resolvedPath != previousPath {
                updatedFolders[index].path = resolvedPath
                hasChanges = true
                persistenceIndexes.insert(index)
            }
        }

        if hasChanges {
            folders = updatedFolders
            rebuildIndexes()
            for index in persistenceIndexes {
                journal.upsert(folders[index])
            }
            if !persistenceIndexes.isEmpty {
                monitoringRevision &+= 1
            }
            accessIssueFolderCount = folders.lazy.filter(Self.hasAccessIssue).count
        }
    }
    
    /// Re-authorizes a watched folder by creating a new security-scoped bookmark from a freshly-picked URL
    @discardableResult
    public func reauthorizeFolder(
        _ folder: WatchedFolder,
        with url: URL
    ) -> WatchedFolderReauthorizationResult {
        guard Self.normalizedPath(url.path) == Self.normalizedPath(folder.path) else {
            DebugLogger.log(
                "Rejected watched-folder access for unexpected path: expected \(folder.path), selected \(url.path)"
            )
            return .incorrectFolder
        }

        // For URLs from fileImporter, startAccessingSecurityScopedResource()
        // may return false because the picker already grants temporary access.
        // We proceed with bookmark creation regardless.
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let newBookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            // Immediately resolve and activate the new bookmark so the folder
            // is usable in the current session without requiring an app restart.
            var isStale = false
            if let resolvedURL = try? URL(resolvingBookmarkData: newBookmarkData,
                                          options: .withSecurityScope,
                                          relativeTo: nil,
                                          bookmarkDataIsStale: &isStale) {
                // Start accessing the resolved bookmark URL. We intentionally
                // do NOT stop this access — it must remain active for the
                // watched folder to function until the app quits.
                stopSecurityScopedAccess(for: folder.id)
                if Self.requiresSecurityScopedAccess,
                   resolvedURL.startAccessingSecurityScopedResource() {
                    activeSecurityScopedURLs[folder.id] = resolvedURL
                }
            }

            var updated = folder
            updated.bookmarkData = newBookmarkData
            updated.path = url.path
            updated.accessStatus = .valid
            updateFolder(updated)

            DebugLogger.log("Successfully reauthorized watched folder: \(folder.name)")
            return .success
        } catch {
            DebugLogger.log("Failed to create bookmark during reauthorization: \(error)")
            return .bookmarkCreationFailed
        }
    }

    public func folder(withID id: UUID) -> WatchedFolder? {
        guard let index = indexByID[id], folders.indices.contains(index) else {
            return nil
        }
        return folders[index]
    }

    public func folder(matchingPath path: String) -> WatchedFolder? {
        guard let id = idByNormalizedPath[Self.normalizedPath(path)] else {
            return nil
        }
        return folder(withID: id)
    }

    public func folderExists(_ folderID: UUID) -> Bool {
        folderExistenceByID[folderID] ?? true
    }

    /// Refreshes cached folder existence without performing filesystem work on the main actor.
    public func refreshFolderExistence() {
        existenceRefreshTask?.cancel()
        let requests = folders.map {
            WatchedFolderExistenceRequest(id: $0.id, path: $0.path)
        }

        guard !requests.isEmpty else {
            folderExistenceByID.removeAll()
            return
        }

        existenceRefreshTask = Task { [weak self, existenceProbe] in
            let statuses = await existenceProbe.statuses(for: requests)
            guard !Task.isCancelled, let self else { return }

            var currentStatuses = folderExistenceByID
            let currentIDs = Set(folders.map(\.id))
            currentStatuses = currentStatuses.filter { currentIDs.contains($0.key) }

            for request in requests where folder(withID: request.id)?.path == request.path {
                currentStatuses[request.id] = statuses[request.id]
            }
            if currentStatuses != folderExistenceByID {
                folderExistenceByID = currentStatuses
            }
        }
    }

    private func rebuildIndexes() {
        indexByID.removeAll(keepingCapacity: true)
        idByNormalizedPath.removeAll(keepingCapacity: true)
        indexByID.reserveCapacity(folders.count)
        idByNormalizedPath.reserveCapacity(folders.count)

        for (index, folder) in folders.enumerated() {
            indexByID[folder.id] = index
            idByNormalizedPath[Self.normalizedPath(folder.path)] = folder.id
        }
    }

    private func setActiveFolderCount(_ count: Int) {
        guard activeFolderCount != count ||
              userDefaults.object(forKey: activeCountStorageKey) == nil else {
            return
        }
        activeFolderCount = count
        userDefaults.set(activeFolderCount, forKey: activeCountStorageKey)
    }

    private func stopSecurityScopedAccess(for id: UUID) {
        guard let url = activeSecurityScopedURLs.removeValue(forKey: id) else { return }
        url.stopAccessingSecurityScopedResource()
    }

    private func stopAllSecurityScopedAccess() {
        for url in activeSecurityScopedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs.removeAll()
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func hasAccessIssue(_ folder: WatchedFolder) -> Bool {
        // Outside the sandbox, .stale is informational only (renewed
        // opportunistically); only .lost blocks automation.
        if folder.accessStatus == .lost {
            return true
        }
        if folder.accessStatus == .stale {
            return SandboxEnvironment.isSandboxed
        }
        return false
    }

    private static var requiresSecurityScopedAccess: Bool {
        SandboxEnvironment.isSandboxed
    }
}

/// Append-only persistence keeps add, update, trigger, and removal work O(1).
/// The previous UserDefaults array re-encoded every bookmark and folder record
/// after each small change, creating large temporary allocations at scale.
private final class WatchedFolderJournal: @unchecked Sendable {
    private enum Operation: String, Codable {
        case upsert
        case remove
        case disableAll
    }

    private struct Record: Codable {
        let operation: Operation
        let id: UUID
        let folder: WatchedFolder?
    }

    private let ioQueue = DispatchQueue(label: "com.sorty.watched-folders.persistence", qos: .utility)
    private let fileManager = FileManager.default
    private let storeURL: URL?

    init() {
        let isRunningTests =
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
            || NSClassFromString("XCTestCase") != nil
        if isRunningTests {
            storeURL = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "SortyTests-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
                .appendingPathComponent("WatchedFolders.jsonl")
        } else {
            storeURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Sorty", isDirectory: true)
                .appendingPathComponent("WatchedFolders.jsonl")
        }
    }

    func load() -> [WatchedFolder]? {
        ioQueue.sync {
            guard let storeURL, fileManager.fileExists(atPath: storeURL.path) else {
                return nil
            }

            guard let stream = InputStream(url: storeURL) else { return [] }
            stream.open()
            defer { stream.close() }

            var slots: [WatchedFolder?] = []
            var indexByID: [UUID: Int] = [:]
            var readBuffer = [UInt8](repeating: 0, count: 64 * 1_024)
            var lineBuffer: [UInt8] = []
            lineBuffer.reserveCapacity(4_096)
            let decoder = JSONDecoder()

            func applyLine() {
                guard !lineBuffer.isEmpty,
                      let record = try? decoder.decode(Record.self, from: Data(lineBuffer)) else {
                    lineBuffer.removeAll(keepingCapacity: true)
                    return
                }

                switch record.operation {
                case .upsert:
                    guard let folder = record.folder else { break }
                    if let index = indexByID[record.id] {
                        slots[index] = folder
                    } else {
                        indexByID[record.id] = slots.count
                        slots.append(folder)
                    }
                case .remove:
                    if let index = indexByID.removeValue(forKey: record.id) {
                        slots[index] = nil
                    }
                case .disableAll:
                    for index in slots.indices {
                        slots[index]?.isEnabled = false
                        slots[index]?.autoOrganize = false
                    }
                }
                lineBuffer.removeAll(keepingCapacity: true)
            }

            while true {
                let count = stream.read(&readBuffer, maxLength: readBuffer.count)
                guard count > 0 else { break }
                for byte in readBuffer.prefix(count) {
                    if byte == 0x0A {
                        applyLine()
                    } else {
                        lineBuffer.append(byte)
                    }
                }
            }
            applyLine()
            return slots.compactMap { $0 }
        }
    }

    func upsert(_ folder: WatchedFolder) {
        append(Record(operation: .upsert, id: folder.id, folder: folder))
    }

    func remove(_ id: UUID) {
        append(Record(operation: .remove, id: id, folder: nil))
    }

    func disableAll() {
        append(Record(operation: .disableAll, id: UUID(), folder: nil))
    }

    func clear() {
        ioQueue.sync {
            guard let storeURL, fileManager.fileExists(atPath: storeURL.path) else {
                return
            }
            try? fileManager.removeItem(at: storeURL)
        }
    }

    @discardableResult
    func replaceAll(with folders: [WatchedFolder]) -> Bool {
        ioQueue.sync {
            guard let storeURL else { return false }
            do {
                try fileManager.createDirectory(
                    at: storeURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let temporaryURL = storeURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(".WatchedFolders-\(UUID().uuidString).jsonl")
                fileManager.createFile(atPath: temporaryURL.path, contents: nil)
                let handle = try FileHandle(forWritingTo: temporaryURL)
                let encoder = JSONEncoder()

                for folder in folders {
                    let record = Record(operation: .upsert, id: folder.id, folder: folder)
                    try handle.write(contentsOf: encoder.encode(record))
                    try handle.write(contentsOf: Data([0x0A]))
                }
                try handle.close()

                if fileManager.fileExists(atPath: storeURL.path) {
                    _ = try fileManager.replaceItemAt(storeURL, withItemAt: temporaryURL)
                } else {
                    try fileManager.moveItem(at: temporaryURL, to: storeURL)
                }
                return true
            } catch {
                DebugLogger.log("Failed to compact watched-folder storage: \(error)")
                return false
            }
        }
    }

    private func append(_ record: Record) {
        ioQueue.sync {
            guard let storeURL else { return }
            do {
                try fileManager.createDirectory(
                    at: storeURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !fileManager.fileExists(atPath: storeURL.path) {
                    fileManager.createFile(atPath: storeURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: storeURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: JSONEncoder().encode(record))
                try handle.write(contentsOf: Data([0x0A]))
                try handle.close()
            } catch {
                DebugLogger.log("Failed to persist watched-folder change: \(error)")
            }
        }
    }
}
