import Foundation
import WidgetKit
#if canImport(SortyLib)
import SortyLib
#endif

private struct WidgetSnapshotSyncResult: Sendable {
    let didChange: Bool
    let errorDescription: String?
}

private actor WidgetSnapshotSyncWorker {
    func sync(
        watchedFolders: [WatchedFolder],
        storageLocations: [StorageLocation],
        activeWatchedFolderCount: Int
    ) -> WidgetSnapshotSyncResult {
        guard !Task.isCancelled else {
            return WidgetSnapshotSyncResult(didChange: false, errorDescription: nil)
        }

        let snapshot = SortyWidgetSnapshotStore.makeSnapshot(
            entries: OrganizationHistory.loadPersistedEntries(),
            watchedFolders: watchedFolders,
            storageLocations: storageLocations,
            activeWatchedFolderCount: activeWatchedFolderCount
        )
        let persistedSnapshot = SortyWidgetSnapshotStore.load()
        guard !snapshot.hasSameWidgetContent(as: persistedSnapshot) else {
            return WidgetSnapshotSyncResult(didChange: false, errorDescription: nil)
        }

        do {
            try SortyWidgetSnapshotStore.save(snapshot)
            return WidgetSnapshotSyncResult(didChange: true, errorDescription: nil)
        } catch {
            return WidgetSnapshotSyncResult(
                didChange: false,
                errorDescription: error.localizedDescription
            )
        }
    }
}

@MainActor
final class SortyWidgetSyncManager {
    static let shared = SortyWidgetSyncManager()

    private let syncWorker = WidgetSnapshotSyncWorker()
    private var observers: [NSObjectProtocol] = []
    private var scheduledSyncTask: Task<Void, Never>?
    private var initialSyncTask: Task<Void, Never>?
    private var scheduledSyncRequiresReload = false

    private init() {}

    /// Cancels pending sync work and drops observers (call on logout/reset).
    func stop() {
        scheduledSyncTask?.cancel()
        scheduledSyncTask = nil
        initialSyncTask?.cancel()
        initialSyncTask = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    func startIfNeeded(
        watchedFoldersManager: WatchedFoldersManager,
        storageLocationsManager: StorageLocationsManager
    ) {
        guard observers.isEmpty else { return }

        let center = NotificationCenter.default
        let notificationNames: [Notification.Name] = [
            .organizationDidFinish,
            .organizationDidRevert,
            .clearAllUsageData
        ]

        observers = notificationNames.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }

                Task { @MainActor in
                    if name == .clearAllUsageData {
                        await Task.yield()
                    }

                    self.scheduleSync(
                        watchedFoldersManager: watchedFoldersManager,
                        storageLocationsManager: storageLocationsManager,
                        forceReload: name == .clearAllUsageData
                    )
                }
            }
        }

        initialSyncTask?.cancel()
        initialSyncTask = Task { @MainActor [weak self, weak watchedFoldersManager, weak storageLocationsManager] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            guard let self, let watchedFoldersManager, let storageLocationsManager else { return }

            // An empty persisted snapshot already represents empty source
            // stores, so avoid opening history and waking WidgetKit at idle.
            if watchedFoldersManager.folders.isEmpty,
               storageLocationsManager.locations.isEmpty,
               SortyWidgetSnapshotStore.load().hasNoContent {
                self.initialSyncTask = nil
                return
            }
            await self.sync(
                watchedFoldersManager: watchedFoldersManager,
                storageLocationsManager: storageLocationsManager
            )
            self.initialSyncTask = nil
        }
    }

    func sync(
        watchedFoldersManager: WatchedFoldersManager,
        storageLocationsManager: StorageLocationsManager,
        forceReload: Bool = false
    ) async {
        let watchedFolders = watchedFoldersManager.folders
        let storageLocations = storageLocationsManager.locations
        let activeWatchedFolderCount = watchedFoldersManager.activeFolderCount

        let result = await syncWorker.sync(
            watchedFolders: watchedFolders,
            storageLocations: storageLocations,
            activeWatchedFolderCount: activeWatchedFolderCount
        )

        if let errorDescription = result.errorDescription {
            LogManager.shared.log(
                "Failed to sync widget snapshot: \(errorDescription)",
                level: .warning,
                category: "Widgets"
            )
        } else if result.didChange || forceReload {
            WidgetCenter.shared.reloadTimelines(
                ofKind: SortyWidgetSnapshotStore.widgetKind
            )
        }
    }

    /// Coalesces bursts from manager publishing and organization notifications so a
    /// single logical update does not repeatedly read history, write disk, and reload WidgetKit.
    func scheduleSync(
        watchedFoldersManager: WatchedFoldersManager,
        storageLocationsManager: StorageLocationsManager,
        forceReload: Bool = false
    ) {
        scheduledSyncRequiresReload = scheduledSyncRequiresReload || forceReload
        scheduledSyncTask?.cancel()
        scheduledSyncTask = Task { @MainActor [weak self, weak watchedFoldersManager, weak storageLocationsManager] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled,
                  let self,
                  let watchedFoldersManager,
                  let storageLocationsManager else { return }

            let forceReload = self.scheduledSyncRequiresReload
            self.scheduledSyncRequiresReload = false
            await self.sync(
                watchedFoldersManager: watchedFoldersManager,
                storageLocationsManager: storageLocationsManager,
                forceReload: forceReload
            )
            self.scheduledSyncTask = nil
        }
    }
}

private extension SortyWidgetSnapshot {
    var hasNoContent: Bool {
        totalSessions == 0
            && totalFilesOrganized == 0
            && activeWatchedFolderCount == 0
            && enabledStorageLocationCount == 0
            && lastRunDate == nil
    }

    func hasSameWidgetContent(as other: SortyWidgetSnapshot) -> Bool {
        totalSessions == other.totalSessions
            && totalFilesOrganized == other.totalFilesOrganized
            && successCount == other.successCount
            && failedCount == other.failedCount
            && activeWatchedFolderCount == other.activeWatchedFolderCount
            && enabledStorageLocationCount == other.enabledStorageLocationCount
            && lastRunDate == other.lastRunDate
            && lastRunFolderName == other.lastRunFolderName
            && lastRunFilesOrganized == other.lastRunFilesOrganized
            && lastRunStatus == other.lastRunStatus
    }
}
