//
//  AIClientProtocol.swift
//  Sorty
//
//  Protocol defining AI client interface
//

import Foundation

public enum AITextResponseFormat: Equatable, Sendable {
    case plain
    case jsonObject
    case jsonArray
}

/// Delegate protocol for streaming updates
@MainActor
public protocol StreamingDelegate: AnyObject {
    func didReceiveChunk(_ chunk: String)
    func didComplete(content: String)
    func didFail(error: Error)
}

public protocol AIClientProtocol: Sendable {
    func analyze(files: [FileItem], customInstructions: String?, personaPrompt: String?, temperature: Double?) async throws -> OrganizationPlan
    func analyzeWithImages(files: [FileItem], imageData: [String: Data], customInstructions: String?, personaPrompt: String?, temperature: Double?) async throws -> OrganizationPlan
    func generateText(prompt: String, systemPrompt: String?) async throws -> String
    func generateText(
        prompt: String,
        systemPrompt: String?,
        responseFormat: AITextResponseFormat
    ) async throws -> String
    func checkHealth() async throws
    var config: AIConfig { get }
    @MainActor var streamingDelegate: StreamingDelegate? { get set }
}

public extension AIClientProtocol {
    func generateText(
        prompt: String,
        systemPrompt: String?,
        responseFormat: AITextResponseFormat
    ) async throws -> String {
        try await generateText(prompt: prompt, systemPrompt: systemPrompt)
    }
}

public enum AIClientError: LocalizedError, Sendable {
    case missingAPIURL
    case missingAPIKey
    case invalidURL
    case invalidResponse
    case invalidResponseFormat
    case internetAccessBlocked
    case apiError(statusCode: Int, message: String)
    case networkError(any Error & Sendable)
    case jsonDecodingError(context: String)

    public static let internetAccessBlockedCode = "SORTY_NETWORK_PRIVACY_BLOCKED"

    public var isInternetAccessBlocked: Bool {
        if case .internetAccessBlocked = self {
            return true
        }
        return false
    }
    
    public var isCancellation: Bool {
        switch self {
        case .networkError(let error):
            if error is CancellationError { return true }
            let nsError = error as NSError
            if (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) || nsError.code == -999 { return true }
            let description = error.localizedDescription.lowercased()
            return description.contains("cancelled") || description.contains("canceled")
        default:
            return false
        }
    }

    /// True when a 429 carries a free-tier/quota-exhaustion body rather than a
    /// transient rate limit. Retrying won't help; the user must add paid
    /// credits or switch models.
    public var isQuotaExhausted: Bool {
        guard case .apiError(let statusCode, let message) = self else { return false }
        return Self.isQuotaExhaustedMessage(message, statusCode: statusCode)
    }

    private static func isQuotaExhaustedMessage(_ message: String, statusCode: Int) -> Bool {
        guard statusCode == 429 else { return false }
        let body = message.lowercased()
        return body.contains("free tier")
            || body.contains("quota")
            || body.contains("insufficient")
            || body.contains("billing")
            || body.contains("paid credits")
            || body.contains("upgrade to paid")
    }
    
    public var errorDescription: String? {
        switch self {
        case .missingAPIURL:
            return "API URL is required"
        case .missingAPIKey:
            return "API key is required"
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from AI provider"
        case .invalidResponseFormat:
            return "Invalid response format (JSON mode might be unsupported)"
        case .internetAccessBlocked:
            return "Internet access is blocked"
        case .apiError(let statusCode, let message):
            if Self.isQuotaExhaustedMessage(message, statusCode: statusCode) {
                return "API Error (\(statusCode)): This model has used its free-tier allowance. Add paid credits or switch models."
            }
            return "API Error (\(statusCode)): \(getStatusExplanation(statusCode))"
        case .networkError(let error):
            return "Connection Failed: \(error.localizedDescription)"
        case .jsonDecodingError:
            return "Invalid Response: The server returned data in an unexpected format"
        }
    }
    
    public var failureReason: String? {
        switch self {
        case .internetAccessBlocked:
            return """
            Code: \(Self.internetAccessBlockedCode)

            Sorty blocked this request before it reached the AI provider because Block Internet Connections is on.
            """
        case .apiError(_, let message):
            let parsed = parseErrorMessage(message)
            let redactedRaw = redactPotentialKeys(message)
            
            // If the message was successfully parsed from JSON, show both.
            // If parsing failed or was unnecessary, just show the redacted raw message.
            if parsed != message && !message.isEmpty {
                return "Error: \(redactPotentialKeys(parsed))\n\nRaw Response:\n\(redactedRaw)"
            }
            return redactedRaw
        case .networkError(let error):
            return error.localizedDescription
        case .missingAPIKey:
            return "Please enter an API key in the settings or disable 'Requires API Key' for local models."
        case .invalidURL:
            return "The URL format is incorrect. Ensure it starts with http:// or https://."
        case .jsonDecodingError(let context):
            return "The API returned an unexpected response format. This may indicate:\n• Wrong API endpoint URL\n• API version mismatch\n• Server configuration issue\n\nDetails: \(context)"
        default:
            return nil
        }
    }
    
    private func redactPotentialKeys(_ text: String) -> String {
        // Redact standard API key patterns: e.g. sk-..., ant-api-..., or any 32+ char alpha-numeric string
        let patterns = [
            "sk-[a-zA-Z0-9]{20,}",
            "ant-api-[a-zA-Z0-9-]{20,}",
            "[a-zA-Z0-9]{32,}"
        ]
        
        var redacted = text
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(location: 0, length: redacted.utf16.count)
                redacted = regex.stringByReplacingMatches(in: redacted, options: [], range: range, withTemplate: "[REDACTED KEY]")
            }
        }
        return redacted
    }
    
    private func getStatusExplanation(_ code: Int) -> String {
        switch code {
        case 401: return "Authentication failed. Your API key may be invalid or expired. Please check your credentials."
        case 403: return "Access denied. Your API key doesn't have permissions for this model or feature."
        case 404: return "Model or endpoint not found. Please verify the model name and API URL in settings."
        case 413: return "Request too large for the selected model context window. Try organizing fewer files at a time."
        case 429: return "Rate limit exceeded. You've sent too many requests. Please wait a moment before trying again."
        case 500: return "Internal server error. The AI provider is experiencing technical difficulties."
        case 501: return "Not supported. This provider or feature is not available in your current environment."
        case 502: return "The AI provider or its upstream model temporarily failed to respond. Sorty retried the request, but the service is still unavailable."
        case 503: return "Service unavailable. The AI provider's servers are overloaded or undergoing maintenance."
        case 504: return "The AI provider timed out while waiting for the model. Sorty retried the request, but the service is still unavailable."
        default: return "The request failed with an unexpected status code."
        }
    }
    
    private func parseErrorMessage(_ message: String) -> String {
        guard let data = message.data(using: .utf8) else { return message }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // OpenAI / Standard format: { "error": { "message": "..." } }
                if let error = json["error"] as? [String: Any],
                   let msg = error["message"] as? String {
                    return msg
                }
                // Anthropic format: { "type": "error", "error": { "message": "..." } }
                // (Handled by the above if it's nested similarly)
                
                // Simple format: { "message": "..." }
                if let msg = json["message"] as? String {
                    return msg
                }
                
                // Ollama/Other: { "error": "..." }
                if let msg = json["error"] as? String {
                    return msg
                }
            }
        } catch {
            // Not JSON or parsing failed, return raw message truncated if too long
        }
        
        // If it's HTML (common for proxy errors), strip it or just return a snippet
        if message.contains("<html>") {
            return "The server returned an HTML error page instead of JSON. This often happens with proxy or DNS issues."
        }
        
        return message.count > 300 ? String(message.prefix(300)) + "..." : message
    }
}
