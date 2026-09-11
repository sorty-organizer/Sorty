//
//  SettingsViewModel.swift
//  Sorty
//
//  Manages API configuration and settings
//

import Foundation
import Combine

/// UserDefaults supports concurrent reads. This wrapper makes that documented contract explicit
/// to Swift's Sendable checker without allowing background writes through the same reference.
final class UserDefaultsDataReader: @unchecked Sendable {
    private let userDefaults: UserDefaults

    init(_ userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    func data(forKey key: String) -> Data? {
        userDefaults.data(forKey: key)
    }

    func string(forKey key: String) -> String? {
        userDefaults.string(forKey: key)
    }

    func stringArray(forKey key: String) -> [String]? {
        userDefaults.stringArray(forKey: key)
    }
}

struct SettingsCredentialStore: Sendable {
    let load: @Sendable (String) async -> String?
    let save: @Sendable (String, String) async -> Bool
    let saveImmediately: @MainActor @Sendable (String, String) -> Bool
    let delete: @Sendable (String) async -> Bool

    static let keychain = SettingsCredentialStore(
        load: { await KeychainManager.getAsync(key: $0) },
        save: { await KeychainManager.saveAsync(key: $0, value: $1) },
        saveImmediately: { KeychainManager.save(key: $0, value: $1) },
        delete: { await KeychainManager.deleteAsync(key: $0) }
    )
}

@MainActor
public class SettingsViewModel: ObservableObject {
    @Published public var config: AIConfig = .default {
        didSet {
            guard !isApplyingConfigMutation else { return }

            let oldKey = oldValue.apiKey
            let newKey = config.apiKey
            let oldProvider = oldValue.provider
            let newProvider = config.provider
            let oldAuthMethod = oldValue.authMethod(for: oldProvider)
            let newAuthMethod = config.authMethod(for: newProvider)

            // Persist model changes immediately for the active provider.
            if oldProvider == newProvider, oldValue.model != config.model {
                userDefaults.set(config.model, forKey: modelSelectionKey(for: newProvider))
            }

            // Same provider, auth method switched — preserve API key and hydrate/clear in-memory field.
            if oldProvider == newProvider, oldAuthMethod != newAuthMethod {
                cancelCredentialHydration()

                if oldAuthMethod == .apiKey,
                   let oldKey = oldValue.apiKey,
                   !oldKey.isEmpty {
                    persistCredential(oldKey, for: newProvider)
                }

                if newAuthMethod == .apiKey {
                    hydrateStoredCredential(for: newProvider, authMethod: newAuthMethod)
                } else {
                    setInMemoryAPIKey(nil)
                }
            }

            // Debounce the save operation
            debouncedSave()

            // Invalidate cached URL sessions when timeout or API URL settings change
            // so the next request creates a fresh session with updated values
            if oldValue.requestTimeout != config.requestTimeout ||
               oldValue.resourceTimeout != config.resourceTimeout ||
               oldValue.apiURL != config.apiURL {
                AISessionManager.shared.invalidateAll()
            }

            // If smart rename is disabled, ensure mode is set to .organize
            if !config.enableSmartRename && config.mode != .organize {
                config.mode = .organize
            }

            // Provider switched — swap API keys via Keychain
            if oldProvider != newProvider {
                cancelCredentialHydration()

                // Save the old provider's selected model so it can be restored later
                userDefaults.set(oldValue.model, forKey: modelSelectionKey(for: oldProvider))

                // Save the old provider's API key to its keychain slot
                // Skip for GitHub Copilot — its token is managed by GitHubCopilotAuthManager
                if oldProvider != .githubCopilot,
                   oldAuthMethod == .apiKey,
                   let oldKey = oldValue.apiKey,
                   !oldKey.isEmpty {
                    persistCredential(oldKey, for: oldProvider)
                }

                // Load the new provider's API key from its keychain slot
                // Skip for GitHub Copilot — auth is handled by GitHubCopilotAuthManager, not apiKey
                isApplyingConfigMutation = true
                config.apiKey = nil
                config.apiURL = newProvider.defaultAPIURL
                config.requiresAPIKey = newProvider.typicallyRequiresAPIKey
                config.visionDetailLevel = VisionDetailLevel.defaultFor(provider: newProvider)
                config.model = userDefaults.string(forKey: modelSelectionKey(for: newProvider)) ?? newProvider.defaultModel
                isApplyingConfigMutation = false
                userDefaults.set(config.model, forKey: modelSelectionKey(for: newProvider))

                if newProvider != .githubCopilot,
                   newProvider.typicallyRequiresAPIKey,
                   newAuthMethod == .apiKey {
                    hydrateStoredCredential(for: newProvider, authMethod: newAuthMethod)
                }

                // Invalidate sessions for new provider URL
                AISessionManager.shared.invalidateAll()

                // Refresh model list for the new provider
                updateAvailableModels(force: true)

                // Auto-check connection after a short delay
                // For GitHub Copilot, skip apiKey check since auth is token-based
                providerConnectionTask?.cancel()
                let connectionConfig = config
                providerConnectionTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled,
                          let self,
                          self.config.provider == newProvider else { return }
                    if newProvider == .githubCopilot
                        || newProvider == .appleFoundationModel
                        || connectionConfig.apiKey != nil {
                        try? await self.testConnection(using: connectionConfig)
                    }
                    guard !Task.isCancelled, self.config.provider == newProvider else { return }
                    await AISessionManager.shared.prewarm(provider: newProvider, config: connectionConfig)
                }
            } else if oldKey != newKey,
                      newProvider.typicallyRequiresAPIKey,
                      newAuthMethod == .apiKey,
                      let newKey = newKey,
                      !newKey.isEmpty {
                cancelCredentialHydration()

                // Same provider, API key changed — save immediately to Keychain
                // so ModelCatalog reads the fresh key (fixes Gemini model list race)
                providerConnectionTask?.cancel()
                let connectionConfig = config
                providerConnectionTask = Task { [weak self, credentialStore] in
                    _ = await credentialStore.save(newProvider.keychainKey, newKey)
                    guard !Task.isCancelled,
                          let self,
                          self.config.provider == newProvider,
                          self.config.apiKey == connectionConfig.apiKey else { return }
                    self.updateAvailableModels(force: true)
                    await AISessionManager.shared.prewarm(provider: newProvider, config: connectionConfig)
                }
            }
        }
    }
    
    @Published public var isAppleModelAvailable: Bool = false
    @Published public var appleModelStatus: String = ""
    @Published public var availableModels: [String] = []
    @Published public var isLoadingModels: Bool = false
    @Published public private(set) var hasLoadedPersistedState = false
    @Published public private(set) var isConfiguredCredentialHydrating = false
    
    private let userDefaults: UserDefaults
    private let persistedDataReader: UserDefaultsDataReader
    private let credentialStore: SettingsCredentialStore
    private let configKey = "aiConfig"
    private let disableStoredCredentialsForUITestsKey = "uitestDisableStoredProviderCredentials"
    private let providerHealthCheckModeForUITestsKey = "uitestProviderHealthCheckMode"
    private let providerHealthCheckFailedOnceForUITestsKey = "uitestProviderHealthCheckFailedOnce"
    private var saveTask: Task<Void, Never>?
    private var credentialTask: Task<Void, Never>?
    private var modelRefreshTask: Task<Void, Never>?
    private var providerConnectionTask: Task<Void, Never>?
    private var credentialHydrationID: UUID?
    private var credentialHydrationProvider: AIProvider?
    private var persistedStateLoadTask: Task<AIConfig?, Never>?
    private var persistedStateLoadGeneration = 0
    private var isApplyingConfigMutation = false

    private func modelSelectionKey(for provider: AIProvider) -> String {
        "lastSelectedModel_\(provider.rawValue)"
    }
    
    public init() {
        userDefaults = .standard
        persistedDataReader = UserDefaultsDataReader(.standard)
        credentialStore = .keychain
        setupNotificationObservers()
    }

    init(
        userDefaults: UserDefaults,
        credentialStore: SettingsCredentialStore,
        observesNotifications: Bool = true
    ) {
        self.userDefaults = userDefaults
        self.persistedDataReader = UserDefaultsDataReader(userDefaults)
        self.credentialStore = credentialStore
        if observesNotifications {
            setupNotificationObservers()
        }
    }
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addMainActorObserver(forName: .clearAllUsageData, object: nil, queue: .main) { [weak self] in
            self?.reset()
        }
    }
    
    /// Loads settings without blocking app construction or the first SwiftUI window.
    public func loadPersistedState() async {
        guard !hasLoadedPersistedState else { return }

        let generation = persistedStateLoadGeneration
        let task: Task<AIConfig?, Never>
        if let persistedStateLoadTask {
            task = persistedStateLoadTask
        } else {
            let persistedDataReader = persistedDataReader
            let configKey = configKey
            task = Task.detached(priority: .userInitiated) {
                guard let data = persistedDataReader.data(forKey: configKey) else { return nil }
                return try? JSONDecoder().decode(AIConfig.self, from: data)
            }
            persistedStateLoadTask = task
        }

        let decodedConfig = await task.value
        guard !hasLoadedPersistedState,
              generation == persistedStateLoadGeneration else {
            return
        }

        if var decoded = decodedConfig {
            decoded.apiKey = nil
            decoded.enableSmartRename = true
            decoded.enableFileTagging = true
            isApplyingConfigMutation = true
            config = decoded
            isApplyingConfigMutation = false
        }

        hasLoadedPersistedState = true
        persistedStateLoadTask = nil
        checkAppleModelAvailability()
        hydrateConfiguredCredentialIfNeeded()
    }

    private func hydrateConfiguredCredentialIfNeeded() {
        let provider = config.provider
        let authMethod = config.authMethod(for: provider)
        guard !userDefaults.bool(forKey: disableStoredCredentialsForUITestsKey),
              provider != .githubCopilot,
              provider.typicallyRequiresAPIKey,
              authMethod == .apiKey else { return }
        hydrateStoredCredential(for: provider, authMethod: authMethod, migratesLegacyKey: true)
    }

    private func setInMemoryAPIKey(_ apiKey: String?) {
        isApplyingConfigMutation = true
        config.apiKey = apiKey
        isApplyingConfigMutation = false
    }

    public func updateAPIKey(_ value: String) {
        let apiKey = value.isEmpty ? nil : value
        config.apiKey = apiKey

        guard let apiKey,
              config.provider != .githubCopilot,
              config.provider.typicallyRequiresAPIKey,
              config.authMethod(for: config.provider) == .apiKey else { return }

        _ = credentialStore.saveImmediately(config.provider.keychainKey, apiKey)
    }

    private func persistCredential(_ apiKey: String, for provider: AIProvider) {
        Task { [credentialStore] in
            _ = await credentialStore.save(provider.keychainKey, apiKey)
        }
    }

    private func hydrateStoredCredential(
        for provider: AIProvider,
        authMethod: ProviderAuthMethod,
        migratesLegacyKey: Bool = false
    ) {
        cancelCredentialHydration()
        isConfiguredCredentialHydrating = true
        let hydrationID = UUID()
        credentialHydrationID = hydrationID
        credentialHydrationProvider = provider
        credentialTask = Task { [weak self, credentialStore] in
            if migratesLegacyKey,
               let oldAPIKey = await credentialStore.load("apiKey"),
               await credentialStore.load(provider.keychainKey) == nil {
                _ = await credentialStore.save(provider.keychainKey, oldAPIKey)
            }

            guard !Task.isCancelled else { return }
            let apiKey = await credentialStore.load(provider.keychainKey)
            guard !Task.isCancelled,
                  let self,
                  self.credentialHydrationID == hydrationID else { return }
            self.credentialTask = nil
            self.credentialHydrationID = nil
            self.credentialHydrationProvider = nil
            guard self.config.provider == provider,
                  self.config.authMethod(for: provider) == authMethod else {
                self.isConfiguredCredentialHydrating = false
                return
            }
            self.setInMemoryAPIKey(apiKey)
            self.isConfiguredCredentialHydrating = false
        }
    }

    private func cancelCredentialHydration() {
        credentialTask?.cancel()
        credentialTask = nil
        credentialHydrationID = nil
        credentialHydrationProvider = nil
        isConfiguredCredentialHydrating = false
    }
    
    /// Debounced save that batches rapid changes
    private func debouncedSave() {
        // Cancel any existing save task
        saveTask?.cancel()
        
        // Create new delayed save task
        saveTask = Task { @MainActor in
            // Wait 0.5 seconds before saving
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            // Only save if task wasn't cancelled
            guard !Task.isCancelled else { return }
            
            await performSave()
        }
    }
    
    /// Synchronous save for app termination. macOS does not wait for unstructured
    /// tasks started from `willTerminate`, so this path must finish before returning.
    public func forceSave() {
        guard hasLoadedPersistedState else { return }
        saveTask?.cancel()
        let apiKey = config.apiKey
        let provider = config.provider
        var configToSave = config
        configToSave.apiKey = nil

        if provider != .githubCopilot,
           provider.typicallyRequiresAPIKey,
           config.authMethod(for: provider) == .apiKey {
            if let apiKey {
                _ = credentialStore.saveImmediately(provider.keychainKey, apiKey)
            } else if credentialHydrationProvider != provider {
                Task { [credentialStore] in
                    _ = await credentialStore.delete(provider.keychainKey)
                }
            }
        }

        if let encoded = try? JSONEncoder().encode(configToSave) {
            userDefaults.set(encoded, forKey: configKey)
        }
    }
    
    private func performSave() async {
        guard hasLoadedPersistedState else { return }
        // Capture values for thread-safe access
        let apiKey = config.apiKey
        let provider = config.provider
        var configToSave = config
        configToSave.apiKey = nil // Don't store in UserDefaults
        let configData = try? JSONEncoder().encode(configToSave)
        
        DebugLogger.log(hypothesisId: "B", location: "SettingsViewModel", message: "Saving config (debounced)", data: [
            "hasAPIKey": apiKey != nil,
            "provider": provider.rawValue
        ])
        
        // Save API key to provider-specific Keychain key
        if provider != .githubCopilot,
           provider.typicallyRequiresAPIKey,
           config.authMethod(for: provider) == .apiKey {
            let providerKey = provider.keychainKey
            if let apiKey = apiKey {
                _ = await credentialStore.save(providerKey, apiKey)
            } else if credentialHydrationProvider != provider {
                _ = await credentialStore.delete(providerKey)
            }
        }
        
        // Save config to UserDefaults
        if let encoded = configData {
            userDefaults.set(encoded, forKey: configKey)
        }
    }
    
    private func checkAppleModelAvailability() {
        let availability: Bool
        let status: String

        #if canImport(FoundationModels) && os(macOS)
        if #available(macOS 26.0, *) {
            availability = AppleFoundationModelClient.isAvailable()
            status = AppleFoundationModelClient.unavailabilityReason
        } else {
            availability = false
            status = "Apple Intelligence requires macOS 26.0 or later."
        }
        #else
        availability = false
        status = "Apple Intelligence is not supported on this version of macOS."
        #endif

        if isAppleModelAvailable != availability {
            isAppleModelAvailable = availability
        }
        if appleModelStatus != status {
            appleModelStatus = status
        }
    }

    public func refreshAppleModelStatus() {
        checkAppleModelAvailability()
    }
    
    public func testConnection() async throws {
        try await testConnection(using: config)
    }

    private func testConnection(using clientConfig: AIConfig) async throws {
        if let uiTestOverride = userDefaults.string(forKey: providerHealthCheckModeForUITestsKey) {
            switch uiTestOverride {
            case "always_succeed":
                return
            case "always_fail":
                throw AIClientError.apiError(statusCode: 503, message: "UI test forced provider health-check failure.")
            case "fail_once_then_succeed":
                if !userDefaults.bool(forKey: providerHealthCheckFailedOnceForUITestsKey) {
                    userDefaults.set(true, forKey: providerHealthCheckFailedOnceForUITestsKey)
                    throw AIClientError.apiError(statusCode: 503, message: "UI test forced provider health-check failure.")
                }
                return
            default:
                break
            }
        }

        // Client creation resolves credentials (sync Keychain reads) and health checks
        // touch the network — keep both off the main actor so provider switches never hitch.
        let healthTask = Task.detached(priority: .userInitiated) {
            let client = try AIClientFactory.createClient(config: clientConfig)
            try await client.checkHealth()
        }
        try await withTaskCancellationHandler {
            try await healthTask.value
        } onCancel: {
            healthTask.cancel()
        }
    }
    
    public func updateAvailableModels(force: Bool = false) {
        modelRefreshTask?.cancel()
        let provider = config.provider
        if !isLoadingModels {
            isLoadingModels = true
        }

        modelRefreshTask = Task { [weak self] in
            guard let self else { return }
            let loadStartedAt = Date()
            await ModelCatalog.shared.refresh(
                provider: provider,
                force: force,
                authMethod: self.config.authMethod(for: provider)
            )
            guard !Task.isCancelled, self.config.provider == provider else { return }

            let catalogModels = ModelCatalog.shared.cachedModels(for: provider)
            let resolvedModels = catalogModels.isEmpty
                ? provider.recommendedModels
                : catalogModels.map(\.id)

            if self.availableModels != resolvedModels {
                self.availableModels = resolvedModels
            }
            let isKnownCodexModel = provider == .openAI
                && ProviderAuthResolver.effectiveAuthMethod(for: .openAI, config: self.config) == .accountSignIn
                && ModelCatalog.shared.isCodexSubscriptionModel(self.config.model)
            if !resolvedModels.isEmpty, !isKnownCodexModel, !resolvedModels.contains(self.config.model) {
                self.config.model = resolvedModels.first ?? provider.defaultModel
            }
            self.isLoadingModels = false
            AnalyticsManager.shared.captureWorkflow(
                workflow: "model_catalog",
                stage: "loaded",
                outcome: catalogModels.isEmpty ? "fallback" : "success",
                properties: AnalyticsManager.durationProperties(
                    Date().timeIntervalSince(loadStartedAt)
                ).merging(["source": "settings"]) { current, _ in current }
            )
        }
    }

    public func reset() {
        providerConnectionTask?.cancel()
        providerConnectionTask = nil
        persistedStateLoadGeneration &+= 1
        persistedStateLoadTask?.cancel()
        persistedStateLoadTask = nil
        hasLoadedPersistedState = true

        // Clear per-provider saved model selections
        for provider in AIProvider.allCases {
            userDefaults.removeObject(forKey: modelSelectionKey(for: provider))
        }
        config = .default
        availableModels = config.provider.recommendedModels
        // No need to save manually here as config.didSet will trigger debouncedSave,
        // but since we want to clear from UserDefaults, we already handled it in AppState.
    }
}
