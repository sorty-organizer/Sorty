import Foundation
import SortyLearnings

/// Connects the learning target to app services after the first window yields.
public enum LiveLearningsServices {
    @MainActor public static func configure() {
        LearningsKeychain.shared = LiveLearningsKeychainStore()
        LearningsRuntime.reportError = { error, operation, recoverable in
            ReliabilityManager.shared.capture(
                error: error,
                feature: "learnings",
                operation: operation,
                recoverable: recoverable
            )
        }
        LearningsRuntime.reportProfileLoad = { outcome, duration in
            AnalyticsManager.shared.captureWorkflow(
                workflow: "learnings_profile",
                stage: "loaded",
                outcome: outcome,
                properties: AnalyticsManager.durationProperties(duration)
            )
        }
        LearningsRuntime.lockSession = { SecurityManager.shared.lock() }
    }
}

public struct LiveLearningsKeychainStore: LearningsKeychainStore {
    public init() {}

    public func get(key: String) -> String? { KeychainManager.get(key: key) }

    public func itemStatus(key: String) -> LearningsKeyStatus {
        switch KeychainManager.itemStatus(key: key) {
        case .found: .found
        case .notFound: .notFound
        case .unavailable: .unavailable
        }
    }

    public func save(key: String, value: String) -> Bool {
        KeychainManager.save(key: key, value: value)
    }

    public func delete(key: String) -> Bool { KeychainManager.delete(key: key) }
}
