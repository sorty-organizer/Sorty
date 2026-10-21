import SwiftUI

// MARK: - AI Provider Extensions

extension AIProvider {
    package var selectorTitle: String {
        switch self {
        case .unavailableProvider:
            return "Unavailable"
        case .openAICompatible:
            return "Compatible API"
        case .openRouter:
            return "OpenRouter"
        case .anthropic:
            return "Claude"
        case .appleFoundationModel:
            return "Apple"
        default:
            return displayName
        }
    }

    package var selectorDescription: String {
        switch self {
        case .unavailableProvider:
            return "Choose a provider"
        case .openAI:
            return "API key or ChatGPT"
        case .anthropic:
            return "Claude models"
        case .groq:
            return "Fast inference"
        case .ollama:
            return "Local models"
        case .openCodeZen:
            return "OpenCode models"
        case .openCodeGo:
            return "Go models"
        case .appleFoundationModel:
            return "On-device"
        case .openAICompatible:
            return "Custom endpoint"
        case .openRouter:
            return "Model router"
        case .gemini:
            return "Gemini models"
        }
    }

    var iconName: String {
        switch self {
        case .unavailableProvider:
            return "exclamationmark.triangle"
        case .openAI:
            return "circle.hexagongrid.fill"
        case .anthropic:
            return "sparkles"
        case .groq:
            return "bolt.fill"
        case .ollama:
            return "cube.fill"
        case .openCodeZen, .openCodeGo:
            return "server.rack"
        case .appleFoundationModel:
            return "apple.logo"
        case .openAICompatible:
            return "network"
        case .openRouter:
            return "arrow.triangle.2.circlepath"
        case .gemini:
            return "diamond.fill"
        }
    }

    // brandColor is now defined canonically in AIProvider (AIConfig.swift)

    var description: String {
        switch self {
        case .unavailableProvider:
            return "Choose an available provider"
        case .openAI:
            return "GPT-5.2, GPT-5 mini, and more"
        case .anthropic:
            return "Claude 4.6 Sonnet, Claude 4.6 Opus, and more"
        case .groq:
            return "Ultra-fast inference provider"
        case .ollama:
            return "Local models on your machine"
        case .openCodeZen:
            return "Use your OpenCode balance"
        case .openCodeGo:
            return "Use your OpenCode Go subscription"
        case .appleFoundationModel:
            return "On-device Apple Foundation Models"
        case .openAICompatible:
            return "Any OpenAI-compatible API"
        case .openRouter:
            return "Choose from the largest selection of providers"
        case .gemini:
            return "Google's Gemini models"
        }
    }
}
