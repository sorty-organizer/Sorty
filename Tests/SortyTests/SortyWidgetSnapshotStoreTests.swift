import XCTest
@testable import SortyLib
@testable import SortyCore

final class SortyWidgetSnapshotStoreTests: XCTestCase {
    func testMakeSnapshotSummarizesRecentActivity() {
        let newerEntry = OrganizationHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 200),
            directoryPath: "/Users/test/Downloads",
            filesOrganized: 18,
            foldersCreated: 4,
            success: true,
            status: .completed
        )
        let olderEntry = OrganizationHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 100),
            directoryPath: "/Users/test/Desktop",
            filesOrganized: 3,
            foldersCreated: 1,
            success: false,
            status: .failed,
            errorMessage: "Boom"
        )

        let watchedFolders = [
            WatchedFolder(path: "/Users/test/Downloads", isEnabled: true, autoOrganize: true),
            WatchedFolder(path: "/Users/test/Desktop", isEnabled: true, autoOrganize: false),
            WatchedFolder(path: "/Users/test/Documents", isEnabled: false, autoOrganize: true)
        ]
        let storageLocations = [
            StorageLocation(path: "/Volumes/Archive", isEnabled: true),
            StorageLocation(path: "/Volumes/Cold", isEnabled: false)
        ]

        let snapshot = SortyWidgetSnapshotStore.makeSnapshot(
            entries: [olderEntry, newerEntry],
            watchedFolders: watchedFolders,
            storageLocations: storageLocations,
            now: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(snapshot.generatedAt, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(snapshot.totalSessions, 2)
        XCTAssertEqual(snapshot.totalFilesOrganized, 18)
        XCTAssertEqual(snapshot.successCount, 1)
        XCTAssertEqual(snapshot.failedCount, 1)
        XCTAssertEqual(snapshot.activeWatchedFolderCount, 1)
        XCTAssertEqual(snapshot.enabledStorageLocationCount, 1)
        XCTAssertEqual(snapshot.lastRunFolderName, "Downloads")
        XCTAssertEqual(snapshot.lastRunFilesOrganized, 18)
        XCTAssertEqual(snapshot.lastRunStatus, .completed)
        XCTAssertEqual(snapshot.lastRunDate, Date(timeIntervalSince1970: 200))
    }
}
