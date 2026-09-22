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
}
