//
//  GitHubCopilotClient.swift
//  Sorty
//
//  GitHub Copilot API Client
//

import Foundation

public final class GitHubCopilotClient: AIClientProtocol, @unchecked Sendable {
    public let config: AIConfig
    @MainActor public weak var streamingDelegate: StreamingDelegate?
    private let testHeadersProvider: (@Sendable () async throws -> [String: String])?
    
    public init(
        config: AIConfig,
        testHeadersProvider: (@Sendable () async throws -> [String: String])? = nil
    ) {
        self.config = config
        self.testHeadersProvider = testHeadersProvider
    }
    
    private func getSession() async -> URLSession {
        return await AIRequestSupport.session(for: config)
    }

    private func ensureNetworkAllowed(_ url: URL) throws {
        try AIRequestSupport.ensureNetworkAllowed(url: url)
    }
    
    private func getHeaders() async throws -> [String: String] {
        if let testHeadersProvider {
            return try await testHeadersProvider()
        }
        let token = try await GitHubCopilotAuthManager.shared.getCopilotToken()
        return [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "Editor-Version": "vscode/1.85.1",
            "Editor-Plugin-Version": "copilot/1.138.0",
            "User-Agent": "GithubCopilot/1.138.0"
        ]
    }

    private func shouldRetryAfterAuthFailure(statusCode: Int) -> Bool {
        statusCode == 401 || statusCode == 403
    }

    private func refreshAuthForRetry() async throws {
        _ = try await GitHubCopilotAuthManager.shared.refreshCopilotTokenAfterCacheInvalidation()
    }
    
    public func analyze(files: [FileItem], customInstructions: String? = nil, personaPrompt: String? = nil, temperature: Double? = nil) async throws -> OrganizationPlan {
        let url = URL(string: "https://api.githubcopilot.com/chat/completions")!
        try ensureNetworkAllowed(url)
        
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
        
        var requestBody: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": AIConfig.organizationTemperature,
            // Copilot often requires stream=true for best results, but supports false too.
        ]
        
        if let maxTokens = config.maxTokens {
            requestBody["max_tokens"] = maxTokens
        }
        Self.configureReasoningEffort(in: &requestBody, effort: config.reasoningEffort)
        
        let finalRequestBody = requestBody // Fix mutating warning by assigning to let
        
        if config.enableStreaming {
            return try await analyzeWithStreaming(url: url, requestBody: finalRequestBody, files: files)
        } else {
            return try await analyzeNonStreaming(url: url, requestBody: finalRequestBody, files: files)
        }
    }
    
    public func analyzeWithImages(files: [FileItem], imageData: [String: Data], customInstructions: String? = nil, personaPrompt: String? = nil, temperature: Double? = nil) async throws -> OrganizationPlan {
        // Check if model supports vision - if not, fall back to text-only
        let supportsVision = await ModelCatalog.shared.supportsVision(modelId: config.model, provider: config.provider)
        
        guard supportsVision, !imageData.isEmpty else {
            return try await analyze(files: files, customInstructions: customInstructions, personaPrompt: personaPrompt, temperature: temperature)
        }
        
        let url = URL(string: "https://api.githubcopilot.com/chat/completions")!
        try ensureNetworkAllowed(url)
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
            analyzedImageFilenames: Array(orderedImageNames.prefix(5))
        )
        
        // Build multimodal content array (OpenAI-compatible format)
        var userContent: [[String: Any]] = [
            ["type": "text", "text": userPrompt]
        ]
        
        // Add images (limit to first 5 to avoid token limits)
        for filename in orderedImageNames.prefix(5) {
            guard let data = imageData[filename] else { continue }
            let base64 = data.base64EncodedString()
            let mimeType = filename.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg"
            userContent.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:\(mimeType);base64,\(base64)",
                    "detail": config.effectiveVisionDetailLevel.rawValue
                ]
            ])
        }
        
        var requestBody: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ],
            "temperature": AIConfig.organizationTemperature
        ]
        
        if let maxTokens = config.maxTokens {
            requestBody["max_tokens"] = maxTokens
        }
        Self.configureReasoningEffort(in: &requestBody, effort: config.reasoningEffort)
        
        if config.enableStreaming {
            return try await analyzeWithStreaming(url: url, requestBody: requestBody, files: files)
        } else {
            return try await analyzeNonStreaming(url: url, requestBody: requestBody, files: files)
        }
    }

    static func orderedImageFilenames(from imageData: [String: Data]) -> [String] {
        imageData.keys.sorted()
    }
    
    public func fetchAvailableModels() async throws -> [String] {
        let url = URL(string: "https://api.githubcopilot.com/models")!
        try ensureNetworkAllowed(url)
        DebugLogger.log("Fetching available models")
        let session = await getSession()
        let fallbackModels = [
            "gpt-5-mini",
            "gpt-5.4-mini",
            "gpt-5.4",
            "gpt-4o",
            "gpt-5.3-codex",
            "claude-sonnet-4.6",
            "claude-opus-4.6",
            "claude-haiku-4.5",
            "gemini-3.1-pro",
            "gemini-3-flash"
        ]
        var didRetryAfterAuthFailure = false

        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"

            let headers = try await getHeaders()
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    return fallbackModels
                }

                if !(200...299).contains(httpResponse.statusCode) {
                    if shouldRetryAfterAuthFailure(statusCode: httpResponse.statusCode),
                       !didRetryAfterAuthFailure {
                        didRetryAfterAuthFailure = true
                        try await refreshAuthForRetry()
                        continue
                    }
                    // Fallback models if endpoint fails or not available
                    return fallbackModels
                }

                struct ModelsResponse: Decodable {
                    let data: [ModelData]
                    struct ModelData: Decodable {
                        let id: String
                    }
                }

                let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
                let models = modelsResponse.data.map { $0.id }
                return models.isEmpty ? fallbackModels : models

            } catch {
                // Fallback on error
                DebugLogger.log("Failed to fetch models: \(error), using defaults")
                return fallbackModels
            }
        }
    }
    
    public func checkHealth() async throws {
        let url = URL(string: "https://api.githubcopilot.com/models")!
        try ensureNetworkAllowed(url)
        let session = await getSession()
        var didRetryAfterAuthFailure = false

        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = min(config.requestTimeout, 60)

            let headers = try await getHeaders()
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let (_, response) = try await AIRequestSupport.withTransientHTTPRetry {
                try await session.data(for: request)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIClientError.invalidResponse
            }

            if (200...299).contains(httpResponse.statusCode) {
                return
            }

            if shouldRetryAfterAuthFailure(statusCode: httpResponse.statusCode),
               !didRetryAfterAuthFailure {
                didRetryAfterAuthFailure = true
                try await refreshAuthForRetry()
                continue
            }

            throw AIClientError.apiError(statusCode: httpResponse.statusCode, message: "Health check failed")
        }
    }
    
    public func generateText(prompt: String, systemPrompt: String? = nil) async throws -> String {
        let url = URL(string: "https://api.githubcopilot.com/chat/completions")!
        try ensureNetworkAllowed(url)
        
        var requestBody: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt ?? "You are a helpful assistant."],
                ["role": "user", "content": prompt]
            ],
            "temperature": AIConfig.organizationTemperature
        ]
        Self.configureReasoningEffort(in: &requestBody, effort: config.reasoningEffort)
        
        let session = await getSession()
        var didRetryAfterAuthFailure = false

        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"

            let headers = try await getHeaders()
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

            let (data, response) = try await AIRequestSupport.withTransientHTTPRetry {
                try await session.data(for: request)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIClientError.invalidResponse
            }

            if !(200...299).contains(httpResponse.statusCode) {
                if shouldRetryAfterAuthFailure(statusCode: httpResponse.statusCode),
                   !didRetryAfterAuthFailure {
                    didRetryAfterAuthFailure = true
                    try await refreshAuthForRetry()
                    continue
                }

                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw AIClientError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
            }

            let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let choices = jsonResponse?["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let content = AIRequestSupport.extractChatMessageText(from: firstChoice),
                  !content.isEmpty else {
                throw AIClientError.invalidResponseFormat
            }

            return content
        }
    }

    static func configureReasoningEffort(
        in requestBody: inout [String: Any],
        effort: ReasoningEffort
    ) {
        guard let requestValue = effort.requestValue else { return }
        requestBody.removeValue(forKey: "temperature")
        requestBody["reasoning_effort"] = requestValue
    }
    
    // MARK: - Non-Streaming Implementation
    
    private func analyzeNonStreaming(url: URL, requestBody: [String: Any], files: [FileItem]) async throws -> OrganizationPlan {
        try ensureNetworkAllowed(url)
        let startTime = Date()
        let session = await getSession()
        var didRetryAfterAuthFailure = false

        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"

            let headers = try await getHeaders()
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

            do {
                let (data, response) = try await AIRequestSupport.withTransientHTTPRetry {
                    try await session.data(for: request)
                }
                let endTime = Date()
                let duration = endTime.timeIntervalSince(startTime)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AIClientError.invalidResponse
                }

                if !(200...299).contains(httpResponse.statusCode) {
                    if shouldRetryAfterAuthFailure(statusCode: httpResponse.statusCode),
                       !didRetryAfterAuthFailure {
                        didRetryAfterAuthFailure = true
                        try await refreshAuthForRetry()
                        continue
                    }
                    let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw AIClientError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
                }

                let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                guard let choices = jsonResponse?["choices"] as? [[String: Any]],
                      let firstChoice = choices.first,
                      let content = AIRequestSupport.extractChatMessageText(from: firstChoice),
                      !content.isEmpty else {
                    throw AIClientError.invalidResponseFormat
                }

                // Calculate stats
                let estimatedTokens = content.count / 4
                let tps = duration > 0 ? Double(estimatedTokens) / duration : 0

                let stats = GenerationStats(
                    duration: duration,
                    tps: tps,
                    ttft: duration, // approximate
                    totalTokens: estimatedTokens,
                    model: config.model,
                    filesScanned: files.count,
                    totalFileSize: files.reduce(0) { $0 + $1.size }
                )

                var plan = try ResponseParser.parseResponse(content, originalFiles: files, mode: config.mode)
                plan.generationStats = stats
                return plan
            } catch let error as AIClientError {
                throw error
            } catch {
                throw AIClientError.networkError(error)
            }
        }
    }
    
    // MARK: - Streaming Implementation
    
    private func analyzeWithStreaming(url: URL, requestBody: [String: Any], files: [FileItem]) async throws -> OrganizationPlan {
        try ensureNetworkAllowed(url)
        var streamingRequestBody = requestBody
        streamingRequestBody["stream"] = true

        let startTime = Date()
        let session = await getSession()
        var didRetryAfterAuthFailure = false

        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"

            let headers = try await getHeaders()
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: streamingRequestBody)

            var firstTokenTime: Date?
            var accumulatedContentBuffer = ""

            do {
                let (bytes, response) = try await AIRequestSupport.withTransientHTTPRetry {
                    try await session.bytes(for: request)
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AIClientError.invalidResponse
                }

                if !(200...299).contains(httpResponse.statusCode) {
                    var errorData = Data()
                    for try await byte in bytes {
                        errorData.append(byte)
                    }
                    if shouldRetryAfterAuthFailure(statusCode: httpResponse.statusCode),
                       !didRetryAfterAuthFailure {
                        didRetryAfterAuthFailure = true
                        try await refreshAuthForRetry()
                        continue
                    }
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    throw AIClientError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
                }

                for try await line in bytes.lines {
                    guard let jsonString = AIRequestSupport.sseDataPayload(from: line) else { continue }

                    if jsonString == "[DONE]" {
                        break
                    }

                    guard let jsonData = jsonString.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                          let parsedChunk = Self.parseStreamChunk(from: json) else {
                        continue
                    }

                    let hasVisibleChunk = parsedChunk.visibleChunk?.isEmpty == false
                    let hasCompletionChunk = parsedChunk.completionChunk?.isEmpty == false
                    if firstTokenTime == nil, hasVisibleChunk || hasCompletionChunk {
                        firstTokenTime = Date()
                    }

                    if let completionChunk = parsedChunk.completionChunk, !completionChunk.isEmpty {
                        accumulatedContentBuffer += completionChunk
                    }

                    if let visibleChunk = parsedChunk.visibleChunk, !visibleChunk.isEmpty {
                        await MainActor.run {
                            streamingDelegate?.didReceiveChunk(visibleChunk)
                        }
                    }
                }

                let endTime = Date()
                let duration = endTime.timeIntervalSince(startTime)
                let ttft = firstTokenTime?.timeIntervalSince(startTime) ?? duration
                let estimatedTokens = accumulatedContentBuffer.count / 4
                let tps = duration > 0 ? Double(estimatedTokens) / duration : 0

                let stats = GenerationStats(
                    duration: duration,
                    tps: tps,
                    ttft: ttft,
                    totalTokens: estimatedTokens,
                    model: config.model,
                    filesScanned: files.count,
                    totalFileSize: files.reduce(0) { $0 + $1.size }
                )

                let finalContent = accumulatedContentBuffer
                await MainActor.run {
                    streamingDelegate?.didComplete(content: finalContent)
                }

                var plan: OrganizationPlan
                do {
                    plan = try ResponseParser.parseResponse(accumulatedContentBuffer, originalFiles: files, mode: config.mode)
                } catch {
                    // Try partial extraction before giving up
                    if let partialPlan = ResponseParser.extractPartialResults(accumulatedContentBuffer, originalFiles: files, mode: config.mode) {
                        plan = partialPlan
                    } else {
                        let clientError = AIClientError.jsonDecodingError(context: error.localizedDescription)
                        await MainActor.run {
                            streamingDelegate?.didFail(error: clientError)
                        }
                        throw clientError
                    }
                }
                plan.generationStats = stats
                return plan
            } catch let error as AIClientError {
                await MainActor.run {
                    streamingDelegate?.didFail(error: error)
                }
                throw error
            } catch {
                let clientError = AIClientError.networkError(error)
                await MainActor.run {
                    streamingDelegate?.didFail(error: clientError)
                }
                throw clientError
            }
        }
    }

    private struct StreamChunk {
        let completionChunk: String?
        let visibleChunk: String?
    }

    private static func parseStreamChunk(from json: [String: Any]) -> StreamChunk? {
        guard let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first else {
            return nil
        }

        let delta = firstChoice["delta"] as? [String: Any]
        let completionChunk = AIRequestSupport.extractChatDeltaText(from: firstChoice)
        let reasoningChunk = extractReasoningChunk(from: delta)
        let visibleChunk = reasoningChunk ?? completionChunk

        if completionChunk == nil && visibleChunk == nil {
            return nil
        }

        return StreamChunk(completionChunk: completionChunk, visibleChunk: visibleChunk)
    }

    private static func extractReasoningChunk(from delta: [String: Any]?) -> String? {
        guard let delta else { return nil }

        let keys = ["reasoning", "reasoning_content", "thinking", "analysis"]
        for key in keys {
            if let chunk = AIRequestSupport.extractText(from: delta[key]), !chunk.isEmpty {
                return chunk
            }
        }

        if let details = delta["reasoning_details"],
           let combined = AIRequestSupport.extractText(from: details),
           !combined.isEmpty {
            return combined
        }

        return nil
    }
}
