import Foundation

public struct ProviderSetupContext: Sendable {
    public let config: AIConfig
    public let isCodexAuthenticated: Bool
    public let isCodexInstalled: Bool
    public let isAppleFoundationModelAvailable: Bool
    public let appleFoundationModelStatus: String?

    public init(
        config: AIConfig,
        isCodexAuthenticated: Bool,
        isCodexInstalled: Bool,
        isAppleFoundationModelAvailable: Bool,
        appleFoundationModelStatus: String? = nil
    ) {
        self.config = config
        self.isCodexAuthenticated = isCodexAuthenticated
        self.isCodexInstalled = isCodexInstalled
        self.isAppleFoundationModelAvailable = isAppleFoundationModelAvailable
        self.appleFoundationModelStatus = appleFoundationModelStatus
    }
}

public struct ProviderSetupStatus: Equatable, Sendable {
    public let isReady: Bool
    public let title: String
    public let message: String
    public let recoverySuggestion: String?

    public init(
        isReady: Bool,
        title: String,
        message: String,
        recoverySuggestion: String? = nil
    ) {
        self.isReady = isReady
        self.title = title
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }
}

public enum OnboardingSetupValidator {
    public static func providerStatus(context: ProviderSetupContext) -> ProviderSetupStatus {
        let provider = context.config.provider

        if provider == .unavailableProvider {
            return ProviderSetupStatus(
                isReady: false,
                title: "Provider unavailable",
                message: "GitHub Copilot was removed. Choose an AI provider before organizing files.",
                recoverySuggestion: "Select a provider and model, then add its credentials if needed."
            )
        }

        if provider == .appleFoundationModel {
            guard context.isAppleFoundationModelAvailable else {
                return ProviderSetupStatus(
                    isReady: false,
                    title: "Apple Intelligence unavailable",
                    message: context.appleFoundationModelStatus ?? "Apple Foundation Model is not available on this Mac.",
                    recoverySuggestion: "Choose another provider or enable Apple Intelligence before continuing."
                )
            }

            return readyStatus(for: provider)
        }

        if requiresAPIURL(provider: provider) {
            let apiURL = context.config.apiURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !apiURL.isEmpty else {
                return ProviderSetupStatus(
                    isReady: false,
                    title: "API URL required",
                    message: "Enter a valid API URL for \(provider.displayName) before continuing.",
                    recoverySuggestion: provider == .ollama
                        ? "Use your Ollama server URL, such as http://localhost:11434."
                        : "Enter the base URL for your compatible API service."
                )
            }
        }

        if provider == .openAI,
           ProviderAuthResolver.effectiveAuthMethod(for: .openAI, config: context.config) == .accountSignIn {
            guard context.isCodexInstalled else {
                return ProviderSetupStatus(
                    isReady: false,
                    title: "Codex CLI required",
                    message: "Install Codex CLI before continuing with OpenAI account sign-in.",
                    recoverySuggestion: "Run `npm i -g @openai/codex`, then `codex login`."
                )
            }

            guard context.isCodexAuthenticated else {
                return ProviderSetupStatus(
                    isReady: false,
                    title: "Codex CLI sign-in required",
                    message: "Sign in with Codex CLI before continuing with your OpenAI account.",
                    recoverySuggestion: "Run `codex login`, then verify the sign-in here."
                )
            }

            return readyStatus(for: provider)
        }

        guard ProviderAuthResolver.hasRequiredCredential(for: provider, config: context.config) else {
            return ProviderSetupStatus(
                isReady: false,
                title: "Credentials required",
                message: missingCredentialMessage(for: provider),
                recoverySuggestion: missingCredentialSuggestion(for: provider)
            )
        }

        return readyStatus(for: provider)
    }

    private static func readyStatus(for provider: AIProvider) -> ProviderSetupStatus {
        ProviderSetupStatus(
            isReady: true,
            title: "Setup complete",
            message: "\(provider.displayName) is configured. Sorty will verify the connection before onboarding finishes.",
            recoverySuggestion: nil
        )
    }

    private static func requiresAPIURL(provider: AIProvider) -> Bool {
        switch provider {
        case .openAICompatible, .ollama:
            return true
        default:
            return false
        }
    }

    private static func missingCredentialMessage(for provider: AIProvider) -> String {
        switch provider {
        case .unavailableProvider:
            return "Choose an AI provider before continuing."
        case .openAI:
            return "Enter an OpenAI API key before continuing."
        case .groq:
            return "Enter a Groq API key before continuing."
        case .openAICompatible:
            return "Enter an API key for your compatible provider before continuing."
        case .openRouter:
            return "Enter an OpenRouter API key before continuing."
        case .anthropic:
            return "Enter an Anthropic API key before continuing."
        case .gemini:
            return "Enter a Gemini API key before continuing."
        case .openCodeZen, .openCodeGo:
            return "Enter an OpenCode API key before continuing."
        case .ollama:
            return "Finish configuring Ollama before continuing."
        case .appleFoundationModel:
            return "Apple Foundation Model is unavailable on this Mac."
        }
    }

    private static func missingCredentialSuggestion(for provider: AIProvider) -> String? {
        switch provider {
        case .unavailableProvider:
            return "Choose an AI provider before continuing."
        case .openAI, .openCodeZen, .openCodeGo, .groq, .openRouter, .anthropic, .gemini:
            return "Paste the provider API key into the secure field in this step."
        case .openAICompatible:
            return "Add both the API URL and API key for your compatible service."
        case .ollama:
            return "Confirm your Ollama server URL and that the service is running."
        case .appleFoundationModel:
            return "Choose another provider or enable Apple Intelligence."
        }
    }
}
