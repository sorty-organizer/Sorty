
import XCTest
@testable import SortyLib

class HistoryTests: XCTestCase {
    
    var history: OrganizationHistory!
    private var testSuiteName: String!
    private var testDefaults: UserDefaults!
    private var storageDirectory: URL!
    
    @MainActor
    override func setUp() async throws {
        
        testSuiteName = "com.sorty.tests.history.\(name)"
        testDefaults = UserDefaults(suiteName: testSuiteName)!
        testDefaults.removePersistentDomain(forName: testSuiteName)
        storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        history = OrganizationHistory(userDefaults: testDefaults, storageDirectory: storageDirectory)
        await history.loadPersistedState()
    }
    
    @MainActor
    override func tearDown() async throws {
        await history?.waitForPendingPersistence()
        testDefaults?.removePersistentDomain(forName: testSuiteName)
        if let storageDirectory {
            try? FileManager.default.removeItem(at: storageDirectory)
        }
        testDefaults = nil
        storageDirectory = nil
        history = nil
        
    }
    
    @MainActor
    func testAddEntry() {
        let entry = OrganizationHistoryEntry(
            directoryPath: "/test/path",
            filesOrganized: 5,
            foldersCreated: 2,
            status: .completed
        )
        
        history.addEntry(entry)
        
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.totalFilesOrganized, 5)
        XCTAssertEqual(history.totalFoldersCreated, 2)
    }

    func testHistoryEntryUsesFolderNameAsDisplayName() {
        let entry = OrganizationHistoryEntry(
            directoryPath: "/Users/test/Downloads",
            filesOrganized: 0,
            foldersCreated: 0
        )

        XCTAssertEqual(entry.displayName, "Downloads")
    }

    func testHistoryEntryUsesGeneratedSessionName() {
        let entry = OrganizationHistoryEntry(
            directoryPath: "/Users/test/Downloads",
            filesOrganized: 0,
            foldersCreated: 0,
            plan: OrganizationPlan(sessionName: "Project Documents")
        )

        XCTAssertEqual(entry.displayName, "Project Documents")
    }

    func testHistoryEntryBuildsNameFromPlanFoldersWhenGeneratedNameIsUnavailable() {
        let plan = OrganizationPlan(
            suggestions: [
                FolderSuggestion(folderName: "Invoices"),
                FolderSuggestion(folderName: "Receipts")
            ]
        )
        let entry = OrganizationHistoryEntry(
            directoryPath: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .path,
            filesOrganized: 0,
            foldersCreated: 0,
            plan: plan
        )

        XCTAssertEqual(entry.displayName, "Invoices & Receipts Organization")
    }

    func testHistoryEntryUsesStatusAndIdentifierWhenNoContextExists() {
        let entryID = UUID(uuidString: "93DC199E-F79F-436E-8F36-9EA949227CB6")!
        let entry = OrganizationHistoryEntry(
            id: entryID,
            directoryPath: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .path,
            filesOrganized: 0,
            foldersCreated: 0,
            success: false,
            status: .failed
        )

        XCTAssertEqual(entry.displayName, "Failed Organization 93DC199E")
    }

    func testHistoryEntryPreservesUUIDFolderOutsideTemporaryDirectory() {
        let directoryID = UUID()
        let entry = OrganizationHistoryEntry(
            directoryPath: "/Users/test/\(directoryID.uuidString)",
            filesOrganized: 0,
            foldersCreated: 0
        )

        XCTAssertEqual(entry.displayName, directoryID.uuidString)
    }
    
    @MainActor
    func testStatsCalculation() {
        let entry1 = OrganizationHistoryEntry(directoryPath: "/p1", filesOrganized: 10, foldersCreated: 3, status: .completed)
        let entry2 = OrganizationHistoryEntry(directoryPath: "/p2", filesOrganized: 5, foldersCreated: 1, status: .completed)
        let entry3 = OrganizationHistoryEntry(directoryPath: "/p3", filesOrganized: 0, foldersCreated: 0, status: .failed)
        
        history.addEntry(entry1)
        history.addEntry(entry2)
        history.addEntry(entry3)
        
        XCTAssertEqual(history.totalFilesOrganized, 15)
        XCTAssertEqual(history.totalFoldersCreated, 4)
        XCTAssertEqual(history.totalSessions, 3)
        XCTAssertEqual(history.failedCount, 1)
        XCTAssertEqual(history.successRate, 2.0/3.0, accuracy: 0.01)
    }
    
    @MainActor
    func testPersistence() async {
        let entry = OrganizationHistoryEntry(directoryPath: "/persist", filesOrganized: 1, foldersCreated: 1)
        history.addEntry(entry)
        await history.waitForPendingPersistence()

        let newHistory = OrganizationHistory(userDefaults: testDefaults, storageDirectory: storageDirectory)
        await newHistory.loadPersistedState()

        XCTAssertTrue(newHistory.entries.contains(where: { $0.directoryPath == "/persist" }))
    }

    @MainActor
    func testMigratesLegacyUserDefaultsIntoFileStore() async throws {
        let legacyEntry = OrganizationHistoryEntry(
            directoryPath: "/legacy",
            filesOrganized: 3,
            foldersCreated: 1,
            status: .completed
        )
        let encoded = try JSONEncoder().encode([legacyEntry])
        testDefaults.set(encoded, forKey: "organizationHistory")

        let migratedHistory = OrganizationHistory(userDefaults: testDefaults, storageDirectory: storageDirectory)
        await migratedHistory.loadPersistedState()

        XCTAssertEqual(migratedHistory.entries.count, 1)
        XCTAssertEqual(migratedHistory.entries.first?.directoryPath, "/legacy")
        XCTAssertNil(testDefaults.data(forKey: "organizationHistory"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(migratedHistory.storageFileURL).path))
    }

    @MainActor
    func testCorruptedPrimaryRecoversLatestSnapshotFromBackup() async throws {
        let first = OrganizationHistoryEntry(directoryPath: "/one", filesOrganized: 1, foldersCreated: 1, status: .completed)
        let second = OrganizationHistoryEntry(directoryPath: "/two", filesOrganized: 2, foldersCreated: 1, status: .completed)

        history.addEntry(first)
        history.addEntry(second)
        await history.waitForPendingPersistence()

        let primaryURL = try XCTUnwrap(history.storageFileURL)
        let backupURL = try XCTUnwrap(history.backupStorageFileURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        let corruptData = Data("{\"entries\": [".utf8)
        try corruptData.write(to: primaryURL)

        let recoveredHistory = OrganizationHistory(userDefaults: testDefaults, storageDirectory: storageDirectory)
        await recoveredHistory.loadPersistedState()

        XCTAssertEqual(recoveredHistory.entries.count, 2)
        XCTAssertEqual(Set(recoveredHistory.entries.map(\.directoryPath)), Set(["/one", "/two"]))

        let recoveredEntries = OrganizationHistory.loadPersistedEntries(
            userDefaults: testDefaults,
            storageDirectory: storageDirectory
        )
        XCTAssertEqual(recoveredEntries.count, 2)
    }

    @MainActor
    func testConstructionDefersDecodeAndLoadAppliesRetentionLimit() async throws {
        let entries = (0..<5_000).map { index in
            OrganizationHistoryEntry(
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                directoryPath: "/history/\(index)",
                filesOrganized: index,
                foldersCreated: 1
            )
        }
        let fileURL = storageDirectory.appendingPathComponent("organization-history.json")
        try JSONEncoder().encode(entries).write(to: fileURL)

        let startedAt = CFAbsoluteTimeGetCurrent()
        let deferredHistory = OrganizationHistory(
            userDefaults: testDefaults,
            storageDirectory: storageDirectory
        )
        let constructionDuration = CFAbsoluteTimeGetCurrent() - startedAt

        XCTAssertFalse(deferredHistory.hasLoadedPersistedState)
        XCTAssertTrue(deferredHistory.entries.isEmpty)
        XCTAssertLessThan(constructionDuration, 0.05)

        await deferredHistory.loadPersistedState()

        XCTAssertTrue(deferredHistory.hasLoadedPersistedState)
        XCTAssertEqual(deferredHistory.entries.count, 100)
        XCTAssertEqual(deferredHistory.entries.first?.directoryPath, "/history/4999")
    }

    @MainActor
    func testCancelledEntryWithStoredPlanCanBeAppliedLater() {
        let plan = OrganizationPlan(
            suggestions: [
                FolderSuggestion(folderName: "Invoices", files: [])
            ]
        )
        let entry = OrganizationHistoryEntry(
            directoryPath: "/planned",
            filesOrganized: 0,
            foldersCreated: 0,
            plan: plan,
            success: false,
            status: .cancelled
        )

        XCTAssertTrue(entry.hasApplicablePlan)
    }

    @MainActor
    func testCompletedEntryWithOperationsIsNotTreatedAsUnappliedPlan() {
        let operation = FileSystemManager.FileOperation(
            type: .createFolder,
            sourcePath: "/planned",
            destinationPath: "/planned/Invoices"
        )
        let entry = OrganizationHistoryEntry(
            directoryPath: "/planned",
            filesOrganized: 1,
            foldersCreated: 1,
            plan: OrganizationPlan(),
            status: .completed,
            operations: [operation]
        )

        XCTAssertFalse(entry.hasApplicablePlan)
    }

    @MainActor
    func testImportReportsAddedUpdatedAndUnchangedEntries() {
        let existingID = UUID()
        let unchanged = OrganizationHistoryEntry(
            id: existingID,
            directoryPath: "/existing",
            filesOrganized: 1,
            foldersCreated: 1
        )
        history.addEntry(unchanged)

        let updated = OrganizationHistoryEntry(
            id: existingID,
            directoryPath: "/existing",
            filesOrganized: 2,
            foldersCreated: 1
        )
        let added = OrganizationHistoryEntry(
            directoryPath: "/imported",
            filesOrganized: 3,
            foldersCreated: 2
        )

        let firstResult = history.importEntries([unchanged])
        XCTAssertEqual(firstResult.unchanged, 1)
        XCTAssertEqual(firstResult.changed, 0)

        let secondResult = history.importEntries([updated, added])
        XCTAssertEqual(secondResult.added, 1)
        XCTAssertEqual(secondResult.updated, 1)
        XCTAssertEqual(secondResult.unchanged, 0)
        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(history.entries.first(where: { $0.id == existingID })?.filesOrganized, 2)
    }

    @MainActor
    func testImportRetainsMostRecentHundredEntries() {
        let entries = (0..<105).map { index in
            OrganizationHistoryEntry(
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                directoryPath: "/imported/\(index)",
                filesOrganized: index,
                foldersCreated: 0
            )
        }

        let result = history.importEntries(entries)

        XCTAssertEqual(history.entries.count, 100)
        XCTAssertEqual(result.added, 105)
        XCTAssertEqual(result.omittedByRetentionLimit, 5)
        XCTAssertEqual(history.entries.first?.directoryPath, "/imported/104")
        XCTAssertEqual(history.entries.last?.directoryPath, "/imported/5")
    }

    func testHistoryFiltersMatchOnlyTheirIntendedStatusOrSource() {
        let testCases: [(HistoryView.HistoryFilter, OrganizationStatus, OrganizationEntrySource, Bool, Bool, Bool)] = [
            (.all, .completed, .manual, false, false, true),
            (.all, .failed, .watchedFolder, false, false, true),
            (.undoable, .completed, .manual, false, true, true),
            (.undoable, .partiallyUndone, .manual, false, true, true),
            (.undoable, .completed, .manual, true, true, false),
            (.undoable, .completed, .manual, false, false, false),
            (.undoable, .failed, .manual, false, true, false),
            (.failed, .failed, .manual, false, false, true),
            (.failed, .cancelled, .manual, false, false, false),
            (.skipped, .skipped, .manual, false, false, true),
            (.skipped, .cancelled, .manual, false, false, false),
            (.cancelled, .cancelled, .manual, false, false, true),
            (.cancelled, .skipped, .manual, false, false, false),
            (.manual, .completed, .manual, false, false, true),
            (.manual, .completed, .watchedFolder, false, false, false),
            (.watched, .completed, .watchedFolder, false, false, true),
            (.watched, .completed, .manual, false, false, false),
        ]

        for (filter, status, source, isUndone, hasOperations, expectedMatch) in testCases {
            XCTAssertEqual(
                filter.includes(
                    status: status,
                    source: source,
                    isUndone: isUndone,
                    hasOperations: hasOperations
                ),
                expectedMatch,
                "\(filter.rawValue) produced the wrong result for \(status.rawValue), \(source.rawValue)"
            )
        }
    }
}
