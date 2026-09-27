//
//  CodexSubscriptionClient.swift
//  Sorty
//
//  Uses Codex CLI account sign-in for ChatGPT subscription-backed OpenAI inference.
//

import Foundation
import Darwin

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
        let prompts = SharedOrganizePipeline.buildPrompts(
            config: config,
            files: files,
            customInstructions: customInstructions,
            personaPrompt: personaPrompt
        )
        let systemPrompt = prompts.system
        let userPrompt = prompts.user
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
        plan.generationStats = SharedOrganizePipeline.makeStats(
            config: config,
            files: files,
            duration: duration,
            ttft: duration,
            totalTokens: response.count / 4,
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

        let prompts = SharedOrganizePipeline.buildPrompts(
            config: config,
            files: files,
            customInstructions: customInstructions,
            personaPrompt: personaPrompt,
            analyzedImageFilenames: imageData.keys.sorted()
        )
        let systemPrompt = prompts.system
        let userPrompt = prompts.user
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
        plan.generationStats = SharedOrganizePipeline.makeStats(
            config: config,
            files: files,
            duration: duration,
            ttft: duration,
            totalTokens: response.count / 4,
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
        // Blocking `which`/`codex login status` probes must never run on the
        // caller's executor (often MainActor). Offload and cache the success
        // verdict briefly so clustered prewarm/setup checks share one probe.
        try await Self.checkHealthDetached()
    }

    private static func checkHealthDetached() async throws {
        let cachedAt = healthVerdictLock.withLock { healthVerdictAt }
        if let cachedAt,
           Date().timeIntervalSince(cachedAt) < healthVerdictLifetime {
            return
        }
        try await Task.detached(priority: .userInitiated) {
            guard let serviceURL = URL(string: "https://api.openai.com") else {
                throw AIClientError.invalidURL
            }
            try AIRequestSupport.ensureNetworkAllowed(url: serviceURL)

            guard await resolveCodexExecutablePathAsync() != nil else {
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
        }.value
        healthVerdictLock.withLock { healthVerdictAt = Date() }
    }

    public nonisolated static func availableModels() async throws -> [CodexAvailableModel] {
        guard let serviceURL = URL(string: "https://api.openai.com") else {
            throw AIClientError.invalidURL
        }
        try AIRequestSupport.ensureNetworkAllowed(url: serviceURL)

        return try await Task.detached(priority: .userInitiated) {
            try await fetchModelsViaAppServer()
        }.value
    }

    private nonisolated static func fetchModelsViaAppServer() async throws -> [CodexAvailableModel] {
        try Task.checkCancellation()
        guard let codexPath = await resolveCodexExecutablePathAsync() else {
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
        // Watchdog: 15s global timeout. A silent app-server blocks inside
        // availableData below, which ignores task cancellation, so the
        // watchdog terminates the CLI to force EOF and unblock the loop.
        // Without this a hung CLI pins the task (and CPU) indefinitely.
        let deadline = Date().addingTimeInterval(15)
        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(15))
            if process.isRunning {
                process.terminate()
            }
        }
        defer {
            watchdog.cancel()
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
            try Task.checkCancellation()
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

        if Date() >= deadline {
            throw AIClientError.apiError(
                statusCode: 504,
                message: "Codex model list timed out. The CLI may be busy; try again."
            )
        }
        throw AIClientError.apiError(
            statusCode: 500,
            message: "Codex ended before returning its model list."
        )
    }

    private func runCodex(
        prompt: String,
        imageFiles: [URL],
        usesOrganizationSchema: Bool
    ) async throws -> String {
        try await checkHealth()
        guard let codexPath = await Self.resolveCodexExecutablePathAsync() else {
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

        let completion = ProcessTerminationCompletion()
        do {
            try Task.checkCancellation()
            // Watchdog: the continuation below otherwise resumes only from the
            // process termination handler, so a wedged `codex exec` (which
            // ignores task cancellation) would pin the task forever. Bound the
            // run by the config's organize/resource timeout, escalate SIGTERM
            // to SIGKILL, and unblock the continuation regardless.
            let executionTimeout = AIRequestSupport.organizeTimeout(for: config)
            let watchdog = Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(executionTimeout))
                guard !Task.isCancelled, process.isRunning else { return }
                // Record the timeout verdict first so the termination handler
                // cannot report a bare SIGTERM exit status instead.
                completion.resume(throwing: AIClientError.apiError(
                    statusCode: 504,
                    message: "Codex CLI exceeded its \(Int(executionTimeout))s execution limit and was stopped."
                ))
                process.terminate()
                try? await Task.sleep(for: .seconds(Self.processTerminationGracePeriod))
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            defer { watchdog.cancel() }

            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    completion.attach(continuation)
                    if Task.isCancelled {
                        completion.resume(throwing: CancellationError())
                        return
                    }
                    process.terminationHandler = { _ in
                        completion.resume()
                    }
                    do {
                        try process.run()
                        if let promptData = prompt.data(using: .utf8) {
                            try inputPipe.fileHandleForWriting.write(contentsOf: promptData)
                        }
                        try inputPipe.fileHandleForWriting.close()
                    } catch {
                        process.terminationHandler = nil
                        completion.resume(throwing: error)
                    }
                }
            } onCancel: {
                // A CLI that ignores SIGTERM must not keep the continuation
                // suspended: escalate to SIGKILL and resume as well.
                Self.terminateWithEscalation(process) {
                    completion.resume(throwing: CancellationError())
                }
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            process.terminate()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? diagnosticsHandle.close()
            throw CancellationError()
        } catch let error as AIClientError {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? diagnosticsHandle.close()
            throw error
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
    /// 60s TTL so clustered launch/setup probes share one lookup.
    private static let executablePathCacheLifetime: TimeInterval = 60

    private static let healthVerdictLock = NSLock()
    nonisolated(unsafe) private static var healthVerdictAt: Date?
    /// Success verdicts are shared briefly so prewarm + organize back-to-back
    /// share one `codex login status` probe instead of spawning two.
    private static let healthVerdictLifetime: TimeInterval = 30

    /// How long a stopped CLI process gets to exit on SIGTERM before SIGKILL.
    private static let processTerminationGracePeriod: TimeInterval = 5

    /// Stops a CLI process that may ignore SIGTERM: signal now, SIGKILL after a
    /// short grace period, then run `onEscalated` so the caller can unblock.
    private nonisolated static func terminateWithEscalation(
        _ process: Process,
        onEscalated: @escaping @Sendable () -> Void
    ) {
        if process.isRunning {
            process.terminate()
        }
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(processTerminationGracePeriod))
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            onEscalated()
        }
    }

    /// Synchronous callers only inspect cached and common paths. A cold login
    /// shell probe belongs to the async resolver so UI work never waits for it.
    nonisolated static func resolveCodexExecutablePath() -> String? {
        let cached = executablePathCacheLock.withLock { executablePathCache }

        if let cached, Date().timeIntervalSince(cached.resolvedAt) < executablePathCacheLifetime {
            if let path = cached.path {
                if FileManager.default.fileExists(atPath: path) { return path }
            } else {
                return nil
            }
        }

        let resolved = codexExecutableCandidates().first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        if let resolved {
            executablePathCacheLock.lock()
            executablePathCache = (path: resolved, resolvedAt: Date())
            executablePathCacheLock.unlock()
        }
        return resolved
    }

    nonisolated static func resolveCodexExecutablePathAsync() async -> String? {
        if let path = resolveCodexExecutablePath() { return path }
        let cached = executablePathCacheLock.withLock { executablePathCache }
        if let cached, cached.path == nil,
           Date().timeIntervalSince(cached.resolvedAt) < executablePathCacheLifetime {
            return nil
        }
        let resolved = await Task.detached(priority: .utility) {
            locateCodexExecutable()
        }.value
        executablePathCacheLock.withLock {
            executablePathCache = (path: resolved, resolvedAt: Date())
        }
        return resolved
    }

    private nonisolated static func locateCodexExecutable() -> String? {
        for path in codexExecutableCandidates() where FileManager.default.fileExists(atPath: path) {
            return path
        }

        // Version-manager installs (nvm, Volta, asdf, bun) only appear on an
        // interactive login PATH, so ask the user's login shell before falling
        // back to the bare environment probe.
        if let loginShellPath = resolveCodexExecutableViaLoginShell() {
            return loginShellPath
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

    /// Common install locations for the Codex CLI: Homebrew, the Codex app,
    /// and the npm/bun/Volta/asdf/pnpm/yarn user-local bin dirs, including
    /// nvm's versioned bin dirs (newest version first).
    private nonisolated static func codexExecutableCandidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.volta/bin/codex",
            "\(home)/.asdf/shims/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/Library/pnpm/codex",
            "\(home)/.local/share/pnpm/codex",
            "\(home)/.config/yarn/global/node_modules/.bin/codex"
        ]
        candidates += nvmCodexCandidates(home: home)
        return candidates
    }

    private nonisolated static func nvmCodexCandidates(home: String) -> [String] {
        let versionsDirectory = URL(fileURLWithPath: home)
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: versionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return versions
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("bin/codex").path }
    }

    /// Resolves the CLI through the user's interactive login shell, bounded so
    /// a slow `.zshrc` cannot stall the caller. Interactive shells may print
    /// banner text, so only the last executable file path counts.
    private nonisolated static func resolveCodexExecutableViaLoginShell() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v codex"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(loginShellProbeTimeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                terminateWithEscalation(process) {}
                return nil
            }

            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            let outputLines = String(data: output, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            return outputLines.last { line in
                line.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: line)
            }
        } catch {
            return nil
        }
    }

    private static let loginShellProbeTimeout: TimeInterval = 5
}

/// Exactly-once resume for the `codex exec` continuation: the termination
/// handler, the execution watchdog and cancellation can all race to finish the
/// process, but only the first outcome reaches the continuation.
private final class ProcessTerminationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var hasResumed = false
    private var firstOutcome: Error?

    /// Attaches the checked continuation. If an outcome was already recorded
    /// (cancellation raced ahead of the process start), the continuation is
    /// resumed immediately so it can never be stranded.
    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if hasResumed {
            let error = firstOutcome ?? CancellationError()
            lock.unlock()
            continuation.resume(throwing: error)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(throwing error: Error? = nil) {
        lock.lock()
        let pending = continuation
        continuation = nil
        if !hasResumed {
            hasResumed = true
            firstOutcome = error ?? CancellationError()
        }
        lock.unlock()

        guard let pending else { return }
        if let error {
            pending.resume(throwing: error)
        } else {
            pending.resume()
        }
    }
}

private final class CodexOutputStreamer: @unchecked Sendable {
    // NSLock stays: readabilityHandler fires on arbitrary background threads
    // and mutates line/pending buffers synchronously; a lock is the smallest
    // correct primitive (no actor hop on this hot path).
    private let lock = NSLock()
    /// Raw bytes are buffered so a multi-byte UTF-8 scalar split across
    /// `availableData` chunks is decoded once complete instead of dropping
    /// the whole chunk as invalid UTF-8.
    private var rawByteBuffer = Data()
    private var lineBuffer = ""
    private var pendingChunk = ""
    private var pendingBytes = 0
    private var lastEmit = Date()
    private let onChunk: @Sendable (String) -> Void

    /// Coalesces visible chunks off-actor: at most one MainActor hop per
    /// 100ms or 4KB. The caller's Task{@MainActor} hop stays, just batched.
    private static let emitInterval: TimeInterval = 0.1
    private static let maxPendingBytes = 4 * 1024

    init(onChunk: @escaping @Sendable (String) -> Void) {
        self.onChunk = onChunk
    }

    func process(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        rawByteBuffer.append(data)
        let text = decodeCompleteScalarsLocked()
        var completeLines: [String] = []
        if !text.isEmpty {
            lineBuffer += text
            let lines = lineBuffer.split(separator: "\n", omittingEmptySubsequences: false)
            if lineBuffer.hasSuffix("\n") {
                completeLines = lines.map { String($0) }
                lineBuffer = ""
            } else {
                completeLines = lines.dropLast().map { String($0) }
                lineBuffer = String(lines.last ?? "")
            }
        }
        lock.unlock()

        for line in completeLines {
            processLine(line)
        }
    }

    func finish() {
        lock.lock()
        let pending = lineBuffer
        lineBuffer = ""
        rawByteBuffer.removeAll(keepingCapacity: false)
        lock.unlock()

        if !pending.isEmpty {
            processLine(pending)
        }
        flushPending()
    }

    /// Decodes every complete UTF-8 scalar already buffered and carries the
    /// trailing bytes of a split scalar to the next chunk. Only the final
    /// scalar can be incomplete, so peeling back up to three bytes recovers
    /// everything that is decodable. Must hold `lock`.
    private func decodeCompleteScalarsLocked() -> String {
        guard !rawByteBuffer.isEmpty else { return "" }

        if let text = String(data: rawByteBuffer, encoding: .utf8) {
            rawByteBuffer.removeAll(keepingCapacity: true)
            return text
        }

        for trailingByteCount in 1...min(3, rawByteBuffer.count) {
            let prefixLength = rawByteBuffer.count - trailingByteCount
            if prefixLength == 0 {
                // Everything buffered is a partial scalar: wait for more bytes.
                return ""
            }
            guard let text = String(data: rawByteBuffer.prefix(prefixLength), encoding: .utf8) else {
                continue
            }
            rawByteBuffer = Data(rawByteBuffer.suffix(trailingByteCount))
            return text
        }

        // Genuinely invalid bytes: decode lossily so the stream never stalls
        // and nothing keeps buffering.
        let text = String(decoding: rawByteBuffer, as: UTF8.self)
        rawByteBuffer.removeAll(keepingCapacity: true)
        return text
    }

    private func flushPending() {
        lock.lock()
        guard !pendingChunk.isEmpty else {
            lock.unlock()
            return
        }
        let payload = pendingChunk
        pendingChunk = ""
        pendingBytes = 0
        lastEmit = Date()
        lock.unlock()
        onChunk(payload)
    }

    private func processLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let chunk = Self.extractVisibleChunk(from: json),
           !chunk.isEmpty {
            lock.lock()
            pendingChunk += chunk
            pendingBytes += chunk.utf8.count
            let shouldEmit = pendingBytes >= Self.maxPendingBytes
                || Date().timeIntervalSince(lastEmit) >= Self.emitInterval
            var payload: String?
            if shouldEmit {
                payload = pendingChunk
                pendingChunk = ""
                pendingBytes = 0
                lastEmit = Date()
            }
            lock.unlock()
            if let payload {
                onChunk(payload)
            }
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
