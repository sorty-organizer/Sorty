import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Only this small label observes the clock. A running operation has no
/// countdown, so it keeps its status without requesting periodic wakeups.
struct WatchedFolderActivityLabel: View {
    let activity: WatchedFolderActivity
    @ObservedObject private var ticker = WatchedFoldersTicker.shared
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isWindowVisible = false
    @State private var holdsTickerDemand = false

    private var needsTicks: Bool {
        switch activity {
        case .waitingForStability, .queued, .retrying: true
        default: false
        }
    }

    private var shouldTick: Bool {
        needsTicks && isWindowVisible && controlActiveState != .inactive
    }

    var body: some View {
        let status = activityText(activity, now: ticker.now)
        Label {
            Text(status)
                .numericTextTransition(animationValue: status)
        } icon: {
            Image(systemName: activityIcon(activity))
        }
        .foregroundStyle(activityColor(activity))
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .onAppear { updateTickerDemand() }
        .onChange(of: shouldTick) { _, _ in updateTickerDemand() }
        .onDisappear { releaseTickerDemand() }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    private func updateTickerDemand() {
        if shouldTick {
            guard !holdsTickerDemand else { return }
            holdsTickerDemand = true
            ticker.start()
        } else {
            releaseTickerDemand()
        }
    }

    private func releaseTickerDemand() {
        guard holdsTickerDemand else { return }
        holdsTickerDemand = false
        ticker.stop()
    }

    private func activityText(_ activity: WatchedFolderActivity, now: Date) -> String {
        switch activity {
        case .waitingForStability(let count, let date):
            return "\(count) waiting for stability · \(countdown(to: date, from: now))"
        case .queued(let count, let date):
            return "\(count) queued · \(countdown(to: date, from: now))"
        case .retrying(let count, let attempt, let date):
            return "\(count) retrying (attempt \(attempt)) · \(countdown(to: date, from: now))"
        case .parked(let count):
            return "\(count) file\(count == 1 ? "" : "s") couldn’t be organized"
        case .running(let count):
            return "Organizing \(count) file\(count == 1 ? "" : "s")"
        case .awaitingReview(let count):
            return "\(count) file\(count == 1 ? "" : "s") ready to review"
        }
    }

    /// Activity dates come from persisted state (and from retry scheduling), so
    /// they can be corrupt by the time they reach the UI. Clamp the interval to
    /// a day before converting to `Int`, which would otherwise trap on values
    /// outside `Int`'s range or on a non-finite subtraction result.
    private static let maxCountdownSeconds: TimeInterval = 86_400

    private func countdown(to date: Date, from now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval.isFinite else { return "starting now" }
        let clamped = min(max(interval, 0), Self.maxCountdownSeconds)
        let seconds = Int(clamped.rounded(.up))
        return seconds == 0 ? "starting now" : "in \(seconds)s"
    }

    private func activityIcon(_ activity: WatchedFolderActivity) -> String {
        switch activity {
        case .waitingForStability: "hourglass"
        case .queued: "tray.full"
        case .retrying: "arrow.clockwise"
        case .parked: "exclamationmark.circle"
        case .running: "arrow.triangle.2.circlepath"
        case .awaitingReview: "eye"
        }
    }

    private func activityColor(_ activity: WatchedFolderActivity) -> Color {
        switch activity {
        case .parked: .red
        case .retrying: .orange
        case .running, .awaitingReview: .blue
        case .waitingForStability, .queued: .secondary
        }
    }
}
