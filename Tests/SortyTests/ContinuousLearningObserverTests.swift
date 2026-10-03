import XCTest
@testable import SortyLib
@testable import SortyCore

@MainActor
final class ContinuousLearningObserverTests: XCTestCase {
    private var manager: LearningsManager!
    private var history: OrganizationHistory!
    private var observer: ContinuousLearningObserver!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var historyStorageDirectory: URL!

    override func setUp() async throws {
        suiteName = "ContinuousLearningObserverTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        historyStorageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: historyStorageDirectory, withIntermediateDirectories: true)
        manager = LearningsManager(userDefaults: defaults)
        manager.currentProfile = LearningsProfile()
        await manager.grantConsent()
        let history = OrganizationHistory(userDefaults: defaults, storageDirectory: historyStorageDirectory)
        await history.loadPersistedState()
        self.history = history
        observer = ContinuousLearningObserver(learningsManager: manager, history: history)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: historyStorageDirectory)
        manager = nil
        history = nil
        observer = nil
        defaults = nil
        historyStorageDirectory = nil
        suiteName = nil
    }

    func testGeneratePromptContextMigratesLegacySignalsIntoSessions() async {
        var profile = LearningsProfile()
        profile.consentGranted = true
        profile.additionalInstructionsHistory = [
            UserInstruction(
                timestamp: Date(),
                instruction: "Keep client work grouped together",
                folderPath: "/Users/test/Projects"
            )
        ]
        profile.postOrganizationChanges = [
            DirectoryChange(
                timestamp: Date(),
                originalPath: "/Users/test/Projects/Misc/invoice.pdf",
                newPath: "/Users/test/Projects/Finance/Invoices/invoice.pdf",
                wasAIOrganized: true
            )
        ]

        manager.currentProfile = profile

        let context = manager.generatePromptContext(forFolder: "/Users/test/Projects")

        XCTAssertFalse(context.isEmpty)
        XCTAssertTrue(context.contains("USER INSTRUCTIONS"))
        XCTAssertTrue(context.contains("PREFERENCES"))
        XCTAssertTrue(context.contains("CORRECTIONS"))
        XCTAssertEqual(manager.currentProfile?.sessions.count, 1)
        XCTAssertEqual(manager.currentProfile?.sessions.first?.reaction, .corrected)
    }

    func testMonitoringWindowExpiryDoesNotReinforceUnreviewedPlacements() async throws {
        let rule = InferredRule(
            id: "rule-invoices",
            pattern: ".*\\.pdf$",
            template: "/Users/test/Finance/Invoices/{filename}",
            priority: 90,
            explanation: "PDF invoices go in Finance/Invoices"
        )
        manager.currentProfile?.inferredRules = [rule]

        let destinationPath = "/Users/test/Finance/Invoices/invoice.pdf"
        let operation = FileSystemManager.FileOperation(
            type: .moveFile,
            sourcePath: "/Users/test/Downloads/invoice.pdf",
            destinationPath: destinationPath
        )

        observer.startSession(folderPath: "/Users/test", historyEntryId: "history-1", operations: [operation])
        observer.recordRuleApplication(destinationPath: destinationPath, ruleId: rule.id)
        await Task.yield()
        observer.endSession()
        observer.handleMonitoringWindowExpired(for: "/Users/test")

        let session = try XCTUnwrap(manager.currentProfile?.sessions.first)
        XCTAssertEqual(session.reaction.rawValue, "unreviewed")
        XCTAssertEqual(session.filesMoved.count, 1)
        XCTAssertEqual(manager.currentProfile?.positiveExamples.count, 0)
        XCTAssertEqual(manager.currentProfile?.inferredRules.first?.successCount, 0)
        XCTAssertEqual(manager.currentProfile?.inferredRules.first?.failureCount, 0)

        manager.recordSessionOutcomeFeedback(sessionId: "history-1", outcome: .useful)
        manager.recordSessionOutcomeFeedback(sessionId: "history-1", outcome: .useful)
        observer.handleMonitoringWindowExpired(for: "/Users/test")
        XCTAssertEqual(manager.currentProfile?.sessions.first?.reaction, .accepted)
        XCTAssertEqual(manager.currentProfile?.positiveExamples.count, 1)
        XCTAssertEqual(manager.currentProfile?.positiveExamples.first?.metadata?["folder_scope"], "/Users/test")
        XCTAssertEqual(manager.currentProfile?.inferredRules.first?.successCount, 1)
    }

    func testLearningExcludedRunNeverCreatesSession() {
        observer.startSession(
            folderPath: "/Users/test",
            historyEntryId: "history-excluded",
            learningExcluded: true
        )

        XCTAssertNil(observer.currentSession)
        XCTAssertTrue(manager.currentProfile?.sessions.isEmpty ?? false)
    }

    func testExclusionInstructionDiscardsOpenSessionWithoutRecordingInstruction() {
        observer.startSession(folderPath: "/Users/test", historyEntryId: "history-1")
        XCTAssertEqual(manager.currentProfile?.sessions.count, 1)

        observer.trackAdditionalInstruction(
            "Don't learn from this organization",
            forFolder: "/Users/test"
        )

        XCTAssertNil(observer.currentSession)
        XCTAssertTrue(manager.currentProfile?.sessions.isEmpty ?? false)
        XCTAssertTrue(manager.currentProfile?.additionalInstructionsHistory.isEmpty ?? false)
    }
}
