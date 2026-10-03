import XCTest
@testable import SortyOrganizer
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

    func testReadyRunRestoresOnlyDirectUserInstructions() async throws {
        let organizer = makeOrganizer()
        try Data("Receipt".utf8).write(to: tempDirectory.appendingPathComponent("receipt.txt"))
        let config = AIConfig(provider: .openAI, apiKey: "test", model: "gpt-4o")
        try await organizer.configure(with: config)
        let client = MockAIClient(config: config)
        await client.setHandler { files in
            OrganizationPlan(suggestions: [FolderSuggestion(
                folderName: "Receipts", files: files, reasoning: "Receipt records"
            )])
        }
        organizer.setAIClientForTesting(client)
        try await organizer.organize(directory: tempDirectory, customPrompt: "sort receipts")

        let relaunched = makeOrganizer()
        _ = await relaunched.restorePersistedManualSession()
        XCTAssertEqual(relaunched.customInstructions, "sort receipts")
        XCTAssertEqual(relaunched.state, .ready)
        relaunched.reset()
        XCTAssertEqual(relaunched.customInstructions, "sort receipts")
    }

    func testLegacyRequestSnapshotsRecoverUserTextWithoutGeneratedContext() async throws {
        let exclusion = "IMPORTANT: The following patterns are STRICTLY EXCLUDED and must NOT be moved, renamed, or modified:"
        let cases: [(String, String)] = [
            ("<user_instructions>\nsort receipts\n</user_instructions>\n\n" + exclusion + "\n- private", "sort receipts"),
            ("<user_instructions>\n<user_instructions>\nsort receipts\n</user_instructions>\n" + exclusion + "\n</user_instructions>", "sort receipts"),
            ("<user_instructions>\n" + exclusion + "\n- private\n</user_instructions>", ""),
            (exclusion + "\n- private", ""),
            ("## SOURCE FOLDER CONTEXT\nInternal file inventory", ""),
            ("## ORGANIZATION LOCATIONS\nApproved storage", ""),
            ("DUPLICATE FILES DETECTED:\nInternal duplicate list", ""),
            ("sort receipts", "sort receipts")
        ]
        for (leaked, expected) in cases {
            let organizer = makeOrganizer()
            organizer.persistManualSession(directory: tempDirectory, plan: makePlan(), stateHint: .ready, instructions: leaked)
            var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sessionURL)) as? [String: Any])
            snapshot.removeValue(forKey: "instructionsFormatVersion")
            try JSONSerialization.data(withJSONObject: snapshot).write(to: sessionURL)

            let relaunched = makeOrganizer()
            _ = await relaunched.restorePersistedManualSession()
            XCTAssertEqual(relaunched.customInstructions, expected)
        }
    }

    func testVersionedSnapshotsPreserveLiteralPromptMarkers() async {
        let instructions = "  Keep <user_instructions> as a filename.\n## SOURCE FOLDER CONTEXT is my folder name.  "
        let organizer = makeOrganizer()
        organizer.persistManualSession(directory: tempDirectory, plan: makePlan(), stateHint: .ready, instructions: instructions)
        let relaunched = makeOrganizer()
        _ = await relaunched.restorePersistedManualSession()
        XCTAssertEqual(relaunched.customInstructions, instructions)
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

    func testSnapshotWriteCoalescing() async throws {
        let organizer = makeOrganizer()
        let plan = makePlan()
        organizer.persistManualSession(
            directory: tempDirectory,
            plan: plan,
            stateHint: .ready,
            instructions: "sort receipts"
        )
        let firstData = try Data(contentsOf: sessionURL)

        // Unchanged snapshot must not rewrite the session file.
        try await Task.sleep(for: .milliseconds(20))
        organizer.persistManualSession(
            directory: tempDirectory,
            plan: plan,
            stateHint: .ready,
            instructions: "sort receipts"
        )

        XCTAssertEqual(try Data(contentsOf: sessionURL), firstData)

        // Changed snapshot must rewrite the session file.
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
