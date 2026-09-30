import XCTest
@testable import SortyLib
@testable import SortyCore
@testable import SortyAI
@testable import SortyModels

final class SubscriptionAuthConfigurationTests: XCTestCase {
    func testOpenCodeRequestCredentialsHonorSourceAndRotation() async throws {
        let previousContent = ProcessInfo.processInfo.environment["OPENCODE_AUTH_CONTENT"]
        let previousStore = AIKeychain.shared
        let disableKey = "uitestDisableStoredProviderCredentials"
        let previousDisabled = UserDefaults.standard.object(forKey: disableKey)
        AIKeychain.shared = EphemeralAIKeychainStore()
        UserDefaults.standard.set(false, forKey: disableKey)
        ProviderAuthResolver.invalidateCredentialCache()
        defer {
            if let previousContent {
                setenv("OPENCODE_AUTH_CONTENT", previousContent, 1)
            } else {
                unsetenv("OPENCODE_AUTH_CONTENT")
            }
            AIKeychain.shared = previousStore
            if let previousDisabled {
                UserDefaults.standard.set(previousDisabled, forKey: disableKey)
            } else {
                UserDefaults.standard.removeObject(forKey: disableKey)
            }
            ProviderAuthResolver.invalidateCredentialCache()
        }

        for provider in [AIProvider.openCodeZen, .openCodeGo] {
            let plan = provider == .openCodeZen ? "opencode" : "opencode-go"
            setenv("OPENCODE_AUTH_CONTENT", "{\"\(plan)\":{\"type\":\"api\",\"key\":\"connected-key\"}}", 1)
            var config = AIConfig(provider: provider)
            XCTAssertEqual(ProviderAuthResolver.authHeader(for: provider, config: config)?.value, "Bearer connected-key")
            let automatic = await ProviderAuthResolver.credentialAsync(for: provider, method: .apiKey, config: config)
            XCTAssertEqual(automatic, "connected-key")

            _ = await AIKeychain.shared.saveAsync(key: provider.keychainKey, value: "manual-key")
            ProviderAuthResolver.invalidateCredentialCache(for: provider)
            XCTAssertEqual(ProviderAuthResolver.authHeader(for: provider, config: config)?.value, "Bearer manual-key")

            config.openCodeAuthSources[provider.rawValue] = .connected
            config.apiKey = "stale-in-memory-key"
            let connected = await ProviderAuthResolver.credentialAsync(for: provider, method: .apiKey, config: config)
            XCTAssertEqual(connected, "connected-key")
            setenv("OPENCODE_AUTH_CONTENT", "{\"\(plan)\":{\"type\":\"api\",\"key\":\"rotated-key\"}}", 1)
            XCTAssertEqual(ProviderAuthResolver.authHeader(for: provider, config: config)?.value, "Bearer rotated-key")
            setenv("OPENCODE_AUTH_CONTENT", "{\"\(plan)\":{\"type\":\"api\",\"key\":\"\"}}", 1)
            XCTAssertNil(ProviderAuthResolver.authHeader(for: provider, config: config))

            config.openCodeAuthSources[provider.rawValue] = .apiKey
            config.apiKey = nil
            XCTAssertEqual(ProviderAuthResolver.authHeader(for: provider, config: config)?.value, "Bearer manual-key")
        }
    }

    func testOpenCodeSetupValidationUsesHydratedCredentialSnapshot() {
        for provider in [AIProvider.openCodeZen, .openCodeGo] {
            var config = AIConfig(provider: provider)
            config.openCodeAuthSources[provider.rawValue] = .connected
            config.apiKey = "hydrated-key"
            func status(_ config: AIConfig) -> ProviderSetupStatus {
                OnboardingSetupValidator.providerStatus(context: ProviderSetupContext(
                    config: config, isCodexAuthenticated: false, isCodexInstalled: false,
                    isAppleFoundationModelAvailable: false
                ))
            }
            XCTAssertTrue(status(config).isReady)
            config.apiKey = "  "
            XCTAssertFalse(status(config).isReady)
        }
    }

    func testOpenCodeImportSeparatesPlansAndPrefersStoredAPIKeys() throws {
        let data = Data(#"{"opencode":{"type":"api","key":" zen-key\n"},"opencode-go":{"type":"api","key":"go-key"},"openai":{"type":"oauth","access":"upstream-token"}}"#.utf8)
        let environment = ["OPENCODE_API_KEY": "environment-key"]
        XCTAssertEqual(try OpenCodeCredentials.apiKey(for: .openCodeZen, data: data, environment: environment), "zen-key")
        XCTAssertEqual(try OpenCodeCredentials.apiKey(for: .openCodeGo, data: data, environment: environment), "go-key")
        let zenOnly = Data(#"{"opencode":{"type":"api","key":"zen-key"}}"#.utf8)
        XCTAssertThrowsError(try OpenCodeCredentials.apiKey(for: .openCodeGo, data: zenOnly, environment: [:]))
        XCTAssertEqual(try OpenCodeCredentials.apiKey(for: .openCodeGo, data: zenOnly, environment: environment), "environment-key")
    }

    func testOpenCodeImportRejectsOAuthEmptyKeysAndMalformedJSON() {
        for content in [
            #"{"opencode":{"type":"oauth","access":"never-import","refresh":"refresh"}}"#,
            #"{"opencode":{"type":"wellknown","key":"never-import","token":"token"}}"#,
            #"{"opencode":{"type":"api","key":"  "}}"#,
            "not json", "[]"
        ] {
            XCTAssertThrowsError(try OpenCodeCredentials.apiKey(for: .openCodeZen, data: Data(content.utf8), environment: [:]))
        }
        XCTAssertThrowsError(try OpenCodeCredentials.apiKey(for: .openAI, data: Data("{}".utf8), environment: ["OPENCODE_API_KEY": "key"]))
    }

    func testOpenCodeImportUsesXDGPathAndAuthContentOverride() throws {
        let home = URL(fileURLWithPath: "/tmp/opencode-test-home", isDirectory: true)
        XCTAssertEqual(OpenCodeCredentials.authFileURL(environment: [:], homeDirectory: home).path,
                       "/tmp/opencode-test-home/.local/share/opencode/auth.json")
        XCTAssertEqual(OpenCodeCredentials.authFileURL(environment: ["XDG_DATA_HOME": "/tmp/custom-data"], homeDirectory: home).path,
                       "/tmp/custom-data/opencode/auth.json")
        XCTAssertEqual(try OpenCodeCredentials.loadAPIKey(for: .openCodeGo, environment: [
            "OPENCODE_AUTH_CONTENT": #"{"opencode-go":{"type":"api","key":"override-key"}}"#
        ], homeDirectory: home), "override-key")
    }

    func testOpenCodeImportReadsFileAndUsesEnvironmentWhenFileIsMissing() throws {
        let dataHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dataHome) }
        let environment = ["XDG_DATA_HOME": dataHome.path, "OPENCODE_API_KEY": "environment-key"]
        let file = OpenCodeCredentials.authFileURL(environment: environment, homeDirectory: dataHome)
        XCTAssertEqual(try OpenCodeCredentials.loadAPIKey(for: .openCodeZen, environment: environment, homeDirectory: dataHome), "environment-key")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"opencode":{"type":"api","key":"file-key"}}"#.utf8).write(to: file)
        XCTAssertEqual(try OpenCodeCredentials.loadAPIKey(for: .openCodeZen, environment: environment, homeDirectory: dataHome), "file-key")
        XCTAssertThrowsError(try OpenCodeCredentials.loadAPIKey(for: .openCodeZen, environment: [
            "XDG_DATA_HOME": dataHome.path, "OPENCODE_AUTH_CONTENT": "invalid"
        ], homeDirectory: dataHome))
    }

    func testOpenCodeCredentialSourceSurvivesRestartWithoutStoringSecret() throws {
        var config = AIConfig(provider: .openCodeGo)
        config.openCodeAuthSources[AIProvider.openCodeGo.rawValue] = .connected
        let data = try JSONEncoder().encode(config)
        let restored = try JSONDecoder().decode(AIConfig.self, from: data)
        XCTAssertNil(restored.apiKey)
        XCTAssertTrue(restored.usesConnectedOpenCodeCredentials(for: .openCodeGo))
        XCTAssertFalse(restored.usesConnectedOpenCodeCredentials(for: .openCodeZen))
        let legacy = try JSONDecoder().decode(AIConfig.self, from: Data(#"{"provider":"opencode_go"}"#.utf8))
        XCTAssertEqual(legacy.openCodeAuthSource(for: .openCodeGo), .automatic)
    }

    func testLiveOpenCodeCredentialsFollowRotationAndRevocation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = ["XDG_DATA_HOME": directory.path]
        let file = OpenCodeCredentials.authFileURL(environment: environment, homeDirectory: directory)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for key in ["first-key", "rotated-key"] {
            let data = try JSONSerialization.data(withJSONObject: ["opencode-go": ["type": "api", "key": key]])
            try data.write(to: file)
            XCTAssertEqual(try OpenCodeCredentials.loadAPIKey(for: .openCodeGo, environment: environment, homeDirectory: directory), key)
        }
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try OpenCodeCredentials.loadAPIKey(for: .openCodeGo, environment: environment, homeDirectory: directory))
    }

    func testCodexLoginScriptQuotesExecutablePathForShell() {
        let quoted = CodexCLIAuthManager.shellQuoted("/tmp/codex '$HOME'; touch /tmp/pwn")

        XCTAssertEqual(quoted, "'/tmp/codex '\\''$HOME'\\''; touch /tmp/pwn'")
    }

    func testProviderAuthMethodDisplayNames() {
        XCTAssertEqual(ProviderAuthMethod.apiKey.displayName, "API Key")
        XCTAssertEqual(ProviderAuthMethod.accountSignIn.displayName, "Codex CLI (Subscription)")
        XCTAssertEqual(ProviderAuthMethod.manualSessionToken.displayName, "API Key")
    }

    func testSubscriptionProductNames() {
        XCTAssertEqual(AIProvider.openAI.subscriptionProductName, "ChatGPT")
        XCTAssertEqual(AIProvider.anthropic.subscriptionProductName, AIProvider.anthropic.displayName)
        XCTAssertEqual(AIProvider.groq.subscriptionProductName, AIProvider.groq.displayName)
    }

    func testSupportedSubscriptionProviders() {
        XCTAssertTrue(AIProvider.openAI.supportsSubscriptionAuth)
        XCTAssertFalse(AIProvider.anthropic.supportsSubscriptionAuth)
        XCTAssertFalse(AIProvider.openCodeZen.supportsSubscriptionAuth)
        XCTAssertFalse(AIProvider.openRouter.supportsSubscriptionAuth)
    }

    func testSupportedAuthMethodsForSubscriptionProviders() {
        XCTAssertEqual(
            AIProvider.openAI.supportedAuthMethods,
            [.apiKey, .accountSignIn]
        )
    }

    func testSupportedAuthMethodsForNonSubscriptionProviders() {
        XCTAssertEqual(AIProvider.groq.supportedAuthMethods, [.apiKey])
        XCTAssertEqual(AIProvider.openCodeZen.supportedAuthMethods, [.apiKey])
        XCTAssertEqual(AIProvider.openCodeGo.supportedAuthMethods, [.apiKey])
        XCTAssertEqual(AIProvider.appleFoundationModel.supportedAuthMethods, [.apiKey])
    }

    func testOpenCodePlansUseSeparateKeysAndEndpoints() throws {
        let zen = AIProvider.openCodeZen
        let go = AIProvider.openCodeGo
        XCTAssertNotEqual(zen.keychainKey, go.keychainKey)
        XCTAssertEqual(zen.defaultAPIURL, "https://opencode.ai/zen/v1")
        XCTAssertEqual(go.defaultAPIURL, "https://opencode.ai/zen/go/v1")

        for provider in [zen, go] {
            let config = AIConfig(
                provider: provider,
                apiURL: provider.defaultAPIURL,
                apiKey: "test-key",
                model: provider.defaultModel
            )
            let url = try AIRequestSupport.openAIChatCompletionsURL(from: config.apiURL!)
            XCTAssertEqual(url.absoluteString, provider.defaultAPIURL! + "/chat/completions")
            XCTAssertEqual(ProviderAuthResolver.authHeader(for: provider, config: config)?.value, "Bearer test-key")
            XCTAssertTrue(try AIClientFactory.createClient(config: config) is OpenAIClient)
        }
    }

    func testRemovedCopilotSelectionUsesChosenAutomationModel() throws {
        let data = Data(#"{"provider":"github_copilot","apiURL":"https://api.githubcopilot.com","model":"gpt-5-mini","enableDeepScan":false,"automationProvider":"opencode_go","automationModel":"glm-5.3"}"#.utf8)
        let config = try JSONDecoder().decode(AIConfig.self, from: data)

        XCTAssertEqual(config.provider, .openCodeGo)
        XCTAssertEqual(config.apiURL, AIProvider.openCodeGo.defaultAPIURL)
        XCTAssertEqual(config.model, "glm-5.3")
        XCTAssertFalse(config.enableDeepScan)
        XCTAssertEqual(config.automationProvider, .openCodeGo)
        XCTAssertEqual(config.automationModel, "glm-5.3")
    }

    func testRemovedCopilotWithoutAutomationSelectionRequiresRepair() throws {
        let data = Data(#"{"provider":"github_copilot","automationProvider":"github_copilot","automationModel":"gpt-5-mini"}"#.utf8)
        let config = try JSONDecoder().decode(AIConfig.self, from: data)

        XCTAssertEqual(config.provider, .unavailableProvider)
        XCTAssertEqual(config.model, "")
        XCTAssertEqual(config.automationProvider, .unavailableProvider)
        let status = OnboardingSetupValidator.providerStatus(
            context: ProviderSetupContext(
                config: config,
                isCodexAuthenticated: false,
                isCodexInstalled: false,
                isAppleFoundationModelAvailable: false
            )
        )
        XCTAssertFalse(status.isReady)
        XCTAssertTrue(status.message.contains("GitHub Copilot was removed"))
    }

    func testAIConfigDefaultAuthMethods() {
        let config = AIConfig.default

        XCTAssertEqual(config.openAIAuthMethod, .apiKey)
        XCTAssertEqual(config.anthropicAuthMethod, .apiKey)
        XCTAssertEqual(config.authMethod(for: .openAI), .apiKey)
        XCTAssertEqual(config.authMethod(for: .anthropic), .apiKey)
    }

    func testAIConfigSetAuthMethodPerProvider() {
        var config = AIConfig.default

        config.setAuthMethod(.manualSessionToken, for: .openAI)
        XCTAssertEqual(config.authMethod(for: .openAI), .manualSessionToken)
        XCTAssertEqual(config.authMethod(for: .anthropic), .apiKey)

        config.setAuthMethod(.accountSignIn, for: .anthropic)
        XCTAssertEqual(config.authMethod(for: .openAI), .manualSessionToken)
        XCTAssertEqual(config.authMethod(for: .anthropic), .accountSignIn)
    }

    func testSubscriptionAuthenticationUsesCodexClient() throws {
        var config = AIConfig.default
        config.provider = .openAI
        config.setAuthMethod(.accountSignIn, for: .openAI)

        let client = try AIClientFactory.createClient(config: config)

        XCTAssertTrue(client is CodexSubscriptionClient)
    }

    func testChangingProviderClearsInMemoryAPIKey() {
        var config = AIConfig(
            provider: .openRouter,
            apiKey: "openrouter-secret",
            model: AIProvider.openRouter.defaultModel
        )

        config.provider = .ollama

        XCTAssertNil(config.apiKey)
    }

    func testAIConfigAuthMethodsAreCodable() throws {
        var config = AIConfig.default
        config.setAuthMethod(.accountSignIn, for: .openAI)
        config.setAuthMethod(.manualSessionToken, for: .anthropic)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AIConfig.self, from: data)

        XCTAssertEqual(decoded.authMethod(for: .openAI), .accountSignIn)
        XCTAssertEqual(decoded.authMethod(for: .anthropic), .manualSessionToken)
    }

    func testReasoningEffortIsRememberedPerProviderAndModel() throws {
        var config = AIConfig(provider: .openAI, model: "gpt-5.4-mini")
        config.setReasoningEffort(.high)
        config.model = "gpt-5.4"
        config.setReasoningEffort(.low)

        let data = try JSONEncoder().encode(config)
        var decoded = try JSONDecoder().decode(AIConfig.self, from: data)

        XCTAssertEqual(decoded.reasoningEffort, .low)
        decoded.model = "gpt-5.4-mini"
        XCTAssertEqual(decoded.reasoningEffort, .high)
        decoded.provider = .gemini
        decoded.model = "gemini-3-flash"
        XCTAssertEqual(decoded.reasoningEffort, .automatic)
    }

    func testReasoningEffortAcceptsProviderDefinedLevels() throws {
        let providerLevel = ReasoningEffort(rawValue: "extreme")
        let data = try JSONEncoder().encode(providerLevel)

        XCTAssertEqual(try JSONDecoder().decode(ReasoningEffort.self, from: data), providerLevel)
        XCTAssertEqual(providerLevel.requestValue, "extreme")
        XCTAssertEqual(providerLevel.displayName, "Extreme")
    }

    func testProviderAuthResolverUsesConfigApiKeyWhenPresent() {
        let config = AIConfig(
            provider: .openAI,
            apiURL: AIProvider.openAI.defaultAPIURL,
            apiKey: "test-openai-key",
            model: AIProvider.openAI.defaultModel,
            requiresAPIKey: true
        )

        let header = ProviderAuthResolver.authHeader(for: .openAI, config: config)

        XCTAssertEqual(header?.field, "Authorization")
        XCTAssertEqual(header?.value, "Bearer test-openai-key")
        XCTAssertTrue(ProviderAuthResolver.hasRequiredCredential(for: .openAI, config: config))
    }

    func testProviderAuthResolverDoesNotExposeHeaderForOpenAIAccountSignIn() {
        var config = AIConfig(
            provider: .openAI,
            apiURL: AIProvider.openAI.defaultAPIURL,
            apiKey: "should-not-be-used",
            model: AIProvider.openAI.defaultModel,
            requiresAPIKey: true
        )
        config.setAuthMethod(.accountSignIn, for: .openAI)

        XCTAssertNil(ProviderAuthResolver.authHeader(for: .openAI, config: config))
    }

    func testProviderAuthResolverRequiresCredentialWhenConfigured() {
        let config = AIConfig(
            provider: .openAI,
            apiURL: AIProvider.openAI.defaultAPIURL,
            apiKey: nil,
            model: AIProvider.openAI.defaultModel,
            requiresAPIKey: true
        )

        XCTAssertFalse(ProviderAuthResolver.hasRequiredCredential(for: .openAI, config: config))
    }

    func testProviderAuthResolverAllowsNoCredentialWhenNotRequired() {
        let config = AIConfig(
            provider: .ollama,
            apiURL: AIProvider.ollama.defaultAPIURL,
            apiKey: nil,
            model: AIProvider.ollama.defaultModel,
            requiresAPIKey: false
        )

        XCTAssertTrue(ProviderAuthResolver.hasRequiredCredential(for: .ollama, config: config))
    }
}
