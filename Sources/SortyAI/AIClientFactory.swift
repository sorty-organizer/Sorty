//
//  AIClientFactory.swift
//  Sorty
//
//  Factory for creating appropriate AI client
//

import Foundation

public struct AIClientFactory {
    /// Detached creation helper so pipeline setup never blocks the MainActor
    /// on provider resolution (auth-method lookup, availability probes).
    public static func createClientDetached(config: AIConfig) async throws -> AIClientProtocol {
        try await Task.detached(priority: .userInitiated) {
            try createClient(config: config)
        }.value
    }

    public static func createClient(config: AIConfig) throws -> AIClientProtocol {
        switch config.provider {
        case .openAI:
            if ProviderAuthResolver.effectiveAuthMethod(for: .openAI, config: config) == .accountSignIn {
                return CodexSubscriptionClient(config: config)
            }
            return OpenAIClient(config: config)

        case .groq, .openAICompatible, .openRouter, .ollama, .gemini:
            return OpenAIClient(config: config)
            
        case .githubCopilot:
            return GitHubCopilotClient(config: config)
            
        case .anthropic:
            return AnthropicClient(config: config)
            
        case .appleFoundationModel:
            #if canImport(FoundationModels) && os(macOS)
            if #available(macOS 26.0, *) {
                if AppleFoundationModelClient.isAvailable() {
                    return AppleFoundationModelClient(config: config)
                }
                throw AIClientError.apiError(
                    statusCode: 503,
                    message: AppleFoundationModelClient.unavailabilityReason
                )
            }
            #endif
            throw AIClientError.apiError(
                statusCode: 501,
                message: "Apple Intelligence in Sorty requires macOS 26 or later. Apple Intelligence being enabled on macOS 15 does not make Apple's Foundation Models framework available to apps."
            )
        }
    }
}
