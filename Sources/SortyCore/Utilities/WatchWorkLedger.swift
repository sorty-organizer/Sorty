import Foundation
import SortyModels
import SortyOrganizer

/// The window session presenting a saved watched-folder review plan.
package final class PendingReviewClaim {
    package let sessionID: UUID
    package weak var organizer: FolderOrganizer?

    package init(sessionID: UUID, organizer: FolderOrganizer) {
        self.sessionID = sessionID
        self.organizer = organizer
    }
}

package struct PendingWatchBatch {
    package var folder: WatchedFolder
    package var files: Set<String>
    package var resolvedURL: URL
    package var stabilityRetryAttempt: Int
    package var operationRetryAttempt: Int
    package var nextAttemptAt: Date

    package init(
        folder: WatchedFolder,
        files: Set<String>,
        resolvedURL: URL,
        stabilityRetryAttempt: Int,
        operationRetryAttempt: Int,
        nextAttemptAt: Date
    ) {
        self.folder = folder
        self.files = files
        self.resolvedURL = resolvedURL
        self.stabilityRetryAttempt = stabilityRetryAttempt
        self.operationRetryAttempt = operationRetryAttempt
        self.nextAttemptAt = nextAttemptAt
    }
}

package struct PendingWatchReview {
    package var folder: WatchedFolder
    package var plan: OrganizationPlan
    package var fileCount: Int
    package var mode: OrganizationMode

    package init(folder: WatchedFolder, plan: OrganizationPlan, fileCount: Int, mode: OrganizationMode) {
        self.folder = folder
        self.plan = plan
        self.fileCount = fileCount
        self.mode = mode
    }
}

/// Per-folder bookkeeping for unattended watched-folder work. A folder can
/// hold a queued batch (waiting to run), an active batch (running now), a
/// saved review plan, and the window claim presenting that plan, all at
/// once, so these stay separate collections. They are private to the
/// ledger so every change goes through a named transition. The persisted
/// format (`PersistedPendingWatchBatch`/`Review`) is derived from these
/// by `AppCoordinator.outstandingWatchWorkSnapshot()` and is unchanged.
package struct WatchWorkLedger {
    package init() {}

    private var queued: [UUID: PendingWatchBatch] = [:]
    private var active: [UUID: PendingWatchBatch] = [:]
    private var reviews: [UUID: PendingWatchReview] = [:]
    private var claims: [UUID: PendingReviewClaim] = [:]

    // MARK: Queued batches

    package var queuedFolderCount: Int { queued.count }
    package var hasQueuedBatches: Bool { !queued.isEmpty }

    package func queuedBatch(for folderID: UUID) -> PendingWatchBatch? { queued[folderID] }

    /// Adds files to the folder's queued batch, keeping the earliest retry
    /// timing. `adoptingFolder` also refreshes the folder and resolved URL
    /// from the incoming batch (live events); restore keeps the existing ones.
    package mutating func enqueue(_ incoming: PendingWatchBatch, adoptingFolder: Bool) {
        guard var existing = queued[incoming.folder.id] else {
            queued[incoming.folder.id] = incoming
            return
        }
        existing.files.formUnion(incoming.files)
        if adoptingFolder {
            existing.folder = incoming.folder
            existing.resolvedURL = incoming.resolvedURL
        }
        existing.stabilityRetryAttempt = min(existing.stabilityRetryAttempt, incoming.stabilityRetryAttempt)
        existing.operationRetryAttempt = min(existing.operationRetryAttempt, incoming.operationRetryAttempt)
        existing.nextAttemptAt = min(existing.nextAttemptAt, incoming.nextAttemptAt)
        queued[incoming.folder.id] = existing
    }

    /// Puts a batch back that was taken for a run that did not start.
    package mutating func requeue(_ batch: PendingWatchBatch, for folderID: UUID) {
        queued[folderID] = batch
    }

    /// Edits the queued batch in place. Returns false when none is queued.
    @discardableResult
    package mutating func updateQueued(_ folderID: UUID, _ update: (inout PendingWatchBatch) -> Void) -> Bool {
        guard var batch = queued[folderID] else { return false }
        update(&batch)
        queued[folderID] = batch
        return true
    }

    @discardableResult
    package mutating func removeQueued(_ folderID: UUID) -> PendingWatchBatch? {
        queued.removeValue(forKey: folderID)
    }

    /// Drops queued batches whose folder is no longer in `keeping`.
    /// Returns true when anything was dropped.
    package mutating func dropQueued(keeping folderIDs: Set<UUID>) -> Bool {
        let stale = queued.keys.filter { !folderIDs.contains($0) }
        for folderID in stale { queued.removeValue(forKey: folderID) }
        return !stale.isEmpty
    }

    package mutating func makeAllQueuedDue(at date: Date) {
        for folderID in Array(queued.keys) {
            queued[folderID]?.nextAttemptAt = date
            queued[folderID]?.operationRetryAttempt = 0
        }
    }

    /// The queued batch that is due soonest. Folders with a saved review
    /// wait until the review is resolved.
    package func nextDueBatch(at date: Date) -> (folderID: UUID, batch: PendingWatchBatch)? {
        queued
            .filter { $0.value.nextAttemptAt <= date && reviews[$0.key] == nil }
            .min(by: { $0.value.nextAttemptAt < $1.value.nextAttemptAt })
            .map { ($0.key, $0.value) }
    }

    package var earliestQueuedAttempt: Date? {
        queued.filter { reviews[$0.key] == nil }.map(\.value.nextAttemptAt).min()
    }

    // MARK: Active batches

    package func activeBatch(for folderID: UUID) -> PendingWatchBatch? { active[folderID] }

    package mutating func beginActive(_ batch: PendingWatchBatch) {
        active[batch.folder.id] = batch
    }

    package mutating func finishActive(_ folderID: UUID) {
        active.removeValue(forKey: folderID)
    }

    /// A manual run takes over the folder: nothing queued or active survives.
    package mutating func discardForManualRun(_ folderID: UUID) {
        queued.removeValue(forKey: folderID)
        active.removeValue(forKey: folderID)
    }

    // MARK: Reviews

    package func review(for folderID: UUID) -> PendingWatchReview? { reviews[folderID] }
    package func hasReview(for folderID: UUID) -> Bool { reviews[folderID] != nil }

    package func reviewFolderID(forPlan planID: UUID) -> UUID? {
        reviews.first(where: { $0.value.plan.id == planID })?.key
    }

    package mutating func saveReview(_ review: PendingWatchReview, for folderID: UUID) {
        reviews[folderID] = review
    }

    @discardableResult
    package mutating func updateReview(_ folderID: UUID, _ update: (inout PendingWatchReview) -> Void) -> Bool {
        guard var review = reviews[folderID] else { return false }
        update(&review)
        reviews[folderID] = review
        return true
    }

    /// Removes the review and its window claim together. Returns what was
    /// removed so a failed save can put it back with `restoreReview`.
    package mutating func resolveReview(_ folderID: UUID) -> (review: PendingWatchReview, claim: PendingReviewClaim?)? {
        guard let review = reviews.removeValue(forKey: folderID) else { return nil }
        return (review, claims.removeValue(forKey: folderID))
    }

    package mutating func restoreReview(_ removed: (review: PendingWatchReview, claim: PendingReviewClaim?), for folderID: UUID) {
        reviews[folderID] = removed.review
        claims[folderID] = removed.claim
    }

    /// Drops reviews whose folder is no longer in `keeping`, with their claims.
    package mutating func dropReviews(keeping folderIDs: Set<UUID>) -> Bool {
        let stale = reviews.keys.filter { !folderIDs.contains($0) }
        for folderID in stale {
            reviews.removeValue(forKey: folderID)
            claims.removeValue(forKey: folderID)
        }
        return !stale.isEmpty
    }

    // MARK: Review claims

    package func claim(for folderID: UUID) -> PendingReviewClaim? { claims[folderID] }

    package mutating func setClaim(_ claim: PendingReviewClaim, for folderID: UUID) {
        claims[folderID] = claim
    }

    package mutating func clearClaim(for folderID: UUID) {
        claims.removeValue(forKey: folderID)
    }

    // MARK: Derived

    /// Folders with anything queued or running, for activity refresh.
    package var busyFolderIDs: Set<UUID> {
        Set(queued.keys).union(active.keys)
    }

    /// Queued work plus whatever is running, merged per folder, so a quit
    /// mid-run re-queues the running files.
    package func outstandingBatches() -> [UUID: PendingWatchBatch] {
        var outstanding = queued
        for (folderID, running) in active {
            if var existing = outstanding[folderID] {
                existing.files.formUnion(running.files)
                existing.stabilityRetryAttempt = min(existing.stabilityRetryAttempt, running.stabilityRetryAttempt)
                existing.operationRetryAttempt = min(existing.operationRetryAttempt, running.operationRetryAttempt)
                existing.nextAttemptAt = min(existing.nextAttemptAt, running.nextAttemptAt)
                outstanding[folderID] = existing
            } else {
                outstanding[folderID] = running
            }
        }
        return outstanding
    }

    package var outstandingReviews: [UUID: PendingWatchReview] { reviews }
}
