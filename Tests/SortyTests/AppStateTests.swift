//
//  AppStateTests.swift
//  SortyTests
//
//  Comprehensive tests for AppState and menu bar controls
//

import XCTest
import Combine
@testable import SortyOrganizer
@testable import SortyLib
@testable import SortyCore
@testable import SortyLearnings

// MARK: - AppState Tests

@MainActor
class AppStateTests: XCTestCase {
    private final class ExportSpyLearningsManager: LearningsManager {
        var exportDestination: URL?

        override func exportProfile(to url: URL) throws -> LearningsProfileArchiveSummary {
            exportDestination = url
            return try super.exportProfile(to: url)
        }
    }
    
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

    func testProviderSetupValidatorTable() {
        var codexConfig = AIConfig(
            provider: .openAI,
            apiURL: AIProvider.openAI.defaultAPIURL,
            apiKey: nil,
            model: AIProvider.openAI.defaultModel,
            requiresAPIKey: true
        )
        codexConfig.setAuthMethod(.accountSignIn, for: .openAI)

        let cases: [(
            name: String,
            config: AIConfig,
            isCodexAuthenticated: Bool,
            isCodexInstalled: Bool,
            isReady: Bool,
            title: String?,
            messageContains: String?
        )] = [
            (
                "missingAPIKey",
                AIConfig(
                    provider: .openAICompatible,
                    apiURL: "https://api.example.com",
                    apiKey: nil,
                    model: AIProvider.openAICompatible.defaultModel,
                    requiresAPIKey: true
                ),
                false, false, false,
                "Credentials required", "API key"
            ),
            (
                "configuredOllama",
                AIConfig(
                    provider: .ollama,
                    apiURL: "http://localhost:11434",
                    apiKey: nil,
                    model: AIProvider.ollama.defaultModel,
                    requiresAPIKey: false
                ),
                false, false, true,
                nil, nil
            ),
            (
                "codexSignInRequired",
                codexConfig,
                false, true, false,
                nil, "Codex CLI"
            ),
        ]

        for testCase in cases {
            let status = OnboardingSetupValidator.providerStatus(
                context: ProviderSetupContext(
                    config: testCase.config,
                    isCodexAuthenticated: testCase.isCodexAuthenticated,
                    isCodexInstalled: testCase.isCodexInstalled,
                    isAppleFoundationModelAvailable: false
                )
            )

            XCTAssertEqual(status.isReady, testCase.isReady, "isReady mismatch for \(testCase.name)")
            if let title = testCase.title {
                XCTAssertEqual(status.title, title, "title mismatch for \(testCase.name)")
            }
            if let messageContains = testCase.messageContains {
                XCTAssertTrue(
                    status.message.contains(messageContains),
                    "message mismatch for \(testCase.name): \(status.message)"
                )
            }
        }
    }
    
    // MARK: - Directory Picker Tests
    
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
    
    func testCanStartOrganizationRequiresDirectory() {
        appState.selectedDirectory = nil
        XCTAssertFalse(appState.canStartOrganization)
    }
    
    func testCanStartOrganizationWhenIdle() {
        appState.selectedDirectory = URL(fileURLWithPath: "/tmp")
        XCTAssertEqual(organizer.state, .idle)
        XCTAssertTrue(appState.canStartOrganization)
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
    
    func testExportLearningsProfileUsesManagerWithoutNotificationBridge() {
        final class NotificationProbe: @unchecked Sendable {
            var wasPosted = false
        }
        let probe = NotificationProbe()

        let manager = ExportSpyLearningsManager(userDefaults: testDefaults)
        manager.currentProfile = LearningsProfile()
        organizer.learningsManager = manager
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorty-export-\(UUID().uuidString).learnings")
        defer { try? FileManager.default.removeItem(at: destination) }

        let observer = NotificationCenter.default.addObserver(
            forName: .exportLearningsProfile,
            object: nil,
            queue: nil
        ) { _ in
            probe.wasPosted = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        appState.performLearningsProfileExport(destinationURL: destination)

        XCTAssertEqual(appState.currentView, .learnings)
        XCTAssertEqual(manager.exportDestination, destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(
            probe.wasPosted,
            "Export must act on the learnings manager directly, not through the removed notification bridge"
        )
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
    
    func testNilOrganizerDefaults() {
        appState.organizer = nil
        
        XCTAssertFalse(appState.hasResults)
        XCTAssertFalse(appState.hasFiles)
        XCTAssertFalse(appState.canStartOrganization)
        XCTAssertFalse(appState.hasCurrentPlan)
        XCTAssertFalse(appState.canApply)
        XCTAssertFalse(appState.isOperationInProgress)
    }
    
    // MARK: - Sparkle Update Manager Tests
    
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
