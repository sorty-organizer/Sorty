//
//  AppCoordinator.swift
//  Sorty
//
//  Coordinates background tasks and watched folder automation
//

@preconcurrency import Foundation
import SwiftUI
import Combine
import UserNotifications
import os
#if canImport(SortyLib)
import SortyLib
#endif

private enum CoordinatorLog {
    static func log(_ message: @autoclosure () -> String) {
        #if canImport(SortyLib)
        LogManager.shared.log(message(), level: .debug, category: "AppCoordinator")
        #else
        Logger(subsystem: "com.sorty.app", category: "AppCoordinator").debug("\(message())")
        #endif
    }
}

@MainActor
class AppCoordinator: ObservableObject, FolderWatcherDelegate {
    enum PendingReviewPresentationResult {
        case presented
        case activatedExisting
        case unavailable
    }

    private final class PendingReviewClaim {
        let sessionID: UUID
        weak var organizer: FolderOrganizer?

        init(sessionID: UUID, organizer: FolderOrganizer) {
            self.sessionID = sessionID
            self.organizer = organizer
        }
    }

    private struct PendingWatchBatch {
        var folder: WatchedFolder
        var files: Set<String>
        var resolvedURL: URL
        var stabilityRetryAttempt: Int
        var operationRetryAttempt: Int
        var nextAttemptAt: Date
    }

    private struct PersistedPendingWatchBatch: Codable, Sendable {
        var folderID: UUID
        var files: Set<String>
        var stabilityRetryAttempt: Int
        var operationRetryAttempt: Int
        var nextAttemptAt: Date
    }

    private struct PersistedPendingWatchReview: Codable, Sendable {
        var folderID: UUID
        var plan: OrganizationPlan
        var fileCount: Int
        var mode: OrganizationMode?
    }

    private struct PersistedOutstandingWatchWork: Codable, Sendable {
        var batches: [PersistedPendingWatchBatch]
        var reviews: [PersistedPendingWatchReview]
    }

    private struct PendingWatchReview {
        var folder: WatchedFolder
        var plan: OrganizationPlan
        var fileCount: Int
        var mode: OrganizationMode
    }

    private actor PendingWorkPersistence {
        private var latestRevision = 0
        private var pendingBatches: [PersistedPendingWatchBatch] = []
        private var pendingReviews: [PersistedPendingWatchReview] = []
        private var pendingURL: URL?
        private var flushTask: Task<Void, Never>?

        func schedule(
            batches: [PersistedPendingWatchBatch],
            reviews: [PersistedPendingWatchReview],
            url: URL,
            revision: Int,
            immediately: Bool = false
        ) -> Bool {
            guard revision >= latestRevision else { return true }
            latestRevision = revision
            pendingBatches = batches
            pendingReviews = reviews
            pendingURL = url
            flushTask?.cancel()
            if immediately {
                return flush()
            }
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                await self?.flush()
            }
            return true
        }

        @discardableResult
        private func flush() -> Bool {
            guard let pendingURL else { return false }
            let batches = pendingBatches
            let reviews = pendingReviews
            flushTask = nil

            do {
                if batches.isEmpty && reviews.isEmpty {
                    if FileManager.default.fileExists(atPath: pendingURL.path) {
                        try FileManager.default.removeItem(at: pendingURL)
                    }
                    return true
                }

                try FileManager.default.createDirectory(
                    at: pendingURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(
                    PersistedOutstandingWatchWork(batches: batches, reviews: reviews)
                )
                try data.write(to: pendingURL, options: .atomic)
                return true
            } catch {
                CoordinatorLog.log("Coordinator: Failed to persist watched-folder pending work: \(error)")
                return false
            }
        }
    }

    let folderWatcher = FolderWatcher()
    let organizer: FolderOrganizer
    let watchedFoldersManager: WatchedFoldersManager
    let learningsManager: LearningsManager
    let continuousLearningObserver: ContinuousLearningObserver
    let learningsFSMonitor: LearningsFSMonitor
    private let notificationManager = NotificationManager.shared
    private var watchedFoldersSubscription: AnyCancellable?
    private var organizerConfigurationSubscription: AnyCancellable?
    private var exclusionMatcherSubscription: AnyCancellable?
    private var pendingFiles: [UUID: PendingWatchBatch] = [:]
    private var activeWatchBatches: [UUID: PendingWatchBatch] = [:]
    private var snoozedFolderIDs: Set<UUID> = []
    private var pendingWatchReviews: [UUID: PendingWatchReview] = [:]
    private var pendingReviewClaims: [UUID: PendingReviewClaim] = [:]
    private var ignoredWatchEventsUntil: [UUID: Date] = [:]
    private var manualOrganizationFolders: [UUID: WatchedFolder] = [:]
    private var autoOrganizeTasks: [UUID: Task<Void, Never>] = [:]
    private var autoOrganizeTaskIDs: [UUID: UUID] = [:]
    private var retryTask: Task<Void, Never>?
    private let pendingWorkPersistence = PendingWorkPersistence()
    private var pendingWorkPersistenceRevision = 0
    /// Gates retry/resume/reconcile until the detached restore finishes, so
    /// pre-restore empty state never clobbers persisted batches.
    private var hasRestoredPendingWork = false
    private let candidateStabilityDelay: TimeInterval = 1.5
    private let retryBaseDelay: TimeInterval = 3
    private let maximumStabilityRetryDelay: TimeInterval = 60
    private let maximumOperationRetryCount = 2
    private let maximumPendingFilesPerFolder = 512
    private let maximumPendingFolderCount = 32
    private lazy var pendingWorkURL: URL? = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sorty", isDirectory: true)
            .appendingPathComponent("WatcherPendingWork.json")
    }()
    nonisolated(unsafe) private var notificationObservers: [NSObjectProtocol] = []
    
    init(
        organizer: FolderOrganizer,
        watchedFoldersManager: WatchedFoldersManager,
        learningsManager: LearningsManager,
        exclusionRules: ExclusionRulesManager
    ) {
        self.organizer = organizer
        self.watchedFoldersManager = watchedFoldersManager
        self.learningsManager = learningsManager
        self.continuousLearningObserver = ContinuousLearningObserver(
            learningsManager: learningsManager,
            history: organizer.history
        )
        self.learningsFSMonitor = LearningsFSMonitor()
        self.folderWatcher.delegate = self
        
        // Inject observer into organizer
        organizer.learningsObserver = self.continuousLearningObserver

        self.folderWatcher.updateExclusionMatcher(exclusionRules.matcherSnapshot())
        self.exclusionMatcherSubscription = exclusionRules.$compiledMatcher
            .dropFirst()
            .sink { [weak self] matcher in
                self?.folderWatcher.updateExclusionMatcher(matcher)
            }

        // Initial sync
        self.folderWatcher.syncWithFolders(watchedFoldersManager.folders)
        self.snoozedFolderIDs = Set(watchedFoldersManager.folders.filter(\.isSnoozed).map(\.id))
        self.watchedFoldersSubscription = watchedFoldersManager.$monitoringRevision
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                let folders = self.watchedFoldersManager.folders
                self.folderWatcher.syncWithFolders(folders)
                self.reconcilePendingWork(with: folders)
            }
        restorePendingWatchWork()
        self.organizerConfigurationSubscription = organizer.$isAIConfigured
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.resumePendingWorkAfterConfiguration()
            }
        if organizer.aiClient != nil {
            resumePendingWorkAfterConfiguration()
        }
        
        setupNotifications()
        requestNotificationPermission()
        
        // Start observing
        self.continuousLearningObserver.startObserving()
        
        // Wire up FSMonitor to ContinuousLearningObserver
        self.learningsFSMonitor.onFileMoveDetected = { [weak self] move in
            Task { @MainActor in
                self?.continuousLearningObserver.handleFileMove(from: move.fromPath, to: move.toPath)
            }
        }
        
        self.learningsFSMonitor.onFileRemoved = { [weak self] path in
            Task { @MainActor in
                self?.continuousLearningObserver.handleFileRemoval(at: path)
            }
        }

        self.learningsFSMonitor.onMonitoringWindowExpired = { [weak self] directoryURL in
            Task { @MainActor in
                self?.continuousLearningObserver.handleMonitoringWindowExpired(for: directoryURL.path)
            }
        }
        
    }
    
    deinit {
        retryTask?.cancel()
        autoOrganizeTasks.values.forEach { $0.cancel() }
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
    }
    
    private func setupNotifications() {
        // macOS can terminate Sorty to apply a Full Disk Access change before
        // the debounced persistence actor flushes. Write synchronously here so
        // pending watched-folder work survives that restart.
        notificationObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.flushPendingWorkSynchronously()
            }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(forName: .organizationDidRevert, object: nil, queue: .main) { [weak self] notification in
            guard let self = self,
                  let url = notification.userInfo?["url"] as? URL else { return }
            
            Task {
                guard let folder = await self.watchedFoldersManager.folder(matchingPath: url.path) else {
                    return
                }
                
                // Just reverted, so we must update snapshot to avoid re-triggering
                CoordinatorLog.log("Coordinator: Revert detected for \(folder.name), updating snapshot to ignore reverted files")

                self.folderWatcher.refreshSnapshot(for: folder)
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(forName: .autoOrganizeDisabledGlobally, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let reason = notification.userInfo?["reason"] as? String ?? "Unknown reason"
            
            Task { @MainActor in
                self.notificationManager.showError(message: "Auto-organization paused: \(reason)", isCritical: true)
            }
        })
        
        // Listen for organization completion
        notificationObservers.append(NotificationCenter.default.addObserver(forName: .organizationDidFinish, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            guard let entry = notification.userInfo?["entry"] as? OrganizationHistoryEntry else { return }
            
            Task { @MainActor in
                var completedReviewFolderID: UUID?
                if let completedPlanID = entry.plan?.id,
                   let reviewedFolderID = self.pendingWatchReviews.first(where: {
                       $0.value.plan.id == completedPlanID
                   })?.key {
                    completedReviewFolderID = reviewedFolderID
                    self.pendingWatchReviews.removeValue(forKey: reviewedFolderID)
                    self.pendingReviewClaims.removeValue(forKey: reviewedFolderID)
                    if !(await self.persistOutstandingWatchWorkImmediately()) {
                        self.persistOutstandingWatchWork()
                    }
                    self.scheduleRetry()
                }

                // If the user manually organized a watched folder, treat that run as
                // the new baseline and ignore the immediate filesystem event burst.
                if entry.source == .manual {
                    let completedPath = URL(fileURLWithPath: entry.directoryPath).standardizedFileURL.path
                    if let watchedFolder = self.watchedFoldersManager.folder(matchingPath: completedPath) {
                        if watchedFolder.id != completedReviewFolderID {
                            self.pendingFiles.removeValue(forKey: watchedFolder.id)
                            self.persistOutstandingWatchWork()
                        }
                        self.ignoredWatchEventsUntil[watchedFolder.id] = Date().addingTimeInterval(2.0)
                        self.folderWatcher.refreshSnapshot(for: watchedFolder)
                    }
                }

                if entry.source != .watchedFolder {
                    let stats = self.extractBatchStats(from: entry)
                    self.notificationManager.showBatchSummary(stats: stats)
                }
                
                // Start FSMonitor for learning from user corrections
                let folderURL = URL(fileURLWithPath: entry.directoryPath)
                self.learningsFSMonitor.startMonitoring(directory: folderURL)
            }
        })
        
        // Handle "Undo" action from notification
        notificationObservers.append(NotificationCenter.default.addObserver(forName: .undoLastOrganization, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let folderPath = notification.userInfo?["folderPath"] as? String
            
            Task { @MainActor in
                await self.handleUndoAction(folderPath: folderPath)
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(forName: .requestUndoOrganizationConfirmation, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let folderPath = notification.userInfo?["folderPath"] as? String

            Task { @MainActor in
                await self.handleUndoConfirmationRequest(folderPath: folderPath)
            }
        })
        
        // Handle "Open Folder" action from notification
        notificationObservers.append(NotificationCenter.default.addObserver(forName: .openOrganizedFolder, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let folderPath = notification.userInfo?["folderPath"] as? String
            
            Task { @MainActor in
                self.handleOpenFolderAction(folderPath: folderPath)
            }
        })
        
        // Handle "Retry" action from notification
        notificationObservers.append(NotificationCenter.default.addObserver(forName: .retryLastOrganization, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let folderPath = notification.userInfo?["folderPath"] as? String
            
            Task { @MainActor in
                await self.handleRetryAction(folderPath: folderPath)
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(forName: .retryWatchedFolderBatch, object: nil, queue: .main) { [weak self] notification in
            guard let self, let folderID = notification.object as? UUID else { return }
            Task { @MainActor in
                self.retryPendingWatchBatch(folderID: folderID)
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(forName: .discardWatchedFolderBatch, object: nil, queue: .main) { [weak self] notification in
            guard let self, let folderID = notification.object as? UUID else { return }
            Task { @MainActor in
                self.discardPendingWatchBatch(folderID: folderID)
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(forName: .discardWatchedFolderReview, object: nil, queue: .main) { [weak self] notification in
            guard let self, let folderID = notification.object as? UUID else { return }
            Task { @MainActor in
                await self.discardPendingWatchReview(folderID: folderID)
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(forName: .requestRetryOrganizationConfirmation, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let folderPath = notification.userInfo?["folderPath"] as? String

            Task { @MainActor in
                await self.handleRetryConfirmationRequest(folderPath: folderPath)
            }
        })
        
        // Handle "Show Details" action from notification
        notificationObservers.append(NotificationCenter.default.addObserver(forName: .showOrganizationDetails, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            
            Task { @MainActor in
                self.handleShowDetailsAction()
            }
        })

        // Handle "Review/Preview" action from notification
        notificationObservers.append(NotificationCenter.default.addObserver(forName: .showOrganizationPreview, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                self.handleShowDetailsAction()
            }
        })
    }
    
    // MARK: - Notification Action Handlers
    
    /// Handle undo action from notification
    private func handleUndoAction(folderPath: String?) async {
        notificationManager.recordActionLifecycle("undo", stage: "executing", detail: folderPath ?? "latest")
        
        // Find the entry to undo
        guard let entryToUndo = findEntryToUndo(folderPath: folderPath) else {
            CoordinatorLog.log("Coordinator: No entry found to undo")
            notificationManager.recordActionLifecycle("undo", stage: "no-op", failed: true, detail: folderPath ?? "latest")
            notificationManager.showError(message: "Nothing to undo", isCritical: false)
            return
        }
        
        guard !entryToUndo.isUndone else {
            CoordinatorLog.log("Coordinator: Entry already undone")
            notificationManager.recordActionLifecycle("undo", stage: "already-undone", failed: true, detail: entryToUndo.directoryPath)
            notificationManager.showError(message: "Already undone", isCritical: false)
            return
        }
        
        CoordinatorLog.log("Coordinator: Undoing organization for \(entryToUndo.directoryPath)")
        
        do {
            let result = try await organizer.undoHistoryEntry(entryToUndo)
            
            // Only surface the skipped count when files were actually skipped;
            // "0 skipped" reads as noise.
            let message: String
            if result.hasIssues, !result.missingFiles.isEmpty {
                message = "Undo complete (\(result.successfulOperations) restored, \(result.missingFiles.count) couldn't be found)"
            } else if result.hasIssues {
                message = "Undo complete (\(result.successfulOperations) restored; some items need another attempt)"
            } else {
                message = "Undo complete - \(result.successfulOperations) files restored"
            }
            
            notificationManager.showInfo(
                title: "Undo Successful",
                message: message
            )
            notificationManager.recordActionLifecycle("undo", stage: "completed", detail: entryToUndo.directoryPath)
            
        } catch {
            CoordinatorLog.log("Coordinator: Undo failed: \(error)")
            notificationManager.recordActionLifecycle("undo", stage: "failed", failed: true, detail: error.localizedDescription)
            notificationManager.showError(message: "Undo failed: \(error.localizedDescription)", isCritical: false)
        }
    }
    
    /// Find the most recent entry to undo, optionally filtered by folder path
    private func findEntryToUndo(folderPath: String?) -> OrganizationHistoryEntry? {
        let entries = organizer.history.entries
        
        if let path = folderPath {
            // Find the most recent non-undone entry for this specific folder
            return entries.first { $0.directoryPath == path && !$0.isUndone && $0.success }
        } else {
            // Find the most recent non-undone entry
            return entries.first { !$0.isUndone && $0.success }
        }
    }
    
    /// Handle open folder action from notification
    private func handleOpenFolderAction(folderPath: String?) {
        // Get folder path from parameter or last history entry
        let path: String?
        if let fp = folderPath {
            path = fp
        } else if let lastEntry = organizer.history.entries.first {
            path = lastEntry.directoryPath
        } else {
            path = nil
        }
        
        guard let path = path else {
            CoordinatorLog.log("Coordinator: No folder path to open")
            return
        }
        
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
        CoordinatorLog.log("Coordinator: Opened folder \(path)")
    }
    
    /// Handle retry action from notification
    private func handleRetryAction(folderPath: String?) async {
        notificationManager.recordActionLifecycle("retry", stage: "executing", detail: folderPath ?? "latestFailed")
        // Get folder path from parameter or last failed entry
        let path: String?
        if let fp = folderPath {
            path = fp
        } else if let lastFailedEntry = organizer.history.entries.first(where: { $0.status == .failed }) {
            path = lastFailedEntry.directoryPath
        } else {
            path = nil
        }
        
        guard let path = path else {
            CoordinatorLog.log("Coordinator: No folder path to retry")
            notificationManager.recordActionLifecycle("retry", stage: "no-op", failed: true, detail: "missing folder path")
            notificationManager.showError(message: "No failed operation to retry", isCritical: false)
            return
        }


        if let watchedFolder = watchedFoldersManager.folder(matchingPath: path),
           pendingFiles[watchedFolder.id] != nil {
            retryPendingWatchBatch(folderID: watchedFolder.id)
            notificationManager.recordActionLifecycle("retry", stage: "queued", detail: path)
            return
        }
        
        // Check if we're already busy
        guard organizer.state == .idle else {
            CoordinatorLog.log("Coordinator: Cannot retry - organizer is busy")
            notificationManager.recordActionLifecycle("retry", stage: "busy", failed: true, detail: path)
            notificationManager.showError(message: "Organizer is busy, try again later", isCritical: false)
            return
        }
        
        CoordinatorLog.log("Coordinator: Retrying organization for \(path)")
        
        do {
            let url = URL(fileURLWithPath: path)
            try await organizer.organize(directory: url, customPrompt: nil, temperature: nil)
            try await organizer.apply(at: url, dryRun: false)
            
            notificationManager.showInfo(
                title: "Retry Successful",
                message: "Organization completed for \(url.lastPathComponent)"
            )
            notificationManager.recordActionLifecycle("retry", stage: "completed", detail: path)
            
        } catch {
            CoordinatorLog.log("Coordinator: Retry failed: \(error)")
            notificationManager.recordActionLifecycle("retry", stage: "failed", failed: true, detail: error.localizedDescription)
            notificationManager.showError(message: "Retry failed: \(error.localizedDescription)", isCritical: false)
        }
    }

    private func handleUndoConfirmationRequest(folderPath: String?) async {
        let targetName = notificationFolderName(for: folderPath) ?? "your last organization"
        notificationManager.recordActionLifecycle("undo", stage: "confirmation_shown", detail: targetName)

        let confirmed = presentNotificationConfirmation(
            title: "Undo Organization?",
            message: "Restore the previous organization for \(targetName)?",
            confirmButtonTitle: "Undo"
        )

        if confirmed {
            notificationManager.recordActionLifecycle("undo", stage: "confirmed", detail: targetName)
            await handleUndoAction(folderPath: folderPath)
        } else {
            notificationManager.recordActionLifecycle("undo", stage: "cancelled", detail: targetName)
        }
    }

    private func handleRetryConfirmationRequest(folderPath: String?) async {
        let targetName = notificationFolderName(for: folderPath) ?? "the failed organization"
        notificationManager.recordActionLifecycle("retry", stage: "confirmation_shown", detail: targetName)

        let confirmed = presentNotificationConfirmation(
            title: "Retry Organization?",
            message: "Run Sorty again for \(targetName)?",
            confirmButtonTitle: "Retry"
        )

        if confirmed {
            notificationManager.recordActionLifecycle("retry", stage: "confirmed", detail: targetName)
            await handleRetryAction(folderPath: folderPath)
        } else {
            notificationManager.recordActionLifecycle("retry", stage: "cancelled", detail: targetName)
        }
    }

    private func presentNotificationConfirmation(
        title: String,
        message: String,
        confirmButtonTitle: String
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmButtonTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func notificationFolderName(for folderPath: String?) -> String? {
        guard let folderPath, !folderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: folderPath).lastPathComponent
    }
    
    /// Handle show details action from notifications by activating the app.
    /// The originating notification already carries navigation intent.
    private func handleShowDetailsAction() {
        // Activate the app and bring it to front
        NSApplication.shared.activate(ignoringOtherApps: true)

        CoordinatorLog.log("Coordinator: Activated app for details view")
    }
    
    /// Extract detailed batch statistics from an organization history entry
    private func extractBatchStats(
        from entry: OrganizationHistoryEntry,
        duration: TimeInterval = 0
    ) -> BatchSummaryStats {
        let folderName = URL(fileURLWithPath: entry.directoryPath).lastPathComponent
        let folderPath = entry.directoryPath
        
        // Count operations by type
        var filesMoved = 0
        var filesRenamed = 0
        var filesTagged = 0
        var foldersCreated = 0
        
        if let operations = entry.operations {
            for op in operations {
                switch op.type {
                case .moveFile:
                    filesMoved += 1
                    if op.metadata?.newFilename != nil {
                        filesRenamed += 1
                    }
                case .renameFile:
                    filesRenamed += 1
                case .tagFile:
                    filesTagged += 1
                case .createFolder:
                    foldersCreated += 1
                case .deleteFile, .copyFile:
                    break
                }
            }
        } else {
            // Fallback to entry-level stats if operations not available
            filesMoved = entry.filesOrganized
            foldersCreated = entry.foldersCreated
        }
        
        // Determine errors
        let errors = entry.status == .failed ? 1 : 0
        
        // Check if undo is possible (has operations to undo)
        let canUndo = (entry.operations?.isEmpty == false)
        
        return BatchSummaryStats(
            filesMoved: filesMoved,
            foldersCreated: foldersCreated,
            filesRenamed: filesRenamed,
            filesTagged: filesTagged,
            duplicatesFound: entry.duplicatesDeleted ?? 0,
            errorsEncountered: errors,
            duration: duration,
            folderName: folderName,
            folderPath: folderPath,
            canUndo: canUndo
        )
    }
    
    private func requestNotificationPermission() {
        // Notification authorization is requested lazily when sending native notifications.
    }
    
    func folderWatcher(_ watcher: FolderWatcher, didDetectStaleBookmarkFor folder: WatchedFolder, newBookmarkData: Data) {
        guard var updatedFolder = watchedFoldersManager.folder(withID: folder.id) else {
            return
        }
        updatedFolder.bookmarkData = newBookmarkData
        // Also ensure status is valid
        updatedFolder.accessStatus = .valid
        watchedFoldersManager.updateFolder(updatedFolder)
        CoordinatorLog.log("Coordinator: Updated stale bookmark for \(folder.name)")
    }
    
    func folderWatcher(
        _ watcher: FolderWatcher,
        didDetectChangesIn folder: WatchedFolder,
        newFiles: Set<String>,
        resolvedURL: URL,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        // FolderWatcher already resolves nested roots with its path index. Doing
        // that work again here used to scan every watched folder for every file,
        // which made event routing quadratic as either dimension grew.
        let routedFiles = newFiles
        guard !routedFiles.isEmpty else {
            completion(true)
            return
        }

        if let snoozedUntil = folder.snoozedUntil, snoozedUntil > Date() {
            mergePendingFiles(folder: folder, files: routedFiles, resolvedURL: resolvedURL)
            deferPendingWork(for: folder.id, until: snoozedUntil)
            scheduleRetry()
            completion(true)
            return
        }

        guard !isManualOrganizationActive(for: folder.id) else {
            CoordinatorLog.log("Coordinator: Ignoring watcher changes for \(folder.name) during manual organization")
            completion(true)
            return
        }

        if let ignoreUntil = ignoredWatchEventsUntil[folder.id] {
            if ignoreUntil > Date() {
                CoordinatorLog.log("Coordinator: Ignoring watcher burst for \(folder.name) after manual apply")
                completion(true)
                return
            }
            ignoredWatchEventsUntil.removeValue(forKey: folder.id)
        }
        
        if isOrganizerBusyForAutomation() || pendingWatchReviews[folder.id] != nil {
            let existingFileCount = pendingFiles[folder.id]?.files.count ?? 0
            let isNewPendingFolder = pendingFiles[folder.id] == nil
            guard existingFileCount + routedFiles.count <= maximumPendingFilesPerFolder,
                  !isNewPendingFolder || pendingFiles.count < maximumPendingFolderCount else {
                completion(false)
                return
            }

            CoordinatorLog.log("Coordinator: Organizer unavailable, queueing \(routedFiles.count) files for \(folder.name)")
            mergePendingFiles(folder: folder, files: routedFiles, resolvedURL: resolvedURL)
            scheduleRetry()
            completion(true)
            return
        }
        
        startAutoOrganize(folder: folder, files: routedFiles, resolvedURL: resolvedURL)
        completion(true)
    }

    @discardableResult
    private func startAutoOrganize(
        folder: WatchedFolder,
        files: Set<String>,
        resolvedURL: URL,
        stabilityRetryAttempt: Int = 0,
        operationRetryAttempt: Int = 0
    ) -> Task<Void, Never> {
        if pendingWatchReviews[folder.id] != nil {
            mergePendingFiles(
                folder: folder,
                files: files,
                resolvedURL: resolvedURL,
                stabilityRetryAttempt: stabilityRetryAttempt,
                operationRetryAttempt: operationRetryAttempt
            )
            scheduleRetry()
            return Task {}
        }

        if let existingTask = autoOrganizeTasks[folder.id] {
            mergePendingFiles(folder: folder, files: files, resolvedURL: resolvedURL)
            return existingTask
        }

        let taskID = UUID()
        autoOrganizeTaskIDs[folder.id] = taskID
        activeWatchBatches[folder.id] = PendingWatchBatch(
            folder: folder,
            files: files,
            resolvedURL: resolvedURL,
            stabilityRetryAttempt: stabilityRetryAttempt,
            operationRetryAttempt: operationRetryAttempt,
            nextAttemptAt: Date()
        )
        persistOutstandingWatchWork()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.autoOrganize(
                folder: folder,
                files: files,
                resolvedURL: resolvedURL,
                stabilityRetryAttempt: stabilityRetryAttempt,
                operationRetryAttempt: operationRetryAttempt
            )
            if self.autoOrganizeTaskIDs[folder.id] == taskID {
                self.autoOrganizeTasks.removeValue(forKey: folder.id)
                self.autoOrganizeTaskIDs.removeValue(forKey: folder.id)
                self.activeWatchBatches.removeValue(forKey: folder.id)
                self.persistOutstandingWatchWork()
            }
            if !Task.isCancelled, !self.isOrganizerBusyForAutomation(), !self.pendingFiles.isEmpty {
                self.processPendingFiles()
            }
        }
        autoOrganizeTasks[folder.id] = task
        return task
    }
    
    private func autoOrganize(
        folder: WatchedFolder,
        files: Set<String>,
        resolvedURL: URL,
        stabilityRetryAttempt: Int,
        operationRetryAttempt: Int
    ) async {
        guard !isManualOrganizationActive(for: folder.id),
              let currentFolder = watchedFoldersManager.folder(withID: folder.id),
              currentFolder.isEnabled else { return }

        guard organizer.aiClient != nil else {
            CoordinatorLog.log("Coordinator: Cannot auto-organize \(folder.name) - provider not configured")
            mergePendingFiles(
                folder: currentFolder,
                files: files,
                resolvedURL: resolvedURL,
                stabilityRetryAttempt: stabilityRetryAttempt,
                operationRetryAttempt: operationRetryAttempt,
                nextAttemptAt: .distantFuture
            )
            notificationManager.showError(message: "Could not auto-organize \"\(folder.name)\" - no provider configured", isCritical: false)
            return
        }

        let candidateAudit = await Self.auditStableCandidates(
            files: files,
            rootURL: resolvedURL,
            stabilityDelay: candidateStabilityDelay
        )

        guard !Task.isCancelled,
              !isManualOrganizationActive(for: folder.id),
              let executionFolder = watchedFoldersManager.folder(withID: folder.id),
              executionFolder.isEnabled else { return }

        if !candidateAudit.unsettled.isEmpty {
            CoordinatorLog.log("Coordinator: Deferring \(candidateAudit.unsettled.count) unsettled files for \(folder.name)")
            let nextRetryAttempt = stabilityRetryAttempt + 1
            mergePendingFiles(
                folder: executionFolder,
                files: candidateAudit.unsettled,
                resolvedURL: resolvedURL,
                stabilityRetryAttempt: nextRetryAttempt,
                operationRetryAttempt: operationRetryAttempt,
                nextAttemptAt: Date().addingTimeInterval(stabilityRetryDelay(for: nextRetryAttempt))
            )
            scheduleRetry()
        }

        guard !candidateAudit.stable.isEmpty else {
            if !candidateAudit.gone.isEmpty {
                CoordinatorLog.log("Coordinator: Dropping \(candidateAudit.gone.count) vanished files for \(folder.name)")
            }
            return
        }

        guard !isOrganizerStateBusy else {
            mergePendingFiles(
                folder: executionFolder,
                files: candidateAudit.stable,
                resolvedURL: resolvedURL,
                stabilityRetryAttempt: stabilityRetryAttempt,
                operationRetryAttempt: operationRetryAttempt,
                nextAttemptAt: Date().addingTimeInterval(retryBaseDelay)
            )
            scheduleRetry()
            return
        }
        
        let startTime = Date()
        let previousNewestHistoryEntryID = organizer.history.entries.first?.id
        
        do {
            watchedFoldersManager.markTriggered(executionFolder)
            refreshActivity(for: executionFolder.id, runningFileCount: candidateAudit.stable.count)
            notificationManager.showWatchedFolderStarted(
                fileCount: candidateAudit.stable.count,
                folderName: executionFolder.name,
                folderPath: resolvedURL.path
            )
            
            CoordinatorLog.log("Coordinator: Auto-organizing \(candidateAudit.stable.count) stable new files in \(folder.name): \(candidateAudit.stable)")
            
            try await organizer.organizeIncremental(
                directory: resolvedURL,
                specificFiles: Array(candidateAudit.stable),
                customPrompt: executionFolder.customPrompt,
                temperature: executionFolder.temperature,
                providerOverride: executionFolder.providerOverride,
                modelOverride: executionFolder.modelOverride,
                mode: executionFolder.effectiveOrganizationMode,
                historySource: .watchedFolder,
                autoApply: executionFolder.effectiveApplyPolicy == .autoApply
            )

            guard !Task.isCancelled, !isManualOrganizationActive(for: folder.id) else {
                organizer.state = .idle
                return
            }

            if executionFolder.effectiveApplyPolicy == .notifyAndReview,
               let plan = organizer.currentPlan {
                pendingWatchReviews[executionFolder.id] = PendingWatchReview(
                    folder: executionFolder,
                    plan: plan,
                    fileCount: candidateAudit.stable.count,
                    mode: executionFolder.effectiveOrganizationMode
                )
                if await persistOutstandingWatchWorkImmediately() {
                    notificationManager.show(
                        .previewReady(
                            folderName: executionFolder.name,
                            folderPath: resolvedURL.path,
                            planID: plan.id,
                            isWatchedReview: true
                        )
                    )
                } else {
                    notificationManager.showError(
                        message: "A review plan is ready for \"\(executionFolder.name)\", but Sorty couldn't save it. Keep Sorty open and review the plan from Watched Folders.",
                        folderPath: resolvedURL.path,
                        isCritical: false
                    )
                }
                organizer.reset()
            } else {
                organizer.state = .idle
            }
            folderWatcher.refreshSnapshot(for: executionFolder)
            
            let duration = Date().timeIntervalSince(startTime)
            CoordinatorLog.log("Coordinator: Auto-organize completed for \(folder.name) in \(String(format: "%.1f", duration))s")
            let newHistoryEntries = organizer.history.entries.prefix { entry in
                previousNewestHistoryEntryID.map { entry.id != $0 } ?? true
            }
            if executionFolder.effectiveApplyPolicy == .autoApply,
               let historyEntry = newHistoryEntries.first(where: {
                $0.source == .watchedFolder
            }) {
                let stats = extractBatchStats(from: historyEntry, duration: duration)
                notificationManager.showBatchSummary(stats: stats, isAutomated: true)
            }
            
        } catch is CancellationError {
            organizer.state = .idle
        } catch {
            CoordinatorLog.log("Coordinator: Auto-organize failed for \(folder.name): \(error)")
            organizer.state = .idle
            folderWatcher.refreshSnapshot(for: executionFolder)

            if operationRetryAttempt < maximumOperationRetryCount {
                let nextRetryAttempt = operationRetryAttempt + 1
                mergePendingFiles(
                    folder: executionFolder,
                    files: candidateAudit.stable,
                    resolvedURL: resolvedURL,
                    stabilityRetryAttempt: stabilityRetryAttempt,
                    operationRetryAttempt: nextRetryAttempt,
                    nextAttemptAt: Date().addingTimeInterval(stabilityRetryDelay(for: nextRetryAttempt))
                )
                scheduleRetry()
            } else {
                mergePendingFiles(
                    folder: executionFolder,
                    files: candidateAudit.stable,
                    resolvedURL: resolvedURL,
                    stabilityRetryAttempt: stabilityRetryAttempt,
                    operationRetryAttempt: operationRetryAttempt,
                    nextAttemptAt: .distantFuture
                )
                notificationManager.showError(
                    message: "Failed to organize \"\(folder.name)\" after retrying: \(error.localizedDescription)",
                    folderPath: resolvedURL.path,
                    isCritical: false,
                    canRetry: true,
                    isAutomated: true
                )
            }
        }
        refreshActivity(for: folder.id)
    }

    private func mergePendingFiles(
        folder: WatchedFolder,
        files: Set<String>,
        resolvedURL: URL,
        stabilityRetryAttempt: Int = 0,
        operationRetryAttempt: Int = 0,
        nextAttemptAt: Date = Date()
    ) {
        guard !files.isEmpty else { return }

        if var existing = pendingFiles[folder.id] {
            existing.files.formUnion(files)
            existing.folder = folder
            existing.resolvedURL = resolvedURL
            existing.stabilityRetryAttempt = min(existing.stabilityRetryAttempt, stabilityRetryAttempt)
            existing.operationRetryAttempt = min(existing.operationRetryAttempt, operationRetryAttempt)
            existing.nextAttemptAt = min(existing.nextAttemptAt, nextAttemptAt)
            pendingFiles[folder.id] = existing
        } else {
            pendingFiles[folder.id] = PendingWatchBatch(
                folder: folder,
                files: files,
                resolvedURL: resolvedURL,
                stabilityRetryAttempt: stabilityRetryAttempt,
                operationRetryAttempt: operationRetryAttempt,
                nextAttemptAt: nextAttemptAt
            )
        }
        persistOutstandingWatchWork()
    }

    private func retryPendingWatchBatch(folderID: UUID) {
        guard var pending = pendingFiles[folderID] else { return }
        pending.nextAttemptAt = Date()
        pending.operationRetryAttempt = 0
        pendingFiles[folderID] = pending
        persistOutstandingWatchWork()
        scheduleRetry()
    }

    private func discardPendingWatchBatch(folderID: UUID) {
        pendingFiles.removeValue(forKey: folderID)
        persistOutstandingWatchWork()
    }

    private func discardPendingWatchReview(folderID: UUID) async {
        guard let review = pendingWatchReviews.removeValue(forKey: folderID) else { return }
        let claim = pendingReviewClaims.removeValue(forKey: folderID)
        guard await persistOutstandingWatchWorkImmediately() else {
            pendingWatchReviews[folderID] = review
            pendingReviewClaims[folderID] = claim
            notificationManager.showError(
                message: "Sorty couldn't discard the saved plan. It remains ready for review.",
                isCritical: false
            )
            return
        }
        scheduleRetry()
    }

    func presentPendingReview(
        folderPath: String?,
        planID: UUID?,
        sessionID: UUID,
        in targetOrganizer: FolderOrganizer
    ) -> PendingReviewPresentationResult {
        guard let folderPath,
              let folder = watchedFoldersManager.folder(matchingPath: folderPath),
              let review = pendingWatchReviews[folder.id] else { return .unavailable }
        if let planID, review.plan.id != planID {
            return .unavailable
        }
        if let claim = pendingReviewClaims[folder.id] {
            let isStillPresented: Bool
            if claim.organizer?.currentPlan?.id == review.plan.id {
                switch claim.organizer?.state {
                case .ready, .applying:
                    isStillPresented = true
                default:
                    isStillPresented = false
                }
            } else {
                isStillPresented = false
            }
            if isStillPresented {
                _ = MainWindowRouter.shared.activateWindow(for: claim.sessionID)
                return .activatedExisting
            }
            pendingReviewClaims.removeValue(forKey: folder.id)
        }
        targetOrganizer.loadPreparedIncrementalPlan(
            review.plan,
            directory: folder.url,
            mode: review.mode
        )
        pendingReviewClaims[folder.id] = PendingReviewClaim(
            sessionID: sessionID,
            organizer: targetOrganizer
        )
        refreshActivity(for: folder.id)
        return .presented
    }

    private var isOrganizerStateBusy: Bool {
        switch organizer.state {
        case .scanning, .organizing, .applying:
            return true
        case .idle, .ready, .completed, .error:
            return false
        }
    }

    private func stabilityRetryDelay(for retryAttempt: Int) -> TimeInterval {
        min(retryBaseDelay * pow(2, Double(max(retryAttempt - 1, 0))), maximumStabilityRetryDelay)
    }

    private func reconcilePendingWork(with folders: [WatchedFolder]) {
        let currentlySnoozedFolderIDs = Set(folders.filter(\.isSnoozed).map(\.id))
        // Gate on restore so pre-restore reconciliation never drops
        // persisted batches that have not been published yet.
        guard hasRestoredPendingWork else {
            snoozedFolderIDs = currentlySnoozedFolderIDs
            return
        }
        let configuredFolders = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let enabledFolders = configuredFolders.filter { $0.value.isEnabled }
        var changed = false

        for folderID in Array(pendingFiles.keys) where enabledFolders[folderID] == nil {
            pendingFiles.removeValue(forKey: folderID)
            changed = true
        }

        for folderID in Array(pendingWatchReviews.keys) where configuredFolders[folderID] == nil {
            pendingWatchReviews.removeValue(forKey: folderID)
            pendingReviewClaims.removeValue(forKey: folderID)
            changed = true
        }

        for (folderID, task) in Array(autoOrganizeTasks) where enabledFolders[folderID] == nil {
            task.cancel()
            autoOrganizeTasks.removeValue(forKey: folderID)
            autoOrganizeTaskIDs.removeValue(forKey: folderID)
            activeWatchBatches.removeValue(forKey: folderID)
            organizer.cancel(source: .watchedFolder)
            changed = true
        }

        for (folderID, folder) in configuredFolders {
            if var pending = pendingFiles[folderID] {
                pending.folder = folder
                pending.resolvedURL = folder.url
                if let snoozedUntil = folder.snoozedUntil, snoozedUntil > Date() {
                    pending.nextAttemptAt = max(pending.nextAttemptAt, snoozedUntil)
                } else if snoozedFolderIDs.contains(folderID) {
                    pending.nextAttemptAt = Date()
                }
                pendingFiles[folderID] = pending
                changed = true
            }
            if var review = pendingWatchReviews[folderID] {
                review.folder = folder
                pendingWatchReviews[folderID] = review
            }
        }

        if changed {
            persistOutstandingWatchWork()
        }
        snoozedFolderIDs = currentlySnoozedFolderIDs
        scheduleRetry()
    }

    private func resumePendingWorkAfterConfiguration() {
        guard hasRestoredPendingWork else { return }
        folderWatcher.reconcileNow()
        let now = Date()
        for folderID in Array(pendingFiles.keys) {
            pendingFiles[folderID]?.nextAttemptAt = now
            pendingFiles[folderID]?.operationRetryAttempt = 0
        }
        persistOutstandingWatchWork()
        scheduleRetry()
    }

    private func restorePendingWatchWork() {
        guard let url = pendingWorkURL else {
            hasRestoredPendingWork = true
            return
        }
        Task { @MainActor [weak self] in
            // Decode off the main actor; `OrganizationPlan` payloads can be large.
            let persistedWork: PersistedOutstandingWatchWork? = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url) else { return nil }
                let decoder = JSONDecoder()
                if let decoded = try? decoder.decode(PersistedOutstandingWatchWork.self, from: data) {
                    return decoded
                }
                if let legacyBatches = try? decoder.decode([PersistedPendingWatchBatch].self, from: data) {
                    return PersistedOutstandingWatchWork(batches: legacyBatches, reviews: [])
                }
                return nil
            }.value
            guard let self else { return }
            if let persistedWork {
                self.applyRestoredWatchWork(persistedWork)
            }
            self.hasRestoredPendingWork = true
            if self.organizer.aiClient != nil {
                self.resumePendingWorkAfterConfiguration()
            }
            self.scheduleRetry()
        }
    }

    @MainActor
    private func applyRestoredWatchWork(_ persistedWork: PersistedOutstandingWatchWork) {
        let configuredFolders = Dictionary(
            uniqueKeysWithValues: watchedFoldersManager.folders.map { ($0.id, $0) }
        )
        let enabledFolders = configuredFolders.filter { $0.value.isEnabled }
        for batch in persistedWork.batches {
            guard let currentFolder = enabledFolders[batch.folderID] else { continue }
            let restored = PendingWatchBatch(
                folder: currentFolder,
                files: batch.files,
                resolvedURL: currentFolder.url,
                stabilityRetryAttempt: batch.stabilityRetryAttempt,
                operationRetryAttempt: 0,
                nextAttemptAt: Date()
            )
            if var existing = pendingFiles[currentFolder.id] {
                existing.files.formUnion(restored.files)
                existing.stabilityRetryAttempt = min(existing.stabilityRetryAttempt, restored.stabilityRetryAttempt)
                existing.operationRetryAttempt = min(existing.operationRetryAttempt, restored.operationRetryAttempt)
                existing.nextAttemptAt = min(existing.nextAttemptAt, restored.nextAttemptAt)
                pendingFiles[currentFolder.id] = existing
            } else {
                pendingFiles[currentFolder.id] = restored
            }
        }
        for review in persistedWork.reviews {
            guard let currentFolder = configuredFolders[review.folderID] else { continue }
            pendingWatchReviews[currentFolder.id] = PendingWatchReview(
                folder: currentFolder,
                plan: review.plan,
                fileCount: review.fileCount,
                mode: review.mode ?? currentFolder.effectiveOrganizationMode
            )
        }
        persistOutstandingWatchWork()
    }

    private func persistOutstandingWatchWork() {
        refreshAllActivity()
        guard let pendingWorkURL else { return }

        let (persisted, persistedReviews) = outstandingWatchWorkSnapshot()
        pendingWorkPersistenceRevision &+= 1
        let revision = pendingWorkPersistenceRevision
        Task { [pendingWorkPersistence] in
            await pendingWorkPersistence.schedule(
                batches: persisted,
                reviews: persistedReviews,
                url: pendingWorkURL,
                revision: revision
            )
        }
    }

    private func persistOutstandingWatchWorkImmediately() async -> Bool {
        refreshAllActivity()
        guard let pendingWorkURL else { return false }

        let (persisted, persistedReviews) = outstandingWatchWorkSnapshot()
        pendingWorkPersistenceRevision &+= 1
        let revision = pendingWorkPersistenceRevision
        return await pendingWorkPersistence.schedule(
            batches: persisted,
            reviews: persistedReviews,
            url: pendingWorkURL,
            revision: revision,
            immediately: true
        )
    }

    /// Synchronous termination-path write. The debounced actor cannot be
    /// awaited from `willTerminate`, so this writes the same snapshot
    /// directly to cover a restart forced by a Full Disk Access change.
    private func flushPendingWorkSynchronously() {
        refreshAllActivity()
        guard let pendingWorkURL else { return }
        let (persisted, persistedReviews) = outstandingWatchWorkSnapshot()
        do {
            if persisted.isEmpty && persistedReviews.isEmpty {
                if FileManager.default.fileExists(atPath: pendingWorkURL.path) {
                    try FileManager.default.removeItem(at: pendingWorkURL)
                }
                return
            }
            try FileManager.default.createDirectory(
                at: pendingWorkURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(
                PersistedOutstandingWatchWork(batches: persisted, reviews: persistedReviews)
            )
            try data.write(to: pendingWorkURL, options: .atomic)
        } catch {
            CoordinatorLog.log("Coordinator: Failed to flush watched-folder pending work: \(error)")
        }
    }

    private func outstandingWatchWorkSnapshot() -> (
        batches: [PersistedPendingWatchBatch],
        reviews: [PersistedPendingWatchReview]
    ) {
        var outstanding = pendingFiles
        for (folderID, active) in activeWatchBatches {
            if var existing = outstanding[folderID] {
                existing.files.formUnion(active.files)
                existing.stabilityRetryAttempt = min(existing.stabilityRetryAttempt, active.stabilityRetryAttempt)
                existing.operationRetryAttempt = min(existing.operationRetryAttempt, active.operationRetryAttempt)
                existing.nextAttemptAt = min(existing.nextAttemptAt, active.nextAttemptAt)
                outstanding[folderID] = existing
            } else {
                outstanding[folderID] = active
            }
        }

        let persisted = outstanding.map { folderID, batch in
            PersistedPendingWatchBatch(
                folderID: folderID,
                files: batch.files,
                stabilityRetryAttempt: batch.stabilityRetryAttempt,
                operationRetryAttempt: batch.operationRetryAttempt,
                nextAttemptAt: batch.nextAttemptAt
            )
        }
        let persistedReviews = pendingWatchReviews.map { folderID, review in
            PersistedPendingWatchReview(
                folderID: folderID,
                plan: review.plan,
                fileCount: review.fileCount,
                mode: review.mode
            )
        }
        return (persisted, persistedReviews)
    }

    private struct CandidateAudit: Sendable {
        var stable: Set<String>
        var unsettled: Set<String>
        var gone: Set<String>
    }

    private struct CandidateSnapshot: Equatable, Sendable {
        var exists: Bool
        var isDirectory: Bool
        var fileCount: Int
        var byteSize: Int64
        var latestModification: Date?
        var rootModification: Date?
        var isTruncated: Bool

        static let missing = CandidateSnapshot(
            exists: false,
            isDirectory: false,
            fileCount: 0,
            byteSize: 0,
            latestModification: nil,
            rootModification: nil,
            isTruncated: false
        )
    }

    private nonisolated static func auditStableCandidates(
        files: Set<String>,
        rootURL: URL,
        stabilityDelay: TimeInterval
    ) async -> CandidateAudit {
        let firstSnapshot = await snapshotCandidates(files: files, rootURL: rootURL)
        let delayNanoseconds = UInt64(stabilityDelay * 1_000_000_000)
        do {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        } catch {
            return CandidateAudit(stable: [], unsettled: files, gone: [])
        }
        let secondSnapshot = await snapshotCandidates(files: files, rootURL: rootURL)

        var stable = Set<String>()
        var unsettled = Set<String>()
        var gone = Set<String>()

        for file in files {
            let first = firstSnapshot[file] ?? CandidateSnapshot.missing
            let second = secondSnapshot[file] ?? CandidateSnapshot.missing

            if second.exists, first == second {
                stable.insert(file)
            } else if !first.exists && !second.exists {
                gone.insert(file)
            } else {
                unsettled.insert(file)
            }
        }

        return CandidateAudit(stable: stable, unsettled: unsettled, gone: gone)
    }

    private nonisolated static func snapshotCandidates(
        files: Set<String>,
        rootURL: URL
    ) async -> [String: CandidateSnapshot] {
        await Task.detached(priority: .utility) {
            var snapshots: [String: CandidateSnapshot] = [:]
            snapshots.reserveCapacity(files.count)

            for file in files {
                let url = rootURL.appendingPathComponent(file)
                guard url.standardizedFileURL.path.hasPrefix(rootURL.standardizedFileURL.path + "/") else {
                    snapshots[file] = .missing
                    continue
                }

                snapshots[file] = snapshotCandidate(at: url)
            }

            return snapshots
        }.value
    }

    private nonisolated static func snapshotCandidate(at url: URL) -> CandidateSnapshot {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }

        let rootValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard isDirectory.boolValue else {
            return CandidateSnapshot(
                exists: true,
                isDirectory: false,
                fileCount: 1,
                byteSize: Int64(rootValues?.fileSize ?? 0),
                latestModification: rootValues?.contentModificationDate,
                rootModification: rootValues?.contentModificationDate,
                isTruncated: false
            )
        }

        let maxEntriesToAudit = 5_000
        var fileCount = 0
        var byteSize: Int64 = 0
        var latestModification = rootValues?.contentModificationDate
        var isTruncated = false

        if let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let childURL as URL in enumerator {
                guard fileCount < maxEntriesToAudit else {
                    isTruncated = true
                    break
                }

                guard let values = try? childURL.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
                ), values.isRegularFile == true else {
                    continue
                }

                fileCount += 1
                byteSize += Int64(values.fileSize ?? 0)
                if let modificationDate = values.contentModificationDate,
                   latestModification.map({ modificationDate > $0 }) ?? true {
                    latestModification = modificationDate
                }
            }
        }

        return CandidateSnapshot(
            exists: true,
            isDirectory: true,
            fileCount: fileCount,
            byteSize: byteSize,
            latestModification: latestModification,
            rootModification: rootValues?.contentModificationDate,
            isTruncated: isTruncated
        )
    }
    
    private func processPendingFiles() {
        guard organizer.aiClient != nil, !isOrganizerBusyForAutomation() else {
            scheduleRetry()
            return
        }

        let now = Date()
        guard let (folderID, pending) = pendingFiles
            .filter({ $0.value.nextAttemptAt <= now && pendingWatchReviews[$0.key] == nil })
            .min(by: { $0.value.nextAttemptAt < $1.value.nextAttemptAt }) else {
            scheduleRetry()
            return
        }

        pendingFiles.removeValue(forKey: folderID)
        guard !isManualOrganizationActive(for: folderID),
              let currentFolder = watchedFoldersManager.folder(withID: folderID),
              currentFolder.isEnabled else {
            persistOutstandingWatchWork()
            scheduleRetry()
            return
        }

        if let snoozedUntil = currentFolder.snoozedUntil, snoozedUntil > now {
            pendingFiles[folderID] = pending
            deferPendingWork(for: folderID, until: snoozedUntil)
            scheduleRetry()
            return
        }

        startAutoOrganize(
            folder: currentFolder,
            files: pending.files,
            resolvedURL: currentFolder.url,
            stabilityRetryAttempt: pending.stabilityRetryAttempt,
            operationRetryAttempt: pending.operationRetryAttempt
        )
    }
    
    private func scheduleRetry() {
        guard hasRestoredPendingWork else { return }
        retryTask?.cancel()
        retryTask = nil
        guard organizer.aiClient != nil,
              let earliestAttempt = pendingFiles
                .filter({ pendingWatchReviews[$0.key] == nil })
                .map(\.value.nextAttemptAt)
                .min(),
              earliestAttempt != .distantFuture else { return }

        let stateDelay = isOrganizerBusyForAutomation() ? retryBaseDelay : 0
        let delay = max(max(earliestAttempt.timeIntervalSinceNow, stateDelay), 0.05)
        let delayNanoseconds = UInt64(delay * 1_000_000_000)
        retryTask = Task {
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            processPendingFiles()
        }
    }

    private func deferPendingWork(for folderID: UUID, until date: Date) {
        guard var pending = pendingFiles[folderID] else { return }
        pending.nextAttemptAt = max(pending.nextAttemptAt, date)
        pendingFiles[folderID] = pending
        persistOutstandingWatchWork()
    }

    private func refreshAllActivity() {
        let folderIDs = Set(watchedFoldersManager.folders.map(\.id))
            .union(pendingFiles.keys)
            .union(activeWatchBatches.keys)
        for folderID in folderIDs {
            refreshActivity(for: folderID)
        }
    }

    private func refreshActivity(for folderID: UUID, runningFileCount: Int? = nil) {
        if let runningFileCount {
            watchedFoldersManager.setActivity(.running(fileCount: runningFileCount), for: folderID)
            return
        }

        if let review = pendingWatchReviews[folderID] {
            watchedFoldersManager.setActivity(
                .awaitingReview(fileCount: review.fileCount),
                for: folderID
            )
            return
        }

        if let active = activeWatchBatches[folderID] {
            watchedFoldersManager.setActivity(
                .waitingForStability(fileCount: active.files.count, nextAttemptAt: Date()),
                for: folderID
            )
            return
        }

        guard let pending = pendingFiles[folderID] else {
            watchedFoldersManager.setActivity(nil, for: folderID)
            return
        }

        let activity: WatchedFolderActivity
        if pending.nextAttemptAt == .distantFuture {
            activity = .parked(fileCount: pending.files.count)
        } else if pending.operationRetryAttempt > 0 {
            activity = .retrying(
                fileCount: pending.files.count,
                attempt: pending.operationRetryAttempt,
                nextAttemptAt: pending.nextAttemptAt
            )
        } else if pending.stabilityRetryAttempt > 0 {
            activity = .waitingForStability(
                fileCount: pending.files.count,
                nextAttemptAt: pending.nextAttemptAt
            )
        } else {
            activity = .queued(fileCount: pending.files.count, nextAttemptAt: pending.nextAttemptAt)
        }
        watchedFoldersManager.setActivity(activity, for: folderID)
    }

    private func isOrganizerBusyForAutomation() -> Bool {
        if !autoOrganizeTasks.isEmpty {
            return true
        }

        switch organizer.state {
        case .scanning, .organizing, .applying:
            return true
        case .idle, .ready, .completed, .error:
            return false
        }
    }

    func beginManualOrganization(in directory: URL, sessionID: UUID) async {
        guard let folder = watchedFolder(matching: directory), folder.isEnabled else {
            finishManualOrganization(sessionID: sessionID)
            return
        }

        if let existing = manualOrganizationFolders[sessionID], existing.id != folder.id {
            finishManualOrganization(sessionID: sessionID)
        }

        manualOrganizationFolders[sessionID] = folder
        pendingFiles.removeValue(forKey: folder.id)
        activeWatchBatches.removeValue(forKey: folder.id)
        persistOutstandingWatchWork()
        ignoredWatchEventsUntil.removeValue(forKey: folder.id)
        folderWatcher.pause(folder)

        guard let automaticTask = autoOrganizeTasks[folder.id] else { return }

        CoordinatorLog.log("Coordinator: Prioritizing manual organization for \(folder.name)")
        automaticTask.cancel()
        organizer.cancel(source: .watchedFolder)
        await automaticTask.value
    }

    func finishManualOrganization(sessionID: UUID) {
        guard let folder = manualOrganizationFolders.removeValue(forKey: sessionID) else { return }
        guard !isManualOrganizationActive(for: folder.id) else { return }

        pendingFiles.removeValue(forKey: folder.id)
        persistOutstandingWatchWork()
        ignoredWatchEventsUntil[folder.id] = Date().addingTimeInterval(2.0)
        if let currentFolder = watchedFoldersManager.folder(withID: folder.id),
           currentFolder.isEnabled {
            folderWatcher.resume(currentFolder)
            CoordinatorLog.log("Coordinator: Resumed watching \(currentFolder.name) after manual organization")
        }
    }

    private func isManualOrganizationActive(for folderID: UUID) -> Bool {
        manualOrganizationFolders.values.contains { $0.id == folderID }
    }

    private func watchedFolder(matching directory: URL) -> WatchedFolder? {
        let directoryPath = canonicalPath(directory)
        return watchedFoldersManager.folders.first {
            canonicalPath($0.url) == directoryPath
        }
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
    
    func calibrateFolder(_ folder: WatchedFolder) {
        Task {
            defer {
                folderWatcher.refreshSnapshot(for: folder)
            }
            do {
                try await organizer.organize(directory: folder.url, customPrompt: folder.customPrompt, temperature: folder.temperature)
                try await organizer.apply(at: folder.url, dryRun: false)
            } catch {
                // Ignore calibrate failures; caller surface is non-blocking.
            }
        }
    }
    
}
