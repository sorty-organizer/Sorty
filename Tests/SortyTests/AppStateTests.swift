//
//  AppStateTests.swift
//  SortyTests
//
//  Comprehensive tests for AppState and menu bar controls
//

import XCTest
import Combine
@testable import SortyLib

// MARK: - AppState Tests

@MainActor
class AppStateTests: XCTestCase {
    
    var appState: AppState!
    var organizer: FolderOrganizer!
    var testDefaults: UserDefaults!
    var testDefaultsSuiteName: String!
    private let requiresSetupRepairKey = "requiresSetupRepair"
    private let setupRepairMessageKey = "setupRepairMessage"
    
    override func setUp() async throws {
        testDefaultsSuiteName = "test.appstate.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: testDefaultsSuiteName)!
        testDefaults.removeObject(forKey: requiresSetupRepairKey)
        testDefaults.removeObject(forKey: setupRepairMessageKey)
        
        appState = AppState(userDefaults: testDefaults)
        organizer = FolderOrganizer()
        appState.organizer = organizer
    }
    
    override func tearDown() async throws {
        NotificationManager.shared.dismissHUD(identifier: "setup-repair")
        if let testDefaultsSuiteName {
            testDefaults.removePersistentDomain(forName: testDefaultsSuiteName)
        }

        testDefaults = nil
        testDefaultsSuiteName = nil
        appState = nil
        organizer = nil
    }
    
    // MARK: - Initialization Tests
    
    func testDefaultInitialization() {
        let freshState = AppState()
        
        XCTAssertEqual(freshState.currentView, .organize)
        XCTAssertTrue(freshState.showingSidebar)
        XCTAssertFalse(freshState.showDirectoryPicker)
        XCTAssertNil(freshState.selectedDirectory)
    }
    
    func testOnboardingPersistence() {
        let testSuiteName = "test.onboarding.persistence.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: testSuiteName)!
        let onboardingKey = "hasCompletedOnboarding"
        let versionKey = "lastLaunchedVersion"
        
        defer {
            userDefaults.removePersistentDomain(forName: testSuiteName)
        }
        
        // Simulate fresh install (no version stored, onboarding not completed)
        userDefaults.removeObject(forKey: onboardingKey)
        userDefaults.removeObject(forKey: versionKey)
        
        // Verify state
        XCTAssertFalse(userDefaults.bool(forKey: onboardingKey), "Fresh install should show onboarding")
        
        // Set onboarding completed
        userDefaults.set(true, forKey: onboardingKey)
        XCTAssertTrue(userDefaults.bool(forKey: onboardingKey))
        
        // Version should be manageable
        userDefaults.set("1.0.0", forKey: versionKey)
        XCTAssertNotNil(userDefaults.string(forKey: versionKey), "Version should be stored after first launch")
    }
    
    func testVersion120RequiresOnboardingOnceAfterUpdate() {
        let testSuiteName = "test.onboarding.updates.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: testSuiteName)!
        let onboardingKey = "hasCompletedOnboarding"
        let versionKey = "lastLaunchedVersion"
        
        defer {
            userDefaults.removePersistentDomain(forName: testSuiteName)
        }
        
        // Simulate an in-app update scenario for a user who completed onboarding.
        userDefaults.set("0.9.0", forKey: versionKey)
        userDefaults.set(true, forKey: onboardingKey)
        
        let state = AppState(userDefaults: userDefaults, currentVersion: "1.2.0")

        XCTAssertFalse(state.hasCompletedOnboarding)
        XCTAssertEqual(userDefaults.string(forKey: versionKey), "0.9.0")

        // The first window records the launched version after initialization.
        userDefaults.set("1.2.0", forKey: versionKey)
        state.recordOnboardingCompletion()
        let relaunchedState = AppState(userDefaults: userDefaults, currentVersion: "1.2.0")
        XCTAssertTrue(relaunchedState.hasCompletedOnboarding)
    }

    func testOnboardingShownWhenPreviousLaunchDidNotCompleteSetup() {
        let testSuiteName = "test.onboarding.incomplete.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: testSuiteName)!
        let onboardingKey = "hasCompletedOnboarding"
        let versionKey = "lastLaunchedVersion"

        defer {
            userDefaults.removePersistentDomain(forName: testSuiteName)
        }

        // A failed first launch can still write lastLaunchedVersion. That must
        // not make the next launch skip onboarding.
        userDefaults.set("nightly", forKey: versionKey)
        userDefaults.set(false, forKey: onboardingKey)

        let state = AppState(userDefaults: userDefaults)

        XCTAssertFalse(state.hasCompletedOnboarding)
        XCTAssertEqual(userDefaults.string(forKey: versionKey), "nightly")
    }
    
    func testOnboardingShownForFreshInstall() {
        let testSuiteName = "test.onboarding.fresh.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: testSuiteName)!
        let onboardingKey = "hasCompletedOnboarding"
        let versionKey = "lastLaunchedVersion"
        
        defer {
            userDefaults.removePersistentDomain(forName: testSuiteName)
        }
        
        // Simulate fresh install: no version, no onboarding completed
        userDefaults.removeObject(forKey: versionKey)
        userDefaults.removeObject(forKey: onboardingKey)
        
        let state = AppState(userDefaults: userDefaults)

        XCTAssertFalse(state.hasCompletedOnboarding, "Fresh install should show onboarding")
        XCTAssertNil(userDefaults.string(forKey: versionKey))
    }

    func testStartSetupRepairRoutesToProviderSettingsAndPersistsMessage() {
        appState.currentView = .history

        appState.startSetupRepair(
            message: "Provider setup is incomplete.",
            navigateToSettings: true
        )

        XCTAssertTrue(appState.requiresSetupRepair)
        XCTAssertEqual(appState.setupRepairMessage, "Provider setup is incomplete.")
        XCTAssertEqual(appState.currentView, .settings)
        XCTAssertEqual(appState.selectedSettingsSection, .provider)
        XCTAssertEqual(testDefaults.string(forKey: setupRepairMessageKey), "Provider setup is incomplete.")
    }

    func testClearSetupRepairStateRemovesPersistence() {
        appState.startSetupRepair(message: "Repair me.")

        appState.clearSetupRepairState()

        XCTAssertFalse(appState.requiresSetupRepair)
        XCTAssertNil(appState.setupRepairMessage)
        XCTAssertFalse(testDefaults.bool(forKey: requiresSetupRepairKey))
        XCTAssertNil(testDefaults.string(forKey: setupRepairMessageKey))
    }

    func testProviderSetupValidatorBlocksMissingAPIKey() {
        let config = AIConfig(
            provider: .openAICompatible,
            apiURL: "https://api.example.com",
            apiKey: nil,
            model: AIProvider.openAICompatible.defaultModel,
            requiresAPIKey: true
        )

        let status = OnboardingSetupValidator.providerStatus(
            context: ProviderSetupContext(
                config: config,
                isGitHubCopilotAuthenticated: false,
                isCodexAuthenticated: false,
                isCodexInstalled: false,
                isAppleFoundationModelAvailable: false
            )
        )

        XCTAssertFalse(status.isReady)
        XCTAssertEqual(status.title, "Credentials required")
        XCTAssertTrue(status.message.contains("API key"))
    }

    func testProviderSetupValidatorAllowsConfiguredOllama() {
        let config = AIConfig(
            provider: .ollama,
            apiURL: "http://localhost:11434",
            apiKey: nil,
            model: AIProvider.ollama.defaultModel,
            requiresAPIKey: false
        )

        let status = OnboardingSetupValidator.providerStatus(
            context: ProviderSetupContext(
                config: config,
                isGitHubCopilotAuthenticated: false,
                isCodexAuthenticated: false,
                isCodexInstalled: false,
                isAppleFoundationModelAvailable: false
            )
        )

        XCTAssertTrue(status.isReady)
    }

    func testProviderSetupValidatorRequiresCodexSignInForOpenAIAccountAuth() {
        var config = AIConfig(
            provider: .openAI,
            apiURL: AIProvider.openAI.defaultAPIURL,
            apiKey: nil,
            model: AIProvider.openAI.defaultModel,
            requiresAPIKey: true
        )
        config.setAuthMethod(.accountSignIn, for: .openAI)

        let status = OnboardingSetupValidator.providerStatus(
            context: ProviderSetupContext(
                config: config,
                isGitHubCopilotAuthenticated: false,
                isCodexAuthenticated: false,
                isCodexInstalled: true,
                isAppleFoundationModelAvailable: false
            )
        )

        XCTAssertFalse(status.isReady)
        XCTAssertTrue(status.message.contains("Codex CLI"))
    }
    
    // MARK: - View Navigation Tests
    
    func testAllAppViewCases() {
        let allViews: [AppState.AppView] = [
            .settings, .organize, .history,
            .duplicates, .exclusions, .watchedFolders, .learnings
        ]
        
        for view in allViews {
            appState.currentView = view
            XCTAssertEqual(appState.currentView, view)
        }
    }
    
    // MARK: - Sidebar Toggle Tests
    
    func testSidebarToggle() {
        XCTAssertTrue(appState.showingSidebar)
        
        appState.showingSidebar.toggle()
        XCTAssertFalse(appState.showingSidebar)
        
        appState.showingSidebar.toggle()
        XCTAssertTrue(appState.showingSidebar)
    }
    
    // MARK: - Directory Picker Tests
    
    func testDirectoryPickerToggle() {
        XCTAssertFalse(appState.showDirectoryPicker)
        
        appState.showDirectoryPicker = true
        XCTAssertTrue(appState.showDirectoryPicker)
    }
    
    func testSelectedDirectory() {
        XCTAssertNil(appState.selectedDirectory)
        
        let testURL = URL(fileURLWithPath: "/tmp/test")
        appState.selectedDirectory = testURL
        XCTAssertEqual(appState.selectedDirectory, testURL)
    }

    func testFilesAndFoldersPermissionPersistsSeparatelyFromSelectedDirectory() throws {
        let folder = URL(fileURLWithPath: "/tmp")

        guard appState.grantFilesAndFoldersPermission(for: folder) else {
            throw XCTSkip("The test host cannot create security-scoped bookmarks.")
        }
        XCTAssertTrue(appState.hasFilesAndFoldersPermission())

        appState.selectedDirectory = nil
        let relaunchedState = AppState(userDefaults: testDefaults)
        XCTAssertTrue(relaunchedState.hasFilesAndFoldersPermission())

        relaunchedState.revokeFilesAndFoldersPermission()
        XCTAssertFalse(relaunchedState.hasFilesAndFoldersPermission())
    }

    func testFilesAndFoldersPermissionRejectsAnUnreadableBookmark() {
        testDefaults.set(Data([0x00]), forKey: "filesAndFoldersPermissionBookmark")
        let state = AppState(userDefaults: testDefaults)

        XCTAssertFalse(state.hasFilesAndFoldersPermission())
        XCTAssertNil(testDefaults.data(forKey: "filesAndFoldersPermissionBookmark"))
    }
    
    // MARK: - Computed Properties Tests
    
    func testHasResultsWhenNoOrganizer() {
        appState.organizer = nil
        XCTAssertFalse(appState.hasResults)
    }
    
    func testHasResultsWhenNoPlan() {
        XCTAssertNil(organizer.currentPlan)
        XCTAssertFalse(appState.hasResults)
    }
    
    func testHasFilesWhenNoPlan() {
        XCTAssertNil(organizer.currentPlan)
        XCTAssertFalse(appState.hasFiles)
    }
    
    func testCanStartOrganizationRequiresDirectory() {
        appState.selectedDirectory = nil
        XCTAssertFalse(appState.canStartOrganization)
    }
    
    func testCanStartOrganizationWhenIdle() {
        appState.selectedDirectory = URL(fileURLWithPath: "/tmp")
        XCTAssertEqual(organizer.state, .idle)
        XCTAssertTrue(appState.canStartOrganization)
    }
    
    func testHasCurrentPlanWhenNoPlan() {
        XCTAssertNil(organizer.currentPlan)
        XCTAssertFalse(appState.hasCurrentPlan)
    }
    
    func testCanApplyWhenIdle() {
        XCTAssertEqual(organizer.state, .idle)
        XCTAssertFalse(appState.canApply)
    }
    
    func testIsOperationInProgressWhenIdle() {
        XCTAssertEqual(organizer.state, .idle)
        XCTAssertFalse(appState.isOperationInProgress)
    }
    
    func testIsOperationInProgressWhenNoOrganizer() {
        appState.organizer = nil
        XCTAssertFalse(appState.isOperationInProgress)
    }
    
    // MARK: - Action Methods Tests
    
    func testResetSessionClearsDirectory() {
        appState.selectedDirectory = URL(fileURLWithPath: "/tmp/test")
        
        appState.resetSession()
        
        XCTAssertNil(appState.selectedDirectory)
    }
    
    func testResetSessionWithNoOrganizer() {
        appState.organizer = nil
        appState.selectedDirectory = URL(fileURLWithPath: "/tmp/test")
        
        appState.resetSession()
        
        XCTAssertNil(appState.selectedDirectory)
    }
    
    func testCancelOperationResetsOrganizer() {
        appState.cancelOperation()
        XCTAssertEqual(organizer.state, .idle)
    }
    
    func testHandoffToDuplicatesCarriesNormalizedFilePaths() {
        let folder = URL(fileURLWithPath: "/tmp/handoff-folder")
        appState.currentView = .history
        appState.handoffToDuplicates(
            forFilePaths: [
                "/tmp/handoff-folder/a/../a/file1.txt",
                "/tmp/handoff-folder/a/file1.txt",
                "/tmp/handoff-folder/b/file2.txt"
            ],
            preferredDirectory: folder,
            autoStart: true
        )

        XCTAssertEqual(appState.currentView, .duplicates)
        XCTAssertEqual(appState.navigationReturnRoute?.destination, .duplicates)
        XCTAssertEqual(appState.navigationReturnRoute?.returnView, .history)
        XCTAssertEqual(appState.selectedDirectory, folder.standardizedFileURL)
        XCTAssertEqual(appState.pendingDuplicatesHandoff?.directory, folder.standardizedFileURL)
        XCTAssertEqual(
            appState.pendingDuplicatesHandoff?.filePaths ?? [],
            [
                "/tmp/handoff-folder/a/file1.txt",
                "/tmp/handoff-folder/b/file2.txt"
            ]
        )
    }

    func testHandoffToDuplicatesDirectoryOnlyHasNoFilePaths() {
        let folder = URL(fileURLWithPath: "/tmp/directory-only")
        appState.handoffToDuplicates(directory: folder, autoStart: false)

        XCTAssertEqual(appState.currentView, .duplicates)
        XCTAssertEqual(appState.pendingDuplicatesHandoff?.directory, folder.standardizedFileURL)
        XCTAssertEqual(appState.pendingDuplicatesHandoff?.filePaths ?? [], [])
    }
    
    // MARK: - Learnings Actions Tests
    
    func testShowLearningsStats() {
        let expectation = XCTestExpectation(description: "Notification received")
        
        let observer = NotificationCenter.default.addObserver(
            forName: .showLearningsStats,
            object: nil,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }
        
        appState.showLearningsStats()
        
        XCTAssertEqual(appState.currentView, .learnings)
        
        wait(for: [expectation], timeout: 2.0)
        NotificationCenter.default.removeObserver(observer)
    }
    
    func testPauseLearning() {
        let expectation = XCTestExpectation(description: "Notification received")
        
        let observer = NotificationCenter.default.addObserver(
            forName: .pauseLearning,
            object: nil,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }
        
        appState.pauseLearning()
        
        wait(for: [expectation], timeout: 2.0)
        NotificationCenter.default.removeObserver(observer)
    }
    
    func testExportLearningsProfile() {
        let expectation = XCTestExpectation(description: "Notification received")
        
        let observer = NotificationCenter.default.addObserver(
            forName: .exportLearningsProfile,
            object: nil,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }
        
        appState.exportLearningsProfile()
        
        XCTAssertEqual(appState.currentView, .learnings)
        
        wait(for: [expectation], timeout: 2.0)
        NotificationCenter.default.removeObserver(observer)
    }
    
    func testImportLearningsProfile() {
        let expectation = XCTestExpectation(description: "Notification received")
        
        let observer = NotificationCenter.default.addObserver(
            forName: .importLearningsProfile,
            object: nil,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }
        
        appState.importLearningsProfile()
        
        XCTAssertEqual(appState.currentView, .learnings)
        
        wait(for: [expectation], timeout: 2.0)
        NotificationCenter.default.removeObserver(observer)
    }
    
    func testUsageDataEraserRemovesOnlySortyOwnedData() throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory
            .appendingPathComponent("SortyUsageDataEraserTests-\(UUID().uuidString)", isDirectory: true)
        let appSupport = sandbox.appendingPathComponent("Application Support", isDirectory: true)
        let caches = sandbox.appendingPathComponent("Caches", isDirectory: true)
        let temporary = sandbox.appendingPathComponent("Temporary", isDirectory: true)
        let appGroup = sandbox.appendingPathComponent("App Group", isDirectory: true)
        let unrelatedTemporaryFile = temporary.appendingPathComponent("unrelated.txt")

        defer {
            try? fileManager.removeItem(at: sandbox)
        }

        let ownedItems = [
            appSupport.appendingPathComponent("Sorty/Learnings/profile.learning"),
            appSupport.appendingPathComponent("com.sorty.app/Logs/sorty.log"),
            caches.appendingPathComponent("Sorty/VisionCache/image.jpg"),
            caches.appendingPathComponent("com.sorty.app/content-metadata-cache.json"),
            temporary.appendingPathComponent("sorty-codex-request.txt"),
            temporary.appendingPathComponent("SortyNotificationIcon-test.png"),
            appGroup.appendingPathComponent("Widget/overview-snapshot.json")
        ]

        for item in ownedItems + [unrelatedTemporaryFile] {
            try fileManager.createDirectory(
                at: item.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("test".utf8).write(to: item)
        }

        let failures = SortyUsageDataEraser.erase(
            fileManager: fileManager,
            bundleIdentifier: "com.sorty.app",
            locations: .init(
                applicationSupportDirectory: appSupport,
                cachesDirectory: caches,
                temporaryDirectory: temporary,
                appGroupContainer: appGroup
            )
        )

        XCTAssertTrue(failures.isEmpty)
        for item in ownedItems {
            XCTAssertFalse(fileManager.fileExists(atPath: item.path))
        }
        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedTemporaryFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: appGroup.path))
    }
    
    // MARK: - Edge Cases
    
    func testWeakOrganizerReference() {
        var localOrganizer: FolderOrganizer? = FolderOrganizer()
        appState.organizer = localOrganizer
        
        XCTAssertNotNil(appState.organizer)
        
        localOrganizer = nil
        
        XCTAssertNil(appState.organizer)
    }
    
    func testComputedPropertiesWithNilOrganizer() {
        appState.organizer = nil
        
        XCTAssertFalse(appState.hasResults)
        XCTAssertFalse(appState.hasFiles)
        XCTAssertFalse(appState.canStartOrganization)
        XCTAssertFalse(appState.hasCurrentPlan)
        XCTAssertFalse(appState.canApply)
        XCTAssertFalse(appState.isOperationInProgress)
    }
    
    func testMultipleViewChanges() {
        let views: [AppState.AppView] = [.organize, .settings, .history, .duplicates, .learnings]
        
        for view in views {
            appState.currentView = view
        }
        
        XCTAssertEqual(appState.currentView, .learnings)
    }
    
    // MARK: - Calibrate Action Tests
    
    func testCalibrateActionProperty() {
        XCTAssertNil(appState.calibrateAction)
        
        appState.calibrateAction = { _ in }
        
        XCTAssertNotNil(appState.calibrateAction)
    }
    
    // MARK: - Sparkle Update Manager Tests
    
    func testUpdateManagerExists() {
        XCTAssertNotNil(appState.updateManager)
    }

    func testVersionHistoryLinkTargetsInstalledReleaseSection() {
        XCTAssertEqual(
            SparkleVersionHistoryLink.url(for: "1.2.0").absoluteString,
            "https://sorty-organizer.github.io/Sorty/changelog/#version-1-2-0"
        )
    }

    func testVersionHistoryLinkFallsBackToChangelog() {
        XCTAssertEqual(
            SparkleVersionHistoryLink.url(for: nil).absoluteString,
            "https://sorty-organizer.github.io/Sorty/changelog/"
        )
    }

    func testMultipleAppStatesKeepIndependentSelections() {
        let stateA = AppState()
        let stateB = AppState()
        stateA.selectedDirectory = URL(fileURLWithPath: "/tmp/a")
        stateB.selectedDirectory = URL(fileURLWithPath: "/tmp/b")

        XCTAssertEqual(stateA.selectedDirectory?.path, "/tmp/a")
        XCTAssertEqual(stateB.selectedDirectory?.path, "/tmp/b")
    }

    func testCancelOperationDoesNotAffectOtherWindowOrganizer() {
        let stateA = AppState()
        let stateB = AppState()
        let organizerA = FolderOrganizer()
        let organizerB = FolderOrganizer()
        stateA.organizer = organizerA
        stateB.organizer = organizerB

        organizerA.state = .organizing
        organizerB.state = .organizing

        stateA.cancelOperation()

        XCTAssertEqual(organizerA.state, .idle)
        XCTAssertEqual(organizerB.state, .organizing)
    }
}

// MARK: - SortyCommands Tests

@MainActor
class SortyCommandsTests: XCTestCase {

    func testSortyCommandsInitialization() {
        let commands = SortyCommands()
        XCTAssertNotNil(commands)
    }
}

// MARK: - OrganizationState Tests

class OrganizationStateTests: XCTestCase {
    
    func testErrorStateEquality() {
        let error1 = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Error"])
        let error2 = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Error"])
        let error3 = NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Different"])
        
        XCTAssertEqual(OrganizationState.error(error1), OrganizationState.error(error2))
        XCTAssertNotEqual(OrganizationState.error(error1), OrganizationState.error(error3))
    }
    
    func testErrorStateNotEqualToOtherStates() {
        let error = NSError(domain: "test", code: 1, userInfo: nil)
        
        XCTAssertNotEqual(OrganizationState.error(error), OrganizationState.idle)
        XCTAssertNotEqual(OrganizationState.error(error), OrganizationState.completed)
    }
    
}

// MARK: - Notification Names Tests

class NotificationNamesTests: XCTestCase {
    
    func testNotificationNamesAreUnique() {
        let names: [Notification.Name] = [
            .showLearningsStats,
            .pauseLearning,
            .exportLearningsProfile,
            .importLearningsProfile,
            .organizationDidStart,
            .organizationDidFinish,
            .organizationDidRevert
        ]
        
        let uniqueNames = Set(names)
        XCTAssertEqual(names.count, uniqueNames.count)
    }
}
