import XCTest
@testable import SortyLib
@testable import SortyCore

private actor BlockingRevertHook {
    private var hasEntered = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func block() async {
        hasEntered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        if hasEntered {
            return
        }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
final class UndoReliabilityTests: XCTestCase {
    private var history: OrganizationHistory!
    private var organizer: FolderOrganizer!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var workspaceDirectory: URL!
    private var historyStorageDirectory: URL!

    override func setUp() async throws {
        suiteName = "UndoReliabilityTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)

        workspaceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        historyStorageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: historyStorageDirectory, withIntermediateDirectories: true)

        history = OrganizationHistory(userDefaults: defaults, storageDirectory: historyStorageDirectory)
        await history.loadPersistedState()
        organizer = FolderOrganizer(history: history)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workspaceDirectory)
        try? FileManager.default.removeItem(at: historyStorageDirectory)
        defaults.removePersistentDomain(forName: suiteName)
        history = nil
        organizer = nil
        defaults = nil
        suiteName = nil
        workspaceDirectory = nil
        historyStorageDirectory = nil
    }

    func testPartialUndoRetainsOnlyFailedRemainderForRetry() async throws {
        let createdEntry = try makeMovedEntry(fileNames: ["keep.txt", "retry.txt"])
        history.addEntry(createdEntry.entry)

        try FileManager.default.removeItem(at: createdEntry.destinations[1])

        let firstResult = try await organizer.undoHistoryEntry(createdEntry.entry)
        XCTAssertEqual(firstResult.successfulOperations, 1)
        XCTAssertEqual(firstResult.missingFiles, ["retry.txt"])

        let partiallyUndone = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(partiallyUndone.status, .partiallyUndone)
        XCTAssertFalse(partiallyUndone.isUndone)
        XCTAssertEqual(partiallyUndone.operations?.count, 1)
        XCTAssertEqual(partiallyUndone.operations?.first?.id, createdEntry.entry.operations?[1].id)
        XCTAssertEqual(partiallyUndone.undoRestoredCount, 1)
        XCTAssertEqual(partiallyUndone.undoFailedFiles, ["retry.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdEntry.sources[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: createdEntry.sources[1].path))

        try "retry".write(to: createdEntry.destinations[1], atomically: true, encoding: .utf8)

        let secondResult = try await organizer.undoHistoryEntry(partiallyUndone)
        XCTAssertEqual(secondResult.successfulOperations, 1)
        XCTAssertTrue(secondResult.missingFiles.isEmpty)

        let fullyUndone = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(fullyUndone.status, .undo)
        XCTAssertTrue(fullyUndone.isUndone)
        XCTAssertNil(fullyUndone.operations)
        XCTAssertEqual(fullyUndone.undoRestoredCount, 2)
        XCTAssertNil(fullyUndone.undoFailedFiles)
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdEntry.sources[1].path))
    }

    func testUndoRecordsEarlierSuccessWhenALaterFilesystemRestoreFails() async throws {
        let destinationDirectory = workspaceDirectory.appendingPathComponent("Organized", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let blockedParent = workspaceDirectory.appendingPathComponent("blocked")
        try "not a directory".write(to: blockedParent, atomically: true, encoding: .utf8)
        let failedDestination = destinationDirectory.appendingPathComponent("failed.txt")
        let restoredDestination = destinationDirectory.appendingPathComponent("restored.txt")
        try "failed".write(to: failedDestination, atomically: true, encoding: .utf8)
        try "restored".write(to: restoredDestination, atomically: true, encoding: .utf8)

        let failedOperation = FileSystemManager.FileOperation(
            type: .moveFile,
            sourcePath: blockedParent.appendingPathComponent("failed.txt").path,
            destinationPath: failedDestination.path
        )
        let restoredOperation = FileSystemManager.FileOperation(
            type: .moveFile,
            sourcePath: workspaceDirectory.appendingPathComponent("restored.txt").path,
            destinationPath: restoredDestination.path
        )
        let entry = OrganizationHistoryEntry(
            directoryPath: workspaceDirectory.path,
            filesOrganized: 2,
            foldersCreated: 1,
            status: .completed,
            operations: [failedOperation, restoredOperation]
        )
        history.addEntry(entry)

        let result = try await organizer.undoHistoryEntry(entry)

        XCTAssertEqual(result.successfulOperations, 1)
        XCTAssertEqual(result.retryableFailedOperationIDs, [failedOperation.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceDirectory.appendingPathComponent("restored.txt").path))

        let partiallyUndone = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(partiallyUndone.operations?.map(\.id), [failedOperation.id])
        XCTAssertEqual(partiallyUndone.undoRestoredCount, 1)
    }

    func testFailedSingleOperationUndoRemainsRetryable() async throws {
        let createdEntry = try makeMovedEntry(fileNames: ["single.txt"])
        history.addEntry(createdEntry.entry)

        let operation = try XCTUnwrap(createdEntry.entry.operations?.first)
        try FileManager.default.removeItem(at: createdEntry.destinations[0])

        let firstResult = try await organizer.undoSingleOperation(from: createdEntry.entry, operation: operation)
        XCTAssertEqual(firstResult.retryableFailedOperationIDs, [operation.id])

        let partiallyUndone = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(partiallyUndone.status, .partiallyUndone)
        XCTAssertFalse(partiallyUndone.isUndone)
        XCTAssertEqual(partiallyUndone.operations?.map(\.id), [operation.id])

        try "single".write(to: createdEntry.destinations[0], atomically: true, encoding: .utf8)

        let secondResult = try await organizer.undoSingleOperation(from: partiallyUndone, operation: operation)
        XCTAssertEqual(secondResult.successfulOperations, 1)

        let fullyUndone = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(fullyUndone.status, .undo)
        XCTAssertTrue(fullyUndone.isUndone)
        XCTAssertNil(fullyUndone.operations)
    }

    func testConcurrentUndoForSameEntryIsRejected() async throws {
        let createdEntry = try makeMovedEntry(fileNames: ["race.txt"])
        history.addEntry(createdEntry.entry)

        let hook = BlockingRevertHook()
        organizer.setRevertOperationHookForTesting {
            await hook.block()
        }
        defer {
            organizer.setRevertOperationHookForTesting(nil)
        }

        let firstTask = Task {
            try await self.organizer.undoHistoryEntry(createdEntry.entry)
        }

        await hook.waitUntilEntered()

        do {
            _ = try await organizer.undoHistoryEntry(createdEntry.entry)
            XCTFail("Expected concurrent undo to be rejected")
        } catch let error as OrganizationError {
            XCTAssertEqual(
                error,
                .revertAlreadyInProgress(URL(fileURLWithPath: createdEntry.entry.directoryPath).standardizedFileURL.path)
            )
        }

        await hook.release()
        let result = try await firstTask.value
        XCTAssertEqual(result.successfulOperations, 1)

        let updatedEntry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(updatedEntry.status, .undo)
        XCTAssertTrue(updatedEntry.isUndone)
    }

    func testUndoCreatedFolderWithUserContentRemainsRetryable() async throws {
        let createdFolder = workspaceDirectory.appendingPathComponent("Created", isDirectory: true)
        try FileManager.default.createDirectory(at: createdFolder, withIntermediateDirectories: true)
        try "user content".write(
            to: createdFolder.appendingPathComponent("manual-note.txt"),
            atomically: true,
            encoding: .utf8
        )

        let operation = FileSystemManager.FileOperation(
            type: .createFolder,
            sourcePath: createdFolder.path,
            destinationPath: nil,
            metadata: .init(wasCreatedDuringOrganization: true)
        )
        let entry = OrganizationHistoryEntry(
            directoryPath: workspaceDirectory.path,
            filesOrganized: 0,
            foldersCreated: 1,
            status: .completed,
            operations: [operation]
        )
        history.addEntry(entry)

        let firstResult = try await organizer.undoHistoryEntry(entry)
        XCTAssertEqual(firstResult.successfulOperations, 0)
        XCTAssertEqual(firstResult.retryableFailedOperationIDs, [operation.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdFolder.path))

        let partiallyUndone = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(partiallyUndone.status, .partiallyUndone)
        XCTAssertEqual(partiallyUndone.operations?.map(\.id), [operation.id])

        try FileManager.default.removeItem(at: createdFolder.appendingPathComponent("manual-note.txt"))

        let secondResult = try await organizer.undoHistoryEntry(partiallyUndone)
        XCTAssertEqual(secondResult.successfulOperations, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: createdFolder.path))

        let fullyUndone = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(fullyUndone.status, .undo)
        XCTAssertTrue(fullyUndone.isUndone)
        XCTAssertNil(fullyUndone.operations)
    }

    private func makeMovedEntry(fileNames: [String]) throws -> (
        entry: OrganizationHistoryEntry,
        sources: [URL],
        destinations: [URL]
    ) {
        let destinationDirectory = workspaceDirectory.appendingPathComponent("Organized", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        var operations: [FileSystemManager.FileOperation] = []
        var sources: [URL] = []
        var destinations: [URL] = []

        for fileName in fileNames {
            let sourceURL = workspaceDirectory.appendingPathComponent(fileName)
            let destinationURL = destinationDirectory.appendingPathComponent(fileName)
            try fileName.write(to: sourceURL, atomically: true, encoding: .utf8)
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)

            operations.append(
                FileSystemManager.FileOperation(
                    type: .moveFile,
                    sourcePath: sourceURL.path,
                    destinationPath: destinationURL.path
                )
            )
            sources.append(sourceURL)
            destinations.append(destinationURL)
        }

        let entry = OrganizationHistoryEntry(
            directoryPath: workspaceDirectory.path,
            filesOrganized: fileNames.count,
            foldersCreated: 1,
            status: .completed,
            operations: operations
        )

        return (entry, sources, destinations)
    }
}
