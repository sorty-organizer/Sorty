
//
//  AppleFoundationModelClient.swift
//  Sorty
//
//  Apple Foundation Models Integration for macOS 26+
//  Uses on-device Apple Intelligence for file organization
//

import Foundation

// NOTE: This client uses futuristic/private APIs (FoundationModels).
#if canImport(FoundationModels) && os(macOS)
import FoundationModels

@available(macOS 26.0, *)
public final class AppleFoundationModelClient: AIClientProtocol, @unchecked Sendable {
    public let config: AIConfig
    @MainActor public weak var streamingDelegate: StreamingDelegate?
    
    public init(config: AIConfig) {
        self.config = config
    }
    
    public func analyze(files: [FileItem], customInstructions: String? = nil, personaPrompt: String? = nil, temperature: Double? = nil) async throws -> OrganizationPlan {
        let startTime = Date()
        
        // Verify availability first
        guard Self.isAvailable() else {
            throw AIClientError.apiError(statusCode: 503, message: Self.unavailabilityReason)
        }

        do {
            return try await analyzeSingleRequest(
                files: files,
                customInstructions: customInstructions,
                personaPrompt: personaPrompt,
                startTime: startTime
            )
        } catch let error as AIClientError where Self.isContextLimitError(error) {
            if files.count > 1 {
                DebugLogger.log("AFM context limit reached for \(files.count) files. Retrying with smaller requests.")
                return try await analyzeInAdaptiveBatches(
                    files: files,
                    customInstructions: customInstructions,
                    personaPrompt: personaPrompt,
                    overallStartTime: startTime
                )
            }
            throw AIClientError.apiError(
                statusCode: 413,
                message: "The folder contents exceed Apple Intelligence's on-device context limits. Try organizing a smaller folder or switching to a cloud AI provider."
            )
        }
    }
    
    public func analyzeWithImages(files: [FileItem], imageData: [String: Data], customInstructions: String? = nil, personaPrompt: String? = nil, temperature: Double? = nil) async throws -> OrganizationPlan {
        // AFM doesn't yet support multimodal analysis via this private API.
        // Fallback to text analysis.
        if config.enableVision, !imageData.isEmpty {
            DebugLogger.log("AppleFoundationModelClient: Vision is enabled but multimodal analysis is unavailable; falling back to text-only.")
        }
        return try await analyze(files: files, customInstructions: customInstructions, personaPrompt: personaPrompt, temperature: temperature)
    }
    
    public func checkHealth() async throws {
        // Verify availability
        guard Self.isAvailable() else {
            throw AIClientError.apiError(statusCode: 503, message: Self.unavailabilityReason)
        }
    }
    
    public func generateText(prompt: String, systemPrompt: String? = nil) async throws -> String {
        // Verify availability first
        guard Self.isAvailable() else {
            throw AIClientError.apiError(statusCode: 503, message: Self.unavailabilityReason)
        }
        
        do {
            // Create a language model session with the system instructions
            let session = LanguageModelSession(instructions: systemPrompt ?? "You are a helpful assistant.")
            
            // Generate response from the model
            let response = try await session.respond(to: prompt)
            return response.content
            
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.mapGenerationError(error)
        } catch {
            throw error
        }
    }

    private static func compactionStrategies(startingWith level: PromptBuilder.CompactionLevel) -> [PromptBuilder.CompactionLevel] {
        switch level {
        case .standard:
            return [.standard, .ultra, .micro, .summary]
        case .ultra:
            return [.ultra, .micro, .summary]
        case .summary:
            return [.summary, .micro]
        case .micro:
            return [.micro, .summary]
        }
    }

    private static func isContextLimitError(_ error: AIClientError) -> Bool {
        if case .apiError(let statusCode, let message) = error {
            if statusCode == 413 { return true }
            let lowered = message.lowercased()
            return lowered.contains("context") || lowered.contains("token") || lowered.contains("length")
        }
        return false
    }

    private func analyzeSingleRequest(
        files: [FileItem],
        customInstructions: String?,
        personaPrompt: String?,
        startTime: Date
    ) async throws -> OrganizationPlan {
        // Apple Foundation Models have a small on-device context window.
        // Start with aggressive compaction to avoid context limit errors.
        let compactionLevel = PromptBuilder.selectCompactionLevel(
            files: files,
            config: config,
            customInstructions: customInstructions,
            personaPrompt: personaPrompt,
            maxTokens: 600
        )

        let strategies = Self.compactionStrategies(startingWith: compactionLevel)
        var lastGenerationError: LanguageModelSession.GenerationError?
        var lastError: Error?

        for (index, strategy) in strategies.enumerated() {
            let isLastAttempt = index == strategies.count - 1
            var prompts = PromptBuilder.promptPair(
                for: strategy,
                config: config,
                files: files
            )

            let preservedContext = PromptBuilder.preservedContext(
                customInstructions: customInstructions,
                personaPrompt: personaPrompt
            )
            if !preservedContext.isEmpty {
                let heading = preservedContext.contains("<user_instructions>")
                    ? "TASK INSTRUCTIONS AND SUPPORTING CONTEXT: Follow <user_instructions> before persona and labeled supporting context."
                    : "USER INSTRUCTIONS:"
                prompts.user = "\(heading) \(preservedContext)\n\n" + prompts.user
            }

            DebugLogger.log("AFM Strategy: \(strategy) compaction for \(files.count) files")

            // A cancel must stop the retry loop, not fall through to another
            // local generation whose result nobody will use.
            try Task.checkCancellation()

            do {
                let session = LanguageModelSession(instructions: prompts.system)
                let response = try await session.respond(to: prompts.user)
                let content = response.content

                await streamContent(content)

                var plan = try ResponseParser.parseResponse(content, originalFiles: files, mode: config.mode)
                plan.generationStats = makeStats(
                    from: content,
                    files: files,
                    startTime: startTime
                )
                return plan

            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LanguageModelSession.GenerationError {
                lastGenerationError = error
                DebugLogger.log("AFM generation failed with \(strategy) compaction: \(error.localizedDescription)")
                if isLastAttempt {
                    throw Self.mapGenerationError(error)
                }
            } catch let error as AIClientError {
                // Retry with a stricter/smaller prompt if model output was malformed.
                if case .invalidResponseFormat = error, !isLastAttempt {
                    DebugLogger.log("AFM produced invalid response format with \(strategy) compaction; retrying.")
                    continue
                }
                throw error
            } catch {
                lastError = error
                if !isLastAttempt {
                    DebugLogger.log("AFM attempt failed with \(strategy) compaction: \(error.localizedDescription). Retrying.")
                    continue
                }
            }
        }

        if let generationError = lastGenerationError {
            throw Self.mapGenerationError(generationError)
        }
        if let error = lastError {
            if error is ParserError {
                throw AIClientError.jsonDecodingError(context: error.localizedDescription)
            }
            throw AIClientError.networkError(error)
        }
        throw AIClientError.invalidResponse
    }

    private func analyzeInAdaptiveBatches(
        files: [FileItem],
        customInstructions: String?,
        personaPrompt: String?,
        overallStartTime: Date
    ) async throws -> OrganizationPlan {
        var pendingChunks: [[FileItem]] = [files]
        var completedPlans: [OrganizationPlan] = []
        var processedChunkCount = 0

        while !pendingChunks.isEmpty {
            let chunk = pendingChunks.removeFirst()
            let chunkStart = Date()

            do {
                let chunkPlan = try await analyzeSingleRequest(
                    files: chunk,
                    customInstructions: customInstructions,
                    personaPrompt: personaPrompt,
                    startTime: chunkStart
                )
                completedPlans.append(chunkPlan)
                processedChunkCount += 1
            } catch let error as AIClientError where Self.isContextLimitError(error) && chunk.count > 1 {
                let midpoint = max(1, chunk.count / 2)
                let left = Array(chunk[..<midpoint])
                let right = Array(chunk[midpoint...])
                // Depth-first split to resolve tight context limits quickly.
                pendingChunks.insert(right, at: 0)
                pendingChunks.insert(left, at: 0)
            }
        }

        var mergedSuggestions: [FolderSuggestion] = []
        var mergedUnorganizedFiles: [FileItem] = []
        var mergedUnorganizedDetails: [UnorganizedFile] = []
        var seenUnorganizedIDs: Set<UUID> = []
        var seenUnorganizedNames: Set<String> = []
        var totalTokens = 0

        for plan in completedPlans {
            mergedSuggestions.append(contentsOf: plan.suggestions)

            for file in plan.unorganizedFiles where seenUnorganizedIDs.insert(file.id).inserted {
                mergedUnorganizedFiles.append(file)
            }

            for detail in plan.unorganizedDetails where seenUnorganizedNames.insert(detail.filename).inserted {
                mergedUnorganizedDetails.append(detail)
            }

            totalTokens += plan.generationStats?.totalTokens ?? 0
        }

        let duration = Date().timeIntervalSince(overallStartTime)
        let tps = duration > 0 ? Double(totalTokens) / duration : 0
        let stats = GenerationStats(
            duration: duration,
            tps: tps,
            ttft: 0.1,
            totalTokens: totalTokens,
            model: "Apple Foundation Model",
            filesScanned: files.count,
            totalFileSize: files.reduce(0) { $0 + $1.size },
            promptTokens: nil
        )

        let notes = "Generated across \(processedChunkCount) requests to fit Apple model context limits."
        return OrganizationPlan(
            suggestions: mergedSuggestions,
            unorganizedFiles: mergedUnorganizedFiles,
            unorganizedDetails: mergedUnorganizedDetails,
            notes: notes,
            timestamp: Date(),
            version: 1,
            generationStats: stats,
            learningToolCall: completedPlans.compactMap(\.learningToolCall).first
        )
    }

    private func makeStats(
        from content: String,
        files: [FileItem],
        startTime: Date
    ) -> GenerationStats {
        let duration = Date().timeIntervalSince(startTime)
        let estimatedTokens = content.count / 4
        let tps = duration > 0 ? Double(estimatedTokens) / duration : 0

        return GenerationStats(
            duration: duration,
            tps: tps,
            ttft: 0.1, // Near instant for on-device
            totalTokens: estimatedTokens,
            model: "Apple Foundation Model",
            filesScanned: files.count,
            totalFileSize: files.reduce(0) { $0 + $1.size },
            promptTokens: nil
        )
    }

    private func streamContent(_ content: String) async {
        // The on-device model does not stream: by the time we have `content`,
        // generation already finished. Deliver it in one shot instead of
        // replaying fake incremental chunks, which only delayed the plan and
        // made the UI pretend work was still happening.
        await MainActor.run {
            streamingDelegate?.didReceiveChunk(content)
            streamingDelegate?.didComplete(content: content)
        }
    }

    private static func mapGenerationError(_ error: LanguageModelSession.GenerationError) -> AIClientError {
        let message = error.localizedDescription
        let lowered = message.lowercased()

        if lowered.contains("context") || lowered.contains("token") || lowered.contains("length") {
            return AIClientError.apiError(
                statusCode: 413,
                message: "Apple Foundation Model request exceeded local context limits. Sorty will retry with fewer files at a time. Details: \(message)"
            )
        }

        if lowered.contains("not ready") || lowered.contains("download") || lowered.contains("unavailable") {
            return AIClientError.apiError(
                statusCode: 503,
                message: "Apple Foundation Model is not ready yet. \(message)"
            )
        }

        return AIClientError.apiError(
            statusCode: 503,
            message: "Apple Foundation Model generation failed: \(message)"
        )
    }
    
    /// Check if Apple Intelligence is available on this device
    static func isAvailable() -> Bool {
        let model = SystemLanguageModel.default
        if case .available = model.availability {
            return true
        }
        return false
    }
    
    /// Get a user-friendly explanation of why Apple Intelligence is unavailable
    static var unavailabilityReason: String {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return "Apple Intelligence is available."
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This device is not eligible for Apple Intelligence. Requires Apple Silicon Mac with macOS 26 or later."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is not enabled. Enable it in System Settings > Apple Intelligence & Siri."
            case .modelNotReady:
                return "Apple Intelligence model is not ready. It may still be downloading. Please wait and try again."
            @unknown default:
                return "Apple Intelligence is unavailable for an unknown reason."
            }
        }
    }
}
#endif
