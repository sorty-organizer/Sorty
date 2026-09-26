import Foundation

public enum LearningExclusionReviewTarget: String, Codable, Sendable {
    case instructions
    case persona
    case watchedFolder
}

public struct LearningExclusionConcern: Equatable, Sendable {
    public let excludedRunCount: Int
    public let evaluatedRunCount: Int
    public let reviewTarget: LearningExclusionReviewTarget
}

public enum ReferenceDirectoryScanState: Equatable, Sendable {
    case scanning
    case ready
    case warning(String)
    case failed(String)
    case unavailable
    case paused
}

enum ReferenceDirectoryAddResult: Equatable {
    case added
    case duplicate
    case activeLimitReached
}

struct ReferenceDirectorySelection: Equatable, Sendable {
    let directoryIDs: [String]
    let reason: String
    let context: String
}

@MainActor
public final class LearningExclusionMonitor {
    private struct Event: Codable {
        let timestamp: Date
        let wasExcluded: Bool
        let reviewTarget: LearningExclusionReviewTarget
    }

    public static let shared = LearningExclusionMonitor()

    private let userDefaults: UserDefaults
    private let eventsKey = "learningToolDecisionEvents"
    private let lastAlertKey = "learningToolDecisionLastAlert"

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func recordDecision(
        wasExcluded: Bool,
        reviewTarget: LearningExclusionReviewTarget,
        now: Date = Date()
    ) -> LearningExclusionConcern? {
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        var events = loadEvents()
            .filter { $0.timestamp >= cutoff }
        events.append(
            Event(
                timestamp: now,
                wasExcluded: wasExcluded,
                reviewTarget: reviewTarget
            )
        )
        events = Array(events.suffix(20))
        saveEvents(events)

        let evaluated = Array(events.suffix(10))
        let excluded = evaluated.filter(\.wasExcluded)
        guard evaluated.count >= 5,
              excluded.count >= 3,
              Double(excluded.count) / Double(evaluated.count) >= 0.3 else { return nil }

        if let lastAlert = userDefaults.object(forKey: lastAlertKey) as? Date,
           now.timeIntervalSince(lastAlert) < 7 * 24 * 60 * 60 {
            return nil
        }

        userDefaults.set(now, forKey: lastAlertKey)
        let target = Dictionary(grouping: excluded, by: \.reviewTarget)
            .max { $0.value.count < $1.value.count }?
            .key ?? reviewTarget
        return LearningExclusionConcern(
            excludedRunCount: excluded.count,
            evaluatedRunCount: evaluated.count,
            reviewTarget: target
        )
    }

    private func loadEvents() -> [Event] {
        guard let data = userDefaults.data(forKey: eventsKey) else { return [] }
        return (try? JSONDecoder().decode([Event].self, from: data)) ?? []
    }

    private func saveEvents(_ events: [Event]) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        userDefaults.set(data, forKey: eventsKey)
    }
}
