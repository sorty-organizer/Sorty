//
//  LearningsFSMonitor.swift
//  Sorty
//
//  FSEvents-based file system monitor for detecting manual file moves
//  after AI organization. Used to learn from user corrections.
//

import Foundation
import Combine
import SortyFileSystem
import SortyModels

/// Snapshot of a directory's contents for detecting moves
public struct FSSnapshot: Sendable {
    let files: Set<String>  // Full paths
    let timestamp: Date
    
    init(at url: URL) {
        var fileSet = Set<String>()
        if !Task.isCancelled, let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let fileURL as URL in enumerator {
                guard !Task.isCancelled else { break }
                if let isFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isFile {
                    fileSet.insert(fileURL.path)
                }
            }
        }
        self.files = fileSet
        self.timestamp = Date()
    }

    init(files: Set<String>, timestamp: Date = Date()) {
        self.files = files
        self.timestamp = timestamp
    }
}

/// Represents a detected file move
public struct DetectedFileMove: Sendable {
    public let fromPath: String
    public let toPath: String
    public let timestamp: Date
}

/// Thread-safe helper class for managing FSEventStream
/// This class is NOT MainActor-isolated and can be safely used from the event queue
private final class FSEventStreamManager: @unchecked Sendable {
    private var eventStream: FSEventStreamRef?
    private let eventQueue: DispatchQueue
    private weak var monitor: LearningsFSMonitor?
    
    init(eventQueue: DispatchQueue) {
        self.eventQueue = eventQueue
    }
    
    func setMonitor(_ monitor: LearningsFSMonitor) {
        self.monitor = monitor
    }
    
    func startStream(paths: [String]) {
        eventQueue.async { [weak self] in
            guard let self = self else { return }
            self.stopStreamSync()
            
            guard !paths.isEmpty else { return }
            
            let pathsToWatch = paths as CFArray
            
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passRetained(self).toOpaque(),
                retain: nil,
                release: { info in
                    guard let info else { return }
                    Unmanaged<FSEventStreamManager>.fromOpaque(info).release()
                },
                copyDescription: nil
            )
            
            let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
                guard let info = info else { return }
                let manager = Unmanaged<FSEventStreamManager>.fromOpaque(info).takeUnretainedValue()
                
                guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
                
                // Copy flags synchronously BEFORE escaping the callback to avoid dangling pointer
                let flagsCopy = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
                
                // Dispatch to main actor
                DispatchQueue.main.async {
                    Task { @MainActor in
                        manager.monitor?.handleFSEvents(paths: paths, flags: flagsCopy)
                    }
                }
            }
            
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                pathsToWatch,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                1.0,  // Latency in seconds
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents |
                    kFSEventStreamCreateFlagUseCFTypes |
                    kFSEventStreamCreateFlagMarkSelf
                )
            )
            
            if let stream = stream {
                self.eventStream = stream
                FSEventStreamSetDispatchQueue(stream, self.eventQueue)
                FSEventStreamStart(stream)
            }
        }
    }
    
    func stopStream() {
        eventQueue.sync { [weak self] in
            self?.stopStreamSync()
        }
    }
    
    private func stopStreamSync() {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
    }
}

/// FSEvents-based monitor for detecting file moves in recently organized directories
@MainActor
public class LearningsFSMonitor: ObservableObject {
    
    // MARK: - Properties
    
    /// Directories being monitored with their snapshots
    private var monitoredDirectories: [URL: FSSnapshot] = [:]
    private var monitoringGenerations: [URL: UUID] = [:]
    
    /// Cleanup timers for auto-removing monitoring after correlation window
    private var cleanupTasks: [URL: Task<Void, Never>] = [:]
    private var initialSnapshotTasks: [URL: Task<Void, Never>] = [:]
    
    /// Stream manager (not MainActor isolated)
    private let streamManager: FSEventStreamManager
    
    /// Paths currently being watched
    private var watchedPaths: [String] = []
    
    /// Callback for detected file moves
    public var onFileMoveDetected: ((DetectedFileMove) -> Void)?
    
    /// Callback for files removed from monitored scope (moved outside or deleted)
    public var onFileRemoved: ((String) -> Void)?

    /// Callback when the correlation window expires for a monitored directory.
    public var onMonitoringWindowExpired: ((URL) -> Void)?
    
    /// Correlation window in seconds (default 30 minutes)
    public var correlationWindowSeconds: TimeInterval = 30 * 60
    
    /// Minimum time between snapshot updates to avoid thrashing
    private let snapshotDebounceInterval: TimeInterval = 2.0
    private var pendingSnapshotUpdates: [URL: Task<Void, Never>] = [:]
    private var pendingSnapshotScopes: [URL: Set<URL>] = [:]
    private var directoriesNeedingFullSnapshot: Set<URL> = []
    /// Event scopes whose pending snapshot update must also report moves and
    /// removals, keyed by monitored directory. Own events refresh the baseline
    /// silently and insert nothing, so a directory-wide flag can no longer make
    /// a replacement update report Sorty's own moves as user corrections.
    private var pendingCorrectionScopes: [URL: Set<URL>] = [:]
    /// Snapshot updates currently running. Later events queue behind an
    /// in-flight update instead of cancelling it, so a corrections pass can
    /// always finish emitting its notifications.
    private var activeSnapshotUpdates: [URL: Task<Void, Never>] = [:]
    
    /// Queue for FSEvents callbacks
    private let eventQueue = DispatchQueue(label: "com.sorty.learnings.fsmonitor", qos: .utility)
    
    // MARK: - Initialization
    
    public init() {
        self.streamManager = FSEventStreamManager(eventQueue: eventQueue)
        self.streamManager.setMonitor(self)
    }
    
    deinit {
        for task in cleanupTasks.values {
            task.cancel()
        }
        for task in pendingSnapshotUpdates.values {
            task.cancel()
        }
        for task in activeSnapshotUpdates.values {
            task.cancel()
        }
        for task in initialSnapshotTasks.values {
            task.cancel()
        }
        streamManager.stopStream()
    }
    
    // MARK: - Public API
    
    /// Start monitoring a directory for file moves
    public func startMonitoring(directory: URL) {
        guard monitoringGenerations[directory] == nil else {
            ModelLog.log("Already monitoring: \(directory.lastPathComponent)", level: .debug, category: "LearningsFSMonitor")
            return
        }
        
        let generation = UUID()
        monitoringGenerations[directory] = generation
        
        // Schedule automatic cleanup after correlation window
        scheduleCleanup(for: directory)
        
        // Restart FSEvents stream with new path
        watchedPaths = monitoringGenerations.keys.map { $0.path }
        streamManager.startStream(paths: watchedPaths)

        initialSnapshotTasks[directory] = Task { [weak self] in
            let scanTask = Task.detached(priority: .utility) { FSSnapshot(at: directory) }
            let snapshot = await withTaskCancellationHandler {
                await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }
            guard !Task.isCancelled,
                  let self,
                  self.monitoringGenerations[directory] == generation else { return }
            self.monitoredDirectories[directory] = snapshot
            self.initialSnapshotTasks[directory] = nil
            if self.pendingSnapshotScopes[directory]?.isEmpty == false {
                // Correction intent is already tracked per event scope; do not
                // widen it to the whole root when rescheduling the full scan.
                self.scheduleSnapshotUpdate(
                    for: directory,
                    scope: directory,
                    requiresFullSnapshot: true,
                    recordsCorrections: false
                )
            }
            ModelLog.log("Started monitoring: \(directory.lastPathComponent) (\(snapshot.files.count) files)", level: .debug, category: "LearningsFSMonitor")
        }
    }
    
    /// Stop monitoring a specific directory
    public func stopMonitoring(directory: URL) {
        guard monitoringGenerations[directory] != nil else { return }
        
        monitoredDirectories.removeValue(forKey: directory)
        monitoringGenerations.removeValue(forKey: directory)
        cleanupTasks[directory]?.cancel()
        cleanupTasks.removeValue(forKey: directory)
        pendingSnapshotUpdates[directory]?.cancel()
        pendingSnapshotUpdates.removeValue(forKey: directory)
        activeSnapshotUpdates[directory]?.cancel()
        activeSnapshotUpdates.removeValue(forKey: directory)
        initialSnapshotTasks[directory]?.cancel()
        initialSnapshotTasks.removeValue(forKey: directory)
        pendingSnapshotScopes.removeValue(forKey: directory)
        directoriesNeedingFullSnapshot.remove(directory)
        pendingCorrectionScopes.removeValue(forKey: directory)
        
        ModelLog.log("Stopped monitoring: \(directory.lastPathComponent)", level: .debug, category: "LearningsFSMonitor")
        
        // Restart FSEvents stream without this path
        if monitoringGenerations.isEmpty {
            streamManager.stopStream()
            watchedPaths = []
        } else {
            watchedPaths = monitoringGenerations.keys.map { $0.path }
            streamManager.startStream(paths: watchedPaths)
        }
    }
    
    /// Stop all monitoring
    public func stopAllMonitoring() {
        streamManager.stopStream()
        watchedPaths = []
        for task in cleanupTasks.values {
            task.cancel()
        }
        for task in pendingSnapshotUpdates.values {
            task.cancel()
        }
        for task in activeSnapshotUpdates.values {
            task.cancel()
        }
        for task in initialSnapshotTasks.values {
            task.cancel()
        }
        monitoredDirectories.removeAll()
        monitoringGenerations.removeAll()
        cleanupTasks.removeAll()
        pendingSnapshotUpdates.removeAll()
        activeSnapshotUpdates.removeAll()
        initialSnapshotTasks.removeAll()
        pendingSnapshotScopes.removeAll()
        directoriesNeedingFullSnapshot.removeAll()
        pendingCorrectionScopes.removeAll()
    }
    
    /// Get list of currently monitored directories
    public var monitoredURLs: [URL] {
        Array(monitoringGenerations.keys)
    }
    
    // MARK: - Event Handling
    
    fileprivate func handleFSEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        // Debounce: schedule snapshot update for affected directories
        for (index, path) in paths.enumerated() {
            let flag = flags.indices.contains(index) ? flags[index] : 0
            // MarkSelf events are Sorty's own filesystem work, not manual
            // corrections. They must still refresh the snapshot, otherwise the
            // next genuine event diffs against a pre-own-move snapshot and
            // reports our own moves as user corrections.
            let isOwnEvent = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagOwnEvent) != 0
            let requiresFullSnapshot = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0
                || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0
                || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
            let isDirectory = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
            let eventURL = URL(fileURLWithPath: path)
            // Nested monitored roots all own this event, so refresh every
            // match instead of stopping at the first one. Only the most
            // specific matching root reports corrections so one move is not
            // delivered once per enclosing root.
            let matchingDirectories = monitoringGenerations.keys.filter {
                StorageLocationPathResolver.isPath(path, within: $0.path)
            }
            let reportingDirectory = matchingDirectories.max { $0.path.count < $1.path.count }
            for dirURL in matchingDirectories {
                scheduleSnapshotUpdate(
                    for: dirURL,
                    scope: isDirectory ? eventURL : eventURL.deletingLastPathComponent(),
                    requiresFullSnapshot: requiresFullSnapshot,
                    recordsCorrections: !isOwnEvent && dirURL == reportingDirectory
                )
            }
        }
    }
    
    private func scheduleSnapshotUpdate(
        for directory: URL,
        scope: URL,
        requiresFullSnapshot: Bool,
        recordsCorrections: Bool = true
    ) {
        pendingSnapshotScopes[directory, default: []].insert(scope)
        if requiresFullSnapshot {
            directoriesNeedingFullSnapshot.insert(directory)
        }
        // Correction intent is tracked per event scope, and only genuine
        // events insert. An own event inside the debounce window therefore
        // cannot make the replacement update report Sorty's own moves.
        if recordsCorrections {
            pendingCorrectionScopes[directory, default: []].insert(scope)
        }
        // Cancel any pending (debounce) update for this directory; an update
        // that already started is left to finish and the replacement queues
        // behind it.
        pendingSnapshotUpdates[directory]?.cancel()
        
        // Schedule new update after debounce interval
        pendingSnapshotUpdates[directory] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(snapshotDebounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Never interrupt an in-flight update: cancelling a corrections
            // pass would drop the moves and removals it was about to report.
            if let active = self.activeSnapshotUpdates[directory] {
                await active.value
            }
            guard !Task.isCancelled else { return }
            guard self.monitoredDirectories[directory] != nil else {
                self.pendingSnapshotUpdates[directory] = nil
                return
            }
            
            let scopes = self.pendingSnapshotScopes.removeValue(forKey: directory) ?? []
            let needsFullSnapshot = self.directoriesNeedingFullSnapshot.remove(directory) != nil
            let consumedScopes = needsFullSnapshot ? [directory] : Array(scopes)
            let correctionScopes = self.consumeCorrectionScopes(
                for: directory,
                consumedScopes: consumedScopes
            )
            
            let update = Task { @MainActor in
                _ = await self.updateSnapshotAndDetectMoves(
                    for: directory,
                    scopes: consumedScopes,
                    correctionScopes: correctionScopes
                )
                self.activeSnapshotUpdates[directory] = nil
            }
            self.activeSnapshotUpdates[directory] = update
            await update.value
        }
    }

    /// Removes and returns the correction intent this update is about to
    /// consume. Intent is matched against the scopes the update refreshes;
    /// intent for other scopes stays queued for the update that consumes them.
    /// Taking it before the scan leaves a genuine event that lands while the
    /// update runs queued for the next pass.
    private func consumeCorrectionScopes(for directory: URL, consumedScopes: [URL]) -> Set<URL> {
        guard let scopes = pendingCorrectionScopes[directory], !scopes.isEmpty else { return [] }

        let consumed = scopes.filter { scope in
            consumedScopes.contains { StorageLocationPathResolver.isPath(scope.path, within: $0.path) }
        }
        guard !consumed.isEmpty else { return [] }

        let remaining = scopes.subtracting(consumed)
        if remaining.isEmpty {
            pendingCorrectionScopes.removeValue(forKey: directory)
        } else {
            pendingCorrectionScopes[directory] = remaining
        }
        return consumed
    }
    
    /// Refreshes the stored snapshot for `directory` and reports the detected
    /// changes whose scope has correction intent. Returns `true` once the
    /// refreshed snapshot was stored, `false` when the update bailed out
    /// before refreshing.
    private func updateSnapshotAndDetectMoves(
        for directory: URL,
        scopes: [URL],
        correctionScopes: Set<URL>
    ) async -> Bool {
        guard let oldSnapshot = monitoredDirectories[directory],
              let generation = monitoringGenerations[directory] else { return false }

        let scanTask = Task.detached(priority: .utility) {
            let effectiveScopes = Self.minimizedScopes(scopes, within: directory)
            var refreshedFiles: Set<String> = []
            for scope in effectiveScopes where !Task.isCancelled {
                refreshedFiles.formUnion(FSSnapshot(at: scope).files)
            }
            let retainedFiles = oldSnapshot.files.filter { path in
                !effectiveScopes.contains { StorageLocationPathResolver.isPath(path, within: $0.path) }
            }
            return FSSnapshot(files: Set(retainedFiles).union(refreshedFiles))
        }
        let newSnapshot = await withTaskCancellationHandler {
            await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }

        guard !Task.isCancelled,
              monitoredDirectories[directory] != nil,
              monitoringGenerations[directory] == generation else { return false }
        
        // Update stored snapshot
        monitoredDirectories[directory] = newSnapshot
        
        // Own moves refresh the baseline silently; reporting them would feed
        // Sorty's own work back in as user corrections.
        guard !correctionScopes.isEmpty else { return true }
        
        // Detect moves by comparing snapshots
        let detection = await Task.detached(priority: .utility) {
            Self.detectFileMoves(from: oldSnapshot, to: newSnapshot)
        }.value

        // Only changes inside a scope with genuine correction intent are
        // reported; moves that happened solely because Sorty itself wrote to
        // the folder stay out of learning.
        func reportsCorrection(_ path: String) -> Bool {
            correctionScopes.contains { StorageLocationPathResolver.isPath(path, within: $0.path) }
        }

        // Notify about detected moves
        for move in detection.moves
        where reportsCorrection(move.fromPath) || reportsCorrection(move.toPath) {
            ModelLog.log("Detected a monitored file move", level: .debug, category: "LearningsFSMonitor")
            onFileMoveDetected?(move)
        }
        
        // Notify about removed files (moved outside monitored scope or deleted)
        for removedPath in detection.removed where reportsCorrection(removedPath) {
            ModelLog.log("Detected a monitored file removal", level: .debug, category: "LearningsFSMonitor")
            onFileRemoved?(removedPath)
        }

        return true
    }
    
    // MARK: - Move Detection
    
    /// Detect file moves by comparing snapshots
    /// Uses filename matching as a heuristic (could be enhanced with file hashes)
    private nonisolated static func detectFileMoves(
        from oldSnapshot: FSSnapshot,
        to newSnapshot: FSSnapshot
    ) -> (moves: [DetectedFileMove], removed: [String]) {
        var moves: [DetectedFileMove] = []
        var matchedRemoved: Set<String> = []
        
        let removedFiles = oldSnapshot.files.subtracting(newSnapshot.files)
        let addedFiles = newSnapshot.files.subtracting(oldSnapshot.files)
        
        var addedByFilename: [String: [String]] = [:]
        for path in addedFiles {
            addedByFilename[URL(fileURLWithPath: path).lastPathComponent, default: []].append(path)
        }

        for removedPath in removedFiles {
            let fileName = URL(fileURLWithPath: removedPath).lastPathComponent
            guard var matches = addedByFilename[fileName], let addedPath = matches.popLast() else { continue }
            addedByFilename[fileName] = matches
            moves.append(DetectedFileMove(fromPath: removedPath, toPath: addedPath, timestamp: Date()))
            matchedRemoved.insert(removedPath)
        }
        
        let unmatchedRemoved = removedFiles.subtracting(matchedRemoved)
        return (moves, Array(unmatchedRemoved))
    }

    private nonisolated static func minimizedScopes(_ scopes: [URL], within root: URL) -> [URL] {
        let eligible = scopes.filter { StorageLocationPathResolver.isPath($0.path, within: root.path) }
            .sorted { $0.path.count < $1.path.count }
        var result: [URL] = []
        for scope in eligible where !result.contains(where: { StorageLocationPathResolver.isPath(scope.path, within: $0.path) }) {
            result.append(scope)
        }
        return result.isEmpty ? [root] : result
    }
    
    // MARK: - Cleanup
    
    private func scheduleCleanup(for directory: URL) {
        cleanupTasks[directory]?.cancel()
        
        cleanupTasks[directory] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(correlationWindowSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            
            ModelLog.log("Correlation window expired for: \(directory.lastPathComponent)", level: .debug, category: "LearningsFSMonitor")
            self.onMonitoringWindowExpired?(directory)
            self.stopMonitoring(directory: directory)
        }
    }
}
