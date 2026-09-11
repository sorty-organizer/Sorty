//
//  ModelCatalog.swift
//  Sorty
//
//  Dynamic model catalog with caching for AI providers.
//

import Foundation
import Combine

public struct ModelInfo: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let provider: AIProvider
    public let capabilities: [String]?
    public let supportedReasoningEfforts: [ReasoningEffort]?
    public let defaultReasoningEffort: ReasoningEffort?
    public let updatedAt: Date
    public let isFree: Bool

    public init(
        id: String,
        displayName: String,
        provider: AIProvider,
        capabilities: [String]? = nil,
        supportedReasoningEfforts: [ReasoningEffort]? = nil,
        defaultReasoningEffort: ReasoningEffort? = nil,
        updatedAt: Date = Date(),
        isFree: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.capabilities = capabilities
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.updatedAt = updatedAt
        self.isFree = isFree
    }
}

@MainActor
public final class ModelCatalog: ObservableObject {
    private struct OpenAICompatibleModelsResponse: Decodable {
        let data: [OpenAICompatibleModel]
    }

    private struct OpenAICompatibleModel: Decodable {
        let id: String
        let created: Int?
        let modalities: [String]?
        let capabilities: [String]?
        let input_modalities: [String]?
        let output_modalities: [String]?
    }

    public static let shared = ModelCatalog()
    
    @Published public var modelsByProvider: [AIProvider: [ModelInfo]] = [:]
    @Published public var isFetching: [AIProvider: Bool] = [:]
    @Published public var lastError: [AIProvider: Error?] = [:]
    @Published public var searchResults: [(provider: AIProvider, models: [ModelInfo])] = []
    @Published public var usingFallback: [AIProvider: Bool] = [:]
    @Published public private(set) var codexSubscriptionModels: [ModelInfo] = []
    
    private var cacheTimestamps: [AIProvider: Date] = [:]
    private let session: URLSession
    private let codexModelLoader: @MainActor () async throws -> [ModelInfo]
    private var searchTask: Task<Void, Never>?
    private var codexModelsTimestamp: Date?
    private var cachedOpenAIAuthMethod: ProviderAuthMethod?
    private var refreshIDs: [AIProvider: UUID] = [:]
    
    private static let cloudTTL: TimeInterval = 24 * 60 * 60
    private static let ollamaTTL: TimeInterval = 10 * 60
    private let configKey = "aiConfig"
    
    private var cacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Sorty/ModelCache")
    }
    
    public convenience init() {
        self.init(codexModelLoader: Self.fetchCodexSubscriptionModels)
    }

    init(codexModelLoader: @escaping @MainActor () async throws -> [ModelInfo]) {
        self.codexModelLoader = codexModelLoader
        let config = URLSessionConfiguration.default
        // Optimized timeouts for fast connection establishment
        // Model list fetches should be quick; slow providers will use fallback models
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpMaximumConnectionsPerHost = 6
        config.httpAdditionalHeaders = [
            "Accept-Encoding": "gzip, deflate",
            "Connection": "keep-alive"
        ]
        self.session = NetworkPrivacyPolicy.makeSession(configuration: config)
        loadCacheFromDisk()
    }
    
    public func cachedModels(for provider: AIProvider) -> [ModelInfo] {
        let cached = modelsByProvider[provider] ?? []
        if cached.isEmpty {
            return fallbackModels(for: provider)
        }
        return filteredModels(cached, for: provider)
    }

    public func reasoningConfiguration(
        for modelID: String,
        provider: AIProvider
    ) -> (efforts: [ReasoningEffort], defaultEffort: ReasoningEffort?)? {
        let providerModels = modelsByProvider[provider] ?? []
        let candidates = provider == .openAI
            ? codexSubscriptionModels + providerModels
            : providerModels
        guard let model = candidates.first(where: {
            $0.id.caseInsensitiveCompare(modelID) == .orderedSame
        }), let efforts = model.supportedReasoningEfforts, !efforts.isEmpty else {
            return nil
        }
        return (efforts, model.defaultReasoningEffort)
    }

    public func refreshCodexSubscriptionModels(force: Bool = false) async {
        if !force,
           let codexModelsTimestamp,
           Date().timeIntervalSince(codexModelsTimestamp) < Self.cloudTTL,
           !codexSubscriptionModels.isEmpty {
            return
        }

        let refreshID = UUID()
        refreshIDs[.openAI] = refreshID
        isFetching[.openAI] = true
        lastError[.openAI] = nil
        defer {
            if refreshIDs[.openAI] == refreshID {
                isFetching[.openAI] = false
            }
        }
        do {
            let models = try await codexModelLoader()
            guard refreshIDs[.openAI] == refreshID, !Task.isCancelled else { return }
            codexSubscriptionModels = models
            codexModelsTimestamp = Date()
            usingFallback[.openAI] = false
            lastError[.openAI] = nil
        } catch {
            guard refreshIDs[.openAI] == refreshID, !Task.isCancelled else { return }
            ReliabilityManager.shared.capture(
                error: error,
                feature: "model_catalog",
                operation: "refresh_codex_models"
            )
            guard codexSubscriptionModels.isEmpty else {
                usingFallback[.openAI] = true
                return
            }
            lastError[.openAI] = error
        }
    }

    /// Whether a model id is served through the ChatGPT subscription (Codex).
    public func isCodexSubscriptionModel(_ modelId: String) -> Bool {
        codexSubscriptionModels.contains { $0.id == modelId }
    }
    
    public func refresh(
        provider: AIProvider,
        force: Bool = false,
        authMethod: ProviderAuthMethod? = nil
    ) async {
        let resolvedAuth = provider == .openAI
            ? (authMethod ?? ProviderAuthResolver.effectiveAuthMethod(for: .openAI, config: storedAIConfig() ?? .default))
            : nil
        let authMatchesCache = provider != .openAI || cachedOpenAIAuthMethod == resolvedAuth
        if !force, authMatchesCache, let timestamp = cacheTimestamps[provider] {
            let ttl = provider == .ollama ? Self.ollamaTTL : Self.cloudTTL
            if Date().timeIntervalSince(timestamp) < ttl {
                return
            }
        }
        
        let refreshID = UUID()
        refreshIDs[provider] = refreshID
        isFetching[provider] = true
        lastError[provider] = nil
        defer {
            if refreshIDs[provider] == refreshID {
                isFetching[provider] = false
            }
        }
        
        do {
            let result = try await fetchModels(for: provider, force: force, authMethod: resolvedAuth, refreshID: refreshID)
            let sortedModels = filteredModels(
                result.models.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
                for: provider
            )
            guard refreshIDs[provider] == refreshID, !Task.isCancelled else { return }
            modelsByProvider[provider] = sortedModels
            if provider == .openAI {
                cachedOpenAIAuthMethod = resolvedAuth
            }
            usingFallback[provider] = result.isFallback
            
            // Only update cache and timestamp if NOT using fallback
            if !result.isFallback {
                cacheTimestamps[provider] = Date()
                saveCacheToDisk(provider: provider, models: sortedModels)
            }
        } catch {
            guard refreshIDs[provider] == refreshID, !Task.isCancelled else { return }
            lastError[provider] = error
            ReliabilityManager.shared.capture(
                error: error,
                feature: "model_catalog",
                operation: "refresh_provider"
            )
        }
    }
    
    public func refreshAllAvailable(force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for provider in AIProvider.allCases where provider.isAvailable {
                group.addTask {
                    await self.refresh(provider: provider, force: force)
                }
            }
        }
    }
    
    public func searchAllProviders(query: String) -> [(provider: AIProvider, models: [ModelInfo])] {
        let lowercased = query.lowercased()
        var results: [(provider: AIProvider, models: [ModelInfo])] = []
        
        for (provider, models) in modelsByProvider {
            let matching = models.filter {
                $0.id.lowercased().contains(lowercased) ||
                $0.displayName.lowercased().contains(lowercased)
            }
            if !matching.isEmpty {
                results.append((provider, matching))
            }
        }
        
        return results.sorted { $0.provider.displayName < $1.provider.displayName }
    }

    private func storedAIConfig() -> AIConfig? {
        guard let data = UserDefaults.standard.data(forKey: configKey) else {
            return nil
        }
        return try? JSONDecoder().decode(AIConfig.self, from: data)
    }

    private func configForProvider(_ provider: AIProvider) -> AIConfig {
        var config = storedAIConfig() ?? .default
        config.provider = provider
        config.apiURL = provider.defaultAPIURL
        config.model = provider.defaultModel
        config.requiresAPIKey = provider.typicallyRequiresAPIKey
        config.apiKey = KeychainManager.get(key: provider.keychainKey)
        return config
    }
    
    public func performDebouncedSearch(query: String) {
        searchTask?.cancel()
        
        if query.isEmpty {
            searchResults = []
            return
        }
        
        searchTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            
            guard !Task.isCancelled else { return }
            
            let capturedModels = modelsByProvider
            let lowercased = query.lowercased()
            
            let results: [(provider: AIProvider, models: [ModelInfo])] = await Task.detached {
                var searchResults: [(provider: AIProvider, models: [ModelInfo])] = []
                for (provider, models) in capturedModels {
                    let matching = models.filter {
                        $0.id.lowercased().contains(lowercased) ||
                        $0.displayName.lowercased().contains(lowercased)
                    }
                    if !matching.isEmpty {
                        searchResults.append((provider, matching))
                    }
                }
                return searchResults.sorted { $0.provider.displayName < $1.provider.displayName }
            }.value
            
            guard !Task.isCancelled else { return }
            searchResults = results
        }
    }
    
    private func fetchModels(for provider: AIProvider, force: Bool, authMethod: ProviderAuthMethod?, refreshID: UUID) async throws -> (models: [ModelInfo], isFallback: Bool) {
        switch provider {
        case .openAI:
            return try await fetchOpenAIModels(force: force, authMethod: authMethod, refreshID: refreshID)
        case .anthropic:
            return try await fetchAnthropicModels()
        case .gemini:
            return try await fetchGeminiModels()
        case .groq:
            return (try await fetchGroqModels(), false)
        case .openRouter:
            return (try await fetchOpenRouterModels(), false)
        case .ollama:
            return (try await fetchOllamaModels(), false)
        case .githubCopilot:
            return try await fetchGitHubCopilotModels()
        case .appleFoundationModel:
            return (appleFoundationModels(), false)
        case .openAICompatible:
            return try await fetchOpenAICompatibleModels()
        }
    }
    
    private func fetchOpenAIModels(force: Bool, authMethod: ProviderAuthMethod?, refreshID: UUID) async throws -> (models: [ModelInfo], isFallback: Bool) {
        var config = configForProvider(.openAI)
        if let authMethod {
            config.setAuthMethod(authMethod, for: .openAI)
        }
        let authMethod = ProviderAuthResolver.effectiveAuthMethod(for: .openAI, config: config)

        if authMethod == .accountSignIn {
            // Avoid CLI startup while the subscription catalog is fresh.
            if !force, !codexSubscriptionModels.isEmpty,
               let codexModelsTimestamp,
               Date().timeIntervalSince(codexModelsTimestamp) < Self.cloudTTL {
                return (codexSubscriptionModels, false)
            }
            // `hasRequiredCredential` may shell out to the Codex CLI (`codex login
            // status`) and block on `Process.waitUntilExit()`. Running that on the
            // main thread spins the run loop and re-enters SwiftUI's in-progress
            // AttributeGraph transaction, which aborts the app. Offload it.
            let hasCredential = await Task.detached(priority: .userInitiated) {
                ProviderAuthResolver.hasRequiredCredential(for: .openAI, config: config)
            }.value
            if hasCredential {
                do {
                    let models = try await codexModelLoader()
                    guard refreshIDs[.openAI] == refreshID, !Task.isCancelled else {
                        throw CancellationError()
                    }
                    codexSubscriptionModels = models
                    codexModelsTimestamp = Date()
                    return (models, false)
                } catch {
                    guard refreshIDs[.openAI] == refreshID, !Task.isCancelled else {
                        throw CancellationError()
                    }
                    ReliabilityManager.shared.capture(
                        error: error,
                        feature: "model_catalog",
                        operation: "refresh_codex_models_stale_fallback"
                    )
                    if !codexSubscriptionModels.isEmpty {
                        return (codexSubscriptionModels, true)
                    }
                    throw error
                }
            }
            return ([], true)
        }

        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            throw ModelCatalogError.invalidURL
        }
        try ensureNetworkAllowed(url)

        guard let authHeader = ProviderAuthResolver.authHeader(for: .openAI, config: config) else {
            throw ModelCatalogError.fetchFailed
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue(authHeader.value, forHTTPHeaderField: authHeader.field)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ModelCatalogError.fetchFailed
        }
        
        let models = try decodeOpenAICompatibleModels(from: data, provider: .openAI)
        return (models, false)
    }

    private static func fetchCodexSubscriptionModels() async throws -> [ModelInfo] {
        try await CodexSubscriptionClient.availableModels().map { model in
            ModelInfo(
                id: model.id,
                displayName: model.displayName,
                provider: .openAI,
                capabilities: model.inputModalities.map { "input:\($0)" }
                    + model.serviceTiers.map { "service:\($0)" },
                supportedReasoningEfforts: model.supportedReasoningEfforts,
                defaultReasoningEffort: model.defaultReasoningEffort,
                updatedAt: Date()
            )
        }
    }
    
    private func fetchGroqModels() async throws -> [ModelInfo] {
        guard let url = URL(string: "https://api.groq.com/openai/v1/models") else {
            throw ModelCatalogError.invalidURL
        }
        try ensureNetworkAllowed(url)
        
        guard let groqAPIKey = KeychainManager.get(key: AIProvider.groq.keychainKey), !groqAPIKey.isEmpty else {
            throw ModelCatalogError.fetchFailed
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(groqAPIKey)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ModelCatalogError.fetchFailed
        }
        
        return try decodeOpenAICompatibleModels(from: data, provider: .groq)
    }
    
    private func fetchOpenRouterModels() async throws -> [ModelInfo] {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models") else {
            throw ModelCatalogError.invalidURL
        }
        try ensureNetworkAllowed(url)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        if let apiKey = KeychainManager.get(key: AIProvider.openRouter.keychainKey), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ModelCatalogError.fetchFailed
        }

        struct OpenRouterModelsResponse: Decodable {
            let data: [OpenRouterModel]
        }
        struct OpenRouterModel: Decodable {
            let id: String
            let name: String?
            let modalities: [String]?
            let capabilities: [String]?
            let architecture: OpenRouterArchitecture?
            let pricing: OpenRouterPricing?
            let reasoning: OpenRouterReasoning?
        }
        struct OpenRouterReasoning: Decodable {
            let supported_efforts: [String]?
            let default_effort: String?
        }
        struct OpenRouterArchitecture: Decodable {
            let modality: String?
            let input_modalities: [String]?
            let output_modalities: [String]?
        }
        struct OpenRouterPricing: Decodable {
            let prompt: String?
            let completion: String?
        }

        let decoded = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)
        return decoded.data.map { model in
            let isFree = model.id.hasSuffix(":free") ||
                (model.pricing?.prompt == "0" && model.pricing?.completion == "0")
            let architectureTags: [String]? = {
                guard model.architecture != nil else { return nil }
                var tags: [String] = []
                if let modality = model.architecture?.modality {
                    tags.append(modality)
                }
                if let inputModalities = model.architecture?.input_modalities {
                    tags.append(contentsOf: inputModalities)
                    tags.append(contentsOf: inputModalities.map { "input:\($0)" })
                }
                if let outputModalities = model.architecture?.output_modalities {
                    tags.append(contentsOf: outputModalities)
                    tags.append(contentsOf: outputModalities.map { "output:\($0)" })
                }
                return tags
            }()
            let capabilityTags = mergeCapabilityTags([
                model.modalities,
                model.capabilities,
                architectureTags
            ])
            return ModelInfo(
                id: model.id,
                displayName: model.name ?? model.id,
                provider: .openRouter,
                capabilities: capabilityTags,
                supportedReasoningEfforts: model.reasoning?.supported_efforts?.map(ReasoningEffort.init(rawValue:)),
                defaultReasoningEffort: model.reasoning?.default_effort.map(ReasoningEffort.init(rawValue:)),
                updatedAt: Date(),
                isFree: isFree
            )
        }
    }
    
    private func fetchOllamaModels() async throws -> [ModelInfo] {
        guard let url = URL(string: "http://localhost:11434/api/tags") else {
            throw ModelCatalogError.invalidURL
        }
        try ensureNetworkAllowed(url)
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ModelCatalogError.fetchFailed
        }
        
        struct OllamaTagsResponse: Decodable {
            let models: [OllamaModel]
        }
        struct OllamaModel: Decodable {
            let name: String
            let modified_at: String?
            let capabilities: [String]?
        }
        
        let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var capabilityByModel: [String: [String]] = [:]
        for model in decoded.models.prefix(40) {
            if let capabilities = normalizedCapabilityTags(from: model.capabilities) {
                capabilityByModel[model.name] = capabilities
                continue
            }
            if let capabilities = await fetchOllamaModelCapabilities(modelName: model.name) {
                capabilityByModel[model.name] = capabilities
            }
        }
        
        return decoded.models.map { model in
            let updatedAt = model.modified_at.flatMap { dateFormatter.date(from: $0) } ?? Date()
            return ModelInfo(
                id: model.name,
                displayName: model.name,
                provider: .ollama,
                capabilities: capabilityByModel[model.name] ?? normalizedCapabilityTags(from: model.capabilities),
                updatedAt: updatedAt
            )
        }
    }

    private func fetchOllamaModelCapabilities(modelName: String) async -> [String]? {
        guard let url = URL(string: "http://localhost:11434/api/show"),
              NetworkPrivacyPolicy.isRequestAllowed(url: url) else {
            return nil
        }

        struct ShowRequest: Encodable {
            let model: String
        }
        struct ShowResponse: Decodable {
            let capabilities: [String]?
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 1.5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(ShowRequest(model: modelName))

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            let decoded = try JSONDecoder().decode(ShowResponse.self, from: data)
            return normalizedCapabilityTags(from: decoded.capabilities)
        } catch {
            return nil
        }
    }
    
    private func fetchAnthropicModels() async throws -> (models: [ModelInfo], isFallback: Bool) {
        guard let url = URL(string: "https://api.anthropic.com/v1/models") else {
            throw ModelCatalogError.invalidURL
        }
        if !NetworkPrivacyPolicy.isRequestAllowed(url: url) {
            return (anthropicFallbackModels(), true)
        }

        let config = configForProvider(.anthropic)
        guard let authHeader = ProviderAuthResolver.authHeader(for: .anthropic, config: config) else {
            return (anthropicFallbackModels(), true)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue(authHeader.value, forHTTPHeaderField: authHeader.field)
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return (anthropicFallbackModels(), true)
            }
            
            struct AnthropicModelsResponse: Decodable {
                let data: [AnthropicModel]
            }
            struct AnthropicModel: Decodable {
                let id: String
                let display_name: String?
                let capabilities: [String: AnyAnthropicCapability]?
            }
            
            let decoded = try JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
            if decoded.data.isEmpty {
                return (anthropicFallbackModels(), true)
            }
            
            let models = decoded.data.map { model in
                let capabilityTags = anthropicCapabilityTags(from: model.capabilities)
                return ModelInfo(
                    id: model.id,
                    displayName: model.display_name ?? model.id,
                    provider: .anthropic,
                    capabilities: capabilityTags,
                    updatedAt: Date()
                )
            }
            return (models, false)
        } catch {
            return (anthropicFallbackModels(), true)
        }
    }

    private func fetchOpenAICompatibleModels() async throws -> (models: [ModelInfo], isFallback: Bool) {
        // We need to get the URL from the current config
        // This is a bit tricky as ModelCatalog is a singleton and doesn't know about SettingsViewModel
        // However, we can try to use the stored URL in UserDefaults or just fallback
        
        let userDefaults = UserDefaults.standard
        
        var apiURL = "https://api.openai.com"
        var apiKey: String?
        
        if let data = userDefaults.data(forKey: configKey),
           let decoded = try? JSONDecoder().decode(AIConfig.self, from: data) {
            if decoded.provider == .openAICompatible {
                apiURL = decoded.apiURL ?? apiURL
            }
        }
        
        apiKey = KeychainManager.get(key: AIProvider.openAICompatible.keychainKey)
        
        var urlString = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.contains("://") && !urlString.isEmpty {
            urlString = "https://" + urlString
        }

        // Ensure URL ends with /v1/models or similar if it's just a base URL
        if !urlString.hasSuffix("/models") {
            if urlString.hasSuffix("/") {
                urlString += "v1/models"
            } else {
                urlString += "/v1/models"
            }
        }
        
        guard let url = URL(string: urlString), url.scheme != nil else {
            return (openAICompatibleFallback(), true)
        }
        if !NetworkPrivacyPolicy.isRequestAllowed(url: url) {
            return (openAICompatibleFallback(), true)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        if let key = apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return (openAICompatibleFallback(), true)
            }
            
            let models = try decodeOpenAICompatibleModels(
                from: data,
                provider: .openAICompatible,
                usesCreatedTimestamp: false
            )
            return (models, false)
        } catch {
            return (openAICompatibleFallback(), true)
        }
    }
    
    private func fetchGitHubCopilotModels() async throws -> (models: [ModelInfo], isFallback: Bool) {
        guard let url = URL(string: "https://api.githubcopilot.com/models") else {
            throw ModelCatalogError.invalidURL
        }
        try ensureNetworkAllowed(url)

        let authManager = GitHubCopilotAuthManager.shared
        let initialToken = try await authManager.getCopilotToken()
        let (initialData, initialStatusCode) = try await fetchGitHubCopilotModelsResponse(url: url, token: initialToken)

        var data = initialData
        var statusCode = initialStatusCode

        // Recover from stale cached Copilot token by forcing a refresh once.
        if statusCode == 401 || statusCode == 403 {
            authManager.invalidateCachedCopilotToken()
            let refreshedToken = try await authManager.getCopilotToken(forceRefresh: true)
            let retryResult = try await fetchGitHubCopilotModelsResponse(url: url, token: refreshedToken)
            data = retryResult.data
            statusCode = retryResult.statusCode
        }

        guard (200...299).contains(statusCode) else {
            if statusCode == 401 || statusCode == 403 {
                throw GitHubAuthError.accessDenied
            }
            throw ModelCatalogError.fetchFailed
        }

        let decodedModels = decodeGitHubCopilotModelPayloads(from: data)
        if decodedModels.isEmpty {
            throw ModelCatalogError.fetchFailed
        }

        let models = decodedModels.compactMap { model -> ModelInfo? in
            guard let modelID = model.resolvedID else { return nil }
            let capabilityTags = mergeCapabilityTags([
                model.modalities,
                model.capabilities,
                model.resolvedInputModalities,
                model.resolvedInputModalities?.map { "input:\($0)" },
                model.resolvedOutputModalities,
                model.resolvedOutputModalities?.map { "output:\($0)" }
            ])
            return ModelInfo(
                id: modelID,
                displayName: modelID,
                provider: .githubCopilot,
                capabilities: capabilityTags,
                supportedReasoningEfforts: model.resolvedReasoningEfforts,
                defaultReasoningEffort: model.resolvedDefaultReasoningEffort,
                updatedAt: Date()
            )
        }

        if models.isEmpty {
            throw ModelCatalogError.fetchFailed
        }

        return (models, false)
    }

    private func fetchGitHubCopilotModelsResponse(url: URL, token: String) async throws -> (data: Data, statusCode: Int) {
        try ensureNetworkAllowed(url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.85.1", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot/1.138.0", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GithubCopilot/1.138.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelCatalogError.fetchFailed
        }

        return (data, httpResponse.statusCode)
    }

    private func decodeGitHubCopilotModelPayloads(from data: Data) -> [GitHubCopilotModelPayload] {
        let decoder = JSONDecoder()

        if let wrapped = try? decoder.decode(GitHubCopilotModelsResponse.self, from: data),
           let wrappedModels = wrapped.preferredModels,
           !wrappedModels.isEmpty {
            return wrappedModels
        }

        if let topLevelArray = try? decoder.decode([GitHubCopilotModelPayload].self, from: data),
           !topLevelArray.isEmpty {
            return topLevelArray
        }

        return decodeGitHubCopilotModelPayloadsLoosely(from: data)
    }

    private func decodeGitHubCopilotModelPayloadsLoosely(from data: Data) -> [GitHubCopilotModelPayload] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        let rawModels: [[String: Any]]
        if let dictionary = json as? [String: Any] {
            if let dataArray = dictionary["data"] as? [[String: Any]] {
                rawModels = dataArray
            } else if let modelsArray = dictionary["models"] as? [[String: Any]] {
                rawModels = modelsArray
            } else {
                rawModels = []
            }
        } else if let array = json as? [[String: Any]] {
            rawModels = array
        } else {
            rawModels = []
        }

        return rawModels.compactMap { GitHubCopilotModelPayload(dictionary: $0) }
    }

    private struct GitHubCopilotModelsResponse: Decodable {
        let data: [GitHubCopilotModelPayload]?
        let models: [GitHubCopilotModelPayload]?

        var preferredModels: [GitHubCopilotModelPayload]? {
            if let data, !data.isEmpty { return data }
            if let models, !models.isEmpty { return models }
            return nil
        }
    }

    private struct GitHubCopilotModelPayload: Decodable {
        let id: String?
        let model: String?
        let name: String?
        let modalities: [String]?
        let capabilities: [String]?
        let input_modalities: [String]?
        let output_modalities: [String]?
        let inputModalities: [String]?
        let outputModalities: [String]?
        let supported_reasoning_efforts: [String]?
        let supportedReasoningEfforts: [String]?
        let default_reasoning_effort: String?
        let defaultReasoningEffort: String?

        var resolvedID: String? {
            [id, model, name]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
        }

        var resolvedInputModalities: [String]? {
            if let input_modalities, !input_modalities.isEmpty {
                return input_modalities
            }
            return inputModalities
        }

        var resolvedOutputModalities: [String]? {
            if let output_modalities, !output_modalities.isEmpty {
                return output_modalities
            }
            return outputModalities
        }

        var resolvedReasoningEfforts: [ReasoningEffort]? {
            let values = supported_reasoning_efforts ?? supportedReasoningEfforts
            let efforts = values?.map(ReasoningEffort.init(rawValue:)) ?? []
            return efforts.isEmpty ? nil : efforts
        }

        var resolvedDefaultReasoningEffort: ReasoningEffort? {
            (default_reasoning_effort ?? defaultReasoningEffort)
                .map(ReasoningEffort.init(rawValue:))
        }

        init(
            id: String? = nil,
            model: String? = nil,
            name: String? = nil,
            modalities: [String]? = nil,
            capabilities: [String]? = nil,
            input_modalities: [String]? = nil,
            output_modalities: [String]? = nil,
            inputModalities: [String]? = nil,
            outputModalities: [String]? = nil,
            supported_reasoning_efforts: [String]? = nil,
            supportedReasoningEfforts: [String]? = nil,
            default_reasoning_effort: String? = nil,
            defaultReasoningEffort: String? = nil
        ) {
            self.id = id
            self.model = model
            self.name = name
            self.modalities = modalities
            self.capabilities = capabilities
            self.input_modalities = input_modalities
            self.output_modalities = output_modalities
            self.inputModalities = inputModalities
            self.outputModalities = outputModalities
            self.supported_reasoning_efforts = supported_reasoning_efforts
            self.supportedReasoningEfforts = supportedReasoningEfforts
            self.default_reasoning_effort = default_reasoning_effort
            self.defaultReasoningEffort = defaultReasoningEffort
        }

        init?(dictionary: [String: Any]) {
            let id = dictionary["id"] as? String
            let model = dictionary["model"] as? String
            let name = dictionary["name"] as? String
            let modalities = Self.stringArray(from: dictionary["modalities"])
            let capabilities = Self.stringArray(from: dictionary["capabilities"])
            let inputModalitiesSnake = Self.stringArray(from: dictionary["input_modalities"])
            let outputModalitiesSnake = Self.stringArray(from: dictionary["output_modalities"])
            let inputModalitiesCamel = Self.stringArray(from: dictionary["inputModalities"])
            let outputModalitiesCamel = Self.stringArray(from: dictionary["outputModalities"])
            let reasoningEffortsSnake = Self.reasoningEffortArray(from: dictionary["supported_reasoning_efforts"])
            let reasoningEffortsCamel = Self.reasoningEffortArray(from: dictionary["supportedReasoningEfforts"])

            let payload = GitHubCopilotModelPayload(
                id: id,
                model: model,
                name: name,
                modalities: modalities,
                capabilities: capabilities,
                input_modalities: inputModalitiesSnake,
                output_modalities: outputModalitiesSnake,
                inputModalities: inputModalitiesCamel,
                outputModalities: outputModalitiesCamel,
                supported_reasoning_efforts: reasoningEffortsSnake,
                supportedReasoningEfforts: reasoningEffortsCamel,
                default_reasoning_effort: dictionary["default_reasoning_effort"] as? String,
                defaultReasoningEffort: dictionary["defaultReasoningEffort"] as? String
            )

            guard payload.resolvedID != nil else { return nil }
            self = payload
        }

        private static func stringArray(from value: Any?) -> [String]? {
            if let values = value as? [String] {
                return values
            }

            if let values = value as? [Any] {
                let strings = values.compactMap { $0 as? String }
                return strings.isEmpty ? nil : strings
            }

            return nil
        }

        private static func reasoningEffortArray(from value: Any?) -> [String]? {
            if let strings = stringArray(from: value) {
                return strings
            }
            guard let values = value as? [[String: Any]] else { return nil }
            let strings = values.compactMap {
                $0["reasoningEffort"] as? String ?? $0["reasoning_effort"] as? String
            }
            return strings.isEmpty ? nil : strings
        }
    }
    
    private func fetchGeminiModels() async throws -> (models: [ModelInfo], isFallback: Bool) {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1/models") else {
            throw ModelCatalogError.invalidURL
        }
        if !NetworkPrivacyPolicy.isRequestAllowed(url: url) {
            return (geminiFallbackModels(), true)
        }
        
        guard let geminiAPIKey = KeychainManager.get(key: AIProvider.gemini.keychainKey), !geminiAPIKey.isEmpty else {
             return (geminiFallbackModels(), true)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(geminiAPIKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 15
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return (geminiFallbackModels(), true)
            }
            
            struct GeminiModelsResponse: Decodable {
                let models: [GeminiModel]
            }
            struct GeminiModel: Decodable {
                let name: String
                let displayName: String?
                let supportedGenerationMethods: [String]?
            }
            
            let decoded = try JSONDecoder().decode(GeminiModelsResponse.self, from: data)
            if decoded.models.isEmpty {
                return (geminiFallbackModels(), true)
            }
            
            let models = decoded.models.map { model in
                let id = model.name.replacingOccurrences(of: "models/", with: "")
                let capabilityTags = geminiCapabilityTags(
                    modelId: id,
                    supportedGenerationMethods: model.supportedGenerationMethods
                )
                return ModelInfo(
                    id: id,
                    displayName: model.displayName ?? id,
                    provider: .gemini,
                    capabilities: capabilityTags,
                    updatedAt: Date()
                )
            }
            return (models, false)
        } catch {
            return (geminiFallbackModels(), true)
        }
    }
    
    private func anthropicFallbackModels() -> [ModelInfo] {
        let models = [
            "claude-sonnet-4-6",
            "claude-opus-4-6",
            "claude-haiku-4-5",
            "claude-haiku-4-5-20251001",
            "claude-sonnet-4",
            "claude-opus-4"
        ]
        return models.map { ModelInfo(id: $0, displayName: $0, provider: .anthropic) }
    }

    private func geminiFallbackModels() -> [ModelInfo] {
        let models = [
            "gemini-3.1-pro-preview",
            "gemini-3-flash-preview",
            "gemini-3.1-flash-lite-preview",
            "gemini-2.5-pro",
            "gemini-2.5-flash",
            "gemini-2.5-flash-lite"
        ]
        return models.map { ModelInfo(id: $0, displayName: $0, provider: .gemini) }
    }
    
    private func appleFoundationModels() -> [ModelInfo] {
        [ModelInfo(id: AIProvider.appleFoundationModelName, displayName: AIProvider.appleFoundationModelName, provider: .appleFoundationModel)]
    }
    
    private func openAICompatibleFallback() -> [ModelInfo] {
        [ModelInfo(id: "gpt-5.4-mini", displayName: "gpt-5.4-mini", provider: .openAICompatible)]
    }
    
    private func fallbackModels(for provider: AIProvider) -> [ModelInfo] {
        filteredModels(
            provider.recommendedModels.map { ModelInfo(id: $0, displayName: $0, provider: provider) },
            for: provider
        )
    }

    private func filteredModels(_ models: [ModelInfo], for provider: AIProvider) -> [ModelInfo] {
        var sanitized: [ModelInfo] = []
        var seenModelIDs = Set<String>()

        for model in models {
            let trimmedID = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty else { continue }

            let dedupeKey = trimmedID.lowercased()
            guard seenModelIDs.insert(dedupeKey).inserted else { continue }

            let trimmedDisplayName = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedDisplayName = trimmedDisplayName.isEmpty ? trimmedID : trimmedDisplayName

            if trimmedID == model.id && normalizedDisplayName == model.displayName {
                sanitized.append(model)
            } else {
                sanitized.append(
                    ModelInfo(
                        id: trimmedID,
                        displayName: normalizedDisplayName,
                        provider: provider,
                        capabilities: model.capabilities,
                        supportedReasoningEfforts: model.supportedReasoningEfforts,
                        defaultReasoningEffort: model.defaultReasoningEffort,
                        updatedAt: model.updatedAt,
                        isFree: model.isFree
                    )
                )
            }
        }

        return sanitized
    }
    
    private func loadCacheFromDisk() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cacheDirectory.path) else { return }
        
        for provider in AIProvider.allCases {
            let cacheFile = cacheDirectory.appendingPathComponent("\(provider.rawValue).json")
            guard fm.fileExists(atPath: cacheFile.path) else { continue }
            
            do {
                let data = try Data(contentsOf: cacheFile)
                let wrapper = try JSONDecoder().decode(CacheWrapper.self, from: data)
                modelsByProvider[provider] = wrapper.models
                cacheTimestamps[provider] = wrapper.timestamp
            } catch {
                ReliabilityManager.shared.capture(
                    error: error,
                    feature: "model_catalog",
                    operation: "load_cache"
                )
                continue
            }
        }
    }
    
    private func saveCacheToDisk(provider: AIProvider, models: [ModelInfo]) {
        let fm = FileManager.default
        
        if !fm.fileExists(atPath: cacheDirectory.path) {
            try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        
        let cacheFile = cacheDirectory.appendingPathComponent("\(provider.rawValue).json")
        let wrapper = CacheWrapper(models: models, timestamp: Date())
        
        do {
            let data = try JSONEncoder().encode(wrapper)
            try data.write(to: cacheFile)
        } catch {
            ReliabilityManager.shared.capture(
                error: error,
                feature: "model_catalog",
                operation: "save_cache"
            )
            return
        }
    }

    private static func normalizeCapabilityTag(_ raw: String) -> String? {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizedCapabilityTags(from rawCapabilities: [String]?) -> [String]? {
        mergeCapabilityTags([rawCapabilities])
    }

    private func mergeCapabilityTags(_ groups: [[String]?]) -> [String]? {
        var tags = Set<String>()

        for group in groups {
            guard let group else { continue }
            for rawTag in group {
                guard let tag = Self.normalizeCapabilityTag(rawTag) else { continue }
                tags.insert(tag)

                if tag == "image_input" || tag == "input:image" || tag == "input:image_url" || tag == "vision" {
                    tags.insert("vision")
                    tags.insert("image")
                }
            }
        }

        return tags.isEmpty ? nil : tags.sorted()
    }

    private func decodeOpenAICompatibleModels(
        from data: Data,
        provider: AIProvider,
        usesCreatedTimestamp: Bool = true
    ) throws -> [ModelInfo] {
        let decoded = try JSONDecoder().decode(OpenAICompatibleModelsResponse.self, from: data)
        return decoded.data.map { model in
            ModelInfo(
                id: model.id,
                displayName: model.id,
                provider: provider,
                capabilities: mergeCapabilityTags([
                    model.modalities,
                    model.capabilities,
                    model.input_modalities,
                    model.input_modalities?.map { "input:\($0)" },
                    model.output_modalities,
                    model.output_modalities?.map { "output:\($0)" }
                ]),
                updatedAt: usesCreatedTimestamp
                    ? model.created.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
                    : Date()
            )
        }
    }

    private func anthropicCapabilityTags(from capabilities: [String: AnyAnthropicCapability]?) -> [String]? {
        guard let capabilities, !capabilities.isEmpty else { return nil }

        var tags = Set<String>()
        for (rawKey, value) in capabilities {
            guard let key = Self.normalizeCapabilityTag(rawKey) else { continue }
            if value.supported == true {
                tags.insert(key)
                if key == "image_input" {
                    tags.insert("vision")
                    tags.insert("image")
                }
            }
            if key == "image_input", value.supported == false {
                tags.insert("no_image_input")
            }
        }

        return tags.isEmpty ? nil : tags.sorted()
    }

    private func geminiCapabilityTags(modelId: String, supportedGenerationMethods: [String]?) -> [String]? {
        let loweredModelId = modelId.lowercased()
        var tags = Set<String>()

        if let supportedGenerationMethods {
            for method in supportedGenerationMethods {
                if let normalizedMethod = Self.normalizeCapabilityTag(method) {
                    tags.insert(normalizedMethod)
                }
            }
        }

        if loweredModelId.contains("embedding") {
            tags.insert("embedding")
            tags.insert("text_only")
        }

        if loweredModelId.contains("tts") || loweredModelId.contains("speech") {
            tags.insert("audio")
        }

        // Gemini model metadata doesn't expose explicit image-input modalities in this endpoint.
        // For generateContent models, Gemini docs indicate multimodal support by default.
        let appearsGenerativeGemini = loweredModelId.hasPrefix("gemini-") &&
            !loweredModelId.contains("embedding") &&
            !loweredModelId.contains("tts") &&
            !loweredModelId.contains("speech")
        if appearsGenerativeGemini,
           tags.contains("generatecontent") || tags.contains("generatemessage") {
            tags.insert("multimodal")
            tags.insert("vision")
            tags.insert("image")
            tags.insert("image_input")
        }

        return tags.isEmpty ? nil : tags.sorted()
    }

    private struct AnyAnthropicCapability: Decodable {
        let supported: Bool?
    }

    // MARK: - Vision Support

    /// Known models that support vision (multimodal)
    private static let knownVisionModels: Set<String> = [
        // OpenAI - GPT models
        "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano",
        "gpt-5.2", "gpt-5-mini", "gpt-5-nano", "gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-4-vision-preview",
        "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano",
        // OpenAI - Reasoning models with vision
        "o1", "o1-mini", "o1-preview", "o3", "o3-mini", "o4-mini",
        // Anthropic - Legacy naming
        "claude-3-5-sonnet-20241022", "claude-3-5-sonnet-latest", "claude-3-5-haiku-20241022",
        "claude-3-opus-20240229", "claude-3-sonnet-20240229", "claude-3-haiku-20240307",
        // Anthropic - New naming (claude-sonnet-4, claude-opus-4, etc.)
        "claude-sonnet-4", "claude-opus-4", "claude-haiku-4.5",
        "claude-sonnet-4.5", "claude-opus-4.5", "claude-sonnet-4.6", "claude-opus-4.6",
        "claude-sonnet-4-6", "claude-opus-4-6", "claude-haiku-4-5", "claude-haiku-4-5-20251001",
        // Gemini
        "gemini-3.1-pro-preview", "gemini-3-flash-preview", "gemini-3.1-flash-lite-preview", "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite",
        "gemini-3.1-pro", "gemini-3-flash", "gemini-3.1-flash-lite",
        "gemini-1.5-pro", "gemini-1.5-flash", "gemini-1.5-flash-8b", "gemini-2.0-flash-exp",
        "gemini-2.0-flash", "gemini-2.0-pro",
        // Groq
        "llama-3.2-11b-vision-preview", "llama-3.2-90b-vision-preview",
        "meta-llama/llama-4-scout-17b-16e-instruct", "llama-4-scout-17b-16e-instruct"
    ]

    /// Known model prefixes that support vision (for partial matching)
    private static let visionModelPrefixes: [String] = [
        // OpenAI GPT models
        "gpt-5", "gpt-4o", "gpt-4-turbo", "gpt-4-vision", "gpt-4.1",
        // OpenAI reasoning models with vision
        "o1", "o3", "o4",
        // Anthropic - Legacy naming
        "claude-3-5-sonnet", "claude-3-opus", "claude-3-sonnet", "claude-3-haiku", "claude-3.5", "claude-3.7",
        // Anthropic - New naming
        "claude-sonnet-4", "claude-opus-4", "claude-haiku-4", "claude-sonnet", "claude-opus",
        // Gemini
        "gemini-3", "gemini-2.5", "gemini-2.0", "gemini-1.5", "gemini-exp", "gemini-pro-vision",
        // Other
        "llama-3.2-11b-vision", "llama-3.2-90b-vision", "llama-4-scout", "llava", "phi-3-vision",
        "qwen3-vl", "qwen2.5vl", "llama3.2-vision"
    ]
    
    /// General vision keywords used across providers
    private static let visionKeywords: [String] = [
        "vision", "image", "multimodal", "omni", "vl", "mm"
    ]

    /// Models known to be text-only despite matching weak heuristics.
    private static let knownNonVisionModels: Set<String> = [
        "gemma-flash",
        "gemma-2-flash",
        "llama-3.3-70b-versatile",
        "llama-4-70b-versatile"
    ]

    /// Local/open-source model families commonly exposed through OpenAI-compatible endpoints.
    private static let openAICompatibleVisionKeywords: [String] = [
        "llava", "bakllava", "moondream", "minicpm", "glm-4v", "internvl", "cogvlm",
        "qwen-vl", "qwen2.5-vl", "qwen2.5vl", "qwen2-vl", "qwen3-vl", "llama3.2-vision",
        "vision", "image", "multimodal", "omni", "vl", "mm"
    ]

    /// OpenAI model families that are generally vision-capable when explicitly namespaced.
    private static let openAIVisionFamilies: [String] = [
        "gpt-5", "gpt-4o", "gpt-4.1", "gpt-4-turbo", "gpt-4-vision", "o1", "o3", "o4"
    ]

    /// Provider-scoped vision prefixes to avoid cross-provider capability assumptions.
    private static let providerVisionPrefixes: [AIProvider: [String]] = [
        .openAI: ["gpt-5", "gpt-4o", "gpt-4-turbo", "gpt-4-vision", "gpt-4.1", "o1", "o3", "o4"],
        .anthropic: ["claude-3-5-sonnet", "claude-3-opus", "claude-3-sonnet", "claude-3-haiku", "claude-3.5", "claude-3.7", "claude-sonnet-4", "claude-opus-4", "claude-haiku-4", "claude-sonnet", "claude-opus"],
        .gemini: ["gemini-3", "gemini-2.5", "gemini-2.0", "gemini-1.5", "gemini-exp", "gemini-pro-vision"],
        .groq: ["llama-3.2-11b-vision", "llama-3.2-90b-vision", "llama-4-scout"],
        .githubCopilot: ["gpt-5", "gpt-4o", "gpt-4-turbo", "gpt-4-vision", "gpt-4.1", "o1", "o3", "o4", "claude-3", "claude-sonnet", "claude-opus", "gemini"]
    ]
    
    /// Known vision-capable model families for GitHub Copilot
    private static let copilotVisionFamilies: [String] = [
        // OpenAI GPT models
        "gpt-5", "gpt-4o", "gpt-4-turbo", "gpt-4-vision", "gpt-4.1",
        // OpenAI reasoning models
        "o1", "o3", "o4",
        // Anthropic models (both old and new naming)
        "claude-3", "claude-sonnet", "claude-opus",
        // Google models
        "gemini"
    ]
    
    /// Try to determine vision support from model metadata capabilities
    private func checkModelMetadataForVision(modelId: String, provider: AIProvider) -> Bool? {
        guard let models = modelsByProvider[provider],
              let model = models.first(where: { $0.id.caseInsensitiveCompare(modelId) == .orderedSame }),
              let caps = model.capabilities else {
            return nil
        }

        let normalizedCaps = caps.compactMap { Self.normalizeCapabilityTag($0) }
        if normalizedCaps.isEmpty {
            return nil
        }

        let positiveSignals = [
            "vision", "multimodal", "input_image", "image_input", "input:image", "input:image_url"
        ]
        if normalizedCaps.contains(where: { positiveSignals.contains($0) }) {
            return true
        }

        let negativeSignals = ["no_image_input", "text-only", "text_only", "text->text"]
        if normalizedCaps.contains(where: { cap in
            negativeSignals.contains(where: { cap == $0 })
        }) {
            return false
        }

        let hasExplicitModalityMetadata = normalizedCaps.contains(where: { cap in
            cap.hasPrefix("input:") ||
            cap.hasPrefix("output:") ||
            cap.contains("->") ||
            cap == "completion" ||
            cap == "embedding" ||
            cap == "audio" ||
            cap == "text"
        })

        if hasExplicitModalityMetadata {
            let hasInputImage = normalizedCaps.contains(where: { cap in
                cap == "input:image" ||
                cap == "input:image_url" ||
                cap == "image_input"
            })
            if hasInputImage {
                return true
            }

            let hasOutputImageOnly = normalizedCaps.contains("output:image")
            if hasOutputImageOnly {
                return false
            }

            if normalizedCaps.contains("text") && !normalizedCaps.contains("image") {
                return false
            }
        }

        return nil
    }

    private func normalizedVisionCandidates(for modelId: String) -> [String] {
        let lowered = modelId.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowered.isEmpty else { return [] }

        var candidates: [String] = [lowered]

        if let slash = lowered.lastIndex(of: "/") {
            let namespacedBase = String(lowered[lowered.index(after: slash)...])
            if !namespacedBase.isEmpty {
                candidates.append(namespacedBase)
            }
        }

        if let colon = lowered.firstIndex(of: ":") {
            let withoutTag = String(lowered[..<colon])
            if !withoutTag.isEmpty {
                candidates.append(withoutTag)
            }
        }

        if let slash = lowered.lastIndex(of: "/") {
            let namespacedBase = String(lowered[lowered.index(after: slash)...])
            if let colon = namespacedBase.firstIndex(of: ":") {
                let namespacedWithoutTag = String(namespacedBase[..<colon])
                if !namespacedWithoutTag.isEmpty {
                    candidates.append(namespacedWithoutTag)
                }
            }
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func matchesKnownVisionModels(_ candidates: [String], provider: AIProvider) -> Bool {
        candidates.contains { candidate in
            guard Self.knownVisionModels.contains(candidate) else { return false }
            switch provider {
            case .openAI:
                return candidate.hasPrefix("gpt-") || candidate.hasPrefix("o1") || candidate.hasPrefix("o3") || candidate.hasPrefix("o4")
            case .anthropic:
                return candidate.hasPrefix("claude")
            case .gemini:
                return candidate.hasPrefix("gemini")
            case .groq:
                return candidate.contains("vision-preview") || candidate.contains("llama-4-scout")
            case .githubCopilot:
                return Self.copilotVisionFamilies.contains { family in candidate.contains(family.lowercased()) }
            default:
                return false
            }
        }
    }

    private func matchesProviderVisionPrefixes(_ candidates: [String], provider: AIProvider) -> Bool {
        guard let prefixes = Self.providerVisionPrefixes[provider] else { return false }
        return prefixes.contains { prefix in
            let normalizedPrefix = prefix.lowercased()
            return candidates.contains(where: { $0.hasPrefix(normalizedPrefix) || $0.contains(normalizedPrefix) })
        }
    }

    private func ensureNetworkAllowed(_ url: URL) throws {
        guard NetworkPrivacyPolicy.isRequestAllowed(url: url) else {
            throw ModelCatalogError.privacyModeBlocked
        }
    }

    /// Check if a specific model supports vision capabilities
    public func supportsVision(modelId: String, provider: AIProvider) -> Bool {
        // First check cached model capabilities metadata if available.
        // If metadata is explicit, treat it as authoritative.
        if let hasVision = checkModelMetadataForVision(modelId: modelId, provider: provider) {
            return hasVision
        }

        let candidates = normalizedVisionCandidates(for: modelId)
        guard !candidates.isEmpty else { return false }

        if candidates.contains(where: { Self.knownNonVisionModels.contains($0) }) {
            return false
        }

        // Only apply known-model and prefix heuristics within the same provider family.
        if matchesKnownVisionModels(candidates, provider: provider) {
            return true
        }

        if matchesProviderVisionPrefixes(candidates, provider: provider) {
            return true
        }

        if provider == .openAICompatible {
            let namespacedOpenAIVision = candidates.contains { candidate in
                candidate.hasPrefix("openai/") && Self.openAIVisionFamilies.contains { family in
                    candidate.contains(family)
                }
            }
            if namespacedOpenAIVision {
                return true
            }
        }

        let lowercaseId = candidates[0]

        // Provider-specific heuristics
        switch provider {
        case .githubCopilot:
            // GitHub Copilot exposes models from multiple providers (OpenAI, Anthropic, Google)
            // Check against known vision-capable model families
            for family in Self.copilotVisionFamilies {
                if lowercaseId.contains(family.lowercased()) {
                    return true
                }
            }
            // Check for vision keywords in model name
            return Self.visionKeywords.contains(where: { lowercaseId.contains($0) })
        case .ollama:
            // Ollama often uses models like 'llava', 'bakllava' for vision
            return Self.openAICompatibleVisionKeywords.contains { keyword in
                candidates.contains(where: { $0.contains(keyword) })
            }
        case .openAICompatible:
            // OpenAI-compatible endpoints frequently proxy local vision models.
            // Reuse both modern OpenAI-family and local-model keyword heuristics.
            return Self.openAICompatibleVisionKeywords.contains { keyword in
                candidates.contains(where: { $0.contains(keyword) })
            }
        case .gemini:
            return lowercaseId.contains("gemini") &&
                !lowercaseId.contains("embedding") &&
                !lowercaseId.contains("tts") &&
                !lowercaseId.contains("speech")
        case .openAI, .anthropic, .groq:
            return Self.visionKeywords.contains(where: { lowercaseId.contains($0) })
        case .openRouter:
            // OpenRouter often includes vision in the name or we can check the ID
            return Self.visionKeywords.contains(where: { lowercaseId.contains($0) })
        default:
            return false
        }
    }
}

private struct CacheWrapper: Codable {
    let models: [ModelInfo]
    let timestamp: Date
}

public enum ModelCatalogError: Error, LocalizedError {
    case invalidURL
    case fetchFailed
    case decodingFailed
    case privacyModeBlocked
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL for model API"
        case .fetchFailed: return "Failed to fetch models from provider"
        case .decodingFailed: return "Failed to decode model response"
        case .privacyModeBlocked: return NetworkPrivacyPolicy.blockedMessage
        }
    }
}
