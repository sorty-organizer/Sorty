//
//  RefreshManager.swift
//  Sorty
//
//  Consolidated timer management to prevent retain cycles and reduce memory overhead
//

import Foundation
import Combine

/// A consolidated timer manager that handles multiple refresh timers with different intervals
/// Uses weak self patterns to prevent retain cycles and provides centralized control
@MainActor
public final class RefreshManager: ObservableObject {

    // MARK: - Types

    /// Represents a scheduled refresh action
    private struct ScheduledAction: @unchecked Sendable {
        let timer: Timer
        var remainingInterval: TimeInterval?
    }

    // MARK: - Properties

    private var scheduledActions: [UUID: ScheduledAction] = [:]
    private var isPaused: Bool = false

    // MARK: - Initialization

    public init() {}

    deinit {
        for action in scheduledActions.values {
            action.timer.invalidate()
        }
    }

    // MARK: - Timer Scheduling

    /// Schedule a repeating timer with the specified interval and action
    /// - Parameters:
    ///   - interval: Time interval between firings
    ///   - action: The action to perform (captured with weak self)
    /// - Returns: A unique identifier for the scheduled timer
    @discardableResult
    public func schedule(interval: TimeInterval, action: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let safeInterval = normalizedRepeatingInterval(interval)

        let timer = Timer(timeInterval: safeInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isPaused else { return }
                action()
            }
        }
        // Let macOS combine noncritical refresh wakeups without changing cadence.
        timer.tolerance = min(safeInterval * 0.1, 0.5)
        if isPaused {
            timer.fireDate = .distantFuture
        }
        RunLoop.main.add(timer, forMode: .common)

        scheduledActions[id] = ScheduledAction(timer: timer, remainingInterval: isPaused ? safeInterval : nil)

        // Fire immediately if not paused
        if !isPaused {
            action()
        }

        return id
    }

    // MARK: - Control Methods

    /// Cancel a specific scheduled timer by its ID
    public func cancel(_ id: UUID) {
        if let action = scheduledActions.removeValue(forKey: id) {
            action.timer.invalidate()
        }
    }

    /// Cancel all scheduled timers and tasks
    public func cancelAll() {
        // Cancel all timer-based actions
        for action in scheduledActions.values {
            action.timer.invalidate()
        }
        scheduledActions.removeAll()
    }

    /// Pause all timers (they won't fire until resumed)
    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        let now = Date()
        for id in Array(scheduledActions.keys) {
            guard var scheduled = scheduledActions[id] else { continue }
            scheduled.remainingInterval = max(0, scheduled.timer.fireDate.timeIntervalSince(now))
            scheduled.timer.fireDate = .distantFuture
            scheduledActions[id] = scheduled
        }
    }

    /// Resume all paused timers
    public func resume() {
        guard isPaused else { return }
        isPaused = false
        let now = Date()
        for id in Array(scheduledActions.keys) {
            guard var scheduled = scheduledActions[id] else { continue }
            scheduled.timer.fireDate = now.addingTimeInterval(scheduled.remainingInterval ?? scheduled.timer.timeInterval)
            scheduled.remainingInterval = nil
            scheduledActions[id] = scheduled
        }
    }

    // MARK: - Convenience Methods

    /// Create a coordinated refresh group that can be controlled together
    public func createCoordinatedGroup() -> CoordinatedRefreshGroup {
        CoordinatedRefreshGroup(manager: self)
    }

    private func normalizedRepeatingInterval(_ interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite, interval > 0 else { return 1 }
        return max(interval, 0.01)
    }
}

// MARK: - Coordinated Refresh Group

/// A group of related refresh timers that can be controlled together
@MainActor
public final class CoordinatedRefreshGroup {
    private weak var manager: RefreshManager?
    private var timerIDs: [UUID] = []
    
    fileprivate init(manager: RefreshManager) {
        self.manager = manager
    }
    
    /// Add a timer to this coordinated group
    @discardableResult
    public func addTimer(interval: TimeInterval, action: @escaping @Sendable () -> Void) -> UUID {
        guard let manager = manager else { return UUID() }
        let id = manager.schedule(interval: interval, action: action)
        timerIDs.append(id)
        return id
    }
    
    /// Cancel all timers in this group
    public func cancelAll() {
        guard let manager = manager else { return }
        for id in timerIDs {
            manager.cancel(id)
        }
        timerIDs.removeAll()
    }
    
    /// Pause all timers in this group
    public func pause() {
        guard let manager = manager else { return }
        manager.pause()
    }
    
    /// Resume all timers in this group
    public func resume() {
        guard let manager = manager else { return }
        manager.resume()
    }
}
