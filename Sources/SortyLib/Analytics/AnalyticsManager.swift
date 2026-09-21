//
//  AnalyticsManager.swift
//  Sorty
//
//  Consent-gated, privacy-preserving product analytics.
//

import Combine
import Foundation
import PostHog

public enum AnalyticsConsent: String, Sendable {
    case undecided
    case granted
    case denied
}

public struct ExperimentalFeature: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let systemImage: String
    public let variant: String?
}

@MainActor
public final class AnalyticsManager: ObservableObject {
    public static let shared = AnalyticsManager()

    public static let consentDefaultsKey = "analyticsConsent"
    @Published public private(set) var consent: AnalyticsConsent
    @Published public private(set) var isActive = false
    @Published public private(set) var experimentalFeatures: [ExperimentalFeature] = []
    @Published public private(set) var isLoadingExperimentalFeatures = false

    private let defaults: UserDefaults
    private var activeProjectToken: String?
    private var captureRateLimiter = AnalyticsCaptureRateLimiter()
    private var lastFeatureFlagReloadAt: TimeInterval?

    private static let productionProjectToken = "phc_rhKqvGRtWWMrSEC34WwUJipMZYM8kJA9ppav4ZxK7RiB"
    private static let productionHost = "https://us.i.posthog.com"
    private static let minimumFeatureFlagReloadInterval: TimeInterval = 300
    private static let maximumExperimentalFeatures = 20
    private static let maximumFeatureTitleLength = 80
    private static let maximumFeatureDescriptionLength = 280

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        consent = defaults.string(forKey: Self.consentDefaultsKey)
            .flatMap(AnalyticsConsent.init(rawValue:)) ?? .undecided
    }

    public func startIfAuthorized(launchDuration: TimeInterval? = nil) {
        guard consent == .granted,
              !NetworkPrivacyPolicy.isInternetPrivacyModeEnabled,
              !Self.isAnalyticsSuppressedForThisProcess,
              !isActive
        else {
            return
        }

        let configuration = Self.configuration()
        let projectToken = configuration.projectToken
        let host = configuration.host
        guard !projectToken.isEmpty else { return }

        let config = PostHogConfig(projectToken: projectToken, host: host)
        config.personProfiles = .never
        config.setDefaultPersonProperties = false
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.flushAt = 20
        config.maxQueueSize = 250
        config.setBeforeSend { event in
            Self.sanitized(event: event)
        }

        PostHogSDK.shared.setup(config)
        activeProjectToken = projectToken
        isActive = true
        var sessionProperties: [String: Any] = [
            "platform_surface": "mac_app",
            "launch_source": "standard",
        ]
        if let launchDuration {
            sessionProperties.merge(Self.durationProperties(launchDuration)) { current, _ in current }
            sessionProperties["stage"] = "main_window_appeared"
        }
        capture(
            event: "app:session_started",
            properties: sessionProperties
        )
    }

    public func setConsent(_ newConsent: AnalyticsConsent) {
        guard newConsent != .undecided else { return }

        defaults.set(newConsent.rawValue, forKey: Self.consentDefaultsKey)
        consent = newConsent

        switch newConsent {
        case .granted:
            ReliabilityManager.shared.consentDidChange(newConsent)
            startIfAuthorized()
            captureFeature(
                feature: "privacy",
                subfeature: "analytics",
                action: "enabled",
                outcome: "success"
            )
        case .denied:
            ReliabilityManager.shared.consentDidChange(newConsent)
            stopAndClear()
        case .undecided:
            break
        }
    }

    public func networkPrivacyDidChange(isEnabled: Bool) {
        ReliabilityManager.shared.networkPrivacyDidChange(isEnabled: isEnabled)
        if isEnabled {
            stopAndClear()
        } else {
            startIfAuthorized()
        }
    }

    public func resetConsentAndData() {
        ReliabilityManager.shared.stopAndClear()
        stopAndClear()
        defaults.removeObject(forKey: Self.consentDefaultsKey)
        consent = .undecided
    }

    public func reloadExperimentalFeatures() {
        guard canCapture else {
            experimentalFeatures = []
            isLoadingExperimentalFeatures = false
            return
        }
        guard !isLoadingExperimentalFeatures else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if let lastFeatureFlagReloadAt,
           now - lastFeatureFlagReloadAt < Self.minimumFeatureFlagReloadInterval
        {
            updateExperimentalFeatures()
            return
        }

        isLoadingExperimentalFeatures = true
        lastFeatureFlagReloadAt = now
        PostHogSDK.shared.reloadFeatureFlags(Self.didReloadExperimentalFeatures)
    }

    public func captureScreen(
        _ screen: String,
        section: String? = nil,
        source: String = "navigation",
        previousScreen: String? = nil
    ) {
        var properties: [String: Any] = [
            "screen": screen,
            "source": source,
        ]
        properties["section"] = section
        properties["previous_screen"] = previousScreen
        capture(event: "app:screen_viewed", properties: properties)
    }

    public func captureFeature(
        feature: String,
        subfeature: String,
        action: String,
        outcome: String,
        properties: [String: Any] = [:]
    ) {
        capture(
            event: "app:feature_used",
            properties: properties.merging([
                "feature": feature,
                "subfeature": subfeature,
                "action": action,
                "outcome": outcome,
            ]) { current, _ in current }
        )
    }

    public func captureWorkflow(
        workflow: String,
        stage: String,
        outcome: String,
        properties: [String: Any] = [:]
    ) {
        capture(
            event: "app:workflow_progressed",
            properties: properties.merging([
                "workflow": workflow,
                "stage": stage,
                "outcome": outcome,
            ]) { current, _ in current }
        )
    }

    public func captureImportantButton(
        _ button: String,
        screen: String,
        feature: String
    ) {
        capture(
            event: "app:important_button_clicked",
            properties: [
                "button": button,
                "screen": screen,
                "feature": feature,
            ]
        )
    }

    public func captureSettingChanged(
        _ control: String,
        isEnabled: Bool,
        section: String = "settings"
    ) {
        captureFeature(
            feature: "settings",
            subfeature: section,
            action: "toggle_changed",
            outcome: isEnabled ? "enabled" : "disabled",
            properties: ["control": control]
        )
    }

    public func capturePersonaInventory(
        action: String,
        customPersonaCount: Int,
        selectionKind: String? = nil
    ) {
        var properties: [String: Any] = [
            "count_bucket": Self.countBucket(customPersonaCount),
        ]
        properties["selection_kind"] = selectionKind
        captureFeature(
            feature: "personas",
            subfeature: "custom_personas",
            action: action,
            outcome: "success",
            properties: properties
        )
    }

    public static func countBucket(_ count: Int) -> String {
        switch count {
        case ..<1: return "0"
        case 1: return "1"
        case 2...5: return "2_5"
        case 6...20: return "6_20"
        case 21...100: return "21_100"
        default: return "101_plus"
        }
    }

    public static func durationBucket(_ duration: TimeInterval) -> String {
        switch duration {
        case ..<1: return "under_1s"
        case ..<5: return "1_5s"
        case ..<15: return "5_15s"
        case ..<60: return "15_60s"
        case ..<300: return "1_5m"
        default: return "5m_plus"
        }
    }

    public static func durationProperties(_ duration: TimeInterval) -> [String: Any] {
        let clampedDuration = max(0, duration)
        return [
            "duration_bucket": durationBucket(clampedDuration),
            "duration_ms": Int((clampedDuration * 1_000).rounded()),
        ]
    }

    public static func generationDurationProperties(
        _ stats: GenerationStats?
    ) -> [String: Any] {
        guard let stats else { return [:] }

        var properties: [String: Any] = [
            "ai_duration_ms": roundedMilliseconds(stats.duration),
            "time_to_first_token_ms": roundedMilliseconds(stats.ttft),
        ]
        if let scanDuration = stats.scanDuration {
            properties["scan_duration_ms"] = roundedMilliseconds(scanDuration)
        }
        return properties
    }

    private static func roundedMilliseconds(_ duration: TimeInterval) -> Int {
        Int((max(0, duration) * 1_000).rounded())
    }

    private var canCapture: Bool {
        isActive
            && consent == .granted
            && !NetworkPrivacyPolicy.isInternetPrivacyModeEnabled
            && !Self.isAnalyticsSuppressedForThisProcess
    }

    private func capture(event: String, properties: [String: Any]) {
        guard canCapture, captureRateLimiter.shouldCapture() else { return }
        var safeProperties = properties
        safeProperties["platform_surface"] = "mac_app"
        safeProperties["$geoip_disable"] = true
        PostHogSDK.shared.capture(event, properties: safeProperties)
    }

    private func stopAndClear() {
        experimentalFeatures = []
        isLoadingExperimentalFeatures = false
        let projectToken = activeProjectToken
            ?? Self.productionProjectToken

        if isActive {
            isActive = false
            PostHogSDK.shared.close()
        }

        Self.removePersistedSDKData(projectToken: projectToken)
        activeProjectToken = nil
    }

    private static func configuration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (projectToken: String, host: String) {
        #if DEBUG
        let projectToken = environment["SORTY_POSTHOG_PROJECT_TOKEN"] ?? productionProjectToken
        let requestedHost = environment["SORTY_POSTHOG_HOST"] ?? productionHost
        let host = validatedDebugHost(requestedHost) ?? productionHost
        return (projectToken, host)
        #else
        // Release builds never trust launch-environment overrides. Allowing an
        // arbitrary host would let another local process redirect opted-in
        // analytics to a collector outside Sorty's PostHog project.
        return (productionProjectToken, productionHost)
        #endif
    }

    private static func validatedDebugHost(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              components.scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            return nil
        }
        return value
    }

    private func updateExperimentalFeatures() {
        guard canCapture else {
            experimentalFeatures = []
            isLoadingExperimentalFeatures = false
            return
        }

        experimentalFeatures = (PostHogSDK.shared.getAllFeatureFlags() ?? [])
            .compactMap(Self.experimentalFeature)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .prefix(Self.maximumExperimentalFeatures)
            .map { $0 }
        isLoadingExperimentalFeatures = false
    }

    private nonisolated static func didReloadExperimentalFeatures() {
        Task { @MainActor in
            shared.updateExperimentalFeatures()
        }
    }

    private static func experimentalFeature(
        from result: PostHogFeatureFlagResult
    ) -> ExperimentalFeature? {
        let prefix = "labs-"
        guard let boundedKey = boundedIdentifier(result.key),
              result.enabled,
              result.key.hasPrefix(prefix),
              result.key.count <= 64,
              boundedKey == result.key
        else {
            return nil
        }

        let payload = result.payload as? [String: Any]
        let fallbackName = result.key
            .dropFirst(prefix.count)
            .replacingOccurrences(of: "-", with: " ")
            .capitalized

        return ExperimentalFeature(
            id: boundedKey,
            title: boundedString(
                payload?["title"],
                maximumLength: maximumFeatureTitleLength
            ) ?? String(fallbackName.prefix(maximumFeatureTitleLength)),
            description: boundedString(
                payload?["description"],
                maximumLength: maximumFeatureDescriptionLength
            )
                ?? "This experiment is available for your installation.",
            systemImage: boundedIdentifier(payload?["system_image"]) ?? "flask",
            variant: result.variant.map { String($0.prefix(64)) }
        )
    }

    private static func boundedString(
        _ value: Any?,
        maximumLength: Int
    ) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maximumLength))
    }

    private static func boundedIdentifier(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.lowercased().replacingOccurrences(
            of: #"[^a-z0-9.-]+"#,
            with: "",
            options: .regularExpression
        )
        return normalized.isEmpty ? nil : String(normalized.prefix(64))
    }

    private nonisolated static func removePersistedSDKData(projectToken: String) {
        let isSafePathComponent = !projectToken.isEmpty && projectToken.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
        }
        guard isSafePathComponent,
              let applicationSupport = FileManager.default.urls(
                  for: .applicationSupportDirectory,
                  in: .userDomainMask
              ).first
        else {
            return
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.sorty.app"
        let sdkDirectory = applicationSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(projectToken, isDirectory: true)
        try? FileManager.default.removeItem(at: sdkDirectory)
    }

    private nonisolated static var isAnalyticsSuppressedForThisProcess: Bool {
        let process = ProcessInfo.processInfo
        return process.environment["XCTestConfigurationFilePath"] != nil
            || process.arguments.contains("--uitesting")
            || process.environment["SORTY_HARNESS_MODE"] == "1"
    }

    private nonisolated static func sanitized(event: PostHogEvent) -> PostHogEvent? {
        let allowedEvents: Set<String> = [
            "app:session_started",
            "app:screen_viewed",
            "app:feature_used",
            "app:workflow_progressed",
            "app:important_button_clicked",
        ]
        guard allowedEvents.contains(event.event) else { return nil }

        let allowedProperties: Set<String> = [
            "$app_build",
            "$app_version",
            "$device_type",
            "$geoip_disable",
            "$lib",
            "$lib_version",
            "$os_name",
            "$os_version",
            "$process_person_profile",
            "$session_id",
            "action",
            "ai_duration_ms",
            "button",
            "control",
            "count_bucket",
            "duration_bucket",
            "duration_ms",
            "entry_source",
            "feature",
            "has_custom_instructions",
            "launch_source",
            "mode",
            "operation",
            "outcome",
            "platform_surface",
            "previous_screen",
            "result_kind",
            "screen",
            "scan_duration_ms",
            "section",
            "selection_kind",
            "semantic_enabled",
            "source",
            "stage",
            "subfeature",
            "time_to_first_token_ms",
            "variant",
            "workflow",
        ]

        let originalProperties = event.properties
        var safeProperties = originalProperties.reduce(into: [String: Any]()) { result, pair in
            guard allowedProperties.contains(pair.key) else {
                return
            }
            result[pair.key] = sanitized(value: pair.value)
        }

        safeProperties["$geoip_disable"] = true
        safeProperties["platform_surface"] = "mac_app"
        event.properties = safeProperties
        return event
    }

    private nonisolated static func sanitized(value: Any) -> Any {
        if let string = value as? String {
            return sanitized(string: string)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(sanitized(value:))
        }
        if let array = value as? [Any] {
            return array.map(sanitized(value:))
        }
        return value
    }

    private nonisolated static func sanitized(string: String) -> String {
        var result = String(string.prefix(500))
        result = result.replacingOccurrences(
            of: #"file://[^\s]+"#,
            with: "file://[redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"/Users/[^/\s]+(?:/[^\s]*)?"#,
            with: "/Users/[redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?<![A-Za-z0-9:])/(?:[^\s/]+/)*[^\s/]+"#,
            with: "/[redacted-path]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            with: "[redacted-email]",
            options: [.regularExpression, .caseInsensitive]
        )
        return result
    }

}

struct AnalyticsCaptureRateLimiter {
    private let maximumEventsPerMinute: Int
    private let maximumEventsPerProcess: Int

    private var windowStartedAt: TimeInterval = 0
    private var windowCount = 0
    private var processCount = 0

    init(
        maximumEventsPerMinute: Int = 120,
        maximumEventsPerProcess: Int = 10_000
    ) {
        self.maximumEventsPerMinute = maximumEventsPerMinute
        self.maximumEventsPerProcess = maximumEventsPerProcess
    }

    mutating func shouldCapture(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard processCount < maximumEventsPerProcess else { return false }

        if windowStartedAt == 0 || now - windowStartedAt >= 60 {
            windowStartedAt = now
            windowCount = 0
        }
        guard windowCount < maximumEventsPerMinute else { return false }

        windowCount += 1
        processCount += 1
        return true
    }

    mutating func reset() {
        windowStartedAt = 0
        windowCount = 0
        processCount = 0
    }
}
