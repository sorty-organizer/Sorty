import Foundation

/// Coalesces and guards a store's one-time background read of persisted state.
///
/// A store's `loadPersistedState()` calls `join` to share a single in-flight
/// read between callers, awaits it, then applies the result only if
/// `isCurrent(generation)` still holds. Clearing or resetting the store calls
/// `invalidate()` so a read that finishes afterwards cannot bring deleted data
/// back. The store keeps its own `hasLoadedPersistedState` flag and merge rules.
@MainActor
public final class HydrationGate<Value: Sendable> {
    private var task: Task<Value, Never>?
    private var generation = 0

    public init() {}

    /// Returns the in-flight read, starting one with `start` when none exists,
    /// and the generation the caller must re-check after awaiting it.
    public func join(_ start: () -> Task<Value, Never>) -> (task: Task<Value, Never>, generation: Int) {
        if let task { return (task, generation) }
        let started = start()
        task = started
        return (started, generation)
    }

    /// False once `invalidate()` ran after the caller captured `generation`.
    public func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation
    }

    /// Releases the finished read after its result has been applied.
    public func finish() {
        task = nil
    }

    /// Drops any in-flight read and makes its result stale.
    public func invalidate() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}
