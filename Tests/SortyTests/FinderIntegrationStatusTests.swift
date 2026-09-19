import XCTest
@testable import SortyLib

final class FinderIntegrationStatusTests: XCTestCase {
    private let preferredExtensionPath = "/Users/test/Applications/Sorty.app/Contents/PlugIns/SortyFinderSync.appex"
    private let staleExtensionPath = "/Applications/Sorty.app/Contents/PlugIns/SortyFinderSync.appex"

    override func tearDown() {
        UserDefaults(suiteName: "group.com.sorty.app")?.removeObject(forKey: "selectedDirectory")
        super.tearDown()
    }

    func testFinderRequestIsConsumedOnlyOnce() {
        let defaults = UserDefaults(suiteName: "group.com.sorty.app")!
        let incoming = FileManager.default.temporaryDirectory
            .appendingPathComponent("SortyIncoming-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defaults.set(incoming.path, forKey: "selectedDirectory")

        XCTAssertEqual(ExtensionCommunication.receiveFromExtension()?.path, incoming.path)
        XCTAssertNil(ExtensionCommunication.receiveFromExtension())
        try? FileManager.default.removeItem(at: incoming)
    }

    func testIntegrationCountUsesActiveIntegrationsOnly() {
        let status = ExtensionCommunication.FinderIntegrationStatus(
            quickActionInstalled: true,
            quickWatchActionInstalled: true,
            quickExcludeActionInstalled: true,
            toolbarAppInstalled: false,
            finderSyncEnabled: true,
            menuBarEnabled: false
        )

        XCTAssertEqual(status.integrationCount, 4)
        XCTAssertEqual(ExtensionCommunication.FinderIntegrationStatus.totalIntegrations, 6)
        XCTAssertEqual(status.overallStatus, "Active")
    }

    func testFinderIntegrationAvailabilityStatusReflectsDisabledFeatureFlag() {
        let status = ExtensionCommunication.finderIntegrationAvailabilityStatus(
            featureFlagEnabled: false,
            diagnostics: nil
        )

        XCTAssertEqual(status.state, .featureDisabled)
        XCTAssertEqual(status.title, "Feature Flag Disabled")
    }

    func testFinderIntegrationAvailabilityStatusFlagsIncompleteFinderSyncSetup() {
        let diagnostics = ExtensionCommunication.finderSyncDiagnostics(
            entries: [.init(path: preferredExtensionPath, isEnabled: false)],
            preferredPath: preferredExtensionPath,
            heartbeat: nil
        )

        let status = ExtensionCommunication.finderIntegrationAvailabilityStatus(
            featureFlagEnabled: true,
            diagnostics: diagnostics
        )

        XCTAssertEqual(status.state, .setupPending)
        XCTAssertTrue(status.detail.contains("currently disabled"))
    }

    func testFinderIntegrationAvailabilityStatusReflectsReadyFinderSync() {
        let diagnostics = ExtensionCommunication.finderSyncDiagnostics(
            entries: [.init(path: preferredExtensionPath, isEnabled: true)],
            preferredPath: preferredExtensionPath,
            heartbeat: .init(
                event: "launch",
                bundleIdentifier: "com.sorty.app.SortyFinderSync",
                path: preferredExtensionPath,
                reportedAt: Date()
            )
        )

        let status = ExtensionCommunication.finderIntegrationAvailabilityStatus(
            featureFlagEnabled: true,
            diagnostics: diagnostics
        )

        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.title, "Finder Sync Verified")
    }

    func testAsyncIntegrationStatusReturnsWithoutThrowing() async {
        let status = await ExtensionCommunication.getIntegrationStatusAsync()
        XCTAssertGreaterThanOrEqual(status.integrationCount, 0)
        XCTAssertLessThanOrEqual(status.integrationCount, ExtensionCommunication.FinderIntegrationStatus.totalIntegrations)
    }

    func testParseFinderSyncRegistrationEntriesTracksEnabledStates() {
        let output = """
        +    com.sorty.app.SortyFinderSync(1.1.2)\tUUID-1\t2026-03-07 02:42:55 +0000\t\(preferredExtensionPath)
        -    com.sorty.app.SortyFinderSync(1.1.2)\tUUID-2\t2026-03-07 02:42:55 +0000\t\(staleExtensionPath)
             com.sorty.app.SortyFinderSync(1.1.2)\tUUID-3\t2026-03-07 02:42:55 +0000\t/private/tmp/Sorty.app/Contents/PlugIns/SortyFinderSync.appex
        """

        let entries = ExtensionCommunication.parseFinderSyncRegistrationEntries(from: output)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first(where: { $0.path == preferredExtensionPath })?.isEnabled, true)
        XCTAssertEqual(entries.first(where: { $0.path == staleExtensionPath })?.isEnabled, false)
        XCTAssertNil(entries.first(where: { $0.path.contains("/private/tmp/") })?.isEnabled)
    }

    func testFinderSyncRegistrationHostEligibilityAcceptsApplicationsPaths() {
        XCTAssertTrue(
            ExtensionCommunication.isFinderSyncRegistrationHostEligible(
                appBundlePath: "/Applications/Sorty.app",
                homeDirectoryPath: "/Users/test"
            )
        )

        XCTAssertTrue(
            ExtensionCommunication.isFinderSyncRegistrationHostEligible(
                appBundlePath: "/Users/test/Applications/Sorty.app",
                homeDirectoryPath: "/Users/test"
            )
        )
    }

    func testFinderSyncRegistrationHostEligibilityRejectsWorkspaceBuildPath() {
        XCTAssertFalse(
            ExtensionCommunication.isFinderSyncRegistrationHostEligible(
                appBundlePath: "/Users/test/Code Projects/Sorty/releases/Sorty.app",
                homeDirectoryPath: "/Users/test"
            )
        )
    }

    func testFinderSyncDiagnosticsFlagsAnotherActiveAppCopy() {
        let diagnostics = ExtensionCommunication.finderSyncDiagnostics(
            entries: [.init(path: staleExtensionPath, isEnabled: true)],
            preferredPath: preferredExtensionPath,
            heartbeat: nil
        )

        XCTAssertEqual(diagnostics.kind, .activeElsewhere)
        XCTAssertEqual(diagnostics.activePath, staleExtensionPath)
        XCTAssertTrue(diagnostics.needsRepair)
    }

    func testFinderSyncDiagnosticsDoesNotClaimWorkingWithoutFinderHeartbeat() {
        let diagnostics = ExtensionCommunication.finderSyncDiagnostics(
            entries: [.init(path: preferredExtensionPath, isEnabled: true)],
            preferredPath: preferredExtensionPath,
            heartbeat: nil
        )

        XCTAssertEqual(diagnostics.kind, .registered)
        XCTAssertTrue(diagnostics.isOperational)
        XCTAssertFalse(diagnostics.isVerifiedWorking)
    }

    func testFinderSyncDiagnosticsVerifiesCurrentBuildWithHeartbeat() {
        let diagnostics = ExtensionCommunication.finderSyncDiagnostics(
            entries: [.init(path: preferredExtensionPath, isEnabled: true)],
            preferredPath: preferredExtensionPath,
            heartbeat: .init(
                event: "launch",
                bundleIdentifier: "com.sorty.app.SortyFinderSync",
                path: preferredExtensionPath,
                reportedAt: Date()
            )
        )

        XCTAssertEqual(diagnostics.kind, .verified)
        XCTAssertTrue(diagnostics.isOperational)
        XCTAssertTrue(diagnostics.isVerifiedWorking)
    }

    func testFinderSyncDiagnosticsVerifiesCurrentBuildWithRunningProcessPath() {
        let diagnostics = ExtensionCommunication.finderSyncDiagnostics(
            entries: [.init(path: preferredExtensionPath, isEnabled: true)],
            preferredPath: preferredExtensionPath,
            heartbeat: nil,
            runningProcessPath: preferredExtensionPath
        )

        XCTAssertEqual(diagnostics.kind, .verified)
        XCTAssertTrue(diagnostics.isOperational)
        XCTAssertTrue(diagnostics.isVerifiedWorking)
    }

    func testFinderSyncDiagnosticsFlagsAnotherActiveCopyFromRunningProcessPath() {
        let diagnostics = ExtensionCommunication.finderSyncDiagnostics(
            entries: [.init(path: preferredExtensionPath, isEnabled: true)],
            preferredPath: preferredExtensionPath,
            heartbeat: nil,
            runningProcessPath: staleExtensionPath
        )

        XCTAssertEqual(diagnostics.kind, .activeElsewhere)
        XCTAssertEqual(diagnostics.activePath, staleExtensionPath)
        XCTAssertTrue(diagnostics.needsRepair)
    }

    func testFinderSyncDiagnosticsFlagsStaleDuplicateRegistrations() {
        let diagnostics = ExtensionCommunication.finderSyncDiagnostics(
            entries: [
                .init(path: preferredExtensionPath, isEnabled: true),
                .init(path: staleExtensionPath, isEnabled: true)
            ],
            preferredPath: preferredExtensionPath,
            heartbeat: nil
        )

        XCTAssertEqual(diagnostics.kind, .needsCleanup)
        XCTAssertEqual(diagnostics.problemPaths, [staleExtensionPath])
        XCTAssertTrue(diagnostics.needsRepair)
    }

    func testMissingFinderIntegrationAppEntitlementsAllowsUnsignedHostApp() {
        let missing = ExtensionCommunication.missingFinderIntegrationAppEntitlements(in: [:])

        XCTAssertTrue(missing.isEmpty)
    }

    func testFinderSyncDiagnosticsIgnoresMissingHostAppEntitlements() {
        let diagnostics = ExtensionCommunication.finderSyncDiagnostics(
            entries: [.init(path: preferredExtensionPath, isEnabled: true)],
            preferredPath: preferredExtensionPath,
            heartbeat: nil,
            appBundleMissingEntitlements: ["com.apple.security.app-sandbox"]
        )

        XCTAssertEqual(diagnostics.kind, .registered)
        XCTAssertFalse(diagnostics.needsCodeSignatureRepair)
        XCTAssertFalse(diagnostics.needsRepair)
    }

    func testAutoRepairSkipsWhenCurrentBuildIsOnlyRegistered() {
        let diagnostics = ExtensionCommunication.finderSyncDiagnostics(
            entries: [.init(path: preferredExtensionPath, isEnabled: true)],
            preferredPath: preferredExtensionPath,
            heartbeat: nil
        )

        XCTAssertFalse(
            ExtensionCommunication.shouldAutoRepairFinderSync(
                diagnostics: diagnostics,
                currentPath: preferredExtensionPath
            )
        )
    }

    func testAutoRepairSkipsWhenCurrentBuildIsVerified() {
        let diagnostics = ExtensionCommunication.finderSyncDiagnostics(
            entries: [.init(path: preferredExtensionPath, isEnabled: true)],
            preferredPath: preferredExtensionPath,
            heartbeat: .init(
                event: "launch",
                bundleIdentifier: "com.sorty.app.SortyFinderSync",
                path: preferredExtensionPath,
                reportedAt: Date()
            )
        )

        XCTAssertFalse(
            ExtensionCommunication.shouldAutoRepairFinderSync(
                diagnostics: diagnostics,
                currentPath: preferredExtensionPath
            )
        )
    }

    func testAutoRepairRespectsDisabledExtension() {
        let diagnostics = ExtensionCommunication.finderSyncDiagnostics(
            entries: [.init(path: preferredExtensionPath, isEnabled: false)],
            preferredPath: preferredExtensionPath,
            heartbeat: nil
        )

        XCTAssertFalse(
            ExtensionCommunication.shouldAutoRepairFinderSync(
                diagnostics: diagnostics,
                currentPath: preferredExtensionPath
            )
        )
    }

    func testAutoRepairTriggersWhenCurrentBuildPathDiffersFromPreferredRegistration() {
        let diagnostics = ExtensionCommunication.finderSyncDiagnostics(
            entries: [.init(path: preferredExtensionPath, isEnabled: true)],
            preferredPath: preferredExtensionPath,
            heartbeat: nil
        )

        let workspaceBuildPath = "/Users/test/Code Projects/Sorty/releases/Sorty.app/Contents/PlugIns/SortyFinderSync.appex"

        XCTAssertTrue(
            ExtensionCommunication.shouldAutoRepairFinderSync(
                diagnostics: diagnostics,
                currentPath: workspaceBuildPath
            )
        )
    }

    func testBackgroundAgentConfigurationRejectsMainAppLabelCollision() {
        let issues = LoginItemManager.backgroundAgentConfigurationIssues(
            label: "com.sorty.app",
            bundleProgram: "Contents/MacOS/Sorty",
            mainAppServiceLabel: "com.sorty.app"
        )

        XCTAssertTrue(issues.contains("Background agent label collides with the main app service label"))
    }

    func testBackgroundAgentConfigurationAcceptsDedicatedAgentLabel() {
        let issues = LoginItemManager.backgroundAgentConfigurationIssues(
            label: LoginItemManager.backgroundAgentServiceLabel,
            bundleProgram: LoginItemManager.backgroundAgentBundleProgram,
            mainAppServiceLabel: "com.sorty.app"
        )

        XCTAssertTrue(issues.isEmpty)
    }

    // MARK: - parseEntitlementsPlist

    func testParseEntitlementsPlistWithValidXML() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.app-sandbox</key>
            <true/>
            <key>com.apple.security.application-groups</key>
            <array>
                <string>group.com.sorty.app</string>
            </array>
        </dict>
        </plist>
        """

        let result = ExtensionCommunication.parseEntitlementsPlist(from: xml)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?["com.apple.security.app-sandbox"] as? Bool, true)
        let groups = result?["com.apple.security.application-groups"] as? [String]
        XCTAssertEqual(groups, ["group.com.sorty.app"])
    }

    func testParseEntitlementsPlistWithEmptyStringReturnsNil() {
        let result = ExtensionCommunication.parseEntitlementsPlist(from: "")
        XCTAssertNil(result)
    }

    func testParseEntitlementsPlistWithInvalidXMLReturnsNil() {
        let result = ExtensionCommunication.parseEntitlementsPlist(from: "not xml at all")
        XCTAssertNil(result)
    }

    // MARK: - finderSyncDiagnostics edge cases

    func testFinderSyncDiagnosticsReportsNotRegisteredWhenNoEntries() {
        let diagnostics = ExtensionCommunication.finderSyncDiagnostics(
            entries: [],
            preferredPath: preferredExtensionPath,
            heartbeat: nil
        )

        XCTAssertEqual(diagnostics.kind, .notRegistered)
        XCTAssertTrue(diagnostics.needsRepair)
    }

    func testFinderSyncDiagnosticsReportsDisabledWhenPreferredEntryDisabled() {
        let diagnostics = ExtensionCommunication.finderSyncDiagnostics(
            entries: [.init(path: preferredExtensionPath, isEnabled: false)],
            preferredPath: preferredExtensionPath,
            heartbeat: nil
        )

        XCTAssertEqual(diagnostics.kind, .disabled)
        XCTAssertTrue(diagnostics.needsRepair)
    }

    func testFinderSyncDiagnosticsReportsMissingWhenNoPreferredPath() {
        let diagnostics = ExtensionCommunication.finderSyncDiagnostics(
            entries: [],
            preferredPath: nil,
            heartbeat: nil
        )

        XCTAssertEqual(diagnostics.kind, .missing)
        XCTAssertFalse(diagnostics.isOperational)
    }

    func testFinderSyncDiagnosticsReportsIndeterminateWhenEntryHasNoEnabledState() {
        let diagnostics = ExtensionCommunication.finderSyncDiagnostics(
            entries: [.init(path: preferredExtensionPath, isEnabled: nil)],
            preferredPath: preferredExtensionPath,
            heartbeat: nil
        )

        XCTAssertEqual(diagnostics.kind, .indeterminate)
    }

    // MARK: - backgroundAgentConfigurationIssues edge cases

    func testBackgroundAgentConfigurationRejectsEmptyLabel() {
        let issues = LoginItemManager.backgroundAgentConfigurationIssues(
            label: "",
            bundleProgram: "Contents/MacOS/Sorty",
            mainAppServiceLabel: "com.sorty.app"
        )

        XCTAssertTrue(issues.contains("Background agent label is missing"))
    }

    func testBackgroundAgentConfigurationRejectsWrongBundleProgram() {
        let issues = LoginItemManager.backgroundAgentConfigurationIssues(
            label: LoginItemManager.backgroundAgentServiceLabel,
            bundleProgram: "MacOS/WrongApp",
            mainAppServiceLabel: "com.sorty.app"
        )

        XCTAssertTrue(issues.contains("Background agent BundleProgram must remain Contents/MacOS/Sorty"))
    }

    // MARK: - parseFinderSyncRegistrationEntries deduplication

    func testParseFinderSyncRegistrationEntriesDeduplicatesMatchingPaths() {
        let output = """
             com.sorty.app.SortyFinderSync(1.1.2)\tUUID-1\t2026-03-07 02:42:55 +0000\t\(preferredExtensionPath)
        +    com.sorty.app.SortyFinderSync(1.1.2)\tUUID-2\t2026-03-07 02:42:55 +0000\t\(preferredExtensionPath)
        """

        let entries = ExtensionCommunication.parseFinderSyncRegistrationEntries(from: output)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.isEnabled, true)
    }

    // MARK: - FinderSyncRuntimeHeartbeat.isRecent

    func testHeartbeatIsRecentReturnsFalseForOldTimestamp() {
        let heartbeat = ExtensionCommunication.FinderSyncRuntimeHeartbeat(
            event: "launch",
            bundleIdentifier: "com.sorty.app.SortyFinderSync",
            path: preferredExtensionPath,
            reportedAt: Date().addingTimeInterval(-300)
        )

        XCTAssertFalse(heartbeat.isRecent)
    }

    func testHeartbeatIsRecentReturnsTrueForFreshTimestamp() {
        let heartbeat = ExtensionCommunication.FinderSyncRuntimeHeartbeat(
            event: "launch",
            bundleIdentifier: "com.sorty.app.SortyFinderSync",
            path: preferredExtensionPath,
            reportedAt: Date()
        )

        XCTAssertTrue(heartbeat.isRecent)
    }
}
