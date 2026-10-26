//
//  ReliabilityManager.swift
//  Sorty
//
//  Consent-gated, privacy-preserving crash, hang, error, and performance reporting.
//

import Foundation
import AppKit
import UniformTypeIdentifiers
@preconcurrency import Sentry
import SortyFS

/// Product area a bug report is about; one per feature module so Sentry
/// reports can be filtered by `report_area`.
public enum BugReportArea: String, CaseIterable, Sendable {
    case organize
    case preview
    case history
    case rules
    case duplicates
    case watchedFolders = "watched_folders"
    case aiSetup = "ai_setup"
    case learnings
    case finderExtension = "finder_extension"
    case widgets
    case onboarding
    case settings
    case performance
    case other

    public var displayName: String {
        switch self {
        case .organize: "Organizing a folder"
        case .preview: "Preview and apply"
        case .history: "History and undo"
        case .rules: "Rules"
        case .duplicates: "Duplicates"
        case .watchedFolders: "Watched folders"
        case .aiSetup: "AI providers and models"
        case .learnings: "Learnings and personas"
        case .finderExtension: "Finder extension"
        case .widgets: "Widgets"
        case .onboarding: "Onboarding"
        case .settings: "Settings"
        case .performance: "Speed, crashes, or freezes"
        case .other: "Something else"
        }
    }
}

/// What kind of feedback the user is sending; drives copy, GitHub labels, and Sentry tags.
public enum FeedbackKind: String, CaseIterable, Sendable {
    case bug
    case idea
    case praise
    case other

    public var displayName: String {
        switch self {
        case .bug: "Something's broken"
        case .idea: "An idea"
        case .praise: "I love it"
        case .other: "Other"
        }
    }
}

@MainActor
public final class ReliabilityManager {
    public static let shared = ReliabilityManager()

    private static let productionDSN =
        "https://5765fff5d0af8028865923c7c73b18ef@o4511816291844096.ingest.us.sentry.io/4511816293744640"

    private let defaults: UserDefaults
    private var isActive = false
    private var isStarting = false
    private var startupGeneration: UInt64 = 0
    private var captureRateLimiter = ReliabilityCaptureRateLimiter()
    private var breadcrumbRateLimiter = AnalyticsCaptureRateLimiter(
        maximumEventsPerMinute: 120, maximumEventsPerProcess: 2_000
    )
    private var launchSpan: ReliabilitySpan?
    private var windowSystemObservers: [NSObjectProtocol] = []

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

    public var canSubmitBugFeedback: Bool {
        isActive && consent == .granted && !NetworkPrivacyPolicy.isInternetPrivacyModeEnabled
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
        startupGeneration &+= 1
        let generation = startupGeneration
        let cacheDirectory = Self.cacheDirectory
        let releaseName = Self.releaseName
        let buildNumber = Self.buildNumber
        let environmentName = Self.environmentName
        let tracesSampleRate = Self.tracesSampleRate
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
            options.attachStacktrace = true
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
            options.beforeSend = { event in
                ReliabilityEventKind.tag(event)
            }

            SentrySDK.start(options: options)
            await MainActor.run {
                ReliabilityManager.shared.finishStarting(
                    telemetryAttributes: Self.telemetryAttributes,
                    metricAttributes: Self.metricAttributes,
                    generation: generation
                )
            }
        }
    }

    private func finishStarting(
        telemetryAttributes: [String: Any],
        metricAttributes: [String: SentryAttributeValue],
        generation: UInt64
    ) {
        guard generation == startupGeneration else {
            // Stop/consent changes can invalidate setup while it is running.
            // Do not start a second setup until this one has been closed.
            isStarting = false
            SentrySDK.close()
            try? FileManager.default.removeItem(at: Self.cacheDirectory)
            startIfAuthorized()
            return
        }
        isStarting = false
        guard !isActive,
              consent == .granted,
              !NetworkPrivacyPolicy.isInternetPrivacyModeEnabled,
              !Self.isReliabilitySuppressedForThisProcess else {
            SentrySDK.close()
            try? FileManager.default.removeItem(at: Self.cacheDirectory)
            return
        }
        isActive = true
        SentrySDK.configureScope { scope in
            scope.setTag(
                value: InternalTelemetry.isEnabled ? "true" : "false",
                key: "is_internal"
            )
        }
        observeWindowSystem()
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

    /// Reports a handled error as a readable, sanitized Sentry issue.
    /// Call it at the workflow boundary that gave up on `error`; `feature` and
    /// `operation` must be fixed snake_case identifiers, never user data.
    /// The issue title reads like `AIProviderError: Organize › Generate plan
    /// — HTTP 503 (service unavailable)`, and the `fault` tag says who most
    /// likely needs to act. Only failures that point at Sorty itself, or that
    /// cannot be recovered from, are reported at error level.
    public func capture(
        error: Error,
        feature: String,
        operation: String,
        recoverable: Bool = true,
        requestContext: AIRequestDiagnosticContext? = nil
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
        let safeFeature = Self.boundedIdentifier(feature, fallback: "unknown_feature")
        let safeOperation = Self.boundedIdentifier(
            operation,
            fallback: "unknown_operation"
        )
        let level = Self.level(for: classification, recoverable: recoverable)
        let requestDetails = requestContext.map(Self.requestDiagnostics) ?? [:]
        let attributes: [String: Any] = [
            "platform_surface": "mac_app",
            "is_internal": InternalTelemetry.isEnabled,
            "feature": safeFeature,
            "operation": safeOperation,
            "error_category": classification.category,
            "error_cause": classification.cause,
            "fault": classification.fault.rawValue,
            "recoverable": recoverable,
        ].merging(requestDetails) { current, _ in current }

        SentrySDK.logger.error("sorty.reliability.handled_error", attributes: attributes)
        SentrySDK.metrics.count(
            key: "sorty.app.handled_error",
            attributes: [
                "platform_surface": "mac_app",
                "is_internal": InternalTelemetry.isEnabled,
                "feature": safeFeature,
                "operation": safeOperation,
                "error_category": classification.category,
                "fault": classification.fault.rawValue,
                "recoverable": recoverable,
            ]
        )

        // Build the exception explicitly. `Event(error:)` is not converted
        // into an exception by `capture(event:)`, which is what left these
        // issues titled "<unlabeled event>".
        let title = Self.issueTitle(
            feature: safeFeature,
            operation: safeOperation,
            classification: classification
        )
        let exception = Exception(value: title.value, type: title.type)
        let mechanism = Mechanism(type: "sorty.handled_error")
        mechanism.handled = true
        exception.mechanism = mechanism

        let event = Event(level: level)
        event.exceptions = [exception]
        event.transaction = "\(safeFeature).\(safeOperation)"
        event.extra = Self.errorDiagnostics(error).merging(requestDetails) { current, _ in current }
        // The version prefix starts clean issues instead of merging into the
        // unlabeled ones still arriving from 1.3.0.
        event.fingerprint = [
            "sorty.handled_error.v2",
            safeFeature,
            safeOperation,
            classification.category,
            classification.cause,
        ]
        SentrySDK.capture(event: event) { scope in
            scope.setTag(value: "mac_app", key: "platform_surface")
            scope.setTag(value: ReliabilityEventKind.handledError.rawValue, key: ReliabilityEventKind.tagKey)
            scope.setTag(value: safeFeature, key: "feature")
            scope.setTag(value: safeOperation, key: "operation")
            scope.setTag(value: classification.category, key: "error_category")
            scope.setTag(value: classification.cause, key: "error_cause")
            scope.setTag(value: classification.fault.rawValue, key: "fault")
            scope.setTag(value: recoverable ? "true" : "false", key: "recoverable")
            if let requestContext {
                scope.setTag(value: requestContext.provider.rawValue, key: "ai_provider")
                scope.setTag(value: requestContext.endpointKind.rawValue, key: "endpoint_kind")
            }
        }
    }

    /// Breadcrumbs give native hangs the recent app workload without enabling
    /// automatic network, file, interaction, or console collection.
    public func recordWorkflow(workflow: String, stage: String, outcome: String) {
        guard let data = Self.workflowDiagnostics(workflow: workflow, stage: stage, outcome: outcome) else { return }
        addBreadcrumb(category: "sorty.workflow", data: data)
    }

    /// Mirrors the PostHog `App Moved` / `App Deleted` family into Sentry:
    /// every stage becomes a breadcrumb and a `sorty.app.lifecycle` metric,
    /// and failures become a handled-error issue titled like
    /// `AppLifecycleError: App › Move to Applications — not_authorized`.
    public func recordAppLifecycle(stage: String, outcome: String, reason: String?, source: String?) {
        guard isActive, consent == .granted, !NetworkPrivacyPolicy.isInternetPrivacyModeEnabled else { return }
        let safeStage = Self.boundedIdentifier(stage, fallback: "unknown")
        let safeOutcome = Self.boundedIdentifier(outcome, fallback: "unknown")
        var data: [String: Any] = ["stage": safeStage, "outcome": safeOutcome]
        data["failure_reason"] = reason.map { Self.boundedIdentifier($0, fallback: "unknown") }
        data["source"] = source.map { Self.boundedIdentifier($0, fallback: "unknown") }
        addBreadcrumb(category: "sorty.app_lifecycle", data: data)
        SentrySDK.metrics.count(
            key: "sorty.app.lifecycle",
            attributes: [
                "platform_surface": "mac_app",
                "is_internal": InternalTelemetry.isEnabled,
                "stage": safeStage,
                "outcome": safeOutcome,
            ]
        )

        guard safeOutcome == "failed", captureRateLimiter.shouldCapture() else { return }
        let isMove = safeStage.hasPrefix("move")
        let operation = isMove ? "move_to_applications" : "uninstall"
        let cause = (data["failure_reason"] as? String) ?? "unknown"
        let fault: ReliabilityFault = ["not_authorized", "permission_denied", "source_missing"].contains(cause) ? .setup : .unknown
        let exception = Exception(
            value: "App › \(isMove ? "Move to Applications" : "Uninstall") — \(cause)",
            type: "AppLifecycleError"
        )
        let mechanism = Mechanism(type: "sorty.handled_error")
        mechanism.handled = true
        exception.mechanism = mechanism
        let event = Event(level: fault == .setup ? .warning : .error)
        event.exceptions = [exception]
        event.transaction = "app.\(operation)"
        event.extra = data
        event.fingerprint = ["sorty.handled_error.v2", "app", operation, "app_lifecycle", cause]
        SentrySDK.capture(event: event) { scope in
            scope.setTag(value: "mac_app", key: "platform_surface")
            scope.setTag(value: ReliabilityEventKind.handledError.rawValue, key: ReliabilityEventKind.tagKey)
            scope.setTag(value: "app", key: "feature")
            scope.setTag(value: operation, key: "operation")
            scope.setTag(value: "app_lifecycle", key: "error_category")
            scope.setTag(value: cause, key: "error_cause")
            scope.setTag(value: fault.rawValue, key: "fault")
            scope.setTag(value: "true", key: "recoverable")
        }
    }

    /// Uploads queued Sentry envelopes before Sorty quits or deletes itself.
    public func flushBeforeExit() async {
        guard isActive else { return }
        await Task.detached(priority: .userInitiated) {
            SentrySDK.flush(timeout: 1.5)
        }.value
    }

    public func recordScreen(_ screen: String) {
        guard let data = Self.screenDiagnostics(screen) else { return }
        addBreadcrumb(category: "sorty.navigation", data: data)
    }

    static func screenDiagnostics(_ screen: String) -> [String: Any]? {
        let screens: Set = ["organize", "history", "duplicates", "exclusions", "watched_folders", "learnings", "settings"]
        let sections: Set = ["general", "ai_provider", "analysis_and_naming", "organize_rules", "automation", "deeplinks", "finder_integration", "notifications", "permissions", "advanced", "troubleshooting", "help_and_support", "experimental"]
        guard screens.contains(screen) || (screen.hasPrefix("settings_") && sections.contains(String(screen.dropFirst(9)))) else { return nil }
        return ["screen": screen]
    }

    func recordAIRequest(
        requestID: UUID, context: AIRequestDiagnosticContext, outcome: String,
        batch: Int, adaptiveDepth: Int, elapsed: TimeInterval, error: Error?
    ) {
        var data = Self.requestDiagnostics(context)
        data["request_id"] = requestID.uuidString
        data["outcome"] = ["started", "succeeded", "failed", "split_retry"].contains(outcome) ? outcome : "unknown"
        data["batch_index"] = min(max(batch, 0), 1_000_000)
        data["adaptive_depth"] = min(max(adaptiveDepth, 0), 9)
        data["duration_ms"] = elapsed.isFinite ? Int(min(max(elapsed, 0), 3_600) * 1_000) : 0
        if let error, !Self.shouldIgnore(error) {
            let classification = Self.classify(error)
            data["error_cause"] = classification.cause
            data.merge(Self.errorDiagnostics(error)) { current, _ in current }
        }
        addBreadcrumb(category: "sorty.ai_request", data: data)
    }

    private func addBreadcrumb(category: String, data: [String: Any]) {
        guard isActive, consent == .granted,
              !NetworkPrivacyPolicy.isInternetPrivacyModeEnabled,
              breadcrumbRateLimiter.shouldCapture() else { return }
        let breadcrumb = Breadcrumb(level: .info, category: category)
        breadcrumb.data = data
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    static func requestDiagnostics(_ context: AIRequestDiagnosticContext) -> [String: Any] {
        var data: [String: Any] = [
            "ai_provider": context.provider.rawValue,
            "configured_authentication": context.authentication.rawValue,
            "organization_mode": context.mode.rawValue,
            "streaming_enabled": context.streaming,
            "vision_enabled": context.visionEnabled,
            "endpoint_kind": context.endpointKind.rawValue,
            "model_family": context.modelFamily,
            "configured_timeout_seconds": context.timeoutSeconds,
            "output_token_limit": context.outputTokenLimit,
        ]
        if let count = context.fileCount {
            data["file_count_bucket"] = AnalyticsManager.countBucket(count)
        }
        if let count = context.attachmentCount {
            data["attachment_count_bucket"] = AnalyticsManager.countBucket(count)
        }
        return data
    }

    static func workflowDiagnostics(workflow: String, stage: String, outcome: String) -> [String: Any]? {
        let workflows: Set = ["organize", "apply", "regenerate", "undo", "duplicate_scan", "app_launch", "model_catalog", "learnings_profile"]
        let stages: Set = ["started", "preparing", "scanning", "scan_completed", "plan_generation", "plan_ready", "apply", "applied", "apply_started", "restore", "loaded", "completed", "main_window_appeared", "window_ready", "cancel_requested", "cancelled", "failed", "finished"]
        let outcomes: Set = ["started", "success", "completed", "failed", "cancelled", "empty", "skipped"]
        guard workflows.contains(workflow), stages.contains(stage), outcomes.contains(outcome) else { return nil }
        return ["workflow": workflow, "stage": stage, "outcome": outcome]
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

        let event = Event(level: .info)
        event.message = SentryMessage(formatted: "Diagnostic report generated")
        event.fingerprint = ["sorty.diagnostic_report"]
        let eventID = SentrySDK.capture(event: event) { scope in
            scope.setTag(value: "mac_app", key: "platform_surface")
            scope.setTag(value: ReliabilityEventKind.diagnosticReport.rawValue, key: ReliabilityEventKind.tagKey)
            scope.setTag(value: "diagnostic_report", key: "feature")
            scope.setTag(value: "generated", key: "operation")
            scope.setTag(value: reportID, key: "diagnostic_report_id")
        }
        return eventID == .empty ? nil : eventID.sentryIdString
    }

    /// Links explicitly submitted bug text to a bounded Sentry event.
    /// Beyond the description, the event carries the feedback kind, chosen area,
    /// and (when `includeDiagnostics`) macOS version, chip type, and the current
    /// `window_system` context and recent breadcrumbs; the caller attaches the
    /// diagnostic ZIP. Without diagnostics both are stripped. A reply
    /// email and files are sent only when the user typed or attached them.
    @discardableResult
    public func submitBugFeedback(
        _ message: String,
        area: BugReportArea,
        kind: FeedbackKind = .bug,
        email: String? = nil,
        attachmentURLs: [URL] = [],
        includeDiagnostics: Bool = true
    ) -> String? {
        let comment = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmitBugFeedback,
              !comment.isEmpty,
              comment.count <= 2_000,
              captureRateLimiter.shouldCapture()
        else {
            return nil
        }

        if includeDiagnostics { refreshWindowSystemContext() }

        // Each report is its own error-level issue. Sentry derives priority from
        // level (error = high, warning = medium, info = low) and the default
        // alert rule only notifies on new high-priority issues, so any lower
        // level, or grouping reports together, means nobody gets notified.
        // Filter on the `event_kind:user_feedback` tag to separate them from crashes.
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: kind == .bug
            ? "User bug report: \(area.displayName)"
            : "User feedback (\(kind.displayName)): \(area.displayName)")
        event.fingerprint = ["sorty.user_bug_report", kind.rawValue, area.rawValue, UUID().uuidString]
        let eventID = SentrySDK.capture(event: event) { scope in
            scope.setTag(value: "mac_app", key: "platform_surface")
            scope.setTag(value: ReliabilityEventKind.userFeedback.rawValue, key: ReliabilityEventKind.tagKey)
            scope.setTag(value: "user_feedback", key: "feature")
            scope.setTag(value: "report_bug", key: "operation")
            scope.setTag(value: kind.rawValue, key: "feedback_kind")
            scope.setTag(value: area.rawValue, key: "report_area")
            if includeDiagnostics {
                scope.setTag(value: Self.operatingSystemVersion, key: "os_version")
                scope.setTag(value: Self.deviceArchitecture, key: "device_arch")
            } else {
                // No diagnostics: drop the app state that would otherwise ride
                // along from the shared scope.
                scope.removeContext(key: "window_system")
                scope.clearBreadcrumbs()
            }
        }
        guard eventID != .empty else { return nil }

        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Read the bytes now, inside the sandbox grant from the open panel or
        // drop. `Attachment(path:)` reads later on Sentry's queue, where the
        // sandbox can deny access and the file is silently dropped.
        let attachments = attachmentURLs.compactMap { url -> Attachment? in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return Attachment(
                data: data,
                filename: url.lastPathComponent,
                contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            )
        }
        let feedback = SentryFeedback(
            message: comment,
            name: nil,
            email: trimmedEmail?.isEmpty == false ? trimmedEmail : nil,
            source: .custom,
            associatedEventId: eventID,
            attachments: attachments.isEmpty ? nil : attachments
        )
        // The feedback item is its own issue (category Feedback) and has no
        // per-capture scope API, so tag the shared scope just for this capture.
        // Alert rules filter on these tags; without them feedback never notifies.
        let feedbackTags = [
            "feature": "user_feedback",
            ReliabilityEventKind.tagKey: ReliabilityEventKind.userFeedback.rawValue,
            "feedback_kind": kind.rawValue,
            "report_area": area.rawValue,
        ]
        SentrySDK.configureScope { scope in
            feedbackTags.forEach { scope.setTag(value: $1, key: $0) }
        }
        SentrySDK.capture(feedback: feedback)
        SentrySDK.configureScope { scope in
            feedbackTags.keys.forEach { scope.removeTag(key: $0) }
        }
        return eventID.sentryIdString
    }

    /// Keeps the `window_system` context current so hangs and bug reports
    /// show the display setup, accessibility display settings, and power state
    /// that WindowServer stalls depend on. Refreshed on the changes that matter.
    private func observeWindowSystem() {
        refreshWindowSystemContext()
        guard windowSystemObservers.isEmpty else { return }
        let names: [(NotificationCenter, Notification.Name)] = [
            (.default, NSApplication.didChangeScreenParametersNotification),
            (.default, NSWindow.didBecomeKeyNotification),
            (.default, ProcessInfo.thermalStateDidChangeNotification),
            (.default, .NSProcessInfoPowerStateDidChange),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification),
        ]
        windowSystemObservers = names.map { center, name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ReliabilityManager.shared.refreshWindowSystemContext() }
            }
        }
    }

    private func refreshWindowSystemContext() {
        guard isActive else { return }
        let context = Self.windowSystemContext()
        SentrySDK.configureScope { scope in
            scope.setContext(value: context, key: "window_system")
        }
    }

    /// Bounded counts, rates, and flags only: no window titles, display
    /// names, or anything that identifies the user or their files.
    static func windowSystemContext() -> [String: Any] {
        let screens = NSScreen.screens
        let workspace = NSWorkspace.shared
        let process = ProcessInfo.processInfo
        let windows = NSApp?.windows ?? []
        let thermal: String = switch process.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        return [
            "display_count": screens.count,
            "max_refresh_rate_hz": screens.map(\.maximumFramesPerSecond).max() ?? 0,
            "max_backing_scale": screens.map(\.backingScaleFactor).max() ?? 0,
            "visible_window_count": min(windows.filter(\.isVisible).count, 100),
            "app_active": NSApp?.isActive ?? false,
            "reduce_motion": workspace.accessibilityDisplayShouldReduceMotion,
            "reduce_transparency": workspace.accessibilityDisplayShouldReduceTransparency,
            "increase_contrast": workspace.accessibilityDisplayShouldIncreaseContrast,
            "low_power_mode": process.isLowPowerModeEnabled,
            "thermal_state": thermal,
            "physical_memory_gb": Int(process.physicalMemory / 1_073_741_824),
        ]
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
        span.setTag(
            value: InternalTelemetry.isEnabled ? "true" : "false",
            key: "is_internal"
        )
        return ReliabilitySpan(span: span)
    }

    public func finishLaunchSpan() {
        launchSpan?.finish()
        launchSpan = nil
    }

    public func stopAndClear() {
        launchSpan = nil
        windowSystemObservers.forEach(NotificationCenter.default.removeObserver)
        windowSystemObservers.removeAll()
        // Keep isStarting set so at most one Sentry setup is ever in flight.
        // The stale finish handler clears it once the in-flight setup is closed.
        startupGeneration &+= 1
        if isActive {
            isActive = false
            SentrySDK.close()
        }
        captureRateLimiter.reset()
        breadcrumbRateLimiter.reset()
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
    }

    private var consent: AnalyticsConsent {
        defaults.string(forKey: AnalyticsManager.consentDefaultsKey)
            .flatMap(AnalyticsConsent.init(rawValue:)) ?? .undecided
    }

    private static var releaseName: String {
        "com.sorty.app@\(versionNumber)+\(buildNumber)"
    }

    /// One-line environment summary shown in the feedback window and GitHub drafts.
    public static var diagnosticsSummary: String {
        "Sorty \(versionNumber) (\(buildNumber)) · macOS \(operatingSystemVersion) · \(deviceArchitecture)"
    }

    /// Bounded macOS version for bug-report tags, such as "15.2.0".
    /// Contains no identity, just the OS release support needs to reproduce.
    private static var operatingSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Chip type of the running app slice. Universal builds run the slice
    /// that matches the Mac, so the compile-time arch is the runtime arch.
    private static var deviceArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static var versionNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
    }

    private static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    private static var environmentName: String {
        // Debug builds are always internal too; keep them under "development".
        #if DEBUG
        return "development"
        #else
        return InternalTelemetry.isEnabled ? "internal" : "production"
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
            "is_internal": InternalTelemetry.isEnabled,
        ]
    }

    private static var metricAttributes: [String: SentryAttributeValue] {
        [
            "platform_surface": "mac_app",
            "environment": environmentName,
            "is_internal": InternalTelemetry.isEnabled,
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

    static func shouldIgnore(_ error: Error) -> Bool {
        if let aiError = error as? AIClientError {
            if case .internetAccessBlocked = aiError { return true }
            if case .networkError(let underlying) = aiError { return shouldIgnore(underlying) }
        }
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        return error is CancellationError
            || (nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError)
            || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            || description.contains("cancelled")
            || description.contains("canceled")
            || description.contains("block internet")
            || description.contains("internet connections")
    }

    static func classify(_ error: Error) -> ReliabilityErrorClassification {
        // Match typed failures before inspecting descriptions. Associated payloads
        // stay local; only fixed causes and valid HTTP status codes are reported.
        if let aiError = error as? AIClientError {
            switch aiError {
            case .missingAPIURL:
                return .init(category: "configuration", cause: "missing_api_url")
            case .missingAPIKey:
                return .init(category: "authentication", cause: "missing_api_key")
            case .invalidURL:
                return .init(category: "configuration", cause: "invalid_api_url")
            case .invalidResponse:
                return .init(category: "validation", cause: "invalid_response")
            case .invalidResponseFormat:
                return .init(category: "validation", cause: "invalid_response_format")
            case .jsonDecodingError:
                return .init(category: "validation", cause: "json_decoding_failed")
            case .internetAccessBlocked:
                return .init(category: "network", cause: "privacy_mode_blocked")
            case .networkError(let underlying):
                let classification = classify(underlying)
                if classification.category == "unknown" {
                    return .init(category: "network", cause: "connection_failed")
                }
                return classification
            case .apiError(let statusCode, _):
                let cause = aiError.isQuotaExhausted ? "quota_exhausted"
                    : ((100...599).contains(statusCode) ? "http_\(statusCode)" : "invalid_http_status")
                let category = (statusCode == 401 || statusCode == 403) ? "authentication" : "provider"
                return .init(category: category, cause: cause)
            }
        }
        if let organizationError = error as? OrganizationError {
            let category: String
            let cause: String
            switch organizationError {
            case .clientNotConfigured: category = "configuration"; cause = "client_not_configured"
            case .noCurrentPlan: category = "validation"; cause = "missing_plan"
            case .planDirectoryMismatch: category = "validation"; cause = "plan_directory_mismatch"
            case .fileMoveFailed: category = "filesystem"; cause = "file_move_failed"
            case .cancelled: category = "cancellation"; cause = "cancelled"
            case .revertAlreadyInProgress: category = "workflow"; cause = "revert_in_progress"
            }
            return .init(category: category, cause: cause)
        }
        if error is DecodingError {
            return .init(category: "validation", cause: "decoding_failed")
        }

        if let fileError = error as? FileSystemError {
            let cause: String
            switch fileError {
            case .fileNotFound: cause = "file_not_found"
            case .permissionDenied: cause = "access_denied"
            case .diskFull: cause = "disk_full"
            case .readOnlyFileSystem: cause = "read_only_filesystem"
            case .quotaExceeded: cause = "quota_exceeded"
            case .uniqueNameExhausted: cause = "unique_name_exhausted"
            case .partialFailure: cause = "partial_failure"
            case .partialApplyFailure: cause = "partial_apply_failure"
            case .preValidationFailed: cause = "prevalidation_failed"
            case .crossVolumeCopyVerificationFailed: cause = "copy_verification_failed"
            case .destinationEscapesBaseDirectory: cause = "destination_outside_base"
            }
            return .init(category: "filesystem", cause: cause)
        }

        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()

        if let catalogError = error as? ModelCatalogError {
            switch catalogError {
            case .invalidURL:
                return .init(category: "configuration", cause: "invalid_model_url")
            case .fetchFailed:
                return .init(category: "provider", cause: "model_list_failed")
            case .decodingFailed:
                return .init(category: "validation", cause: "invalid_model_list")
            case .privacyModeBlocked:
                return .init(category: "network", cause: "privacy_mode_blocked")
            }
        }

        if (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut)
            || description.contains("timed out")
            || description.contains("timeout")
        {
            return .init(category: "network", cause: "timeout")
        }
        if nsError.domain == NSURLErrorDomain {
            return .init(
                category: "network",
                cause: "connection_failed"
            )
        }
        if nsError.domain == NSPOSIXErrorDomain || nsError.domain == NSCocoaErrorDomain {
            if description.contains("permission")
                || description.contains("not permitted")
                || description.contains("access")
            {
                return .init(
                    category: "permission",
                    cause: "access_denied"
                )
            }
            return .init(
                category: "filesystem",
                cause: "file_operation_failed"
            )
        }
        if description.contains("api key")
            || description.contains("authentication")
            || description.contains("unauthorized")
        {
            return .init(
                category: "authentication",
                cause: "credentials_rejected"
            )
        }
        if description.contains("configuration") || description.contains("not configured") {
            return .init(
                category: "configuration",
                cause: "missing_or_invalid_configuration"
            )
        }
        if description.contains("validation")
            || description.contains("invalid response")
            || description.contains("decode")
        {
            return .init(
                category: "validation",
                cause: "invalid_data"
            )
        }

        return .init(
            category: "unknown",
            cause: "unclassified"
        )
    }

    /// Keep diagnostics numeric or allowlisted. Never serialize NSError userInfo,
    /// decoding contexts, provider bodies, or arbitrary error domains.
    static func errorDiagnostics(_ error: Error) -> [String: Any] {
        var diagnostics: [String: Any] = ["diagnostics_version": 2]
        var underlying = error
        if let aiError = error as? AIClientError {
            if case .apiError(let statusCode, let message) = aiError, (100...599).contains(statusCode) {
                diagnostics["http_status"] = statusCode
                // Only recognize fixed provider codes, never their message,
                // parameter value, request ID, or arbitrary JSON properties.
                if message.utf8.count <= 65_536,
                   let data = message.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let payload = object["error"] as? [String: Any] {
                    let allowedCodes: Set = [
                        "model_not_found", "unsupported_parameter", "unsupported_value",
                        "invalid_api_key", "insufficient_quota", "context_length_exceeded",
                        "invalid_request_error", "authentication_error", "rate_limit_error",
                        "overloaded_error", "NOT_FOUND", "INVALID_ARGUMENT", "RESOURCE_EXHAUSTED",
                    ]
                    let code = ["code", "type", "status"].compactMap { payload[$0] as? String }
                        .first { allowedCodes.contains($0) }
                    diagnostics["provider_error_code"] = code
                }
                if statusCode == 413 {
                    // Only fixed hints leave the device. A 413 can also be
                    // synthesized locally for model context/output limits.
                    let normalized = message.lowercased()
                    if normalized.contains("output limit") || normalized.contains("max_tokens") || normalized.contains("finish_reason: length") {
                        diagnostics["limit_hint"] = "output"
                    } else if normalized.contains("context") || normalized.contains("too many tokens") {
                        diagnostics["limit_hint"] = "context"
                    } else if normalized.contains("payload") || normalized.contains("request too large") || normalized.contains("request entity too large") {
                        diagnostics["limit_hint"] = "request_size"
                    } else {
                        diagnostics["limit_hint"] = "unknown"
                    }
                }
            }
            if case .jsonDecodingError(let context) = aiError {
                let knownFailures = [
                    "Invalid JSON response from AI": "invalid_json",
                    "Response missing required fields": "missing_required_fields",
                    "Referenced file not found in original list": "unknown_file_reference",
                    "Empty response from AI": "empty_response",
                ]
                if let failure = knownFailures[context] {
                    diagnostics["decoding_failure"] = failure
                } else if context.hasPrefix("HTTP 200 contained no completion text (") {
                    diagnostics["decoding_failure"] = "empty_completion"
                } else if context == "The provider returned a JSON value that was not a chat-completion object." {
                    diagnostics["decoding_failure"] = "invalid_envelope"
                } else if context == "The model stream ended before its completion event." {
                    diagnostics["decoding_failure"] = "incomplete_stream"
                } else {
                    diagnostics["decoding_failure"] = "unknown"
                }
            }
            if case .networkError(let wrapped) = aiError { underlying = wrapped }
        }
        let nsError = underlying as NSError
        if [NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain].contains(nsError.domain) {
            diagnostics["system_error_domain"] = nsError.domain
            diagnostics["system_error_code"] = nsError.code
        }
        if let decodingError = underlying as? DecodingError {
            switch decodingError {
            case .dataCorrupted: diagnostics["decoding_failure"] = "data_corrupted"
            case .keyNotFound: diagnostics["decoding_failure"] = "key_not_found"
            case .typeMismatch: diagnostics["decoding_failure"] = "type_mismatch"
            case .valueNotFound: diagnostics["decoding_failure"] = "value_not_found"
            @unknown default: diagnostics["decoding_failure"] = "unknown"
            }
        }
        return diagnostics
    }

    /// Sorty bugs, unknown failures, and unrecoverable errors are errors;
    /// provider, network, setup, and system failures are warnings.
    static func level(
        for classification: ReliabilityErrorClassification,
        recoverable: Bool
    ) -> SentryLevel {
        guard recoverable else { return .error }
        switch classification.fault {
        case .sorty, .unknown: return .error
        case .aiProvider, .aiOutput, .setup, .network, .system: return .warning
        }
    }

    /// Readable exception type and value for the Sentry issue title, built
    /// only from bounded identifiers, for example
    /// `SortyError: Organize › Generate plan — HTTP 413 (request too large)`.
    static func issueTitle(
        feature: String,
        operation: String,
        classification: ReliabilityErrorClassification
    ) -> (type: String, value: String) {
        let value = "\(humanized(feature)) › \(humanized(operation)) — \(causeLabel(classification.cause))"
        return (classification.fault.exceptionType, value)
    }

    static func causeLabel(_ cause: String) -> String {
        if cause.hasPrefix("http_"), let status = Int(cause.dropFirst(5)) {
            let reasons = [
                400: "bad request", 401: "unauthorized", 403: "forbidden",
                404: "not found", 408: "request timeout", 409: "conflict",
                413: "request too large", 422: "unprocessable request",
                429: "rate limited", 500: "server error", 502: "bad gateway",
                503: "service unavailable", 504: "gateway timeout", 529: "overloaded",
            ]
            return reasons[status].map { "HTTP \(status) (\($0))" } ?? "HTTP \(status)"
        }
        let labels = [
            "missing_api_url": "no API URL configured",
            "missing_api_key": "no API key configured",
            "invalid_api_url": "invalid API URL",
            "invalid_response": "invalid response",
            "invalid_response_format": "response in an unexpected format",
            "json_decoding_failed": "response was not valid JSON",
            "connection_failed": "connection failed",
            "timeout": "request timed out",
            "quota_exhausted": "quota exhausted",
            "invalid_http_status": "invalid HTTP status",
            "client_not_configured": "no AI provider configured",
            "missing_plan": "no current plan",
            "plan_directory_mismatch": "plan belongs to a different folder",
            "file_move_failed": "file move failed",
            "revert_in_progress": "undo already in progress",
            "decoding_failed": "stored data could not be decoded",
            "access_denied": "access denied",
            "read_only_filesystem": "read-only volume",
            "quota_exceeded": "disk quota exceeded",
            "unique_name_exhausted": "no unique file name available",
            "partial_failure": "some file operations failed",
            "partial_apply_failure": "some moves failed during apply",
            "prevalidation_failed": "pre-apply validation failed",
            "copy_verification_failed": "cross-volume copy verification failed",
            "destination_outside_base": "destination outside the chosen folder",
            "invalid_model_url": "invalid model list URL",
            "model_list_failed": "model list request failed",
            "invalid_model_list": "model list could not be read",
            "credentials_rejected": "credentials rejected",
            "missing_or_invalid_configuration": "missing or invalid configuration",
            "unclassified": "unclassified error",
        ]
        return labels[cause] ?? cause.replacingOccurrences(of: "_", with: " ")
    }

    /// `refresh_provider_openai` → `Refresh provider openai`.
    private static func humanized(_ identifier: String) -> String {
        let words = identifier.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
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

struct ReliabilityErrorClassification: Sendable {
    let category: String
    let cause: String

    var fault: ReliabilityFault {
        ReliabilityFault(category: category, cause: cause)
    }
}

/// Who most likely has to act on a handled error. Sent as the `fault` tag so
/// Sentry can separate Sorty bugs from provider outages and user setup.
enum ReliabilityFault: String, Sendable {
    /// Likely a Sorty defect: invalid requests, bad plans, failed moves.
    case sorty
    /// The AI service failed: outages, rate limits, exhausted quota.
    case aiProvider = "ai_provider"
    /// The model answered, but with unusable output such as invalid JSON.
    case aiOutput = "ai_output"
    /// The user's provider setup: missing keys, rejected credentials, bad URLs.
    case setup
    /// Connectivity: timeouts and unreachable hosts, including local servers.
    case network
    /// The Mac itself: permissions, full disks, missing files.
    case system
    case unknown

    init(category: String, cause: String) {
        switch category {
        case "configuration", "authentication":
            self = .setup
        case "network":
            self = .network
        case "permission":
            self = .system
        case "filesystem":
            let environmental: Set = [
                "file_not_found", "access_denied", "disk_full",
                "read_only_filesystem", "quota_exceeded",
            ]
            self = environmental.contains(cause) ? .system : .sorty
        case "provider":
            if let status = Int(cause.replacingOccurrences(of: "http_", with: "")),
               cause.hasPrefix("http_") {
                switch status {
                case 404: self = .setup
                case 408, 429, 500...599: self = .aiProvider
                default: self = .sorty
                }
            } else {
                self = .aiProvider
            }
        case "validation":
            switch cause {
            case "invalid_response", "invalid_response_format", "json_decoding_failed":
                self = .aiOutput
            case "invalid_model_list":
                self = .aiProvider
            default:
                self = .sorty
            }
        case "workflow", "cancellation":
            self = .sorty
        default:
            self = .unknown
        }
    }

    /// Exception type shown as the Sentry issue title prefix.
    var exceptionType: String {
        switch self {
        case .sorty: "SortyError"
        case .aiProvider: "AIProviderError"
        case .aiOutput: "AIResponseError"
        case .setup: "SetupError"
        case .network: "NetworkError"
        case .system: "SystemError"
        case .unknown: "UnclassifiedError"
        }
    }
}

/// Broad kind of every Sentry event, sent as the `event_kind` tag so the
/// issue stream can be split into crashes, hangs, handled errors, and reports.
enum ReliabilityEventKind: String, Sendable {
    case handledError = "handled_error"
    case crash
    case hang
    case watchdogTermination = "watchdog_termination"
    case diagnosticReport = "diagnostic_report"
    case userFeedback = "user_feedback"
    case other

    static let tagKey = "event_kind"

    /// Classifies events the SDK creates itself (crashes, hangs, watchdog
    /// terminations). Sorty's own captures set the tag explicitly.
    static func inferred(
        exceptionTypes: [String],
        isFatal: Bool,
        hasUnhandledException: Bool
    ) -> Self {
        let types = exceptionTypes.map { $0.lowercased() }
        if types.contains(where: { $0.contains("watchdogtermination") }) {
            return .watchdogTermination
        }
        if types.contains(where: { $0.contains("app hang") }) {
            return .hang
        }
        if isFatal || hasUnhandledException {
            return .crash
        }
        return .other
    }

    /// `beforeSend` hook: adds `event_kind` when a capture did not set it.
    static func tag(_ event: Event) -> Event {
        guard event.tags?[tagKey] == nil else { return event }
        let exceptions = event.exceptions ?? []
        let kind = inferred(
            exceptionTypes: exceptions.compactMap(\.type),
            isFatal: event.level == .fatal,
            hasUnhandledException: exceptions.contains { $0.mechanism?.handled?.boolValue == false }
        )
        var tags = event.tags ?? [:]
        tags[tagKey] = kind.rawValue
        event.tags = tags
        return event
    }
}
