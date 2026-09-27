import Foundation
import XCTest
@testable import SortyLib
@testable import SortyCore

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

    func testGitHubCopilotClientCapsImagesAtFiveAndUsesLowDetailByDefault() async throws {
        let config = AIConfig(
            provider: .githubCopilot,
            model: "gpt-4o",
            enableStreaming: false
        )
        let client = GitHubCopilotClient(
            config: config,
            testHeadersProvider: {
                ["Authorization": "Bearer test", "Content-Type": "application/json"]
            }
        )

        let files = (1...7).map { index in
            FileItem(path: "/tmp/photo\(index).jpg", name: "photo\(index)", extension: "jpg")
        }
        var imageData: [String: Data] = [:]
        for index in 1...7 {
            imageData["photo\(index).jpg"] = Data([UInt8(index)])
        }

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

        let imageParts = content.filter { ($0["type"] as? String) == "image_url" }
        XCTAssertEqual(imageParts.count, 5)
        for imagePart in imageParts {
            let imageURL = try XCTUnwrap(imagePart["image_url"] as? [String: Any])
            XCTAssertEqual(imageURL["detail"] as? String, "low")
        }
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
            host == "api.githubcopilot.com" ||
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
