//
//  AnthropicClient.swift
//  Sorty
//
//  Anthropic API client implementation
//

import Foundation

public final class AnthropicClient: AIClientProtocol, Sendable {
    public let config: AIConfig
    @MainActor public weak var streamingDelegate: StreamingDelegate?

    private static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let modelsURL = URL(string: "https://api.anthropic.com/v1/models")!
    
    public init(config: AIConfig) {
        self.config = config
    }

    private func requiredHeaders() throws -> [String: String] {
        guard let authHeader = ProviderAuthResolver.authHeader(for: .anthropic, config: config) else {
            throw AIClientError.missingAPIKey
        }

        return [
            authHeader.field: authHeader.value,
            "anthropic-version": "2023-06-01"
        ]
    }
    
    public func analyze(files: [FileItem], customInstructions: String? = nil, personaPrompt: String? = nil, temperature: Double? = nil) async throws -> OrganizationPlan {
        let headers = try requiredHeaders()

        let url = Self.messagesURL
        
        let prompts = SharedOrganizePipeline.buildPrompts(
            config: config,
            files: files,
            customInstructions: customInstructions,
            personaPrompt: personaPrompt,
            personaAsSeparateSection: true
        )
        let fullSystemPrompt = prompts.system
        let userPrompt = prompts.user

        let requestBody: [String: Any] = [
            "model": config.model,
            "max_tokens": config.maxTokens ?? 4096,
            "system": fullSystemPrompt,
            "messages": [
                ["role": "user", "content": userPrompt]
            ],
            "temperature": temperature ?? AIConfig.organizationTemperature
        ]

        if config.enableStreaming {
            return try await analyzeWithStreaming(url: url, requestBody: requestBody, headers: headers, files: files, totalFileSize: AIRequestSupport.totalFileSize(of: files))
        } else {
            return try await analyzeStandard(url: url, requestBody: requestBody, headers: headers, files: files, totalFileSize: AIRequestSupport.totalFileSize(of: files))
        }
    }

    public func analyzeWithImages(files: [FileItem], imageData: [String: Data], customInstructions: String? = nil, personaPrompt: String? = nil, temperature: Double? = nil) async throws -> OrganizationPlan {
        let headers = try requiredHeaders()

        let url = Self.messagesURL
        let orderedImageNames = Self.orderedImageFilenames(from: imageData)

        let prompts = SharedOrganizePipeline.buildPrompts(
            config: config,
            files: files,
            customInstructions: customInstructions,
            personaPrompt: personaPrompt,
            analyzedImageFilenames: orderedImageNames,
            personaAsSeparateSection: true
        )
        let fullSystemPrompt = prompts.system
        let userPrompt = prompts.user
        
        // Build multimodal content for Claude Vision
        var contentArray: [[String: Any]] = [
            ["type": "text", "text": userPrompt]
        ]
        
        // Add images in Claude's format (cached base64 so retries skip re-encode)
        for name in orderedImageNames {
            guard let data = imageData[name] else { continue }
            let base64 = ImageBase64Cache.shared.base64(for: name, data: data)
            contentArray.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": base64
                ]
            ])
        }
        
        let requestBody: [String: Any] = [
            "model": config.model,
            "max_tokens": config.maxTokens ?? 4096,
            "system": fullSystemPrompt,
            "messages": [
                ["role": "user", "content": contentArray]
            ],
            "temperature": temperature ?? AIConfig.organizationTemperature
        ]

        do {
            if config.enableStreaming {
                return try await analyzeWithStreaming(url: url, requestBody: requestBody, headers: headers, files: files, totalFileSize: AIRequestSupport.totalFileSize(of: files))
            } else {
                return try await analyzeStandard(url: url, requestBody: requestBody, headers: headers, files: files, totalFileSize: AIRequestSupport.totalFileSize(of: files))
            }
        } catch where AIRequestSupport.isPayloadTooLarge(error) {
            // Strip images first on 400/413/422 instead of re-sending megabytes.
            ModelLog.log(
                "Anthropic multimodal request rejected; retrying text-only.",
                level: .warning,
                category: "AnthropicClient"
            )
            return try await analyze(
                files: files,
                customInstructions: customInstructions,
                personaPrompt: personaPrompt,
                temperature: temperature
            )
        }
    }

    static func orderedImageFilenames(from imageData: [String: Data]) -> [String] {
        imageData.keys.sorted()
    }
    
    private func analyzeStandard(url: URL, requestBody: [String: Any], headers: [String: String], files: [FileItem], totalFileSize: Int64) async throws -> OrganizationPlan {
        var request = try AIRequestSupport.makeJSONRequest(
            url: url,
            headers: headers,
            body: requestBody
        )
        // Explicit organize timeout: never inherit the 600s resource default.
        request.timeoutInterval = AIRequestSupport.organizeTimeout(for: config)

        let session = await AIRequestSupport.session(for: config)
        do {
            let (data, response) = try await AIRequestSupport.withTransientHTTPRetry(maxElapsed: .milliseconds(Int64(request.timeoutInterval * 1_000))) {
                try await session.data(for: request)
            }

            _ = try AIRequestSupport.validateHTTPResponse(data: data, response: response)

            return try Self.parsePlan(from: data, files: files, mode: config.mode)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AIClientError {
            throw error
        } catch {
            throw AIClientError.networkError(error)
        }
    }

    /// Decodes a non-streaming Anthropic response. Malformed JSON and parser
    /// failures surface as `.jsonDecodingError` (as in OpenAIClient) so callers
    /// can repair the batch instead of treating them as transport failures.
    private static func parsePlan(from data: Data, files: [FileItem], mode: OrganizationMode) throws -> OrganizationPlan {
        let json: [String: Any]?
        do {
            json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            throw AIClientError.jsonDecodingError(context: error.localizedDescription)
        }

        if let stopReason = json?["stop_reason"] as? String, stopReason == "max_tokens" {
            throw outputLimitError()
        }
        guard let text = AIRequestSupport.extractText(from: json?["content"]),
              !text.isEmpty else {
            throw AIClientError.invalidResponseFormat
        }

        do {
            return try ResponseParser.parseResponse(text, originalFiles: files, mode: mode)
        } catch {
            throw AIClientError.jsonDecodingError(context: error.localizedDescription)
        }
    }
    
    private func analyzeWithStreaming(url: URL, requestBody: [String: Any], headers: [String: String], files: [FileItem], totalFileSize: Int64) async throws -> OrganizationPlan {
        var streamingRequestBody = requestBody
        streamingRequestBody["stream"] = true

        var request = try AIRequestSupport.makeJSONRequest(
            url: url,
            headers: headers,
            body: streamingRequestBody
        )
        // Explicit organize timeout: never inherit the 600s resource default.
        request.timeoutInterval = AIRequestSupport.organizeTimeout(for: config)

        let session = await AIRequestSupport.session(for: config)
        do {
            let (bytes, response) = try await AIRequestSupport.withTransientHTTPRetry(maxElapsed: .milliseconds(Int64(request.timeoutInterval * 1_000))) {
                try await session.bytes(for: request)
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIClientError.invalidResponse
            }
            
            if httpResponse.statusCode != 200 {
                var errorData = Data()
                try await withTaskCancellationHandler {
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        errorData.append(byte)
                    }
                } onCancel: {}
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown streaming error"
                throw AIClientError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
            }

            var accumulatedContent = ""
            var streamStopReason: String?
            // Coalesce off-actor: one MainActor hop per 100ms/4KB, not per delta.
            var coalescer = StreamingChunkCoalescer()

            try await AIRequestSupport.consumeSSEEvents(bytes) { jsonString in
                if let data = jsonString.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                    let type = json["type"] as? String
                    var chunkText: String?

                    if type == "message_delta",
                       let delta = json["delta"] as? [String: Any] {
                        streamStopReason = delta["stop_reason"] as? String ?? streamStopReason
                    } else if type == "message_stop",
                              let message = json["message"] as? [String: Any] {
                        streamStopReason = message["stop_reason"] as? String ?? streamStopReason
                    }

                    if type == "error" {
                        let errorObject = json["error"] as? [String: Any]
                        let message = errorObject?["message"] as? String ?? "Anthropic streaming request failed"
                        throw AIClientError.apiError(
                            statusCode: Self.streamErrorStatusCode(for: errorObject?["type"] as? String),
                            message: message
                        )
                    }

                    if type == "content_block_delta",
                    let delta = json["delta"] as? [String: Any] {
                        chunkText =
                            AIRequestSupport.extractText(from: delta["text"]) ??
                            AIRequestSupport.extractText(from: delta["partial_json"]) ??
                            AIRequestSupport.extractText(from: delta["content"])
                    } else if type == "content_block_start",
                            let contentBlock = json["content_block"] as? [String: Any] {
                        chunkText = AIRequestSupport.extractText(from: contentBlock["text"])
                    }

                    if let chunk = chunkText, !chunk.isEmpty {
                        accumulatedContent += chunk
                        if let payload = coalescer.append(chunk) {
                            await MainActor.run { [weak self] in
                                self?.streamingDelegate?.didReceiveChunk(payload)
                            }
                        }
                    }
                }
                return true
            }

            if let tail = coalescer.flush() {
                await MainActor.run { [weak self] in
                    self?.streamingDelegate?.didReceiveChunk(tail)
                }
            }
            
            if streamStopReason == "max_tokens" {
                throw Self.outputLimitError()
            }

            // Parse (with a partial fallback) before signaling completion so a
            // failed parse can never report didComplete followed by didFail.
            let plan: OrganizationPlan
            do {
                plan = try ResponseParser.parseResponse(accumulatedContent, originalFiles: files, mode: config.mode)
            } catch {
                if let partialPlan = ResponseParser.extractPartialResults(accumulatedContent, originalFiles: files, mode: config.mode) {
                    plan = partialPlan
                } else {
                    throw AIClientError.jsonDecodingError(context: error.localizedDescription)
                }
            }

            let finalContent = accumulatedContent
            await MainActor.run { [weak self] in
                self?.streamingDelegate?.didComplete(content: finalContent)
            }
            return plan
        } catch is CancellationError {
            await MainActor.run { [weak self] in
                self?.streamingDelegate?.didFail(error: CancellationError())
            }
            throw CancellationError()
        } catch let error as AIClientError {
            await MainActor.run { [weak self] in
                self?.streamingDelegate?.didFail(error: error)
            }
            throw error
        } catch {
            let clientError = AIClientError.networkError(error)
            await MainActor.run { [weak self] in
                self?.streamingDelegate?.didFail(error: clientError)
            }
            throw clientError
        }
    }
    
    private static func outputLimitError() -> AIClientError {
        .apiError(
            statusCode: 413,
            message: "Anthropic reached max_tokens before completing the response. Try fewer files or increase the output token limit."
        )
    }

    /// Maps a stream `error.type` to the status used for retry/quota decisions.
    /// Mid-stream errors arrive after a 200 response, so the transport status
    /// says nothing about the failure.
    static func streamErrorStatusCode(for errorType: String?) -> Int {
        switch errorType {
        case "rate_limit_error":
            return 429
        case "overloaded_error":
            return 529
        case "api_error":
            return 502
        default:
            return 503
        }
    }

    public func checkHealth() async throws {
        let headers = try requiredHeaders()

        var request = try AIRequestSupport.makeJSONRequest(
            url: Self.modelsURL,
            method: "GET",
            headers: headers
        )
        request.timeoutInterval = min(AIRequestSupport.clampedTimeout(config.requestTimeout), 60)
        // Health checks never wake constrained/expensive radios.
        request.allowsConstrainedNetworkAccess = false
        request.allowsExpensiveNetworkAccess = false

        let session = await AIRequestSupport.session(for: config)
        let (data, response) = try await AIRequestSupport.withTransientHTTPRetry(maxElapsed: .milliseconds(Int64(request.timeoutInterval * 1_000))) {
            try await session.data(for: request)
        }
        _ = try AIRequestSupport.validateHTTPResponse(data: data, response: response)
    }
    
    public func generateText(prompt: String, systemPrompt: String? = nil) async throws -> String {
        let headers = try requiredHeaders()
        
        let url = Self.messagesURL
        
        let requestBody: [String: Any] = [
            "model": config.model,
            "max_tokens": config.maxTokens ?? 4096,
            "system": systemPrompt ?? "You are a helpful assistant.",
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": AIConfig.organizationTemperature
        ]
        
        var request = try AIRequestSupport.makeJSONRequest(
            url: url,
            headers: headers,
            body: requestBody
        )
        // Explicit timeout: never inherit the 600s resource default.
        request.timeoutInterval = AIRequestSupport.interactiveTimeout(for: config)

        let session = await AIRequestSupport.session(for: config)
        let (data, response) = try await AIRequestSupport.withTransientHTTPRetry(maxElapsed: .milliseconds(Int64(request.timeoutInterval * 1_000))) {
            try await session.data(for: request)
        }
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIClientError.apiError(statusCode: status, message: errorText)
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if json?["stop_reason"] as? String == "max_tokens" {
            throw Self.outputLimitError()
        }
        guard let text = AIRequestSupport.extractText(from: json?["content"]),
              !text.isEmpty else {
            throw AIClientError.invalidResponseFormat
        }
        
        return text
    }
}
