import Foundation

/// Encryption key access stays synchronous because profile encoding and file IO
/// already run on a worker. An unavailable Keychain must never mean no key.
public enum LearningsKeyStatus: Sendable {
    case found
    case notFound
    case unavailable
}

public protocol LearningsKeychainStore: Sendable {
    func get(key: String) -> String?
    func itemStatus(key: String) -> LearningsKeyStatus
    func save(key: String, value: String) -> Bool
    func delete(key: String) -> Bool
}

private struct UnavailableLearningsKeychainStore: LearningsKeychainStore {
    func get(key: String) -> String? { nil }
    func itemStatus(key: String) -> LearningsKeyStatus { .unavailable }
    func save(key: String, value: String) -> Bool { false }
    func delete(key: String) -> Bool { false }
}

/// The app installs its KeychainManager adapter before profile hydration.
public enum LearningsKeychain {
    nonisolated(unsafe) public static var shared: any LearningsKeychainStore =
        UnavailableLearningsKeychainStore()
}

/// Core-owned diagnostics and session locking used by the learning manager.
/// Defaults keep previews and isolated tests free of app service startup.
@MainActor
public enum LearningsRuntime {
    public static var reportError: (any Error, String, Bool) -> Void = { _, _, _ in }
    public static var reportProfileLoad: (String, TimeInterval) -> Void = { _, _ in }
    public static var lockSession: () -> Void = {}

    public static func capture(
        error: any Error,
        feature _: String,
        operation: String,
        recoverable: Bool = true
    ) {
        reportError(error, operation, recoverable)
    }
}
