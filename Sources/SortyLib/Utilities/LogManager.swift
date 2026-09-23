//
//  LogManager.swift
//  Sorty
//
//  Production-grade logging system with rotation, sanitization, and export.
//

import Foundation

public enum DiagnosticReportError: LocalizedError {
    case unavailable
    case archiveFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Sorty couldn't prepare the diagnostic report."
        case .archiveFailed:
            return "Sorty couldn't create the diagnostic ZIP archive."
        }
    }
}

public struct DiagnosticReportResult: Sendable {
    public let reportID: String
    public let sentryEventID: String?
}

/// Best-effort log context ferried to the logging queue. The payload is only
/// JSON-serialized there, so shared mutable values are never touched off-queue.
private struct UncheckedLogPayload: @unchecked Sendable {
    let data: [String: Any]?
}

public final class LogManager: @unchecked Sendable {
    public static let shared = LogManager()
    
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.sorty.logQueue")
    private let maxArchivedLogFiles = 2
    private let maxLogSize: UInt64 = 2 * 1024 * 1024
    private var currentLogSize: UInt64 = 0
    private var logFileHandle: FileHandle?
    private var hasPreparedLogFile = false
    private let timestampFormatter = ISO8601DateFormatter()
    private let userPathRegex = try? NSRegularExpression(pattern: "/Users/([^/]+)")
    /// Debug sampling: hot loops must not thrash the log file, so only 1 in
    /// 100 debug messages is persisted. Info and above always persist.
    private let debugSampleLock = NSLock()
    private var debugSampleCount = 0

    private var logsDirectory: URL? {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sorty.app"
        let logsDir = appSupport.appendingPathComponent(bundleID).appendingPathComponent("Logs")
        
        if !fileManager.fileExists(atPath: logsDir.path) {
            try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }
        
        return logsDir
    }
    
    private var currentLogFile: URL? {
        return logsDirectory?.appendingPathComponent("sorty.log")
    }
    
    private init() {}
    
    // MARK: - Public API
    
    public func log(
        _ message: @autoclosure () -> String,
        level: LogLevel = .info,
        category: String = "General",
        data: [String: Any]? = nil
    ) {
        guard shouldPersist(level) else { return }
        if level == .debug, !shouldKeepDebugSample() { return }
        let resolvedMessage = message()
        // The context payload is serialized on the logging queue; box it so the
        // @Sendable work item below captures only Sendable state.
        let payload = UncheckedLogPayload(data: data)
        queue.async {
            self.writeLog(resolvedMessage, level: level, category: category, data: payload.data)
        }
    }
    
    // Cheap MainActor-bound reads stay on the main actor; every blocking
    // step (log scans, file writes, ditto zip) runs in writeReport off it,
    // so the UI never beachballs while a report is generated.
    @MainActor
    public func generateDiagnosticReport(
        config: AIConfig,
        at destinationURL: URL
    ) async throws -> DiagnosticReportResult {
        guard let logsDirectory else { throw DiagnosticReportError.unavailable }
        // Flush pending log writes without blocking the main actor: the
        // serial logging queue drains ahead of this async barrier, then the
        // file handle is synchronized for a consistent snapshot.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                try? self.logFileHandle?.synchronize()
                continuation.resume()
            }
        }
        let reportID = UUID().uuidString.lowercased()
        let sentryEventID = ReliabilityManager.shared.captureDiagnosticReport(reportID: reportID)

        let overview = diagnosticOverview(
            config: config,
            reportID: reportID,
            sentryEventID: sentryEventID
        )
        let telemetry: String
        do {
            telemetry = try telemetryReport(reportID: reportID, sentryEventID: sentryEventID)
        } catch {
            throw DiagnosticReportError.unavailable
        }
        let readme = privacyReadme

        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.writeReport(
                    overview: overview,
                    telemetry: telemetry,
                    readme: readme,
                    logsDirectory: logsDirectory,
                    destinationURL: destinationURL
                )
            }.value
        } catch let reportError as DiagnosticReportError {
            throw reportError
        } catch {
            throw DiagnosticReportError.unavailable
        }
        return DiagnosticReportResult(
            reportID: reportID,
            sentryEventID: sentryEventID
        )
    }

    nonisolated private static func writeReport(
        overview: String,
        telemetry: String,
        readme: String,
        logsDirectory: URL,
        destinationURL: URL
    ) throws {
        let fileManager = FileManager.default
        let reportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("Sorty-Diagnostic-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: reportDirectory) }

        do {
            try fileManager.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
            try overview.write(
                to: reportDirectory.appendingPathComponent("diagnostic.txt"),
                atomically: true,
                encoding: .utf8
            )
            try telemetry.write(
                to: reportDirectory.appendingPathComponent("telemetry.json"),
                atomically: true,
                encoding: .utf8
            )
            try logSummary(in: logsDirectory, fileManager: fileManager).write(
                to: reportDirectory.appendingPathComponent("log-summary.json"),
                atomically: true,
                encoding: .utf8
            )
            try safeLogTimeline(in: logsDirectory, fileManager: fileManager).write(
                to: reportDirectory.appendingPathComponent("log-timeline.json"),
                atomically: true,
                encoding: .utf8
            )
            try readme.write(
                to: reportDirectory.appendingPathComponent("README.txt"),
                atomically: true,
                encoding: .utf8
            )

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = [
                "-c", "-k", "--sequesterRsrc",
                reportDirectory.path, destinationURL.path,
            ]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw DiagnosticReportError.archiveFailed
            }
        } catch {
            if let reportError = error as? DiagnosticReportError {
                throw reportError
            }
            throw DiagnosticReportError.unavailable
        }
    }

    @MainActor
    private func diagnosticOverview(
        config: AIConfig,
        reportID: String,
        sentryEventID: String?
    ) -> String {
        let process = ProcessInfo.processInfo
        let defaults = UserDefaults.standard
        let memory = ByteCountFormatter.string(
            fromByteCount: Int64(process.physicalMemory),
            countStyle: .memory
        )
        // Model IDs (e.g. gpt-5.4-mini) are public provider catalog values,
        // never user data, so the bounded identifier is safe for support.
        let modelTrimmed = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveModel = modelTrimmed.isEmpty ? config.provider.defaultModel : modelTrimmed
        let apiKeyConfigured = !(config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let customAPIURL = config.apiURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return """
        Sorty Diagnostic Report
        Generated: \(timestampFormatter.string(from: Date()))
        Diagnostic ID: \(reportID)
        Sentry event: \(sentryEventID ?? "Not sent — reliability sharing is unavailable or disabled")

        App
        - Version: \(BuildInfo.fullVersion)
        - Commit: \(BuildInfo.shortCommit)
        - Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")
        - Build: \(Self.buildConfiguration)

        System
        - macOS: \(process.operatingSystemVersionString)
        - Architecture: \(Self.systemArchitecture)
        - CPU cores: \(process.activeProcessorCount)
        - Memory: \(memory)
        - Locale: \(Locale.current.identifier)
        - UTC offset: \(Self.utcOffsetLabel)
        - Uptime: \(Self.uptimeBucket(process.systemUptime))
        - Disk free: \(Self.diskFreeBucket)
        - Full Disk Access: \(Self.yesNo(FullDiskAccessProbe.isGranted()))
        - Finder integration enabled: \(Self.yesNo(FeatureFlags.finderSyncEnabled))

        AI configuration
        - Provider: \(config.provider.displayName)
        - Model: \(String(effectiveModel.prefix(128)))\(modelTrimmed.isEmpty ? " (provider default)" : "")
        - Auth method: \(config.authMethod(for: config.provider).displayName)
        - API key configured: \(Self.yesNo(apiKeyConfigured))
        - Requires API key: \(Self.yesNo(config.requiresAPIKey))
        - Custom API URL: \(customAPIURL.isEmpty ? "No" : (Self.isLocalhostURL(customAPIURL) ? "Yes (localhost)" : "Yes (remote)"))
        - Readiness: \(Self.providerReadiness(config: config, apiKeyConfigured: apiKeyConfigured))
        - Mode: \(config.mode.displayName)
        - Deep scan: \(Self.yesNo(config.enableDeepScan))
        - Vision: \(Self.yesNo(config.enableVision)) (\(config.effectiveVisionDetailLevel.displayName), \(config.limitVisionImages ? "\(config.visionBatchStrategy.displayName), max \(config.visionBatchSize)" : "all images"))
        - Smart rename: \(Self.yesNo(config.enableSmartRename)) (\(config.renameRules.count) custom rules, \(config.renameRuleMode.displayName))
        - Naming style: \(config.namingStyle.displayName)
        - Custom naming instructions: \(Self.yesNo(!(config.customNamingInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)))
        - System prompt override: \(Self.yesNo(!(config.systemPromptOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)))
        - Duplicate detection: \(Self.yesNo(config.detectDuplicates)) (\(config.duplicateHandlingMode.rawValue))
        - File tagging: \(Self.yesNo(config.enableFileTagging))
        - Strict exclusions: \(Self.yesNo(config.strictExclusions))
        - Streaming: \(Self.yesNo(config.enableStreaming))
        - Reasoning: \(Self.yesNo(config.enableReasoning))
        - Max tokens override: \(config.maxTokens.map(String.init) ?? "provider default")
        - OCR languages: \(config.ocrLanguages.count)
        - Automation override: \(config.automationProvider.map(\.displayName) ?? "none")\(config.automationModel.map { " (\($0.prefix(64)))" } ?? "")
        - Request timeout: \(Int(config.requestTimeout))s
        - Resource timeout: \(Int(config.resourceTimeout))s

        App settings
        - Privacy mode: \(Self.yesNo(defaults.bool(forKey: "privacyModeEnabled")))
        - Block Internet Connections: \(Self.yesNo(FeatureFlags.internetPrivacyModeEnabled))
        - Menu bar extra: \(Self.yesNo(defaults.object(forKey: "showMenuBarExtra") as? Bool ?? true))
        - Completed onboarding: \(Self.yesNo(defaults.bool(forKey: "hasCompletedOnboarding")))
        """
    }

    @MainActor
    private func telemetryReport(reportID: String, sentryEventID: String?) throws -> String {
        let analytics = AnalyticsManager.shared
        let reliability = ReliabilityManager.shared
        let grouped = Dictionary(
            grouping: NotificationManager.shared.analyticsEvents,
            by: { "\($0.eventType.rawValue):\($0.notificationType)" }
        ).mapValues(\.count)
        let totalActivityEvents = grouped.values.reduce(0, +)
        // Bound the dict so one noisy category can't bloat the archive.
        let activityCounts = Dictionary(
            uniqueKeysWithValues: grouped.sorted { $0.value > $1.value }.prefix(50).map { ($0.key, $0.value) }
        )
        let experimentIDs = analytics.experimentalFeatures
            .map { String($0.id.prefix(64)) }
            .sorted()
            .prefix(20)
            .map { $0 }

        let report: [String: Any] = [
            "diagnostic_report_id": reportID,
            "sentry_event_id": sentryEventID ?? NSNull(),
            "posthog": [
                "consent": analytics.consent.rawValue,
                "active": analytics.isActive,
                "internet_privacy_blocked": FeatureFlags.internetPrivacyModeEnabled,
                "person_profiles": "disabled",
                "geoip": "disabled",
                "allowed_event_families": [
                    "app:session_started",
                    "app:screen_viewed",
                    "app:feature_used",
                    "app:workflow_progressed",
                    "app:important_button_clicked",
                ],
                "active_experiment_count": analytics.experimentalFeatures.count,
                "active_experiment_ids": Array(experimentIDs),
            ],
            "sentry": reliability.diagnosticSummary,
            "local_activity_counts": activityCounts,
            "local_activity_total": totalActivityEvents,
            "local_activity_truncated": grouped.count > activityCounts.count,
            "privacy": [
                "contains_remote_events": false,
                "contains_user_or_device_ids": false,
                "contains_diagnostic_correlation_ids": true,
                "contains_raw_errors": false,
                "contains_notification_details": false,
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private static func safeLogTimeline(in directory: URL, fileManager: FileManager = .default) throws -> String {
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let pattern = try NSRegularExpression(
            pattern: #"^\[([^\]]+)\] \[([A-Z]+)\] \[([A-Za-z0-9_. -]{1,64})\] (.*)$"#
        )
        var entries: [[String: String]] = []
        var signalTotals: [String: Int] = [:]
        var totalParsed = 0

        for file in files {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            contents.enumerateLines { line, _ in
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard let match = pattern.firstMatch(in: line, range: range),
                      let timestampRange = Range(match.range(at: 1), in: line),
                      let levelRange = Range(match.range(at: 2), in: line),
                      let categoryRange = Range(match.range(at: 3), in: line),
                      let messageRange = Range(match.range(at: 4), in: line)
                else { return }
                totalParsed += 1
                let signals = Self.diagnosticSignals(in: String(line[messageRange]))
                for signal in signals { signalTotals[signal, default: 0] += 1 }
                entries.append([
                    "timestamp": String(line[timestampRange]),
                    "level": String(line[levelRange]),
                    "category": String(line[categoryRange]),
                    "signals": signals.isEmpty ? "none" : signals.joined(separator: ","),
                ])
                if entries.count > 250 {
                    entries.removeFirst(entries.count - 250)
                }
            }
        }

        let data = try JSONSerialization.data(
            withJSONObject: [
                "entries": entries,
                "total_parsed": totalParsed,
                "kept": entries.count,
                "dropped": max(0, totalParsed - entries.count),
                "signal_totals": signalTotals,
                "raw_messages_included": false,
                "description": "Chronology and machine-derived failure signals; message text is discarded.",
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private static func diagnosticSignals(in message: String) -> [String] {
        let lowercased = message.lowercased()
        var signals: [String] = []
        let rules: [(String, [String])] = [
            ("timeout", ["timeout", "timed out"]),
            ("cancelled", ["cancelled", "canceled"]),
            ("permission_denied", ["permission", "not permitted", "access denied"]),
            ("authentication", ["unauthorized", "authentication", "invalid token", "signing out", "api key"]),
            ("rate_limited", ["rate limit", "too many requests", "429"]),
            ("network", ["connection", "network", "offline", "dns"]),
            ("file_conflict", ["already exists", "path exists", "conflict"]),
            ("parse_failure", ["parse", "decoding", "invalid json", "unexpected response", "schema"]),
            ("disk", ["disk full", "no space", "enospc"]),
            ("memory", ["out of memory", "memory pressure", "memory warning"]),
            ("keychain", ["keychain", "secitem", "errsec"]),
            ("finder", ["finder", "appex", "pluginkit", "finder sync"]),
            ("provider", ["model not found", "invalid model", "context length", "overloaded", "service unavailable"]),
        ]
        for (signal, needles) in rules where needles.contains(where: lowercased.contains) {
            signals.append(signal)
        }
        if let status = firstMatch(in: message, pattern: #"\bHTTP\s+([1-5][0-9]{2})\b"#) {
            signals.append("http_\(status)")
        }
        if let code = firstMatch(
            in: message,
            pattern: #"\b(?:NSURLError|OSStatus|errSec|error\s+code|code)[\s:=]+(-?[0-9]+)\b"#
        ) {
            signals.append("code_\(code)")
        }
        if let exitCode = firstMatch(in: message, pattern: #"\bexit(?:ed)?\s*(?:code|status)?[: ]+(-?[0-9]+)\b"#) {
            signals.append("exit_\(exitCode)")
        }
        return signals
    }

    private static func firstMatch(in value: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              let range = Range(match.range(at: 1), in: value)
        else {
            return nil
        }
        return String(value[range])
    }

    private static func logSummary(in directory: URL, fileManager: FileManager = .default) throws -> String {
        var levels: [String: Int] = [:]
        var categories: [String: Int] = [:]
        var signals: [String: Int] = [:]
        var totalLines = 0
        var oldestTimestamp: String?
        var newestTimestamp: String?
        var filesInfo: [[String: Any]] = []
        let pattern = try NSRegularExpression(
            pattern: #"^\[([^\]]+)\] \[([A-Z]+)\] \[([A-Za-z0-9_. -]{1,64})\](?: (.*))?$"#
        )
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in files {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var fileLines = 0
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            contents.enumerateLines { line, _ in
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard let match = pattern.firstMatch(in: line, range: range),
                      let timestampRange = Range(match.range(at: 1), in: line),
                      let levelRange = Range(match.range(at: 2), in: line),
                      let categoryRange = Range(match.range(at: 3), in: line)
                else { return }
                let timestamp = String(line[timestampRange])
                if oldestTimestamp == nil || timestamp < oldestTimestamp! { oldestTimestamp = timestamp }
                if newestTimestamp == nil || timestamp > newestTimestamp! { newestTimestamp = timestamp }
                levels[String(line[levelRange]), default: 0] += 1
                categories[String(line[categoryRange]), default: 0] += 1
                if let messageRange = Range(match.range(at: 4), in: line) {
                    for signal in Self.diagnosticSignals(in: String(line[messageRange])) {
                        signals[signal, default: 0] += 1
                    }
                }
                totalLines += 1
                fileLines += 1
            }
            // lastPathComponent only: these are Sorty-owned log names
            // (sorty.log, sorty-<timestamp>.log), never user file names.
            filesInfo.append([
                "name": file.lastPathComponent,
                "size_bytes": size,
                "parsed_lines": fileLines,
            ])
        }

        var report: [String: Any] = [
            "log_file_count": files.count,
            "total_lines": totalLines,
            "levels": levels,
            "categories": categories,
            "signals": signals,
            "files": filesInfo,
            "raw_messages_included": false,
        ]
        if let oldestTimestamp { report["oldest_timestamp"] = oldestTimestamp }
        if let newestTimestamp { report["newest_timestamp"] = newestTimestamp }
        let data = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private var privacyReadme: String {
        """
        This archive is designed to be safe to attach to a public GitHub issue.

        It intentionally excludes raw log messages, file and folder names, paths,
        file contents, prompts, custom instructions text, system prompt text,
        credentials, API keys, API URLs and hosts, email addresses, user or
        device identifiers, timezone cities, PostHog event payloads, Sentry
        envelopes, crash dumps, and SDK caches. The diagnostic and Sentry event
        IDs are random correlation values and do not identify the user or device.
        Where a value could identify you, the report keeps only a bounded fact:
        Yes/No presence, a count, a bucket (e.g. 1_10GB, 8_24h), a UTC offset,
        or a public catalog name such as the provider or model ID.

        diagnostic.txt contains environment and bounded configuration facts,
        including build channel, exact model ID, auth readiness, and storage,
        permission, and Finder-enablement signals.
        telemetry.json describes analytics and reliability status plus aggregate
        local activity categories (top 50, with totals). log-summary.json
        contains counts only, plus per-log-file sizes, time range, and a signal
        histogram. log-timeline.json preserves chronology and recognized
        failure signals while permanently discarding every raw log message.
        """
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private static var buildConfiguration: String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }

    // UTC offset only (e.g. UTC-5), never the timezone city, so timestamps
    // stay interpretable without revealing coarse location.
    private static var utcOffsetLabel: String {
        let seconds = TimeZone.current.secondsFromGMT()
        let hours = seconds / 3600
        let minutes = abs(seconds % 3600) / 60
        let sign = seconds < 0 ? "-" : "+"
        return minutes == 0 ? "UTC\(sign)\(abs(hours))" : "UTC\(sign)\(abs(hours)):\(String(format: "%02d", minutes))"
    }

    private static func uptimeBucket(_ uptime: TimeInterval) -> String {
        switch uptime {
        case ..<3600: return "under_1h"
        case ..<28800: return "1_8h"
        case ..<86400: return "8_24h"
        case ..<604800: return "1_7d"
        default: return "7d_plus"
        }
    }

    private static var diskFreeBucket: String {
        let path = NSHomeDirectory()
        guard let values = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = values[.systemFreeSize] as? NSNumber
        else {
            return "unknown"
        }
        switch free.int64Value {
        case ..<1_000_000_000: return "under_1GB"
        case ..<10_000_000_000: return "1_10GB"
        case ..<50_000_000_000: return "10_50GB"
        default: return "50GB_plus"
        }
    }

    private static func isLocalhostURL(_ value: String) -> Bool {
        guard let host = URL(string: value)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
    }

    // Mirrors the Troubleshooting support checks without leaking secrets:
    // booleans and bounded enum names only, never keys, URLs, or prompts.
    @MainActor
    private static func providerReadiness(config: AIConfig, apiKeyConfigured: Bool) -> String {
        if config.requiresAPIKey,
           config.authMethod(for: config.provider) == .apiKey,
           !apiKeyConfigured {
            return "Not ready — missing API key"
        }
        if FeatureFlags.internetPrivacyModeEnabled,
           config.provider != .ollama,
           config.provider != .appleFoundationModel {
            return "Blocked — internet privacy is on"
        }
        return "Ready"
    }

    private static var systemArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
    
    // MARK: - Private Methods
    
    private func writeLog(_ message: String, level: LogLevel, category: String, data: [String: Any]?) {
        if !hasPreparedLogFile {
            hasPreparedLogFile = true
            rotateLogsIfNeeded()
            if let logFile = currentLogFile,
               let size = try? logFile.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                currentLogSize = UInt64(size)
            }
        }
        guard let logFile = currentLogFile else { return }
        
        let timestamp = timestampFormatter.string(from: Date())
        let sanitizedMessage = sanitize(message)
        var contextString = ""
        
        if let data = data {
            if let jsonData = try? JSONSerialization.data(withJSONObject: data, options: []),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                contextString = " | Context: " + sanitize(jsonString)
            }
        }
        
        let logLine = "[\(timestamp)] [\(level.rawValue.uppercased())] [\(category)] \(sanitizedMessage)\(contextString)\n"
        
        guard let data = logLine.data(using: .utf8) else { return }

        if logFileHandle == nil {
            if !fileManager.fileExists(atPath: logFile.path) {
                fileManager.createFile(atPath: logFile.path, contents: nil)
            }
            logFileHandle = try? FileHandle(forWritingTo: logFile)
            _ = try? logFileHandle?.seekToEnd()
        }

        guard let logFileHandle else { return }

        do {
            try logFileHandle.write(contentsOf: data)
            currentLogSize += UInt64(data.count)
            // fsync only on faults: warning-level fsyncs on every write kept
            // the disk awake during bulk operations. Rotation still syncs via
            // generateDiagnosticReport before reading.
            if level >= .fault {
                try logFileHandle.synchronize()
            }
        } catch {
            try? logFileHandle.close()
            self.logFileHandle = nil
        }

        if currentLogSize > maxLogSize {
            rotateLogsIfNeeded(force: true)
        }
    }

    private func shouldPersist(_ level: LogLevel) -> Bool {
#if DEBUG
        level >= .debug
#else
        level >= .info
#endif
    }

    private func shouldKeepDebugSample() -> Bool {
        debugSampleLock.lock()
        defer { debugSampleLock.unlock() }
        debugSampleCount &+= 1
        return debugSampleCount.isMultiple(of: 100) || debugSampleCount == 1
    }

    private func sanitize(_ text: String) -> String {
        // Fast path: messages without user paths or key prefixes skip every
        // regex below. This covers the vast majority of hot-loop messages.
        guard text.contains("/Users/")
            || text.contains("sk-")
            || text.contains("ghp_")
            || text.contains("gho_") else {
            return text
        }
        var result = text
        
        // Redact standard API keys
        result = result.replacingOccurrences(of: "sk-[a-zA-Z0-9]{20,}", with: "[REDACTED_OPENAI_KEY]", options: .regularExpression)
        result = result.replacingOccurrences(of: "ghp_[a-zA-Z0-9]{20,}", with: "[REDACTED_GITHUB_TOKEN]", options: .regularExpression)
        result = result.replacingOccurrences(of: "gho_[a-zA-Z0-9]{20,}", with: "[REDACTED_GITHUB_TOKEN]", options: .regularExpression)
        
        // Redact User Paths
        // Matches /Users/username/ or /Users/username
        // We look for /Users/ followed by non-slash characters
        if let regex = userPathRegex {
            let nsString = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: nsString.length))
            
            // Iterate in reverse to avoid range offsets shifting
            for match in matches.reversed() {
                if match.numberOfRanges > 1 {
                    let usernameRange = match.range(at: 1)
                    let username = nsString.substring(with: usernameRange)
                    
                    // Don't redact "Shared" or "Guest" if desired, but for strict privacy, redact all users
                    if username != "Shared" {
                        result = result.replacingOccurrences(of: "/Users/\(username)", with: "/Users/[REDACTED_USER]")
                    }
                }
            }
        }
        
        return result
    }
    
    private func rotateLogsIfNeeded(force: Bool = false) {
        guard let logsDirectory = logsDirectory, let currentLog = currentLogFile else { return }
        
        // If current log exists and is too big, or if we just want to verify cleanup
        if force || (try? fileManager.attributesOfItem(atPath: currentLog.path)) != nil {
            if force {
                try? logFileHandle?.close()
                logFileHandle = nil

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let timestamp = formatter.string(from: Date())
                let archivedLog = logsDirectory.appendingPathComponent("sorty-\(timestamp).log")
                
                try? fileManager.moveItem(at: currentLog, to: archivedLog)
                currentLogSize = 0
            }
            
            // Cleanup old logs
            do {
                let fileURLs = try fileManager.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)
                let logFiles = fileURLs.filter {
                    $0.pathExtension == "log" && $0 != currentLog
                }
                
                if logFiles.count > maxArchivedLogFiles {
                    let sortedFiles = logFiles.sorted {
                        let date0 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                        let date1 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                        return date0 < date1
                    }
                    
                    // Delete oldest
                    for i in 0..<(sortedFiles.count - maxArchivedLogFiles) {
                        try? fileManager.removeItem(at: sortedFiles[i])
                    }
                }
            } catch {
                print("Error rotating logs: \(error)")
            }
        }
    }
}

public enum LogLevel: String, Comparable, Sendable {
    case debug
    case info
    case warning
    case error
    case fault

    private var priority: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        case .fault: 4
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.priority < rhs.priority
    }
}
