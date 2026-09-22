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
        
        let systemPrompt = config.systemPromptOverride ?? PromptBuilder.buildSystemPrompt(personaInfo: "", mode: config.mode, enableTagging: config.enableFileTagging)
        let fullSystemPrompt = personaPrompt != nil ? "\(systemPrompt)\n\nPERSONA INSTRUCTIONS:\n\(personaPrompt!)" : systemPrompt

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

        let requestBody: [String: Any] = [
            "model": config.model,
            "max_tokens": config.maxTokens ?? 4096,
            "system": fullSystemPrompt,
            "messages": [
                ["role": "user", "content": userPrompt]
            ],
            "temperature": AIConfig.organizationTemperature
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

        let systemPrompt = config.systemPromptOverride ?? PromptBuilder.buildSystemPrompt(personaInfo: "", mode: config.mode, enableTagging: config.enableFileTagging)
        let fullSystemPrompt = personaPrompt != nil ? "\(systemPrompt)\n\nPERSONA INSTRUCTIONS:\n\(personaPrompt!)" : systemPrompt
        
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
        
        // Build multimodal content for Claude Vision
        var contentArray: [[String: Any]] = [
            ["type": "text", "text": userPrompt]
        ]
        
        // Add images in Claude's format
        for name in orderedImageNames {
            guard let data = imageData[name] else { continue }
            let base64 = data.base64EncodedString()
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
            "temperature": AIConfig.organizationTemperature
        ]
        
        if config.enableStreaming {
            return try await analyzeWithStreaming(url: url, requestBody: requestBody, headers: headers, files: files, totalFileSize: AIRequestSupport.totalFileSize(of: files))
        } else {
            return try await analyzeStandard(url: url, requestBody: requestBody, headers: headers, files: files, totalFileSize: AIRequestSupport.totalFileSize(of: files))
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
            let (data, response) = try await AIRequestSupport.withTransientHTTPRetry {
                try await session.data(for: request)
            }

            _ = try AIRequestSupport.validateHTTPResponse(data: data, response: response)
            
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let text = AIRequestSupport.extractText(from: json?["content"]),
                  !text.isEmpty else {
                throw AIClientError.invalidResponseFormat
            }
            
            return try ResponseParser.parseResponse(text, originalFiles: files, mode: config.mode)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AIClientError {
            throw error
        } catch {
            throw AIClientError.networkError(error)
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
            let (bytes, response) = try await AIRequestSupport.withTransientHTTPRetry {
                try await session.bytes(for: request)
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIClientError.invalidResponse
            }
            
            if httpResponse.statusCode != 200 {
                var errorData = Data()
                for try await byte in bytes {
                    errorData.append(byte)
                }
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown streaming error"
                throw AIClientError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
            }
            
            var accumulatedContent = ""
            // Coalesce off-actor: one MainActor hop per 100ms/4KB, not per delta.
            var coalescer = StreamingChunkCoalescer()
            
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let jsonString = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if jsonString == "[DONE]" { break }

                if let data = jsonString.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                    let type = json["type"] as? String
                    var chunkText: String?

                    if type == "error" {
                        let errorObject = json["error"] as? [String: Any]
                        let message = errorObject?["message"] as? String ?? "Anthropic streaming request failed"
                        throw AIClientError.apiError(statusCode: httpResponse.statusCode, message: message)
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
            }

            if let tail = coalescer.flush() {
                await MainActor.run { [weak self] in
                    self?.streamingDelegate?.didReceiveChunk(tail)
                }
            }
            
            let finalContent = accumulatedContent
            await MainActor.run { [weak self] in
                self?.streamingDelegate?.didComplete(content: finalContent)
            }
            
            do {
                return try ResponseParser.parseResponse(accumulatedContent, originalFiles: files, mode: config.mode)
            } catch {
                if let partialPlan = ResponseParser.extractPartialResults(accumulatedContent, originalFiles: files, mode: config.mode) {
                    return partialPlan
                }
                throw AIClientError.jsonDecodingError(context: error.localizedDescription)
            }
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
    
    public func checkHealth() async throws {
        let headers = try requiredHeaders()

        var request = try AIRequestSupport.makeJSONRequest(
            url: Self.modelsURL,
            method: "GET",
            headers: headers
        )
        request.timeoutInterval = min(config.requestTimeout, 60)

        let session = await AIRequestSupport.session(for: config)
        let (data, response) = try await AIRequestSupport.withTransientHTTPRetry {
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
        let (data, response) = try await AIRequestSupport.withTransientHTTPRetry {
            try await session.data(for: request)
        }
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIClientError.apiError(statusCode: status, message: errorText)
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let text = AIRequestSupport.extractText(from: json?["content"]),
              !text.isEmpty else {
            throw AIClientError.invalidResponseFormat
        }
        
        return text
    }
}
