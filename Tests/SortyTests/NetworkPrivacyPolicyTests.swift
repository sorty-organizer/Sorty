import XCTest
@testable import SortyLib

private final class SuspendedNetworkPrivacyURLProtocol: URLProtocol {
    nonisolated(unsafe) static var onStart: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.onStart?()
    }

    override func stopLoading() {}
}

final class NetworkPrivacyPolicyTests: XCTestCase {
    func testTextOnlyFallbackRequiresPayloadOrMediaError() {
        XCTAssertFalse(AIRequestSupport.isPayloadTooLarge(
            AIClientError.apiError(statusCode: 400, message: "Invalid model")
        ))
        XCTAssertFalse(AIRequestSupport.isPayloadTooLarge(
            AIClientError.apiError(statusCode: 422, message: "Invalid response format")
        ))
        XCTAssertTrue(AIRequestSupport.isPayloadTooLarge(
            AIClientError.apiError(statusCode: 413, message: "Request rejected")
        ))
        XCTAssertTrue(AIRequestSupport.isPayloadTooLarge(
            AIClientError.apiError(statusCode: 400, message: "Unsupported image format")
        ))
    }

    func testGeminiOpenAIEndpointDoesNotAddAnExtraV1PathComponent() throws {
        let url = try AIRequestSupport.openAIChatCompletionsURL(
            from: AIProvider.gemini.defaultAPIURL!
        )

        XCTAssertEqual(url.absoluteString, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
    }

    private var testDefaultsSuiteName = ""
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        TestSynchronization.networkPrivacyModeLock.lock()
        testDefaultsSuiteName = "Sorty.NetworkPrivacyPolicyTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: testDefaultsSuiteName)
        testDefaults.removePersistentDomain(forName: testDefaultsSuiteName)
        NetworkPrivacyPolicy.setTestDefaultsSuiteName(testDefaultsSuiteName)
        testDefaults.removeObject(forKey: NetworkPrivacyPolicy.internetPrivacyModeKey)
    }

    override func tearDown() {
        SuspendedNetworkPrivacyURLProtocol.onStart = nil
        NetworkPrivacyPolicy.setTestDefaultsSuiteName(nil)
        testDefaults.removePersistentDomain(forName: testDefaultsSuiteName)
        testDefaults = nil
        testDefaultsSuiteName = ""
        TestSynchronization.networkPrivacyModeLock.unlock()
        super.tearDown()
    }

    func testInternetPrivacyModeDefaultsToDisabledWhenUnset() {
        testDefaults.removeObject(forKey: NetworkPrivacyPolicy.internetPrivacyModeKey)
        XCTAssertFalse(NetworkPrivacyPolicy.isInternetPrivacyModeEnabled)
    }

    func testAllRequestsAllowedWhenPrivacyModeDisabled() {
        testDefaults.set(false, forKey: NetworkPrivacyPolicy.internetPrivacyModeKey)

        let remote = URL(string: "https://api.openai.com/v1/models")!
        let localhost = URL(string: "http://localhost:11434/api/tags")!

        XCTAssertTrue(NetworkPrivacyPolicy.isRequestAllowed(url: remote))
        XCTAssertTrue(NetworkPrivacyPolicy.isRequestAllowed(url: localhost))
    }

    func testOnlyLoopbackAllowedWhenPrivacyModeEnabled() {
        testDefaults.set(true, forKey: NetworkPrivacyPolicy.internetPrivacyModeKey)

        let localhost = URL(string: "http://localhost:11434/api/tags")!
        let loopbackV4 = URL(string: "http://127.0.0.1:11434/api/tags")!
        let loopbackV4Alt = URL(string: "http://127.0.0.2:11434/api/tags")!
        let loopbackV6 = URL(string: "http://[::1]:11434/api/tags")!
        let loopbackV6Expanded = URL(string: "http://[0:0:0:0:0:0:0:1]:11434/api/tags")!
        let remote = URL(string: "https://api.openai.com/v1/models")!
        let nonLoopbackV4 = URL(string: "http://126.0.0.1:11434/api/tags")!

        XCTAssertTrue(NetworkPrivacyPolicy.isRequestAllowed(url: localhost))
        XCTAssertTrue(NetworkPrivacyPolicy.isRequestAllowed(url: loopbackV4))
        XCTAssertTrue(NetworkPrivacyPolicy.isRequestAllowed(url: loopbackV4Alt))
        XCTAssertTrue(NetworkPrivacyPolicy.isRequestAllowed(url: loopbackV6))
        XCTAssertTrue(NetworkPrivacyPolicy.isRequestAllowed(url: loopbackV6Expanded))
        XCTAssertFalse(NetworkPrivacyPolicy.isRequestAllowed(url: nonLoopbackV4))
        XCTAssertFalse(NetworkPrivacyPolicy.isRequestAllowed(url: remote))
    }

    func testAIRequestSupportBlocksRemoteRequestsWhenPrivacyModeEnabled() throws {
        testDefaults.set(true, forKey: NetworkPrivacyPolicy.internetPrivacyModeKey)

        let remote = URL(string: "https://api.openai.com/v1/models")!

        XCTAssertThrowsError(try AIRequestSupport.makeJSONRequest(url: remote, method: "GET")) { error in
            guard case AIClientError.internetAccessBlocked = error else {
                XCTFail("Expected internetAccessBlocked, got: \(error)")
                return
            }
            XCTAssertEqual(error.localizedDescription, "Internet access is blocked")
        }
    }

    func testAIRequestSupportAllowsLoopbackRequestsWhenPrivacyModeEnabled() throws {
        testDefaults.set(true, forKey: NetworkPrivacyPolicy.internetPrivacyModeKey)

        let local = URL(string: "http://localhost:11434/api/tags")!

        XCTAssertNoThrow(try AIRequestSupport.makeJSONRequest(url: local, method: "GET"))
    }

    func testGeminiOpenAICompatibleChatEndpointDoesNotDuplicateVersionPath() throws {
        let url = try AIRequestSupport.openAIChatCompletionsURL(
            from: "https://generativelanguage.googleapis.com/v1beta/openai"
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        )
    }

    func testSessionDelegateBlocksRedirectFromLoopbackToRemoteHost() throws {
        testDefaults.set(true, forKey: NetworkPrivacyPolicy.internetPrivacyModeKey)

        let local = URL(string: "http://localhost:11434/redirect")!
        let remote = URL(string: "https://api.openai.com/v1/models")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: local)
        let response = HTTPURLResponse(
            url: local,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": remote.absoluteString]
        )!
        var redirectedRequest: URLRequest?

        NetworkPrivacyURLSessionDelegate().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: remote)
        ) { request in
            redirectedRequest = request
        }

        XCTAssertNil(redirectedRequest)
    }

    func testEnablingPrivacyModeCancelsAnInFlightRemoteRequest() async throws {
        // The live session observes the standard defaults key for changes.
        NetworkPrivacyPolicy.setTestDefaultsSuiteName(nil)
        let key = NetworkPrivacyPolicy.internetPrivacyModeKey
        let previousValue = UserDefaults.standard.object(forKey: key)
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(false, forKey: key)
        let requestStarted = expectation(description: "Request started")
        SuspendedNetworkPrivacyURLProtocol.onStart = {
            requestStarted.fulfill()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuspendedNetworkPrivacyURLProtocol.self]
        let session = NetworkPrivacyPolicy.makeSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let requestTask = Task {
            try await session.data(from: URL(string: "https://example.com/private-upload")!)
        }
        await fulfillment(of: [requestStarted], timeout: 1)
        UserDefaults.standard.set(true, forKey: key)

        do {
            _ = try await requestTask.value
            XCTFail("Expected the in-flight request to be cancelled")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
    }

    func testCodexSubscriptionHealthCheckIsBlockedBeforeLaunchingCLI() async {
        testDefaults.set(true, forKey: NetworkPrivacyPolicy.internetPrivacyModeKey)
        let client = CodexSubscriptionClient(config: .default)

        do {
            try await client.checkHealth()
            XCTFail("Expected privacy mode to block Codex subscription access")
        } catch let error as AIClientError {
            XCTAssertTrue(error.isInternetAccessBlocked)
            XCTAssertEqual(error.localizedDescription, "Internet access is blocked")
            XCTAssertTrue(error.failureReason?.contains(AIClientError.internetAccessBlockedCode) == true)
        } catch {
            XCTFail("Expected internet privacy error, got: \(error)")
        }
    }

    @MainActor
    func testSparkleUpdateCheckStopsBeforeStartingNetworkAccess() {
        testDefaults.set(true, forKey: NetworkPrivacyPolicy.internetPrivacyModeKey)
        let updateManager = SparkleUpdateManager()

        updateManager.checkForUpdates()

        XCTAssertEqual(
            updateManager.updateState,
            .error(NetworkPrivacyPolicy.blockedMessage)
        )
    }

    func testTransientHTTPRetryInspectsStatusBeforeReturning() async throws {
        let url = URL(string: "https://example.com/v1/chat/completions")!
        var attempts = 0

        let (_, response) = try await AIRequestSupport.withTransientHTTPRetry(
            delays: [.zero, .zero]
        ) {
            attempts += 1
            let statusCode = attempts < 3 ? 502 : 200
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response as URLResponse)
        }

        XCTAssertEqual(attempts, 3)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testTransientHTTPRetryDoesNotRepeatDeterministicClientErrors() async throws {
        let url = URL(string: "https://example.com/v1/chat/completions")!
        var attempts = 0

        let (_, response) = try await AIRequestSupport.withTransientHTTPRetry(
            delays: [.zero, .zero]
        ) {
            attempts += 1
            let response = HTTPURLResponse(
                url: url,
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response as URLResponse)
        }

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
    }
}
