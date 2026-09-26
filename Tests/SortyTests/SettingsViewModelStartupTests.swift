import Foundation
import XCTest
@testable import SortyLib

@MainActor
final class SettingsViewModelStartupTests: XCTestCase {
    func testInitializationDoesNotWaitForPersistedStateOrCredentialLookup() async throws {
        let suiteName = "SettingsViewModelStartupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var storedConfig = AIConfig.default
        storedConfig.model = "startup-test-model"
        defaults.set(try JSONEncoder().encode(storedConfig), forKey: "aiConfig")

        let slowCredentialStore = SettingsCredentialStore(
            load: { _ in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            },
            save: { _, _ in true },
            saveImmediately: { _, _ in true },
            delete: { _ in true }
        )

        let startedAt = CFAbsoluteTimeGetCurrent()
        let viewModel = SettingsViewModel(
            userDefaults: defaults,
            credentialStore: slowCredentialStore,
            observesNotifications: false
        )
        let initializationDuration = CFAbsoluteTimeGetCurrent() - startedAt

        XCTAssertFalse(viewModel.hasLoadedPersistedState)
        XCTAssertLessThan(
            initializationDuration,
            0.05,
            "Settings construction must not read persisted state or wait for Security.framework."
        )

        await viewModel.loadPersistedState()

        XCTAssertTrue(viewModel.hasLoadedPersistedState)
        XCTAssertEqual(viewModel.config.model, "startup-test-model")
    }

    func testPersistedFileTaggingPreferenceIsPreservedDuringStartup() async throws {
        let suiteName = "SettingsViewModelStartupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var storedConfig = AIConfig.default
        storedConfig.enableFileTagging = false
        defaults.set(try JSONEncoder().encode(storedConfig), forKey: "aiConfig")

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

        await viewModel.loadPersistedState()

        XCTAssertFalse(viewModel.config.enableFileTagging)
    }

    func testResetBeforeHydrationDoesNotRestorePersistedConfiguration() async throws {
        let suiteName = "SettingsViewModelStartupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var persistedConfig = AIConfig.default
        persistedConfig.model = "must-not-return"
        defaults.set(try JSONEncoder().encode(persistedConfig), forKey: "aiConfig")

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
        viewModel.reset()
        await viewModel.loadPersistedState()

        XCTAssertTrue(viewModel.hasLoadedPersistedState)
        XCTAssertEqual(viewModel.config.model, AIConfig.default.model)
    }

    func testSwitchingToProviderWithoutAPIKeyDoesNotHydrateStoredCredential() async throws {
        let suiteName = "SettingsViewModelStartupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storedConfig = AIConfig(
            provider: .openRouter,
            model: AIProvider.openRouter.defaultModel
        )
        defaults.set(try JSONEncoder().encode(storedConfig), forKey: "aiConfig")

        let credentialStore = SettingsCredentialStore(
            load: { _ in "stale-credential" },
            save: { _, _ in true },
            saveImmediately: { _, _ in true },
            delete: { _ in true }
        )
        let viewModel = SettingsViewModel(
            userDefaults: defaults,
            credentialStore: credentialStore,
            observesNotifications: false
        )
        await viewModel.loadPersistedState()

        viewModel.config.apiKey = "openrouter-secret"
        viewModel.config.provider = .ollama
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(viewModel.config.provider, .ollama)
        XCTAssertNil(viewModel.config.apiKey)
    }

    func testUpdatingAPIKeyPersistsBeforeReturning() async throws {
        let suiteName = "SettingsViewModelStartupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var storedConfig = AIConfig.default
        storedConfig.provider = .openRouter
        defaults.set(try JSONEncoder().encode(storedConfig), forKey: "aiConfig")

        let recorder = ImmediateCredentialSaveRecorder()
        let credentialStore = SettingsCredentialStore(
            load: { _ in nil },
            save: { _, _ in true },
            saveImmediately: { key, value in
                recorder.record(key: key, value: value)
                return true
            },
            delete: { _ in true }
        )
        let viewModel = SettingsViewModel(
            userDefaults: defaults,
            credentialStore: credentialStore,
            observesNotifications: false
        )
        await viewModel.loadPersistedState()

        viewModel.updateAPIKey("openrouter-secret")

        XCTAssertEqual(recorder.savedKey, AIProvider.openRouter.keychainKey)
        XCTAssertEqual(recorder.savedValue, "openrouter-secret")
    }

    func testForceSavePersistsCredentialBeforeReturning() async throws {
        let suiteName = "SettingsViewModelStartupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var storedConfig = AIConfig.default
        storedConfig.provider = .openRouter
        defaults.set(try JSONEncoder().encode(storedConfig), forKey: "aiConfig")

        let recorder = ImmediateCredentialSaveRecorder()
        let credentialStore = SettingsCredentialStore(
            load: { _ in nil },
            save: { _, _ in true },
            saveImmediately: { key, value in
                recorder.record(key: key, value: value)
                return true
            },
            delete: { _ in true }
        )
        let viewModel = SettingsViewModel(
            userDefaults: defaults,
            credentialStore: credentialStore,
            observesNotifications: false
        )
        await viewModel.loadPersistedState()
        viewModel.config.apiKey = "openrouter-secret"

        viewModel.forceSave()

        XCTAssertEqual(recorder.savedKey, AIProvider.openRouter.keychainKey)
        XCTAssertEqual(recorder.savedValue, "openrouter-secret")
    }

    func testStartupSaveDoesNotDeleteCredentialBeforeHydrationCompletes() async throws {
        let suiteName = "SettingsViewModelStartupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var storedConfig = AIConfig.default
        storedConfig.provider = .openRouter
        storedConfig.model = AIProvider.openRouter.defaultModel
        defaults.set(try JSONEncoder().encode(storedConfig), forKey: "aiConfig")

        let recorder = StartupCredentialStoreRecorder()
        let credentialStore = SettingsCredentialStore(
            load: { key in
                if key == "apiKey" {
                    return nil
                }
                try? await Task.sleep(for: .milliseconds(800))
                return "persisted-openrouter-key"
            },
            save: { key, value in
                await recorder.recordSave(key: key, value: value)
                return true
            },
            saveImmediately: { _, _ in true },
            delete: { key in
                await recorder.recordDelete(key: key)
                return true
            }
        )
        let viewModel = SettingsViewModel(
            userDefaults: defaults,
            credentialStore: credentialStore,
            observesNotifications: false
        )
        await viewModel.loadPersistedState()

        XCTAssertTrue(viewModel.isConfiguredCredentialHydrating)
        viewModel.config.enableReasoning.toggle()
        try await Task.sleep(for: .milliseconds(600))

        let deletedBeforeHydration = await recorder.deletedKeys()
        XCTAssertEqual(deletedBeforeHydration, [])

        try await Task.sleep(for: .milliseconds(300))
        let deletedAfterHydration = await recorder.deletedKeys()
        XCTAssertEqual(viewModel.config.apiKey, "persisted-openrouter-key")
        XCTAssertFalse(viewModel.isConfiguredCredentialHydrating)
        XCTAssertEqual(deletedAfterHydration, [])
    }
}

@MainActor
private final class ImmediateCredentialSaveRecorder {
    private(set) var savedKey: String?
    private(set) var savedValue: String?

    func record(key: String, value: String) {
        savedKey = key
        savedValue = value
    }
}

private actor StartupCredentialStoreRecorder {
    private var saves: [(key: String, value: String)] = []
    private var deletes: [String] = []

    func recordSave(key: String, value: String) {
        saves.append((key, value))
    }

    func recordDelete(key: String) {
        deletes.append(key)
    }

    func deletedKeys() -> [String] {
        deletes
    }
}
