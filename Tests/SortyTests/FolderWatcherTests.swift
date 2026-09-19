import XCTest
@testable import SortyLib

final class FolderWatcherTests: XCTestCase {
    @MainActor
    private final class RestartRecoveryDelegate: FolderWatcherDelegate {
        let expectation: XCTestExpectation
        private(set) var deliveredFiles: Set<String> = []

        init(expectation: XCTestExpectation) {
            self.expectation = expectation
        }

        func folderWatcher(
            _ watcher: FolderWatcher,
            didDetectChangesIn folder: WatchedFolder,
            newFiles: Set<String>,
            resolvedURL: URL,
            completion: @escaping @Sendable (Bool) -> Void
        ) {
            deliveredFiles.formUnion(newFiles)
            completion(true)
            expectation.fulfill()
        }

        func folderWatcher(
            _ watcher: FolderWatcher,
            didDetectStaleBookmarkFor folder: WatchedFolder,
            newBookmarkData: Data
        ) {}
    }

    func testWatchedFolderUsesSevenSecondSettleDelayByDefault() {
        let folder = WatchedFolder(path: "/tmp/Sorty-Watched-Default-Delay")

        XCTAssertEqual(folder.triggerDelay, 7)
    }

    @MainActor
    func testRestartRecoveryDeliversFileAddedWhileWatcherWasStopped() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sorty-Watcher-Restart-\(UUID().uuidString)", isDirectory: true)
        let watchedURL = testRoot.appendingPathComponent("Watched", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("State", isDirectory: true)
        try FileManager.default.createDirectory(at: watchedURL, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: testRoot)
            } catch {
                XCTFail("Failed to clean up \(testRoot.path): \(error)")
            }
        }

        try Data("before".utf8).write(to: watchedURL.appendingPathComponent("before.txt"))
        let folder = WatchedFolder(
            path: watchedURL.path,
            triggerDelay: 0.05
        )

        var firstWatcher: FolderWatcher? = FolderWatcher(persistenceRoot: persistenceRoot)
        firstWatcher?.syncWithFolders([folder])

        let snapshotURL = persistenceRoot
            .appendingPathComponent("WatcherSnapshots", isDirectory: true)
            .appendingPathComponent("\(folder.id.uuidString).json")
        // Poll for snapshot with an early exit instead of a fixed long sleep.
        let snapshotDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: snapshotURL.path), Date() < snapshotDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))

        firstWatcher?.stopAllWatching()
        firstWatcher = nil
        try Data("after".utf8).write(to: watchedURL.appendingPathComponent("after.txt"))

        let delivered = expectation(description: "file added while stopped is recovered")
        let delegate = RestartRecoveryDelegate(expectation: delivered)
        let secondWatcher = FolderWatcher(persistenceRoot: persistenceRoot)
        secondWatcher.delegate = delegate
        secondWatcher.syncWithFolders([folder])

        // Generous timeout for slow CI; fulfillment fires on delivery, not on sleep.
        await fulfillment(of: [delivered], timeout: 10)
        XCTAssertEqual(delegate.deliveredFiles, ["after.txt"])
        secondWatcher.stopAllWatching()
    }

    func testUnchangedReconciliationDoesNotRewriteSnapshot() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sorty-Watcher-Unchanged-\(UUID().uuidString)", isDirectory: true)
        let watchedURL = testRoot.appendingPathComponent("Watched", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("State", isDirectory: true)
        try FileManager.default.createDirectory(at: watchedURL, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: testRoot)
            } catch {
                XCTFail("Failed to clean up \(testRoot.path): \(error)")
            }
        }

        try Data("unchanged".utf8).write(to: watchedURL.appendingPathComponent("file.txt"))
        let folder = WatchedFolder(path: watchedURL.path, triggerDelay: 0.05)
        let watcher = FolderWatcher(persistenceRoot: persistenceRoot)
        watcher.syncWithFolders([folder])
        defer { watcher.stopAllWatching() }

        let snapshotURL = persistenceRoot
            .appendingPathComponent("WatcherSnapshots", isDirectory: true)
            .appendingPathComponent("\(folder.id.uuidString).json")
        let unchangedDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: snapshotURL.path), Date() < unchangedDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let initialSnapshot = try Data(contentsOf: snapshotURL)

        watcher.reconcileNow()
        // Fixed settle window for the no-rewrite assertion; kept generous so
        // slow CI does not flake on a negative assertion.
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(try Data(contentsOf: snapshotURL), initialSnapshot)
    }

    func testIgnoresICloudAndOneDrivePlaceholderFiles() {
        let iCloudPlaceholder = URL(fileURLWithPath: "/tmp/.Document.pdf.icloud")
        let oneDrivePlaceholder = URL(fileURLWithPath: "/tmp/Document.cloud")

        XCTAssertTrue(FolderWatcher.shouldIgnoreCloudPlaceholder(at: iCloudPlaceholder))
        XCTAssertTrue(FolderWatcher.shouldIgnoreCloudPlaceholder(at: oneDrivePlaceholder))
    }

    func testKeepsGoogleDriveNativeDocumentsActionable() {
        let googleDocument = URL(fileURLWithPath: "/tmp/Planning.gdoc")

        XCTAssertFalse(FolderWatcher.shouldIgnoreCloudPlaceholder(at: googleDocument))
    }

    func testAcceptedDeliveryOnlyRemovesFilesStillPending() {
        var pending: Set<String> = ["later.txt"]

        let removedCount = FolderWatcher.removeAcceptedBatch(
            ["already-cleared.txt"],
            from: &pending
        )

        XCTAssertEqual(removedCount, 0)
        XCTAssertEqual(pending, ["later.txt"])
    }

    func testCoalescesNestedMonitoringRootsWithoutCollapsingSiblingPrefixes() {
        let roots = FolderWatcher.minimalMonitoringRoots(from: [
            "/Users/example/Documents",
            "/Users/example/Documents/Projects",
            "/Users/example/Documents/Projects/Sorty",
            "/Users/example/Documents-Archive",
        ])

        XCTAssertEqual(roots, [
            "/Users/example/Documents",
            "/Users/example/Documents-Archive",
        ])
    }

    func testLargeNestedWatchSetUsesOnlyTopLevelMonitoringRoots() {
        let paths = (0..<10_000).map { index in
            "/Volumes/Archive-\(index % 10)/group-\(index % 100)/folder-\(index)"
        }

        let roots = FolderWatcher.coalescedMonitoringRoots(from: paths)

        XCTAssertEqual(roots.count, 10)
        XCTAssertEqual(Set(roots), Set((0..<10).map { "/Volumes/Archive-\($0)" }))
    }

    @MainActor
    func testWatchedFolderJournalRoundTripsIndexedConfiguration() async {
        let firstManager = WatchedFoldersManager()
        firstManager.clearAll()
        defer { firstManager.clearAll() }

        let folder = WatchedFolder(
            path: "/tmp/Sorty-Watched-Journal",
            isEnabled: true,
            triggerDelay: 2
        )
        firstManager.addFolder(folder)

        let reloadedManager = WatchedFoldersManager()
        await reloadedManager.loadPersistedState()
        XCTAssertEqual(reloadedManager.folder(withID: folder.id)?.path, folder.path)
        XCTAssertEqual(reloadedManager.folder(matchingPath: folder.path)?.id, folder.id)
        XCTAssertEqual(reloadedManager.activeFolderCount, 1)
    }

    @MainActor
    func testLastTriggeredUpdateDoesNotRebuildWatcherConfiguration() {
        let manager = WatchedFoldersManager()
        manager.clearAll()
        defer { manager.clearAll() }

        let folder = WatchedFolder(
            path: "/tmp/Sorty-Watched-Trigger",
            isEnabled: true
        )
        manager.addFolder(folder)
        let revision = manager.monitoringRevision

        manager.markTriggered(folder)

        XCTAssertNotNil(manager.folder(withID: folder.id)?.lastTriggered)
        XCTAssertEqual(manager.monitoringRevision, revision)
    }

    @MainActor
    func testReauthorizationRejectsASelectedDifferentFolderWithoutChangingState() {
        let manager = WatchedFoldersManager()
        manager.clearAll()
        defer { manager.clearAll() }

        let folder = WatchedFolder(
            path: "/tmp/Sorty-Expected-Watched-Folder",
            bookmarkData: Data([1, 2, 3])
        )
        manager.addFolder(folder)
        let revision = manager.monitoringRevision

        let result = manager.reauthorizeFolder(
            folder,
            with: URL(fileURLWithPath: "/tmp/Sorty-Different-Watched-Folder")
        )

        guard case .incorrectFolder = result else {
            return XCTFail("Expected a mismatched folder selection to be rejected")
        }
        XCTAssertEqual(manager.folder(withID: folder.id)?.path, folder.path)
        XCTAssertEqual(manager.folder(withID: folder.id)?.bookmarkData, folder.bookmarkData)
        XCTAssertEqual(manager.monitoringRevision, revision)
    }
}
