import XCTest
@testable import SortyLib
@testable import SortyCore

final class UserStatsSnapshotTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "com.sorty.tests.user-stats-snapshot"
    private var storageDirectory: URL!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: storageDirectory)
        defaults = nil
        storageDirectory = nil
        super.tearDown()
    }

    func testLoadReturnsZerosWhenNoHistoryExists() {
        let stats = UserStatsSnapshot.load(userDefaults: defaults, storageDirectory: storageDirectory)

        XCTAssertEqual(stats.sessions, 0)
        XCTAssertEqual(stats.filesOrganized, 0)
        XCTAssertEqual(stats.successRate, 0)
        XCTAssertEqual(stats.activeDays, 0)
        XCTAssertEqual(stats.successRatePercent, 0)
    }

    @MainActor
    func testLoadAggregatesCompletedEntriesAndActiveDays() async throws {
        let calendar = Calendar.current
        let dayOne = calendar.startOfDay(for: Date())
        let dayTwo = calendar.date(byAdding: .day, value: -1, to: dayOne)!

        let entries = [
            makeEntry(timestamp: dayOne.addingTimeInterval(60), status: .completed, filesOrganized: 12),
            makeEntry(timestamp: dayOne.addingTimeInterval(3600), status: .failed, filesOrganized: 99),
            makeEntry(timestamp: dayTwo.addingTimeInterval(120), status: .completed, filesOrganized: 8)
        ]

        let history = OrganizationHistory(userDefaults: defaults, storageDirectory: storageDirectory)
        await history.loadPersistedState()
        entries.forEach { history.addEntry($0) }
        await history.waitForPendingPersistence()

        let stats = UserStatsSnapshot.load(userDefaults: defaults, storageDirectory: storageDirectory)

        XCTAssertEqual(stats.sessions, 3)
        XCTAssertEqual(stats.filesOrganized, 20)
        XCTAssertEqual(stats.successRatePercent, 67)
        XCTAssertEqual(stats.activeDays, 2)
    }

    private func makeEntry(timestamp: Date, status: OrganizationStatus, filesOrganized: Int) -> OrganizationHistoryEntry {
        OrganizationHistoryEntry(
            id: UUID(),
            timestamp: timestamp,
            directoryPath: "/tmp/Test Folder",
            filesOrganized: filesOrganized,
            foldersCreated: 2,
            plan: nil,
            success: status == .completed,
            status: status,
            errorMessage: status == .failed ? "Network error" : nil,
            rawAIResponse: nil,
            operations: nil,
            isUndone: false,
            source: .manual,
            undoRestoredCount: nil,
            undoFailedFiles: nil,
            duplicatesDeleted: nil,
            recoveredSpace: nil,
            restorableItems: nil,
            duplicateCleanupMode: nil
        )
    }
}
