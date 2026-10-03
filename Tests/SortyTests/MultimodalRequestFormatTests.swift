import Foundation
import XCTest
@testable import SortyLib
@testable import SortyCore
@testable import SortyAI

final class MultimodalRequestFormatTests: XCTestCase {
    private var testDefaultsSuiteName = ""
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        TestSynchronization.networkPrivacyModeLock.lock()
        testDefaultsSuiteName = "Sorty.MultimodalRequestFormatTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: testDefaultsSuiteName)
        testDefaults.removePersistentDomain(forName: testDefaultsSuiteName)
        NetworkPrivacyPolicy.setTestDefaultsSuiteName(testDefaultsSuiteName)
        testDefaults.set(false, forKey: NetworkPrivacyPolicy.internetPrivacyModeKey)

        MockHTTPURLProtocol.reset()
        AIRequestSupport.sessionOverride = { _ in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockHTTPURLProtocol.self]
            return URLSession(configuration: config)
        }
    }

    override func tearDown() {
        AIRequestSupport.sessionOverride = nil
        NetworkPrivacyPolicy.setTestDefaultsSuiteName(nil)
        testDefaults.removePersistentDomain(forName: testDefaultsSuiteName)
        testDefaults = nil
        testDefaultsSuiteName = ""

        TestSynchronization.networkPrivacyModeLock.unlock()

        super.tearDown()
    }

    func testOpenCodeGoMessagesUsePlanEndpointAndCredentials() async throws {
        let config = AIConfig(provider: .openCodeGo, apiURL: AIProvider.openCodeGo.defaultAPIURL,
                              apiKey: "go-test-key", model: "minimax-m3", enableStreaming: false)
        let client = try AIClientFactory.createClient(config: config)
        XCTAssertTrue(client is AnthropicClient)
        MockHTTPURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"content":[{"type":"text","text":"OK"}],"stop_reason":"end_turn"}"#.utf8))
        }
        let text = try await client.generateText(prompt: "Hello", systemPrompt: nil)
        XCTAssertEqual(text, "OK")
        let request = try XCTUnwrap(MockHTTPURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://opencode.ai/zen/go/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer go-test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Sorty/1.0")
        let session = try XCTUnwrap(request.value(forHTTPHeaderField: "x-opencode-session"))
        try await client.checkHealth()
        let health = try XCTUnwrap(MockHTTPURLProtocol.lastRequest)
        XCTAssertEqual(health.httpMethod, "POST")
        XCTAssertEqual(health.url, request.url)
        XCTAssertEqual(health.value(forHTTPHeaderField: "x-opencode-session"), session)
    }

    func testOpenCodeRoutingDiffersByPlan() throws {
        XCTAssertEqual(AIProvider.openCodeZen.openCodeAPIFormat(for: "qwen3.8-max"), .chatCompletions)
        XCTAssertEqual(AIProvider.openCodeGo.openCodeAPIFormat(for: "qwen3.8-max"), .messages)
        XCTAssertEqual(AIProvider.openCodeZen.openCodeAPIFormat(for: " CLAUDE-SONNET-4-6 "), .messages)
        XCTAssertEqual(AIProvider.openCodeGo.openCodeAPIFormat(for: "gpt-6-luna"), .responses)
        XCTAssertEqual(AIProvider.openCodeZen.openCodeAPIFormat(for: "gemini-3.1-pro"), .gemini)
    }

    func testOpenCodeResponsesRequestAndTextExtraction() async throws {
        let config = AIConfig(provider: .openCodeZen, apiURL: AIProvider.openCodeZen.defaultAPIURL,
                              apiKey: "zen-test-key", model: "gpt-6-luna", enableStreaming: false)
        let client = try AIClientFactory.createClient(config: config)
        MockHTTPURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"status":"completed","output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}"#.utf8))
        }
        let text = try await client.generateText(prompt: "Hello", systemPrompt: "Be concise")
        XCTAssertEqual(text, "OK")
        let request = try XCTUnwrap(MockHTTPURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://opencode.ai/zen/v1/responses")
        let body = try request.jsonBody()
        XCTAssertNil(body["messages"])
        XCTAssertEqual(body["temperature"] as? Double, AIConfig.generationTemperature)
        XCTAssertEqual((body["input"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(body["store"] as? Bool, false)
    }

    func testOpenCodeNativeStreamsRejectTruncationAndIgnoreReasoning() throws {
        let responseClient = OpenAIClient(config: AIConfig(provider: .openCodeGo, model: "gpt-6-luna"))
        XCTAssertThrowsError(try responseClient.normalizedCompletion([
            "type": "response.incomplete", "response": ["status": "incomplete"]
        ], streaming: true))
        let chunk = try responseClient.normalizedCompletion([
            "type": "response.output_text.delta", "delta": "hello"
        ], streaming: true)
        XCTAssertEqual(AIRequestSupport.streamCompletionChunk(from: chunk), "hello")
        let gemini = OpenAIClient(config: AIConfig(provider: .openCodeZen, model: "gemini-3.1-pro"))
        let result = try gemini.normalizedCompletion(["candidates": [[
            "content": ["parts": [["text": "secret", "thought": true], ["text": "visible"]]],
            "finishReason": "STOP"
        ]]])
        let choices = try XCTUnwrap(result["choices"] as? [[String: Any]])
        XCTAssertEqual(AIRequestSupport.extractChatMessageText(from: choices[0]), "visible")
        XCTAssertThrowsError(try gemini.normalizedCompletion(["candidates": [["finishReason": "MAX_TOKENS"]]]))
    }

    func testOpenCodeGeminiAcceptsTextWithoutFinishReason() throws {
        let gemini = OpenAIClient(config: AIConfig(provider: .openCodeZen, model: "gemini-3.1-pro"))
        let result = try gemini.normalizedCompletion(["candidates": [[
            "content": ["parts": [["text": "visible"]]]
        ]]])
        let choices = try XCTUnwrap(result["choices"] as? [[String: Any]])
        XCTAssertEqual(AIRequestSupport.extractChatMessageText(from: choices[0]), "visible")
        XCTAssertEqual(choices[0]["finish_reason"] as? String, "stop")
        XCTAssertThrowsError(try gemini.normalizedCompletion(["candidates": [[:]]]))
    }

    func testOpenCodeResponsesStreamRequiresCompletionEvent() async throws {
        let config = AIConfig(provider: .openCodeGo, apiURL: AIProvider.openCodeGo.defaultAPIURL,
                              apiKey: "go-test-key", model: "gpt-6-luna", enableStreaming: true)
        let files = [FileItem(path: "/tmp/photo1.jpg", name: "photo1", extension: "jpg")]
        for completes in [true, false] {
            MockHTTPURLProtocol.requestHandler = { request in
                let plan = #"{"folders":[{"name":"Images","files":["photo1.jpg"]}],"unorganized":[]}"#
                let delta = try JSONSerialization.data(withJSONObject: [
                    "type": "response.output_text.delta", "delta": plan
                ])
                var events = "data: \(String(decoding: delta, as: UTF8.self))\n\n"
                if completes {
                    events += "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                               headerFields: ["Content-Type": "text/event-stream"])!
                return (response, Data(events.utf8))
            }
            do {
                _ = try await OpenAIClient(config: config).analyze(files: files)
                XCTAssertTrue(completes, "A truncated stream must not produce an accepted plan")
            } catch {
                if completes { throw error }
                guard case AIClientError.jsonDecodingError = error else {
                    return XCTFail("Expected an incomplete stream error, got \(error)")
                }
            }
        }
    }

    func testOpenCodeGeminiRequestPreservesImagesAndSystemPrompt() throws {
        let client = OpenAIClient(config: AIConfig(provider: .openCodeZen, model: "gemini-3.1-pro"))
        let request = try client.makeCompletionRequest(
            url: URL(string: "https://opencode.ai/zen/v1/chat/completions")!, headers: [:], body: [
                "messages": [
                    ["role": "system", "content": "Be concise"],
                    ["role": "user", "content": [
                        ["type": "text", "text": "Describe"],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,AQID"]]
                    ]]
                ], "max_tokens": 512, "stream": true
            ])
        XCTAssertEqual(request.url?.path, "/zen/v1/models/gemini-3.1-pro:streamGenerateContent")
        XCTAssertEqual(request.url?.query, "alt=sse")
        let body = try request.jsonBody()
        XCTAssertNotNil(body["systemInstruction"])
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        let image = try XCTUnwrap(parts[1]["inlineData"] as? [String: String])
        XCTAssertEqual(image, ["mimeType": "image/jpeg", "data": "AQID"])
    }

    func testOpenAIClientBuildsImageURLPartsWithConfigurableDetail() async throws {
        let config = AIConfig(
            provider: .openAI,
            apiURL: "https://api.openai.com",
            apiKey: "test-key",
            model: "gpt-4o",
            enableStreaming: false,
            visionDetailLevel: .high
        )
        let client = OpenAIClient(config: config)
        let files = [FileItem(path: "/tmp/photo1.jpg", name: "photo1", extension: "jpg")]
        let imageData: [String: Data] = ["photo1.jpg": Data([0x01, 0x02, 0x03])]

        MockHTTPURLProtocol.requestHandler = { request in
            let responseBody = """
            {"choices":[{"message":{"content":"{\\"folders\\":[{\\"name\\":\\"Images\\",\\"files\\":[\\"photo1.jpg\\"]}],\\"unorganized\\":[]}"}}]}
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(responseBody.utf8))
        }

        _ = try await client.analyzeWithImages(files: files, imageData: imageData)
        let request = try XCTUnwrap(MockHTTPURLProtocol.lastRequest)
        let json = try request.jsonBody()
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let userMessage = try XCTUnwrap(messages.last)
        let content = try XCTUnwrap(userMessage["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)

        let imagePart = try XCTUnwrap(content.last)
        let imageURL = try XCTUnwrap(imagePart["image_url"] as? [String: Any])
        XCTAssertNotNil(imageURL["url"] as? String)
        XCTAssertEqual(imageURL["detail"] as? String, "high")
    }

    func testOpenCodeGoUsesItsChatEndpointAndSessionHeaders() async throws {
        let config = AIConfig(
            provider: .openCodeGo,
            apiURL: AIProvider.openCodeGo.defaultAPIURL,
            apiKey: "test-key",
            model: "glm-5.3",
            enableStreaming: false
        )
        let client = OpenAIClient(config: config)
        let files = [FileItem(path: "/tmp/report.pdf", name: "report", extension: "pdf")]

        MockHTTPURLProtocol.requestHandler = { request in
            let body = """
            {"choices":[{"message":{"content":"{\\"folders\\":[{\\"name\\":\\"Documents\\",\\"files\\":[\\"report.pdf\\"]}],\\"unorganized\\":[]}"}}]}
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        _ = try await client.analyze(files: files)
        let request = try XCTUnwrap(MockHTTPURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://opencode.ai/zen/go/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Sorty/1.0")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "x-opencode-session"))
    }

    func testOpenRouterRequestsJSONWithoutEliminatingFreeRouteProviders() async throws {
        let config = AIConfig(
            provider: .openRouter,
            apiURL: "https://openrouter.ai/api/v1",
            apiKey: "test-key",
            model: "openrouter/free",
            enableStreaming: false
        )
        let client = OpenAIClient(config: config)
        let files = [FileItem(path: "/tmp/report.pdf", name: "report", extension: "pdf")]

        MockHTTPURLProtocol.requestHandler = { request in
            let responseBody = """
            {"choices":[{"message":{"content":"{\\"folders\\":[{\\"name\\":\\"Documents\\",\\"files\\":[\\"report.pdf\\"]}],\\"unorganized\\":[]}"}}]}
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(responseBody.utf8))
        }

        _ = try await client.analyze(files: files)

        let request = try XCTUnwrap(MockHTTPURLProtocol.lastRequest)
        let json = try request.jsonBody()
        let responseFormat = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_object")

        XCTAssertNil(json["provider"])
        let plugins = try XCTUnwrap(json["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.first?["id"] as? String, "response-healing")
    }

    func testOpenRouterRetriesMidStreamProviderFailureWithResponseHealing() async throws {
        let config = AIConfig(
            provider: .openRouter,
            apiURL: "https://openrouter.ai/api/v1",
            apiKey: "test-key",
            model: "openrouter/free",
            enableStreaming: true
        )
        let client = OpenAIClient(config: config)
        let files = [FileItem(path: "/tmp/report.pdf", name: "report", extension: "pdf")]

        MockHTTPURLProtocol.requestHandler = { request in
            let requestJSON = try request.jsonBody()
            let responseBody: String
            if requestJSON["stream"] as? Bool == true {
                responseBody = """
                data: {"error":{"code":502,"message":"Provider disconnected","metadata":{"error_type":"provider_unavailable"}},"choices":[{"delta":{"content":""},"finish_reason":"error"}]}

                data: [DONE]

                """
            } else {
                responseBody = """
                {"choices":[{"message":{"content":"{\\"folders\\":[{\\"name\\":\\"Documents\\",\\"files\\":[\\"report.pdf\\"]}],\\"unorganized\\":[]}"}}]}
                """
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(responseBody.utf8))
        }

        let plan = try await client.analyze(files: files)

        XCTAssertEqual(plan.suggestions.first?.folderName, "Documents")
        let fallbackRequest = try XCTUnwrap(MockHTTPURLProtocol.lastRequest)
        let fallbackJSON = try fallbackRequest.jsonBody()
        let plugins = try XCTUnwrap(fallbackJSON["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.first?["id"] as? String, "response-healing")
        XCTAssertNil(fallbackJSON["stream"])
    }

    func testOpenRouterRetriesWithoutOptionalParametersWhenFreeRouteRejectsThem() async throws {
        let config = AIConfig(
            provider: .openRouter,
            apiURL: "https://openrouter.ai/api/v1",
            apiKey: "test-key",
            model: "openrouter/free",
            enableStreaming: false
        )
        let client = OpenAIClient(config: config)
        let files = [FileItem(path: "/tmp/report.pdf", name: "report", extension: "pdf")]

        MockHTTPURLProtocol.requestHandler = { request in
            let requestJSON = try request.jsonBody()
            if requestJSON["response_format"] != nil {
                let errorBody = """
                {"error":{"message":"No endpoints found that can handle requested parameters"}}
                """
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data(errorBody.utf8))
            }

            let responseBody = """
            {"choices":[{"message":{"content":"{\\"folders\\":[{\\"name\\":\\"Documents\\",\\"files\\":[\\"report.pdf\\"]}],\\"unorganized\\":[]}"}}]}
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(responseBody.utf8))
        }

        let plan = try await client.analyze(files: files)

        XCTAssertEqual(plan.suggestions.first?.folderName, "Documents")
        let requests = MockHTTPURLProtocol.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        let fallbackJSON = try requests[1].jsonBody()
        XCTAssertNil(fallbackJSON["response_format"])
        XCTAssertNil(fallbackJSON["reasoning"])
        XCTAssertNil(fallbackJSON["plugins"])
        XCTAssertNil(fallbackJSON["provider"])
        XCTAssertEqual(fallbackJSON["temperature"] as? Double, 0.2)
    }

    func testOpenRouterRetriesEmptyCompletionWithPortableJSONRequest() async throws {
        let config = AIConfig(
            provider: .openRouter,
            apiURL: "https://openrouter.ai/api/v1",
            apiKey: "test-key",
            model: "openrouter/free",
            enableStreaming: false
        )
        let client = OpenAIClient(config: config)
        let files = [FileItem(path: "/tmp/report.pdf", name: "report", extension: "pdf")]

        MockHTTPURLProtocol.requestHandler = { request in
            let requestJSON = try request.jsonBody()
            let responseBody: String
            if requestJSON["response_format"] != nil {
                responseBody = """
                {"choices":[{"message":{"content":null},"finish_reason":"stop"}]}
                """
            } else {
                responseBody = """
                {"choices":[{"message":{"content":"{\\"folders\\":[{\\"name\\":\\"Documents\\",\\"files\\":[\\"report.pdf\\"]}],\\"unorganized\\":[]}"}}]}
                """
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(responseBody.utf8))
        }

        let plan = try await client.analyze(files: files)

        XCTAssertEqual(plan.suggestions.first?.folderName, "Documents")
        XCTAssertEqual(MockHTTPURLProtocol.capturedRequests().count, 2)
    }

    func testOpenRouterRetriesTextOnlyWhenFreeRouteRejectsImageInput() async throws {
        let config = AIConfig(
            provider: .openRouter,
            apiURL: "https://openrouter.ai/api/v1",
            apiKey: "test-key",
            model: "openrouter/free",
            enableStreaming: false
        )
        let client = OpenAIClient(config: config)
        let files = [FileItem(path: "/tmp/photo.jpg", name: "photo", extension: "jpg")]

        MockHTTPURLProtocol.requestHandler = { request in
            let requestJSON = try request.jsonBody()
            let messages = try XCTUnwrap(requestJSON["messages"] as? [[String: Any]])
            let userContent = try XCTUnwrap(messages.last?["content"])
            if userContent is [[String: Any]] {
                let errorBody = """
                {"error":{"message":"No endpoints found that support image input"}}
                """
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data(errorBody.utf8))
            }

            let responseBody = """
            {"choices":[{"message":{"content":"{\\"folders\\":[{\\"name\\":\\"Images\\",\\"files\\":[\\"photo.jpg\\"]}],\\"unorganized\\":[]}"}}]}
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(responseBody.utf8))
        }

        let plan = try await client.analyzeWithImages(
            files: files,
            imageData: ["photo.jpg": Data([0x01, 0x02])]
        )

        XCTAssertEqual(plan.suggestions.first?.folderName, "Images")
        let requests = MockHTTPURLProtocol.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        let fallbackJSON = try requests[1].jsonBody()
        let fallbackMessages = try XCTUnwrap(fallbackJSON["messages"] as? [[String: Any]])
        XCTAssertTrue(fallbackMessages.last?["content"] is String)
    }

    func testAnthropicClientBuildsBase64ImageParts() async throws {
        let config = AIConfig(
            provider: .anthropic,
            apiKey: "test-key",
            model: "claude-sonnet-4",
            enableStreaming: false
        )
        let client = AnthropicClient(config: config)
        let files = [FileItem(path: "/tmp/photo1.jpg", name: "photo1", extension: "jpg")]
        let imageData: [String: Data] = ["photo1.jpg": Data([0x10, 0x20, 0x30])]

        MockHTTPURLProtocol.requestHandler = { request in
            let responseBody = """
            {"content":[{"type":"text","text":"{\\"folders\\":[{\\"name\\":\\"Images\\",\\"files\\":[\\"photo1.jpg\\"]}],\\"unorganized\\":[]}"}]}
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(responseBody.utf8))
        }

        _ = try await client.analyzeWithImages(files: files, imageData: imageData)
        let request = try XCTUnwrap(MockHTTPURLProtocol.lastRequest)
        let json = try request.jsonBody()
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let userMessage = try XCTUnwrap(messages.first)
        let content = try XCTUnwrap(userMessage["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)

        let imagePart = try XCTUnwrap(content.last)
        XCTAssertEqual(imagePart["type"] as? String, "image")
        let source = try XCTUnwrap(imagePart["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertNotNil(source["data"] as? String)
    }


}

private final class MockHTTPURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        requestHandler = nil
        lastRequest = nil
        requests = []
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "api.openai.com" ||
            host == "api.anthropic.com" ||
            host == "opencode.ai" ||
            host == "openrouter.ai"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.lastRequest = request
        Self.requests.append(request)
        let handler = Self.requestHandler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func jsonBody() throws -> [String: Any] {
        let body = try XCTUnwrap(serializedBodyData())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func serializedBodyData() -> Data? {
        if let httpBody {
            return httpBody
        }
        guard let stream = httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        var buffer = Array<UInt8>(repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let readCount = stream.read(&buffer, maxLength: bufferSize)
            if readCount < 0 {
                return nil
            }
            if readCount == 0 {
                break
            }
            data.append(buffer, count: readCount)
        }

        return data
    }
}
