import XCTest
@testable import SortyCore
import SortyModels

/// Watched-folder work is moved unattended and persisted, so the ledger's
/// transitions are pinned here rather than left to the compiler.
@MainActor
final class WatchWorkLedgerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func folder(_ path: String = "/tmp/watch-a") -> WatchedFolder {
        WatchedFolder(path: path)
    }

    private func batch(
        _ folder: WatchedFolder,
        files: Set<String>,
        stability: Int = 0,
        operation: Int = 0,
        at date: Date? = nil
    ) -> PendingWatchBatch {
        PendingWatchBatch(
            folder: folder,
            files: files,
            resolvedURL: folder.url,
            stabilityRetryAttempt: stability,
            operationRetryAttempt: operation,
            nextAttemptAt: date ?? t0
        )
    }

    private func review(_ folder: WatchedFolder) -> PendingWatchReview {
        PendingWatchReview(
            folder: folder,
            plan: OrganizationPlan(suggestions: [], unorganizedFiles: [], notes: "n"),
            fileCount: 3,
            mode: .organize
        )
    }

    func testEnqueueMergesFilesAndKeepsEarliestRetryTiming() {
        let f = folder()
        var ledger = WatchWorkLedger()
        ledger.enqueue(batch(f, files: ["a"], stability: 3, operation: 2, at: t0.addingTimeInterval(60)), adoptingFolder: true)
        ledger.enqueue(batch(f, files: ["b"], stability: 1, operation: 2, at: t0), adoptingFolder: true)

        let merged = ledger.queuedBatch(for: f.id)
        XCTAssertEqual(merged?.files, ["a", "b"])
        XCTAssertEqual(merged?.stabilityRetryAttempt, 1)
        XCTAssertEqual(merged?.operationRetryAttempt, 2)
        XCTAssertEqual(merged?.nextAttemptAt, t0)
        XCTAssertEqual(ledger.queuedFolderCount, 1)
    }

    func testEnqueueRestoreKeepsExistingFolderAndURL() {
        let original = folder("/tmp/watch-a")
        var renamed = original
        renamed.name = "Renamed"
        var ledger = WatchWorkLedger()
        ledger.enqueue(batch(original, files: ["a"]), adoptingFolder: true)
        ledger.enqueue(batch(renamed, files: ["b"]), adoptingFolder: false)
        XCTAssertEqual(ledger.queuedBatch(for: original.id)?.folder.name, original.name)

        ledger.enqueue(batch(renamed, files: ["c"]), adoptingFolder: true)
        XCTAssertEqual(ledger.queuedBatch(for: original.id)?.folder.name, "Renamed")
        XCTAssertEqual(ledger.queuedBatch(for: original.id)?.files, ["a", "b", "c"])
    }

    func testTakeAndRequeueRoundTripsBatch() {
        let f = folder()
        var ledger = WatchWorkLedger()
        let original = batch(f, files: ["a", "b"], stability: 2)
        ledger.enqueue(original, adoptingFolder: true)

        let taken = ledger.nextDueBatch(at: t0)
        XCTAssertEqual(taken?.folderID, f.id)
        ledger.removeQueued(f.id)
        XCTAssertNil(ledger.queuedBatch(for: f.id))

        ledger.requeue(taken!.batch, for: f.id)
        XCTAssertEqual(ledger.queuedBatch(for: f.id)?.files, ["a", "b"])
        XCTAssertEqual(ledger.queuedBatch(for: f.id)?.stabilityRetryAttempt, 2)
    }

    func testNextDueBatchSkipsFuturesAndFoldersAwaitingReview() {
        let a = folder("/tmp/watch-a")
        let b = folder("/tmp/watch-b")
        let c = folder("/tmp/watch-c")
        var ledger = WatchWorkLedger()
        ledger.enqueue(batch(a, files: ["a"], at: t0.addingTimeInterval(-10)), adoptingFolder: true)
        ledger.enqueue(batch(b, files: ["b"], at: t0.addingTimeInterval(-5)), adoptingFolder: true)
        ledger.enqueue(batch(c, files: ["c"], at: t0.addingTimeInterval(500)), adoptingFolder: true)
        ledger.saveReview(review(a), for: a.id)

        XCTAssertEqual(ledger.nextDueBatch(at: t0)?.folderID, b.id)
        // The earliest attempt ignores the review-held folder too.
        XCTAssertEqual(ledger.earliestQueuedAttempt, t0.addingTimeInterval(-5))

        ledger.removeQueued(b.id)
        XCTAssertNil(ledger.nextDueBatch(at: t0))
    }

    func testMakeAllQueuedDueResetsOperationRetries() {
        let f = folder()
        var ledger = WatchWorkLedger()
        ledger.enqueue(batch(f, files: ["a"], stability: 2, operation: 2, at: .distantFuture), adoptingFolder: true)
        ledger.makeAllQueuedDue(at: t0)
        XCTAssertEqual(ledger.queuedBatch(for: f.id)?.nextAttemptAt, t0)
        XCTAssertEqual(ledger.queuedBatch(for: f.id)?.operationRetryAttempt, 0)
        XCTAssertEqual(ledger.queuedBatch(for: f.id)?.stabilityRetryAttempt, 2)
    }

    func testDropQueuedKeepsOnlyListedFolders() {
        let a = folder("/tmp/watch-a")
        let b = folder("/tmp/watch-b")
        var ledger = WatchWorkLedger()
        ledger.enqueue(batch(a, files: ["a"]), adoptingFolder: true)
        ledger.enqueue(batch(b, files: ["b"]), adoptingFolder: true)

        XCTAssertTrue(ledger.dropQueued(keeping: [a.id]))
        XCTAssertNotNil(ledger.queuedBatch(for: a.id))
        XCTAssertNil(ledger.queuedBatch(for: b.id))
        XCTAssertFalse(ledger.dropQueued(keeping: [a.id]))
    }

    func testBeginAndFinishActive() {
        let f = folder()
        var ledger = WatchWorkLedger()
        ledger.beginActive(batch(f, files: ["a"]))
        XCTAssertEqual(ledger.activeBatch(for: f.id)?.files, ["a"])
        XCTAssertEqual(ledger.busyFolderIDs, [f.id])

        ledger.finishActive(f.id)
        XCTAssertNil(ledger.activeBatch(for: f.id))
        XCTAssertTrue(ledger.busyFolderIDs.isEmpty)
    }

    func testReviewSaveResolveRestoreRoundTripWithClaim() {
        let f = folder()
        let organizer = FolderOrganizer()
        var ledger = WatchWorkLedger()
        ledger.saveReview(review(f), for: f.id)
        ledger.setClaim(PendingReviewClaim(sessionID: UUID(), organizer: organizer), for: f.id)
        let planID = ledger.review(for: f.id)!.plan.id
        XCTAssertEqual(ledger.reviewFolderID(forPlan: planID), f.id)

        let removed = ledger.resolveReview(f.id)
        XCTAssertNotNil(removed)
        XCTAssertFalse(ledger.hasReview(for: f.id))
        XCTAssertNil(ledger.claim(for: f.id))
        XCTAssertNil(ledger.reviewFolderID(forPlan: planID))
        XCTAssertNil(ledger.resolveReview(f.id))

        // A failed save puts the review and its claim back.
        ledger.restoreReview(removed!, for: f.id)
        XCTAssertEqual(ledger.review(for: f.id)?.plan.id, planID)
        XCTAssertNotNil(ledger.claim(for: f.id))
    }

    func testRestoreWithoutClaimLeavesNoClaim() {
        let f = folder()
        var ledger = WatchWorkLedger()
        ledger.saveReview(review(f), for: f.id)
        let removed = ledger.resolveReview(f.id)!
        ledger.restoreReview(removed, for: f.id)
        XCTAssertTrue(ledger.hasReview(for: f.id))
        XCTAssertNil(ledger.claim(for: f.id))
    }

    func testDropReviewsRemovesClaimsToo() {
        let a = folder("/tmp/watch-a")
        let b = folder("/tmp/watch-b")
        var ledger = WatchWorkLedger()
        ledger.saveReview(review(a), for: a.id)
        ledger.saveReview(review(b), for: b.id)
        ledger.setClaim(PendingReviewClaim(sessionID: UUID(), organizer: FolderOrganizer()), for: b.id)

        XCTAssertTrue(ledger.dropReviews(keeping: [a.id]))
        XCTAssertTrue(ledger.hasReview(for: a.id))
        XCTAssertFalse(ledger.hasReview(for: b.id))
        XCTAssertNil(ledger.claim(for: b.id))
    }

    func testDiscardForManualRunClearsQueuedAndActiveButKeepsReview() {
        let f = folder()
        var ledger = WatchWorkLedger()
        ledger.enqueue(batch(f, files: ["a"]), adoptingFolder: true)
        ledger.beginActive(batch(f, files: ["b"]))
        ledger.saveReview(review(f), for: f.id)

        ledger.discardForManualRun(f.id)
        XCTAssertNil(ledger.queuedBatch(for: f.id))
        XCTAssertNil(ledger.activeBatch(for: f.id))
        XCTAssertTrue(ledger.hasReview(for: f.id))
        XCTAssertTrue(ledger.outstandingBatches().isEmpty)
    }

    func testOutstandingBatchesMergeQueuedAndActive() {
        let f = folder()
        let g = folder("/tmp/watch-b")
        var ledger = WatchWorkLedger()
        ledger.enqueue(batch(f, files: ["queued"], stability: 3, operation: 1, at: t0.addingTimeInterval(30)), adoptingFolder: true)
        ledger.beginActive(batch(f, files: ["running"], stability: 1, operation: 2, at: t0))
        ledger.beginActive(batch(g, files: ["only-active"]))

        let outstanding = ledger.outstandingBatches()
        XCTAssertEqual(outstanding[f.id]?.files, ["queued", "running"])
        XCTAssertEqual(outstanding[f.id]?.stabilityRetryAttempt, 1)
        XCTAssertEqual(outstanding[f.id]?.operationRetryAttempt, 1)
        XCTAssertEqual(outstanding[f.id]?.nextAttemptAt, t0)
        XCTAssertEqual(outstanding[g.id]?.files, ["only-active"])
        // The snapshot is derived; the ledger's own collections are unchanged.
        XCTAssertEqual(ledger.queuedBatch(for: f.id)?.files, ["queued"])
    }

    func testUpdateQueuedAndUpdateReviewReportMissingFolders() {
        let f = folder()
        var ledger = WatchWorkLedger()
        XCTAssertFalse(ledger.updateQueued(f.id) { $0.files = [] })
        XCTAssertFalse(ledger.updateReview(f.id) { $0.fileCount = 0 })

        ledger.enqueue(batch(f, files: ["a"]), adoptingFolder: true)
        XCTAssertTrue(ledger.updateQueued(f.id) { $0.files.insert("z") })
        XCTAssertEqual(ledger.queuedBatch(for: f.id)?.files, ["a", "z"])
    }
}
