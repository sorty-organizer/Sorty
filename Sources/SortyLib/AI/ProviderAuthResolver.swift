import Foundation

public enum ProviderAuthResolver {
    typealias Header = (field: String, value: String)
    private static let subscriptionAuthFlagKey = "subscriptionAuthEnabled"
    private static let disableStoredCredentialsForUITestsKey = "uitestDisableStoredProviderCredentials"

    private static let credentialCacheLock = NSLock()
    nonisolated(unsafe) private static var credentialCache: [String: (value: String?, cachedAt: Date)] = [:]
    /// Bounds keychain-hit staleness when callers cannot invalidate (e.g.
    /// SettingsViewModel.updateAPIKey, which lives outside the AI layer).
    /// In-memory `config.apiKey` is part of the cache key, so same-process
    /// edits always miss; this TTL only covers external keychain writes.
    private static let credentialCacheLifetime: TimeInterval = 60

    /// Drops memoized credentials. Called from
    /// `AISessionManager.resetPrewarmState(for:)` whenever provider, API key,
    /// API URL, or auth method changes; call from credential writers too.
    public static func invalidateCredentialCache(for provider: AIProvider? = nil) {
        credentialCacheLock.lock()
        defer { credentialCacheLock.unlock() }
        if let provider {
            credentialCache = credentialCache.filter { !$0.key.hasPrefix(provider.rawValue + "|") }
        } else {
            credentialCache.removeAll()
        }
    }

    static func authHeaders(for provider: AIProvider, config: AIConfig) -> [String: String] {
        guard let header = authHeader(for: provider, config: config) else {
            return [:]
        }
        return [header.field: header.value]
    }

    static func authHeader(for provider: AIProvider, config: AIConfig) -> Header? {
        let method = effectiveAuthMethod(for: provider, config: config)

        guard let rawCredential = credential(for: provider, method: method, config: config) else {
            return nil
        }

        let credential = rawCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else {
            return nil
        }

        switch provider {
        case .openAI, .groq, .openRouter, .openAICompatible:
            return ("Authorization", "Bearer \(credential)")
        case .anthropic:
            if method == .apiKey {
                return ("x-api-key", credential)
            }
            return ("Authorization", "Bearer \(credential)")
        case .gemini:
            return ("x-goog-api-key", credential)
        case .githubCopilot, .ollama, .appleFoundationModel:
            return nil
        }
    }

    static func hasRequiredCredential(for provider: AIProvider, config: AIConfig) -> Bool {
        switch provider {
        case .githubCopilot:
            return KeychainManager.get(key: provider.keychainKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        case .ollama, .appleFoundationModel:
            return true
        default:
            let method = effectiveAuthMethod(for: provider, config: config)
            switch method {
            case .accountSignIn:
                if provider == .openAI {
                    return CodexCLIAuthManager.hasUsableSubscriptionLogin()
                }
                return authHeader(for: provider, config: config) != nil
            case .manualSessionToken:
                return authHeader(for: provider, config: config) != nil
            case .apiKey:
                guard config.requiresAPIKey else {
                    return true
                }
                return authHeader(for: provider, config: config) != nil
            }
        }
    }

    public static func effectiveAuthMethod(for provider: AIProvider, config: AIConfig) -> ProviderAuthMethod {
        guard isSubscriptionAuthEnabled, provider.supportsSubscriptionAuth else {
            return .apiKey
        }
        return config.authMethod(for: provider)
    }

    private static var isSubscriptionAuthEnabled: Bool {
        if UserDefaults.standard.object(forKey: subscriptionAuthFlagKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: subscriptionAuthFlagKey)
    }

    private static func credential(for provider: AIProvider, method: ProviderAuthMethod, config: AIConfig) -> String? {
        switch method {
        case .apiKey:
            return configuredOrStoredAPIKey(for: provider, config: config)
        case .accountSignIn:
            // Codex ChatGPT/account credentials are consumed by `codex exec`, not
            // by Sorty's direct OpenAI API client.
            if provider == .openAI {
                return nil
            }
            return configuredOrStoredAPIKey(for: provider, config: config)
        case .manualSessionToken:
            return configuredOrStoredAPIKey(for: provider, config: config)
        }
    }

    /// Off-main credential read for catalog/session setup. Uses the same memo
    /// as the sync path; misses go through `KeychainManager.getAsync`
    /// (already detached) instead of blocking the caller on SecItem calls.
    static func credentialAsync(for provider: AIProvider, method: ProviderAuthMethod, config: AIConfig) async -> String? {
        if provider == .openAI, method == .accountSignIn {
            return nil
        }
        if let key = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        if UserDefaults.standard.bool(forKey: disableStoredCredentialsForUITestsKey) {
            return nil
        }
        let cacheKey = credentialCacheKey(for: provider, method: method, configAPIKey: nil)
        credentialCacheLock.lock()
        let cached = credentialCache[cacheKey]
        credentialCacheLock.unlock()
        if let cached, Date().timeIntervalSince(cached.cachedAt) < credentialCacheLifetime {
            return cached.value
        }
        let value = await KeychainManager.getAsync(key: provider.keychainKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = (value?.isEmpty == false) ? value : nil
        credentialCacheLock.lock()
        credentialCache[cacheKey] = (stored, Date())
        credentialCacheLock.unlock()
        return stored
    }

    /// Off-main variant of `hasRequiredCredential` for catalog fetches.
    static func hasRequiredCredentialAsync(for provider: AIProvider, config: AIConfig) async -> Bool {
        switch provider {
        case .githubCopilot:
            let cacheKey = credentialCacheKey(for: provider, method: .apiKey, configAPIKey: nil)
            credentialCacheLock.lock()
            let cached = credentialCache[cacheKey]
            credentialCacheLock.unlock()
            if let cached, Date().timeIntervalSince(cached.cachedAt) < credentialCacheLifetime {
                return cached.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            let value = await KeychainManager.getAsync(key: provider.keychainKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let valid = value?.isEmpty == false
            credentialCacheLock.lock()
            credentialCache[cacheKey] = (valid ? value : nil, Date())
            credentialCacheLock.unlock()
            return valid
        case .ollama, .appleFoundationModel:
            return true
        default:
            let method = effectiveAuthMethod(for: provider, config: config)
            switch method {
            case .accountSignIn:
                if provider == .openAI {
                    return await Task.detached(priority: .userInitiated) {
                        CodexCLIAuthManager.hasUsableSubscriptionLogin()
                    }.value
                }
                return await credentialAsync(for: provider, method: method, config: config) != nil
            case .manualSessionToken:
                return await credentialAsync(for: provider, method: method, config: config) != nil
            case .apiKey:
                guard config.requiresAPIKey else {
                    return true
                }
                return await credentialAsync(for: provider, method: method, config: config) != nil
            }
        }
    }

    private static func credentialCacheKey(
        for provider: AIProvider,
        method: ProviderAuthMethod,
        configAPIKey: String?
    ) -> String {
        let apiKeyPart = configAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(provider.rawValue)|\(method)|\(apiKeyPart.isEmpty ? "-" : "mem")"
    }

    private static func configuredOrStoredAPIKey(for provider: AIProvider, config: AIConfig) -> String? {
        if let key = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        if UserDefaults.standard.bool(forKey: disableStoredCredentialsForUITestsKey) {
            return nil
        }
        // Resolve once per configure signature and memoize; invalidated by
        // `invalidateCredentialCache(for:)` on credential/auth changes.
        let cacheKey = credentialCacheKey(for: provider, method: .apiKey, configAPIKey: nil)
        credentialCacheLock.lock()
        let cached = credentialCache[cacheKey]
        credentialCacheLock.unlock()
        if let cached, Date().timeIntervalSince(cached.cachedAt) < credentialCacheLifetime {
            return cached.value
        }
        let stored = KeychainManager.get(key: provider.keychainKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (stored?.isEmpty == false) ? stored : nil
        credentialCacheLock.lock()
        credentialCache[cacheKey] = (value, Date())
        credentialCacheLock.unlock()
        return value
    }
}
