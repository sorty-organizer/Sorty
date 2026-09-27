//
//  Constants.swift
//  Sorty
//
//  App-wide constants
//

import Foundation

enum Constants {
    static let appGroupIdentifier = "group.com.sorty.app"
    static let maxPreviewVersions = 5
}

extension Notification.Name {
    public static let organizationDidStart = Notification.Name("OrganizationDidStart")
    public static let organizationDidFinish = Notification.Name("OrganizationDidFinish")
    public static let organizationDidRevert = Notification.Name("OrganizationDidRevert")
    public static let forceQuitSorty = Notification.Name("ForceQuitSorty")

    /// Triggered when the user requests to delete all usage data
    public static let clearAllUsageData = Notification.Name("clearAllUsageData")
}




import SwiftUI
import AppKit

// MARK: - Haptic Feedback Manager

/// Manages haptic feedback for user interactions on macOS
@MainActor
public class HapticFeedbackManager {
    @MainActor
    public static let shared = HapticFeedbackManager()

    private init() {}

    /// Performs haptic feedback for button taps and general interactions
    public func tap() {
        performEmphasizedPulse()
    }

    /// Performs haptic feedback for successful actions
    public func success() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Performs haptic feedback for alignment or snapping
    public func alignment() {
        performLightAlignmentHaptic()
    }

    /// Performs haptic feedback for errors or warnings
    public func error() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Performs haptic feedback for selection changes
    public func selection() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    /// Performs a subtle light haptic for hover transitions and gentle state changes.
    public func light() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    /// Emits a short two-step pulse that is more perceptible than a single generic tap.
    private func performEmphasizedPulse() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    private func performLightAlignmentHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }
}

// MARK: - Haptic Sequence Manager

/// Plays timed haptic sequences that follow visual animations (e.g., shimmer left-to-right).
@MainActor
public final class HapticSequenceManager {
    public static let shared = HapticSequenceManager()
    private var activeTask: Task<Void, Never>?
    private var lastWaveStartAt: Date = .distantPast

    private init() {}

    /// Plays a left-to-right haptic wave whose cadence mirrors an ease-in-out shimmer.
    public func playShimmerWave(
        tapCount: Int = 5,
        duration: TimeInterval = 0.65,
        minimumInterval: TimeInterval = 0.2
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastWaveStartAt) >= minimumInterval else { return }
        lastWaveStartAt = now

        activeTask?.cancel()
        activeTask = Task { @MainActor in
            let clampedTapCount = max(tapCount, 2)
            var previousTimelinePhase = 0.0

            for i in 0..<clampedTapCount {
                guard !Task.isCancelled else { return }

                if i > 0 {
                    let spatialPhase = Double(i) / Double(clampedTapCount - 1)
                    let timelinePhase = easeInOutTimelinePhase(for: spatialPhase)
                    let delay = max(0, duration * (timelinePhase - previousTimelinePhase))
                    previousTimelinePhase = timelinePhase

                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }

                guard !Task.isCancelled else { return }

                let feedback: NSHapticFeedbackManager.FeedbackPattern =
                    i == clampedTapCount - 1 ? .levelChange : .alignment
                NSHapticFeedbackManager.defaultPerformer.perform(feedback, performanceTime: .now)
            }
        }
    }

    /// Inverts a smooth ease-in-out curve so evenly spaced haptic positions
    /// arrive slowly at each edge and more quickly through the center.
    private func easeInOutTimelinePhase(for spatialPhase: Double) -> Double {
        let clampedPhase = min(max(spatialPhase, 0), 1)
        return 0.5 - sin(asin(1 - 2 * clampedPhase) / 3)
    }

    /// Plays a single emphasis haptic for a notable UI event (new insight, popup appearing).
    public func playEventPulse() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }
}
