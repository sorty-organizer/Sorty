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

public enum InternalTelemetry {
    public static let defaultsKey = "internalTelemetry"

    /// True for the team's own traffic: every debug build (`make now`/`make dev`),
    /// plus release builds opted in with `defaults write com.sorty.app internalTelemetry -bool true`.
    public static var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: defaultsKey)
        #endif
    }
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
    private var isStarting = false
    private var startupGeneration: UInt64 = 0
    private var captureRateLimiter = AnalyticsCaptureRateLimiter()
    private var pendingCaptures: [BufferedAnalyticsCapture] = []
    private var lastFeatureFlagReloadAt: TimeInterval?

    private static let productionProjectToken = "phc_rhKqvGRtWWMrSEC34WwUJipMZYM8kJA9ppav4ZxK7RiB"
    private static let productionHost = "https://us.i.posthog.com"
    private static let minimumFeatureFlagReloadInterval: TimeInterval = 300
    private static let maximumExperimentalFeatures = 20
    private static let maximumFeatureTitleLength = 80
    private static let maximumFeatureDescriptionLength = 280
    private static let maximumPendingCaptures = 25

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        consent = defaults.string(forKey: Self.consentDefaultsKey)
            .flatMap(AnalyticsConsent.init(rawValue:)) ?? .undecided
    }

    public func startIfAuthorized(launchDuration: TimeInterval? = nil) {
        guard consent == .granted,
              !NetworkPrivacyPolicy.isInternetPrivacyModeEnabled,
              !Self.isAnalyticsSuppressedForThisProcess,
              !isActive,
              !isStarting
        else {
            return
        }

        let configuration = Self.configuration()
        let projectToken = configuration.projectToken
        let host = configuration.host
        guard !projectToken.isEmpty else { return }

        // Keep consent gating on the main actor; hop PostHog setup off
        // launch. Preserve the launchDuration timestamp across the hop.
        isStarting = true
        startupGeneration &+= 1
        let generation = startupGeneration
        let capturedLaunchDuration = launchDuration

        Task.detached(priority: .utility) {
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
            await MainActor.run {
                AnalyticsManager.shared.finishStarting(
                    projectToken: projectToken,
                    launchDuration: capturedLaunchDuration,
                    generation: generation
                )
            }
        }
    }

    private func finishStarting(
        projectToken: String,
        launchDuration: TimeInterval?,
        generation: UInt64
    ) {
        guard generation == startupGeneration else {
            // Stop/consent changes can invalidate setup while it is running.
            // Do not start a second setup until this one has been closed.
            isStarting = false
            PostHogSDK.shared.close()
            Self.removePersistedSDKData(projectToken: projectToken)
            startIfAuthorized()
            return
        }
        isStarting = false
        guard !isActive,
              consent == .granted,
              !NetworkPrivacyPolicy.isInternetPrivacyModeEnabled,
              !Self.isAnalyticsSuppressedForThisProcess else {
            // An opt-out landed while setup was running; drop anything
            // buffered so no events leave after the user said no.
            pendingCaptures.removeAll()
            PostHogSDK.shared.close()
            Self.removePersistedSDKData(projectToken: projectToken)
            return
        }
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
            event: AnalyticsEventName.appOpened,
            properties: sessionProperties.merging(["event_category": "session"]) { current, _ in current }
        )
        flushPendingCaptures()
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
        defaults.removeObject(forKey: Self.lastActiveDayDefaultsKey)
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
        ReliabilityManager.shared.recordScreen(screen)
        var properties: [String: Any] = [
            "screen": screen,
            "source": source,
        ]
        properties["section"] = section
        properties["previous_screen"] = previousScreen
        // PostHog's native screen event, so screens show up by name in
        // Product Analytics and paths without custom breakdowns.
        properties["$screen_name"] = AnalyticsEventName.screenName(screen: screen, section: section)
        properties["event_category"] = "screen"
        capture(event: "$screen", properties: properties)
    }

    public func captureFeature(
        feature: String,
        subfeature: String,
        action: String,
        outcome: String,
        properties: [String: Any] = [:]
    ) {
        capture(
            event: AnalyticsEventName.feature(subfeature: subfeature, action: action, outcome: outcome),
            properties: properties.merging([
                "event_category": "feature",
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
        ReliabilityManager.shared.recordWorkflow(workflow: workflow, stage: stage, outcome: outcome)
        if workflow == "app" {
            ReliabilityManager.shared.recordAppLifecycle(
                stage: stage,
                outcome: outcome,
                reason: properties["failure_reason"] as? String,
                source: properties["source"] as? String
            )
        }
        capture(
            event: AnalyticsEventName.workflow(workflow: workflow, stage: stage, outcome: outcome),
            properties: properties.merging([
                "event_category": "workflow",
                "workflow": workflow,
                "stage": stage,
                "outcome": outcome,
            ]) { current, _ in current }
        )
    }

    /// Sends queued events and gives them a moment to upload. Use right
    /// before Sorty quits or deletes itself, when the on-disk queue would
    /// otherwise be lost or not retried until a next launch.
    public func flushBeforeExit() async {
        if canCapture {
            PostHogSDK.shared.flush()
        }
        // Sentry's flush blocks for up to 1.5s, which also covers PostHog's upload.
        await ReliabilityManager.shared.flushBeforeExit()
    }

    public func captureImportantButton(
        _ button: String,
        screen: String,
        feature: String
    ) {
        capture(
            event: AnalyticsEventName.buttonClicked(button),
            properties: [
                "event_category": "button",
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
        capture(
            event: AnalyticsEventName.settingChanged,
            properties: [
                "event_category": "feature",
                "feature": "settings",
                "subfeature": section,
                "action": "toggle_changed",
                "outcome": isEnabled ? "enabled" : "disabled",
                "control": control,
            ]
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

    private var canSend: Bool {
        consent == .granted
            && !NetworkPrivacyPolicy.isInternetPrivacyModeEnabled
            && !Self.isAnalyticsSuppressedForThisProcess
    }

    private var canCapture: Bool {
        isActive && canSend
    }

    private func capture(event: String, properties: [String: Any]) {
        // Consent gate first: buffering must never hold events the user did
        // not opt into. While the SDK is inactive (cold launch before setup
        // begins, or setup in flight) eligible events are buffered rather than
        // dropped, so the first screen view survives.
        guard canSend, captureRateLimiter.shouldCapture() else {
            return
        }

        guard !isActive else {
            send(event: event, properties: properties)
            return
        }

        pendingCaptures.append(
            BufferedAnalyticsCapture(event: event, properties: properties)
        )
        if pendingCaptures.count > Self.maximumPendingCaptures {
            pendingCaptures.removeFirst(
                pendingCaptures.count - Self.maximumPendingCaptures
            )
        }
    }

    private func flushPendingCaptures() {
        guard !pendingCaptures.isEmpty else { return }
        let captures = pendingCaptures
        pendingCaptures.removeAll()
        guard canCapture else { return }
        for bufferedCapture in captures {
            send(event: bufferedCapture.event, properties: bufferedCapture.properties)
        }
    }

    private func send(event: String, properties: [String: Any]) {
        sendDailyActiveIfNeeded()
        PostHogSDK.shared.capture(event, properties: commonProperties(properties))
    }

    /// Sends one `Daily Active` event per local calendar day, so DAU/WAU/MAU
    /// are "unique users of Daily Active" even when Sorty stays open past
    /// midnight without being relaunched.
    private func sendDailyActiveIfNeeded() {
        let today = Self.dayFormatter.string(from: Date())
        guard defaults.string(forKey: Self.lastActiveDayDefaultsKey) != today else { return }
        defaults.set(today, forKey: Self.lastActiveDayDefaultsKey)
        PostHogSDK.shared.capture(
            AnalyticsEventName.dailyActive,
            properties: commonProperties(["event_category": "session"])
        )
    }

    private func commonProperties(_ properties: [String: Any]) -> [String: Any] {
        var safeProperties = properties
        safeProperties["platform_surface"] = "mac_app"
        safeProperties["is_internal"] = InternalTelemetry.isEnabled
        // Country comes from the Mac's Region setting, never from the IP
        // address, so PostHog GeoIP (city, coordinates) stays disabled.
        safeProperties["country_code"] = Self.countryCode()
        safeProperties["$geoip_disable"] = true
        return safeProperties
    }

    nonisolated static func countryCode(locale: Locale = .current) -> String {
        guard let region = locale.region?.identifier,
              region.count == 2,
              region.allSatisfy({ $0.isASCII && $0.isLetter })
        else {
            return "unknown"
        }
        return region.uppercased()
    }

    private static let lastActiveDayDefaultsKey = "analyticsLastActiveDay"

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func stopAndClear() {
        experimentalFeatures = []
        isLoadingExperimentalFeatures = false
        // Consent denial and privacy mode both land here; never flush events
        // that were buffered before the user opted out.
        pendingCaptures.removeAll()
        startupGeneration &+= 1
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
        // Event names are generated by `AnalyticsEventName` from bounded
        // identifiers; anything else (SDK autocapture, stray events) is dropped.
        let allowedCategories: Set<String> = ["session", "screen", "feature", "workflow", "button"]
        guard let category = event.properties["event_category"] as? String,
              allowedCategories.contains(category),
              event.event == "$screen" || AnalyticsEventName.isValid(event.event)
        else {
            return nil
        }

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
            "$screen_name",
            "$session_id",
            "action",
            "ai_duration_ms",
            "button",
            "control",
            "count_bucket",
            "country_code",
            "duration_bucket",
            "duration_ms",
            "entry_source",
            "failure_reason",
            "event_category",
            "feature",
            "has_custom_instructions",
            "is_internal",
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

/// Human-readable PostHog event names built from the bounded snake_case
/// identifiers call sites already pass, e.g. `organize` + `plan_ready` becomes
/// `Organize Plan Ready`. The raw identifiers stay on the event as properties.
enum AnalyticsEventName {
    static let appOpened = "App Opened"
    static let dailyActive = "Daily Active"
    static let settingChanged = "Setting Changed"

    private static let notableOutcomes: Set<String> = ["failed", "cancelled", "empty", "unavailable"]

    static func workflow(workflow: String, stage: String, outcome: String) -> String {
        withOutcome(titled(workflow) + " " + titled(stage), outcome: outcome)
    }

    static func feature(subfeature: String, action: String, outcome: String) -> String {
        let subject = titled(subfeature)
        // Drop action words that repeat the subject ("Custom Personas" +
        // "persona_selected" reads as "Custom Personas Selected").
        let singular: (Substring) -> Substring = { $0.hasSuffix("s") ? $0.dropLast() : $0 }
        let subjectWords = Set(subject.split(separator: " ").map(singular))
        let verb = titled(action)
            .split(separator: " ")
            .filter { !subjectWords.contains(singular($0)) }
            .joined(separator: " ")
        return withOutcome(verb.isEmpty ? subject : "\(subject) \(verb)", outcome: outcome)
    }

    static func buttonClicked(_ button: String) -> String {
        titled(button) + " Clicked"
    }

    static func screenName(screen: String, section: String?) -> String {
        guard let section, !section.isEmpty, section != screen else { return titled(screen) }
        // Settings screens repeat their section ("settings_ai_provider" +
        // "ai_provider"); show that as "Settings › AI Provider".
        let parent = screen.hasSuffix("_" + section) ? String(screen.dropLast(section.count + 1)) : screen
        return titled(parent) + " › " + titled(section)
    }

    static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 80 && name.allSatisfy {
            ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == " "
        }
    }

    private static func withOutcome(_ name: String, outcome: String) -> String {
        let suffix = titled(outcome)
        guard notableOutcomes.contains(outcome), !name.hasSuffix(suffix) else { return name }
        return name + " " + suffix
    }

    private static func titled(_ identifier: String) -> String {
        identifier
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            .map { $0.lowercased() == "ai" ? "AI" : $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}

private struct BufferedAnalyticsCapture {
    let event: String
    let properties: [String: Any]
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
