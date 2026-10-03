import XCTest
@testable import SortyLib
@testable import SortyCore
@testable import SortyLearnings

@MainActor
final class LearningsSessionFeedbackLoopTests: XCTestCase {
    private var manager: LearningsManager!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "LearningsSessionFeedbackLoopTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        manager = LearningsManager(userDefaults: defaults)
        manager.currentProfile = LearningsProfile()
        await manager.grantConsent()
    }

    override func tearDown() async throws {
        manager = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testUsefulOutcomePersistsReasonInEventMetadata() {
        manager.currentProfile?.sessions = [
            OrganizationSession(id: "session-1", folderPath: "/Work", reaction: .inProgress)
        ]

        manager.recordSessionOutcomeFeedback(
            sessionId: "session-1",
            outcome: .useful,
            folderPath: "/Work",
            reason: "Folders look right"
        )

        let session = manager.currentProfile?.sessions.first(where: { $0.id == "session-1" })
        XCTAssertEqual(session?.reaction, .accepted)
        let event = session?.events.last(where: { $0.kind == .feedback })
        XCTAssertEqual(event?.metadata?["reason"], "Folders look right")
        XCTAssertEqual(event?.metadata?["outcome"], "useful")
    }

    func testNotUsefulReasonLinksToSteeringPrompt() {
        manager.currentProfile?.sessions = [
            OrganizationSession(id: "session-2", folderPath: "/Work", reaction: .inProgress)
        ]

        manager.recordSessionOutcomeFeedback(
            sessionId: "session-2",
            outcome: .notUseful,
            folderPath: "/Work",
            reason: "Wrong folders"
        )

        let session = manager.currentProfile?.sessions.first(where: { $0.id == "session-2" })
        let event = session?.events.last(where: { $0.kind == .feedback })
        XCTAssertEqual(event?.metadata?["reason"], "Wrong folders")
        XCTAssertTrue(
            manager.currentProfile?.steeringPrompts.contains(where: {
                $0.prompt.contains("Wrong folders") && $0.sessionId == "session-2"
            }) ?? false
        )
    }

    func testOutcomeIgnoredWhenLearningPaused() {
        manager.currentProfile?.sessions = [
            OrganizationSession(id: "session-3", folderPath: "/Work", reaction: .inProgress)
        ]
        manager.sessionLearningPaused = true

        manager.recordSessionOutcomeFeedback(
            sessionId: "session-3",
            outcome: .notUseful,
            folderPath: "/Work",
            reason: "Too many folders"
        )

        let session = manager.currentProfile?.sessions.first(where: { $0.id == "session-3" })
        XCTAssertEqual(session?.reaction, .inProgress)
        XCTAssertFalse(session?.events.contains(where: { $0.kind == .feedback }) ?? true)
    }

    func testFeedbackDraftValidation() {
        var draft = SessionFeedbackDraft()
        XCTAssertFalse(draft.canSubmit)

        draft.outcome = .useful
        XCTAssertTrue(draft.canSubmit)

        draft = SessionFeedbackDraft(outcome: .notUseful)
        XCTAssertFalse(draft.canSubmit)

        draft.selectedChip = "Wrong folders"
        XCTAssertTrue(draft.canSubmit)
        XCTAssertEqual(draft.resolvedReason, "Wrong folders")

        draft.freeText = "  split my invoices  "
        XCTAssertEqual(draft.resolvedReason, "split my invoices")
    }
}

@MainActor
final class ContinuousLearningMomentLoopTests: XCTestCase {
    private var manager: LearningsManager!
    private var history: OrganizationHistory!
    private var observer: ContinuousLearningObserver!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var historyDir: URL!

    override func setUp() async throws {
        suiteName = "ContinuousLearningMomentLoopTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        historyDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        manager = LearningsManager(userDefaults: defaults)
        manager.currentProfile = LearningsProfile()
        await manager.grantConsent()
        history = OrganizationHistory(userDefaults: defaults, storageDirectory: historyDir)
        await history.loadPersistedState()
        observer = ContinuousLearningObserver(learningsManager: manager, history: history)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: historyDir)
        manager = nil
        history = nil
        observer = nil
        defaults = nil
        historyDir = nil
        suiteName = nil
    }

    func testUncertainSessionGeneratesMoment() {
        let session = OrganizationSession(
            folderPath: "/Projects",
            filesMoved: [
                OrganizationSessionMovedFile(sourcePath: "/Downloads/a.pdf", destinationPath: "/Projects/Invoices/a.pdf"),
                OrganizationSessionMovedFile(sourcePath: "/Downloads/b.pdf", destinationPath: "/Projects/Receipts/b.pdf"),
            ],
            folderPatterns: [
                OrganizationSessionFolderPattern(relativePath: "Invoices", folderName: "Invoices", fileCount: 1),
                OrganizationSessionFolderPattern(relativePath: "Receipts", folderName: "Receipts", fileCount: 1),
            ]
        )
        let moment = manager.generateInlineLearningMoment(from: session, proposedFolders: ["Invoices", "Receipts", "Archive"])
        XCTAssertNotNil(moment)
        XCTAssertFalse(moment?.options.isEmpty ?? true)
    }

    func testStraightforwardSessionGeneratesNoMoment() {
        let session = OrganizationSession(folderPath: "/Projects")
        XCTAssertNil(manager.generateInlineLearningMoment(from: session, proposedFolders: ["Invoices"]))
    }

    func testConsumeEnforcesOncePerSession() {
        let moment = InlineLearningMoment(
            sessionId: "session-once",
            folderPath: "/Projects",
            prompt: "Where should these go?",
            options: ["A", "B"],
            kind: .folderPlacement
        )
        observer.pendingLearningMoment = moment

        XCTAssertTrue(InlineLearningMomentPolicy.shouldPresent(
            moment: observer.pendingLearningMoment,
            presentedSessionIDs: [],
            alreadyPresenting: false
        ))
        let first = observer.consumePendingLearningMoment()
        XCTAssertEqual(first?.id, moment.id)

        observer.pendingLearningMoment = moment
        XCTAssertFalse(InlineLearningMomentPolicy.shouldPresent(
            moment: observer.pendingLearningMoment,
            presentedSessionIDs: ["session-once"],
            alreadyPresenting: false
        ))
        XCTAssertNil(observer.consumePendingLearningMoment())
    }

    func testDismissClearsPending() {
        observer.pendingLearningMoment = InlineLearningMoment(
            sessionId: "session-dismiss",
            folderPath: "/Projects",
            prompt: "Where?",
            options: ["A"],
            kind: .fileGrouping
        )
        observer.dismissPendingLearningMoment()
        XCTAssertNil(observer.pendingLearningMoment)
        XCTAssertNil(observer.consumePendingLearningMoment())
    }
}

@MainActor
final class HistoryDetailFeedbackLoopTests: XCTestCase {
    func testNotUsefulDraftRequiresReason() {
        let draft = SessionFeedbackDraft(outcome: .notUseful, selectedChip: "Files split up")
        XCTAssertTrue(draft.requiresReason)
        XCTAssertTrue(draft.canSubmit)
        XCTAssertEqual(draft.resolvedReason, "Files split up")
    }

    func testPresetChipsAvailable() {
        XCTAssertFalse(LearningsManager.sessionFeedbackReasonPresets.isEmpty)
    }
}
