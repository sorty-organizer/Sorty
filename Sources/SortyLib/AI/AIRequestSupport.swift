import Foundation

enum AIRequestSupport {
    nonisolated(unsafe) static var sessionOverride: (@Sendable (AIConfig) async -> URLSession)?

    static func session(for config: AIConfig) async -> URLSession {
        if let sessionOverride {
            return await sessionOverride(config)
        }
        return await AISessionManager.shared.session(for: config.provider, config: config)
    }

    static func requireAPIURL(from config: AIConfig) throws -> String {
        guard let apiURL = config.apiURL?.trimmingCharacters(in: .whitespacesAndNewlines), !apiURL.isEmpty else {
            throw AIClientError.missingAPIURL
        }
        return apiURL
    }

    static func requireAPIKeyIfNeeded(from config: AIConfig) throws {
        if !ProviderAuthResolver.hasRequiredCredential(for: config.provider, config: config) {
            throw AIClientError.missingAPIKey
        }
    }

    static func openAIChatCompletionsURL(from apiURL: String) throws -> URL {
        let normalized = normalizeBaseURL(apiURL)

        guard var components = URLComponents(string: normalized), components.scheme != nil else {
            throw AIClientError.invalidURL
        }

        let path = components.path
        if path.hasSuffix("/v1/chat/completions") {
            return try ensureURL(components)
        }

        if path.hasSuffix("/v1beta/openai") {
            components.path += "/chat/completions"
            return try ensureURL(components)
        }

        if path.hasSuffix("/v1beta/openai/") {
            components.path += "chat/completions"
            return try ensureURL(components)
        }

        if path.hasSuffix("/v1") {
            components.path += "/chat/completions"
            return try ensureURL(components)
        }

        if path.hasSuffix("/v1/") {
            components.path += "chat/completions"
            return try ensureURL(components)
        }

        if path.hasSuffix("/v1beta/openai") || path.hasSuffix("/v1beta/openai/") {
            components.path = path.hasSuffix("/") ? path + "chat/completions" : path + "/chat/completions"
            return try ensureURL(components)
        }

        let trimmedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        components.path = trimmedPath + "/v1/chat/completions"
        return try ensureURL(components)
    }

    static func openAIModelsURL(from apiURL: String) throws -> URL {
        let normalized = normalizeBaseURL(apiURL)

        guard var components = URLComponents(string: normalized), components.scheme != nil else {
            throw AIClientError.invalidURL
        }

        let path = components.path
        if path.hasSuffix("/chat/completions") {
            components.path = String(path.dropLast("/chat/completions".count)) + "/models"
            return try ensureURL(components)
        }

        if path.hasSuffix("/chat/completions/") {
            components.path = String(path.dropLast("/chat/completions/".count)) + "/models"
            return try ensureURL(components)
        }

        if path.hasSuffix("/v1") {
            components.path += "/models"
            return try ensureURL(components)
        }

        if path.hasSuffix("/v1/") {
            components.path += "models"
            return try ensureURL(components)
        }

        if path.contains("/v1/") || path.contains("/v1beta/") {
            let normalizedPath = path.hasSuffix("/") ? path + "models" : path + "/models"
            components.path = normalizedPath
            return try ensureURL(components)
        }

        let trimmedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        components.path = trimmedPath + "/v1/models"
        return try ensureURL(components)
    }

    static func makeJSONRequest(
        url: URL,
        method: String = "POST",
        headers: [String: String] = [:],
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        try ensureNetworkAllowed(url: url)

        var request = URLRequest(url: url)
        request.httpMethod = method

        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        if body != nil && headers["Content-Type"] == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        return request
    }

    static func ensureNetworkAllowed(url: URL) throws {
        guard NetworkPrivacyPolicy.isRequestAllowed(url: url) else {
            throw AIClientError.internetAccessBlocked
        }
    }

    static func validateHTTPResponse(data: Data, response: URLResponse) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIClientError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIClientError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        return httpResponse
    }

    private static func normalizeBaseURL(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.contains("://") {
            normalized = "https://" + normalized
        }
        return normalized
    }

    private static func ensureURL(_ components: URLComponents) throws -> URL {
        guard let url = components.url, url.scheme != nil else {
            throw AIClientError.invalidURL
        }
        return url
    }

    /// Extracts textual content from heterogeneous OpenAI-compatible payloads.
    /// Handles plain strings plus content-part arrays/dictionaries used by newer APIs.
    static func extractText(from value: Any?) -> String? {
        guard let value else { return nil }

        if let text = value as? String {
            return text
        }

        if let parts = value as? [Any] {
            let joined = parts.compactMap { extractText(from: $0) }.joined()
            return joined.isEmpty ? nil : joined
        }

        if let dict = value as? [String: Any] {
            let priorityKeys = ["text", "content", "value", "output_text", "reasoning", "thinking", "analysis", "parts"]
            for key in priorityKeys {
                if let extracted = extractText(from: dict[key]), !extracted.isEmpty {
                    return extracted
                }
            }
        }

        return nil
    }

    /// Best-effort extraction for chat completion message text in non-streaming responses.
    static func extractChatMessageText(from choice: [String: Any]) -> String? {
        let message = choice["message"] as? [String: Any]
        return extractText(from: message?["content"]) ??
            extractText(from: message?["text"]) ??
            extractText(from: choice["text"])
    }

    /// Best-effort extraction for streaming chunk text in OpenAI-compatible responses.
    static func extractChatDeltaText(from choice: [String: Any]) -> String? {
        let delta = choice["delta"] as? [String: Any]
        let message = choice["message"] as? [String: Any]
        return extractText(from: delta?["content"]) ??
            extractText(from: delta?["text"]) ??
            extractText(from: message?["content"]) ??
            extractText(from: choice["text"])
    }

    /// Completion text from the first choice of an OpenAI-style streaming chunk,
    /// or nil when the chunk carries no choices.
    static func streamCompletionChunk(from json: [String: Any]) -> String? {
        guard let firstChoice = (json["choices"] as? [[String: Any]])?.first else { return nil }
        return extractChatDeltaText(from: firstChoice)
    }

    /// Payload of an SSE `data:` line, or nil for other lines and empty payloads.
    static func sseDataPayload(from line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        return payload.isEmpty ? nil : payload
    }

    /// Retries transient transport and HTTP failures with bounded backoff.
    ///
    /// HTTP status inspection deliberately happens inside this wrapper. URLSession considers
    /// responses such as 502 successful network calls, so validating them after this function
    /// returns prevents the retry policy from ever seeing them.
    static func withTransientHTTPRetry<Payload>(
        delays: [Duration] = [.milliseconds(500), .seconds(1)],
        _ operation: () async throws -> (Payload, URLResponse)
    ) async throws -> (Payload, URLResponse) {
        var attempt = 0

        while true {
            try Task.checkCancellation()

            do {
                let result = try await operation()
                guard let response = result.1 as? HTTPURLResponse,
                      isTransientStatusCode(response.statusCode),
                      attempt < delays.count else {
                    return result
                }

                let delay = retryDelay(from: response, fallback: delays[attempt])
                attempt += 1
                try await Task.sleep(for: delay)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AIClientError {
                guard shouldRetry(error), attempt < delays.count else { throw error }
                let delay = delays[attempt]
                attempt += 1
                try await Task.sleep(for: delay)
            } catch let error as URLError {
                guard shouldRetry(error), attempt < delays.count else { throw error }
                let delay = delays[attempt]
                attempt += 1
                try await Task.sleep(for: delay)
            }
        }
    }

    /// Whether a given error is transient and worth retrying
    private static func shouldRetry(_ error: AIClientError) -> Bool {
        switch error {
        case .apiError(let statusCode, _):
            return isTransientStatusCode(statusCode)
        case .networkError:
            return true
        default:
            return false
        }
    }

    private static func shouldRetry(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private static func isTransientStatusCode(_ statusCode: Int) -> Bool {
        [429, 500, 502, 503, 504].contains(statusCode)
    }

    private static func retryDelay(from response: HTTPURLResponse, fallback: Duration) -> Duration {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds.isFinite else {
            return fallback
        }

        return .milliseconds(Int64(min(max(seconds, 0.25), 10) * 1_000))
    }

    /// Computes the file-size total once per request so streaming/non-streaming
    /// stats paths share a single pass instead of reducing per batch.
    static func totalFileSize(of files: [FileItem]) -> Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    /// Slice overload so batch callers can pass `files[start..<end]` counts
    /// without materializing `Array(slice)` copies where trivial.
    static func totalFileSize(of slice: ArraySlice<FileItem>) -> Int64 {
        slice.reduce(0) { $0 + $1.size }
    }

    /// Bounded organize timeout: fails large organize calls fast instead of
    /// hanging on the URLRequest/session default (up to 600s resource timeout).
    static func organizeTimeout(for config: AIConfig) -> TimeInterval {
        max(30, min(config.requestTimeout, 300))
    }

    /// Short timeout for health checks and single-turn generation.
    static func interactiveTimeout(for config: AIConfig) -> TimeInterval {
        min(config.requestTimeout, 60)
    }
}

/// Coalesces streaming chunks off-actor before a single MainActor hop.
/// Flushes when ~4KB accumulates or 100ms elapses since the last flush.
/// The outer 0.55s display throttle in FolderOrganizer remains the UI bound;
/// this only reduces MainActor traffic from per-token to per-flush.
struct StreamingChunkCoalescer: Sendable {
    private var buffer = ""
    private var bufferedBytes = 0
    private var lastFlush: Date

    static let flushInterval: TimeInterval = 0.1
    static let maxBufferedBytes = 4 * 1024

    init(now: Date = Date()) {
        lastFlush = now
    }

    mutating func append(_ chunk: String, now: Date = Date()) -> String? {
        guard !chunk.isEmpty else { return nil }
        buffer += chunk
        bufferedBytes += chunk.utf8.count
        if bufferedBytes >= Self.maxBufferedBytes
            || now.timeIntervalSince(lastFlush) >= Self.flushInterval {
            return flush(now: now)
        }
        return nil
    }

    mutating func flush(now: Date = Date()) -> String? {
        guard !buffer.isEmpty else { return nil }
        let payload = buffer
        buffer = ""
        bufferedBytes = 0
        lastFlush = now
        return payload
    }
}

/// Accounts base64 image payloads against the 32MB prepared-vision cap.
/// Base64 inflates ~4/3, so budgets are estimated on the encoded size.
public enum VisionPayloadBudget {
    public static let maximumPreparedVisionBytes = 32 * 1_024 * 1_024

    public static func totalBase64Bytes(for payload: [String: Data]) -> Int {
        payload.values.reduce(0) { $0 + $1.count * 4 / 3 }
    }

    /// Drops trailing sorted keys until the estimated encoded size fits.
    /// Keeps deterministic survivors so retries behave identically.
    public static func clamped(
        _ payload: [String: Data],
        cap: Int = maximumPreparedVisionBytes
    ) -> [String: Data] {
        var kept: [String: Data] = [:]
        var budgeted = 0
        for key in payload.keys.sorted() {
            guard let data = payload[key] else { continue }
            let encoded = data.count * 4 / 3
            if budgeted + encoded > cap { continue }
            kept[key] = data
            budgeted += encoded
        }
        return kept
    }
}

/// Single entry point for vision preparation: calls
/// `prepareFilesForVision` once per request (maxConcurrent 4 stays inside
/// ImageVisionAnalyzer) and clamps the result to the 32MB budget.
/// The pipeline agent wires this into the organizer batch loop.
public func prepareVisionBatch(
    files: [FileItem],
    base: URL?,
    pdfPageLimit: Int = 2,
    progress: (@Sendable (Int, Int) async -> Void)? = nil
) async -> [String: Data] {
    let prepared = await ImageVisionAnalyzer().prepareFilesForVision(
        files: files,
        baseDirectoryURL: base,
        pdfPageLimit: pdfPageLimit,
        progress: progress
    )
    return VisionPayloadBudget.clamped(prepared)
}

/// Releases per-batch image payloads after the request finishes.
/// Call sites must not retain the full payload in resume checkpoints;
/// re-prepare from the ImageVisionAnalyzer disk cache on resume instead.
public func clearVisionBatch(_ payload: inout [String: Data]) {
    payload.removeAll(keepingCapacity: false)
}

/// Extracts JSON from free-form LLM output.
enum LLMJSONExtractor {
    /// Last balanced top-level JSON object in the text.
    static func lastObject(in text: String) -> String? {
        balancedSpans(in: text, open: "{", close: "}").last
    }

    /// All balanced top-level JSON objects in the text.
    static func objectCandidates(in text: String) -> [String] {
        balancedSpans(in: text, open: "{", close: "}")
    }

    /// First balanced JSON array in the text.
    static func firstArray(in text: String) -> String? {
        balancedSpans(in: text, open: "[", close: "]").first
    }

    /// Rule-induction responses: a ```json fenced block if present (trimmed),
    /// else the first "[" through last "]", else the first "{" through last "}"
    /// wrapped as a one-element array, else the text unchanged.
    static func fencedOrBracketedJSON(from text: String) -> String {
        // 1. Try to find JSON markdown blocks: ```json ... ``` or ``` ... ```
        if let startRange = text.range(of: "```json"),
           let endRange = text.range(of: "```", options: .backwards, range: startRange.upperBound..<text.endIndex) {
            let content = text[startRange.upperBound..<endRange.lowerBound]
            return String(content).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let startRange = text.range(of: "```"),
                  let endRange = text.range(of: "```", options: .backwards, range: startRange.upperBound..<text.endIndex) {
            let content = text[startRange.upperBound..<endRange.lowerBound]
            return String(content).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Fallback: Find the first '[' and last ']' for array response
        if let startRange = text.range(of: "["),
           let endRange = text.range(of: "]", options: .backwards) {
            let range = startRange.lowerBound..<endRange.upperBound
            return String(text[range])
        }

        // 3. Fallback: Find the first '{' and last '}' for single object response
        if let startRange = text.range(of: "{"),
           let endRange = text.range(of: "}", options: .backwards) {
            let range = startRange.lowerBound..<endRange.upperBound
            let objectJson = String(text[range])
            // If we found an object but expected an array, wrap it in brackets for the decoder
            return "[\(objectJson)]"
        }

        return text
    }

    private static func balancedSpans(in text: String, open: Character, close: Character) -> [String] {
        var candidates: [String] = []
        var depth = 0
        var start: String.Index?
        var isInsideString = false
        var isEscaping = false

        for index in text.indices {
            let character = text[index]

            if isInsideString {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
                continue
            }

            if character == "\"" {
                isInsideString = true
            } else if character == open {
                if depth == 0 {
                    start = index
                }
                depth += 1
            } else if character == close, depth > 0 {
                depth -= 1
                if depth == 0, let start {
                    candidates.append(String(text[start...index]))
                }
            }
        }

        return candidates
    }
}
