import XCTest
@testable import SortyLib

final class SubscriptionAuthConfigurationTests: XCTestCase {
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
        XCTAssertFalse(AIProvider.githubCopilot.supportsSubscriptionAuth)
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
        XCTAssertEqual(AIProvider.githubCopilot.supportedAuthMethods, [.apiKey])
        XCTAssertEqual(AIProvider.appleFoundationModel.supportedAuthMethods, [.apiKey])
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
