//
//  AIConfig.swift
//  Sorty
//
//  AI Configuration Model
//

import Foundation
import SwiftUI

public enum ProviderAuthMethod: String, Codable, CaseIterable, Sendable {
    case apiKey = "api_key"
    case accountSignIn = "account_sign_in"
    case manualSessionToken = "manual_session_token"

    public var displayName: String {
        switch self {
        case .apiKey:
            return "API Key"
        case .accountSignIn:
            return "Codex CLI (Subscription)"
        case .manualSessionToken:
            return "API Key"
        }
    }
}

public struct ReasoningEffort: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let automatic = Self(rawValue: "automatic")
    public static let none = Self(rawValue: "none")
    public static let minimal = Self(rawValue: "minimal")
    public static let low = Self(rawValue: "low")
    public static let medium = Self(rawValue: "medium")
    public static let high = Self(rawValue: "high")
    public static let xhigh = Self(rawValue: "xhigh")
    public static let max = Self(rawValue: "max")
    public static let ultra = Self(rawValue: "ultra")

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .none: "None"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        case .ultra: "Ultra"
        default:
            rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public var helpText: String {
        switch self {
        case .automatic: "Let the model choose how much reasoning to use."
        case .none: "Skip additional reasoning when the model allows it."
        case .minimal: "Use the model's smallest reasoning level."
        case .low: "Use less reasoning for quicker results."
        case .medium: "Balance response time with more careful decisions."
        case .high: "Use more reasoning for difficult or ambiguous folders."
        case .xhigh: "Use extra reasoning for complex folders."
        case .max: "Use the model's maximum reasoning depth."
        case .ultra: "Use the model's most intensive reasoning mode."
        default: "Use the provider's \(displayName.lowercased()) reasoning level."
        }
    }

    public var requestValue: String? {
        self == .automatic ? nil : rawValue
    }
}

public enum AIProvider: String, Codable, CaseIterable, Sendable {
    case openAI = "openai"
    case githubCopilot = "github_copilot"
    case groq = "groq"
    case openAICompatible = "openai_compatible"
    case openRouter = "open_router"
    case ollama = "ollama"
    case anthropic = "anthropic"
    case gemini = "gemini"
    case appleFoundationModel = "apple_foundation_model"

    public static let appleFoundationModelName = "Apple Foundation Model"

    public static var userSelectableProviders: [AIProvider] {
        allCases
    }
    
    public var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .githubCopilot:
            return "GitHub Copilot"
        case .groq:
            return "Groq"
        case .openAICompatible:
            return "OpenAI-Compatible API"
        case .openRouter:
            return "OpenRouter"
        case .ollama:
            return "Ollama"
        case .anthropic:
            return "Anthropic (Claude)"
        case .gemini:
            return "Google Gemini"
        case .appleFoundationModel:
            return "Apple"
        }
    }
    
    public var isAvailable: Bool {
        switch self {
        case .openAI, .githubCopilot, .groq, .openAICompatible, .openRouter, .ollama, .anthropic, .gemini:
            return true
        case .appleFoundationModel:
            return true
        }
    }
    
    public var unavailabilityReason: String? {
        switch self {
        case .openAI, .githubCopilot, .groq, .openAICompatible, .openRouter, .ollama, .anthropic, .gemini:
            return nil
        case .appleFoundationModel:
            return nil
        }
    }
    
    /// Default API URL for this provider
    public var defaultAPIURL: String? {
        switch self {
        case .openAI:
            return "https://api.openai.com"
        case .githubCopilot:
            return "https://api.githubcopilot.com"
        case .groq:
            return "https://api.groq.com/openai"
        case .openAICompatible:
            return "https://api.openai.com"
        case .openRouter:
            return "https://openrouter.ai/api/v1"
        case .ollama:
            return "http://localhost:11434"
        case .anthropic:
            return "https://api.anthropic.com/v1/messages"
        case .gemini:
            return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .appleFoundationModel:
            return nil
        }
    }
    
    /// Default model for this provider
    public var defaultModel: String {
        switch self {
        case .openAI:
            return "gpt-5.4-mini"
        case .githubCopilot:
            return "gpt-5-mini"
        case .groq:
            return "openai/gpt-oss-120b"
        case .openAICompatible:
            return "gpt-5.4-mini"
        case .openRouter:
            return "anthropic/claude-sonnet-4.6"
        case .ollama:
            return "llama3.1"
        case .anthropic:
            return "claude-sonnet-4-6"
        case .gemini:
            return "gemini-2.5-flash"
        case .appleFoundationModel:
            return Self.appleFoundationModelName
        }
    }
    
    /// Whether this provider typically requires an API key
    public var typicallyRequiresAPIKey: Bool {
        switch self {
        case .openAI, .githubCopilot, .groq, .openAICompatible, .openRouter, .anthropic, .gemini:
            return true
        case .ollama:
            return false
        case .appleFoundationModel:
            // CRITICAL: Apple Foundation Model runs strictly on-device via FoundationModels.framework
            // it does NOT use an API key and this must remain 'false'.
            return false
        }
    }
    
    /// Help text for obtaining API keys
    public var apiKeyHelpText: String {
        switch self {
        case .openAI:
            return "Get your API key from platform.openai.com"
        case .githubCopilot:
            return "Use your GitHub Personal Access Token with Copilot enabled"
        case .groq:
            return "Get your API key from console.groq.com"
        case .openAICompatible:
            return "Enter your API key for the compatible provider"
        case .openRouter:
            return "Get your API key from openrouter.ai/keys"
        case .ollama:
            return "Find local models in the Ollama library"
        case .anthropic:
            return "Get your API key from console.anthropic.com"
        case .gemini:
            return "Get your API key from aistudio.google.com"
        case .appleFoundationModel:
            return "No API key required"
        }
    }
    
    /// URL where users can get their API key
    public var apiKeyURL: URL? {
        switch self {
        case .openAI:
            return URL(string: "https://platform.openai.com/api-keys")
        case .githubCopilot:
            return URL(string: "https://github.com/settings/tokens")
        case .groq:
            return URL(string: "https://console.groq.com/keys")
        case .openAICompatible:
            return nil // Varies by provider
        case .openRouter:
            return URL(string: "https://openrouter.ai/keys")
        case .ollama:
            return URL(string: "https://ollama.com/search")
        case .anthropic:
            return URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini:
            return URL(string: "https://aistudio.google.com/app/apikey")
        case .appleFoundationModel:
            return nil
        }
    }
    
    /// Short label for the API key link
    public var apiKeyLinkLabel: String {
        switch self {
        case .openAI:
            return "platform.openai.com"
        case .githubCopilot:
            return "github.com/settings/tokens"
        case .groq:
            return "console.groq.com"
        case .openAICompatible:
            return "your provider's website"
        case .openRouter:
            return "openrouter.ai/keys"
        case .ollama:
            return "ollama.com/search"
        case .anthropic:
            return "console.anthropic.com"
        case .gemini:
            return "aistudio.google.com"
        case .appleFoundationModel:
            return ""
        }
    }
    
    /// URL to the provider's model documentation
    public var modelDocumentationURL: URL? {
        switch self {
        case .openAI:
            return URL(string: "https://platform.openai.com/docs/models")
        case .githubCopilot:
            return URL(string: "https://docs.github.com/en/copilot/reference/ai-models/supported-models")
        case .groq:
            return URL(string: "https://console.groq.com/docs/models")
        case .openAICompatible:
            return nil
        case .openRouter:
            return URL(string: "https://openrouter.ai/models")
        case .ollama:
            return URL(string: "https://ollama.com/search")
        case .anthropic:
            return URL(string: "https://docs.anthropic.com/en/docs/about-claude/models")
        case .gemini:
            return URL(string: "https://ai.google.dev/gemini-api/docs/models")
        case .appleFoundationModel:
            return nil
        }
    }
    
    /// Short label for the model documentation link
    public var modelDocsLinkLabel: String {
        switch self {
        case .openAI:
            return "OpenAI Models"
        case .githubCopilot:
            return "Copilot Models"
        case .groq:
            return "Groq Models"
        case .openAICompatible:
            return "provider docs"
        case .openRouter:
            return "OpenRouter Models"
        case .ollama:
            return "Ollama Library"
        case .anthropic:
            return "Claude Models"
        case .gemini:
            return "Gemini Models"
        case .appleFoundationModel:
            return ""
        }
    }
    
    public var logoImageName: String {
        switch self {
        case .openAI: return "ChatGPT"
        case .githubCopilot: return "GitHubCopilot"
        case .groq: return "Groq"
        case .openRouter: return "OpenRouter"
        case .ollama: return "Ollama"
        case .anthropic: return "Claude"
        case .gemini: return "Gemini"
        case .openAICompatible: return "server.rack"
        case .appleFoundationModel: return "apple.logo"
        }
    }

    /// Whether this provider supports deep scanning (analyzing file content)
    /// Some providers (like Apple Foundation Model) have limited context windows
    /// that make deep scanning impractical or risky for stability.
    public var supportsDeepScan: Bool {
        switch self {
        case .appleFoundationModel:
            return false
        default:
            return true
        }
    }

    public var usesSystemImage: Bool {
        switch self {
        case .openAICompatible, .appleFoundationModel: return true
        default: return false
        }
    }

    public var brandColor: Color {
        switch self {
        case .openAI:
            return Color(red: 0.13, green: 0.71, blue: 0.42)
        case .anthropic:
            return Color(red: 0.85, green: 0.55, blue: 0.35)
        case .groq:
            return Color(red: 0.95, green: 0.45, blue: 0.25)
        case .ollama:
            return .primary
        case .githubCopilot:
            return Color(red: 0.32, green: 0.35, blue: 0.94)
        case .appleFoundationModel:
            return Color.gray
        case .openAICompatible:
            return Color.blue
        case .openRouter:
            return Color(red: 0.4627, green: 0.1412, blue: 0.9569)
        case .gemini:
            return Color.cyan
        }
    }

    public var hasColorLogo: Bool {
        switch self {
        case .gemini, .openAI:
            return true
        default:
            return false
        }
    }

    /// Recommended models for this provider
    public var recommendedModels: [String] {
        switch self {
        case .openAI:
            return ["gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.2", "gpt-5-mini", "gpt-5-nano", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-mini"]
        case .anthropic:
            return ["claude-sonnet-4-6", "claude-opus-4-6", "claude-haiku-4-5", "claude-haiku-4-5-20251001", "claude-sonnet-4", "claude-opus-4"]
        case .gemini:
            return ["gemini-3.1-pro", "gemini-3-flash", "gemini-3.1-flash-lite", "gemini-3.1-pro-preview", "gemini-3-flash-preview", "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite"]
        case .groq:
            return ["meta-llama/llama-4-scout-17b-16e-instruct", "llama-3.2-90b-vision-preview", "llama-3.2-11b-vision-preview", "openai/gpt-oss-120b", "openai/gpt-oss-20b", "llama-3.3-70b-versatile"]
        case .openRouter:
            return ["anthropic/claude-sonnet-4.6", "openai/gpt-5.4-mini", "openai/gpt-4o", "google/gemini-2.5-pro", "google/gemini-2.5-flash", "meta-llama/llama-4-scout-17b-16e-instruct"]
        case .ollama:
            return ["llava", "llama3.2-vision", "qwen2.5vl", "gemma3", "llama4", "moondream", "llama3.1"]
        case .githubCopilot:
            return ["gpt-5-mini", "gpt-5.4-mini", "gpt-5.4", "gpt-5.3-codex", "claude-sonnet-4.6", "claude-opus-4.6", "claude-haiku-4.5", "gemini-3.1-pro", "gemini-3-flash", "grok-code-fast-1", "gpt-4.1"]
        case .openAICompatible:
            return ["gpt-5.4-mini", "gpt-5.4", "gpt-4.1", "gpt-4o"]
        case .appleFoundationModel:
            return [Self.appleFoundationModelName]
        }
    }

    /// The key used in Keychain to store the API key for this provider
    public var keychainKey: String {
        switch self {
        case .openAI: return "openAIAPIKey"
        case .anthropic: return "anthropicAPIKey"
        case .gemini: return "geminiAPIKey"
        case .groq: return "groqAPIKey"
        case .openRouter: return "openRouterAPIKey"
        case .ollama: return "ollamaAPIKey"
        case .githubCopilot: return "github_access_token" // Special case handled by GitHubCopilotAuthManager
        case .openAICompatible: return "openAICompatibleAPIKey"
        case .appleFoundationModel: return "appleFoundationAPIKey"
        }
    }

    public var supportsSubscriptionAuth: Bool {
        switch self {
        case .openAI:
            return true
        default:
            return false
        }
    }

    public var supportedAuthMethods: [ProviderAuthMethod] {
        guard supportsSubscriptionAuth else {
            return [.apiKey]
        }
        return [.apiKey, .accountSignIn]
    }
}

public enum OrganizationMode: String, Codable, CaseIterable, Sendable {
    case organize          // Move files, no rename
    case organizeAndRename // Move + rename
    case renameOnly        // Rename in place, no moves
    
    public var displayName: String {
        switch self {
        case .organize: return "Organize Only"
        case .organizeAndRename: return "Organize & Rename"
        case .renameOnly: return "Rename Only"
        }
    }
    
    public var description: String {
        switch self {
        case .organize: return "Move files into descriptive folders without changing filenames"
        case .organizeAndRename: return "Move files into descriptive folders and improve their names"
        case .renameOnly: return "Keep files where they are but improve their names"
        }
    }

    public var subtitle: String {
        switch self {
        case .organize: return "Keep original names"
        case .organizeAndRename: return "Move & Rename"
        case .renameOnly: return "In-place Rename"
        }
    }
    
    public var iconName: String {
        switch self {
        case .organize: return "folder.badge.plus"
        case .organizeAndRename: return "text.badge.checkmark"
        case .renameOnly: return "pencil.line"
        }
    }

    public var actionVerb: String {
        switch self {
        case .organize: return "Organize"
        case .organizeAndRename: return "Organize & Rename"
        case .renameOnly: return "Rename"
        }
    }

    public var workflowTitle: String {
        switch self {
        case .organize: return "Organize Files"
        case .organizeAndRename: return "Organize & Rename Files"
        case .renameOnly: return "Rename Files"
        }
    }

    public var gerund: String {
        switch self {
        case .organize: return "organizing"
        case .organizeAndRename: return "organizing and renaming"
        case .renameOnly: return "renaming"
        }
    }

    public var completionTitle: String {
        switch self {
        case .organize: return "Organization Complete"
        case .organizeAndRename: return "Organization & Renaming Complete"
        case .renameOnly: return "Renaming Complete"
        }
    }

    public var completionMessage: String {
        switch self {
        case .organize: return "Successfully organized your files into a clean structure."
        case .organizeAndRename: return "Successfully organized your files and improved their names."
        case .renameOnly: return "Successfully renamed your files in place."
        }
    }

    public var instructionPlaceholder: String {
        switch self {
        case .organize:
            return "e.g. \"Group by project\", \"Separate RAW photos\", \"Keep documents by year\"..."
        case .organizeAndRename:
            return "e.g. \"Group by client, then rename invoices with dates and vendor names\"..."
        case .renameOnly:
            return "e.g. \"Use clear invoice names\", \"Keep dates first\", \"Use natural names with spaces\"..."
        }
    }
}

public enum DuplicateHandlingMode: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case detectOnly = "Detect in Preview"
    case detectAndPreserveMetadata = "Detect + Preserve Metadata"

    public var id: String { rawValue }

    public var description: String {
        switch self {
        case .off:
            return "Skip duplicate detection when generating plans."
        case .detectOnly:
            return "Detect duplicates and surface them in preview insights."
        case .detectAndPreserveMetadata:
            return "Detect duplicates and preserve metadata for safer cleanup workflows."
        }
    }
}

public enum VisionDetailLevel: String, Codable, CaseIterable, Sendable {
    case low
    case auto
    case high

    public var displayName: String {
        switch self {
        case .low:
            return "Low"
        case .auto:
            return "Auto"
        case .high:
            return "High"
        }
    }

    public static func defaultFor(provider: AIProvider) -> VisionDetailLevel {
        switch provider {
        case .githubCopilot:
            return .low
        default:
            return .auto
        }
    }
}

public enum VisionBatchStrategy: String, Codable, CaseIterable, Sendable {
    case firstN
    case random
    case noText

    public var displayName: String {
        switch self {
        case .firstN:
            return "First N"
        case .random:
            return "Random"
        case .noText:
            return "Prioritize No OCR Text"
        }
    }

    public var description: String {
        switch self {
        case .firstN:
            return "Analyze the first N images in scan order."
        case .random:
            return "Analyze a random sample of images."
        case .noText:
            return "Prioritize images without OCR text before other images."
        }
    }
}

public struct AIConfig: Codable, Sendable, Equatable {
    public static let organizationTemperature = 0.7

    public var provider: AIProvider {
        didSet {
            if provider != oldValue {
                apiKey = nil
            }
        }
    }
    public var apiURL: String?
    public var apiKey: String?
    public var model: String
    
    // Advanced Settings
    public var requestTimeout: TimeInterval
    public var resourceTimeout: TimeInterval
    public var systemPromptOverride: String?
    public var maxTokens: Int?
    public var enableStreaming: Bool
    /// Whether the current provider requires an API key. 
    /// NOTE: For .appleFoundationModel and .ollama (usually), this should be false.
    public var requiresAPIKey: Bool
    public var enableReasoning: Bool  // Ask AI to explain organization decisions
    public var reasoningEffortByModel: [String: ReasoningEffort]
    
    // Deep Scanning & Duplicate Detection
    public var mode: OrganizationMode
    public var enableDeepScan: Bool   // Analyze file content (PDF text, EXIF, etc.)
    public var enableSmartRename: Bool // AI suggests better filenames
    public var detectDuplicates: Bool // Find duplicate files by hash
    public var enableFileTagging: Bool // Apply Finder tags to files
    public var showStatsForNerds: Bool // Show detailed stats about generation
    public var storeDuplicateMetadata: Bool // Save original metadata for duplicates (opt-in)
    public var strictExclusions: Bool // Higher-level screening for exclusions
    
    // Vision & Multimodal
    public var enableVision: Bool // Use AI vision to analyze image content
    public var namingStyle: NamingStyle // Preferred naming convention
    public var renameNamingOptions: RenameNamingOptions // Detailed filename formatting preferences
    public var customNamingInstructions: String? // Custom naming preferences
    public var renameRules: [RenameRule] // Custom find/replace rename rules
    public var renameRuleMode: RenameRuleApplicationMode // How custom rules interact with AI renaming
    public var selectedNamingPresetId: UUID? // Selected naming preset ID
    public var limitVisionImages: Bool // If false, send all detected images to the AI
    public var visionBatchSize: Int // Number of images to process in one AI call
    public var visionBatchStrategy: VisionBatchStrategy = .firstN // How images are selected for vision analysis
    public var visionDetailLevel: VisionDetailLevel = .auto // Provider image detail hint for multimodal APIs
    public var ocrLanguages: [String] = ["en-US"] // Apple Vision OCR language hints (BCP-47 codes)
    public var customOCRKeywords: [String]? // Custom keywords for OCR document type detection
    
    // Automation-specific settings (for background/watched folder operations)
    public var automationProvider: AIProvider?  // nil = use main provider
    public var automationModel: String?         // nil = use main model
    public var openAIAuthMethod: ProviderAuthMethod = .apiKey
    public var anthropicAuthMethod: ProviderAuthMethod = .apiKey

    public init(
        provider: AIProvider = .openAICompatible,
        apiURL: String? = nil,
        apiKey: String? = nil,
        model: String = AIProvider.openAICompatible.defaultModel,
        temperature _: Double = AIConfig.organizationTemperature,
        requestTimeout: TimeInterval = 120,
        resourceTimeout: TimeInterval = 600,
        systemPromptOverride: String? = nil,
        maxTokens: Int? = nil,
        enableStreaming: Bool = true,
        requiresAPIKey: Bool = true,
        enableReasoning: Bool = false,
        reasoningEffortByModel: [String: ReasoningEffort] = [:],
        mode: OrganizationMode = .organize,
        enableDeepScan: Bool = true,
        enableSmartRename: Bool = true,
        detectDuplicates: Bool = false,
        enableFileTagging: Bool = true,
        showStatsForNerds: Bool = false,
        storeDuplicateMetadata: Bool = true,
        strictExclusions: Bool = true,
        enableVision: Bool = true,
        namingStyle: NamingStyle = .descriptive,
        renameNamingOptions: RenameNamingOptions = .default,
        customNamingInstructions: String? = nil,
        renameRules: [RenameRule] = [],
        renameRuleMode: RenameRuleApplicationMode = .beforeAI,
        selectedNamingPresetId: UUID? = nil,
        limitVisionImages: Bool = true,
        visionBatchSize: Int = 12,
        visionBatchStrategy: VisionBatchStrategy = .noText,
        visionDetailLevel: VisionDetailLevel? = nil,
        ocrLanguages: [String] = ["en-US"],
        customOCRKeywords: [String]? = nil,
        automationProvider: AIProvider? = nil,
        automationModel: String? = nil,
        openAIAuthMethod: ProviderAuthMethod = .apiKey,
        anthropicAuthMethod: ProviderAuthMethod = .apiKey
    ) {
        self.provider = provider
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.model = model
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.systemPromptOverride = systemPromptOverride
        self.maxTokens = maxTokens
        self.enableStreaming = enableStreaming
        self.requiresAPIKey = requiresAPIKey
        self.enableReasoning = enableReasoning
        self.reasoningEffortByModel = reasoningEffortByModel
        self.mode = mode
        self.enableDeepScan = enableDeepScan
        self.enableSmartRename = enableSmartRename
        self.detectDuplicates = detectDuplicates
        self.enableFileTagging = enableFileTagging
        self.showStatsForNerds = showStatsForNerds
        self.storeDuplicateMetadata = storeDuplicateMetadata
        self.strictExclusions = strictExclusions
        self.enableVision = enableVision
        self.namingStyle = namingStyle
        self.renameNamingOptions = renameNamingOptions
        self.customNamingInstructions = customNamingInstructions
        self.renameRules = renameRules
        self.renameRuleMode = renameRuleMode
        self.selectedNamingPresetId = selectedNamingPresetId
        self.limitVisionImages = limitVisionImages
        self.visionBatchSize = visionBatchSize
        self.visionBatchStrategy = visionBatchStrategy
        self.visionDetailLevel = visionDetailLevel ?? VisionDetailLevel.defaultFor(provider: provider)
        self.ocrLanguages = ocrLanguages
        self.customOCRKeywords = customOCRKeywords
        self.automationProvider = automationProvider
        self.automationModel = automationModel
        self.openAIAuthMethod = openAIAuthMethod
        self.anthropicAuthMethod = anthropicAuthMethod
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case apiURL
        case apiKey
        case model
        case temperature
        case requestTimeout
        case resourceTimeout
        case systemPromptOverride
        case maxTokens
        case enableStreaming
        case requiresAPIKey
        case enableReasoning
        case reasoningEffortByModel
        case mode
        case enableDeepScan
        case enableSmartRename
        case detectDuplicates
        case enableFileTagging
        case showStatsForNerds
        case storeDuplicateMetadata
        case strictExclusions
        case enableVision
        case namingStyle
        case renameNamingOptions
        case customNamingInstructions
        case renameRules
        case renameRuleMode
        case selectedNamingPresetId
        case limitVisionImages
        case visionBatchSize
        case visionBatchStrategy
        case visionDetailLevel
        case ocrLanguages
        case customOCRKeywords
        case automationProvider
        case automationModel
        case openAIAuthMethod
        case anthropicAuthMethod
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedProvider = try container.decodeIfPresent(AIProvider.self, forKey: .provider) ?? .openAICompatible
        provider = decodedProvider
        apiURL = try container.decodeIfPresent(String.self, forKey: .apiURL)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
        let decodedModel = try container.decodeIfPresent(String.self, forKey: .model)
        model = decodedModel ?? provider.defaultModel
        _ = try container.decodeIfPresent(Double.self, forKey: .temperature)
        requestTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .requestTimeout) ?? 120
        resourceTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .resourceTimeout) ?? 600
        systemPromptOverride = try container.decodeIfPresent(String.self, forKey: .systemPromptOverride)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        enableStreaming = try container.decodeIfPresent(Bool.self, forKey: .enableStreaming) ?? true
        requiresAPIKey = try container.decodeIfPresent(Bool.self, forKey: .requiresAPIKey) ?? provider.typicallyRequiresAPIKey
        enableReasoning = try container.decodeIfPresent(Bool.self, forKey: .enableReasoning) ?? false
        reasoningEffortByModel = try container.decodeIfPresent(
            [String: ReasoningEffort].self,
            forKey: .reasoningEffortByModel
        ) ?? [:]
        mode = try container.decodeIfPresent(OrganizationMode.self, forKey: .mode) ?? .organize
        enableDeepScan = try container.decodeIfPresent(Bool.self, forKey: .enableDeepScan) ?? true
        enableSmartRename = try container.decodeIfPresent(Bool.self, forKey: .enableSmartRename) ?? true
        detectDuplicates = try container.decodeIfPresent(Bool.self, forKey: .detectDuplicates) ?? false
        enableFileTagging = try container.decodeIfPresent(Bool.self, forKey: .enableFileTagging) ?? true
        showStatsForNerds = try container.decodeIfPresent(Bool.self, forKey: .showStatsForNerds) ?? false
        storeDuplicateMetadata = try container.decodeIfPresent(Bool.self, forKey: .storeDuplicateMetadata) ?? true
        strictExclusions = try container.decodeIfPresent(Bool.self, forKey: .strictExclusions) ?? true
        enableVision = try container.decodeIfPresent(Bool.self, forKey: .enableVision) ?? true
        namingStyle = try container.decodeIfPresent(NamingStyle.self, forKey: .namingStyle) ?? .descriptive
        renameNamingOptions = try container.decodeIfPresent(RenameNamingOptions.self, forKey: .renameNamingOptions) ?? .default
        customNamingInstructions = try container.decodeIfPresent(String.self, forKey: .customNamingInstructions)
        renameRules = try container.decodeIfPresent([RenameRule].self, forKey: .renameRules) ?? []
        renameRuleMode = try container.decodeIfPresent(RenameRuleApplicationMode.self, forKey: .renameRuleMode) ?? .beforeAI
        selectedNamingPresetId = try container.decodeIfPresent(UUID.self, forKey: .selectedNamingPresetId)
        limitVisionImages = try container.decodeIfPresent(Bool.self, forKey: .limitVisionImages) ?? true
        let decodedVisionBatchSize = try container.decodeIfPresent(Int.self, forKey: .visionBatchSize) ?? 12
        let decodedVisionBatchStrategy = try container.decodeIfPresent(VisionBatchStrategy.self, forKey: .visionBatchStrategy) ?? .noText
        if limitVisionImages,
           decodedVisionBatchSize == 5,
           decodedVisionBatchStrategy == .firstN {
            // Migrate the former hidden defaults to a broader, higher-value sample.
            visionBatchSize = 12
            visionBatchStrategy = .noText
        } else {
            visionBatchSize = decodedVisionBatchSize
            visionBatchStrategy = decodedVisionBatchStrategy
        }
        visionDetailLevel = try container.decodeIfPresent(VisionDetailLevel.self, forKey: .visionDetailLevel) ?? VisionDetailLevel.defaultFor(provider: provider)
        ocrLanguages = try container.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? ["en-US"]
        customOCRKeywords = try container.decodeIfPresent([String].self, forKey: .customOCRKeywords)
        automationProvider = try container.decodeIfPresent(AIProvider.self, forKey: .automationProvider)
        automationModel = try container.decodeIfPresent(String.self, forKey: .automationModel)
        openAIAuthMethod = try container.decodeIfPresent(ProviderAuthMethod.self, forKey: .openAIAuthMethod) ?? .apiKey
        anthropicAuthMethod = try container.decodeIfPresent(ProviderAuthMethod.self, forKey: .anthropicAuthMethod) ?? .apiKey
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(apiURL, forKey: .apiURL)
        try container.encodeIfPresent(apiKey, forKey: .apiKey)
        try container.encode(model, forKey: .model)
        try container.encode(Self.organizationTemperature, forKey: .temperature)
        try container.encode(requestTimeout, forKey: .requestTimeout)
        try container.encode(resourceTimeout, forKey: .resourceTimeout)
        try container.encodeIfPresent(systemPromptOverride, forKey: .systemPromptOverride)
        try container.encodeIfPresent(maxTokens, forKey: .maxTokens)
        try container.encode(enableStreaming, forKey: .enableStreaming)
        try container.encode(requiresAPIKey, forKey: .requiresAPIKey)
        try container.encode(enableReasoning, forKey: .enableReasoning)
        try container.encode(reasoningEffortByModel, forKey: .reasoningEffortByModel)
        try container.encode(mode, forKey: .mode)
        try container.encode(enableDeepScan, forKey: .enableDeepScan)
        try container.encode(enableSmartRename, forKey: .enableSmartRename)
        try container.encode(detectDuplicates, forKey: .detectDuplicates)
        try container.encode(enableFileTagging, forKey: .enableFileTagging)
        try container.encode(showStatsForNerds, forKey: .showStatsForNerds)
        try container.encode(storeDuplicateMetadata, forKey: .storeDuplicateMetadata)
        try container.encode(strictExclusions, forKey: .strictExclusions)
        try container.encode(enableVision, forKey: .enableVision)
        try container.encode(namingStyle, forKey: .namingStyle)
        try container.encode(renameNamingOptions, forKey: .renameNamingOptions)
        try container.encodeIfPresent(customNamingInstructions, forKey: .customNamingInstructions)
        try container.encode(renameRules, forKey: .renameRules)
        try container.encode(renameRuleMode, forKey: .renameRuleMode)
        try container.encodeIfPresent(selectedNamingPresetId, forKey: .selectedNamingPresetId)
        try container.encode(limitVisionImages, forKey: .limitVisionImages)
        try container.encode(visionBatchSize, forKey: .visionBatchSize)
        try container.encode(visionBatchStrategy, forKey: .visionBatchStrategy)
        try container.encode(visionDetailLevel, forKey: .visionDetailLevel)
        try container.encode(ocrLanguages, forKey: .ocrLanguages)
        try container.encodeIfPresent(customOCRKeywords, forKey: .customOCRKeywords)
        try container.encodeIfPresent(automationProvider, forKey: .automationProvider)
        try container.encodeIfPresent(automationModel, forKey: .automationModel)
        try container.encode(openAIAuthMethod, forKey: .openAIAuthMethod)
        try container.encode(anthropicAuthMethod, forKey: .anthropicAuthMethod)
    }

    public var reasoningEffort: ReasoningEffort {
        reasoningEffort(for: provider, model: model)
    }

    public mutating func setReasoningEffort(_ effort: ReasoningEffort) {
        setReasoningEffort(effort, for: provider, model: model)
    }

    /// Pair-keyed access so any selection surface can read/write effort for the
    /// picked model without switching the active config first.
    public func reasoningEffort(for provider: AIProvider, model: String) -> ReasoningEffort {
        reasoningEffortByModel[Self.reasoningPreferenceKey(provider: provider, model: model)] ?? .automatic
    }

    public mutating func setReasoningEffort(_ effort: ReasoningEffort, for provider: AIProvider, model: String) {
        let key = Self.reasoningPreferenceKey(provider: provider, model: model)
        if effort == .automatic {
            reasoningEffortByModel.removeValue(forKey: key)
        } else {
            reasoningEffortByModel[key] = effort
        }
    }

    private static func reasoningPreferenceKey(provider: AIProvider, model: String) -> String {
        "\(provider.rawValue)|\(model.lowercased())"
    }

    private var reasoningPreferenceKey: String {
        Self.reasoningPreferenceKey(provider: provider, model: model)
    }

    public static let `default` = AIConfig(
        provider: .openAICompatible,
        apiURL: "https://api.openai.com",
        model: AIProvider.openAICompatible.defaultModel,
        requestTimeout: 120,
        resourceTimeout: 600,
        systemPromptOverride: nil,
        maxTokens: nil,
        enableStreaming: true,
        requiresAPIKey: true,
        enableReasoning: false,
        mode: .organize,
        enableDeepScan: true,
        enableSmartRename: true,
        detectDuplicates: false,
        enableFileTagging: true,
        showStatsForNerds: false,
        storeDuplicateMetadata: true,
        strictExclusions: true,
        enableVision: true,
        namingStyle: .descriptive,
        renameNamingOptions: .default,
        customNamingInstructions: nil,
        renameRules: [],
        renameRuleMode: .beforeAI,
        selectedNamingPresetId: nil,
        limitVisionImages: true,
        visionBatchSize: 12,
        visionBatchStrategy: .noText,
        visionDetailLevel: .auto,
        ocrLanguages: ["en-US"],
        customOCRKeywords: nil,
        automationProvider: nil,
        automationModel: nil,
        openAIAuthMethod: .apiKey,
        anthropicAuthMethod: .apiKey
    )
}

public extension AIConfig {
    func authMethod(for provider: AIProvider) -> ProviderAuthMethod {
        switch provider {
        case .openAI:
            return openAIAuthMethod
        case .anthropic:
            return anthropicAuthMethod
        default:
            return .apiKey
        }
    }

    mutating func setAuthMethod(_ method: ProviderAuthMethod, for provider: AIProvider) {
        switch provider {
        case .openAI:
            openAIAuthMethod = method
        case .anthropic:
            anthropicAuthMethod = method
        default:
            break
        }
    }

    var effectiveVisionDetailLevel: VisionDetailLevel {
        if provider == .githubCopilot && visionDetailLevel == .auto {
            return .low
        }
        return visionDetailLevel
    }

    var duplicateHandlingMode: DuplicateHandlingMode {
        get {
            guard detectDuplicates else { return .off }
            return storeDuplicateMetadata ? .detectAndPreserveMetadata : .detectOnly
        }
        set {
            switch newValue {
            case .off:
                detectDuplicates = false
            case .detectOnly:
                detectDuplicates = true
                storeDuplicateMetadata = false
            case .detectAndPreserveMetadata:
                detectDuplicates = true
                storeDuplicateMetadata = true
            }
        }
    }
}

public struct RenameNamingOptions: Codable, Sendable, Equatable {
    public var separator: RenameSeparatorPreference
    public var caseStyle: RenameCaseStyle
    public var maxFilenameLength: Int
    public var outputLanguage: String
    public var datePolicy: RenameDatePolicy

    public init(
        separator: RenameSeparatorPreference = .spaces,
        caseStyle: RenameCaseStyle = .natural,
        maxFilenameLength: Int = 80,
        outputLanguage: String = "English",
        datePolicy: RenameDatePolicy = .whenFound
    ) {
        self.separator = separator
        self.caseStyle = caseStyle
        self.maxFilenameLength = min(max(maxFilenameLength, 20), 180)
        self.outputLanguage = outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "English" : outputLanguage
        self.datePolicy = datePolicy
    }

    public static let `default` = RenameNamingOptions()

    public var promptInstructions: String {
        """
        Filename formatting preferences:
        - Separator: \(separator.promptDescription)
        - Case style: \(caseStyle.promptDescription)
        - Maximum filename length, including extension: \(maxFilenameLength) characters.
        - Output language: \(outputLanguage).
        - Date usage: \(datePolicy.promptDescription)
        """
    }

    public var exampleFilename: String {
        let candidates: [(source: String, original: String)] = [
            ("Invoice.pdf", "scan.pdf"),
            ("Receipt 2026.pdf", "scan.pdf"),
            ("2026-03-19 Invoice.pdf", "scan_001.pdf"),
            ("2026-03-19 Acme Invoice.pdf", "scan_002.pdf"),
            ("2026-03-19 Service Agreement.pdf", "scan_003.pdf"),
            ("2026-03-19 Signed Service Agreement.pdf", "scan_004.pdf"),
            ("2026-03-19 Acme Signed Service Agreement.pdf", "scan_005.pdf"),
            ("2026-03-19 Acme Corporation Service Agreement.pdf", "scan_006.pdf"),
            ("2026-03-19 Acme Corporation Signed Service Agreement.pdf", "scan_007.pdf"),
            ("2026-03-19 Acme Corporation Signed Master Service Agreement.pdf", "scan_008.pdf"),
            ("2026-03-19 Acme Corporation Signed Master Service Agreement Final.pdf", "scan_009.pdf"),
            ("2026-03-19 Acme Corporation Signed Master Service Agreement Final Executed.pdf", "scan_010.pdf"),
            ("2026-03-19 Acme Corporation Signed Master Service Agreement Final Executed Version.pdf", "scan_011.pdf"),
            ("2026-03-19 Acme Corporation Signed Master Service Agreement Final Executed Version Counterparty Approved.pdf", "scan_012.pdf"),
            ("2026-03-19 Acme Corporation Legal Department Signed Master Service Agreement Final Executed Version Counterparty Approved.pdf", "scan_013.pdf"),
            ("2026-03-19 Acme Corporation Legal Department Signed Master Service Agreement Final Executed Version Counterparty Approved Archival Copy.pdf", "scan_014.pdf"),
            ("2026-03-19 Acme Corporation Legal Department Confidential Signed Master Service Agreement Final Executed Version Counterparty Approved Archival Copy.pdf", "scan_015.pdf"),
            ("2026-03-19 Acme Corporation Legal Department Confidential Signed Master Service Agreement Final Executed Version Counterparty Approved Archival Copy Authorized Signatories.pdf", "scan_016.pdf")
        ]

        let unboundedOptions = RenameNamingOptions(
            separator: separator,
            caseStyle: caseStyle,
            maxFilenameLength: 999,
            outputLanguage: outputLanguage,
            datePolicy: datePolicy
        )

        let formatted: [String] = candidates.compactMap { candidate in
            FilenameNormalizer.normalize(
                candidate.source,
                originalFilename: candidate.original,
                options: unboundedOptions
            ) ?? candidate.source
        }

        let fitting = formatted.filter { $0.count <= maxFilenameLength }
        if let longest = fitting.max(by: { $0.count < $1.count }) {
            return longest
        }

        return formatted.min(by: { $0.count < $1.count }) ?? "Invoice.pdf"
    }
}

public enum RenameSeparatorPreference: String, Codable, CaseIterable, Sendable {
    case spaces
    case hyphen
    case underscore
    case smart

    public var displayName: String {
        switch self {
        case .spaces: return "Spaces"
        case .hyphen: return "Hyphen"
        case .underscore: return "Underscore"
        case .smart: return "Smart"
        }
    }

    public var promptDescription: String {
        switch self {
        case .spaces: return "Use normal spaces between words. Spaces are allowed and often preferred."
        case .hyphen: return "Use hyphens between filename parts."
        case .underscore: return "Use underscores between filename parts."
        case .smart: return "Choose spaces, hyphens, or underscores based on the selected template and file type."
        }
    }
}

public enum RenameCaseStyle: String, Codable, CaseIterable, Sendable {
    case natural
    case title
    case sentence
    case camel
    case pascal
    case snake
    case kebab

    public var displayName: String {
        switch self {
        case .natural: return "Natural"
        case .title: return "Title"
        case .sentence: return "Sentence"
        case .camel: return "camelCase"
        case .pascal: return "PascalCase"
        case .snake: return "snake_case"
        case .kebab: return "kebab-case"
        }
    }

    public var promptDescription: String {
        switch self {
        case .natural: return "Use natural human-readable capitalization."
        case .title: return "Use Title Case."
        case .sentence: return "Use sentence case."
        case .camel: return "Use camelCase for the base filename."
        case .pascal: return "Use PascalCase for the base filename."
        case .snake: return "Use snake_case for the base filename."
        case .kebab: return "Use kebab-case for the base filename."
        }
    }
}

public enum RenameDatePolicy: String, Codable, CaseIterable, Sendable {
    case never
    case whenFound
    case alwaysWhenReliable

    public var displayName: String {
        switch self {
        case .never: return "Never"
        case .whenFound: return "When Found"
        case .alwaysWhenReliable: return "When Reliable"
        }
    }

    public var promptDescription: String {
        switch self {
        case .never: return "Do not add dates unless the current filename already has one and removing it would lose meaning."
        case .whenFound: return "Include dates only when found in file content, OCR, EXIF, metadata, or the current filename."
        case .alwaysWhenReliable: return "Prefer a leading date when a reliable date can be inferred from content or metadata."
        }
    }
}

public enum NamingStyle: String, Codable, CaseIterable, Sendable {
    case descriptive // Natural document names with reliable dates when useful
    case minimalist  // Subject
    case technical   // TYPE_DATE_ID
    case datePrefix  // YYYY-MM-DD - Subject - Type
    case screenshotFriendly
    case custom      // User-defined naming style
    
    public var displayName: String {
        switch self {
        case .descriptive: return "Natural Document Name"
        case .minimalist: return "Subject Only"
        case .technical: return "Technical"
        case .datePrefix: return "Date - Client - Type"
        case .screenshotFriendly: return "Screenshot Friendly"
        case .custom: return "Custom"
        }
    }
    
    public var promptInstructions: String {
        switch self {
        case .descriptive:
            return "Use natural, readable names with spaces when helpful, such as 2026-03-19 Signed Service Agreement.pdf. Include dates only when reliable."
        case .minimalist:
            return "Use the clearest subject only, such as Vendor Contract Notes.docx. Keep names short and omit dates or IDs unless essential."
        case .technical:
            return "Use a structured technical style, such as INVOICE_20251204_ACME_1843.pdf. Prefer uppercase type and compact identifiers."
        case .datePrefix:
            return "Use date, client or source, and document type when available, such as 2025-12-04 - Acme Co - Invoice 1843.pdf."
        case .screenshotFriendly:
            return "Use screenshot-friendly names with visible context, such as 2026-03-12 Checkout Error Screenshot.png."
        case .custom:
            return "Follow the custom naming instructions provided by the user exactly as specified."
        }
    }
}
