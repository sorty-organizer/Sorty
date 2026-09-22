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
    
    // MARK: - Singleton
    
    public static let shared = AISessionManager()
    
    // MARK: - Properties
    
    /// Tracks config-relevant properties to detect when a session needs recreation
    private struct SessionSignature: Equatable {
        let requestTimeout: TimeInterval
        let resourceTimeout: TimeInterval
        let apiURL: String?
    }
    
    /// Cached sessions per provider
    private var sessions: [AIProvider: URLSession] = [:]
    
    /// Cached signatures per provider for change detection
    private var sessionSignatures: [AIProvider: SessionSignature] = [:]
    
    /// Last usage time for cleanup
    private var lastUsed: [AIProvider: Date] = [:]
    
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
    
    /// Get or create a URLSession for a provider
    public func session(for provider: AIProvider, config: AIConfig) -> URLSession {
        lastUsed[provider] = Date()
        scheduleCleanup()
        
        let currentSignature = SessionSignature(
            requestTimeout: config.requestTimeout,
            resourceTimeout: config.resourceTimeout,
            apiURL: config.apiURL
        )
        
        if let existing = sessions[provider] {
            if sessionSignatures[provider] == currentSignature {
                return existing
            }
            LogManager.shared.log("Config changed for \(provider.displayName), recreating session", level: .debug, category: "AISessionManager")
            let retiredSession = sessions.removeValue(forKey: provider)
            sessionSignatures.removeValue(forKey: provider)
            retire(retiredSession)
        }
        
        let sessionConfig = createSessionConfiguration(for: provider, aiConfig: config)
        let session = NetworkPrivacyPolicy.makeSession(configuration: sessionConfig)
        sessions[provider] = session
        sessionSignatures[provider] = currentSignature
        
        LogManager.shared.log("Created new session for \(provider.displayName)", level: .debug, category: "AISessionManager")
        
        return session
    }
    
    /// Prewarm connection for a provider (call when user selects folder)
    public func prewarm(provider: AIProvider, config: AIConfig) async {
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
            return
        }

        // Skip prewarming for local/on-device providers
        switch provider {
        case .ollama, .appleFoundationModel:
            isPrewarmed = true
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
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 5

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
                        return
                    } else {
                        // Non-success status, try next URL
                        LogManager.shared.log("Prewarm attempt \(index + 1) for \(provider.displayName): HTTP \(httpResponse.statusCode)", level: .debug, category: "AISessionManager")
                    }
                }
            } catch {
                // This URL failed, try the next one
                LogManager.shared.log("Prewarm attempt \(index + 1) failed for \(provider.displayName): \(error.localizedDescription)", level: .debug, category: "AISessionManager")
                continue
            }
        }

        // All URLs failed
        guard generation == prewarmGenerations[provider, default: 0] else { return }
        prewarmError = "Could not establish connection to \(provider.displayName)"
        isPrewarmed = false

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
        if let session = sessions.removeValue(forKey: provider) {
            sessionSignatures.removeValue(forKey: provider)
            lastUsed.removeValue(forKey: provider)
            retire(session)
            LogManager.shared.log("Removed session for \(provider.displayName)", category: "AISessionManager")
        }
        
        prewarmingProviders.remove(provider)
        scheduleCleanup()
    }
    
    /// Invalidate all sessions
    public func invalidateAll() {
        for (provider, _) in sessions {
            LogManager.shared.log("Removing session for \(provider.displayName)", category: "AISessionManager")
        }
        let retiredSessions = Array(sessions.values)
        sessions.removeAll()
        sessionSignatures.removeAll()
        lastUsed.removeAll()
        isPrewarmed = false
        cleanupTask?.cancel()
        cleanupTask = nil
        retiredSessions.forEach(retire)
    }
    
    // MARK: - Configuration
    
    private func createSessionConfiguration(for provider: AIProvider, aiConfig: AIConfig) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        
        // Enable HTTP/2 for better performance
        config.httpAdditionalHeaders = [
            "Accept-Encoding": "gzip, deflate",
            "Connection": "keep-alive"
        ]
        
        // Use user's configured timeout values from AIConfig
        // requestTimeout: time to establish connection and receive response headers
        // resourceTimeout: total time allowed for streaming/large responses
        config.timeoutIntervalForRequest = aiConfig.requestTimeout  // User's setting (default 120s)
        config.timeoutIntervalForResource = aiConfig.resourceTimeout  // User's setting (default 600s)
        
        // Enable connection reuse - critical for performance
        config.httpMaximumConnectionsPerHost = 6
        config.urlCache = nil  // No caching for AI requests
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        // Enable TLS 1.2+ for security and performance
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.tlsMaximumSupportedProtocolVersion = .TLSv13
        
        // TCP connection optimization
        config.shouldUseExtendedBackgroundIdleMode = true
        config.sessionSendsLaunchEvents = false
        
        return config
    }

    private func addAuthHeaders(to request: inout URLRequest, provider: AIProvider, config: AIConfig) {
        if let header = ProviderAuthResolver.authHeader(for: provider, config: config) {
            request.setValue(header.value, forHTTPHeaderField: header.field)
        }
    }
    
    // MARK: - Cleanup
    
    private func scheduleCleanup() {
        cleanupTask?.cancel()
        cleanupTask = nil

        guard let nextExpiry = lastUsed.values.min()?.addingTimeInterval(sessionTimeout) else {
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

    /// Stops pooling immediately, then gives freshly returned callers one run-loop turn
    /// to create their task before the session rejects new work.
    private func retire(_ session: URLSession?) {
        guard let session else { return }
        Task { @MainActor in
            await Task.yield()
            session.finishTasksAndInvalidate()
        }
    }
    
    private func cleanupStaleSessions() {
        let now = Date()

        let staleProviders = lastUsed.compactMap { provider, lastAccess in
            now.timeIntervalSince(lastAccess) >= sessionTimeout ? provider : nil
        }
        for provider in staleProviders {
            LogManager.shared.log("Cleaning up stale session for \(provider.displayName)", category: "AISessionManager")
            invalidate(provider: provider)
        }
    }
}

// MARK: - AIProvider Extension
// defaultAPIURL is already defined in AIConfig.swift
