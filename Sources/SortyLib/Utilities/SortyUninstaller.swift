//
//  SortyUninstaller.swift
//  Sorty
//
//  One-shot local cleanup for users who want to fully remove Sorty.
//

import Foundation
import ServiceManagement
import UserNotifications

public struct SortyUninstallReport: Equatable {
    public let removedPaths: [String]
    public let missingPaths: [String]
    public let failedPaths: [String: String]
    public let blockingFailureDescriptions: [String]
    public let applicationPathsScheduledForRemoval: [String]
    public let removedQuickActionCount: Int
    public let didScheduleApplicationRemoval: Bool
    public let didClearDefaults: Bool
    public let didClearKeychain: Bool
    public let didClearNotifications: Bool
    public let didClearQuickActionRegistrations: Bool
    public let didResetPrivacyPermissions: Bool
    public let didUnregisterApplications: Bool
    public let didRequestFinderExtensionDisable: Bool
    public let didRequestFinderExtensionRemoval: Bool
    public let didRequestFinderExtensionStop: Bool
    public let didRequestLoginItemRemoval: Bool
}

public enum SortyUninstaller {
    public static let requestDefaultsKey = "runUninstallerOnNextLaunch"

    private static let bundleIdentifier = "com.sorty.app"
    private static let finderSyncBundleIdentifier = "com.sorty.app.SortyFinderSync"
    private static let widgetBundleIdentifier = "com.sorty.app.SortyWidgets"
    private static let appGroupIdentifier = "group.com.sorty.app"
    private static let toolbarHelperBundleIdentifier = "com.sorty.toolbar-helper"
    private static let servicesDirectoryPathDefaultsKey = "finderQuickActionServicesDirectoryPath"
    private static let launchServicesRegisterPath = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

    private static let legacyApplicationBundleIdentifiers = [
        "com.shirishpothi.Sorty",
        "com.sorty.Sorty",
        "com.sorty.SortyApp",
        "shirishpothi.Sorty",
    ]

    private static let legacyFinderSyncBundleIdentifiers = [
        "com.shirishpothi.Sorty.SortyFinderSync",
        "shirishpothi.Sorty.SortyFinderSync",
    ]

    private static let quickActionWorkflows: [(name: String, bundleIdentifier: String)] = [
        ("Organize with Sorty.workflow", "com.sorty.workflow.organize"),
        ("Watch with Sorty.workflow", "com.sorty.workflow.watch"),
        ("Exclude from Sorty.workflow", "com.sorty.workflow.exclude"),
        ("Exclude with Sorty.workflow", "com.sorty.workflow.exclude"),
        ("Scan with Sorty.workflow", "com.sorty.workflow.scan"),
        ("Preview with Sorty.workflow", "com.sorty.workflow.preview"),
    ]

    private static var knownApplicationBundleIdentifiers: [String] {
        [bundleIdentifier] + legacyApplicationBundleIdentifiers
    }

    private static var knownFinderSyncBundleIdentifiers: [String] {
        [finderSyncBundleIdentifier] + legacyFinderSyncBundleIdentifiers
    }

    private static var knownComponentBundleIdentifiers: [String] {
        knownApplicationBundleIdentifiers
            + knownFinderSyncBundleIdentifiers
            + [widgetBundleIdentifier, toolbarHelperBundleIdentifier]
    }

    public static func discardLegacyRequest() {
        UserDefaults.standard.removeObject(forKey: requestDefaultsKey)
    }

    public static func canRemoveCurrentApplication() -> Bool {
        let applicationURL = Bundle.main.bundleURL.standardizedFileURL
        return isOwnedApplicationBundle(applicationURL, fileManager: .default)
            && FileManager.default.isDeletableFile(atPath: applicationURL.path)
    }

    public static func run() -> SortyUninstallReport {
        run(
            currentApplicationURL: Bundle.main.bundleURL.standardizedFileURL,
            additionalApplicationURLs: [ExtensionCommunication.stagedApplicationURLForUninstall()].compactMap { $0 }
        )
    }

    /// Finishes uninstalling when Finder moves the running app out of Applications.
    public static func runAfterExternalApplicationRemoval(
        movedApplicationURL: URL?
    ) -> SortyUninstallReport? {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let candidates = externalRemovalApplicationBundleCandidates(
            movedApplicationURL: movedApplicationURL,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        guard let currentApplicationURL = candidates.first else { return nil }

        return run(
            currentApplicationURL: currentApplicationURL,
            additionalApplicationURLs: Array(candidates.dropFirst())
        )
    }

    private static func run(
        currentApplicationURL: URL,
        additionalApplicationURLs: [URL]
    ) -> SortyUninstallReport {
        let fileManager = FileManager.default
        let currentApplicationURL = currentApplicationURL.standardizedFileURL
        let homeDirectory = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let temporaryDirectory = fileManager.temporaryDirectory.standardizedFileURL
        let customServicesDirectory = UserDefaults.standard
            .string(forKey: servicesDirectoryPathDefaultsKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        let applicationURLs = applicationBundleCandidates(
            currentApplicationURL: currentApplicationURL,
            additionalApplicationURLs: additionalApplicationURLs,
            fileManager: fileManager
        )

        guard applicationURLs.contains(where: { $0.path == currentApplicationURL.path }),
              applicationURLs.allSatisfy({ fileManager.isDeletableFile(atPath: $0.path) }) else {
            return emptyReport()
        }

        let removalPaths = removalPathCandidates(
            homeDirectory: homeDirectory,
            temporaryDirectory: temporaryDirectory,
            customServicesDirectory: customServicesDirectory,
            fileManager: fileManager
        )
        let removedServiceRegistrations = removeServiceRegistrations()
        let didClearKeychain = KeychainManager.deleteAll()
        let resetPrivacyPermissions = resetPrivacyPermissions()
        var blockingFailures: [String] = []
        if !removedServiceRegistrations {
            blockingFailures.append("login and background items")
        }
        if !didClearKeychain {
            blockingFailures.append("Keychain credentials")
        }
        if !resetPrivacyPermissions {
            blockingFailures.append("privacy permissions")
        }

        // Keep the app installed so the user can retry protected cleanup safely.
        guard blockingFailures.isEmpty else {
            return SortyUninstallReport(
                removedPaths: [],
                missingPaths: [],
                failedPaths: [:],
                blockingFailureDescriptions: blockingFailures,
                applicationPathsScheduledForRemoval: [],
                removedQuickActionCount: 0,
                didScheduleApplicationRemoval: false,
                didClearDefaults: false,
                didClearKeychain: didClearKeychain,
                didClearNotifications: false,
                didClearQuickActionRegistrations: false,
                didResetPrivacyPermissions: resetPrivacyPermissions,
                didUnregisterApplications: false,
                didRequestFinderExtensionDisable: false,
                didRequestFinderExtensionRemoval: false,
                didRequestFinderExtensionStop: false,
                didRequestLoginItemRemoval: removedServiceRegistrations
            )
        }

        let finalRemovalTargets = safeUniqueURLs(removalPaths + applicationURLs)
        let removalReadyURL = temporaryDirectory
            .appendingPathComponent("sorty-uninstall-ready-\(UUID().uuidString)")
        let didStartRemovalHelper = schedulePostTerminationRemoval(
            targetURLs: finalRemovalTargets,
            readyURL: removalReadyURL,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        guard didStartRemovalHelper else {
            return SortyUninstallReport(
                removedPaths: [],
                missingPaths: [],
                failedPaths: [:],
                blockingFailureDescriptions: ["post-quit app removal"],
                applicationPathsScheduledForRemoval: [],
                removedQuickActionCount: 0,
                didScheduleApplicationRemoval: false,
                didClearDefaults: false,
                didClearKeychain: didClearKeychain,
                didClearNotifications: false,
                didClearQuickActionRegistrations: false,
                didResetPrivacyPermissions: resetPrivacyPermissions,
                didUnregisterApplications: false,
                didRequestFinderExtensionDisable: false,
                didRequestFinderExtensionRemoval: false,
                didRequestFinderExtensionStop: false,
                didRequestLoginItemRemoval: removedServiceRegistrations
            )
        }

        let disabledFinderExtension = knownFinderSyncBundleIdentifiers.reduce(true) { success, identifier in
            let didDisable = runCommand(
                "/usr/bin/pluginkit",
                arguments: ["-e", "ignore", "-i", identifier],
                acceptedTerminationStatuses: [0, 1]
            )
            return didDisable && success
        }
        let removedFinderExtension = removeFinderExtensionRegistrations(
            applicationURLs: applicationURLs,
            fileManager: fileManager
        )
        let stoppedFinderExtension = runCommand(
            "/usr/bin/pkill",
            arguments: ["-x", "SortyFinderSync"],
            acceptedTerminationStatuses: [0, 1]
        )
        let unregisteredApplications = unregisterApplications(
            applicationURLs: applicationURLs,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let clearedNotifications = clearNotifications()
        clearNetworkState()

        let quickActionResult = ExtensionCommunication.uninstallAllQuickActions()
        let pathResult = removeFilesystemState(
            candidates: removalPaths,
            fileManager: fileManager
        )
        let clearedQuickActionRegistrations = ExtensionCommunication
            .removeAllQuickActionRegistrationState()
        let didClearDefaults = clearDefaults()

        if !disabledFinderExtension || !removedFinderExtension || !stoppedFinderExtension {
            blockingFailures.append("Finder extension state")
        }
        if !unregisteredApplications {
            blockingFailures.append("Launch Services registrations")
        }
        if !clearedQuickActionRegistrations {
            blockingFailures.append("Finder action registrations")
        }
        if !didClearDefaults {
            blockingFailures.append("saved settings")
        }

        let didScheduleApplicationRemoval = blockingFailures.isEmpty
            && markRemovalReady(at: removalReadyURL)
        if blockingFailures.isEmpty && !didScheduleApplicationRemoval {
            blockingFailures.append("post-quit app removal")
        }

        return SortyUninstallReport(
            removedPaths: pathResult.removed,
            missingPaths: pathResult.missing,
            failedPaths: pathResult.failed,
            blockingFailureDescriptions: blockingFailures,
            applicationPathsScheduledForRemoval: didScheduleApplicationRemoval ? applicationURLs.map(\.path) : [],
            removedQuickActionCount: quickActionResult.removed,
            didScheduleApplicationRemoval: didScheduleApplicationRemoval,
            didClearDefaults: didClearDefaults,
            didClearKeychain: didClearKeychain,
            didClearNotifications: clearedNotifications,
            didClearQuickActionRegistrations: clearedQuickActionRegistrations,
            didResetPrivacyPermissions: resetPrivacyPermissions,
            didUnregisterApplications: unregisteredApplications,
            didRequestFinderExtensionDisable: disabledFinderExtension,
            didRequestFinderExtensionRemoval: removedFinderExtension,
            didRequestFinderExtensionStop: stoppedFinderExtension,
            didRequestLoginItemRemoval: removedServiceRegistrations
        )
    }

    public static func cleanupPathCandidates(homeDirectory: URL) -> [URL] {
        safeUniqueURLs(
            persistentStatePathCandidates(
                homeDirectory: homeDirectory,
                fileManager: .default
            ) + quickActionPathCandidates(
                customServicesDirectory: nil,
                homeDirectory: homeDirectory,
                fileManager: .default
            )
        )
    }

    static func applicationBundleCandidates(
        currentApplicationURL: URL,
        stagedApplicationURL: URL?,
        fileManager: FileManager
    ) -> [URL] {
        applicationBundleCandidates(
            currentApplicationURL: currentApplicationURL,
            additionalApplicationURLs: [stagedApplicationURL].compactMap { $0 },
            fileManager: fileManager
        )
    }

    private static func applicationBundleCandidates(
        currentApplicationURL: URL,
        additionalApplicationURLs: [URL],
        fileManager: FileManager
    ) -> [URL] {
        let currentApplicationURL = currentApplicationURL.standardizedFileURL
        guard isOwnedApplicationBundle(currentApplicationURL, fileManager: fileManager) else {
            return []
        }

        return safeUniqueURLs([currentApplicationURL] + additionalApplicationURLs).filter {
            isOwnedApplicationBundle($0, fileManager: fileManager)
        }
    }

    static func externalRemovalApplicationBundleCandidates(
        movedApplicationURL: URL?,
        homeDirectory: URL,
        fileManager: FileManager
    ) -> [URL] {
        let trashDirectory = homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
        return [movedApplicationURL]
            .compactMap { $0?.standardizedFileURL }
            .filter { $0.path.hasPrefix(trashDirectory.path + "/") }
            .filter {
                isOwnedApplicationBundle($0, fileManager: fileManager)
            }
    }

    static func temporaryItemCandidates(
        temporaryDirectory: URL,
        fileManager: FileManager
    ) -> [URL] {
        let prefixes = ["sorty-", "Sorty_", "SortyNotificationIcon-"]
        guard let contents = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.filter { item in
            prefixes.contains { item.lastPathComponent.hasPrefix($0) }
        }
    }

    static func removeFilesystemState(
        homeDirectory: URL,
        fileManager: FileManager
    ) -> (removed: [String], missing: [String], failed: [String: String]) {
        removeFilesystemState(
            candidates: persistentStatePathCandidates(
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ) + quickActionPathCandidates(
                customServicesDirectory: nil,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ),
            fileManager: fileManager
        )
    }

    static func postTerminationRemovalArguments(
        processIdentifier: Int32,
        readyURL: URL,
        targetURLs: [URL]
    ) -> [String] {
        [
            "-c",
            """
            TARGET_PID="$1"
            READY_FILE="$2"
            shift 2
            EXPECTED_START=$(/bin/ps -p "$TARGET_PID" -o lstart= 2>/dev/null)
            if [ -z "$EXPECTED_START" ]; then
                exit 1
            fi
            WAIT_COUNT=0
            while /bin/kill -0 "$TARGET_PID" 2>/dev/null; do
                CURRENT_START=$(/bin/ps -p "$TARGET_PID" -o lstart= 2>/dev/null)
                if [ "$CURRENT_START" != "$EXPECTED_START" ]; then
                    break
                fi
                if [ "$WAIT_COUNT" -ge 600 ]; then
                    /bin/rm -f "$READY_FILE"
                    exit 1
                fi
                WAIT_COUNT=$((WAIT_COUNT + 1))
                /bin/sleep 0.1
            done
            if [ ! -f "$READY_FILE" ]; then
                exit 1
            fi
            /bin/rm -f "$READY_FILE"
            ATTEMPT=0
            # Finder, Spotlight, and launch services can briefly retain a just-quit
            # app bundle. Keep retrying long enough for those processes to release it.
            while [ "$ATTEMPT" -lt 150 ]; do
                for TARGET in "$@"; do
                    /bin/rm -rf "$TARGET"
                done
                ATTEMPT=$((ATTEMPT + 1))
                /bin/sleep 0.2
            done
            for TARGET in "$@"; do
                if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
                    exit 1
                fi
            done
            exit 0
            """,
            "sorty-uninstall-remove",
            String(processIdentifier),
            readyURL.path,
        ] + safeUniqueURLs(targetURLs).map(\.path)
    }

    private static func removalPathCandidates(
        homeDirectory: URL,
        temporaryDirectory: URL,
        customServicesDirectory: URL?,
        fileManager: FileManager
    ) -> [URL] {
        safeUniqueURLs(
            persistentStatePathCandidates(
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
                + quickActionPathCandidates(
                    customServicesDirectory: customServicesDirectory,
                    homeDirectory: homeDirectory,
                    fileManager: fileManager
                )
                + temporaryItemCandidates(
                    temporaryDirectory: temporaryDirectory,
                    fileManager: fileManager
                )
        )
    }

    private static func persistentStatePathCandidates(
        homeDirectory: URL,
        fileManager: FileManager
    ) -> [URL] {
        let library = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        var candidates = [
            library.appendingPathComponent("Application Support/Sorty", isDirectory: true),
            library.appendingPathComponent("Application Support/\(bundleIdentifier).ShipIt", isDirectory: true),
            library.appendingPathComponent("Caches/Sorty", isDirectory: true),
            library.appendingPathComponent("Logs/Sorty", isDirectory: true),
            library.appendingPathComponent("Group Containers/\(appGroupIdentifier)", isDirectory: true),
            library.appendingPathComponent("Application Scripts/\(appGroupIdentifier)", isDirectory: true),
            library.appendingPathComponent("Preferences/\(appGroupIdentifier).plist"),
            library.appendingPathComponent("LaunchAgents/com.sorty.app.background-agent.plist"),
            library.appendingPathComponent("LaunchAgents/com.sorty.app.plist"),
        ]

        for identifier in knownComponentBundleIdentifiers {
            candidates.append(contentsOf: [
                library.appendingPathComponent("Application Support/\(identifier)", isDirectory: true),
                library.appendingPathComponent("Caches/\(identifier)", isDirectory: true),
                library.appendingPathComponent("Caches/\(identifier).ShipIt", isDirectory: true),
                library.appendingPathComponent("Logs/\(identifier)", isDirectory: true),
                library.appendingPathComponent("Containers/\(identifier)", isDirectory: true),
                library.appendingPathComponent("Application Scripts/\(identifier)", isDirectory: true),
                library.appendingPathComponent("HTTPStorages/\(identifier)", isDirectory: true),
                library.appendingPathComponent("WebKit/\(identifier)", isDirectory: true),
                library.appendingPathComponent("Saved Application State/\(identifier).savedState", isDirectory: true),
                library.appendingPathComponent("Preferences/\(identifier).plist"),
                library.appendingPathComponent("Cookies/\(identifier).binarycookies"),
            ])
        }

        let byHostPreferences = library.appendingPathComponent("Preferences/ByHost", isDirectory: true)
        if let contents = try? fileManager.contentsOfDirectory(
            at: byHostPreferences,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: contents.filter { item in
                knownComponentBundleIdentifiers.contains { identifier in
                    item.lastPathComponent.hasPrefix("\(identifier).")
                }
            })
        }

        let diagnosticPrefixes = ["Sorty_", "SortyFinderSync_"]
        for directory in [
            library.appendingPathComponent("Application Support/CrashReporter", isDirectory: true),
            library.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true),
        ] {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            candidates.append(contentsOf: contents.filter { item in
                diagnosticPrefixes.contains { item.lastPathComponent.hasPrefix($0) }
            })
        }

        return safeUniqueURLs(candidates)
    }

    private static func quickActionPathCandidates(
        customServicesDirectory: URL?,
        homeDirectory: URL,
        fileManager: FileManager
    ) -> [URL] {
        let defaultServicesDirectory = homeDirectory
            .appendingPathComponent("Library/Services", isDirectory: true)
            .standardizedFileURL
        var servicesDirectories = [defaultServicesDirectory]
        if let customServicesDirectory,
           customServicesDirectory.standardizedFileURL.path != defaultServicesDirectory.path {
            servicesDirectories.append(customServicesDirectory.standardizedFileURL)
        }

        return servicesDirectories.flatMap { servicesDirectory in
            quickActionWorkflows.compactMap { workflow in
                let workflowURL = servicesDirectory
                    .appendingPathComponent(workflow.name, isDirectory: true)
                    .standardizedFileURL
                guard bundleIdentifierForBundle(at: workflowURL, fileManager: fileManager) == workflow.bundleIdentifier else {
                    return nil
                }
                return workflowURL
            }
        }
    }

    private static func removeFilesystemState(
        candidates: [URL],
        fileManager: FileManager
    ) -> (removed: [String], missing: [String], failed: [String: String]) {
        var removed: [String] = []
        var missing: [String] = []
        var failed: [String: String] = [:]

        for url in safeUniqueURLs(candidates) {
            let path = url.path
            guard pathExistsOrIsSymbolicLink(url, fileManager: fileManager) else {
                missing.append(path)
                continue
            }

            do {
                try fileManager.removeItem(at: url)
                removed.append(path)
            } catch {
                failed[path] = error.localizedDescription
            }
        }

        return (removed, missing, failed)
    }

    private static func schedulePostTerminationRemoval(
        targetURLs: [URL],
        readyURL: URL,
        processIdentifier: Int32
    ) -> Bool {
        guard !targetURLs.isEmpty else { return false }
        return launchDetachedShell(
            arguments: postTerminationRemovalArguments(
                processIdentifier: processIdentifier,
                readyURL: readyURL,
                targetURLs: targetURLs
            )
        )
    }

    private static func markRemovalReady(at readyURL: URL) -> Bool {
        do {
            try Data("ready".utf8).write(to: readyURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func launchDetachedShell(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private static func removeFinderExtensionRegistrations(
        applicationURLs: [URL],
        fileManager: FileManager
    ) -> Bool {
        var success = true
        for applicationURL in applicationURLs {
            let extensionURL = applicationURL
                .appendingPathComponent("Contents/PlugIns/SortyFinderSync.appex", isDirectory: true)
            guard fileManager.fileExists(atPath: extensionURL.path) else { continue }
            success = runCommand(
                "/usr/bin/pluginkit",
                arguments: ["-r", extensionURL.path],
                acceptedTerminationStatuses: [0, 1]
            ) && success
        }
        return success
    }

    private static func unregisterApplications(
        applicationURLs: [URL],
        homeDirectory: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.isExecutableFile(atPath: launchServicesRegisterPath) else {
            return false
        }

        var candidates = applicationURLs
        let toolbarHelperURL = homeDirectory
            .appendingPathComponent("Library/Application Support/Sorty/Organize with Sorty.app", isDirectory: true)
        if fileManager.fileExists(atPath: toolbarHelperURL.path) {
            candidates.append(toolbarHelperURL)
        }

        return safeUniqueURLs(candidates).reduce(true) { success, applicationURL in
            let didUnregister = runCommand(
                launchServicesRegisterPath,
                arguments: ["-u", applicationURL.path]
            )
            return didUnregister && success
        }
    }

    private static func resetPrivacyPermissions() -> Bool {
        let didResetCurrentApplication = runCommand(
            "/usr/bin/tccutil",
            arguments: ["reset", "All", bundleIdentifier]
        )
        for identifier in legacyApplicationBundleIdentifiers
            + knownFinderSyncBundleIdentifiers
            + [widgetBundleIdentifier, toolbarHelperBundleIdentifier] {
            _ = runCommand(
                "/usr/bin/tccutil",
                arguments: ["reset", "All", identifier]
            )
        }
        return didResetCurrentApplication
    }

    private static func clearNotifications() -> Bool {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeAllPendingNotificationRequests()
        notificationCenter.removeAllDeliveredNotifications()
        notificationCenter.setNotificationCategories([])
        return true
    }

    private static func clearNetworkState() {
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
    }

    private static func clearDefaults() -> Bool {
        let defaults = UserDefaults.standard
        for identifier in knownComponentBundleIdentifiers {
            defaults.removePersistentDomain(forName: identifier)
        }

        var success = knownComponentBundleIdentifiers.allSatisfy {
            defaults.persistentDomain(forName: $0) == nil
        }

        if let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier) {
            sharedDefaults.removePersistentDomain(forName: appGroupIdentifier)
            success = sharedDefaults.persistentDomain(forName: appGroupIdentifier) == nil && success
        }

        return success
    }

    private static func removeServiceRegistrations() -> Bool {
        var success = true

        success = unregister(SMAppService.mainApp) && success
        success = unregister(SMAppService.agent(plistName: LoginItemManager.backgroundAgentPlistName)) && success
        success = unregister(SMAppService.agent(plistName: LoginItemManager.legacyBackgroundAgentPlistName)) && success

        return success
    }

    private static func unregister(_ service: SMAppService) -> Bool {
        switch service.status {
        case .enabled, .requiresApproval:
            do {
                try service.unregister()
                return true
            } catch {
                return false
            }
        case .notRegistered, .notFound:
            return true
        @unknown default:
            return false
        }
    }

    private static func isOwnedApplicationBundle(
        _ applicationURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              fileManager.fileExists(atPath: applicationURL.path),
              let identifier = bundleIdentifierForBundle(at: applicationURL, fileManager: fileManager) else {
            return false
        }
        return knownApplicationBundleIdentifiers.contains(identifier)
    }

    private static func bundleIdentifierForBundle(
        at bundleURL: URL,
        fileManager: FileManager
    ) -> String? {
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard fileManager.fileExists(atPath: infoPlistURL.path),
              let data = try? Data(contentsOf: infoPlistURL),
              let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = propertyList as? [String: Any] else {
            return nil
        }
        return info["CFBundleIdentifier"] as? String
    }

    private static func safeUniqueURLs(_ urls: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        return urls.compactMap { url in
            guard url.isFileURL else { return nil }
            let standardizedURL = url.standardizedFileURL
            let path = standardizedURL.path
            guard path.hasPrefix("/"), path != "/", standardizedURL.pathComponents.count >= 3 else {
                return nil
            }
            return seenPaths.insert(path).inserted ? standardizedURL : nil
        }
    }

    private static func pathExistsOrIsSymbolicLink(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func emptyReport() -> SortyUninstallReport {
        SortyUninstallReport(
            removedPaths: [],
            missingPaths: [],
            failedPaths: [:],
            blockingFailureDescriptions: ["application bundle"],
            applicationPathsScheduledForRemoval: [],
            removedQuickActionCount: 0,
            didScheduleApplicationRemoval: false,
            didClearDefaults: false,
            didClearKeychain: false,
            didClearNotifications: false,
            didClearQuickActionRegistrations: false,
            didResetPrivacyPermissions: false,
            didUnregisterApplications: false,
            didRequestFinderExtensionDisable: false,
            didRequestFinderExtensionRemoval: false,
            didRequestFinderExtensionStop: false,
            didRequestLoginItemRemoval: false
        )
    }

    @discardableResult
    private static func runCommand(
        _ launchPath: String,
        arguments: [String],
        acceptedTerminationStatuses: Set<Int32> = [0]
    ) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return acceptedTerminationStatuses.contains(process.terminationStatus)
        } catch {
            return false
        }
    }
}
