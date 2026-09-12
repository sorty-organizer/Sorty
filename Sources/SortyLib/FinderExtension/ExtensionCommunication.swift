//
//  ExtensionCommunication.swift
//  Sorty
//
//  Finder integration without code signing
//  Uses URL schemes, Services menu, and AppleScript for integration
//

import Foundation
import AppKit
import Darwin

private actor FinderSyncAutoRepairGate {
    static let shared = FinderSyncAutoRepairGate()

    private var isRunning = false

    func run(_ operation: () async -> Void) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        await operation()
    }
}

/// Shares one expensive Finder registration probe between callers that ask at
/// the same time, such as Settings and the troubleshooting check.
private actor FinderSyncDiagnosticsGate {
    static let shared = FinderSyncDiagnosticsGate()

    private var inFlight: Task<ExtensionCommunication.FinderSyncDiagnostics, Never>?

    func run(
        _ operation: @escaping @Sendable () async -> ExtensionCommunication.FinderSyncDiagnostics
    ) async -> ExtensionCommunication.FinderSyncDiagnostics {
        if let inFlight {
            return await inFlight.value
        }

        let task = Task { await operation() }
        inFlight = task
        let diagnostics = await task.value
        inFlight = nil
        return diagnostics
    }
}

public struct ExtensionCommunication {
    private static let appGroupIdentifier = "group.com.sorty.app"
    private static let directoryKey = "selectedDirectory"
    private static let organizeQuickActionWorkflowName = "Organize with Sorty.workflow"
    private static let watchQuickActionWorkflowName = "Watch with Sorty.workflow"
    private static let excludeQuickActionWorkflowName = "Exclude from Sorty.workflow"
    private static let legacyExcludeQuickActionWorkflowName = "Exclude with Sorty.workflow"
    private static let scanQuickActionWorkflowName = "Scan with Sorty.workflow"
    private static let previewQuickActionWorkflowName = "Preview with Sorty.workflow"
    private static let organizeQuickActionBundleIdentifier = "com.sorty.workflow.organize"
    private static let watchQuickActionBundleIdentifier = "com.sorty.workflow.watch"
    private static let excludeQuickActionBundleIdentifier = "com.sorty.workflow.exclude"
    private static let scanQuickActionBundleIdentifier = "com.sorty.workflow.scan"
    private static let previewQuickActionBundleIdentifier = "com.sorty.workflow.preview"
    private static let quickActionIconBaseName = "SortyQuickActionIcon"
    private static let quickActionServiceIconName = "workflowCustomImageTemplate"
    private static let organizeWorkflowIconVersionInfoKey = "SortyOrganizeIconVersion"
    private static let organizeWorkflowIconVersion = "2"
    private static let watchWorkflowIconVariantInfoKey = "SortyWatchIconVariant"
    private static let servicesDirectoryPathDefaultsKey = "finderQuickActionServicesDirectoryPath"
    private static let stagedApplicationPathDefaultsKey = "finderStagedApplicationPath"
    private static let stagedApplicationIdentityDefaultsKey = "finderStagedApplicationIdentity"
    private static let finderSyncExtensionName = "SortyFinderSync.appex"
    private static let finderSyncBundleSuffix = ".SortyFinderSync"
    private static let systemApplicationsDirectoryPath = "/Applications"
    private static let userApplicationsDirectoryName = "Applications"
    private static let finderRepairEntitlementsResourceName = "SortyAppRepair.entitlements"
    private static let finderRepairVerificationTimeout: TimeInterval = 8
    private static let finderRepairVerificationPollInterval: TimeInterval = 0.5
    private static let finderRepairRequiredAppGroup = "group.com.sorty.app"
    private static let pbsDomain = "pbs"
    private static let activeSortyServices: [(bundleIdentifier: String, menuTitle: String)] = [
        (organizeQuickActionBundleIdentifier, "Organize with Sorty"),
        (watchQuickActionBundleIdentifier, "Watch with Sorty"),
        (excludeQuickActionBundleIdentifier, "Exclude from Sorty")
    ]
    private static let deprecatedSortyServices: [(bundleIdentifier: String, menuTitle: String)] = [
        (scanQuickActionBundleIdentifier, "Scan with Sorty"),
        (previewQuickActionBundleIdentifier, "Preview with Sorty"),
        (excludeQuickActionBundleIdentifier, "Exclude with Sorty")
    ]
    public static let notificationName = Notification.Name("SortyDirectorySelected")
    public static let finderSyncHeartbeatNotification = Notification.Name("SortyFinderSyncHeartbeat")
    private static let finderSyncHeartbeatDefaultsKey = "finderSyncHeartbeatCache"
    private static let finderSyncHeartbeatMaxAge: TimeInterval = 180
    private static let servicesRegistryRefreshDefaultsKey = "finderServicesRegistryLastRefresh"
    private static let servicesRegistryRefreshMinimumInterval: TimeInterval = 6 * 60 * 60
    nonisolated(unsafe) private static var finderSyncHeartbeatObserver: NSObjectProtocol?

    // MARK: - URL Scheme Handling

    /// Handle incoming URL schemes: sorty://organize?path=/path/to/folder
    public static func handleURL(_ url: URL) -> URL? {
        guard url.scheme == "sorty" else { return nil }

        switch url.host {
        case "organize":
            // sorty://organize?path=/path/to/folder
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let pathItem = components.queryItems?.first(where: { $0.name == "path" }),
               let path = pathItem.value?.removingPercentEncoding {
                return URL(fileURLWithPath: path)
            }

        case "scan":
            // sorty://scan?path=/path/to/folder
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let pathItem = components.queryItems?.first(where: { $0.name == "path" }),
               let path = pathItem.value?.removingPercentEncoding {
                return URL(fileURLWithPath: path)
            }

        case "open":
            // sorty://open?path=/path/to/folder
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let pathItem = components.queryItems?.first(where: { $0.name == "path" }),
               let path = pathItem.value?.removingPercentEncoding {
                return URL(fileURLWithPath: path)
            }

        case "watched":
            // sorty://watched?action=add&path=/path/to/folder
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let pathItem = components.queryItems?.first(where: { $0.name == "path" }),
               let path = pathItem.value?.removingPercentEncoding {
                return URL(fileURLWithPath: path)
            }

        default:
            // Legacy: sorty:///path/to/folder (path in URL path component)
            if !url.path.isEmpty && url.path != "/" {
                return URL(fileURLWithPath: url.path)
            }
        }

        return nil
    }

    /// Generate a URL scheme command for organizing a given path
    public static func urlForOrganizing(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "sorty"
        components.host = "organize"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    /// Generate a URL scheme command for scanning a given path
    public static func urlForScanning(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "sorty"
        components.host = "scan"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    // MARK: - App Group Communication (for sandboxed extensions)

    public static func sendDirectoryToApp(_ directoryURL: URL) {
        if let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier) {
            sharedDefaults.set(directoryURL.path, forKey: directoryKey)
            sharedDefaults.synchronize()
        }

        let notificationCenter = DistributedNotificationCenter.default()
        notificationCenter.post(
            name: notificationName,
            object: nil,
            userInfo: ["path": directoryURL.path]
        )
    }

    public static func receiveFromExtension() -> URL? {
        if let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier),
           let path = sharedDefaults.string(forKey: directoryKey) {
            sharedDefaults.removeObject(forKey: directoryKey)
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    @discardableResult
    public static func setupNotificationObserver(handler: @escaping @Sendable @MainActor (URL) -> Void) -> NSObjectProtocol {
        let notificationCenter = DistributedNotificationCenter.default()
        return notificationCenter.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { notification in
            if let userInfo = notification.userInfo,
               let path = userInfo["path"] as? String {
                UserDefaults(suiteName: appGroupIdentifier)?.removeObject(forKey: directoryKey)
                let url = URL(fileURLWithPath: path)
                Task { @MainActor in
                    handler(url)
                }
            }
        }
    }

    public static func removeNotificationObserver(_ observer: NSObjectProtocol) {
        DistributedNotificationCenter.default().removeObserver(observer)
    }

    // MARK: - Finder Sync Extension Registration

    private struct CommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    struct FinderSyncRegistrationEntry: Sendable, Equatable {
        let path: String
        let isEnabled: Bool?
    }

    struct FinderSyncRuntimeHeartbeat: Codable, Sendable, Equatable {
        let event: String
        let bundleIdentifier: String
        let path: String
        let reportedAt: Date

        var isRecent: Bool {
            Date().timeIntervalSince(reportedAt) <= finderSyncHeartbeatMaxAge
        }
    }

    enum FinderSyncStatusKind: String, Sendable {
        case missing
        case signatureInvalid
        case notRegistered
        case disabled
        case indeterminate
        case activeElsewhere
        case needsCleanup
        case registered
        case verified
    }

    struct FinderSyncDiagnostics: Sendable {
        let kind: FinderSyncStatusKind
        let statusText: String
        let detailMessage: String
        let preferredPath: String?
        let activePath: String?
        let problemPaths: [String]
        let registeredPaths: [String]
        let heartbeat: FinderSyncRuntimeHeartbeat?
        let appBundleMissingEntitlements: [String]

        var isOperational: Bool {
            switch kind {
            case .registered, .verified:
                return true
            default:
                return false
            }
        }

        var isVerifiedWorking: Bool {
            kind == .verified
        }

        var needsCodeSignatureRepair: Bool {
            kind == .signatureInvalid && !appBundleMissingEntitlements.isEmpty
        }

        var needsRepair: Bool {
            if needsCodeSignatureRepair {
                return true
            }
            switch kind {
            case .registered, .verified:
                return false
            default:
                return true
            }
        }
    }

    static func shouldAutoRepairFinderSync(
        diagnostics: FinderSyncDiagnostics,
        currentPath: String
    ) -> Bool {
        if diagnostics.needsCodeSignatureRepair {
            return true
        }

        guard let preferredPath = diagnostics.preferredPath else {
            return true
        }

        if !extensionPathsMatch(preferredPath, currentPath) {
            return true
        }

        switch diagnostics.kind {
        case .missing, .signatureInvalid, .notRegistered, .indeterminate, .activeElsewhere, .needsCleanup:
            return true
        case .disabled, .registered, .verified:
            return false
        }
    }

    public static func beginMonitoringFinderSyncRuntime() {
        Task { @MainActor in
            beginMonitoringFinderSyncRuntimeOnMainActor()
        }
    }

    @MainActor
    private static func beginMonitoringFinderSyncRuntimeOnMainActor() {
        guard finderSyncHeartbeatObserver == nil else { return }

        finderSyncHeartbeatObserver = DistributedNotificationCenter.default().addObserver(
            forName: finderSyncHeartbeatNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let heartbeat = finderSyncRuntimeHeartbeat(from: notification.userInfo) else { return }
            cacheFinderSyncRuntimeHeartbeat(heartbeat)
        }
    }

    private static func runCommand(executablePath: String, arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func runCommandAsync(executablePath: String, arguments: [String]) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = runCommand(executablePath: executablePath, arguments: arguments)
                continuation.resume(returning: result)
            }
        }
    }

    private static func commandFailureSummary(_ result: CommandResult) -> String? {
        guard result.exitCode != 0 else { return nil }
        let raw = combinedCommandOutput(result)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "exit code \(result.exitCode)" }
        return raw.replacingOccurrences(of: "\n", with: " ")
    }

    private static func combinedCommandOutput(_ result: CommandResult) -> [String] {
        [result.stderr, result.stdout].filter { !$0.isEmpty }
    }

    private static let finderSyncProcessPathRegex = try? NSRegularExpression(
        pattern: #"(/.+?/SortyFinderSync\.appex)/Contents/MacOS/SortyFinderSync\b"#
    )

    private static func runningFinderSyncExtensionPath() -> String? {
        guard let finderSyncProcessPathRegex else { return nil }

        let result = runCommand(executablePath: "/usr/bin/pgrep", arguments: ["-fl", "SortyFinderSync"])
        guard result.exitCode == 0 else { return nil }

        let output = combinedCommandOutput(result).joined(separator: "\n")
        let searchRange = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = finderSyncProcessPathRegex.firstMatch(in: output, range: searchRange),
              match.numberOfRanges > 1,
              let pathRange = Range(match.range(at: 1), in: output) else {
            return nil
        }

        return String(output[pathRange])
    }

    private static func finderSyncRuntimeHeartbeat(from userInfo: [AnyHashable: Any]?) -> FinderSyncRuntimeHeartbeat? {
        guard let userInfo,
              let path = userInfo["path"] as? String,
              !path.isEmpty else {
            return nil
        }

        let event = (userInfo["event"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleIdentifier = (userInfo["bundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestampValue = userInfo["timestamp"]

        let reportedAt: Date
        switch timestampValue {
        case let value as Double:
            reportedAt = Date(timeIntervalSince1970: value)
        case let value as NSNumber:
            reportedAt = Date(timeIntervalSince1970: value.doubleValue)
        case let value as String:
            reportedAt = Date(timeIntervalSince1970: Double(value) ?? Date().timeIntervalSince1970)
        default:
            reportedAt = Date()
        }

        return FinderSyncRuntimeHeartbeat(
            event: event?.isEmpty == false ? event! : "heartbeat",
            bundleIdentifier: bundleIdentifier?.isEmpty == false ? bundleIdentifier! : finderSyncBundleIdentifier(),
            path: path,
            reportedAt: reportedAt
        )
    }

    private static func cacheFinderSyncRuntimeHeartbeat(_ heartbeat: FinderSyncRuntimeHeartbeat) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(heartbeat) else { return }
        UserDefaults.standard.set(data, forKey: finderSyncHeartbeatDefaultsKey)
    }

    private static func clearCachedFinderSyncRuntimeHeartbeat() {
        UserDefaults.standard.removeObject(forKey: finderSyncHeartbeatDefaultsKey)
    }

    private static func cachedFinderSyncRuntimeHeartbeat() -> FinderSyncRuntimeHeartbeat? {
        guard let data = UserDefaults.standard.data(forKey: finderSyncHeartbeatDefaultsKey) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let heartbeat = try? decoder.decode(FinderSyncRuntimeHeartbeat.self, from: data) else {
            UserDefaults.standard.removeObject(forKey: finderSyncHeartbeatDefaultsKey)
            return nil
        }

        return heartbeat.isRecent ? heartbeat : nil
    }

    private static func finderSyncBundleIdentifier() -> String {
        // Try to get identifier from the actual embedded extension bundle first
        // This avoids mismatches if the main app's bundle ID was overridden at build time
        if let url = currentFinderSyncExtensionURL(),
           let bundle = Bundle(url: url),
           let id = bundle.bundleIdentifier {
            return id
        }

        if let appBundleID = Bundle.main.bundleIdentifier, !appBundleID.isEmpty {
            return appBundleID + finderSyncBundleSuffix
        }
        return "shirishpothi.Sorty.SortyFinderSync"
    }

    private static func finderSyncPluginkitArguments() -> [String] {
        ["-m", "-v", "-A", "-D", "-i", finderSyncBundleIdentifier()]
    }

    private static func currentFinderSyncExtensionURL() -> URL? {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL else { return nil }

        let directPath = pluginsURL.appendingPathComponent(finderSyncExtensionName)
        if FileManager.default.fileExists(atPath: directPath.path) {
            return directPath
        }

        let fallbackPath = pluginsURL.appendingPathComponent("SortyFinderSync.appex")
        if FileManager.default.fileExists(atPath: fallbackPath.path) {
            return fallbackPath
        }

        return nil
    }

    private static func finderSyncExtensionURL(inAppBundleURL appURL: URL) -> URL? {
        let pluginsURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("PlugIns", isDirectory: true)

        let extensionURL = pluginsURL.appendingPathComponent(finderSyncExtensionName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: extensionURL.path) else {
            return nil
        }
        return extensionURL
    }

    private static func hostAppBundleURL(forFinderSyncExtensionURL extensionURL: URL) -> URL {
        extensionURL
            .deletingLastPathComponent() // PlugIns
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // *.app
    }

    static func isFinderSyncRegistrationHostEligible(appBundlePath: String, homeDirectoryPath: String) -> Bool {
        let canonicalPath = URL(fileURLWithPath: appBundlePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        let systemApplicationsPath = URL(fileURLWithPath: systemApplicationsDirectoryPath, isDirectory: true)
            .standardizedFileURL
            .path
        let userApplicationsPath = URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
            .appendingPathComponent(userApplicationsDirectoryName, isDirectory: true)
            .standardizedFileURL
            .path

        func isWithin(_ rootPath: String) -> Bool {
            canonicalPath == rootPath || canonicalPath.hasPrefix(rootPath + "/")
        }

        return isWithin(systemApplicationsPath) || isWithin(userApplicationsPath)
    }

    private static func isFinderSyncRegistrationHostEligible(appURL: URL) -> Bool {
        isFinderSyncRegistrationHostEligible(
            appBundlePath: appURL.path,
            homeDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    private static func candidateFinderSyncExtensionURLsInApplications() -> [URL] {
        let appName = Bundle.main.bundleURL.lastPathComponent
        guard !appName.isEmpty else { return [] }

        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let appCandidates: [URL] = [
            userHome
                .appendingPathComponent(userApplicationsDirectoryName, isDirectory: true)
                .appendingPathComponent(appName, isDirectory: true),
            URL(fileURLWithPath: systemApplicationsDirectoryPath, isDirectory: true)
                .appendingPathComponent(appName, isDirectory: true)
        ]

        var extensions: [URL] = []
        for appURL in appCandidates {
            guard let extensionURL = finderSyncExtensionURL(inAppBundleURL: appURL) else { continue }
            if extensions.contains(where: { extensionPathsMatch($0.path, extensionURL.path) }) {
                continue
            }
            extensions.append(extensionURL)
        }
        return extensions
    }

    private static func preferredRegisteredFinderSyncExtensionURL(from candidates: [URL]) async -> URL? {
        guard !candidates.isEmpty else { return nil }

        let entries = await registeredFinderSyncExtensionEntriesAsync()

        func candidateMatching(path: String) -> URL? {
            candidates.first(where: { extensionPathsMatch($0.path, path) })
        }

        for entry in entries where entry.isEnabled == true {
            if let candidate = candidateMatching(path: entry.path) {
                return candidate
            }
        }

        for entry in entries where entry.isEnabled != false {
            if let candidate = candidateMatching(path: entry.path) {
                return candidate
            }
        }

        return nil
    }

    private static func stageCurrentAppInUserApplications() -> URL? {
        let sourceAppURL = Bundle.main.bundleURL.standardizedFileURL
        let userApplicationsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(userApplicationsDirectoryName, isDirectory: true)
        let destinationAppURL = userApplicationsURL
            .appendingPathComponent(sourceAppURL.lastPathComponent, isDirectory: true)
            .standardizedFileURL

        let sourcePath = sourceAppURL.resolvingSymlinksInPath().standardizedFileURL.path
        let destinationPath = destinationAppURL.resolvingSymlinksInPath().standardizedFileURL.path
        if sourcePath == destinationPath {
            return sourceAppURL
        }

        // Stage into a temporary app first and atomically replace existing copy.
        let stagedName = sourceAppURL
            .deletingPathExtension()
            .lastPathComponent + "-staging-\(UUID().uuidString).app"
        let stagingURL = userApplicationsURL.appendingPathComponent(stagedName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: userApplicationsURL, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: stagingURL)
            try FileManager.default.copyItem(at: sourceAppURL, to: stagingURL)

            if FileManager.default.fileExists(atPath: destinationAppURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationAppURL, withItemAt: stagingURL)
            } else {
                try FileManager.default.moveItem(at: stagingURL, to: destinationAppURL)
            }

            if let identity = applicationFileIdentity(at: destinationAppURL) {
                UserDefaults.standard.set(destinationAppURL.path, forKey: stagedApplicationPathDefaultsKey)
                UserDefaults.standard.set(identity, forKey: stagedApplicationIdentityDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: stagedApplicationPathDefaultsKey)
                UserDefaults.standard.removeObject(forKey: stagedApplicationIdentityDefaultsKey)
            }
            return destinationAppURL
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            return nil
        }
    }

    public static func stagedApplicationURLForUninstall() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: stagedApplicationPathDefaultsKey),
              !path.isEmpty,
              let expectedIdentity = UserDefaults.standard.string(
                forKey: stagedApplicationIdentityDefaultsKey
              ) else {
            return nil
        }

        let applicationURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let userApplicationsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(userApplicationsDirectoryName, isDirectory: true)
            .standardizedFileURL
        guard applicationURL.deletingLastPathComponent().path == userApplicationsURL.path else {
            return nil
        }
        guard applicationFileIdentity(at: applicationURL) == expectedIdentity else {
            return nil
        }
        return applicationURL
    }

    private static func applicationFileIdentity(at applicationURL: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: applicationURL.path),
              let systemNumber = attributes[.systemNumber] as? NSNumber,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return "\(systemNumber.uint64Value):\(fileNumber.uint64Value)"
    }

    private static func finderSyncExtensionURLForRepair() -> (url: URL?, stagedAppPath: String?) {
        guard let currentExtensionURL = currentFinderSyncExtensionURL() else {
            return (nil, nil)
        }

        let currentAppURL = hostAppBundleURL(forFinderSyncExtensionURL: currentExtensionURL)
        if isFinderSyncRegistrationHostEligible(appURL: currentAppURL) {
            return (currentExtensionURL, nil)
        }

        if let stagedAppURL = stageCurrentAppInUserApplications(),
           let stagedExtensionURL = finderSyncExtensionURL(inAppBundleURL: stagedAppURL) {
            return (stagedExtensionURL, stagedAppURL.path)
        }

        if let existingApplicationsExtension = candidateFinderSyncExtensionURLsInApplications().first {
            return (existingApplicationsExtension, nil)
        }

        return (currentExtensionURL, nil)
    }

    private static func preferredFinderSyncExtensionURLForRegistration() async -> URL? {
        guard let currentExtensionURL = currentFinderSyncExtensionURL() else { return nil }

        let currentAppURL = hostAppBundleURL(forFinderSyncExtensionURL: currentExtensionURL)
        if isFinderSyncRegistrationHostEligible(appURL: currentAppURL) {
            return currentExtensionURL
        }

        let candidates = candidateFinderSyncExtensionURLsInApplications()

        if let registeredCandidate = await preferredRegisteredFinderSyncExtensionURL(from: candidates) {
            return registeredCandidate
        }

        if let heartbeatPath = cachedFinderSyncRuntimeHeartbeat()?.path,
           let heartbeatCandidate = candidates.first(where: { extensionPathsMatch($0.path, heartbeatPath) }) {
            return heartbeatCandidate
        }

        return candidates.first ?? currentExtensionURL
    }

    private static func extractAppeXPath(from line: String) -> String? {
        let tabParts = line
            .split(separator: "\t")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let path = tabParts.last, path.hasSuffix(".appex") {
            return path
        }

        guard let start = line.firstIndex(of: "/"),
              let appexRange = line.range(of: ".appex", options: .backwards) else {
            return nil
        }
        return String(line[start...appexRange.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalExtensionPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func extensionPathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        canonicalExtensionPath(lhs) == canonicalExtensionPath(rhs)
    }

    static func parseFinderSyncRegistrationEntries(from output: String) -> [FinderSyncRegistrationEntry] {
        var entries: [FinderSyncRegistrationEntry] = []

        for rawLine in output.split(separator: "\n").map(String.init) {
            guard let path = extractAppeXPath(from: rawLine) else { continue }

            let marker = rawLine.first(where: { !$0.isWhitespace })
            let isEnabled: Bool?
            switch marker {
            case "+":
                isEnabled = true
            case "-":
                isEnabled = false
            default:
                // Some extension classes omit explicit +/- markers in pluginkit output.
                isEnabled = nil
            }

            if let existingIndex = entries.firstIndex(where: { extensionPathsMatch($0.path, path) }) {
                // Prefer explicit enabled/disabled markers over unknown marker state.
                if entries[existingIndex].isEnabled == nil, isEnabled != nil {
                    entries[existingIndex] = FinderSyncRegistrationEntry(path: path, isEnabled: isEnabled)
                }
                continue
            }

            entries.append(FinderSyncRegistrationEntry(path: path, isEnabled: isEnabled))
        }

        return entries
    }

    static func parseEntitlementsPlist(from output: String) -> [String: Any]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    static func missingFinderIntegrationAppEntitlements(in entitlements: [String: Any]) -> [String] {
        // The host app no longer depends on sandbox-scoped entitlements for
        // Finder integration. The embedded extension remains separately
        // entitled; communication falls back to distributed notifications.
        _ = entitlements
        _ = finderRepairRequiredAppGroup
        return []
    }

    private static func currentAppMissingFinderIntegrationEntitlementsAsync() async -> [String] {
        let result = await runCommandAsync(
            executablePath: "/usr/bin/codesign",
            arguments: ["-d", "--entitlements", ":-", Bundle.main.bundleURL.path]
        )

        let output = combinedCommandOutput(result)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entitlements = parseEntitlementsPlist(from: output) else { return [] }
        return missingFinderIntegrationAppEntitlements(in: entitlements)
    }

    private static func repairEntitlementsFileContents() -> String? {
        if let url = SortyResources.urlForCopiedResource(named: finderRepairEntitlementsResourceName),
           let contents = try? String(contentsOf: url, encoding: .utf8),
           !contents.isEmpty {
            return contents
        }
        return nil
    }

    private static func temporaryEntitlementsFileURL(contents: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorty-finder-repair", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(UUID().uuidString + ".entitlements")
            guard let data = contents.data(using: .utf8) else { return nil }
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func scheduleDeferredAppCodeSignatureRepair(
        entitlementsURL: URL,
        appURL: URL
    ) -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorty-finder-repair", isDirectory: true)
        let scriptURL = directory.appendingPathComponent(UUID().uuidString + ".sh")
        let logURL = directory.appendingPathComponent(UUID().uuidString + ".log")
        let currentPID = ProcessInfo.processInfo.processIdentifier

        let script = """
        #!/bin/sh
        TARGET_PID="$1"
        APP_PATH="$2"
        ENTITLEMENTS_PATH="$3"
        LOG_PATH="$4"

        while kill -0 "$TARGET_PID" 2>/dev/null; do
            sleep 1
        done

        /usr/bin/codesign --force --sign - --entitlements "$ENTITLEMENTS_PATH" "$APP_PATH" >>"$LOG_PATH" 2>&1 || exit 1
        /usr/bin/open "$APP_PATH" >>"$LOG_PATH" 2>&1 || true
        rm -f "$ENTITLEMENTS_PATH" "$0"
        exit 0
        """

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptURL.path, String(currentPID), appURL.path, entitlementsURL.path, logURL.path]
            try process.run()
            return true
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
            return false
        }
    }

    private static func shouldDeferCodeSignatureRepair(_ result: CommandResult) -> Bool {
        let detail = commandFailureSummary(result)?.lowercased() ?? ""
        return detail.contains("operation not permitted")
    }

    private static func requestAppTerminationForDeferredRepair() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .forceQuitSorty, object: nil)
            NSApplication.shared.terminate(nil)
        }
    }

    private static func repairCurrentAppCodeSignatureIfNeededAsync() async -> (success: Bool, message: String, didResign: Bool, scheduledDeferredRepair: Bool) {
        let missingEntitlements = await currentAppMissingFinderIntegrationEntitlementsAsync()
        guard !missingEntitlements.isEmpty else {
            return (true, "", false, false)
        }

        guard let entitlementsContents = repairEntitlementsFileContents(),
              let entitlementsURL = temporaryEntitlementsFileURL(contents: entitlementsContents) else {
            return (false, "Sorty could not load the bundled Finder repair entitlements.", false, false)
        }

        let result = await runCommandAsync(
            executablePath: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", "--entitlements", entitlementsURL.path, Bundle.main.bundleURL.path]
        )

        guard result.exitCode == 0 else {
            if shouldDeferCodeSignatureRepair(result),
               scheduleDeferredAppCodeSignatureRepair(entitlementsURL: entitlementsURL, appURL: Bundle.main.bundleURL) {
                requestAppTerminationForDeferredRepair()
                return (
                    true,
                    "Sorty needs one relaunch to repair this build's code signature. Repair has been staged; Sorty will quit, re-sign itself out-of-process, and reopen automatically.",
                    false,
                    true
                )
            }

            defer { try? FileManager.default.removeItem(at: entitlementsURL) }
            let detail = commandFailureSummary(result) ?? "codesign failed"
            return (false, "Sorty could not re-sign this build for Finder integration (\(detail)).", false, false)
        }
        defer { try? FileManager.default.removeItem(at: entitlementsURL) }

        let remainingMissingEntitlements = await currentAppMissingFinderIntegrationEntitlementsAsync()
        guard remainingMissingEntitlements.isEmpty else {
            return (
                false,
                "Sorty re-signed the app bundle, but macOS still reports missing Finder entitlements: \(remainingMissingEntitlements.joined(separator: ", ")).",
                true,
                false
            )
        }

        return (true, "Re-signed this Sorty build with the Finder entitlements it was missing.", true, false)
    }

    private static func registeredFinderSyncExtensionPathsAsync() async -> [String] {
        let result = await runCommandAsync(
            executablePath: "/usr/bin/pluginkit",
            arguments: finderSyncPluginkitArguments()
        )

        guard result.exitCode == 0 else { return [] }

        var paths: [String] = []
        for line in result.stdout.split(separator: "\n").map(String.init) {
            if let path = extractAppeXPath(from: line),
               !paths.contains(where: { extensionPathsMatch($0, path) }) {
                paths.append(path)
            }
        }
        return paths
    }

    private static func registeredFinderSyncExtensionEntriesAsync() async -> [FinderSyncRegistrationEntry] {
        let result = await runCommandAsync(
            executablePath: "/usr/bin/pluginkit",
            arguments: finderSyncPluginkitArguments()
        )

        guard result.exitCode == 0 else { return [] }
        return parseFinderSyncRegistrationEntries(from: result.stdout)
    }

    private static func waitForFinderSyncDiagnosticsVerificationAsync(timeout: TimeInterval) async -> FinderSyncDiagnostics {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = await getFinderSyncDiagnosticsAsync()
        while Date() < deadline {
            if latest.isVerifiedWorking {
                return latest
            }
            try? await Task.sleep(nanoseconds: UInt64(finderRepairVerificationPollInterval * 1_000_000_000))
            latest = await getFinderSyncDiagnosticsAsync()
        }
        return latest
    }

    static func finderSyncDiagnostics(
        entries: [FinderSyncRegistrationEntry],
        preferredPath: String?,
        heartbeat: FinderSyncRuntimeHeartbeat?,
        runningProcessPath: String? = nil,
        appBundleMissingEntitlements: [String] = []
    ) -> FinderSyncDiagnostics {
        let recentHeartbeat = heartbeat?.isRecent == true ? heartbeat : nil
        let preferredEntry = preferredPath.flatMap { preferredPath in
            entries.first(where: { extensionPathsMatch($0.path, preferredPath) })
        }
        let enabledEntries = entries.filter { $0.isEnabled == true }
        let ambiguousEntries = entries.filter { $0.isEnabled == nil }
        let runtimeActivePath = recentHeartbeat?.path ?? runningProcessPath
        let activePath = runtimeActivePath ?? enabledEntries.first?.path
        let problemEntries = entries.filter { entry in
            guard let preferredPath else { return entry.isEnabled != false }
            return !extensionPathsMatch(entry.path, preferredPath) && entry.isEnabled != false
        }
        let problemPaths = problemEntries.map(\.path)

        func diagnostics(kind: FinderSyncStatusKind, statusText: String, detail: String) -> FinderSyncDiagnostics {
            FinderSyncDiagnostics(
                kind: kind,
                statusText: statusText,
                detailMessage: detail,
                preferredPath: preferredPath,
                activePath: activePath,
                problemPaths: problemPaths,
                registeredPaths: entries.map(\.path),
                heartbeat: recentHeartbeat,
                appBundleMissingEntitlements: appBundleMissingEntitlements
            )
        }

        guard let preferredPath else {
            return diagnostics(
                kind: .missing,
                statusText: "Missing",
                detail: "Sorty could not find an embedded Finder Sync extension in this app bundle. Rebuild with ENABLE_FINDER_EXTENSION=true."
            )
        }

        if let runtimeActivePath, !extensionPathsMatch(runtimeActivePath, preferredPath) {
            return diagnostics(
                kind: .activeElsewhere,
                statusText: "Another App Copy Active",
                detail: "Finder recently loaded a different Sorty app copy. Repair will remove stale registrations and switch Finder back to this build."
            )
        }

        guard !entries.isEmpty else {
            return diagnostics(
                kind: .notRegistered,
                statusText: "Not Registered",
                detail: "Finder does not have Sorty registered yet. Repair will register the extension and restart Finder."
            )
        }

        guard let preferredEntry else {
            if enabledEntries.isEmpty, !ambiguousEntries.isEmpty {
                return diagnostics(
                    kind: .indeterminate,
                    statusText: "Needs Repair",
                    detail: "Finder knows about Sorty, but macOS did not report the preferred app copy as enabled. Repair will rebuild the registration."
                )
            }

            return diagnostics(
                kind: .activeElsewhere,
                statusText: "Another App Copy Active",
                detail: "Finder is registered to another Sorty app copy instead of this build. Repair will remove the stale copy and switch Finder back."
            )
        }

        switch preferredEntry.isEnabled {
        case false:
            return diagnostics(
                kind: .disabled,
                statusText: "Disabled",
                detail: "The Sorty Finder extension is registered, but Finder currently has it disabled. Repair will re-enable it and restart Finder."
            )
        case nil:
            return diagnostics(
                kind: .indeterminate,
                statusText: "Needs Repair",
                detail: "macOS reported the Sorty Finder extension in an indeterminate state. Repair will rebuild the registration from scratch."
            )
        case true:
            if !problemPaths.isEmpty {
                return diagnostics(
                    kind: .needsCleanup,
                    statusText: "Cleanup Needed",
                    detail: "Finder still has stale Sorty extension registrations from other app copies. Repair will clean those up so this build stays active."
                )
            }

            if let runtimeActivePath, extensionPathsMatch(runtimeActivePath, preferredPath) {
                return diagnostics(
                    kind: .verified,
                    statusText: "Verified Working",
                    detail: "Finder recently loaded this Sorty extension build, so the right-click menu should be available."
                )
            }

            return diagnostics(
                kind: .registered,
                statusText: "Registered",
                detail: "Finder has the correct Sorty registration, but Sorty has not yet confirmed this build loaded into Finder. If the menu is missing, click Repair."
            )
        }
    }

    static func getFinderSyncDiagnosticsAsync() async -> FinderSyncDiagnostics {
        await FinderSyncDiagnosticsGate.shared.run {
            await collectFinderSyncDiagnostics()
        }
    }

    private static func collectFinderSyncDiagnostics() async -> FinderSyncDiagnostics {
        beginMonitoringFinderSyncRuntime()
        let entries = await registeredFinderSyncExtensionEntriesAsync()
        return finderSyncDiagnostics(
            entries: entries,
            preferredPath: await preferredFinderSyncExtensionURLForRegistration()?.path,
            heartbeat: cachedFinderSyncRuntimeHeartbeat(),
            runningProcessPath: runningFinderSyncExtensionPath(),
            appBundleMissingEntitlements: await currentAppMissingFinderIntegrationEntitlementsAsync()
        )
    }

    public static func isFinderSyncExtensionActiveAsync() async -> Bool {
        (await getFinderSyncDiagnosticsAsync()).isOperational
    }

    public static func repairFinderSyncExtensionRegistrationAsync(restartFinder: Bool = true) async -> (success: Bool, message: String) {
        let registrationTarget = finderSyncExtensionURLForRepair()
        guard let currentExtensionURL = registrationTarget.url else {
            return (false, "Finder Sync extension (.appex) is missing from this app bundle. Rebuild with ENABLE_FINDER_EXTENSION=true.")
        }

        let currentPath = currentExtensionURL.path
        let stagedAppPath = registrationTarget.stagedAppPath
        let bundleIdentifier = finderSyncBundleIdentifier()

        beginMonitoringFinderSyncRuntime()
        clearCachedFinderSyncRuntimeHeartbeat()

        let codeSignatureRepair = await repairCurrentAppCodeSignatureIfNeededAsync()
        guard codeSignatureRepair.success else {
            return (false, codeSignatureRepair.message)
        }
        if codeSignatureRepair.scheduledDeferredRepair {
            return (true, codeSignatureRepair.message)
        }

        // Kill any running instance of the extension so macOS loads the fresh one
        _ = await runCommandAsync(executablePath: "/usr/bin/pkill", arguments: ["-f", "SortyFinderSync"])

        let beforePaths = await registeredFinderSyncExtensionPathsAsync()
        var removedStaleCount = 0
        var removeFailures = 0

        for path in beforePaths where !extensionPathsMatch(path, currentPath) {
            let removeResult = await runCommandAsync(executablePath: "/usr/bin/pluginkit", arguments: ["-r", path])
            if removeResult.exitCode == 0 {
                removedStaleCount += 1
            } else {
                removeFailures += 1
            }
        }

        // Also remove any existing registration at the current path to force
        // pluginkit to re-read the on-disk binary (picks up new builds).
        _ = await runCommandAsync(executablePath: "/usr/bin/pluginkit", arguments: ["-r", currentPath])

        let addResult = await runCommandAsync(executablePath: "/usr/bin/pluginkit", arguments: ["-a", currentPath])
        let useResult = await runCommandAsync(executablePath: "/usr/bin/pluginkit", arguments: ["-e", "use", "-i", bundleIdentifier])
        if restartFinder {
            _ = await runCommandAsync(executablePath: "/usr/bin/killall", arguments: ["Finder"])
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        let diagnostics = await waitForFinderSyncDiagnosticsVerificationAsync(timeout: finderRepairVerificationTimeout)
        let repairVerified = diagnostics.isVerifiedWorking || diagnostics.kind == .registered || diagnostics.kind == .needsCleanup
        UserDefaults.standard.set(repairVerified, forKey: "enableFinderSyncExtension")

        guard repairVerified else {
            var details: [String] = []
            if addResult.exitCode != 0 { details.append("register failed") }
            if useResult.exitCode != 0 { details.append("enable failed") }
            if diagnostics.problemPaths.isEmpty {
                details.append(diagnostics.statusText.lowercased())
            }
            if diagnostics.kind == .registered {
                details.append("Finder never loaded this build after restart")
            }
            if !isFinderSyncRegistrationHostEligible(appURL: hostAppBundleURL(forFinderSyncExtensionURL: currentExtensionURL)) {
                details.append("registration path is outside /Applications")
            }
            if let detail = commandFailureSummary(addResult) {
                details.append(detail)
            }
            if let detail = commandFailureSummary(useResult) {
                details.append(detail)
            }
            if details.isEmpty {
                details.append(diagnostics.statusText.lowercased())
            }
            return (false, "Finder Sync repair could not verify this build loaded into Finder (\(details.joined(separator: ", "))). The repair cleared stale registrations and restarted Finder, but macOS still did not activate this extension. Open System Settings → Privacy & Security → Extensions → Finder, confirm Sorty is enabled, then click Repair again.")
        }

        var messageParts: [String] = []
        if codeSignatureRepair.didResign {
            messageParts.append(codeSignatureRepair.message)
        }
        var message = diagnostics.detailMessage
        if diagnostics.kind == .registered {
            message += " Finder loads this extension lazily; right-click any folder once if the menu is not visible yet."
        }
        if removedStaleCount > 0 {
            message += " Removed \(removedStaleCount) stale registration(s)."
        }
        if removeFailures > 0 {
            message += " \(removeFailures) stale registration(s) could not be removed."
        }
        if let stagedAppPath {
            message += " Registered this build at \(stagedAppPath) so Finder can activate the right-click menu."
        }
        messageParts.append(message)
        return (true, messageParts.filter { !$0.isEmpty }.joined(separator: " "))
    }

    /// Silently re-registers the Finder Sync extension on launch when the
    /// currently registered path doesn't match this build.  This prevents
    /// the extension from going missing after a rebuild or after switching
    /// between release and debug builds.
    public static func autoRepairFinderSyncIfNeeded() async {
        await FinderSyncAutoRepairGate.shared.run {
            guard let currentExtensionURL = currentFinderSyncExtensionURL() else {
                return
            }
            let currentPath = currentExtensionURL.path

            let diagnostics = await getFinderSyncDiagnosticsAsync()

            if !shouldAutoRepairFinderSync(diagnostics: diagnostics, currentPath: currentPath) {
                return
            }

            _ = await repairFinderSyncExtensionRegistrationAsync(restartFinder: true)
        }
    }

    // MARK: - Quick Action Installation

    private static func currentUserHomeDirectoryURL() -> URL {
        if let pwd = getpwuid(getuid()), let home = pwd.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static func defaultServicesDirectoryURL() -> URL {
        currentUserHomeDirectoryURL().appendingPathComponent("Library/Services", isDirectory: true)
    }

    private static func savedServicesDirectoryURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: servicesDirectoryPathDefaultsKey),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func candidateServicesDirectories() -> [URL] {
        var directories: [URL] = []
        if let saved = savedServicesDirectoryURL() {
            directories.append(saved)
        }
        directories.append(defaultServicesDirectoryURL())

        var unique: [URL] = []
        for directory in directories where !unique.contains(where: { $0.path == directory.path }) {
            unique.append(directory)
        }
        return unique
    }

    private static var isRunningInSandbox: Bool {
        let home = currentUserHomeDirectoryURL().path
        let containerDir = home + "/Library/Containers/"
        let cwd = FileManager.default.currentDirectoryPath
        return cwd.hasPrefix(containerDir)
    }

    private static func canWriteWorkflow(in servicesDirectory: URL, userSelected: Bool = false) -> Bool {
        // In a sandboxed app, writes to ~/Library/Services/ are silently
        // redirected into the container (~/Library/Containers/<id>/Data/Library/Services/).
        // The files end up invisible to macOS Quick Actions.
        // If we're sandboxed and this is the default services path (not user-selected
        // via NSOpenPanel), reject it so the caller falls through to the open panel.
        // Directories selected via NSOpenPanel bypass this check because the sandbox
        // grants real access to the chosen path.
        if !userSelected && isRunningInSandbox {
            let defaultPath = defaultServicesDirectoryURL().standardizedFileURL.path
            let candidatePath = servicesDirectory.standardizedFileURL.path
            if candidatePath == defaultPath {
                return false
            }
        }

        do {
            try FileManager.default.createDirectory(at: servicesDirectory, withIntermediateDirectories: true)
            let probeURL = servicesDirectory.appendingPathComponent(".sorty-write-check")
            try Data("ok".utf8).write(to: probeURL)
            try? FileManager.default.removeItem(at: probeURL)
            return true
        } catch {
            return false
        }
    }

    private static func presentServicesDirectoryAccessPanel(suggestedDirectory: URL) -> URL? {
        // AppKit panel APIs are main-actor isolated on newer SDKs.
        return MainActor.assumeIsolated {
            let panel = NSOpenPanel()
            panel.title = "Allow Access to Finder Quick Actions Folder"
            panel.message = "Select your ~/Library/Services folder so Sorty can install the Finder Quick Action."
            panel.prompt = "Allow Access"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.directoryURL = suggestedDirectory

            guard panel.runModal() == .OK, let selectedDirectory = panel.url else {
                return nil
            }
            return selectedDirectory
        }
    }

    private static func promptForServicesDirectoryAccess(suggestedDirectory: URL) -> URL? {
        // NSOpenPanel (AppKit window creation) must run on the main thread.
        if Thread.isMainThread {
            return presentServicesDirectoryAccessPanel(suggestedDirectory: suggestedDirectory)
        }

        return DispatchQueue.main.sync {
            presentServicesDirectoryAccessPanel(suggestedDirectory: suggestedDirectory)
        }
    }

    private static func resolveServicesDirectoryForInstall() -> URL? {
        for directory in candidateServicesDirectories() {
            if canWriteWorkflow(in: directory) {
                UserDefaults.standard.set(directory.path, forKey: servicesDirectoryPathDefaultsKey)
                return directory
            }
        }

        // In sandboxed/signed builds this path may require user-granted access.
        // NSOpenPanel grants real filesystem access outside the sandbox container,
        // so skip the sandbox-redirect check for the user-selected directory.
        if let selectedDirectory = promptForServicesDirectoryAccess(suggestedDirectory: defaultServicesDirectoryURL()),
           canWriteWorkflow(in: selectedDirectory, userSelected: true) {
            UserDefaults.standard.set(selectedDirectory.path, forKey: servicesDirectoryPathDefaultsKey)
            return selectedDirectory
        }

        return nil
    }

    private static func workflowHasFinderContext(infoPlist: [String: Any]) -> Bool {
        guard let services = infoPlist["NSServices"] as? [[String: Any]], let firstService = services.first,
              let requiredContext = firstService["NSRequiredContext"] as? [String: Any],
              let appIdentifier = requiredContext["NSApplicationIdentifier"] as? String else {
            return false
        }
        return appIdentifier == "com.apple.finder"
    }

    private enum QuickActionIconStyle {
        case organize
        case watch
        case exclude
    }

    private static func isSystemUsingDarkAppearance() -> Bool {
        guard let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") else {
            return false
        }
        return style.caseInsensitiveCompare("Dark") == .orderedSame
    }

    private static func currentWatchWorkflowIconVariant() -> String {
        isSystemUsingDarkAppearance() ? "dark" : "light"
    }

    private static func preferredWatchIconBaseNames() -> [String] {
        if isSystemUsingDarkAppearance() {
            // Quick Action icons are rasterized files; use explicit white glyph in dark mode.
            return ["eye_white", "eye_black", "WatchIconTemplate"]
        }
        return ["eye_black", "eye_white", "WatchIconTemplate"]
    }

    private static func quickActionMascotIconURLCandidates() -> [URL] {
        let finderSyncResources = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("SortyFinderSync.appex/Contents/Resources", isDirectory: true)
        let roots: [URL] = [
            Bundle.main.bundleURL,
            Bundle.main.resourceURL,
            SortyResources.bundle.resourceURL,
            finderSyncResources
        ].compactMap { $0 }

        var candidates: [URL] = []
        for root in roots {
            candidates.append(root.appendingPathComponent("SortyMascotHead.icns"))
            candidates.append(root.appendingPathComponent("Sorty Mascot Head.icns"))
            candidates.append(root.appendingPathComponent("AppIcon.icns"))
            candidates.append(root.appendingPathComponent("SortyLib_SortyLib.bundle/SortyMascotHead.icns"))
            candidates.append(root.appendingPathComponent("SortyLib_SortyLib.bundle/AppIcon.icns"))
        }

        var unique: [URL] = []
        for candidate in candidates where !unique.contains(where: { $0.path == candidate.path }) {
            unique.append(candidate)
        }
        return unique
    }

    private static func quickActionMascotSVGURLCandidates() -> [URL] {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let finderSyncResources = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("SortyFinderSync.appex/Contents/Resources", isDirectory: true)
        let roots: [URL] = [
            Bundle.main.resourceURL,
            SortyResources.bundle.resourceURL,
            finderSyncResources
        ].compactMap { $0 }

        var candidates: [URL] = []
        for root in roots {
            candidates.append(root.appendingPathComponent("SortyFinderSyncMenuIcon.svg"))
            candidates.append(root.appendingPathComponent("SortyMascotTemplate.svg"))
            candidates.append(root.appendingPathComponent("SortyLib_SortyLib.bundle/SortyMascotTemplate.svg"))
        }

        candidates.append(cwd.appendingPathComponent("SortyFinderSync/SortyFinderSyncMenuIcon.svg"))
        candidates.append(cwd.appendingPathComponent("Sources/SortyLib/Resources/SortyMascotTemplate.svg"))

        var unique: [URL] = []
        for candidate in candidates where !unique.contains(where: { $0.path == candidate.path }) {
            unique.append(candidate)
        }
        return unique
    }

    private static func quickActionWatchIconURLCandidates() -> [URL] {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let finderSyncResources = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("SortyFinderSync.appex/Contents/Resources", isDirectory: true)
        let roots: [URL] = [
            Bundle.main.bundleURL,
            Bundle.main.resourceURL,
            SortyResources.bundle.resourceURL,
            finderSyncResources
        ].compactMap { $0 }

        var candidates: [URL] = []
        let preferredBaseNames = preferredWatchIconBaseNames()
        for root in roots {
            for baseName in preferredBaseNames {
                candidates.append(root.appendingPathComponent("\(baseName).png"))
                candidates.append(root.appendingPathComponent("Assets.xcassets/WatchIcon.imageset/\(baseName).png"))
                candidates.append(root.appendingPathComponent("SortyLib_SortyLib.bundle/\(baseName).png"))
                candidates.append(root.appendingPathComponent("SortyLib_SortyLib.bundle/Assets.xcassets/WatchIcon.imageset/\(baseName).png"))
            }
        }

        for baseName in preferredBaseNames {
            candidates.append(cwd.appendingPathComponent("Resources/\(baseName).png"))
            candidates.append(cwd.appendingPathComponent("Resources/Assets.xcassets/WatchIcon.imageset/\(baseName).png"))
        }

        var unique: [URL] = []
        for candidate in candidates where !unique.contains(where: { $0.path == candidate.path }) {
            unique.append(candidate)
        }
        return unique
    }

    private static func quickActionWatchTemplateImage() -> NSImage? {
        for candidate in quickActionWatchIconURLCandidates() where FileManager.default.fileExists(atPath: candidate.path) {
            if let image = NSImage(contentsOf: candidate) {
                image.isTemplate = false
                return image
            }
        }

        return nil
    }

    private static func quickActionGeneratedMascotImage(named resourceName: String) -> NSImage? {
        let finderSyncResources = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("SortyFinderSync.appex/Contents/Resources", isDirectory: true)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let candidates = [
            finderSyncResources?.appendingPathComponent("\(resourceName).png"),
            cwd.appendingPathComponent("SortyFinderSync/\(resourceName).png"),
            cwd.appendingPathComponent("Sources/SortyLib/Resources/Images/\(resourceName).png")
        ].compactMap { $0 }

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let image = NSImage(contentsOf: candidate) {
                image.isTemplate = false
                return image
            }
        }
        return nil
    }

    private static func quickActionIconImage(style: QuickActionIconStyle) -> NSImage {
        switch style {
        case .organize:
            if let mascot = quickActionGeneratedMascotImage(named: "SortyMenuOrganizing") {
                return mascot
            }

            // Prefer the full-color mascot head icns for workflow icons.
            for candidate in quickActionMascotIconURLCandidates() where FileManager.default.fileExists(atPath: candidate.path) {
                if let head = NSImage(contentsOf: candidate) {
                    head.isTemplate = false
                    return head
                }
            }

            for candidate in quickActionMascotSVGURLCandidates() where FileManager.default.fileExists(atPath: candidate.path) {
                if let mascot = NSImage(contentsOf: candidate) {
                    mascot.isTemplate = false
                    return mascot
                }
            }

            if let mascot = SortyResources.image(named: "SortyMascotHead", withExtension: "png")
                ?? SortyResources.image(named: "SortyMascot", withExtension: "svg")
                ?? SortyResources.image(named: "SortyMascotTemplate", withExtension: "svg") {
                mascot.isTemplate = false
                return mascot
            }

            let fallback = SortyResources.menuBarNSImage()
            fallback.isTemplate = false
            return fallback

        case .watch:
            if let mascot = quickActionGeneratedMascotImage(named: "SortyWatchMascot") {
                return mascot
            }

            if let watchTemplateImage = quickActionWatchTemplateImage() {
                return watchTemplateImage
            }

            let symbol = NSImage(systemSymbolName: "eye", accessibilityDescription: "Watch with Sorty")
                ?? NSImage(systemSymbolName: "folder", accessibilityDescription: "Watch with Sorty")
                ?? NSImage(size: NSSize(width: 256, height: 256))
            let config = NSImage.SymbolConfiguration(pointSize: 120, weight: .regular)
            let configured = symbol.withSymbolConfiguration(config) ?? symbol
            let drawColor = isSystemUsingDarkAppearance() ? NSColor.white : NSColor.black
            let targetSize = NSSize(width: 256, height: 256)
            let rendered = NSImage(size: targetSize)
            rendered.lockFocus()
            drawColor.set()
            configured.draw(
                in: NSRect(origin: .zero, size: targetSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
            rendered.unlockFocus()
            rendered.isTemplate = false
            return rendered

        case .exclude:
            if let mascot = quickActionGeneratedMascotImage(named: "SortyExcludeMascot") {
                return mascot
            }

            let fallback = NSImage(
                systemSymbolName: "folder.badge.minus",
                accessibilityDescription: "Exclude from Sorty"
            ) ?? NSImage(size: NSSize(width: 256, height: 256))
            fallback.isTemplate = false
            return fallback
        }
    }

    private static func renderedPNGData(for image: NSImage, size: NSSize = NSSize(width: 256, height: 256)) -> Data? {
        let renderedImage = NSImage(size: size)
        renderedImage.lockFocus()
        let srcSize = image.size
        if srcSize.width > 0, srcSize.height > 0 {
            let scale = min(size.width / srcSize.width, size.height / srcSize.height)
            let drawSize = NSSize(width: srcSize.width * scale, height: srcSize.height * scale)
            let origin = NSPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
            image.draw(in: NSRect(origin: origin, size: drawSize), from: .zero, operation: .sourceOver, fraction: 1.0)
        } else {
            image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        renderedImage.unlockFocus()

        guard let tiffData = renderedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func applyQuickActionIcon(
        workflowDir: URL,
        contentsDir: URL,
        style: QuickActionIconStyle = .organize
    ) {
        let iconImage = quickActionIconImage(style: style)

        // Use the action-specific mascot instead of Automator's default wand icon.
        _ = NSWorkspace.shared.setIcon(iconImage, forFile: workflowDir.path, options: [])

        do {
            let resourcesDir = contentsDir.appendingPathComponent("Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

            // Finder Quick Actions look up icon name via NSServices.NSIconName,
            // while some surfaces still use bundle icon keys.
            let iconNames = style == .watch
                ? [quickActionServiceIconName]
                : [quickActionIconBaseName, quickActionServiceIconName]

            guard let pngData = renderedPNGData(for: iconImage) else { return }
            for iconName in iconNames {
                let iconPath = resourcesDir.appendingPathComponent("\(iconName).png")
                try pngData.write(to: iconPath, options: .atomic)
            }

            // Also write a tiff representation since some macOS surfaces prefer it
            if let tiffData = iconImage.tiffRepresentation {
                for iconName in iconNames {
                    let tiffPath = resourcesDir.appendingPathComponent("\(iconName).tiff")
                    try tiffData.write(to: tiffPath, options: .atomic)
                }
            }
        } catch {
            // Best-effort only.
        }

        // Clear Finder's icon cache for this workflow
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        if FileManager.default.fileExists(atPath: lsregister) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: lsregister)
            process.arguments = ["-f", workflowDir.path]
            try? process.run()
            process.waitUntilExit()
        }
    }

    private static func replaceWorkflowDirectoryIfNeeded(_ workflowDir: URL) throws {
        if FileManager.default.fileExists(atPath: workflowDir.path) {
            // Finder can keep stale icon metadata when workflow packages are updated in place.
            // Replace the whole package during reinstall so icon and plist changes are applied.
            try FileManager.default.removeItem(at: workflowDir)
        }
    }

    private static func isWorkflowInstalledAndCompatible(workflowName: String, bundleIdentifier: String) -> Bool {
        for servicesDir in candidateServicesDirectories() {
            let workflowPath = servicesDir.appendingPathComponent(workflowName)
            guard FileManager.default.fileExists(atPath: workflowPath.path) else { continue }

            let infoPath = workflowPath.appendingPathComponent("Contents/Info.plist")
            guard let info = NSDictionary(contentsOf: infoPath) as? [String: Any],
                  let currentBundleIdentifier = info["CFBundleIdentifier"] as? String,
                  currentBundleIdentifier == bundleIdentifier,
                  workflowHasFinderContext(infoPlist: info) else {
                continue
            }

            return true
        }
        return false
    }

    private static func hasInstalledWatchWorkflowPackage() -> Bool {
        candidateServicesDirectories().contains { servicesDir in
            let workflowPath = servicesDir.appendingPathComponent(watchQuickActionWorkflowName)
            return FileManager.default.fileExists(atPath: workflowPath.path)
        }
    }

    private static func watchWorkflowUsesExpectedIconConfiguration(
        workflowPath: URL,
        infoPlist: [String: Any]
    ) -> Bool {
        guard infoPlist["CFBundleIconFile"] as? String == quickActionServiceIconName else {
            return false
        }

        guard infoPlist[watchWorkflowIconVariantInfoKey] as? String == currentWatchWorkflowIconVariant() else {
            return false
        }

        let resourcesDir = workflowPath.appendingPathComponent("Contents/Resources", isDirectory: true)
        let servicePNG = resourcesDir.appendingPathComponent("\(quickActionServiceIconName).png")
        guard FileManager.default.fileExists(atPath: servicePNG.path) else {
            return false
        }

        let legacyIconCandidates = ["Icon", "Icon\r"]
        for iconName in legacyIconCandidates {
            let candidate = workflowPath.appendingPathComponent(iconName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return false
            }
        }

        return true
    }

    private static func isWatchWorkflowInstalledAndCompatible() -> Bool {
        for servicesDir in candidateServicesDirectories() {
            let workflowPath = servicesDir.appendingPathComponent(watchQuickActionWorkflowName)
            guard FileManager.default.fileExists(atPath: workflowPath.path) else { continue }

            let infoPath = workflowPath.appendingPathComponent("Contents/Info.plist")
            guard let info = NSDictionary(contentsOf: infoPath) as? [String: Any],
                  let currentBundleIdentifier = info["CFBundleIdentifier"] as? String,
                  currentBundleIdentifier == watchQuickActionBundleIdentifier,
                  workflowHasFinderContext(infoPlist: info),
                  watchWorkflowUsesExpectedIconConfiguration(workflowPath: workflowPath, infoPlist: info) else {
                continue
            }

            return true
        }

        return false
    }

    private static func serviceStatusKeySuffix(menuTitle: String) -> String {
        " - \(menuTitle) - runWorkflowAsService"
    }

    private static func serviceStatusKeyCandidates(
        for service: (bundleIdentifier: String, menuTitle: String),
        from serviceStatus: [String: Any]
    ) -> [String] {
        let suffix = serviceStatusKeySuffix(menuTitle: service.menuTitle)
        var candidates = serviceStatus.keys.filter { $0.hasSuffix(suffix) }

        if candidates.isEmpty {
            candidates = [
                "\(service.bundleIdentifier)\(suffix)",
                "(null)\(suffix)"
            ]
        }

        var unique: [String] = []
        for candidate in candidates where !unique.contains(candidate) {
            unique.append(candidate)
        }
        return unique
    }

    private static func ownedServiceStatusKeyCandidates(
        for service: (bundleIdentifier: String, menuTitle: String),
        from serviceStatus: [String: Any]
    ) -> [String] {
        let suffix = serviceStatusKeySuffix(menuTitle: service.menuTitle)
        let ownedKeys = [service.bundleIdentifier + suffix, "(null)" + suffix]
        return ownedKeys.filter { serviceStatus[$0] != nil }
    }

    private static func statusEntryPrefersContextMenu(_ currentStatus: [String: Any]) -> Bool {
        guard isEnabledValue(currentStatus["enabled_context_menu"]),
              isEnabledValue(currentStatus["enabled_services_menu"]) else {
            return false
        }

        let presentationModes = currentStatus["presentation_modes"] as? [String: Any] ?? [:]
        guard isEnabledValue(presentationModes["ContextMenu"]),
              isEnabledValue(presentationModes["ServicesMenu"]) else {
            return false
        }

        // Keep services out of Finder's Quick Actions submenu and show only in direct context menu.
        return !isEnabledValue(presentationModes["FinderPreview"])
    }

    private static func forceEnableSortyServiceEntries() {
        var pbsDomainValues = UserDefaults.standard.persistentDomain(forName: pbsDomain) ?? [:]
        var serviceStatus = pbsDomainValues["NSServicesStatus"] as? [String: Any] ?? [:]

        for service in activeSortyServices {
            for statusKey in serviceStatusKeyCandidates(for: service, from: serviceStatus) {
                var currentStatus = serviceStatus[statusKey] as? [String: Any] ?? [:]
                currentStatus["enabled_context_menu"] = 1
                currentStatus["enabled_services_menu"] = 1

                var presentationModes = currentStatus["presentation_modes"] as? [String: Any] ?? [:]
                presentationModes["ContextMenu"] = 1
                presentationModes["ServicesMenu"] = 1
                presentationModes["FinderPreview"] = 0
                presentationModes["TouchBar"] = 0
                currentStatus["presentation_modes"] = presentationModes

                serviceStatus[statusKey] = currentStatus
            }
        }

        pbsDomainValues["NSServicesStatus"] = serviceStatus
        UserDefaults.standard.setPersistentDomain(pbsDomainValues, forName: pbsDomain)
        UserDefaults.standard.synchronize()
    }

    private static func isEnabledValue(_ value: Any?) -> Bool {
        if let intValue = value as? Int {
            return intValue == 1
        }
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.intValue == 1
        }
        return false
    }

    private static func areSortyServiceEntriesEnabled() -> Bool {
        let pbsDomainValues = UserDefaults.standard.persistentDomain(forName: pbsDomain) ?? [:]
        let serviceStatus = pbsDomainValues["NSServicesStatus"] as? [String: Any] ?? [:]

        for service in activeSortyServices {
            let statusKeys = serviceStatusKeyCandidates(for: service, from: serviceStatus)
            guard !statusKeys.isEmpty else {
                return false
            }
            let hasPreferredEntry = statusKeys.contains { statusKey in
                let currentStatus = serviceStatus[statusKey] as? [String: Any] ?? [:]
                return statusEntryPrefersContextMenu(currentStatus)
            }
            guard hasPreferredEntry else {
                return false
            }
        }

        return true
    }

    private static func shouldRefreshDynamicServicesRegistry(force: Bool) -> Bool {
        if force {
            return true
        }

        let lastRefresh = UserDefaults.standard.object(forKey: servicesRegistryRefreshDefaultsKey) as? Date
        guard let lastRefresh else {
            return true
        }
        return Date().timeIntervalSince(lastRefresh) >= servicesRegistryRefreshMinimumInterval
    }

    private static func refreshDynamicServicesRegistry(force: Bool = true) {
        guard shouldRefreshDynamicServicesRegistry(force: force) else {
            forceEnableSortyServiceEntries()
            return
        }

        removeLegacyServiceStatusEntries()
        forceEnableSortyServiceEntries()
        NSUpdateDynamicServices()

        // A plain NSUpdateDynamicServices call is sometimes not enough for Finder
        // to immediately refresh the Quick Actions registry.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        process.arguments = ["-flush"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Best-effort refresh only.
        }

        forceEnableSortyServiceEntries()
        UserDefaults.standard.set(Date(), forKey: servicesRegistryRefreshDefaultsKey)
    }

    private static func removeServiceStatusEntries(
        _ services: [(bundleIdentifier: String, menuTitle: String)]
    ) {
        var pbsDomainValues = UserDefaults.standard.persistentDomain(forName: pbsDomain) ?? [:]
        var serviceStatus = pbsDomainValues["NSServicesStatus"] as? [String: Any] ?? [:]
        var didRemove = false

        for service in services {
            for statusKey in ownedServiceStatusKeyCandidates(for: service, from: serviceStatus) {
                serviceStatus.removeValue(forKey: statusKey)
                didRemove = true
            }
        }

        guard didRemove else { return }

        pbsDomainValues["NSServicesStatus"] = serviceStatus
        UserDefaults.standard.setPersistentDomain(pbsDomainValues, forName: pbsDomain)
        UserDefaults.standard.synchronize()
    }

    private static func removeLegacyServiceStatusEntries() {
        removeServiceStatusEntries(deprecatedSortyServices)
    }

    /// Remove Sorty's Finder service preferences and refresh the system Services registry.
    @discardableResult
    public static func removeAllQuickActionRegistrationState() -> Bool {
        removeServiceStatusEntries(activeSortyServices + deprecatedSortyServices)
        NSUpdateDynamicServices()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        process.arguments = ["-flush"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Install an "Organize with Sorty" Quick Action workflow to ~/Library/Services.
    public static func installQuickAction() -> (success: Bool, message: String) {
        let workflowName = organizeQuickActionWorkflowName
        guard let servicesDir = resolveServicesDirectoryForInstall() else {
            return (
                false,
                "Could not access ~/Library/Services. Click Install again and allow folder access when prompted."
            )
        }
        let workflowDir = servicesDir.appendingPathComponent(workflowName)
        let contentsDir = workflowDir.appendingPathComponent("Contents")

        do {
            try replaceWorkflowDirectoryIfNeeded(workflowDir)
            try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)

            let infoPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleIdentifier</key>
                <string>\(organizeQuickActionBundleIdentifier)</string>
                <key>CFBundleName</key>
                <string>Organize with Sorty</string>
                <key>CFBundlePackageType</key>
                <string>BNDL</string>
                <key>CFBundleIconFile</key>
                <string>\(quickActionServiceIconName)</string>
                <key>\(organizeWorkflowIconVersionInfoKey)</key>
                <string>\(organizeWorkflowIconVersion)</string>
                <key>NSServices</key>
                <array>
                    <dict>
                        <key>NSMenuItem</key>
                        <dict>
                            <key>default</key>
                            <string>Organize with Sorty</string>
                        </dict>
                        <key>NSIconName</key>
                        <string>\(quickActionServiceIconName)</string>
                        <key>NSMessage</key>
                        <string>runWorkflowAsService</string>
                        <key>NSRequiredContext</key>
                        <dict>
                            <key>NSApplicationIdentifier</key>
                            <string>com.apple.finder</string>
                        </dict>
                        <key>NSSendFileTypes</key>
                        <array>
                            <string>public.folder</string>
                            <string>public.item</string>
                        </array>
                    </dict>
                </array>
            </dict>
            </plist>
            """
            try infoPlist.write(to: contentsDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

            let shellCommand = """
            for f in "$@"; do if [[ "$f" == file://* ]]; then f=$(/usr/bin/python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(urllib.parse.urlparse(sys.argv[1]).path))" "$f" 2>/dev/null || echo "$f" | sed 's|^file://||'); fi; if [ -f "$f" ]; then f="$(dirname "$f")"; fi; encoded=$(/usr/bin/python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$f" 2>/dev/null || printf '%s' "$f" | sed 's/ /%20/g; s/!/%21/g; s/#/%23/g; s/\\$/%24/g; s/&amp;/%26/g; s/(/%28/g; s/)/%29/g'); open "sorty://organize?path=$encoded&source=finder"; done
            """

            let workflowPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>AMApplicationBuild</key>
                <string>523</string>
                <key>AMApplicationVersion</key>
                <string>2.10</string>
                <key>AMDocumentVersion</key>
                <string>2</string>
                <key>actions</key>
                <array>
                    <dict>
                        <key>action</key>
                        <dict>
                            <key>AMAccepts</key>
                            <dict>
                                <key>Container</key>
                                <string>List</string>
                                <key>Optional</key>
                                <true/>
                                <key>Types</key>
                                <array>
                                    <string>com.apple.cocoa.path</string>
                                    <string>com.apple.cocoa.url</string>
                                    <string>public.item</string>
                                    <string>public.folder</string>
                                </array>
                            </dict>
                            <key>AMActionVersion</key>
                            <string>1.0.2</string>
                            <key>AMApplication</key>
                            <array>
                                <string>Automator</string>
                            </array>
                            <key>AMCategory</key>
                            <string>AMCategoryUtilities</string>
                            <key>AMIconName</key>
                            <string>\(quickActionServiceIconName)</string>
                            <key>AMName</key>
                            <string>Run Shell Script</string>
                            <key>AMParameters</key>
                            <dict>
                                <key>COMMAND_STRING</key>
                                <string>\(shellCommand)</string>
                                <key>CheckedForUserDefaultShell</key>
                                <true/>
                                <key>inputMethod</key>
                                <integer>1</integer>
                                <key>shell</key>
                                <string>/bin/zsh</string>
                                <key>source</key>
                                <string></string>
                            </dict>
                            <key>AMProvides</key>
                            <dict>
                                <key>Container</key>
                                <string>List</string>
                                <key>Types</key>
                                <array>
                                    <string>com.apple.cocoa.path</string>
                                </array>
                            </dict>
                            <key>AMRequiredResources</key>
                            <array/>
                            <key>ActionBundlePath</key>
                            <string>/System/Library/Automator/Run Shell Script.action</string>
                            <key>ActionName</key>
                            <string>Run Shell Script</string>
                            <key>ActionParameters</key>
                            <dict>
                                <key>COMMAND_STRING</key>
                                <string>\(shellCommand)</string>
                                <key>CheckedForUserDefaultShell</key>
                                <true/>
                                <key>inputMethod</key>
                                <integer>1</integer>
                                <key>shell</key>
                                <string>/bin/zsh</string>
                                <key>source</key>
                                <string></string>
                            </dict>
                            <key>BundleIdentifier</key>
                            <string>com.apple.RunShellScript</string>
                            <key>CFBundleVersion</key>
                            <string>1.0.2</string>
                            <key>CanShowSelectedItemsWhenRun</key>
                            <false/>
                            <key>CanShowWhenRun</key>
                            <true/>
                            <key>Category</key>
                            <array>
                                <string>AMCategoryUtilities</string>
                            </array>
                            <key>Class Name</key>
                            <string>RunShellScriptAction</string>
                            <key>InputUUID</key>
                            <string>6A1B2C3D-4E5F-6A7B-8C9D-0E1F2A3B4C5D</string>
                            <key>Keywords</key>
                            <array>
                                <string>Shell</string>
                                <string>Script</string>
                                <string>Command</string>
                                <string>Run</string>
                                <string>Unix</string>
                            </array>
                            <key>OutputUUID</key>
                            <string>7B2C3D4E-5F6A-7B8C-9D0E-1F2A3B4C5D6E</string>
                            <key>UUID</key>
                            <string>8C3D4E5F-6A7B-8C9D-0E1F-2A3B4C5D6E7F</string>
                            <key>UnlocalizedApplications</key>
                            <array>
                                <string>Automator</string>
                            </array>
                            <key>arguments</key>
                            <dict>
                                <key>0</key>
                                <dict>
                                    <key>default value</key>
                                    <integer>1</integer>
                                    <key>name</key>
                                    <string>inputMethod</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>0</string>
                                </dict>
                                <key>1</key>
                                <dict>
                                    <key>default value</key>
                                    <string></string>
                                    <key>name</key>
                                    <string>source</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>1</string>
                                </dict>
                                <key>2</key>
                                <dict>
                                    <key>default value</key>
                                    <false/>
                                    <key>name</key>
                                    <string>CheckedForUserDefaultShell</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>2</string>
                                </dict>
                                <key>3</key>
                                <dict>
                                    <key>default value</key>
                                    <string></string>
                                    <key>name</key>
                                    <string>COMMAND_STRING</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>3</string>
                                </dict>
                                <key>4</key>
                                <dict>
                                    <key>default value</key>
                                    <string>/bin/sh</string>
                                    <key>name</key>
                                    <string>shell</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>4</string>
                                </dict>
                            </dict>
                            <key>isViewVisible</key>
                            <integer>1</integer>
                            <key>location</key>
                            <string>309.000000:253.000000</string>
                            <key>nibPath</key>
                            <string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
                        </dict>
                        <key>isViewVisible</key>
                        <integer>1</integer>
                    </dict>
                </array>
                <key>connectors</key>
                <dict/>
                <key>workflowMetaData</key>
                <dict>
                    <key>serviceInputTypeIdentifier</key>
                    <string>com.apple.Automator.fileSystemObject</string>
                    <key>serviceApplicationPath</key>
                    <string>/System/Library/CoreServices/Finder.app</string>
                    <key>workflowTypeIdentifier</key>
                    <string>com.apple.Automator.servicesMenu</string>
                </dict>
            </dict>
            </plist>
            """
            try workflowPlist.write(to: contentsDir.appendingPathComponent("document.wflow"), atomically: true, encoding: .utf8)
            applyQuickActionIcon(workflowDir: workflowDir, contentsDir: contentsDir)
            refreshDynamicServicesRegistry()

            return (true, "Organize Action installed. Right-click folders in Finder to use 'Organize with Sorty'.")
        } catch {
            return (false, "Installation failed: \(error.localizedDescription)")
        }
    }

    /// Ensure Organize, Watch, and Exclude service entries are installed and refreshed.
    public static func ensureQuickActionInstalled(forceRefreshServices: Bool = false) -> (installed: Bool, message: String) {
        var refreshedOrganizeWorkflow = false
        var organizeRefreshError: String?
        if !isQuickActionInstalled() {
            let refreshResult = installQuickAction()
            refreshedOrganizeWorkflow = refreshResult.success
            if !refreshResult.success {
                organizeRefreshError = refreshResult.message
            }
        }

        var refreshedWatchWorkflow = false
        var watchRefreshError: String?
        if !isWatchWorkflowInstalledAndCompatible() {
            let refreshResult = installQuickWatchAction()
            refreshedWatchWorkflow = refreshResult.success
            if !refreshResult.success {
                watchRefreshError = refreshResult.message
            }
        }

        var refreshedExcludeWorkflow = false
        var excludeRefreshError: String?
        if !isWorkflowInstalledAndCompatible(
            workflowName: excludeQuickActionWorkflowName,
            bundleIdentifier: excludeQuickActionBundleIdentifier
        ) {
            let refreshResult = installQuickExcludeAction()
            refreshedExcludeWorkflow = refreshResult.success
            if !refreshResult.success {
                excludeRefreshError = refreshResult.message
            }
        }

        if forceRefreshServices || !areSortyServiceEntriesEnabled() {
            refreshDynamicServicesRegistry(force: forceRefreshServices)
        }

        if let organizeRefreshError {
            return (false, "Finder services refreshed, but Organize workflow install failed: \(organizeRefreshError)")
        }

        if let watchRefreshError {
            return (false, "Finder services refreshed, but Watch workflow icon update failed: \(watchRefreshError)")
        }

        if let excludeRefreshError {
            return (false, "Finder services refreshed, but Exclude workflow install failed: \(excludeRefreshError)")
        }

        if refreshedOrganizeWorkflow || refreshedWatchWorkflow || refreshedExcludeWorkflow {
            return (true, "Installed Sorty Services menu actions and refreshed Finder services.")
        }

        return (true, "Finder services are up to date. Organize, Watch, and Exclude are available in Finder's Services menu.")
    }

    public static func ensureQuickActionInstalledAsync(forceRefreshServices: Bool = false) async -> (installed: Bool, message: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = ensureQuickActionInstalled(forceRefreshServices: forceRefreshServices)
                continuation.resume(returning: result)
            }
        }
    }

    /// Check if Quick Action is installed
    public static func isQuickActionInstalled() -> Bool {
        for servicesDir in candidateServicesDirectories() {
            let workflowPath = servicesDir.appendingPathComponent(organizeQuickActionWorkflowName)
            guard FileManager.default.fileExists(atPath: workflowPath.path) else { continue }

            let infoPath = workflowPath.appendingPathComponent("Contents/Info.plist")
            guard let info = NSDictionary(contentsOf: infoPath) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == organizeQuickActionBundleIdentifier,
                  info[organizeWorkflowIconVersionInfoKey] as? String == organizeWorkflowIconVersion,
                  workflowHasFinderContext(infoPlist: info) else {
                continue
            }

            let iconPath = workflowPath
                .appendingPathComponent("Contents/Resources")
                .appendingPathComponent("\(quickActionServiceIconName).png")
            if FileManager.default.fileExists(atPath: iconPath.path) {
                return true
            }
        }
        return false
    }

    /// Check if Quick Action is installed (async)
    public static func isQuickActionInstalledAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = isQuickActionInstalled()
                continuation.resume(returning: result)
            }
        }
    }

    /// Uninstall the Quick Action
    public static func uninstallQuickAction() -> Bool {
        var removed = false

        for servicesDir in candidateServicesDirectories() {
            let workflowPath = servicesDir.appendingPathComponent(organizeQuickActionWorkflowName)
            if FileManager.default.fileExists(atPath: workflowPath.path) {
                do {
                    try FileManager.default.removeItem(at: workflowPath)
                    removed = true
                } catch {
                    // Continue trying other candidate directories.
                }
            }
        }

        if removed {
            refreshDynamicServicesRegistry()
        }

        return removed
    }

    // MARK: - Quick Watch Action Installation

    /// Install a "Watch with Sorty" Quick Action workflow to ~/Library/Services
    public static func installQuickWatchAction() -> (success: Bool, message: String) {
        let workflowName = watchQuickActionWorkflowName
        guard let servicesDir = resolveServicesDirectoryForInstall() else {
            return (
                false,
                "Could not access ~/Library/Services. Click Install again and allow folder access when prompted."
            )
        }
        let workflowDir = servicesDir.appendingPathComponent(workflowName)
        let contentsDir = workflowDir.appendingPathComponent("Contents")

        do {
            try replaceWorkflowDirectoryIfNeeded(workflowDir)
            try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)

            let infoPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleIdentifier</key>
                <string>\(watchQuickActionBundleIdentifier)</string>
                <key>CFBundleName</key>
                <string>Watch with Sorty</string>
                <key>CFBundlePackageType</key>
                <string>BNDL</string>
                <key>CFBundleIconFile</key>
                <string>\(quickActionServiceIconName)</string>
                <key>\(watchWorkflowIconVariantInfoKey)</key>
                <string>\(currentWatchWorkflowIconVariant())</string>
                <key>NSServices</key>
                <array>
                    <dict>
                        <key>NSMenuItem</key>
                        <dict>
                            <key>default</key>
                            <string>Watch with Sorty</string>
                        </dict>
                        <key>NSIconName</key>
                        <string>\(quickActionServiceIconName)</string>
                        <key>NSMessage</key>
                        <string>runWorkflowAsService</string>
                        <key>NSRequiredContext</key>
                        <dict>
                            <key>NSApplicationIdentifier</key>
                            <string>com.apple.finder</string>
                        </dict>
                        <key>NSSendFileTypes</key>
                        <array>
                            <string>public.folder</string>
                        </array>
                    </dict>
                </array>
            </dict>
            </plist>
            """
            try infoPlist.write(to: contentsDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

            let shellCommand = """
            for f in "$@"; do if [[ "$f" == file://* ]]; then f=$(/usr/bin/python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(urllib.parse.urlparse(sys.argv[1]).path))" "$f" 2>/dev/null || echo "$f" | sed 's|^file://||'); fi; if [ -f "$f" ]; then f="$(dirname "$f")"; fi; encoded=$(/usr/bin/python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$f" 2>/dev/null || printf '%s' "$f" | sed 's/ /%20/g; s/!/%21/g; s/#/%23/g; s/\\$/%24/g; s/&amp;/%26/g; s/(/%28/g; s/)/%29/g'); open "sorty://watched?action=add&amp;path=$encoded"; done
            """

            let workflowPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>AMApplicationBuild</key>
                <string>523</string>
                <key>AMApplicationVersion</key>
                <string>2.10</string>
                <key>AMDocumentVersion</key>
                <string>2</string>
                <key>actions</key>
                <array>
                    <dict>
                        <key>action</key>
                        <dict>
                            <key>AMAccepts</key>
                            <dict>
                                <key>Container</key>
                                <string>List</string>
                                <key>Optional</key>
                                <true/>
                                <key>Types</key>
                                <array>
                                    <string>com.apple.cocoa.path</string>
                                    <string>com.apple.cocoa.url</string>
                                    <string>public.item</string>
                                    <string>public.folder</string>
                                </array>
                            </dict>
                            <key>AMActionVersion</key>
                            <string>1.0.2</string>
                            <key>AMApplication</key>
                            <array>
                                <string>Automator</string>
                            </array>
                            <key>AMCategory</key>
                            <string>AMCategoryUtilities</string>
                            <key>AMIconName</key>
                            <string>\(quickActionServiceIconName)</string>
                            <key>AMName</key>
                            <string>Run Shell Script</string>
                            <key>AMParameters</key>
                            <dict>
                                <key>COMMAND_STRING</key>
                                <string>\(shellCommand)</string>
                                <key>CheckedForUserDefaultShell</key>
                                <true/>
                                <key>inputMethod</key>
                                <integer>1</integer>
                                <key>shell</key>
                                <string>/bin/zsh</string>
                                <key>source</key>
                                <string></string>
                            </dict>
                            <key>AMProvides</key>
                            <dict>
                                <key>Container</key>
                                <string>List</string>
                                <key>Types</key>
                                <array>
                                    <string>com.apple.cocoa.path</string>
                                </array>
                            </dict>
                            <key>AMRequiredResources</key>
                            <array/>
                            <key>ActionBundlePath</key>
                            <string>/System/Library/Automator/Run Shell Script.action</string>
                            <key>ActionName</key>
                            <string>Run Shell Script</string>
                            <key>ActionParameters</key>
                            <dict>
                                <key>COMMAND_STRING</key>
                                <string>\(shellCommand)</string>
                                <key>CheckedForUserDefaultShell</key>
                                <true/>
                                <key>inputMethod</key>
                                <integer>1</integer>
                                <key>shell</key>
                                <string>/bin/zsh</string>
                                <key>source</key>
                                <string></string>
                            </dict>
                            <key>BundleIdentifier</key>
                            <string>com.apple.RunShellScript</string>
                            <key>CFBundleVersion</key>
                            <string>1.0.2</string>
                            <key>CanShowSelectedItemsWhenRun</key>
                            <false/>
                            <key>CanShowWhenRun</key>
                            <true/>
                            <key>Category</key>
                            <array>
                                <string>AMCategoryUtilities</string>
                            </array>
                            <key>Class Name</key>
                            <string>RunShellScriptAction</string>
                            <key>InputUUID</key>
                            <string>6A1B2C3D-4E5F-6A7B-8C9D-0E1F2A3B4C5D</string>
                            <key>Keywords</key>
                            <array>
                                <string>Shell</string>
                                <string>Script</string>
                                <string>Command</string>
                                <string>Run</string>
                                <string>Unix</string>
                            </array>
                            <key>OutputUUID</key>
                            <string>7B2C3D4E-5F6A-7B8C-9D0E-1F2A3B4C5D6E</string>
                            <key>UUID</key>
                            <string>8C3D4E5F-6A7B-8C9D-0E1F-2A3B4C5D6E7F</string>
                            <key>UnlocalizedApplications</key>
                            <array>
                                <string>Automator</string>
                            </array>
                            <key>arguments</key>
                            <dict>
                                <key>0</key>
                                <dict>
                                    <key>default value</key>
                                    <integer>1</integer>
                                    <key>name</key>
                                    <string>inputMethod</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>0</string>
                                </dict>
                                <key>1</key>
                                <dict>
                                    <key>default value</key>
                                    <string></string>
                                    <key>name</key>
                                    <string>source</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>1</string>
                                </dict>
                                <key>2</key>
                                <dict>
                                    <key>default value</key>
                                    <false/>
                                    <key>name</key>
                                    <string>CheckedForUserDefaultShell</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>2</string>
                                </dict>
                                <key>3</key>
                                <dict>
                                    <key>default value</key>
                                    <string></string>
                                    <key>name</key>
                                    <string>COMMAND_STRING</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>3</string>
                                </dict>
                                <key>4</key>
                                <dict>
                                    <key>default value</key>
                                    <string>/bin/sh</string>
                                    <key>name</key>
                                    <string>shell</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>4</string>
                                </dict>
                            </dict>
                            <key>isViewVisible</key>
                            <integer>1</integer>
                            <key>location</key>
                            <string>309.000000:253.000000</string>
                            <key>nibPath</key>
                            <string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
                        </dict>
                        <key>isViewVisible</key>
                        <integer>1</integer>
                    </dict>
                </array>
                <key>connectors</key>
                <dict/>
                <key>workflowMetaData</key>
                <dict>
                    <key>serviceInputTypeIdentifier</key>
                    <string>com.apple.Automator.fileSystemObject</string>
                    <key>serviceApplicationPath</key>
                    <string>/System/Library/CoreServices/Finder.app</string>
                    <key>workflowTypeIdentifier</key>
                    <string>com.apple.Automator.servicesMenu</string>
                </dict>
            </dict>
            </plist>
            """
            try workflowPlist.write(to: contentsDir.appendingPathComponent("document.wflow"), atomically: true, encoding: .utf8)
            applyQuickActionIcon(workflowDir: workflowDir, contentsDir: contentsDir, style: .watch)

            removeLegacyServiceStatusEntries()
            refreshDynamicServicesRegistry()

            return (true, "Watch Action installed. Right-click folders in Finder to use 'Watch with Sorty'.")

        } catch {
            return (false, "Installation failed: \(error.localizedDescription)")
        }
    }

    /// Install an "Exclude from Sorty" Quick Action workflow to ~/Library/Services
    public static func installQuickExcludeAction() -> (success: Bool, message: String) {
        let workflowName = excludeQuickActionWorkflowName
        guard let servicesDir = resolveServicesDirectoryForInstall() else {
            return (
                false,
                "Could not access ~/Library/Services. Click Install again and allow folder access when prompted."
            )
        }
        let workflowDir = servicesDir.appendingPathComponent(workflowName)
        let contentsDir = workflowDir.appendingPathComponent("Contents")

        do {
            let legacyWorkflowDir = servicesDir.appendingPathComponent(
                legacyExcludeQuickActionWorkflowName
            )
            if FileManager.default.fileExists(atPath: legacyWorkflowDir.path) {
                try FileManager.default.removeItem(at: legacyWorkflowDir)
            }
            try replaceWorkflowDirectoryIfNeeded(workflowDir)
            try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)

            let infoPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleIdentifier</key>
                <string>\(excludeQuickActionBundleIdentifier)</string>
                <key>CFBundleName</key>
                <string>Exclude from Sorty</string>
                <key>CFBundlePackageType</key>
                <string>BNDL</string>
                <key>CFBundleIconFile</key>
                <string>\(quickActionIconBaseName)</string>
                <key>NSServices</key>
                <array>
                    <dict>
                        <key>NSMenuItem</key>
                        <dict>
                            <key>default</key>
                            <string>Exclude from Sorty</string>
                        </dict>
                        <key>NSIconName</key>
                        <string>\(quickActionServiceIconName)</string>
                        <key>NSMessage</key>
                        <string>runWorkflowAsService</string>
                        <key>NSRequiredContext</key>
                        <dict>
                            <key>NSApplicationIdentifier</key>
                            <string>com.apple.finder</string>
                        </dict>
                        <key>NSSendFileTypes</key>
                        <array>
                            <string>public.folder</string>
                            <string>public.item</string>
                        </array>
                    </dict>
                </array>
            </dict>
            </plist>
            """
            try infoPlist.write(to: contentsDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

            let shellCommand = """
            for f in "$@"; do if [[ "$f" == file://* ]]; then f=$(/usr/bin/python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(urllib.parse.urlparse(sys.argv[1]).path))" "$f" 2>/dev/null || echo "$f" | sed 's|^file://||'); fi; if [ -f "$f" ]; then f="$(dirname "$f")"; fi; encoded=$(/usr/bin/python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$f" 2>/dev/null || printf '%s' "$f" | sed 's/ /%20/g; s/!/%21/g; s/#/%23/g; s/\\$/%24/g; s/&amp;/%26/g; s/(/%28/g; s/)/%29/g'); open "sorty://exclude?path=$encoded"; done
            """

            let workflowPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>AMApplicationBuild</key>
                <string>523</string>
                <key>AMApplicationVersion</key>
                <string>2.10</string>
                <key>AMDocumentVersion</key>
                <string>2</string>
                <key>actions</key>
                <array>
                    <dict>
                        <key>action</key>
                        <dict>
                            <key>AMAccepts</key>
                            <dict>
                                <key>Container</key>
                                <string>List</string>
                                <key>Optional</key>
                                <true/>
                                <key>Types</key>
                                <array>
                                    <string>com.apple.cocoa.path</string>
                                    <string>com.apple.cocoa.url</string>
                                    <string>public.item</string>
                                    <string>public.folder</string>
                                </array>
                            </dict>
                            <key>AMActionVersion</key>
                            <string>1.0.2</string>
                            <key>AMApplication</key>
                            <array>
                                <string>Automator</string>
                            </array>
                            <key>AMCategory</key>
                            <string>AMCategoryUtilities</string>
                            <key>AMIconName</key>
                            <string>\(quickActionServiceIconName)</string>
                            <key>AMName</key>
                            <string>Run Shell Script</string>
                            <key>AMParameters</key>
                            <dict>
                                <key>COMMAND_STRING</key>
                                <string>\(shellCommand)</string>
                                <key>CheckedForUserDefaultShell</key>
                                <true/>
                                <key>inputMethod</key>
                                <integer>1</integer>
                                <key>shell</key>
                                <string>/bin/zsh</string>
                                <key>source</key>
                                <string></string>
                            </dict>
                            <key>AMProvides</key>
                            <dict>
                                <key>Container</key>
                                <string>List</string>
                                <key>Types</key>
                                <array>
                                    <string>com.apple.cocoa.path</string>
                                </array>
                            </dict>
                            <key>AMRequiredResources</key>
                            <array/>
                            <key>ActionBundlePath</key>
                            <string>/System/Library/Automator/Run Shell Script.action</string>
                            <key>ActionName</key>
                            <string>Run Shell Script</string>
                            <key>ActionParameters</key>
                            <dict>
                                <key>COMMAND_STRING</key>
                                <string>\(shellCommand)</string>
                                <key>CheckedForUserDefaultShell</key>
                                <true/>
                                <key>inputMethod</key>
                                <integer>1</integer>
                                <key>shell</key>
                                <string>/bin/zsh</string>
                                <key>source</key>
                                <string></string>
                            </dict>
                            <key>BundleIdentifier</key>
                            <string>com.apple.RunShellScript</string>
                            <key>CFBundleVersion</key>
                            <string>1.0.2</string>
                            <key>CanShowSelectedItemsWhenRun</key>
                            <false/>
                            <key>CanShowWhenRun</key>
                            <true/>
                            <key>Category</key>
                            <array>
                                <string>AMCategoryUtilities</string>
                            </array>
                            <key>Class Name</key>
                            <string>RunShellScriptAction</string>
                            <key>InputUUID</key>
                            <string>6A1B2C3D-4E5F-6A7B-8C9D-0E1F2A3B4C5D</string>
                            <key>Keywords</key>
                            <array>
                                <string>Shell</string>
                                <string>Script</string>
                                <string>Command</string>
                                <string>Run</string>
                                <string>Unix</string>
                            </array>
                            <key>OutputUUID</key>
                            <string>7B2C3D4E-5F6A-7B8C-9D0E-1F2A3B4C5D6E</string>
                            <key>UUID</key>
                            <string>8C3D4E5F-6A7B-8C9D-0E1F-2A3B4C5D6E7F</string>
                            <key>UnlocalizedApplications</key>
                            <array>
                                <string>Automator</string>
                            </array>
                            <key>arguments</key>
                            <dict>
                                <key>0</key>
                                <dict>
                                    <key>default value</key>
                                    <integer>1</integer>
                                    <key>name</key>
                                    <string>inputMethod</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>0</string>
                                </dict>
                                <key>1</key>
                                <dict>
                                    <key>default value</key>
                                    <string></string>
                                    <key>name</key>
                                    <string>source</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>1</string>
                                </dict>
                                <key>2</key>
                                <dict>
                                    <key>default value</key>
                                    <false/>
                                    <key>name</key>
                                    <string>CheckedForUserDefaultShell</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>2</string>
                                </dict>
                                <key>3</key>
                                <dict>
                                    <key>default value</key>
                                    <string></string>
                                    <key>name</key>
                                    <string>COMMAND_STRING</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>3</string>
                                </dict>
                                <key>4</key>
                                <dict>
                                    <key>default value</key>
                                    <string>/bin/sh</string>
                                    <key>name</key>
                                    <string>shell</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>4</string>
                                </dict>
                            </dict>
                            <key>isViewVisible</key>
                            <integer>1</integer>
                            <key>location</key>
                            <string>309.000000:253.000000</string>
                            <key>nibPath</key>
                            <string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
                        </dict>
                        <key>isViewVisible</key>
                        <integer>1</integer>
                    </dict>
                </array>
                <key>connectors</key>
                <dict/>
                <key>workflowMetaData</key>
                <dict>
                    <key>serviceInputTypeIdentifier</key>
                    <string>com.apple.Automator.fileSystemObject</string>
                    <key>serviceApplicationPath</key>
                    <string>/System/Library/CoreServices/Finder.app</string>
                    <key>workflowTypeIdentifier</key>
                    <string>com.apple.Automator.servicesMenu</string>
                </dict>
            </dict>
            </plist>
            """
            try workflowPlist.write(to: contentsDir.appendingPathComponent("document.wflow"), atomically: true, encoding: .utf8)
            applyQuickActionIcon(workflowDir: workflowDir, contentsDir: contentsDir, style: .exclude)

            refreshDynamicServicesRegistry()

            return (true, "Exclude Action installed. Right-click any folder in Finder to use 'Exclude from Sorty'.")

        } catch {
            return (false, "Installation failed: \(error.localizedDescription)")
        }
    }

    /// Check if Quick Watch Action is installed
    public static func isQuickWatchActionInstalled() -> Bool {
        return isWatchWorkflowInstalledAndCompatible()
    }

    public static func isQuickExcludeActionInstalled() -> Bool {
        return isWorkflowInstalledAndCompatible(
            workflowName: excludeQuickActionWorkflowName,
            bundleIdentifier: excludeQuickActionBundleIdentifier
        )
    }

    public static func isQuickWatchActionInstalledAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = isQuickWatchActionInstalled()
                continuation.resume(returning: result)
            }
        }
    }

    public static func isQuickExcludeActionInstalledAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = isQuickExcludeActionInstalled()
                continuation.resume(returning: result)
            }
        }
    }

    /// Uninstall the Quick Watch Action
    public static func uninstallQuickWatchAction() -> Bool {
        var removed = false

        for servicesDir in candidateServicesDirectories() {
            let workflowPath = servicesDir.appendingPathComponent(watchQuickActionWorkflowName)
            if FileManager.default.fileExists(atPath: workflowPath.path) {
                do {
                    try FileManager.default.removeItem(at: workflowPath)
                    removed = true
                } catch {
                    // Continue trying other candidate directories.
                }
            }
        }

        if removed {
            refreshDynamicServicesRegistry()
        }

        return removed
    }

    // MARK: - Quick Preview Action Installation

    /// Install a "Preview with Sorty" Quick Action workflow to ~/Library/Services
    public static func installQuickPreviewAction() -> (success: Bool, message: String) {
        let workflowName = previewQuickActionWorkflowName
        guard let servicesDir = resolveServicesDirectoryForInstall() else {
            return (
                false,
                "Could not access ~/Library/Services. Click Install again and allow folder access when prompted."
            )
        }
        let workflowDir = servicesDir.appendingPathComponent(workflowName)
        let contentsDir = workflowDir.appendingPathComponent("Contents")

        do {
            try replaceWorkflowDirectoryIfNeeded(workflowDir)
            try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)

            let infoPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleIdentifier</key>
                <string>\(previewQuickActionBundleIdentifier)</string>
                <key>CFBundleName</key>
                <string>Preview with Sorty</string>
                <key>CFBundlePackageType</key>
                <string>BNDL</string>
                <key>CFBundleIconFile</key>
                <string>\(quickActionIconBaseName)</string>
                <key>NSServices</key>
                <array>
                    <dict>
                        <key>NSMenuItem</key>
                        <dict>
                            <key>default</key>
                            <string>Preview with Sorty</string>
                        </dict>
                        <key>NSIconName</key>
                        <string>\(quickActionServiceIconName)</string>
                        <key>NSMessage</key>
                        <string>runWorkflowAsService</string>
                        <key>NSRequiredContext</key>
                        <dict>
                            <key>NSApplicationIdentifier</key>
                            <string>com.apple.finder</string>
                        </dict>
                        <key>NSSendFileTypes</key>
                        <array>
                            <string>public.folder</string>
                            <string>public.item</string>
                        </array>
                    </dict>
                </array>
            </dict>
            </plist>
            """
            try infoPlist.write(to: contentsDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

            let shellCommand = """
            for f in "$@"; do if [[ "$f" == file://* ]]; then f=$(/usr/bin/python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(urllib.parse.urlparse(sys.argv[1]).path))" "$f" 2>/dev/null || echo "$f" | sed 's|^file://||'); fi; if [ -f "$f" ]; then f="$(dirname "$f")"; fi; encoded=$(/usr/bin/python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$f" 2>/dev/null || printf '%s' "$f" | sed 's/ /%20/g; s/!/%21/g; s/#/%23/g; s/\\$/%24/g; s/&amp;/%26/g; s/(/%28/g; s/)/%29/g'); open "sorty://scan?path=$encoded&amp;preview=true"; done
            """

            let workflowPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>AMApplicationBuild</key>
                <string>523</string>
                <key>AMApplicationVersion</key>
                <string>2.10</string>
                <key>AMDocumentVersion</key>
                <string>2</string>
                <key>actions</key>
                <array>
                    <dict>
                        <key>action</key>
                        <dict>
                            <key>AMAccepts</key>
                            <dict>
                                <key>Container</key>
                                <string>List</string>
                                <key>Optional</key>
                                <true/>
                                <key>Types</key>
                                <array>
                                    <string>com.apple.cocoa.path</string>
                                    <string>com.apple.cocoa.url</string>
                                    <string>public.item</string>
                                    <string>public.folder</string>
                                </array>
                            </dict>
                            <key>AMActionVersion</key>
                            <string>1.0.2</string>
                            <key>AMApplication</key>
                            <array>
                                <string>Automator</string>
                            </array>
                            <key>AMCategory</key>
                            <string>AMCategoryUtilities</string>
                            <key>AMIconName</key>
                            <string>\(quickActionServiceIconName)</string>
                            <key>AMName</key>
                            <string>Run Shell Script</string>
                            <key>AMParameters</key>
                            <dict>
                                <key>COMMAND_STRING</key>
                                <string>\(shellCommand)</string>
                                <key>CheckedForUserDefaultShell</key>
                                <true/>
                                <key>inputMethod</key>
                                <integer>1</integer>
                                <key>shell</key>
                                <string>/bin/zsh</string>
                                <key>source</key>
                                <string></string>
                            </dict>
                            <key>AMProvides</key>
                            <dict>
                                <key>Container</key>
                                <string>List</string>
                                <key>Types</key>
                                <array>
                                    <string>com.apple.cocoa.path</string>
                                </array>
                            </dict>
                            <key>AMRequiredResources</key>
                            <array/>
                            <key>ActionBundlePath</key>
                            <string>/System/Library/Automator/Run Shell Script.action</string>
                            <key>ActionName</key>
                            <string>Run Shell Script</string>
                            <key>ActionParameters</key>
                            <dict>
                                <key>COMMAND_STRING</key>
                                <string>\(shellCommand)</string>
                                <key>CheckedForUserDefaultShell</key>
                                <true/>
                                <key>inputMethod</key>
                                <integer>1</integer>
                                <key>shell</key>
                                <string>/bin/zsh</string>
                                <key>source</key>
                                <string></string>
                            </dict>
                            <key>BundleIdentifier</key>
                            <string>com.apple.RunShellScript</string>
                            <key>CFBundleVersion</key>
                            <string>1.0.2</string>
                            <key>CanShowSelectedItemsWhenRun</key>
                            <false/>
                            <key>CanShowWhenRun</key>
                            <true/>
                            <key>Category</key>
                            <array>
                                <string>AMCategoryUtilities</string>
                            </array>
                            <key>Class Name</key>
                            <string>RunShellScriptAction</string>
                            <key>InputUUID</key>
                            <string>9D4E5F6A-7B8C-9D0E-1F2A-3B4C5D6E7F8A</string>
                            <key>Keywords</key>
                            <array>
                                <string>Shell</string>
                                <string>Script</string>
                                <string>Command</string>
                                <string>Run</string>
                                <string>Unix</string>
                            </array>
                            <key>OutputUUID</key>
                            <string>AE5F6A7B-8C9D-0E1F-2A3B-4C5D6E7F8A9B</string>
                            <key>UUID</key>
                            <string>BF6A7B8C-9D0E-1F2A-3B4C-5D6E7F8A9B0C</string>
                            <key>UnlocalizedApplications</key>
                            <array>
                                <string>Automator</string>
                            </array>
                            <key>arguments</key>
                            <dict>
                                <key>0</key>
                                <dict>
                                    <key>default value</key>
                                    <integer>1</integer>
                                    <key>name</key>
                                    <string>inputMethod</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>0</string>
                                </dict>
                                <key>1</key>
                                <dict>
                                    <key>default value</key>
                                    <string></string>
                                    <key>name</key>
                                    <string>source</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>1</string>
                                </dict>
                                <key>2</key>
                                <dict>
                                    <key>default value</key>
                                    <false/>
                                    <key>name</key>
                                    <string>CheckedForUserDefaultShell</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>2</string>
                                </dict>
                                <key>3</key>
                                <dict>
                                    <key>default value</key>
                                    <string></string>
                                    <key>name</key>
                                    <string>COMMAND_STRING</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>3</string>
                                </dict>
                                <key>4</key>
                                <dict>
                                    <key>default value</key>
                                    <string>/bin/sh</string>
                                    <key>name</key>
                                    <string>shell</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>4</string>
                                </dict>
                            </dict>
                            <key>isViewVisible</key>
                            <integer>1</integer>
                            <key>location</key>
                            <string>309.000000:253.000000</string>
                            <key>nibPath</key>
                            <string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
                        </dict>
                        <key>isViewVisible</key>
                        <integer>1</integer>
                    </dict>
                </array>
                <key>connectors</key>
                <dict/>
                <key>workflowMetaData</key>
                <dict>
                    <key>serviceInputTypeIdentifier</key>
                    <string>com.apple.Automator.fileSystemObject</string>
                    <key>serviceApplicationPath</key>
                    <string>/System/Library/CoreServices/Finder.app</string>
                    <key>workflowTypeIdentifier</key>
                    <string>com.apple.Automator.servicesMenu</string>
                </dict>
            </dict>
            </plist>
            """
            try workflowPlist.write(to: contentsDir.appendingPathComponent("document.wflow"), atomically: true, encoding: .utf8)
            applyQuickActionIcon(workflowDir: workflowDir, contentsDir: contentsDir)

            refreshDynamicServicesRegistry()

            return (true, "Preview Action installed! Right-click any folder in Finder to use 'Preview with Sorty'.")

        } catch {
            return (false, "Installation failed: \(error.localizedDescription)")
        }
    }

    /// Check if Quick Preview Action is installed
    public static func isQuickPreviewActionInstalled() -> Bool {
        return isWorkflowInstalledAndCompatible(
            workflowName: previewQuickActionWorkflowName,
            bundleIdentifier: previewQuickActionBundleIdentifier
        )
    }

    /// Uninstall the Quick Preview Action
    public static func uninstallQuickPreviewAction() -> Bool {
        var removed = false

        for servicesDir in candidateServicesDirectories() {
            let workflowPath = servicesDir.appendingPathComponent(previewQuickActionWorkflowName)
            if FileManager.default.fileExists(atPath: workflowPath.path) {
                do {
                    try FileManager.default.removeItem(at: workflowPath)
                    removed = true
                } catch {
                    // Continue trying other candidate directories.
                }
            }
        }

        if removed {
            refreshDynamicServicesRegistry()
        }

        return removed
    }

    /// Uninstall all Quick Action workflows
    public static func uninstallAllQuickActions() -> (success: Bool, removed: Int) {
        let workflows = [
            (organizeQuickActionWorkflowName, organizeQuickActionBundleIdentifier),
            (watchQuickActionWorkflowName, watchQuickActionBundleIdentifier),
            (excludeQuickActionWorkflowName, excludeQuickActionBundleIdentifier),
            (scanQuickActionWorkflowName, scanQuickActionBundleIdentifier),
            (previewQuickActionWorkflowName, previewQuickActionBundleIdentifier)
        ]

        var removedCount = 0
        for servicesDir in candidateServicesDirectories() {
            for workflow in workflows {
                let workflowPath = servicesDir.appendingPathComponent(workflow.0)
                if FileManager.default.fileExists(atPath: workflowPath.path) {
                    let infoPath = workflowPath.appendingPathComponent("Contents/Info.plist")
                    guard let info = NSDictionary(contentsOf: infoPath) as? [String: Any],
                          info["CFBundleIdentifier"] as? String == workflow.1 else {
                        continue
                    }
                    do {
                        try FileManager.default.removeItem(at: workflowPath)
                        removedCount += 1
                    } catch {
                        // Continue trying other workflows.
                    }
                }
            }
        }

        if removedCount > 0 {
            refreshDynamicServicesRegistry()
        }

        return (removedCount > 0, removedCount)
    }

    // MARK: - AppleScript Integration

    /// Generate AppleScript for organizing a folder
    public static func appleScriptForOrganizing() -> String {
        return """
        on run {input, parameters}
            repeat with theItem in input
                set thePath to POSIX path of theItem
                set encodedPath to do shell script "/usr/bin/python3 -c \\"import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))\\" " & quoted form of thePath & " 2>/dev/null || printf '%s' " & quoted form of thePath & " | sed 's/ /%20/g; s/!/%21/g; s/#/%23/g; s/\\\\$/%24/g; s/&/%26/g; s/(/%28/g; s/)/%29/g'"
                do shell script "open -g 'sorty://organize?path=" & encodedPath & "&source=finder'"
            end repeat
            return input
        end run
        """
    }

    /// Open Finder Extension preferences
    public static func openFinderExtensionSettings() {
        let candidateURLs = [
            // macOS 15+ (Sequoia / Tahoe): Login Items & Extensions pane
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.preferences.extensions?Finder",
            "x-apple.systempreferences:com.apple.preferences.extensions?Extensions",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences"
        ]

        for rawURL in candidateURLs {
            if let url = URL(string: rawURL), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    // MARK: - Finder Integration Status

    public struct FinderIntegrationStatus: Sendable {
        public let quickActionInstalled: Bool
        public let quickWatchActionInstalled: Bool
        public let quickExcludeActionInstalled: Bool
        public let toolbarAppInstalled: Bool
        public let finderSyncEnabled: Bool
        public let menuBarEnabled: Bool

        public static let totalIntegrations = 6
        public static let empty = FinderIntegrationStatus(
            quickActionInstalled: false,
            quickWatchActionInstalled: false,
            quickExcludeActionInstalled: false,
            toolbarAppInstalled: false,
            finderSyncEnabled: false,
            menuBarEnabled: false
        )

        public var overallStatus: String {
            if quickActionInstalled || quickWatchActionInstalled || quickExcludeActionInstalled || toolbarAppInstalled || finderSyncEnabled || menuBarEnabled {
                return "Active"
            }
            return "Not Configured"
        }

        public var integrationCount: Int {
            [quickActionInstalled, quickWatchActionInstalled, quickExcludeActionInstalled, toolbarAppInstalled, finderSyncEnabled, menuBarEnabled]
                .filter { $0 }.count
        }
    }

    public struct FinderIntegrationAvailabilityStatus: Sendable, Equatable {
        enum State: Sendable, Equatable {
            case featureDisabled
            case checking
            case setupPending
            case ready
        }

        let state: State
        let title: String
        let detail: String
    }

    static func finderIntegrationAvailabilityStatus(
        featureFlagEnabled: Bool,
        diagnostics: FinderSyncDiagnostics?
    ) -> FinderIntegrationAvailabilityStatus {
        guard featureFlagEnabled else {
            return FinderIntegrationAvailabilityStatus(
                state: .featureDisabled,
                title: "Feature Flag Disabled",
                detail: "Turn this on to show Sorty's Finder integration controls and setup flow."
            )
        }

        guard let diagnostics else {
            return FinderIntegrationAvailabilityStatus(
                state: .checking,
                title: "Checking Finder Sync",
                detail: "Sorty is checking whether the macOS Finder Sync extension is enabled."
            )
        }

        if diagnostics.isOperational {
            return FinderIntegrationAvailabilityStatus(
                state: .ready,
                title: diagnostics.isVerifiedWorking ? "Finder Sync Verified" : "Finder Sync Registered",
                detail: diagnostics.detailMessage
            )
        }

        return FinderIntegrationAvailabilityStatus(
            state: .setupPending,
            title: "Finder Sync Needs Setup",
            detail: "Finder integration is enabled in Sorty, but the macOS Finder Sync extension is currently \(diagnostics.statusText.lowercased()). Open Settings -> Finder Integration and run Repair to finish setup."
        )
    }

    /// Whether the legacy "Organize with Sorty" toolbar app bundle exists.
    private static func isToolbarAppInstalled() -> Bool {
        let appPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Sorty")
            .appendingPathComponent("Organize with Sorty.app")
        guard let appPath else { return false }
        return FileManager.default.fileExists(atPath: appPath.path)
    }

    public static func getIntegrationStatusAsync() async -> FinderIntegrationStatus {
        let finderSyncEnabled = await isFinderSyncExtensionActiveAsync()
        UserDefaults.standard.set(finderSyncEnabled, forKey: "enableFinderSyncExtension")

        let quickWatchActionInstalled = await isQuickWatchActionInstalledAsync()
        let quickExcludeActionInstalled = await isQuickExcludeActionInstalledAsync()
        let toolbarAppInstalled = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: isToolbarAppInstalled())
            }
        }

        return FinderIntegrationStatus(
            quickActionInstalled: await isQuickActionInstalledAsync(),
            quickWatchActionInstalled: quickWatchActionInstalled,
            quickExcludeActionInstalled: quickExcludeActionInstalled,
            toolbarAppInstalled: toolbarAppInstalled,
            finderSyncEnabled: finderSyncEnabled,
            menuBarEnabled: UserDefaults.standard.bool(forKey: "showMenuBarExtra")
        )
    }
}
