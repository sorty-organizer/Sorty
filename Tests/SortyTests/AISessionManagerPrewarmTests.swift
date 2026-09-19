import Foundation
import XCTest
@testable import SortyLib

/// Covers the stale ready-screen error: fixing the config (e.g. adding the
/// missing API key) must clear the previous prewarm verdict immediately
/// instead of leaving it visible until the next prewarm finishes.
@MainActor
final class AISessionManagerPrewarmTests: XCTestCase {
    override func tearDown() async throws {
        AISessionManager.shared.setPrewarmStateForTesting(isPrewarmed: false, error: nil)
        try await super.tearDown()
    }

    func testResetPrewarmStateClearsStaleError() {
        AISessionManager.shared.setPrewarmStateForTesting(
            isPrewarmed: false,
            error: "Could not establish connection to OpenAI"
        )

        AISessionManager.shared.resetPrewarmState(for: .openAI)

        XCTAssertNil(AISessionManager.shared.prewarmError)
        XCTAssertFalse(AISessionManager.shared.isPrewarmed)
    }

    func testConfigChangeClearsStalePrewarmErrorSynchronously() async throws {
        let suiteName = "AISessionManagerPrewarmTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewModel = SettingsViewModel(
            userDefaults: defaults,
            credentialStore: SettingsCredentialStore(
                load: { _ in nil },
                save: { _, _ in true },
                saveImmediately: { _, _ in true },
                delete: { _ in true }
            ),
            observesNotifications: false
        )
        AISessionManager.shared.setPrewarmStateForTesting(
            isPrewarmed: false,
            error: "Could not establish connection to OpenAI"
        )

        // Same-provider credential-URL change performs no background network
        // work, so the assertion below observes only the synchronous reset.
        viewModel.config.apiURL = "https://example.com/v1"

        XCTAssertNil(
            AISessionManager.shared.prewarmError,
            "Fixing the config must clear the stale prewarm error immediately, not after the next prewarm."
        )
    }
}
