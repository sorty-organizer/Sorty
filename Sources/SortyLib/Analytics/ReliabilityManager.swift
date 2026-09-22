//
//  ReliabilityManager.swift
//  Sorty
//
//  Consent-gated, privacy-preserving crash, hang, error, and performance reporting.
//

import Foundation
@preconcurrency import Sentry

@MainActor
public final class ReliabilityManager {
    public static let shared = ReliabilityManager()

    private static let productionDSN =
        "https://5765fff5d0af8028865923c7c73b18ef@o4511816291844096.ingest.us.sentry.io/4511816293744640"

    private let defaults: UserDefaults
    private var isActive = false
    private var isStarting = false
    private var captureRateLimiter = ReliabilityCaptureRateLimiter()
    private var launchSpan: ReliabilitySpan?

    public var diagnosticSummary: [String: Any] {
        [
            "consent": consent.rawValue,
            "active": isActive,
            "environment": Self.environmentName,
            "send_default_pii": false,
            "network_tracking": false,
            "file_io_tracing": false,
            "raw_payloads_included": false,
        ]
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func startIfAuthorized() {
        guard consent == .granted,
              !NetworkPrivacyPolicy.isInternetPrivacyModeEnabled
        else {
            stopAndClear()
            return
        }

        guard !isActive,
              !isStarting,
              !Self.isReliabilitySuppressedForThisProcess,
              let dsn = Self.configuredDSN()
        else {
            return
        }

        // Keep consent gating on the main actor; hop SDK start off launch.
        isStarting = true
        let cacheDirectory = Self.cacheDirectory
        let releaseName = Self.releaseName
        let buildNumber = Self.buildNumber
        let environmentName = Self.environmentName
        let tracesSampleRate = Self.tracesSampleRate
        let telemetryAttributes = Self.telemetryAttributes
        let metricAttributes = Self.metricAttributes
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )

        Task.detached(priority: .utility) {
            let options = Options()
            options.dsn = dsn
            options.cacheDirectoryPath = cacheDirectory.path
            options.releaseName = releaseName
            options.dist = buildNumber
            options.environment = environmentName
            options.sendDefaultPii = false
            options.enableCrashHandler = true
            options.enableAppHangTracking = true
            options.enableAutoSessionTracking = true
            options.enableWatchdogTerminationTracking = true
            options.enableNetworkTracking = false
            options.enableFileIOTracing = false
            options.enableAutoPerformanceTracing = false
            options.enableCoreDataTracing = false
            options.enableSwizzling = false
            options.enableMetricKitRawPayload = false
            options.enableLogs = true
            options.enableMetrics = true
            options.tracesSampleRate = tracesSampleRate

            SentrySDK.start(options: options)
            await MainActor.run {
                ReliabilityManager.shared.finishStarting(
                    telemetryAttributes: telemetryAttributes,
                    metricAttributes: metricAttributes
                )
            }
        }
    }

    private func finishStarting(
        telemetryAttributes: [String: Any],
        metricAttributes: [String: SentryAttributeValue]
    ) {
        isStarting = false
        guard !isActive, consent == .granted else { return }
        isActive = true
        SentrySDK.logger.info(
            "sorty.reliability.started",
            attributes: telemetryAttributes
        )
        SentrySDK.metrics.count(
            key: "sorty.app.launch",
            attributes: metricAttributes
        )
        launchSpan = startSpan(
            name: "app.launch",
            operation: "app.start",
            feature: "app_runtime"
        )
    }

    public func consentDidChange(_ newConsent: AnalyticsConsent) {
        if newConsent == .granted {
            startIfAuthorized()
        } else {
            stopAndClear()
        }
    }

    public func networkPrivacyDidChange(isEnabled: Bool) {
        if isEnabled {
            stopAndClear()
        } else {
            startIfAuthorized()
        }
    }

    public func capture(
        error: Error,
        feature: String,
        operation: String,
        severity: String = "error",
        recoverable: Bool = true
    ) {
        guard isActive,
              consent == .granted,
              !NetworkPrivacyPolicy.isInternetPrivacyModeEnabled,
              !Self.shouldIgnore(error),
              captureRateLimiter.shouldCapture()
        else {
            return
        }

        let classification = Self.classify(error)
        let sanitizedError = SanitizedReliabilityError(
            category: classification.category,
            cause: classification.cause,
            operation: Self.boundedIdentifier(operation, fallback: "unknown_operation")
        )
        let safeFeature = Self.boundedIdentifier(feature, fallback: "unknown_feature")
        let safeOperation = Self.boundedIdentifier(
            operation,
            fallback: "unknown_operation"
        )

        SentrySDK.logger.error(
            "sorty.reliability.handled_error",
            attributes: [
                "platform_surface": "mac_app",
                "feature": safeFeature,
                "operation": safeOperation,
                "error_category": classification.category,
                "error_cause": classification.cause,
                "recoverable": recoverable,
            ]
        )
        SentrySDK.metrics.count(
            key: "sorty.app.handled_error",
            attributes: [
                "platform_surface": "mac_app",
                "feature": safeFeature,
                "operation": safeOperation,
                "error_category": classification.category,
                "recoverable": recoverable,
            ]
        )

        SentrySDK.capture(error: sanitizedError) { scope in
            scope.setTag(value: "mac_app", key: "platform_surface")
            scope.setTag(
                value: safeFeature,
                key: "feature"
            )
            scope.setTag(
                value: safeOperation,
                key: "operation"
            )
            scope.setTag(value: classification.category, key: "error_category")
            scope.setTag(value: classification.cause, key: "error_cause")
            scope.setTag(value: classification.type, key: "error_type")
            scope.setTag(
                value: Self.boundedIdentifier(severity, fallback: "error"),
                key: "severity"
            )
            scope.setTag(value: recoverable ? "true" : "false", key: "recoverable")
        }
    }

    @discardableResult
    public func captureDiagnosticReport(reportID: String) -> String? {
        guard isActive,
              consent == .granted,
              !NetworkPrivacyPolicy.isInternetPrivacyModeEnabled,
              captureRateLimiter.shouldCapture()
        else {
            return nil
        }

        let eventID = SentrySDK.capture(
            message: "sorty.diagnostic_report.generated"
        ) { scope in
            scope.setTag(value: "mac_app", key: "platform_surface")
            scope.setTag(value: "diagnostic_report", key: "feature")
            scope.setTag(value: "generated", key: "operation")
            scope.setTag(value: reportID, key: "diagnostic_report_id")
        }
        return eventID == .empty ? nil : eventID.sentryIdString
    }

    public func startSpan(
        name: String,
        operation: String,
        feature: String
    ) -> ReliabilitySpan? {
        guard isActive,
              consent == .granted,
              !NetworkPrivacyPolicy.isInternetPrivacyModeEnabled,
              captureRateLimiter.shouldCapture()
        else {
            return nil
        }

        let span = SentrySDK.startTransaction(
            name: Self.boundedIdentifier(name, fallback: "app.operation"),
            operation: Self.boundedIdentifier(operation, fallback: "app.operation")
        )
        span.setTag(
            value: Self.boundedIdentifier(feature, fallback: "unknown_feature"),
            key: "feature"
        )
        span.setTag(value: "mac_app", key: "platform_surface")
        return ReliabilitySpan(span: span)
    }

    public func finishLaunchSpan() {
        launchSpan?.finish()
        launchSpan = nil
    }

    public func stopAndClear() {
        launchSpan = nil
        isStarting = false
        if isActive {
            isActive = false
            SentrySDK.close()
        }
        captureRateLimiter.reset()
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
    }

    private var consent: AnalyticsConsent {
        defaults.string(forKey: AnalyticsManager.consentDefaultsKey)
            .flatMap(AnalyticsConsent.init(rawValue:)) ?? .undecided
    }

    private static var releaseName: String {
        "com.sorty.app@\(versionNumber)+\(buildNumber)"
    }

    private static var versionNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
    }

    private static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    private static var environmentName: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    private static var tracesSampleRate: NSNumber {
        #if DEBUG
        return 1
        #else
        // Keep full local diagnostics while limiting the retained and uploaded
        // transaction volume for an app that commonly runs all day.
        return 0.1
        #endif
    }

    private static func configuredDSN(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        #if DEBUG
        let dsn = environment["SORTY_SENTRY_DSN"] ?? productionDSN
        #else
        let dsn = productionDSN
        #endif

        guard let components = URLComponents(string: dsn),
              components.scheme == "https",
              components.host == "o4511816291844096.ingest.us.sentry.io",
              components.user != nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            return nil
        }
        return dsn
    }

    private static var telemetryAttributes: [String: Any] {
        [
            "platform_surface": "mac_app",
            "environment": environmentName,
        ]
    }

    private static var metricAttributes: [String: SentryAttributeValue] {
        [
            "platform_surface": "mac_app",
            "environment": environmentName,
        ]
    }

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("com.sorty.app", isDirectory: true)
            .appendingPathComponent("Sentry", isDirectory: true)
    }

    private static var isReliabilitySuppressedForThisProcess: Bool {
        let process = ProcessInfo.processInfo
        return process.environment["XCTestConfigurationFilePath"] != nil
            || process.arguments.contains("--uitesting")
            || process.environment["SORTY_HARNESS_MODE"] == "1"
    }

    private static func shouldIgnore(_ error: Error) -> Bool {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        return error is CancellationError
            || nsError.code == NSUserCancelledError
            || nsError.code == NSURLErrorCancelled
            || description.contains("cancelled")
            || description.contains("canceled")
            || description.contains("block internet")
            || description.contains("internet connections")
    }

    private static func classify(_ error: Error) -> ReliabilityErrorClassification {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()

        if nsError.code == NSURLErrorTimedOut
            || description.contains("timed out")
            || description.contains("timeout")
        {
            return .init(category: "network", cause: "timeout", type: "url_error")
        }
        if nsError.domain == NSURLErrorDomain {
            return .init(
                category: "network",
                cause: "connection_failed",
                type: "url_error"
            )
        }
        if nsError.domain == NSPOSIXErrorDomain || nsError.domain == NSCocoaErrorDomain {
            if description.contains("permission")
                || description.contains("not permitted")
                || description.contains("access")
            {
                return .init(
                    category: "permission",
                    cause: "access_denied",
                    type: "filesystem_error"
                )
            }
            return .init(
                category: "filesystem",
                cause: "file_operation_failed",
                type: "filesystem_error"
            )
        }
        if description.contains("api key")
            || description.contains("authentication")
            || description.contains("unauthorized")
        {
            return .init(
                category: "authentication",
                cause: "credentials_rejected",
                type: "provider_error"
            )
        }
        if description.contains("configuration") || description.contains("not configured") {
            return .init(
                category: "configuration",
                cause: "missing_or_invalid_configuration",
                type: "configuration_error"
            )
        }
        if description.contains("validation")
            || description.contains("invalid response")
            || description.contains("decode")
        {
            return .init(
                category: "validation",
                cause: "invalid_data",
                type: "validation_error"
            )
        }

        return .init(
            category: "unknown",
            cause: "unclassified",
            type: "application_error"
        )
    }

    private static func boundedIdentifier(_ value: String, fallback: String) -> String {
        let normalized = value.lowercased().replacingOccurrences(
            of: #"[^a-z0-9_.-]+"#,
            with: "_",
            options: .regularExpression
        )
        let bounded = String(normalized.prefix(64))
        return bounded.isEmpty ? fallback : bounded
    }
}

@MainActor
public final class ReliabilitySpan {
    private let span: any Span
    private var isFinished = false

    fileprivate init(span: any Span) {
        self.span = span
    }

    public func finish() {
        guard !isFinished else { return }
        isFinished = true
        span.finish()
    }
}

struct ReliabilityCaptureRateLimiter {
    private var limiter = AnalyticsCaptureRateLimiter(
        maximumEventsPerMinute: 30,
        maximumEventsPerProcess: 500
    )

    mutating func shouldCapture(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        limiter.shouldCapture(now: now)
    }

    mutating func reset() {
        limiter.reset()
    }
}

private struct ReliabilityErrorClassification: Sendable {
    let category: String
    let cause: String
    let type: String
}

private struct SanitizedReliabilityError: LocalizedError, CustomNSError {
    let category: String
    let cause: String
    let operation: String

    static var errorDomain: String { "com.sorty.app.reliability" }
    var errorCode: Int { 1 }
    var errorDescription: String? { "\(category):\(cause):\(operation)" }
}
