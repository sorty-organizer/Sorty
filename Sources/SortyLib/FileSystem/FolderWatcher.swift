//
//  FolderWatcher.swift
//  Sorty
//
//  Scalable FSEvents monitoring for watched folders.
//

import Foundation
import AppKit
import CoreServices

/// Protocol for receiving bounded folder-change batches.
///
/// Completing with `false` applies backpressure. `FolderWatcher` retains the batch,
/// pauses its event stream if necessary, and retries without growing an
/// unbounded in-memory queue.
@MainActor
public protocol FolderWatcherDelegate: AnyObject {
    func folderWatcher(
        _ watcher: FolderWatcher,
        didDetectChangesIn folder: WatchedFolder,
        newFiles: Set<String>,
        resolvedURL: URL,
        completion: @escaping @Sendable (Bool) -> Void
    )

    func folderWatcher(
        _ watcher: FolderWatcher,
        didDetectStaleBookmarkFor folder: WatchedFolder,
        newBookmarkData: Data
    )
}

/// Monitors directory hierarchies using one coalesced FSEvents stream.
///
/// All mutable state is isolated to `queue`. File enumeration is isolated to a
/// single utility queue, and delivery is bounded by the delegate's backpressure
/// response. This is why the type can safely cross actor boundaries.
public final class FolderWatcher: @unchecked Sendable {
    @MainActor public weak var delegate: FolderWatcherDelegate?

    private struct PersistedEventCursor: Codable {
        let eventID: FSEventStreamEventId
        let updatedAt: Date
    }

    private struct FileFingerprint: Codable, Equatable, Sendable {
        let size: Int64
        let modificationDate: Date?
    }

    private struct PersistedFolderSnapshot: Codable {
        let rootPath: String
        let files: [String: FileFingerprint]
        let updatedAt: Date
    }

    private struct RecoveryTarget: Sendable {
        let folderID: UUID
        let rootPath: String
        let baseline: [String: FileFingerprint]?
    }

    private static let maximumFilesPerBatch = 256
    private static let maximumPendingFiles = 4_096
    private static let eventCursorPersistenceDelay: TimeInterval = 5
    private static let streamLatency: TimeInterval = 1
    private static let retryDelay: TimeInterval = 0.25
    private static let healthCheckInterval: TimeInterval = 60
    private static let reconciliationInterval: TimeInterval = 300
    private static let maximumReconciliationInterval: TimeInterval = 3_600
    private static let maximumExplicitRootsPerAnchor = 512
    private static let maximumPendingScans = 128

    private let queue = DispatchQueue(label: "com.sorty.folderwatcher", qos: .utility)
    private let scanQueue = DispatchQueue(label: "com.sorty.folderwatcher.scanner", qos: .utility)
    private let queueSpecificKey = DispatchSpecificKey<Void>()
    private let fileManager = FileManager.default
    private let persistenceRootOverride: URL?

    private var stream: FSEventStreamRef?
    private var callbackContext: UnsafeMutableRawPointer?
    private var watchedFolders: [UUID: WatchedFolder] = [:]
    private var resolvedURLs: [UUID: URL] = [:]
    private var securityScopedFolderIDs: Set<UUID> = []
    private var folderIDsByRootPath: [String: [UUID]] = [:]
    private var sortedRootPaths: [String] = []
    private var monitoringRoots: [String] = []
    private var pausedFolders: Set<UUID> = []
    private var minimumEventIDs: [UUID: FSEventStreamEventId] = [:]
    private var exclusionMatcher = ExclusionMatcher.empty

    private var pendingFiles: [UUID: Set<String>] = [:]
    private var deliveryInFlight: Set<UUID> = []
    private var debounceWorkItems: [UUID: DispatchWorkItem] = [:]
    private var pendingFileCount = 0
    private var isSuspendedForBackpressure = false
    private var shouldReplayAfterBackpressure = false

    private var recentlyRemovedFiles: [UUID: [String: Date]] = [:]
    private var activeScanCount = 0
    private var activeScanPath: String?
    private var pendingScanPaths: [String] = []
    private var recoveryScanPaths: Set<String> = []
    private var requiresFullRecoveryScan = false
    private var reconciliationTimer: DispatchSourceTimer?
    private var streamRecoveryTimer: DispatchSourceTimer?
    private var cursorPersistenceWorkItem: DispatchWorkItem?
    private var persistedEventID: FSEventStreamEventId?
    private var latestProcessedEventID: FSEventStreamEventId?
    /// Event cursor at the last full reconciliation. When the cursor has not
    /// advanced since then, the stream is live, and no recovery is pending,
    /// there is nothing to rescan (FSEvents guarantees delivery).
    private var eventIDAtLastReconciliation: FSEventStreamEventId?
    private var replayFromEventID: FSEventStreamEventId?
    private var hasCompletedInitialSync = false
    private var folderSnapshots: [UUID: [String: FileFingerprint]] = [:]
    private var dirtySnapshotFolderIDs: Set<UUID> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationObservers: [NSObjectProtocol] = []
    private var lastReconciliationAt = Date.distantPast
    private var currentReconciliationInterval = reconciliationInterval

    private lazy var watcherStateURL: URL? = {
        let root = persistenceRootOverride
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Sorty", isDirectory: true)
        return root?.appendingPathComponent("WatcherState.json")
    }()

    private lazy var snapshotStoreDirectory: URL? = {
        let root = persistenceRootOverride
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Sorty", isDirectory: true)
        return root?.appendingPathComponent("WatcherSnapshots", isDirectory: true)
    }()

    public convenience init() {
        self.init(persistenceRoot: nil)
    }

    init(persistenceRoot: URL?) {
        self.persistenceRootOverride = persistenceRoot
        queue.setSpecific(key: queueSpecificKey, value: ())
        // Cursor restores on the watcher queue so `Data(contentsOf:)` never
        // blocks the main thread. `syncWithFolders` also hops to this queue,
        // so FIFO ordering preserves load-before-sync without a gate.
        queue.async { [weak self] in
            guard let self else { return }
            let cursor = self.readPersistedEventCursor()
            self.persistedEventID = cursor?.eventID
            self.latestProcessedEventID = cursor?.eventID
            self.replayFromEventID = cursor?.eventID
        }
        installWorkspaceObservers()
    }

    deinit {
        performOnQueueSyncIfNeeded {
            stopStream()
            reconciliationTimer?.cancel()
            reconciliationTimer = nil
            streamRecoveryTimer?.cancel()
            streamRecoveryTimer = nil
            cursorPersistenceWorkItem?.cancel()
            cursorPersistenceWorkItem = nil
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        applicationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Public API

    /// Atomically replaces the immutable matcher used by the event and recovery
    /// scan pipelines. Pending batches are rechecked so a newly enabled rule
    /// takes effect before already-buffered files reach automation.
    public func updateExclusionMatcher(_ matcher: ExclusionMatcher) {
        queue.async { [weak self] in
            guard let self else { return }
            self.exclusionMatcher = matcher
            self.removeExcludedPendingFiles()
        }
    }

    /// Pauses one watched root without interrupting unrelated roots.
    public func pause(_ folder: WatchedFolder) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pausedFolders.insert(folder.id)
            self.clearPendingFiles(for: folder.id)
            self.minimumEventIDs[folder.id] = FSEventsGetCurrentEventId()
            DebugLogger.log("Paused watching: \(folder.name)")
        }
    }

    /// Resumes from the current event cursor, intentionally ignoring changes
    /// made while Sorty owned the folder for a manual operation.
    public func resume(_ folder: WatchedFolder) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pausedFolders.remove(folder.id)
            self.clearPendingFiles(for: folder.id)
            self.minimumEventIDs[folder.id] = FSEventsGetCurrentEventId()
            self.folderSnapshots.removeValue(forKey: folder.id)
            self.beginScan(at: self.rootPath(for: folder.id, folder: folder), isRecovery: true)
            DebugLogger.log("Resumed watching: \(folder.name)")
        }
    }

    /// Advances the root's baseline after known in-app mutations.
    ///
    /// Rebuilds the recovery baseline after known in-app mutations without
    /// delivering those mutations back through automation.
    public func refreshSnapshot(for folder: WatchedFolder) {
        queue.async { [weak self] in
            guard let self else { return }
            self.clearPendingFiles(for: folder.id)
            self.minimumEventIDs[folder.id] = FSEventsGetCurrentEventId()
            self.folderSnapshots.removeValue(forKey: folder.id)
            self.beginScan(at: self.rootPath(for: folder.id, folder: folder), isRecovery: true)
            DebugLogger.log("Rebuilding watcher recovery baseline: \(folder.name)")
        }
    }

    public func startWatching(_ folder: WatchedFolder) {
        queue.async { [weak self] in
            guard let self, folder.isEnabled else { return }
            let previousRoots = self.monitoringRoots
            self.install(folder, minimumEventID: FSEventsGetCurrentEventId())
            self.rebuildPathIndex()
            if previousRoots != self.monitoringRoots {
                self.rebuildStream()
            }
            self.beginScan(
                at: self.rootPath(for: folder.id, folder: folder),
                isRecovery: true
            )
            self.startHealthTimerIfNeeded()
        }
    }

    /// Reconciles persisted baselines with disk without waiting for a stream event.
    /// This is used after launch/configuration and as a bounded fallback if FSEvents
    /// was quiet while the app was rebuilding or not running.
    public func reconcileNow() {
        queue.async { [weak self] in
            self?.scheduleFullReconciliation()
        }
    }

    public func stopWatching(_ folder: WatchedFolder) {
        queue.async { [weak self] in
            guard let self else { return }
            let previousRoots = self.monitoringRoots
            self.uninstall(folderID: folder.id)
            self.rebuildPathIndex()
            if previousRoots != self.monitoringRoots {
                self.rebuildStream()
            }
            self.stopHealthTimerIfIdle()
        }
    }

    public func stopAllWatching() {
        performOnQueueSyncIfNeeded {
            stopStream()
            for folderID in securityScopedFolderIDs {
                resolvedURLs[folderID]?.stopAccessingSecurityScopedResource()
            }
            resolvedURLs.removeAll()
            securityScopedFolderIDs.removeAll()
            watchedFolders.removeAll()
            folderIDsByRootPath.removeAll()
            sortedRootPaths.removeAll()
            monitoringRoots.removeAll()
            pausedFolders.removeAll()
            minimumEventIDs.removeAll()
            clearAllPendingFiles()
            pendingScanPaths.removeAll()
            recoveryScanPaths.removeAll()
            folderSnapshots.removeAll()
            requiresFullRecoveryScan = false
            stopHealthTimerIfIdle()
        }
    }

    /// Applies a complete configuration snapshot with one index rebuild and at
    /// most one stream restart, regardless of the number of folders changed.
    public func syncWithFolders(_ folders: [WatchedFolder]) {
        queue.async { [weak self] in
            guard let self else { return }
            let isInitialSync = !self.hasCompletedInitialSync

            let enabledFolders = Dictionary(
                uniqueKeysWithValues: folders.lazy.filter(\.isEnabled).map { ($0.id, $0) }
            )
            let previousRoots = self.monitoringRoots
            let initialMinimumEventID = self.persistedEventID ?? FSEventsGetCurrentEventId()
            var rootsNeedingRecovery: Set<String> = []

            for folderID in Array(self.watchedFolders.keys) where enabledFolders[folderID] == nil {
                self.uninstall(folderID: folderID)
            }

            for folder in enabledFolders.values {
                if let existing = self.watchedFolders[folder.id],
                   existing.path == folder.path,
                   existing.bookmarkData == folder.bookmarkData {
                    self.watchedFolders[folder.id] = folder
                } else {
                    self.uninstall(folderID: folder.id, removePersistedSnapshot: false)
                    self.install(
                        folder,
                        minimumEventID: self.hasCompletedInitialSync
                            ? FSEventsGetCurrentEventId()
                            : initialMinimumEventID
                    )
                    rootsNeedingRecovery.insert(self.rootPath(for: folder.id, folder: folder))
                }
            }

            self.hasCompletedInitialSync = true
            self.rebuildPathIndex()
            if previousRoots != self.monitoringRoots || self.stream == nil {
                self.rebuildStream()
            }
            if isInitialSync {
                self.scheduleFullReconciliation()
            } else {
                for root in Self.minimalMonitoringRoots(from: Array(rootsNeedingRecovery)) {
                    self.beginScan(at: root, isRecovery: true)
                }
            }
            self.startHealthTimerIfNeeded()
            self.stopHealthTimerIfIdle()
        }
    }

    public func reacquireAccessIfNeeded(for folder: WatchedFolder) -> Bool {
        performOnQueueSyncIfNeeded {
            guard watchedFolders[folder.id] != nil else { return false }
            return resolveBookmark(for: folder) != nil
        }
    }

    public func isFolderHealthy(_ folder: WatchedFolder) -> Bool {
        performOnQueueSyncIfNeeded {
            let path = resolvedURLs[folder.id]?.path ?? folder.path
            return isReadableDirectory(atPath: path)
        }
    }

    // MARK: - Configuration and stream topology

    private func install(
        _ folder: WatchedFolder,
        minimumEventID: FSEventStreamEventId
    ) {
        watchedFolders[folder.id] = folder
        minimumEventIDs[folder.id] = minimumEventID
        _ = resolveBookmark(for: folder)
        restorePersistedSnapshot(for: folder)
    }

    private func uninstall(folderID: UUID, removePersistedSnapshot: Bool = true) {
        watchedFolders.removeValue(forKey: folderID)
        pausedFolders.remove(folderID)
        minimumEventIDs.removeValue(forKey: folderID)
        recentlyRemovedFiles.removeValue(forKey: folderID)
        folderSnapshots.removeValue(forKey: folderID)
        dirtySnapshotFolderIDs.remove(folderID)
        if removePersistedSnapshot, let url = snapshotURL(for: folderID) {
            try? fileManager.removeItem(at: url)
        }
        clearPendingFiles(for: folderID)

        if let url = resolvedURLs.removeValue(forKey: folderID),
           securityScopedFolderIDs.remove(folderID) != nil {
            url.stopAccessingSecurityScopedResource()
        }
    }

    @discardableResult
    private func resolveBookmark(for folder: WatchedFolder) -> URL? {
        guard let bookmarkData = folder.bookmarkData else {
            return nil
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            DebugLogger.log("Failed to resolve bookmark for: \(folder.name)")
            return nil
        }

        if let previousURL = resolvedURLs.removeValue(forKey: folder.id),
           securityScopedFolderIDs.remove(folder.id) != nil {
            previousURL.stopAccessingSecurityScopedResource()
        }

        if !Self.requiresSecurityScopedAccess {
            resolvedURLs[folder.id] = url
        } else if url.startAccessingSecurityScopedResource() {
            resolvedURLs[folder.id] = url
            securityScopedFolderIDs.insert(folder.id)
        } else {
            DebugLogger.log("Lost security-scoped access for: \(folder.name)")
        }

        if isStale,
           let newData = try? url.bookmarkData(
               options: .withSecurityScope,
               includingResourceValuesForKeys: nil,
               relativeTo: nil
           ) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.folderWatcher(
                    self,
                    didDetectStaleBookmarkFor: folder,
                    newBookmarkData: newData
                )
            }
        }

        return url
    }

    private func rebuildPathIndex() {
        var foldersByPath: [String: [UUID]] = [:]
        foldersByPath.reserveCapacity(watchedFolders.count)

        for (folderID, folder) in watchedFolders {
            let path = standardizedPath(resolvedURLs[folderID]?.path ?? folder.path)
            foldersByPath[path, default: []].append(folderID)
        }

        folderIDsByRootPath = foldersByPath
        sortedRootPaths = foldersByPath.keys.sorted()
        monitoringRoots = Self.coalescedMonitoringRoots(from: sortedRootPaths)
    }

    static func minimalMonitoringRoots(from paths: [String]) -> [String] {
        let uniquePaths = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let orderedPaths = uniquePaths.sorted {
            let leftDepth = $0.split(separator: "/").count
            let rightDepth = $1.split(separator: "/").count
            return leftDepth == rightDepth ? $0 < $1 : leftDepth < rightDepth
        }

        var selected: [String] = []
        var selectedSet: Set<String> = []
        selected.reserveCapacity(orderedPaths.count)

        for path in orderedPaths {
            var ancestor = URL(fileURLWithPath: path).deletingLastPathComponent().path
            var isCovered = selectedSet.contains(path)

            while !isCovered, ancestor != "/", !ancestor.isEmpty {
                if selectedSet.contains(ancestor) {
                    isCovered = true
                    break
                }
                let parent = URL(fileURLWithPath: ancestor).deletingLastPathComponent().path
                if parent == ancestor { break }
                ancestor = parent
            }

            if !isCovered, selectedSet.contains("/") {
                isCovered = true
            }

            if !isCovered {
                selected.append(path)
                selectedSet.insert(path)
            }
        }

        return selected.sorted()
    }

    static func coalescedMonitoringRoots(from paths: [String]) -> [String] {
        var rootsByAnchor: [String: [String]] = [:]
        var collapsedAnchors: Set<String> = []

        for rawPath in paths {
            let root = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            let anchor = monitoringAnchor(for: root)
            guard !collapsedAnchors.contains(anchor) else { continue }

            rootsByAnchor[anchor, default: []].append(root)
            if rootsByAnchor[anchor]?.count ?? 0 > maximumExplicitRootsPerAnchor, anchor != "/" {
                rootsByAnchor.removeValue(forKey: anchor)
                collapsedAnchors.insert(anchor)
            }
        }

        var candidates = Array(collapsedAnchors)
        candidates.reserveCapacity(
            collapsedAnchors.count + rootsByAnchor.values.reduce(0) { $0 + $1.count }
        )
        for roots in rootsByAnchor.values {
            candidates.append(contentsOf: roots)
        }
        return minimalMonitoringRoots(from: candidates)
    }

    private static func monitoringAnchor(for path: String) -> String {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.count > 2 else { return path }

        // Keep the anchor at a user, mounted-volume, or top-level data boundary.
        // This bounds the FSEvents path array without broadening a subscription
        // all the way to the startup disk root.
        if components[1] == "Users" || components[1] == "Volumes" {
            guard components.count > 3 else { return path }
            return NSString.path(withComponents: Array(components.prefix(3)))
        }
        return NSString.path(withComponents: Array(components.prefix(2)))
    }

    private func rebuildStream() {
        stopStream()
        guard !monitoringRoots.isEmpty, !isSuspendedForBackpressure else {
            scheduleStreamRecoveryIfNeeded()
            return
        }

        let contextObject = FolderWatcherContext(watcher: self)
        let info = UnsafeMutableRawPointer(Unmanaged.passRetained(contextObject).toOpaque())
        var context = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let sinceWhen: FSEventStreamEventId
        if let replayFromEventID {
            sinceWhen = replayFromEventID
        } else {
            let currentEventID = FSEventsGetCurrentEventId()
            replayFromEventID = currentEventID
            sinceWhen = currentEventID
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagMarkSelf
        )

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            folderWatcherCallback,
            &context,
            monitoringRoots as CFArray,
            sinceWhen,
            Self.streamLatency,
            flags
        ) else {
            Unmanaged<FolderWatcherContext>.fromOpaque(info).release()
            DebugLogger.log("FSEvents: Failed to create shared watched-folder stream")
            scheduleStreamRecoveryIfNeeded()
            return
        }

        FSEventStreamSetDispatchQueue(newStream, queue)
        guard FSEventStreamStart(newStream) else {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            Unmanaged<FolderWatcherContext>.fromOpaque(info).release()
            DebugLogger.log("FSEvents: Failed to start shared watched-folder stream")
            scheduleStreamRecoveryIfNeeded()
            return
        }

        stream = newStream
        callbackContext = info
        scheduleStreamRecoveryIfNeeded()
        DebugLogger.log(
            "FSEvents: Watching \(watchedFolders.count) folders through \(monitoringRoots.count) coalesced roots"
        )
    }

    private func stopStream() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }

        if let callbackContext {
            Unmanaged<FolderWatcherContext>.fromOpaque(callbackContext).release()
            self.callbackContext = nil
        }
    }

    // MARK: - Event routing

    fileprivate func handleEvent(
        path rawPath: String,
        flags: FSEventStreamEventFlags,
        eventID: FSEventStreamEventId
    ) -> Bool {
        guard !isSuspendedForBackpressure else { return false }
        if exclusionMatcher.needsRefresh() {
            exclusionMatcher = exclusionMatcher.refreshed()
        }
        if flags & UInt32(kFSEventStreamEventFlagOwnEvent) != 0 {
            latestProcessedEventID = max(latestProcessedEventID ?? eventID, eventID)
            scheduleCursorPersistence()
            return true
        }

        let path = standardizedPath(rawPath)
        let requiresRecursiveScan =
            flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
        let rootChanged =
            flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0
        let directoryArrived =
            flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 &&
            (
                flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 ||
                flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
            )
        let itemWasRenamed =
            flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
        let eventHistoryIsUnsafe =
            flags & UInt32(kFSEventStreamEventFlagUserDropped) != 0 ||
            flags & UInt32(kFSEventStreamEventFlagKernelDropped) != 0 ||
            flags & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0

        if eventHistoryIsUnsafe {
            scheduleRecoveryScans(affectedBy: path)
        } else if rootChanged {
            let recoveredRoots = reacquireRoots(affectedBy: path)
            for root in recoveredRoots {
                beginScan(at: root)
            }
        } else if itemWasRenamed, !fileManager.fileExists(atPath: path) {
            rememberRemoval(at: path)
        } else if requiresRecursiveScan || directoryArrived {
            let name = URL(fileURLWithPath: path).lastPathComponent
            if let folderID = mostSpecificFolderID(containing: path),
               itemWasRenamed,
               consumeRecentRemoval(named: name, folderID: folderID) {
                // A rename with both endpoints inside the same watched root is
                // a user move, not a new arrival.
            } else {
                scheduleDirectoryScan(at: path)
            }
        } else if flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
            rememberRemoval(at: path)
        } else {
            enqueueFileIfActionable(at: path, flags: flags, eventID: eventID)
        }

        latestProcessedEventID = max(latestProcessedEventID ?? eventID, eventID)
        scheduleCursorPersistence()
        return !isSuspendedForBackpressure
    }

    private func enqueueFileIfActionable(
        at path: String,
        flags: FSEventStreamEventFlags,
        eventID: FSEventStreamEventId
    ) {
        guard let folderID = mostSpecificFolderID(containing: path),
              let folder = watchedFolders[folderID],
              !pausedFolders.contains(folderID),
              eventID >= minimumEventIDs[folderID] ?? 0 else {
            return
        }

        let rootPath = rootPath(for: folderID, folder: folder)
        guard let relativePath = Self.relativePath(of: path, within: rootPath),
              !relativePath.isEmpty,
              !Self.isIgnoredFile(URL(fileURLWithPath: path).lastPathComponent) else {
            return
        }

        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .labelNumberKey,
            .ubiquitousItemDownloadingStatusKey,
        ]),
        values.isRegularFile == true,
        !Self.shouldIgnoreCloudPlaceholder(at: url, resourceValues: values),
        !exclusionMatcher.shouldExcludeFile(
            at: url,
            size: Int64(values.fileSize ?? 0),
            creationDate: values.creationDate,
            modificationDate: values.contentModificationDate,
            finderLabelNumber: values.labelNumber
        ) else {
            return
        }

        if flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0,
           consumeRecentRemoval(named: url.lastPathComponent, folderID: folderID) {
            return
        }

        enqueue(relativePath, for: folderID)
    }

    private func enqueue(_ relativePath: String, for folderID: UUID) {
        guard pendingFileCount < Self.maximumPendingFiles else {
            suspendForBackpressure()
            return
        }

        var files = pendingFiles[folderID] ?? []
        let wasInserted = files.insert(relativePath).inserted
        pendingFiles[folderID] = files
        if wasInserted {
            pendingFileCount += 1
        }

        if files.count >= Self.maximumFilesPerBatch {
            flushPendingFiles(for: folderID)
        } else {
            scheduleFlush(for: folderID)
        }
    }

    private func scheduleFlush(for folderID: UUID) {
        guard let folder = watchedFolders[folderID] else { return }
        debounceWorkItems[folderID]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingFiles(for: folderID)
        }
        debounceWorkItems[folderID] = workItem
        queue.asyncAfter(
            deadline: .now() + max(Self.retryDelay, folder.triggerDelay),
            execute: workItem
        )
    }

    private func flushPendingFiles(for folderID: UUID) {
        removeExcludedPendingFiles(for: folderID)
        guard let folder = watchedFolders[folderID],
              !pausedFolders.contains(folderID),
              let files = pendingFiles[folderID],
              !files.isEmpty else {
            clearPendingFiles(for: folderID)
            return
        }

        let batch = Set(files.prefix(Self.maximumFilesPerBatch))
        let resolvedURL = resolvedURLs[folderID] ?? folder.url
        guard deliveryInFlight.insert(folderID).inserted else { return }
        // Hop to the main actor for the @MainActor delegate instead of
        // assuming isolation: `assumeIsolated` traps on the wrong executor,
        // while this Task resumes on the main actor by construction.
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let delegate = self.delegate else {
                self.completeDelivery(for: folderID, batch: batch, accepted: true)
                return
            }
            delegate.folderWatcher(
                self,
                didDetectChangesIn: folder,
                newFiles: batch,
                resolvedURL: resolvedURL
            ) { [weak self] accepted in
                self?.completeDelivery(for: folderID, batch: batch, accepted: accepted)
            }
        }
    }

    private func completeDelivery(for folderID: UUID, batch: Set<String>, accepted: Bool) {
        queue.async { [weak self] in
            guard let self, self.deliveryInFlight.remove(folderID) != nil else { return }
            guard accepted else {
                self.suspendForBackpressure()
                self.scheduleFlush(for: folderID)
                return
            }

            if var pending = self.pendingFiles[folderID] {
                let removedCount = Self.removeAcceptedBatch(batch, from: &pending)
                self.pendingFileCount -= removedCount
                self.pendingFiles[folderID] = pending
            }
            self.recordAcceptedFiles(batch, for: folderID)
            if self.pendingFiles[folderID]?.isEmpty != false {
                self.pendingFiles.removeValue(forKey: folderID)
                self.debounceWorkItems.removeValue(forKey: folderID)
                self.persistSnapshot(for: folderID)
            } else {
                self.scheduleFlush(for: folderID)
            }
            self.resumeAfterBackpressureIfPossible()
            self.scheduleCursorPersistence()
        }
    }

    private func suspendForBackpressure() {
        guard !isSuspendedForBackpressure else { return }
        isSuspendedForBackpressure = true
        shouldReplayAfterBackpressure = true
        cursorPersistenceWorkItem?.cancel()
        cursorPersistenceWorkItem = nil
        queue.async { [weak self] in
            self?.stopStream()
        }
        DebugLogger.log("FSEvents: Paused shared stream to apply bounded backpressure")
    }

    private func resumeAfterBackpressureIfPossible() {
        guard isSuspendedForBackpressure,
              pendingFileCount == 0,
              activeScanCount == 0 else {
            return
        }

        isSuspendedForBackpressure = false
        if shouldReplayAfterBackpressure {
            shouldReplayAfterBackpressure = false
            rebuildStream()
        }
    }

    private func rememberRemoval(at path: String) {
        guard let folderID = mostSpecificFolderID(containing: path) else { return }
        let name = URL(fileURLWithPath: path).lastPathComponent
        var removals = recentlyRemovedFiles[folderID] ?? [:]
        let cutoff = Date().addingTimeInterval(-3)
        removals = removals.filter { $0.value >= cutoff }
        if removals.count < 128 {
            removals[name] = Date()
        }
        recentlyRemovedFiles[folderID] = removals
    }

    private func consumeRecentRemoval(named name: String, folderID: UUID) -> Bool {
        guard var removals = recentlyRemovedFiles[folderID],
              let removedAt = removals.removeValue(forKey: name),
              Date().timeIntervalSince(removedAt) < 3 else {
            return false
        }
        recentlyRemovedFiles[folderID] = removals
        return true
    }

    // MARK: - Bounded scanning

    private func scheduleDirectoryScan(at path: String) {
        let scanPath: String
        if isReadableDirectory(atPath: path) {
            scanPath = path
        } else if let folderID = mostSpecificFolderID(containing: path),
                  let folder = watchedFolders[folderID] {
            scanPath = rootPath(for: folderID, folder: folder)
        } else {
            return
        }
        let scanURL = URL(fileURLWithPath: scanPath)
        let finderLabelNumber = try? scanURL.resourceValues(
            forKeys: [.labelNumberKey]
        ).labelNumber
        guard !exclusionMatcher.shouldPruneDirectory(
            at: scanURL,
            finderLabelNumber: finderLabelNumber
        ) else {
            return
        }
        beginScan(at: scanPath)
    }

    private func scheduleRecoveryScans(affectedBy path: String) {
        let roots = watchedRootPaths(affectedBy: path)
        for root in roots {
            let rootURL = URL(fileURLWithPath: root)
            let finderLabelNumber = try? rootURL.resourceValues(
                forKeys: [.labelNumberKey]
            ).labelNumber
            if !exclusionMatcher.shouldPruneDirectory(
                at: rootURL,
                finderLabelNumber: finderLabelNumber
            ) {
                beginScan(at: root, isRecovery: true)
            }
        }
    }

    private func reacquireRoots(affectedBy path: String) -> [String] {
        let previousMonitoringRoots = monitoringRoots
        var affectedFolderIDs: [UUID] = []
        for (folderID, folder) in watchedFolders {
            let folderRoot = rootPath(for: folderID, folder: folder)
            guard Self.isPath(path, within: folderRoot) ||
                  Self.isPath(folderRoot, within: path) else {
                continue
            }
            affectedFolderIDs.append(folderID)
            _ = resolveBookmark(for: folder)
        }
        rebuildPathIndex()
        if previousMonitoringRoots != monitoringRoots {
            queue.async { [weak self] in
                self?.rebuildStream()
            }
        }
        let recoveredRoots = affectedFolderIDs.compactMap { folderID -> String? in
            guard let folder = watchedFolders[folderID] else { return nil }
            return rootPath(for: folderID, folder: folder)
        }
        return Self.minimalMonitoringRoots(from: recoveredRoots)
    }

    private func beginScan(at path: String, isRecovery: Bool = false) {
        let path = standardizedPath(path)
        if let activeScanPath, Self.isPath(path, within: activeScanPath) {
            return
        }
        if let coveringPath = pendingScanPaths.first(where: { Self.isPath(path, within: $0) }) {
            if isRecovery { recoveryScanPaths.insert(coveringPath) }
            return
        }

        let removedPaths = pendingScanPaths.filter { Self.isPath($0, within: path) }
        pendingScanPaths.removeAll(where: { Self.isPath($0, within: path) })
        if isRecovery || removedPaths.contains(where: recoveryScanPaths.contains) {
            recoveryScanPaths.insert(path)
        }
        recoveryScanPaths.subtract(removedPaths)
        guard pendingScanPaths.count < Self.maximumPendingScans else {
            pendingScanPaths.removeAll(keepingCapacity: true)
            recoveryScanPaths.removeAll(keepingCapacity: true)
            requiresFullRecoveryScan = true
            return
        }
        pendingScanPaths.append(path)
        startNextScanIfNeeded()
    }

    private func startNextScanIfNeeded() {
        guard activeScanPath == nil else { return }

        if pendingScanPaths.isEmpty, requiresFullRecoveryScan {
            pendingScanPaths = monitoringRoots
            requiresFullRecoveryScan = false
        }
        guard !pendingScanPaths.isEmpty else {
            activeScanCount = 0
            resumeAfterBackpressureIfPossible()
            scheduleCursorPersistence()
            return
        }

        let path = pendingScanPaths.removeFirst()
        let isRecovery = recoveryScanPaths.remove(path) != nil
        let matcher = exclusionMatcher
        activeScanPath = path
        activeScanCount = 1
        scanQueue.async { [weak self] in
            guard let self else { return }
            if isRecovery {
                self.enumerateRecoveryFiles(at: path, exclusionMatcher: matcher)
            } else {
                self.enumerateFiles(at: path, exclusionMatcher: matcher)
            }
            self.queue.async {
                self.activeScanPath = nil
                self.activeScanCount = 0
                self.startNextScanIfNeeded()
            }
        }
    }

    private func enumerateFiles(
        at path: String,
        exclusionMatcher: ExclusionMatcher
    ) {
        let manager = FileManager()
        guard let enumerator = manager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .fileSizeKey,
                .creationDateKey,
                .contentModificationDateKey,
                .labelNumberKey,
                .ubiquitousItemDownloadingStatusKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return
        }

        var absolutePaths: [String] = []
        absolutePaths.reserveCapacity(Self.maximumFilesPerBatch)

        for case let fileURL as URL in enumerator {
            let fileName = fileURL.lastPathComponent
            if Self.isIgnoredFile(fileName) {
                // Ignored names skip the full 7-key resource fetch; a single
                // directory bit is enough to decide whether to prune the subtree.
                if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .fileSizeKey,
                .creationDateKey,
                .contentModificationDateKey,
                .labelNumberKey,
                .ubiquitousItemDownloadingStatusKey,
            ]) else {
                continue
            }

            if values.isDirectory == true {
                if exclusionMatcher.shouldPruneDirectory(
                    at: fileURL,
                    finderLabelNumber: values.labelNumber
                ) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true,
                  !Self.shouldIgnoreCloudPlaceholder(at: fileURL, resourceValues: values),
                  !exclusionMatcher.shouldExcludeFile(
                      at: fileURL,
                      size: Int64(values.fileSize ?? 0),
                      creationDate: values.creationDate,
                      modificationDate: values.contentModificationDate,
                      finderLabelNumber: values.labelNumber
                  ) else {
                continue
            }

            absolutePaths.append(fileURL.standardizedFileURL.path)
            if absolutePaths.count == Self.maximumFilesPerBatch {
                ingestScannedPathsWithBackpressure(absolutePaths)
                absolutePaths.removeAll(keepingCapacity: true)
            }
        }

        if !absolutePaths.isEmpty {
            ingestScannedPathsWithBackpressure(absolutePaths)
        }
    }

    /// Reconciles a complete watched subtree against the last accepted state.
    /// A missing baseline is initialized silently so enabling an existing tree
    /// never presents all of its contents as newly arrived.
    private func enumerateRecoveryFiles(
        at path: String,
        exclusionMatcher: ExclusionMatcher
    ) {
        let targets = performOnQueueSyncIfNeeded {
            watchedFolders.compactMap { folderID, folder -> RecoveryTarget? in
                let root = rootPath(for: folderID, folder: folder)
                guard Self.isPath(root, within: path) || Self.isPath(path, within: root) else {
                    return nil
                }
                return RecoveryTarget(
                    folderID: folderID,
                    rootPath: root,
                    baseline: folderSnapshots[folderID]
                )
            }.sorted { $0.rootPath.count > $1.rootPath.count }
        }
        guard !targets.isEmpty else { return }

        var currentStates = Dictionary(
            uniqueKeysWithValues: targets.map { ($0.folderID, [String: FileFingerprint]()) }
        )
        let manager = FileManager()
        guard let enumerator = manager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .fileSizeKey,
                .creationDateKey,
                .contentModificationDateKey,
                .labelNumberKey,
                .ubiquitousItemDownloadingStatusKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            let fileName = fileURL.lastPathComponent
            if Self.isIgnoredFile(fileName) {
                // Ignored names skip the full 7-key resource fetch; a single
                // directory bit is enough to decide whether to prune the subtree.
                if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .fileSizeKey,
                .creationDateKey,
                .contentModificationDateKey,
                .labelNumberKey,
                .ubiquitousItemDownloadingStatusKey,
            ]) else { continue }

            if values.isDirectory == true {
                if exclusionMatcher.shouldPruneDirectory(
                    at: fileURL,
                    finderLabelNumber: values.labelNumber
                ) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true,
                  !Self.shouldIgnoreCloudPlaceholder(at: fileURL, resourceValues: values),
                  !exclusionMatcher.shouldExcludeFile(
                      at: fileURL,
                      size: Int64(values.fileSize ?? 0),
                      creationDate: values.creationDate,
                      modificationDate: values.contentModificationDate,
                      finderLabelNumber: values.labelNumber
                  ),
                  let target = targets.first(where: {
                      Self.isPath(fileURL.standardizedFileURL.path, within: $0.rootPath)
                  }),
                  let relativePath = Self.relativePath(
                      of: fileURL.standardizedFileURL.path,
                      within: target.rootPath
                  ),
                  !relativePath.isEmpty else {
                continue
            }

            currentStates[target.folderID]?[relativePath] = FileFingerprint(
                size: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate
            )
        }

        var reconciliationChangedSnapshot = false
        for target in targets {
            let current = currentStates[target.folderID] ?? [:]
            let changedPaths: [String]
            if let baseline = target.baseline {
                changedPaths = current.compactMap { relativePath, fingerprint in
                    baseline[relativePath] == fingerprint
                        ? nil
                        : URL(fileURLWithPath: target.rootPath)
                            .appendingPathComponent(relativePath).path
                }
            } else {
                changedPaths = []
            }
            let snapshotChanged = target.baseline != current
            reconciliationChangedSnapshot = reconciliationChangedSnapshot || snapshotChanged

            performOnQueueSyncIfNeeded {
                if snapshotChanged {
                    folderSnapshots[target.folderID] = current
                    dirtySnapshotFolderIDs.insert(target.folderID)
                }
                if changedPaths.isEmpty, snapshotChanged {
                    persistSnapshot(for: target.folderID)
                }
            }
            for batchStart in stride(
                from: 0,
                to: changedPaths.count,
                by: Self.maximumFilesPerBatch
            ) {
                let end = min(batchStart + Self.maximumFilesPerBatch, changedPaths.count)
                ingestScannedPathsWithBackpressure(Array(changedPaths[batchStart..<end]))
            }
        }

        performOnQueueSyncIfNeeded {
            if reconciliationChangedSnapshot {
                currentReconciliationInterval = Self.reconciliationInterval
            } else {
                currentReconciliationInterval = min(
                    currentReconciliationInterval * 2,
                    Self.maximumReconciliationInterval
                )
            }
            scheduleReconciliationDeadline()
        }
    }

    private func ingestScannedPathsWithBackpressure(_ paths: [String], attempt: Int = 0) {
        let didIngest = performOnQueueSyncIfNeeded {
            guard !watchedFolders.isEmpty else { return true }
            guard pendingFileCount + paths.count <= Self.maximumPendingFiles else {
                suspendForBackpressure()
                return false
            }

            for path in paths {
                guard let folderID = mostSpecificFolderID(containing: path),
                      let folder = watchedFolders[folderID],
                      !pausedFolders.contains(folderID),
                      let relativePath = Self.relativePath(
                          of: path,
                          within: rootPath(for: folderID, folder: folder)
                      ),
                      !relativePath.isEmpty else {
                    continue
                }
                enqueue(relativePath, for: folderID)
            }
            return true
        }

        guard !didIngest else { return }
        // Bounded async retry with exponential backoff instead of a
        // Thread.sleep spin on the scan queue: each retry waits longer
        // (0.25s, 0.5s, 1s...) and gives up after ~8 attempts so a stuck
        // consumer cannot pin a thread forever. Dropped batches are picked up
        // by the next reconciliation pass, which rebuilds from snapshots.
        let nextAttempt = attempt + 1
        guard nextAttempt <= 8, !paths.isEmpty else {
            DebugLogger.log("FSEvents: Dropping \(paths.count) scanned paths after sustained backpressure")
            return
        }
        let delay = min(4.0, Self.retryDelay * Double(1 << min(nextAttempt, 4)))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.ingestScannedPathsWithBackpressure(paths, attempt: nextAttempt)
        }
    }

    private func removeExcludedPendingFiles(for requestedFolderID: UUID? = nil) {
        guard !exclusionMatcher.isEmpty else { return }

        let folderIDs = requestedFolderID.map { [$0] } ?? Array(pendingFiles.keys)
        for folderID in folderIDs {
            guard let relativePaths = pendingFiles[folderID] else { continue }
            guard let folder = watchedFolders[folderID] else {
                clearPendingFiles(for: folderID)
                continue
            }

            let rootURL = URL(fileURLWithPath: rootPath(for: folderID, folder: folder))
            let includedPaths = Set(relativePaths.lazy.filter { relativePath in
                let url = rootURL.appendingPathComponent(relativePath)
                guard let values = try? url.resourceValues(forKeys: [
                    .fileSizeKey,
                    .creationDateKey,
                    .contentModificationDateKey,
                    .labelNumberKey,
                ]) else {
                    return true
                }
                return !self.exclusionMatcher.shouldExcludeFile(
                    at: url,
                    size: Int64(values.fileSize ?? 0),
                    creationDate: values.creationDate,
                    modificationDate: values.contentModificationDate,
                    finderLabelNumber: values.labelNumber
                )
            })

            pendingFileCount -= relativePaths.count - includedPaths.count
            if includedPaths.isEmpty {
                pendingFiles.removeValue(forKey: folderID)
                debounceWorkItems[folderID]?.cancel()
                debounceWorkItems.removeValue(forKey: folderID)
            } else {
                pendingFiles[folderID] = includedPaths
            }
        }

        resumeAfterBackpressureIfPossible()
    }

    // MARK: - Path index

    private func mostSpecificFolderID(containing path: String) -> UUID? {
        var candidate = path
        while true {
            if let folderIDs = folderIDsByRootPath[candidate] {
                return folderIDs.first(where: { !pausedFolders.contains($0) })
            }
            guard candidate != "/" else { return nil }
            let parent = URL(fileURLWithPath: candidate).deletingLastPathComponent().path
            guard parent != candidate else { return nil }
            candidate = parent
        }
    }

    private func watchedRootPaths(affectedBy path: String) -> [String] {
        var results: [String] = []

        if let ownerID = mostSpecificFolderID(containing: path),
           let owner = watchedFolders[ownerID] {
            results.append(rootPath(for: ownerID, folder: owner))
        }

        let prefix = path == "/" ? "/" : path + "/"
        var index = sortedRootPaths.firstIndex { $0 >= prefix } ?? sortedRootPaths.count
        while index < sortedRootPaths.count {
            let root = sortedRootPaths[index]
            guard root.hasPrefix(prefix) else { break }
            results.append(root)
            index += 1
        }

        return Self.minimalMonitoringRoots(from: results)
    }

    private func rootPath(for folderID: UUID, folder: WatchedFolder) -> String {
        standardizedPath(resolvedURLs[folderID]?.path ?? folder.path)
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func isPath(_ path: String, within rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }

    private static func relativePath(of path: String, within rootPath: String) -> String? {
        guard isPath(path, within: rootPath) else { return nil }
        guard path != rootPath else { return "" }
        return String(path.dropFirst(rootPath.count + (rootPath == "/" ? 0 : 1)))
    }

    // MARK: - Cursor persistence and health

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                self?.recoverAfterLifecycleChange(affectedPath: "/")
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let mountedPath = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?
                .standardizedFileURL.path
            guard let mountedPath else { return }
            self?.queue.async { [weak self] in
                self?.recoverAfterLifecycleChange(affectedPath: mountedPath)
            }
        })

        applicationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self,
                      Date().timeIntervalSince(self.lastReconciliationAt)
                        >= self.currentReconciliationInterval else {
                    return
                }
                self.scheduleFullReconciliation()
            }
        })
    }

    private func recoverAfterLifecycleChange(affectedPath: String) {
        guard !watchedFolders.isEmpty else { return }
        currentReconciliationInterval = Self.reconciliationInterval
        replayFromEventID = persistedEventID ?? replayFromEventID
        if affectedPath != "/" {
            _ = reacquireRoots(affectedBy: affectedPath)
        }
        if !isSuspendedForBackpressure {
            rebuildStream()
        }
        scheduleRecoveryScans(affectedBy: affectedPath)
        lastReconciliationAt = Date()
        scheduleReconciliationDeadline()
        DebugLogger.log("FSEvents: Replayed cursor and scheduled lifecycle recovery")
    }

    private func scheduleFullReconciliation() {
        guard !watchedFolders.isEmpty else { return }
        // Event-ID short-circuit: with a live stream, no pending scans, and a
        // cursor that has not advanced since the last pass, skip the
        // full-tree rescan. The deadline still backs off exponentially via
        // currentReconciliationInterval.
        if hasCompletedInitialSync,
           stream != nil,
           !requiresFullRecoveryScan,
           pendingScanPaths.isEmpty,
           activeScanPath == nil,
           let lastEventID = latestProcessedEventID,
           eventIDAtLastReconciliation == lastEventID {
            lastReconciliationAt = Date()
            scheduleReconciliationDeadline()
            return
        }
        eventIDAtLastReconciliation = latestProcessedEventID
        scheduleRecoveryScans(affectedBy: "/")
        lastReconciliationAt = Date()
        scheduleReconciliationDeadline()
    }

    private func scheduleCursorPersistence() {
        guard !isSuspendedForBackpressure,
              activeScanCount == 0,
              pendingFileCount == 0,
              let latestProcessedEventID,
              latestProcessedEventID > (persistedEventID ?? 0) else {
            return
        }

        cursorPersistenceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.persistLatestEventCursor()
        }
        cursorPersistenceWorkItem = workItem
        queue.asyncAfter(
            deadline: .now() + Self.eventCursorPersistenceDelay,
            execute: workItem
        )
    }

    private func persistLatestEventCursor() {
        guard !isSuspendedForBackpressure,
              activeScanCount == 0,
              pendingFileCount == 0,
              let eventID = latestProcessedEventID,
              eventID > (persistedEventID ?? 0),
              let watcherStateURL else {
            return
        }

        do {
            try fileManager.createDirectory(
                at: watcherStateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let cursor = PersistedEventCursor(eventID: eventID, updatedAt: Date())
            try JSONEncoder().encode(cursor).write(to: watcherStateURL, options: .atomic)
            persistedEventID = eventID
            replayFromEventID = eventID
        } catch {
            DebugLogger.log("Failed to persist watched-folder event cursor: \(error)")
        }
    }

    private func readPersistedEventCursor() -> PersistedEventCursor? {
        guard let watcherStateURL,
              let data = try? Data(contentsOf: watcherStateURL) else {
            return nil
        }
        return try? JSONDecoder().decode(PersistedEventCursor.self, from: data)
    }

    private func startHealthTimerIfNeeded() {
        guard !watchedFolders.isEmpty else { return }
        scheduleReconciliationDeadline()
        scheduleStreamRecoveryIfNeeded()
    }

    private func scheduleReconciliationDeadline() {
        reconciliationTimer?.cancel()
        reconciliationTimer = nil
        guard !watchedFolders.isEmpty else { return }

        let delay = lastReconciliationAt == .distantPast
            ? currentReconciliationInterval
            : max(
                0,
                currentReconciliationInterval - Date().timeIntervalSince(lastReconciliationAt)
            )
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + delay,
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.reconciliationTimer?.cancel()
            self.reconciliationTimer = nil
            self.scheduleFullReconciliation()
        }
        timer.resume()
        reconciliationTimer = timer
    }

    private func scheduleStreamRecoveryIfNeeded() {
        streamRecoveryTimer?.cancel()
        streamRecoveryTimer = nil
        guard !watchedFolders.isEmpty,
              stream == nil,
              !isSuspendedForBackpressure else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.healthCheckInterval,
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.streamRecoveryTimer?.cancel()
            self.streamRecoveryTimer = nil
            self.rebuildStream()
        }
        timer.resume()
        streamRecoveryTimer = timer
    }

    private func stopHealthTimerIfIdle() {
        guard watchedFolders.isEmpty else { return }
        reconciliationTimer?.cancel()
        reconciliationTimer = nil
        streamRecoveryTimer?.cancel()
        streamRecoveryTimer = nil
    }

    private func recordAcceptedFiles(_ relativePaths: Set<String>, for folderID: UUID) {
        guard let folder = watchedFolders[folderID], folderSnapshots[folderID] != nil else {
            return
        }
        let root = URL(fileURLWithPath: rootPath(for: folderID, folder: folder))
        for relativePath in relativePaths {
            let url = root.appendingPathComponent(relativePath)
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ]), values.isRegularFile == true else {
                folderSnapshots[folderID]?.removeValue(forKey: relativePath)
                continue
            }
            folderSnapshots[folderID]?[relativePath] = FileFingerprint(
                size: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate
            )
        }
        dirtySnapshotFolderIDs.insert(folderID)
    }

    private func restorePersistedSnapshot(for folder: WatchedFolder) {
        guard folderSnapshots[folder.id] == nil,
              let url = snapshotURL(for: folder.id),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(PersistedFolderSnapshot.self, from: data),
              snapshot.rootPath == rootPath(for: folder.id, folder: folder) else {
            return
        }
        folderSnapshots[folder.id] = snapshot.files
    }

    private func persistSnapshot(for folderID: UUID) {
        guard dirtySnapshotFolderIDs.contains(folderID),
              pendingFiles[folderID]?.isEmpty != false,
              !deliveryInFlight.contains(folderID),
              let folder = watchedFolders[folderID],
              let files = folderSnapshots[folderID],
              let url = snapshotURL(for: folderID) else {
            return
        }
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let snapshot = PersistedFolderSnapshot(
                rootPath: rootPath(for: folderID, folder: folder),
                files: files,
                updatedAt: Date()
            )
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            dirtySnapshotFolderIDs.remove(folderID)
        } catch {
            DebugLogger.log("Failed to persist watcher snapshot for \(folder.name): \(error)")
        }
    }

    private func snapshotURL(for folderID: UUID) -> URL? {
        snapshotStoreDirectory?.appendingPathComponent("\(folderID.uuidString).json")
    }

    // MARK: - Helpers

    private func clearPendingFiles(for folderID: UUID) {
        debounceWorkItems[folderID]?.cancel()
        debounceWorkItems.removeValue(forKey: folderID)
        if let files = pendingFiles.removeValue(forKey: folderID) {
            pendingFileCount -= files.count
        }
    }

    static func removeAcceptedBatch(_ batch: Set<String>, from pending: inout Set<String>) -> Int {
        let removedCount = pending.intersection(batch).count
        pending.subtract(batch)
        return removedCount
    }

    private func clearAllPendingFiles() {
        debounceWorkItems.values.forEach { $0.cancel() }
        debounceWorkItems.removeAll()
        pendingFiles.removeAll()
        pendingFileCount = 0
        isSuspendedForBackpressure = false
        shouldReplayAfterBackpressure = false
    }

    private func isReadableDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileManager.isReadableFile(atPath: path)
    }

    private static func isIgnoredFile(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        if ["Thumbs.db", "desktop.ini"].contains(name) { return true }
        if name.hasSuffix("~") { return true }
        return ["tmp", "download", "partial", "crdownload", "part"]
            .contains((name as NSString).pathExtension.lowercased())
    }

    private static var requiresSecurityScopedAccess: Bool {
        SandboxEnvironment.isSandboxed
    }

    static func shouldIgnoreCloudPlaceholder(
        at url: URL,
        resourceValues: URLResourceValues? = nil
    ) -> Bool {
        if resourceValues?.ubiquitousItemDownloadingStatus == .notDownloaded {
            return true
        }

        let fileName = url.lastPathComponent
        let pathExtension = url.pathExtension.lowercased()
        if (fileName.hasPrefix(".") && pathExtension == "icloud") || pathExtension == "cloud" {
            return true
        }

        guard resourceValues?.fileSize == 0 else { return false }
        // getxattr is a syscall per zero-byte file; negative results are
        // cached briefly because re-scans revisit the same files.
        if Self.cachedDropboxNegative(for: url.path) {
            return false
        }
        let hasAttr = getxattr(url.path, "com.dropbox.attrs", nil, 0, 0, 0) > 0
        if !hasAttr {
            Self.cacheDropboxNegative(for: url.path)
        }
        return hasAttr
    }

    private static let dropboxNegativeCacheLock = NSLock()
    nonisolated(unsafe) private static var dropboxNegativeCache: [String: Date] = [:]
    private static let dropboxNegativeCacheTTL: TimeInterval = 60

    private static func cachedDropboxNegative(for path: String) -> Bool {
        dropboxNegativeCacheLock.lock()
        defer { dropboxNegativeCacheLock.unlock() }
        guard let expires = dropboxNegativeCache[path] else { return false }
        if expires < Date() {
            dropboxNegativeCache.removeValue(forKey: path)
            return false
        }
        return true
    }

    private static func cacheDropboxNegative(for path: String) {
        dropboxNegativeCacheLock.lock()
        defer { dropboxNegativeCacheLock.unlock() }
        if dropboxNegativeCache.count > 4_096 {
            let cutoff = Date()
            dropboxNegativeCache = dropboxNegativeCache.filter { $0.value > cutoff }
        }
        dropboxNegativeCache[path] = Date().addingTimeInterval(dropboxNegativeCacheTTL)
    }

    private func performOnQueueSyncIfNeeded<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            return block()
        }
        return queue.sync(execute: block)
    }
}

private final class FolderWatcherContext {
    weak var watcher: FolderWatcher?

    init(watcher: FolderWatcher) {
        self.watcher = watcher
    }
}

private func folderWatcherCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo else { return }
    let context = Unmanaged<FolderWatcherContext>
        .fromOpaque(clientCallBackInfo)
        .takeUnretainedValue()
    guard let watcher = context.watcher else { return }

    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    for index in 0..<numEvents {
        guard let value = CFArrayGetValueAtIndex(paths, index) else { continue }
        let path = Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
        if !watcher.handleEvent(
            path: path,
            flags: eventFlags[index],
            eventID: eventIds[index]
        ) {
            break
        }
    }
}
