import XCTest
@testable import SortyLib
@testable import SortyCore

/// Restart recovery for a Full Disk Access relaunch: the manual folder and its
/// ready preview must survive, interruptions must restore the folder without
/// auto-reapplying, and stale or corrupt snapshots must be discarded.
@MainActor
final class ManualSessionRestoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var sessionURL: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualSessionRestore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        sessionURL = tempDirectory.appendingPathComponent("ManualSession.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        sessionURL = nil
    }

    private func makeOrganizer() -> FolderOrganizer {
        let organizer = FolderOrganizer()
        organizer.isManualSessionPersistenceEnabled = true
        organizer.manualSessionURLForTesting = sessionURL
        return organizer
    }

    private func makePlan() -> OrganizationPlan {
        OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Receipts", files: [])],
            notes: "test plan"
        )
    }

    func testReadyPlanRoundTripsWithDirectoryAndState() async {
        let organizer = makeOrganizer()
        let plan = makePlan()
        organizer.persistManualSession(
            directory: tempDirectory,
            plan: plan,
            stateHint: .ready,
            instructions: "sort receipts"
        )

        let relaunched = makeOrganizer()
        let restored = await relaunched.restorePersistedManualSession()

        XCTAssertEqual(restored?.standardizedFileURL.path, tempDirectory.standardizedFileURL.path)
        XCTAssertEqual(relaunched.currentDirectory?.standardizedFileURL.path, tempDirectory.standardizedFileURL.path)
        XCTAssertEqual(relaunched.currentPlan?.id, plan.id)
        XCTAssertEqual(relaunched.state, .ready)
        XCTAssertEqual(relaunched.customInstructions, "sort receipts")
    }

    func testInterruptedRestoresFolderWithoutPlanOrWork() async {
        let organizer = makeOrganizer()
        organizer.persistManualSession(
            directory: tempDirectory,
            plan: nil,
            stateHint: .interrupted,
            instructions: ""
        )

        let relaunched = makeOrganizer()
        let restored = await relaunched.restorePersistedManualSession()

        XCTAssertNotNil(restored)
        XCTAssertEqual(relaunched.currentDirectory?.standardizedFileURL.path, tempDirectory.standardizedFileURL.path)
        XCTAssertNil(relaunched.currentPlan)
        XCTAssertEqual(relaunched.state, .idle)
    }

    func testCompletedPlanRestoresCompletedState() async {
        let organizer = makeOrganizer()
        let plan = makePlan()
        organizer.persistManualSession(
            directory: tempDirectory,
            plan: plan,
            stateHint: .completed,
            instructions: ""
        )

        let relaunched = makeOrganizer()
        _ = await relaunched.restorePersistedManualSession()

        XCTAssertEqual(relaunched.state, .completed)
        XCTAssertEqual(relaunched.currentPlan?.id, plan.id)
    }

    func testResetClearsPersistedSession() async {
        let organizer = makeOrganizer()
        organizer.persistManualSession(
            directory: tempDirectory,
            plan: makePlan(),
            stateHint: .ready,
            instructions: ""
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionURL.path))

        organizer.reset()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionURL.path))
        let relaunched = makeOrganizer()
        let restoredAfterReset = await relaunched.restorePersistedManualSession()
        XCTAssertNil(restoredAfterReset)
    }

    func testSelectedDirectoryPersistsWithoutPlan() async {
        let organizer = makeOrganizer()
        organizer.persistSelectedDirectoryForRestart(tempDirectory)

        let relaunched = makeOrganizer()
        let restored = await relaunched.restorePersistedManualSession()

        XCTAssertNotNil(restored)
        XCTAssertNil(relaunched.currentPlan)
        XCTAssertEqual(relaunched.state, .idle)
    }

    func testUnchangedSnapshotDoesNotRewriteSessionFile() async throws {
        let organizer = makeOrganizer()
        let plan = makePlan()
        organizer.persistManualSession(
            directory: tempDirectory,
            plan: plan,
            stateHint: .ready,
            instructions: "sort receipts"
        )
        let firstData = try Data(contentsOf: sessionURL)

        try await Task.sleep(for: .milliseconds(20))
        organizer.persistManualSession(
            directory: tempDirectory,
            plan: plan,
            stateHint: .ready,
            instructions: "sort receipts"
        )

        XCTAssertEqual(try Data(contentsOf: sessionURL), firstData)
    }

    func testChangedSnapshotRewritesSessionFile() async throws {
        let organizer = makeOrganizer()
        let plan = makePlan()
        organizer.persistManualSession(
            directory: tempDirectory,
            plan: plan,
            stateHint: .ready,
            instructions: "sort receipts"
        )
        let firstData = try Data(contentsOf: sessionURL)

        organizer.persistManualSession(
            directory: tempDirectory,
            plan: plan,
            stateHint: .completed,
            instructions: "sort receipts"
        )

        XCTAssertNotEqual(try Data(contentsOf: sessionURL), firstData)
    }

    func testRestoreDiscardsMissingDirectory() async {
        let missing = tempDirectory.appendingPathComponent("gone-\(UUID().uuidString)")
        let organizer = makeOrganizer()
        organizer.persistManualSession(
            directory: missing,
            plan: makePlan(),
            stateHint: .ready,
            instructions: ""
        )

        let relaunched = makeOrganizer()
        let restored = await relaunched.restorePersistedManualSession()

        XCTAssertNil(restored)
        XCTAssertNil(relaunched.currentDirectory)
        XCTAssertNil(relaunched.currentPlan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionURL.path))
    }

    func testRestoreDoesNotClobberActiveWork() async {
        let organizer = makeOrganizer()
        organizer.persistManualSession(
            directory: tempDirectory,
            plan: makePlan(),
            stateHint: .ready,
            instructions: ""
        )

        let relaunched = makeOrganizer()
        relaunched.currentDirectory = tempDirectory
        let restored = await relaunched.restorePersistedManualSession()

        XCTAssertNil(restored)
        XCTAssertNil(relaunched.currentPlan)
    }

    func testCorruptSnapshotReturnsNil() async {
        try? Data("not-json".utf8).write(to: sessionURL)
        let relaunched = makeOrganizer()
        let restored = await relaunched.restorePersistedManualSession()

        XCTAssertNil(restored)
        XCTAssertNil(relaunched.currentDirectory)
    }

    func testPersistenceDisabledByDefault() async {
        let organizer = FolderOrganizer()
        XCTAssertFalse(organizer.isManualSessionPersistenceEnabled)
        organizer.persistManualSession(
            directory: tempDirectory,
            plan: makePlan(),
            stateHint: .ready,
            instructions: ""
        )
        let restored = await organizer.restorePersistedManualSession()
        XCTAssertNil(restored)
    }
}
