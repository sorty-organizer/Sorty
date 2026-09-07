import XCTest
@testable import SortyLib

/// Focused startup hydration and bookmark-restore races.
/// Covers: deferred exclusion loads, early-mutation preservation, reset invalidation,
/// and balanced bookmark-less restores. No launch-time claims.
final class StartupHydrationTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    @MainActor
    func testExclusionInitDoesNotHydrateSynchronously() throws {
        let suiteName = "StartupHydrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let seeded = ExclusionRule(type: .folderName, pattern: "SeededPersisted")
        defaults.set(try JSONEncoder().encode([seeded]), forKey: "exclusionRules")

        let startedAt = CFAbsoluteTimeGetCurrent()
        let manager = ExclusionRulesManager(userDefaults: defaults)
        let initDuration = CFAbsoluteTimeGetCurrent() - startedAt

        XCTAssertFalse(manager.hasLoadedPersistedState)
        XCTAssertTrue(manager.rules.isEmpty)
        XCTAssertLessThan(initDuration, 0.05, "Exclusion construction must not decode persisted state.")
    }

    @MainActor
    func testExclusionEarlyAddPreservedThroughHydration() async throws {
        let suiteName = "StartupHydrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persisted = ExclusionRule(type: .folderName, pattern: "PersistedFolder")
        defaults.set(try JSONEncoder().encode([persisted]), forKey: "exclusionRules")

        let manager = ExclusionRulesManager(userDefaults: defaults)
        manager.addRule(ExclusionRule(type: .fileExtension, pattern: "tmp"))

        await manager.loadPersistedState()

        XCTAssertTrue(manager.hasLoadedPersistedState)
        XCTAssertTrue(manager.rules.contains { $0.pattern == "PersistedFolder" })
        XCTAssertTrue(manager.rules.contains { $0.pattern == "tmp" })
    }

    @MainActor
    func testExclusionResetBeforeHydrationDoesNotRestorePersisted() async throws {
        let suiteName = "StartupHydrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persisted = ExclusionRule(type: .folderName, pattern: "MustNotReturn")
        defaults.set(try JSONEncoder().encode([persisted]), forKey: "exclusionRules")

        let manager = ExclusionRulesManager(userDefaults: defaults)
        manager.clearAllRules()
        await manager.loadPersistedState()

        XCTAssertTrue(manager.hasLoadedPersistedState)
        XCTAssertFalse(manager.rules.contains { $0.pattern == "MustNotReturn" })
        XCTAssertTrue(manager.rules.isEmpty)
    }

    @MainActor
    func testExclusionClearEverythingRestoresDefaultsNotPersistedCustom() async throws {
        let suiteName = "StartupHydrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let custom = ExclusionRule(type: .folderName, pattern: "CustomOnly")
        defaults.set(try JSONEncoder().encode([custom]), forKey: "exclusionRules")

        let manager = ExclusionRulesManager(userDefaults: defaults)
        await manager.loadPersistedState()
        XCTAssertTrue(manager.rules.contains { $0.pattern == "CustomOnly" })

        manager.clearEverything()

        XCTAssertFalse(manager.rules.contains { $0.pattern == "CustomOnly" })
        XCTAssertTrue(manager.rules.contains { $0.pattern == "node_modules" })
    }

    @MainActor
    func testStorageBookmarklessRestoreMarksValidThenLost() async throws {
        let manager = StorageLocationsManager()
        manager.clearAll()
        defer { manager.clearAll() }
        await manager.loadPersistedState()

        let dir = tempRoot.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        manager.addLocation(StorageLocation(path: dir.path, name: "Archive"))

        await manager.refreshAccessStatus()
        XCTAssertEqual(manager.locations.first?.accessStatus, .valid)

        try FileManager.default.removeItem(at: dir)
        await manager.refreshAccessStatus()
        XCTAssertEqual(manager.locations.first?.accessStatus, .lost)
    }

    @MainActor
    func testWatchedRestoreWithoutBookmarksLeavesFoldersUsable() async {
        let manager = WatchedFoldersManager()
        manager.clearAll()
        defer { manager.clearAll() }
        await manager.loadPersistedState()

        manager.addFolder(WatchedFolder(path: tempRoot.path))
        await manager.restoreSecurityScopedAccess()

        XCTAssertEqual(manager.folders.count, 1)
        XCTAssertEqual(manager.accessIssueFolderCount, 0)
    }

    @MainActor
    func testWatchedRemoveDuringRestoreDiscardsStaleResult() async {
        let manager = WatchedFoldersManager()
        manager.clearAll()
        defer { manager.clearAll() }
        await manager.loadPersistedState()

        let folder = WatchedFolder(path: tempRoot.path)
        manager.addFolder(folder)
        manager.removeFolder(folder)

        await manager.restoreSecurityScopedAccess()

        XCTAssertTrue(manager.folders.isEmpty)
        XCTAssertEqual(manager.accessIssueFolderCount, 0)
    }

    @MainActor
    func testPersonaInitDoesNotHydrateSynchronously() throws {
        let suiteName = "StartupHydrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(PersonaType.developer.rawValue, forKey: "selectedPersona")

        let startedAt = CFAbsoluteTimeGetCurrent()
        let manager = PersonaManager(userDefaults: defaults)
        let initDuration = CFAbsoluteTimeGetCurrent() - startedAt

        XCTAssertFalse(manager.hasLoadedPersistedState)
        XCTAssertEqual(manager.selectedPersona, .general)
        XCTAssertLessThan(initDuration, 0.05, "Persona construction must not read persisted state.")
    }

    @MainActor
    func testPersonaEarlySelectionWinsOverPersisted() async throws {
        let suiteName = "StartupHydrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(PersonaType.developer.rawValue, forKey: "selectedPersona")

        let manager = PersonaManager(userDefaults: defaults)
        manager.selectPersona(.photographer)
        await manager.loadPersistedState()

        XCTAssertTrue(manager.hasLoadedPersistedState)
        XCTAssertEqual(manager.selectedPersona, .photographer)
    }

    @MainActor
    func testPersonaResetBeforeHydrationDoesNotRestorePersisted() async throws {
        let suiteName = "StartupHydrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(PersonaType.office.rawValue, forKey: "selectedPersona")

        let manager = PersonaManager(userDefaults: defaults)
        manager.reset()
        await manager.loadPersistedState()

        XCTAssertTrue(manager.hasLoadedPersistedState)
        XCTAssertEqual(manager.selectedPersona, .general)
    }

    @MainActor
    func testCustomPersonaEarlyAddPreservedThroughHydration() async throws {
        let suiteName = "StartupHydrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persisted = CustomPersona(name: "Persisted", promptModifier: "persisted prompt")
        defaults.set(try JSONEncoder().encode([persisted]), forKey: "customPersonas")

        let store = CustomPersonaStore(userDefaults: defaults)
        store.addPersona(CustomPersona(name: "Early", promptModifier: "early prompt"))
        await store.loadPersistedState()

        XCTAssertTrue(store.hasLoadedPersistedState)
        XCTAssertTrue(store.customPersonas.contains { $0.name == "Persisted" })
        XCTAssertTrue(store.customPersonas.contains { $0.name == "Early" })
    }

    @MainActor
    func testCustomPersonaClearBeforeHydrationDoesNotRestore() async throws {
        let suiteName = "StartupHydrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persisted = CustomPersona(name: "MustNotReturn", promptModifier: "x")
        defaults.set(try JSONEncoder().encode([persisted]), forKey: "customPersonas")

        let store = CustomPersonaStore(userDefaults: defaults)
        store.clearAll()
        await store.loadPersistedState()

        XCTAssertTrue(store.hasLoadedPersistedState)
        XCTAssertTrue(store.customPersonas.isEmpty)
    }

    @MainActor
    func testNamingPresetEarlyAddPreservedThroughHydration() async throws {
        let suiteName = "StartupHydrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persisted = NamingPreset(name: "Persisted", instructions: "persisted instructions")
        defaults.set(try JSONEncoder().encode([persisted]), forKey: "sorty.namingPresets")

        let manager = NamingPresetManager(userDefaults: defaults)
        manager.addPreset(NamingPreset(name: "Early", instructions: "early instructions"))
        await manager.loadPersistedState()

        XCTAssertTrue(manager.hasLoadedPersistedState)
        XCTAssertTrue(manager.customPresets.contains { $0.name == "Persisted" })
        XCTAssertTrue(manager.customPresets.contains { $0.name == "Early" })
    }

    @MainActor
    func testSteeringPromptEarlyAddPreservedThroughHydration() async throws {
        let suiteName = "StartupHydrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persisted = SavedSteeringPrompt(name: "Persisted", prompt: "persisted prompt")
        defaults.set(try JSONEncoder().encode([persisted]), forKey: "sorty.steeringPrompts")

        let manager = SteeringPromptManager(userDefaults: defaults)
        XCTAssertTrue(manager.addPrompt(SavedSteeringPrompt(name: "Early", prompt: "early prompt")))
        await manager.loadPersistedState()

        XCTAssertTrue(manager.hasLoadedPersistedState)
        XCTAssertTrue(manager.prompts.contains { $0.name == "Persisted" })
        XCTAssertTrue(manager.prompts.contains { $0.name == "Early" })
    }

    @MainActor
    func testLearningsEarlyDirectoryAddPreservedThroughHydration() async throws {
        let suiteName = "StartupHydrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persisted = ReferenceModelDirectory(path: "/tmp/persisted-reference")
        defaults.set(
            try JSONEncoder().encode([persisted]),
            forKey: "learningsModelDirectories"
        )

        let manager = LearningsManager(userDefaults: defaults)
        XCTAssertTrue(manager.addModelDirectory(path: "/tmp/early-reference"))
        await manager.loadPersistedState()

        XCTAssertTrue(manager.modelDirectories.contains { $0.path == persisted.path })
        XCTAssertTrue(manager.modelDirectories.contains { $0.path == "/tmp/early-reference" })
    }
}
