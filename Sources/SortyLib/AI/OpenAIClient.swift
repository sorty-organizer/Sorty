//
//  OpenAIClient.swift
//  Sorty
//
//  OpenAI-Compatible API Client with Streaming Support
//

import Foundation

public final class OpenAIClient: AIClientProtocol, Sendable {
    public let config: AIConfig
    @MainActor public weak var streamingDelegate: StreamingDelegate?
    
    public init(config: AIConfig) {
        self.config = config
    }

    private func authHeaders() -> [String: String] {
        ProviderAuthResolver.authHeaders(for: config.provider, config: config)
    }
    
    public func analyze(files: [FileItem], customInstructions: String? = nil, personaPrompt: String? = nil, temperature: Double? = nil) async throws -> OrganizationPlan {
        let apiURL = try AIRequestSupport.requireAPIURL(from: config)
        try AIRequestSupport.requireAPIKeyIfNeeded(from: config)
        let url = try AIRequestSupport.openAIChatCompletionsURL(from: apiURL)
        
        // Use custom system prompt if provided, otherwise use default
        let systemPrompt = config.systemPromptOverride ?? PromptBuilder.buildSystemPrompt(personaInfo: personaPrompt ?? "", mode: config.mode, enableTagging: config.enableFileTagging)
        let userPrompt = PromptBuilder.buildOrganizationPrompt(
            files: files, 
            mode: config.mode,
            namingStyle: config.namingStyle,
            renameNamingOptions: config.renameNamingOptions,
            customNamingInstructions: config.customNamingInstructions,
            renameRules: config.renameRules,
            renameRuleMode: config.renameRuleMode,
            enableReasoning: config.enableReasoning, 
            enableSmartRename: config.enableSmartRename,
            includeContentMetadata: config.enableDeepScan,
            customInstructions: customInstructions
        )
        let estimatedPromptTokens = PromptBuilder.estimateTokens(systemPrompt + userPrompt)
        
        // Build request body
        var requestBody: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": AIConfig.organizationTemperature
        ]
        
        // Add max_tokens if specified
        if let maxTokens = config.maxTokens {
            requestBody["max_tokens"] = maxTokens
        }
        configureStructuredOrganizationOutput(in: &requestBody)

        do {
            return try await performOrganizationRequest(
                url: url,
                requestBody: requestBody,
                files: files,
                promptTokens: estimatedPromptTokens,
                isMultimodal: false
            )
        } catch {
            await notifyStreamingFailure(error)
            throw error
        }
    }
    
    public func analyzeWithImages(files: [FileItem], imageData: [String: Data], customInstructions: String? = nil, personaPrompt: String? = nil, temperature: Double? = nil) async throws -> OrganizationPlan {
        let apiURL = try AIRequestSupport.requireAPIURL(from: config)
        try AIRequestSupport.requireAPIKeyIfNeeded(from: config)
        let url = try AIRequestSupport.openAIChatCompletionsURL(from: apiURL)

        let orderedImageNames = Self.orderedImageFilenames(from: imageData)
        
        let systemPrompt = config.systemPromptOverride ?? PromptBuilder.buildSystemPrompt(personaInfo: personaPrompt ?? "", mode: config.mode, enableTagging: config.enableFileTagging)
        let userPrompt = PromptBuilder.buildOrganizationPrompt(
            files: files, 
            mode: config.mode,
            namingStyle: config.namingStyle,
            renameNamingOptions: config.renameNamingOptions,
            customNamingInstructions: config.customNamingInstructions,
            renameRules: config.renameRules,
            renameRuleMode: config.renameRuleMode,
            enableReasoning: config.enableReasoning, 
            enableSmartRename: config.enableSmartRename,
            includeContentMetadata: config.enableDeepScan,
            customInstructions: customInstructions,
            analyzedImageFilenames: orderedImageNames
        )
        let estimatedPromptTokens = PromptBuilder.estimateTokens(systemPrompt + userPrompt)
        
        // Build multimodal content
        var contentArray: [[String: Any]] = [
            ["type": "text", "text": userPrompt]
        ]
        
        // Add images as base64
        for name in orderedImageNames {
            guard let data = imageData[name] else { continue }
            let base64 = data.base64EncodedString()
            contentArray.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/jpeg;base64,\(base64)",
                    "detail": config.effectiveVisionDetailLevel.rawValue
                ]
            ])
        }
        
        var requestBody: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": contentArray]
            ],
            "temperature": AIConfig.organizationTemperature
        ]
        
        if let maxTokens = config.maxTokens {
            requestBody["max_tokens"] = maxTokens
        }
        configureStructuredOrganizationOutput(in: &requestBody)

        do {
            return try await performOrganizationRequest(
                url: url,
                requestBody: requestBody,
                files: files,
                promptTokens: estimatedPromptTokens,
                isMultimodal: true
            )
        } catch where config.provider == .openRouter && Self.shouldRetryOpenRouterWithoutImages(error) {
            LogManager.shared.log(
                "OpenRouter could not complete the multimodal request; retrying once with file metadata only.",
                level: .warning,
                category: "OpenAIClient"
            )
            return try await analyze(
                files: files,
                customInstructions: customInstructions,
                personaPrompt: personaPrompt,
                temperature: temperature
            )
        } catch {
            await notifyStreamingFailure(error)
            throw error
        }
    }

    static func orderedImageFilenames(from imageData: [String: Data]) -> [String] {
        imageData.keys.sorted()
    }

    /// OpenRouter's free route can select reasoning models. Keep their internal
    /// planning out of the response and reserve the completion for Sorty's plan.
    private func configureStructuredOrganizationOutput(in requestBody: inout [String: Any]) {
        Self.configureReasoningEffort(
            in: &requestBody,
            provider: config.provider,
            effort: config.reasoningEffort
        )

        guard config.provider == .openRouter else { return }

        requestBody["response_format"] = ["type": "json_object"]
        if !config.enableStreaming {
            requestBody["plugins"] = [["id": "response-healing"]]
        }
    }
    
    public func generateText(prompt: String, systemPrompt: String? = nil) async throws -> String {
        try await generateText(
            prompt: prompt,
            systemPrompt: systemPrompt,
            responseFormat: .plain
        )
    }

    public func generateText(
        prompt: String,
        systemPrompt: String? = nil,
        responseFormat: AITextResponseFormat
    ) async throws -> String {
        let apiURL = try AIRequestSupport.requireAPIURL(from: config)
        try AIRequestSupport.requireAPIKeyIfNeeded(from: config)
        let url = try AIRequestSupport.openAIChatCompletionsURL(from: apiURL)
        
        var requestBody: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt ?? "You are a helpful assistant."],
                ["role": "user", "content": prompt]
            ],
            "temperature": AIConfig.organizationTemperature
        ]
        
        if let maxTokens = config.maxTokens {
            requestBody["max_tokens"] = maxTokens
        }

        Self.configureTextGenerationOutput(
            in: &requestBody,
            provider: config.provider,
            responseFormat: responseFormat,
            reasoningEffort: config.reasoningEffort
        )
        
        let headers = authHeaders()
        let request = try AIRequestSupport.makeJSONRequest(url: url, headers: headers, body: requestBody)

        let session = await AIRequestSupport.session(for: config)
        let (data, response) = try await AIRequestSupport.withTransientHTTPRetry {
            try await session.data(for: request)
        }

        _ = try AIRequestSupport.validateHTTPResponse(data: data, response: response)
        
        let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        guard let choices = jsonResponse?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let content = AIRequestSupport.extractChatMessageText(from: firstChoice),
              !content.isEmpty else {
            throw AIClientError.invalidResponseFormat
        }
        
        return content
    }

    static func configureTextGenerationOutput(
        in requestBody: inout [String: Any],
        provider: AIProvider,
        responseFormat: AITextResponseFormat,
        reasoningEffort: ReasoningEffort = .automatic
    ) {
        configureReasoningEffort(in: &requestBody, provider: provider, effort: reasoningEffort)

        if provider == .openRouter, responseFormat == .jsonObject {
            requestBody["response_format"] = ["type": "json_object"]
            requestBody["plugins"] = [["id": "response-healing"]]
        }
    }

    static func configureReasoningEffort(
        in requestBody: inout [String: Any],
        provider: AIProvider,
        effort: ReasoningEffort
    ) {
        guard let requestValue = effort.requestValue else { return }

        requestBody.removeValue(forKey: "temperature")
        switch provider {
        case .openRouter:
            requestBody["reasoning"] = [
                "effort": requestValue,
                "exclude": true
            ]
        case .openAI, .gemini:
            requestBody["reasoning_effort"] = requestValue
        case .githubCopilot, .groq, .openAICompatible, .ollama, .anthropic, .appleFoundationModel:
            break
        }
    }
    
    public func checkHealth() async throws {
        let apiURL = try AIRequestSupport.requireAPIURL(from: config)

        if config.provider == .openAI,
           ProviderAuthResolver.effectiveAuthMethod(for: .openAI, config: config) == .accountSignIn {
            try await CodexSubscriptionClient(config: config).checkHealth()
            return
        } else {
            try AIRequestSupport.requireAPIKeyIfNeeded(from: config)
        }

        let url = try AIRequestSupport.openAIModelsURL(from: apiURL)

        let headers = authHeaders()

        var request = try AIRequestSupport.makeJSONRequest(url: url, method: "GET", headers: headers)
        request.timeoutInterval = min(config.requestTimeout, 60)

        let session = await AIRequestSupport.session(for: config)
        let (data, response) = try await AIRequestSupport.withTransientHTTPRetry {
            try await session.data(for: request)
        }
        _ = try AIRequestSupport.validateHTTPResponse(data: data, response: response)
    }

    private func performOrganizationRequest(
        url: URL,
        requestBody: [String: Any],
        files: [FileItem],
        promptTokens: Int?,
        isMultimodal: Bool
    ) async throws -> OrganizationPlan {
        do {
            if config.enableStreaming {
                return try await analyzeWithStreaming(
                    url: url,
                    requestBody: requestBody,
                    files: files,
                    promptTokens: promptTokens
                )
            }
            return try await analyzeNonStreaming(
                url: url,
                requestBody: requestBody,
                files: files,
                promptTokens: promptTokens
            )
        } catch {
            guard config.provider == .openRouter,
                  !isMultimodal || !Self.isOpenRouterVisionRoutingError(error),
                  Self.shouldRetryOpenRouterPortably(error) else {
                throw error
            }

            return try await retryOpenRouterWithPortableJSONRequest(
                url: url,
                requestBody: requestBody,
                files: files,
                promptTokens: promptTokens
            )
        }
    }

    private func notifyStreamingFailure(_ error: Error) async {
        await MainActor.run {
            streamingDelegate?.didFail(error: error)
        }
    }
    
    // MARK: - Non-Streaming Implementation
    
    private func analyzeNonStreaming(url: URL, requestBody: [String: Any], files: [FileItem], promptTokens: Int?) async throws -> OrganizationPlan {
        let startTime = Date()
        let headers = authHeaders()

        let request = try AIRequestSupport.makeJSONRequest(url: url, headers: headers, body: requestBody)

        let session = await AIRequestSupport.session(for: config)
        do {
            let (data, response) = try await AIRequestSupport.withTransientHTTPRetry {
                try await session.data(for: request)
            }
            let endTime = Date()
            let duration = endTime.timeIntervalSince(startTime)

            _ = try AIRequestSupport.validateHTTPResponse(data: data, response: response)
            
            guard let jsonResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIClientError.jsonDecodingError(
                    context: "The provider returned a JSON value that was not a chat-completion object."
                )
            }

            guard let choices = jsonResponse["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let content = AIRequestSupport.extractChatMessageText(from: firstChoice),
                  !content.isEmpty else {
                throw AIClientError.jsonDecodingError(
                    context: Self.missingCompletionContext(from: jsonResponse)
                )
            }
            
            // Calculate stats
            // For non-streaming, TTFT is essentially the total duration as we wait for the full response
            // Estimated tokens: ~4 chars per token
            let estimatedTokens = content.count / 4
            let tps = duration > 0 ? Double(estimatedTokens) / duration : 0
            
            let stats = GenerationStats(
                duration: duration,
                tps: tps,
                ttft: duration, // approximate
                totalTokens: estimatedTokens,
                model: config.model,
                filesScanned: files.count,
                totalFileSize: files.reduce(0) { $0 + $1.size },
                promptTokens: promptTokens
            )
            
            let parsedPlan: OrganizationPlan
            do {
                parsedPlan = try ResponseParser.parseResponse(content, originalFiles: files, mode: config.mode)
            } catch {
                throw AIClientError.jsonDecodingError(context: error.localizedDescription)
            }

            var plan = parsedPlan
            plan.generationStats = stats
            await MainActor.run {
                streamingDelegate?.didComplete(content: content)
            }
            return plan
        } catch let error as AIClientError {
            throw error
        } catch {
            throw AIClientError.networkError(error)
        }
    }
    
    // MARK: - Streaming Implementation
    
    private func analyzeWithStreaming(url: URL, requestBody: [String: Any], files: [FileItem], promptTokens: Int?) async throws -> OrganizationPlan {
        var streamingRequestBody = requestBody
        streamingRequestBody["stream"] = true
        
        let headers = authHeaders()

        let request = try AIRequestSupport.makeJSONRequest(url: url, headers: headers, body: streamingRequestBody)
        
        let startTime = Date()
        var firstTokenTime: Date?
        var accumulatedContent = ""
        
        let session = await AIRequestSupport.session(for: config)
        do {
            let (bytes, response) = try await AIRequestSupport.withTransientHTTPRetry {
                try await session.bytes(for: request)
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIClientError.invalidResponse
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                // For streaming errors, we need to collect the error message
                var errorData = Data()
                for try await byte in bytes {
                    errorData.append(byte)
                }
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                throw AIClientError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
            }
            
            // Process SSE stream
            for try await line in bytes.lines {
                guard let jsonString = AIRequestSupport.sseDataPayload(from: line) else { continue }

                // Check for stream end
                if jsonString == "[DONE]" {
                    break
                }

                // Parse the JSON chunk
                guard let jsonData = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    continue
                }

                if let streamError = Self.streamError(from: json) {
                    if config.provider == .openRouter, Self.isTransientStreamError(streamError.statusCode) {
                        return try await retryOpenRouterWithoutStreaming(
                            url: url,
                            requestBody: requestBody,
                            files: files,
                            promptTokens: promptTokens
                        )
                    }
                    throw AIClientError.apiError(
                        statusCode: streamError.statusCode,
                        message: streamError.message
                    )
                }

                if let finishError = Self.finishReasonError(from: json) {
                    throw AIClientError.apiError(
                        statusCode: finishError.statusCode,
                        message: finishError.message
                    )
                }

                guard let completionChunk = AIRequestSupport.streamCompletionChunk(from: json),
                      !completionChunk.isEmpty else { continue }

                if firstTokenTime == nil {
                    firstTokenTime = Date()
                }

                accumulatedContent += completionChunk

                await MainActor.run {
                    streamingDelegate?.didReceiveChunk(completionChunk)
                }
            }
            
            let endTime = Date()
            let duration = endTime.timeIntervalSince(startTime)
            let ttft = firstTokenTime?.timeIntervalSince(startTime) ?? duration
            
            // improved token estimation: ~4 chars per token
            let estimatedTokens = accumulatedContent.count / 4
            let tps = duration > 0 ? Double(estimatedTokens) / duration : 0
            
            let stats = GenerationStats(
                duration: duration,
                tps: tps,
                ttft: ttft,
                totalTokens: estimatedTokens,
                model: config.model,
                filesScanned: files.count,
                totalFileSize: files.reduce(0) { $0 + $1.size },
                promptTokens: promptTokens
            )
            
            var plan: OrganizationPlan
            do {
                plan = try ResponseParser.parseResponse(accumulatedContent, originalFiles: files, mode: config.mode)
            } catch {
                // Try partial extraction before giving up
                if let partialPlan = ResponseParser.extractPartialResults(accumulatedContent, originalFiles: files, mode: config.mode) {
                    plan = partialPlan
                } else if config.provider == .openRouter {
                    return try await retryOpenRouterWithoutStreaming(
                        url: url,
                        requestBody: requestBody,
                        files: files,
                        promptTokens: promptTokens
                    )
                } else {
                    let clientError = AIClientError.jsonDecodingError(context: error.localizedDescription)
                    throw clientError
                }
            }
            plan.generationStats = stats
            let finalContent = accumulatedContent
            await MainActor.run {
                streamingDelegate?.didComplete(content: finalContent)
            }
            return plan
            
        } catch let error as AIClientError {
            throw error
        } catch {
            let clientError = AIClientError.networkError(error)
            throw clientError
        }
    }

    private struct StreamError {
        let statusCode: Int
        let message: String
    }

    private func retryOpenRouterWithoutStreaming(
        url: URL,
        requestBody: [String: Any],
        files: [FileItem],
        promptTokens: Int?
    ) async throws -> OrganizationPlan {
        var fallbackBody = requestBody
        fallbackBody["plugins"] = [["id": "response-healing"]]
        return try await analyzeNonStreaming(
            url: url,
            requestBody: fallbackBody,
            files: files,
            promptTokens: promptTokens
        )
    }

    private func retryOpenRouterWithPortableJSONRequest(
        url: URL,
        requestBody: [String: Any],
        files: [FileItem],
        promptTokens: Int?
    ) async throws -> OrganizationPlan {
        var fallbackBody = requestBody
        fallbackBody.removeValue(forKey: "provider")
        fallbackBody.removeValue(forKey: "response_format")
        fallbackBody.removeValue(forKey: "reasoning")
        fallbackBody.removeValue(forKey: "plugins")
        fallbackBody.removeValue(forKey: "stream")
        if let temperature = fallbackBody["temperature"] as? Double {
            fallbackBody["temperature"] = min(temperature, 0.2)
        }

        LogManager.shared.log(
            "Retrying OpenRouter once without optional routing parameters.",
            level: .warning,
            category: "OpenAIClient"
        )
        return try await analyzeNonStreaming(
            url: url,
            requestBody: fallbackBody,
            files: files,
            promptTokens: promptTokens
        )
    }

    private static func shouldRetryOpenRouterPortably(_ error: Error) -> Bool {
        guard let clientError = error as? AIClientError else { return false }
        switch clientError {
        case .invalidResponseFormat, .jsonDecodingError:
            return true
        case .apiError(let statusCode, let message):
            let normalized = message.lowercased()
            let parameterMismatch = normalized.contains("no endpoints") ||
                normalized.contains("requested parameters") ||
                normalized.contains("unsupported parameter") ||
                normalized.contains("response_format") ||
                normalized.contains("reasoning")
            return parameterMismatch || [400, 404, 422, 503].contains(statusCode)
        default:
            return false
        }
    }

    private static func isOpenRouterVisionRoutingError(_ error: Error) -> Bool {
        guard case let AIClientError.apiError(statusCode, message) = error,
              [400, 404, 422, 503].contains(statusCode) else {
            return false
        }
        let normalized = message.lowercased()
        return normalized.contains("vision") ||
            (normalized.contains("image") && (
                normalized.contains("input") ||
                normalized.contains("support") ||
                normalized.contains("endpoint") ||
                normalized.contains("modal")
            ))
    }

    private static func shouldRetryOpenRouterWithoutImages(_ error: Error) -> Bool {
        if isOpenRouterVisionRoutingError(error) {
            return true
        }
        guard let clientError = error as? AIClientError else { return false }
        switch clientError {
        case .invalidResponseFormat, .jsonDecodingError:
            return true
        default:
            return false
        }
    }

    private static func missingCompletionContext(from response: [String: Any]) -> String {
        let responseKeys = response.keys.sorted().joined(separator: ", ")
        let choices = response["choices"] as? [[String: Any]]
        let firstChoice = choices?.first
        let choiceKeys = firstChoice?.keys.sorted().joined(separator: ", ") ?? "none"
        let messageKeys = (firstChoice?["message"] as? [String: Any])?.keys.sorted().joined(separator: ", ") ?? "none"
        let finishReason = firstChoice?["finish_reason"] as? String ?? "missing"
        return "HTTP 200 contained no completion text (response keys: [\(responseKeys)]; choices: \(choices?.count ?? 0); choice keys: [\(choiceKeys)]; message keys: [\(messageKeys)]; finish reason: \(finishReason))."
    }

    private static func streamError(from json: [String: Any]) -> StreamError? {
        let firstChoice = (json["choices"] as? [[String: Any]])?.first
        guard let payload = (json["error"] as? [String: Any]) ??
            (firstChoice?["error"] as? [String: Any]) else {
            return nil
        }

        let metadata = payload["metadata"] as? [String: Any]
        let errorType = metadata?["error_type"] as? String
        let statusCode: Int
        if let number = payload["code"] as? NSNumber {
            statusCode = number.intValue
        } else if let string = payload["code"] as? String, let parsed = Int(string) {
            statusCode = parsed
        } else {
            switch errorType {
            case "rate_limit_exceeded":
                statusCode = 429
            case "provider_overloaded":
                statusCode = 503
            case "timeout":
                statusCode = 504
            default:
                statusCode = 502
            }
        }

        let message = (payload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMessage = if let message, !message.isEmpty {
            message
        } else {
            "The AI provider stopped the response before it completed."
        }
        return StreamError(
            statusCode: statusCode,
            message: resolvedMessage
        )
    }

    private static func finishReasonError(from json: [String: Any]) -> StreamError? {
        guard let firstChoice = (json["choices"] as? [[String: Any]])?.first,
              let finishReason = firstChoice["finish_reason"] as? String else {
            return nil
        }

        switch finishReason {
        case "length":
            return StreamError(
                statusCode: 413,
                message: "The model reached its output limit before finishing the organization plan. Try fewer files or a model with a larger output limit."
            )
        case "content_filter":
            return StreamError(
                statusCode: 422,
                message: "The model stopped because its content filter rejected part of the response."
            )
        case "error":
            return StreamError(
                statusCode: 502,
                message: "The AI provider stopped the response before it completed."
            )
        default:
            return nil
        }
    }

    private static func isTransientStreamError(_ statusCode: Int) -> Bool {
        [429, 500, 502, 503, 504].contains(statusCode)
    }

}
