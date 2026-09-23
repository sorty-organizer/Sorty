//
//  AISessionManager.swift
//  Sorty
//
//  Manages URLSession pooling and connection prewarming for AI clients.
//  Reduces latency by reusing connections and prewarming before organization.
//

import Foundation
import Combine

/// Manages shared URLSession instances for AI providers
@MainActor
public class AISessionManager: ObservableObject {
    // MARK: - Session storage (non-MainActor)

    /// Pooled sessions live off the MainActor in a lock-protected store so
    /// `session(for:)` never blocks publishes. Only @Published prewarm state
    /// stays on the MainActor. NSLock stays: synchronous sync-context callers
    /// (settings didSet) require sync access, which an actor cannot provide.
    private final class AISessionStore: @unchecked Sendable {
        private struct Signature: Equatable {
            let requestTimeout: TimeInterval
            let resourceTimeout: TimeInterval
            let apiURL: String?
        }

        private let lock = NSLock()
        private var sessions: [AIProvider: URLSession] = [:]
        private var signatures: [AIProvider: Signature] = [:]
        private var lastUsed: [AIProvider: Date] = [:]

        func pooledSession(
            for provider: AIProvider,
            requestTimeout: TimeInterval,
            resourceTimeout: TimeInterval,
            apiURL: String?
        ) -> URLSession {
            let signature = Signature(
                requestTimeout: requestTimeout,
                resourceTimeout: resourceTimeout,
                apiURL: apiURL
            )
            lock.lock()
            lastUsed[provider] = Date()
            if let existing = sessions[provider], signatures[provider] == signature {
                lock.unlock()
                return existing
            }
            let retired = sessions.removeValue(forKey: provider)
            signatures.removeValue(forKey: provider)
            lock.unlock()
            if let retired {
                AISessionManager.retireDetached(retired)
            }

            let sessionConfig = Self.makeConfiguration(
                requestTimeout: requestTimeout,
                resourceTimeout: resourceTimeout,
                provider: provider,
                apiURL: apiURL
            )
            let session = NetworkPrivacyPolicy.makeSession(configuration: sessionConfig)
            lock.lock()
            // A concurrent caller may have populated while we built; keep the
            // newest and retire ours instead of leaking either.
            if sessions[provider] == nil {
                sessions[provider] = session
                signatures[provider] = signature
                lock.unlock()
                return session
            }
            let winner = sessions[provider]
            lock.unlock()
            AISessionManager.retireDetached(session)
            return winner!
        }

        func removeSession(for provider: AIProvider) -> URLSession? {
            lock.lock()
            defer { lock.unlock() }
            signatures.removeValue(forKey: provider)
            lastUsed.removeValue(forKey: provider)
            return sessions.removeValue(forKey: provider)
        }

        func removeAllSessions() -> [URLSession] {
            lock.lock()
            defer { lock.unlock() }
            let retired = Array(sessions.values)
            sessions.removeAll()
            signatures.removeAll()
            lastUsed.removeAll()
            return retired
        }

        func nextExpiry(timeout: TimeInterval) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return lastUsed.values.min()?.addingTimeInterval(timeout)
        }

        func staleProviders(timeout: TimeInterval, now: Date = Date()) -> [AIProvider] {
            lock.lock()
            defer { lock.unlock() }
            return lastUsed.compactMap { provider, lastAccess in
                now.timeIntervalSince(lastAccess) >= timeout ? provider : nil
            }
        }

        private static func makeConfiguration(
            requestTimeout: TimeInterval,
            resourceTimeout: TimeInterval,
            provider: AIProvider,
            apiURL: String?
        ) -> URLSessionConfiguration {
            let config = URLSessionConfiguration.default

            // Enable HTTP/2 for better performance
            config.httpAdditionalHeaders = [
                "Accept-Encoding": "gzip, deflate",
                "Connection": "keep-alive"
            ]

            // Use user's configured timeout values from AIConfig
            // requestTimeout: time to establish connection and receive response headers
            // resourceTimeout: total time allowed for streaming/large responses
            config.timeoutIntervalForRequest = requestTimeout
            config.timeoutIntervalForResource = resourceTimeout

            // Enable connection reuse - critical for performance
            let rawURL = (apiURL?.isEmpty ?? true) ? provider.defaultAPIURL : apiURL
            let host = rawURL.flatMap { URL(string: $0.contains("://") ? $0 : "https://" + $0)?.host?.lowercased() }
            let isLocalhost = host == "localhost" || host == "::1" || host?.hasPrefix("127.") == true
            config.httpMaximumConnectionsPerHost = isLocalhost ? 6 : 3
            config.urlCache = nil  // No caching for AI requests
            config.requestCachePolicy = .reloadIgnoringLocalCacheData

            // Enable TLS 1.2+ for security and performance
            config.tlsMinimumSupportedProtocolVersion = .TLSv12
            config.tlsMaximumSupportedProtocolVersion = .TLSv13

            // TCP connection optimization
            config.waitsForConnectivity = true
            config.shouldUseExtendedBackgroundIdleMode = false
            config.sessionSendsLaunchEvents = false

            return config
        }
    }

    private let store = AISessionStore()
    
    // MARK: - Singleton
    
    public static let shared = AISessionManager()
    
    // MARK: - Properties

    /// Single-flight prewarm tasks per provider so rapid folder selection
    /// cannot fan out duplicate connection storms.
    private var prewarmTasks: [AIProvider: Task<Void, Never>] = [:]
    /// Last prewarm verdict per provider; fresh verdicts (<5m) skip network I/O.
    private var prewarmVerdicts: [AIProvider: (at: Date, success: Bool, error: String?)] = [:]
    private static let prewarmTTL: TimeInterval = 5 * 60

    /// Prewarming status
    @Published public private(set) var prewarmingProviders: Set<AIProvider> = []
    @Published public private(set) var isPrewarmed: Bool = false
    @Published public private(set) var prewarmError: String?

    /// Prewarm generations per provider. Bumped whenever credentials change so
    /// a prewarm that started with the previous config cannot overwrite fresh
    /// state when it finishes late.
    private var prewarmGenerations: [AIProvider: Int] = [:]

    /// Clear current prewarm errors
    public func clearErrors() {
        prewarmError = nil
    }

    /// Drops any prewarm verdict tied to previous credentials. Call
    /// synchronously when the provider, API key, API URL, or auth method
    /// changes so the ready-to-organize screen never shows an error produced
    /// with the old config. In-flight prewarms keep running but their results
    /// are discarded by the generation guard in `prewarm(provider:config:)`;
    /// the caller re-verifies with the new config through the normal delayed
    /// connection task.
    public func resetPrewarmState(for provider: AIProvider) {
        prewarmGenerations[provider, default: 0] += 1
        prewarmTasks[provider]?.cancel()
        prewarmTasks[provider] = nil
        prewarmVerdicts[provider] = nil
        ProviderAuthResolver.invalidateCredentialCache(for: provider)
        prewarmError = nil
        isPrewarmed = false
    }

    #if DEBUG
    /// Test hook: seeds a prewarm verdict without performing network I/O.
    public func setPrewarmStateForTesting(isPrewarmed: Bool, error: String?) {
        self.isPrewarmed = isPrewarmed
        self.prewarmError = error
    }
    #endif

    public var prewarmingProvider: AIProvider? {
        prewarmingProviders.first
    }
    
    /// Session timeout for cleanup (10 minutes of inactivity)
    private let sessionTimeout: TimeInterval = 10 * 60
    
    /// Cleanup task
    private var cleanupTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Session Management
    
    /// Get or create a URLSession for a provider. Storage lives in the
    /// non-MainActor store; only logging happens here on the MainActor.
    public func session(for provider: AIProvider, config: AIConfig) -> URLSession {
        let session = store.pooledSession(
            for: provider,
            requestTimeout: config.requestTimeout,
            resourceTimeout: config.effectiveOrganizeResourceTimeout,
            apiURL: config.apiURL
        )
        scheduleCleanup()
        return session
    }
    
    /// Prewarm connection for a provider (call when user selects folder).
    /// Single-flight with a <5m TTL: concurrent callers join the in-flight
    /// task and fresh verdicts skip network I/O entirely. This is also the
    /// merged connection-check entry point — callers should use `prewarm`
    /// instead of a separate testConnection call.
    public func prewarm(provider: AIProvider, config: AIConfig) async {
        if let verdict = prewarmVerdicts[provider],
           Date().timeIntervalSince(verdict.at) < Self.prewarmTTL {
            isPrewarmed = verdict.success
            prewarmError = verdict.error
            return
        }
        if let inFlight = prewarmTasks[provider] {
            await inFlight.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runPrewarm(provider: provider, config: config)
        }
        prewarmTasks[provider] = task
        await task.value
        prewarmTasks[provider] = nil
    }

    /// Merged connection check: identical to `prewarm`, kept as the single
    /// named entry point so call sites do not fan out testConnection + prewarm.
    public func verifyConnection(provider: AIProvider, config: AIConfig) async {
        await prewarm(provider: provider, config: config)
    }

    private func runPrewarm(provider: AIProvider, config: AIConfig) async {
        guard !prewarmingProviders.contains(provider) else { return }

        prewarmingProviders.insert(provider)
        prewarmError = nil
        isPrewarmed = false
        let generation = prewarmGenerations[provider, default: 0]

        defer {
            prewarmingProviders.remove(provider)
        }

        if provider == .openAI,
           ProviderAuthResolver.effectiveAuthMethod(for: .openAI, config: config) == .accountSignIn {
            let codexPrewarmError = await Task.detached(priority: .userInitiated) {
                do {
                    try await CodexSubscriptionClient(config: config).checkHealth()
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value

            // Credentials may have changed while the detached health check ran;
            // a stale verdict must not overwrite the reset state.
            guard generation == prewarmGenerations[provider, default: 0] else { return }
            if let codexPrewarmError {
                isPrewarmed = false
                prewarmError = codexPrewarmError
            } else {
                isPrewarmed = true
                prewarmError = nil
            }
            prewarmVerdicts[provider] = (at: Date(), success: isPrewarmed, error: prewarmError)
            return
        }

        // Skip prewarming for local/on-device providers
        switch provider {
        case .ollama, .appleFoundationModel:
            isPrewarmed = true
            prewarmVerdicts[provider] = (at: Date(), success: true, error: nil)
            return
        default:
            break
        }

        let session = session(for: provider, config: config)

        // Try the models endpoint first, then fallback to base URL if it fails
        // This handles custom setups (Azure, proxies, enterprise gateways) where
        // the standard /v1/models path may not exist
        let prewarmURLs = getPrewarmURLs(for: provider, config: config)
        let allowedPrewarmURLs = prewarmURLs.filter { NetworkPrivacyPolicy.isRequestAllowed(url: $0) }

        guard !allowedPrewarmURLs.isEmpty else {
            if NetworkPrivacyPolicy.isInternetPrivacyModeEnabled {
                prewarmError = NetworkPrivacyPolicy.blockedMessage
            } else {
                prewarmError = "Invalid API URL"
            }
            return
        }

        // Try each URL in order (specific endpoint first, then root)
        for (index, url) in allowedPrewarmURLs.enumerated() {
            if Task.isCancelled { return }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 5
            // Prewarm/catalog/health must never wake constrained or expensive
            // radios: fail fast on Low Data Mode / cellular instead.
            request.allowsConstrainedNetworkAccess = false
            request.allowsExpensiveNetworkAccess = false

            addAuthHeaders(to: &request, provider: provider, config: config)

            do {
                let (_, response) = try await session.data(for: request)

                if let httpResponse = response as? HTTPURLResponse {
                    // Any response (including 404) means connection is established
                    // 404 on models endpoint is OK for custom/proxy setups
                    let isSuccess = (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 404

                    if isSuccess {
                        LogManager.shared.log("Prewarmed \(provider.displayName): HTTP \(httpResponse.statusCode)", level: .debug, category: "AISessionManager")
                        // The config may have been fixed while the request was in
                        // flight; only a verdict for the current generation applies.
                        guard generation == prewarmGenerations[provider, default: 0] else { return }
                        isPrewarmed = true
                        prewarmError = nil
                        prewarmVerdicts[provider] = (at: Date(), success: true, error: nil)
                        return
                    } else {
                        // Non-success status, try next URL
                        LogManager.shared.log("Prewarm attempt \(index + 1) for \(provider.displayName): HTTP \(httpResponse.statusCode)", level: .debug, category: "AISessionManager")
                    }
                }
            } catch {
                if (error as? URLError)?.code == .cancelled { return }
                // This URL failed, try the next one
                LogManager.shared.log("Prewarm attempt \(index + 1) failed for \(provider.displayName): \(error.localizedDescription)", level: .debug, category: "AISessionManager")
                continue
            }
        }

        // All URLs failed
        guard generation == prewarmGenerations[provider, default: 0] else { return }
        prewarmError = "Could not establish connection to \(provider.displayName)"
        isPrewarmed = false
        prewarmVerdicts[provider] = (at: Date(), success: false, error: prewarmError)

    }
    
    /// Get the appropriate URLs for prewarming (models endpoint and fallback to base URL)
    /// Returns array of URLs to try in order - specific endpoint first, then root URL
    private func getPrewarmURLs(for provider: AIProvider, config: AIConfig) -> [URL] {
        let rawURLString = (config.apiURL?.isEmpty ?? true) ? provider.defaultAPIURL : config.apiURL

        guard var urlString = rawURLString?.trimmingCharacters(in: .whitespacesAndNewlines), !urlString.isEmpty else { return [] }
        
        // Ensure scheme is present
        if !urlString.contains("://") {
            urlString = "https://" + urlString
        }

        var urls: [URL] = []

        let modelsPathSuffix: String
        switch provider {
        case .openRouter:
            modelsPathSuffix = "api/v1/models"
        case .githubCopilot:
            modelsPathSuffix = "models"
        case .ollama:
            modelsPathSuffix = "api/tags"
        case .appleFoundationModel:
            return [] // No prewarming needed
        case .openAI, .groq, .anthropic, .gemini, .openAICompatible:
            modelsPathSuffix = "v1/models"
        }

        // First try the specific models endpoint
        let modelsURLString = urlString.hasSuffix("/") ? urlString + modelsPathSuffix : urlString + "/" + modelsPathSuffix

        if let modelsURL = URL(string: modelsURLString), modelsURL.scheme != nil {
            urls.append(modelsURL)
        }

        // Add base URL as fallback for custom setups (Azure, proxies, enterprise gateways)
        // where the models endpoint might not exist but the base connection works
        if let baseURL = URL(string: urlString), baseURL.scheme != nil {
            // Only add if different from models URL
            if urls.isEmpty || baseURL.absoluteString != modelsURLString {
                urls.append(baseURL)
            }
        }

        return urls
    }
    
    /// Invalidate session for a provider (e.g., after auth failure)
    public func invalidate(provider: AIProvider) {
        if let retired = store.removeSession(for: provider) {
            Self.retireDetached(retired)
            LogManager.shared.log("Removed session for \(provider.displayName)", category: "AISessionManager")
        }

        prewarmTasks[provider]?.cancel()
        prewarmTasks[provider] = nil
        prewarmVerdicts[provider] = nil
        prewarmingProviders.remove(provider)
        scheduleCleanup()
    }

    /// Invalidate all sessions
    public func invalidateAll() {
        let retiredSessions = store.removeAllSessions()
        for session in retiredSessions {
            Self.retireDetached(session)
        }
        isPrewarmed = false
        cleanupTask?.cancel()
        cleanupTask = nil
    }

    // MARK: - Configuration

    private func addAuthHeaders(to request: inout URLRequest, provider: AIProvider, config: AIConfig) {
        if let header = ProviderAuthResolver.authHeader(for: provider, config: config) {
            request.setValue(header.value, forHTTPHeaderField: header.field)
        }
    }
    
    // MARK: - Cleanup
    
    private func scheduleCleanup() {
        cleanupTask?.cancel()
        cleanupTask = nil

        guard let nextExpiry = store.nextExpiry(timeout: sessionTimeout) else {
            return
        }

        cleanupTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(until: .now + .seconds(max(0, nextExpiry.timeIntervalSinceNow)))
            } catch {
                return
            }
            guard let self else { return }
            self.cleanupTask = nil
            self.cleanupStaleSessions()
            self.scheduleCleanup()
        }
    }

    /// Stops pooling immediately, then gives freshly returned callers one
    /// suspension point to create their task before the session rejects work.
    /// Detached (never MainActor): invalidating a session must not bounce
    /// through the main thread.
    nonisolated private static func retireDetached(_ session: URLSession) {
        Task.detached(priority: .utility) {
            await Task.yield()
            session.finishTasksAndInvalidate()
        }
    }

    private func cleanupStaleSessions() {
        let staleProviders = store.staleProviders(timeout: sessionTimeout)
        for provider in staleProviders {
            LogManager.shared.log("Cleaning up stale session for \(provider.displayName)", category: "AISessionManager")
            invalidate(provider: provider)
        }
    }
}

// MARK: - AIProvider Extension
// defaultAPIURL is already defined in AIConfig.swift
