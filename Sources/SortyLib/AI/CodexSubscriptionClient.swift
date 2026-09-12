//
//  CodexSubscriptionClient.swift
//  Sorty
//
//  Uses Codex CLI account sign-in for ChatGPT subscription-backed OpenAI inference.
//

import Foundation

public struct CodexAvailableModel: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let inputModalities: [String]
    public let serviceTiers: [String]
    public let supportedReasoningEfforts: [ReasoningEffort]
    public let defaultReasoningEffort: ReasoningEffort?

    public init(
        id: String,
        displayName: String,
        inputModalities: [String],
        serviceTiers: [String],
        supportedReasoningEfforts: [ReasoningEffort] = [],
        defaultReasoningEffort: ReasoningEffort? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.inputModalities = inputModalities
        self.serviceTiers = serviceTiers
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }
}

public enum CodexSubscriptionSettings {
    public static let fastModeKey = "codexSubscriptionFastMode"

    public static var isFastModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: fastModeKey)
    }
}

public final class CodexSubscriptionClient: AIClientProtocol, Sendable {
    public let config: AIConfig
    @MainActor public weak var streamingDelegate: StreamingDelegate?

    public init(config: AIConfig) {
        self.config = config
    }

    public func analyze(
        files: [FileItem],
        customInstructions: String? = nil,
        personaPrompt: String? = nil,
        temperature: Double? = nil
    ) async throws -> OrganizationPlan {
        let systemPrompt = config.systemPromptOverride ?? PromptBuilder.buildSystemPrompt(
            personaInfo: personaPrompt ?? "",
            mode: config.mode,
            enableTagging: config.enableFileTagging
        )
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
        let prompt = Self.organizationPrompt(systemPrompt: systemPrompt, userPrompt: userPrompt)
        let estimatedPromptTokens = PromptBuilder.estimateTokens(systemPrompt + userPrompt)
        let start = Date()
        let response = try await runCodex(
            prompt: prompt,
            imageFiles: [],
            usesOrganizationSchema: true
        )
        let duration = Date().timeIntervalSince(start)

        var plan = try parseOrganizationResponse(response, files: files)
        plan.generationStats = GenerationStats(
            duration: duration,
            tps: duration > 0 ? Double(response.count / 4) / duration : 0,
            ttft: duration,
            totalTokens: response.count / 4,
            model: config.model,
            filesScanned: files.count,
            totalFileSize: files.reduce(0) { $0 + $1.size },
            promptTokens: estimatedPromptTokens,
            provider: AIProvider.openAI.displayName
        )
        return plan
    }

    public func analyzeWithImages(
        files: [FileItem],
        imageData: [String: Data],
        customInstructions: String? = nil,
        personaPrompt: String? = nil,
        temperature: Double? = nil
    ) async throws -> OrganizationPlan {
        let imageFiles = try Self.writeTemporaryImages(imageData)
        defer {
            for url in imageFiles {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let systemPrompt = config.systemPromptOverride ?? PromptBuilder.buildSystemPrompt(
            personaInfo: personaPrompt ?? "",
            mode: config.mode,
            enableTagging: config.enableFileTagging
        )
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
            analyzedImageFilenames: imageData.keys.sorted()
        )
        let prompt = Self.organizationPrompt(systemPrompt: systemPrompt, userPrompt: userPrompt)
        let estimatedPromptTokens = PromptBuilder.estimateTokens(systemPrompt + userPrompt)
        let start = Date()
        let response = try await runCodex(
            prompt: prompt,
            imageFiles: imageFiles,
            usesOrganizationSchema: true
        )
        let duration = Date().timeIntervalSince(start)

        var plan = try parseOrganizationResponse(response, files: files)
        plan.generationStats = GenerationStats(
            duration: duration,
            tps: duration > 0 ? Double(response.count / 4) / duration : 0,
            ttft: duration,
            totalTokens: response.count / 4,
            model: config.model,
            filesScanned: files.count,
            totalFileSize: files.reduce(0) { $0 + $1.size },
            promptTokens: estimatedPromptTokens,
            provider: AIProvider.openAI.displayName
        )
        return plan
    }

    public func generateText(prompt: String, systemPrompt: String? = nil) async throws -> String {
        let combinedPrompt = [
            systemPrompt,
            prompt
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")

        return try await runCodex(
            prompt: combinedPrompt,
            imageFiles: [],
            usesOrganizationSchema: false
        )
    }

    public func checkHealth() async throws {
        guard let serviceURL = URL(string: "https://api.openai.com") else {
            throw AIClientError.invalidURL
        }
        try AIRequestSupport.ensureNetworkAllowed(url: serviceURL)

        guard Self.resolveCodexExecutablePath() != nil else {
            throw AIClientError.apiError(
                statusCode: 501,
                message: "Codex CLI is required. Install with: npm i -g @openai/codex"
            )
        }

        switch CodexCLIAuthManager.readLoginStatus() {
        case .chatGPT, .accessToken:
            return
        case .apiKey:
            throw AIClientError.apiError(
                statusCode: 401,
                message: "Codex CLI is signed in with an API key. Use ChatGPT sign-in or a Codex access token for subscription-backed inference."
            )
        case .notLoggedIn:
            throw AIClientError.apiError(
                statusCode: 401,
                message: "Codex CLI sign-in is required. Reauthenticate your ChatGPT subscription in Sorty settings."
            )
        case .unavailable(let message):
            throw AIClientError.apiError(
                statusCode: 401,
                message: message ?? "Codex CLI sign-in could not be verified. Run `codex login status` in Terminal."
            )
        }
    }

    public nonisolated static func availableModels() async throws -> [CodexAvailableModel] {
        guard let serviceURL = URL(string: "https://api.openai.com") else {
            throw AIClientError.invalidURL
        }
        try AIRequestSupport.ensureNetworkAllowed(url: serviceURL)

        return try await Task.detached(priority: .userInitiated) {
            guard let codexPath = resolveCodexExecutablePath() else {
                throw AIClientError.apiError(
                    statusCode: 501,
                    message: "Codex CLI is required. Install with: npm i -g @openai/codex"
                )
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: codexPath)
            process.arguments = ["app-server", "--stdio"]

            let inputPipe = Pipe()
            let outputPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice

            try process.run()
            defer {
                inputPipe.fileHandleForWriting.closeFile()
                if process.isRunning {
                    process.terminate()
                }
            }

            let requests = [
                #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"sorty","title":"Sorty","version":"1"}}}"#,
                #"{"id":2,"method":"model/list","params":{"includeHidden":false,"limit":100}}"#
            ].joined(separator: "\n") + "\n"
            try inputPipe.fileHandleForWriting.write(contentsOf: Data(requests.utf8))

            var bufferedData = Data()
            while process.isRunning {
                let chunk = outputPipe.fileHandleForReading.availableData
                guard !chunk.isEmpty else { break }
                bufferedData.append(chunk)

                while let newline = bufferedData.firstIndex(of: 0x0A) {
                    let lineData = bufferedData[..<newline]
                    bufferedData.removeSubrange(...newline)
                    guard
                        let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                        (json["id"] as? Int) == 2
                    else {
                        continue
                    }

                    if let error = json["error"] as? [String: Any] {
                        let message = error["message"] as? String ?? "Codex could not provide its model list."
                        throw AIClientError.apiError(statusCode: 500, message: message)
                    }

                    guard
                        let result = json["result"] as? [String: Any],
                        let models = result["data"] as? [[String: Any]]
                    else {
                        throw AIClientError.jsonDecodingError(context: "Invalid Codex model-list response")
                    }

                    let availableModels: [CodexAvailableModel] = models.compactMap { model -> CodexAvailableModel? in
                        guard let id = model["id"] as? String else { return nil }
                        return CodexAvailableModel(
                            id: id,
                            displayName: model["displayName"] as? String ?? id,
                            inputModalities: model["inputModalities"] as? [String] ?? [],
                            serviceTiers: (model["serviceTiers"] as? [[String: Any]])?
                                .compactMap { $0["id"] as? String } ?? [],
                            supportedReasoningEfforts: (model["supportedReasoningEfforts"] as? [[String: Any]])?
                                .compactMap { item in
                                    guard let value = item["reasoningEffort"] as? String else { return nil }
                                    return ReasoningEffort(rawValue: value)
                                } ?? [],
                            defaultReasoningEffort: (model["defaultReasoningEffort"] as? String)
                                .map(ReasoningEffort.init(rawValue:))
                        )
                    }
                    return availableModels
                }
            }

            throw AIClientError.apiError(
                statusCode: 500,
                message: "Codex ended before returning its model list."
            )
        }.value
    }

    private func runCodex(
        prompt: String,
        imageFiles: [URL],
        usesOrganizationSchema: Bool
    ) async throws -> String {
        try await checkHealth()
        guard let codexPath = Self.resolveCodexExecutablePath() else {
            throw AIClientError.apiError(
                statusCode: 501,
                message: "Codex CLI is required. Install with: npm i -g @openai/codex"
            )
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorty-codex-\(UUID().uuidString).txt")
        let diagnosticsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorty-codex-diagnostics-\(UUID().uuidString).txt")
        let schemaURL = usesOrganizationSchema
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("sorty-codex-schema-\(UUID().uuidString).json")
            : nil
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: diagnosticsURL)
            if let schemaURL {
                try? FileManager.default.removeItem(at: schemaURL)
            }
        }
        if let schemaURL {
            try Self.writeOrganizationResponseSchema(to: schemaURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = Self.codexArguments(
            model: config.model,
            outputURL: outputURL,
            schemaURL: schemaURL,
            imageFiles: imageFiles,
            fastMode: CodexSubscriptionSettings.isFastModeEnabled,
            reasoningEffort: config.reasoningEffort
        )

        let inputPipe = Pipe()
        FileManager.default.createFile(atPath: diagnosticsURL.path, contents: nil)
        let diagnosticsHandle = try FileHandle(forWritingTo: diagnosticsURL)
        let diagnosticsLock = NSLock()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let stdoutStreamer = CodexOutputStreamer { [weak self] chunk in
            guard let self else { return }
            Task { @MainActor in
                self.streamingDelegate?.didReceiveChunk(chunk)
            }
        }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            diagnosticsLock.lock()
            try? diagnosticsHandle.write(contentsOf: data)
            diagnosticsLock.unlock()
            stdoutStreamer.process(data)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            diagnosticsLock.lock()
            try? diagnosticsHandle.write(contentsOf: data)
            diagnosticsLock.unlock()
        }

        do {
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { _ in
                        continuation.resume()
                    }
                    do {
                        try process.run()
                        if let promptData = prompt.data(using: .utf8) {
                            try inputPipe.fileHandleForWriting.write(contentsOf: promptData)
                        }
                        try inputPipe.fileHandleForWriting.close()
                    } catch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                if process.isRunning {
                    process.terminate()
                }
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            process.terminate()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? diagnosticsHandle.close()
            throw CancellationError()
        } catch {
            process.terminate()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? diagnosticsHandle.close()
            throw AIClientError.networkError(error)
        }
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        stdoutStreamer.finish()
        try? diagnosticsHandle.close()

        let diagnosticData = (try? Data(contentsOf: diagnosticsURL)) ?? Data()
        let diagnostics = String(data: diagnosticData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw AIClientError.apiError(
                statusCode: Int(process.terminationStatus),
                message: diagnostics.isEmpty ? "Codex CLI exited without a response." : diagnostics
            )
        }

        let response = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let response, !response.isEmpty else {
            throw AIClientError.invalidResponseFormat
        }
        await MainActor.run {
            streamingDelegate?.didComplete(content: response)
        }
        return response
    }

    private func parseOrganizationResponse(_ response: String, files: [FileItem]) throws -> OrganizationPlan {
        do {
            return try ResponseParser.parseResponse(response, originalFiles: files, mode: config.mode)
        } catch {
            if let partialPlan = ResponseParser.extractPartialResults(response, originalFiles: files, mode: config.mode) {
                return partialPlan
            }
            throw AIClientError.jsonDecodingError(context: error.localizedDescription)
        }
    }

    private nonisolated static func organizationPrompt(systemPrompt: String, userPrompt: String) -> String {
        """
        \(systemPrompt)

        \(userPrompt)

        Return only the JSON object that matches Sorty's requested schema. Do not include Markdown fences, commentary, progress notes, or explanations.
        """
    }

    nonisolated static func codexArguments(
        model: String,
        outputURL: URL,
        schemaURL: URL?,
        imageFiles: [URL],
        fastMode: Bool = false,
        reasoningEffort: ReasoningEffort = .automatic
    ) -> [String] {
        var arguments = [
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--skip-git-repo-check",
            "--sandbox",
            "read-only",
            "--json",
            "--output-last-message",
            outputURL.path,
            "--model",
            model
        ]

        if fastMode {
            arguments += [
                "--enable",
                "fast_mode",
                "--config",
                #"service_tier="fast""#
            ]
        }

        if let requestValue = reasoningEffort.requestValue {
            arguments += [
                "--config",
                #"model_reasoning_effort="\#(requestValue)""#
            ]
        }

        if let schemaURL {
            arguments += ["--output-schema", schemaURL.path]
        }

        for imageFile in imageFiles {
            arguments += ["--image", imageFile.path]
        }

        arguments.append("-")
        return arguments
    }

    private nonisolated static func writeOrganizationResponseSchema(to url: URL) throws {
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "session_name": ["type": "string"],
                "folders": [
                    "type": "array",
                    "items": folderSchema()
                ],
                "folder_assignments": [
                    "type": ["array", "null"],
                    "items": folderSchema()
                ],
                "unorganized": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "filename": ["type": "string"],
                            "reason": ["type": "string"]
                        ],
                        "required": ["filename", "reason"]
                    ]
                ],
                "unorganized_ids": [
                    "type": ["array", "null"],
                    "items": ["type": "integer"]
                ],
                "notes": ["type": "string"],
                "learning_action": [
                    "anyOf": [
                        ["type": "null"],
                        [
                            "type": "object",
                            "additionalProperties": false,
                            "properties": [
                                "name": [
                                    "type": "string",
                                    "enum": [LearningToolCall.excludeCurrentRunToolName],
                                ],
                                "reason": ["type": "string"],
                                "source": [
                                    "type": "string",
                                    "enum": ["direct_instructions", "persona"],
                                ],
                            ],
                            "required": ["name", "reason", "source"],
                        ],
                    ]
                ]
            ],
            "required": [
                "session_name",
                "folders",
                "folder_assignments",
                "unorganized",
                "unorganized_ids",
                "notes",
                "learning_action",
            ],
            "$defs": [
                "folder": folderSchema()
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private nonisolated static func folderSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "name": ["type": "string"],
                "description": ["type": ["string", "null"]],
                "reasoning": ["type": ["string", "null"]],
                "subfolders": [
                    "type": ["array", "null"],
                    "items": ["$ref": "#/$defs/folder"]
                ],
                "files": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "filename": ["type": "string"],
                            "suggested_name": ["type": ["string", "null"]],
                            "rename_reason": ["type": ["string", "null"]],
                            "rename_confidence": ["type": ["number", "null"]],
                            "tags": [
                                "type": ["array", "null"],
                                "items": ["type": "string"]
                            ],
                            "comment": ["type": ["string", "null"]]
                        ],
                        "required": [
                            "filename",
                            "suggested_name",
                            "rename_reason",
                            "rename_confidence",
                            "tags",
                            "comment"
                        ]
                    ]
                ],
                "tags": [
                    "type": ["array", "null"],
                    "items": ["type": "string"]
                ],
                "comment": ["type": ["string", "null"]],
                "semantic_tags": [
                    "type": ["array", "null"],
                    "items": ["type": "string"]
                ],
                "confidence": ["type": ["number", "null"]],
                "rule_id": ["type": ["string", "null"]],
                "file_ids": [
                    "type": ["array", "null"],
                    "items": ["type": "integer"]
                ],
                "rename_suggestions": [
                    "type": ["array", "null"],
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "file_id": ["type": "integer"],
                            "suggested_name": ["type": ["string", "null"]],
                            "rename_reason": ["type": ["string", "null"]],
                            "rename_confidence": ["type": ["number", "null"]]
                        ],
                        "required": [
                            "file_id",
                            "suggested_name",
                            "rename_reason",
                            "rename_confidence"
                        ]
                    ]
                ]
            ],
            "required": [
                "name",
                "description",
                "reasoning",
                "subfolders",
                "files",
                "tags",
                "comment",
                "semantic_tags",
                "confidence",
                "rule_id",
                "file_ids",
                "rename_suggestions"
            ]
        ]
    }

    private nonisolated static func writeTemporaryImages(_ imageData: [String: Data]) throws -> [URL] {
        try imageData.keys.sorted().map { name in
            let safeName = URL(fileURLWithPath: name).lastPathComponent
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("sorty-codex-\(UUID().uuidString)-\(safeName)")
            guard let data = imageData[name] else { return url }
            try data.write(to: url, options: .atomic)
            return url
        }
    }

    private static let executablePathCacheLock = NSLock()
    nonisolated(unsafe) private static var executablePathCache: (path: String?, resolvedAt: Date)?
    /// Bounds how often a missing install re-runs the `which` subprocess.
    private static let executablePathCacheLifetime: TimeInterval = 10

    /// Locates the Codex CLI, caching the outcome briefly so the status probes
    /// clustered around launch and setup reconciliation do not each spawn
    /// `which`. A cached hit is re-validated against the file system.
    nonisolated static func resolveCodexExecutablePath() -> String? {
        executablePathCacheLock.lock()
        let cached = executablePathCache
        executablePathCacheLock.unlock()

        if let cached, Date().timeIntervalSince(cached.resolvedAt) < executablePathCacheLifetime {
            if let path = cached.path {
                if FileManager.default.fileExists(atPath: path) { return path }
            } else {
                return nil
            }
        }

        let resolved = locateCodexExecutable()
        executablePathCacheLock.lock()
        executablePathCache = (path: resolved, resolvedAt: Date())
        executablePathCacheLock.unlock()
        return resolved
    }

    private nonisolated static func locateCodexExecutable() -> String? {
        let paths = [
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.npm-global/bin/codex"
        ]

        for path in paths where FileManager.default.fileExists(atPath: path) {
            return path
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "codex"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let resolvedPath = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !resolvedPath.isEmpty,
                FileManager.default.fileExists(atPath: resolvedPath) else {
                return nil
            }
            return resolvedPath
        } catch {
            return nil
        }
    }
}

private final class CodexOutputStreamer: @unchecked Sendable {
    private let lock = NSLock()
    private var lineBuffer = ""
    private let onChunk: @Sendable (String) -> Void

    init(onChunk: @escaping @Sendable (String) -> Void) {
        self.onChunk = onChunk
    }

    func process(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }

        lock.lock()
        lineBuffer += text
        let lines = lineBuffer.split(separator: "\n", omittingEmptySubsequences: false)
        let completeLines = lineBuffer.hasSuffix("\n") ? lines : Array(lines.dropLast())
        lineBuffer = lineBuffer.hasSuffix("\n") ? "" : String(lines.last ?? "")
        lock.unlock()

        for line in completeLines {
            processLine(String(line))
        }
    }

    func finish() {
        lock.lock()
        let pending = lineBuffer
        lineBuffer = ""
        lock.unlock()

        if !pending.isEmpty {
            processLine(pending)
        }
    }

    private func processLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let chunk = Self.extractVisibleChunk(from: json) {
            onChunk(chunk)
        }
    }

    private static func extractVisibleChunk(from json: [String: Any]) -> String? {
        if let type = json["type"] as? String {
            switch type {
            case "agent_message_delta", "response.output_text.delta", "message_delta",
                 "agent_reasoning_delta", "response.reasoning.delta", "reasoning_delta":
                return nonEmptyString(json["delta"] ?? json["content"] ?? json["text"] ?? json["summary"])
            case "agent_message", "assistant_message", "message":
                return nonEmptyString(json["message"] ?? json["content"] ?? json["text"])
            case "reasoning":
                return nonEmptyString(json["text"] ?? json["summary"] ?? json["content"])
            case "item.completed", "item.updated":
                if let item = json["item"] as? [String: Any] {
                    return extractVisibleChunk(from: item)
                }
            default:
                break
            }
        }

        if let item = json["item"] as? [String: Any],
           let chunk = extractVisibleChunk(from: item) {
            return chunk
        }

        if let message = json["message"] as? [String: Any] {
            return extractMessageContent(from: message)
        }

        if let content = json["content"] as? [[String: Any]] {
            return content.compactMap(extractMessageContent(from:)).joinedNonEmpty()
        }

        return nil
    }

    private static func extractMessageContent(from json: [String: Any]) -> String? {
        if let text = nonEmptyString(json["text"] ?? json["content"] ?? json["delta"]) {
            return text
        }

        if let content = json["content"] as? [[String: Any]] {
            return content.compactMap(extractMessageContent(from:)).joinedNonEmpty()
        }

        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}

private extension Array where Element == String {
    func joinedNonEmpty() -> String? {
        let value = joined()
        return value.isEmpty ? nil : value
    }
}
