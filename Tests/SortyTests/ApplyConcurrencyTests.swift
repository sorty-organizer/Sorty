import XCTest
@testable import SortyLib

/// Regression tests for FolderOrganizer apply/undo state tracking:
/// - concurrent apply() calls must single-flight (the second no-ops on
///   .applying) instead of cancelling the first run and starting a second
///   file-move pass that records duplicate history entries.
/// - undo issued from .idle must still track .applying while files move and
///   restore every file to its original location.
final class ApplyConcurrencyTests: XCTestCase {
    private var tempRoot: URL!
    private var testSuiteName: String!
    private var testDefaults: UserDefaults!
    private var storageDirectory: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        testSuiteName = "com.sorty.tests.apply-concurrency.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: testSuiteName)!
        testDefaults.removePersistentDomain(forName: testSuiteName)
        storageDirectory = tempRoot.appendingPathComponent("History", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let testSuiteName {
            testDefaults?.removePersistentDomain(forName: testSuiteName)
        }
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        testDefaults = nil
        tempRoot = nil
    }

    @MainActor
    func testApplyRejectsDirectoryDifferentFromPlanDirectory() async throws {
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let otherDir = tempRoot.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        let fileURL = sourceDir.appendingPathComponent("a.txt")
        try "contents".write(to: fileURL, atomically: true, encoding: .utf8)
        let file = FileItem(path: fileURL.path, name: "a", extension: "txt")
        let organizer = FolderOrganizer()
        organizer.currentDirectory = sourceDir
        organizer.currentPlan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Docs", files: [file])]
        )

        do {
            try await organizer.apply(at: otherDir)
            XCTFail("Apply must reject a directory different from the plan's source")
        } catch let error as OrganizationError {
            guard case .planDirectoryMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherDir.appendingPathComponent("Docs/a.txt").path))
    }

    func testValidatorRejectsParentTraversalDestination() throws {
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "../Sibling")]
        )

        XCTAssertThrowsError(
            try FileOrganizationValidator.validate(plan, at: tempRoot)
        ) { error in
            guard case ValidationError.destinationEscapesBaseDirectory = error else {
                return XCTFail("Unexpected validation error: \(error)")
            }
        }
    }

    @MainActor
    func testConcurrentDoubleApplySingleFlightsAndUndoRestores() async throws {
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let fileNames = ["a.txt", "b.txt"]
        var files: [FileItem] = []
        for name in fileNames {
            let url = sourceDir.appendingPathComponent(name)
            try "contents of \(name)".write(to: url, atomically: true, encoding: .utf8)
            files.append(FileItem(
                path: url.path,
                name: url.deletingPathExtension().lastPathComponent,
                extension: "txt",
                size: 1,
                isDirectory: false
            ))
        }

        let history = OrganizationHistory(userDefaults: testDefaults, storageDirectory: storageDirectory)
        let organizer = FolderOrganizer(history: history)
        organizer.currentPlan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Docs", files: files)],
            unorganizedFiles: [],
            notes: "test"
        )

        // Two concurrent applies: the loser must no-op on .applying.
        async let first: Void = organizer.apply(at: sourceDir)
        async let second: Void = organizer.apply(at: sourceDir)
        try await first
        try await second

        XCTAssertEqual(organizer.state, .completed)
        let completedEntries = history.entries.filter {
            $0.status == .completed && $0.directoryPath == sourceDir.path
        }
        XCTAssertEqual(completedEntries.count, 1, "concurrent apply() must record a single history entry")
        for name in fileNames {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: sourceDir.appendingPathComponent(name).path),
                "\(name) must be moved out of the source root"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: sourceDir.appendingPathComponent("Docs").appendingPathComponent(name).path),
                "\(name) must land in Docs/"
            )
        }

        // Undo from a fresh idle organizer still tracks the restore and
        // brings every file back.
        let idleOrganizer = FolderOrganizer(history: history)
        XCTAssertEqual(idleOrganizer.state, .idle)
        guard let entry = completedEntries.first else {
            return XCTFail("missing completed history entry")
        }
        let result = try await idleOrganizer.undoHistoryEntry(entry)
        XCTAssertFalse(result.hasIssues, "undo must restore without missing files")
        XCTAssertEqual(idleOrganizer.state, .idle)
        for name in fileNames {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: sourceDir.appendingPathComponent(name).path),
                "undo must restore \(name) to the source root"
            )
        }

        await history.waitForPendingPersistence()
    }

    /// Cancelling after the moves completed but before the post-move
    /// cancellation check must still record an entry carrying those operations,
    /// otherwise the moved files have no undo path.
    @MainActor
    func testCancelAfterMovesRecordsUndoablePartialHistory() async throws {
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let fileNames = ["a.txt", "b.txt"]
        var files: [FileItem] = []
        for name in fileNames {
            let url = sourceDir.appendingPathComponent(name)
            try "contents of \(name)".write(to: url, atomically: true, encoding: .utf8)
            files.append(FileItem(
                path: url.path,
                name: url.deletingPathExtension().lastPathComponent,
                extension: "txt",
                size: 1,
                isDirectory: false
            ))
        }

        let history = OrganizationHistory(userDefaults: testDefaults, storageDirectory: storageDirectory)
        let organizer = FolderOrganizer(history: history)
        organizer.currentPlan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Docs", files: files)],
            unorganizedFiles: [],
            notes: "cancel after moves"
        )
        organizer.setPostMoveCancellationCheckHookForTesting { [weak organizer] in
            await MainActor.run {
                organizer?.cancel()
            }
        }

        do {
            try await organizer.apply(at: sourceDir)
            XCTFail("apply must surface the cancellation")
        } catch {
            // Expected: the hook cancelled after the moves completed.
        }

        let partialEntry = history.entries.first { $0.directoryPath == sourceDir.path }
        XCTAssertNotNil(partialEntry, "partial cancel must record history so moved files stay undoable")
        XCTAssertNotEqual(partialEntry?.status, .completed)
        XCTAssertFalse(partialEntry?.operations?.isEmpty ?? true, "the partial entry must carry the completed operations")

        guard let entry = partialEntry else { return }
        let result = try await organizer.undoHistoryEntry(entry)
        XCTAssertFalse(result.hasIssues, "undo must restore the moved files")
        for name in fileNames {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: sourceDir.appendingPathComponent(name).path),
                "undo must restore \(name) to the source root"
            )
        }

        await history.waitForPendingPersistence()
    }

    /// A second organize() while the first is still starting must not cancel it
    /// or clobber its task; exactly one analysis run should happen.
    @MainActor
    func testConcurrentOrganizeCallsSingleFlight() async throws {
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "contents".write(to: sourceDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let config = AIConfig(apiKey: "test-key", model: "test-model", enableSmartRename: false)
        let mockClient = MockAIClient(config: config)
        await mockClient.setHandler { files in
            try await Task.sleep(nanoseconds: 150_000_000)
            return OrganizationPlan(
                suggestions: [FolderSuggestion(folderName: "Docs", files: files)],
                unorganizedFiles: [],
                notes: "concurrent organize"
            )
        }

        let history = OrganizationHistory(userDefaults: testDefaults, storageDirectory: storageDirectory)
        let organizer = FolderOrganizer(history: history)
        organizer.setAIClientForTesting(mockClient)

        async let first: Void = organizer.organize(directory: sourceDir)
        async let second: Void = organizer.organize(directory: sourceDir)
        try await first
        try await second

        XCTAssertEqual(organizer.state, .ready)
        XCTAssertNotNil(organizer.currentPlan)
        let analyzedBatchSizes = await mockClient.currentAnalyzedBatchSizes()
        XCTAssertEqual(analyzedBatchSizes.count, 1, "the second organize() must not restart analysis")
    }

    /// Incremental auto-apply moves files from .organizing straight into
    /// .applying/.completed; those transitions must be accepted so the run
    /// finishes in .completed instead of silently staying in .organizing.
    @MainActor
    func testIncrementalAutoApplyReachesCompleted() async throws {
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "contents".write(to: sourceDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let history = OrganizationHistory(userDefaults: testDefaults, storageDirectory: storageDirectory)
        let organizer = FolderOrganizer(history: history)
        let config = AIConfig(
            apiKey: "test-key",
            model: "test-model",
            enableSmartRename: false,
            enableFileTagging: false
        )
        let mockClient = MockAIClient(config: config)
        await mockClient.setHandler { files in
            OrganizationPlan(
                suggestions: [FolderSuggestion(folderName: "Docs", files: files)],
                unorganizedFiles: [],
                notes: "incremental"
            )
        }
        organizer.setAIClientForTesting(mockClient)

        try await organizer.organizeIncremental(directory: sourceDir, autoApply: true)

        XCTAssertEqual(organizer.state, .completed)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: sourceDir.appendingPathComponent("Docs").appendingPathComponent("a.txt").path
            ),
            "auto-apply must move the file into Docs/"
        )
        let completedEntries = history.entries.filter {
            $0.status == .completed && $0.directoryPath == sourceDir.path
        }
        XCTAssertEqual(completedEntries.count, 1)

        await history.waitForPendingPersistence()
    }
}
