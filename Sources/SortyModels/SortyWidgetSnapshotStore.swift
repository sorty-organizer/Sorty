import Foundation

public struct SortyWidgetSnapshot: Codable, Equatable, Sendable {
    public static let empty = Self(
        generatedAt: .distantPast,
        totalSessions: 0,
        totalFilesOrganized: 0,
        successCount: 0,
        failedCount: 0,
        activeWatchedFolderCount: 0,
        enabledStorageLocationCount: 0,
        lastRunDate: nil,
        lastRunFolderName: nil,
        lastRunFilesOrganized: nil,
        lastRunStatus: nil
    )

    public let generatedAt: Date
    public let totalSessions: Int
    public let totalFilesOrganized: Int
    public let successCount: Int
    public let failedCount: Int
    public let activeWatchedFolderCount: Int
    public let enabledStorageLocationCount: Int
    public let lastRunDate: Date?
    public let lastRunFolderName: String?
    public let lastRunFilesOrganized: Int?
    public let lastRunStatus: OrganizationStatus?

    public init(
        generatedAt: Date = Date(),
        totalSessions: Int,
        totalFilesOrganized: Int,
        successCount: Int,
        failedCount: Int,
        activeWatchedFolderCount: Int,
        enabledStorageLocationCount: Int,
        lastRunDate: Date?,
        lastRunFolderName: String?,
        lastRunFilesOrganized: Int?,
        lastRunStatus: OrganizationStatus?
    ) {
        self.generatedAt = generatedAt
        self.totalSessions = totalSessions
        self.totalFilesOrganized = totalFilesOrganized
        self.successCount = successCount
        self.failedCount = failedCount
        self.activeWatchedFolderCount = activeWatchedFolderCount
        self.enabledStorageLocationCount = enabledStorageLocationCount
        self.lastRunDate = lastRunDate
        self.lastRunFolderName = lastRunFolderName
        self.lastRunFilesOrganized = lastRunFilesOrganized
        self.lastRunStatus = lastRunStatus
    }
}

public enum SortyWidgetSnapshotStore {
    public static let appGroupIdentifier = "group.com.sorty.app"
    public static let widgetKind = "com.sorty.app.widget.overview"

    private static let directoryName = "Widget"
    private static let fileName = "overview-snapshot.json"

    public static func load(fileManager: FileManager = .default) -> SortyWidgetSnapshot {
        guard let snapshotURL = snapshotURL(fileManager: fileManager),
              let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(SortyWidgetSnapshot.self, from: data) else {
            return .empty
        }

        return snapshot
    }

    @discardableResult
    public static func save(
        _ snapshot: SortyWidgetSnapshot,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let snapshotURL = snapshotURL(fileManager: fileManager) else {
            throw CocoaError(.fileNoSuchFile)
        }

        try ensureDirectoryExists(for: snapshotURL, fileManager: fileManager)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
        return snapshotURL
    }

    public static func clear(fileManager: FileManager = .default) {
        guard let snapshotURL = snapshotURL(fileManager: fileManager),
              fileManager.fileExists(atPath: snapshotURL.path) else {
            return
        }

        try? fileManager.removeItem(at: snapshotURL)
    }

    public static func makeSnapshot(
        entries: [OrganizationHistoryEntry],
        watchedFolders: [WatchedFolder],
        storageLocations: [StorageLocation],
        activeWatchedFolderCount: Int? = nil,
        now: Date = Date()
    ) -> SortyWidgetSnapshot {
        var latestEntry: OrganizationHistoryEntry?
        var totalFilesOrganized = 0
        var successCount = 0
        var failedCount = 0

        for entry in entries {
            if latestEntry.map({ entry.timestamp > $0.timestamp }) ?? true {
                latestEntry = entry
            }

            switch entry.status {
            case .completed:
                successCount += 1
                totalFilesOrganized += entry.filesOrganized
            case .failed:
                failedCount += 1
            default:
                break
            }
        }

        return SortyWidgetSnapshot(
            generatedAt: now,
            totalSessions: entries.count,
            totalFilesOrganized: totalFilesOrganized,
            successCount: successCount,
            failedCount: failedCount,
            activeWatchedFolderCount: activeWatchedFolderCount
                ?? watchedFolders.lazy.filter { $0.isEnabled && $0.autoOrganize }.count,
            enabledStorageLocationCount: storageLocations.filter(\.isEnabled).count,
            lastRunDate: latestEntry?.timestamp,
            lastRunFolderName: latestEntry.flatMap(lastRunFolderName(for:)),
            lastRunFilesOrganized: latestEntry?.filesOrganized,
            lastRunStatus: latestEntry?.status
        )
    }

    private static func snapshotURL(fileManager: FileManager) -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static func ensureDirectoryExists(for fileURL: URL, fileManager: FileManager) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        guard !fileManager.fileExists(atPath: directoryURL.path) else { return }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private static func lastRunFolderName(for entry: OrganizationHistoryEntry) -> String? {
        guard !entry.directoryPath.isEmpty else { return nil }
        return URL(fileURLWithPath: entry.directoryPath).lastPathComponent
    }
}
