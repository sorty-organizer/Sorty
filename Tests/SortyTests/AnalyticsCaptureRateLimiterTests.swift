import XCTest
@testable import SortyLib
@testable import SortyCore

final class AnalyticsCaptureRateLimiterTests: XCTestCase {
    func testAnalyticsCaptureRateLimiting() {
        var limiter = AnalyticsCaptureRateLimiter()

        // Phase 1: limit enforced within the window.
        for _ in 0..<120 {
            XCTAssertTrue(limiter.shouldCapture(now: 10))
        }
        XCTAssertFalse(limiter.shouldCapture(now: 10))

        // Phase 2: window reset allows captures again.
        XCTAssertTrue(limiter.shouldCapture(now: 70))

        // Phase 3: reset() clears the limit.
        limiter.reset()
        for _ in 0..<120 {
            XCTAssertTrue(limiter.shouldCapture(now: 10))
        }
        XCTAssertFalse(limiter.shouldCapture(now: 10))
        limiter.reset()
        XCTAssertTrue(limiter.shouldCapture(now: 10))
    }
}

final class ReliabilityCaptureRateLimiterTests: XCTestCase {
    func testReliabilityCaptureRateLimiting() {
        var limiter = ReliabilityCaptureRateLimiter()

        // Phase 1: limit enforced within the window.
        for _ in 0..<30 {
            XCTAssertTrue(limiter.shouldCapture(now: 10))
        }
        XCTAssertFalse(limiter.shouldCapture(now: 10))

        // Phase 2: window reset allows captures again.
        XCTAssertTrue(limiter.shouldCapture(now: 70))

        // Phase 3: reset() clears the limit.
        limiter.reset()
        for _ in 0..<30 {
            XCTAssertTrue(limiter.shouldCapture(now: 10))
        }
        XCTAssertFalse(limiter.shouldCapture(now: 10))
        limiter.reset()
        XCTAssertTrue(limiter.shouldCapture(now: 10))
    }
}

@MainActor
final class ReliabilityErrorDiagnosticsTests: XCTestCase {
    func testRequestContextRetainsSafeFactsWithoutConfigurationSecrets() {
        let secret = "private-customer-model-and-api-key"
        var config = AIConfig(
            provider: .openAICompatible, apiURL: "https://private.example/\(secret)?key=\(secret)",
            apiKey: secret, model: secret, requestTimeout: 75, maxTokens: 2048,
            enableStreaming: true, enableVision: false
        )
        let context = AIRequestDiagnosticContext(config: config, fileCount: 350, attachmentCount: 0)
        config.provider = .gemini
        let data = ReliabilityManager.requestDiagnostics(context)

        XCTAssertEqual(data["ai_provider"] as? String, AIProvider.openAICompatible.rawValue)
        XCTAssertEqual(data["endpoint_kind"] as? String, "custom")
        XCTAssertEqual(data["model_family"] as? String, "other")
        XCTAssertEqual(data["configured_timeout_seconds"] as? Int, 75)
        XCTAssertEqual(data["output_token_limit"] as? Int, 2048)
        XCTAssertFalse(String(describing: data).contains(secret))
        XCTAssertFalse(String(reflecting: context).contains(secret))
        XCTAssertFalse(String(describing: data).contains("private.example"))
    }

    func testRequestContextDistinguishesProviderLocalAndOnDeviceEndpoints() {
        let cases: [(AIProvider, String?, AIRequestDiagnosticContext.EndpointKind)] = [
            (.gemini, AIProvider.gemini.defaultAPIURL, .provider),
            (.ollama, "http://localhost:11434", .local),
            (.openAICompatible, "http://[::1]:8080/v1", .local),
            (.openAI, "https://proxy.example/v1", .custom),
            (.appleFoundationModel, nil, .onDevice),
        ]
        for (provider, url, expected) in cases {
            let config = AIConfig(provider: provider, apiURL: url, model: "customer-model")
            XCTAssertEqual(AIRequestDiagnosticContext(config: config).endpointKind, expected)
        }
    }

    func testProviderCodesAndDecodingHintsDoNotForwardUntrustedContent() {
        let message = #"{"error":{"code":"model_not_found","message":"private-file secret-token","param":"private-param"}}"#
        let data = ReliabilityManager.errorDiagnostics(AIClientError.apiError(statusCode: 404, message: message))
        XCTAssertEqual(data["provider_error_code"] as? String, "model_not_found")
        XCTAssertFalse(String(describing: data).contains("private"))
        XCTAssertFalse(String(describing: data).contains("secret-token"))
        let unknown = ReliabilityManager.errorDiagnostics(AIClientError.apiError(
            statusCode: 400, message: #"{"error":{"code":"private-secret-code"}}"#
        ))
        XCTAssertNil(unknown["provider_error_code"])
        let cases = [
            ("Invalid JSON response from AI", "invalid_json"),
            ("Response missing required fields", "missing_required_fields"),
            ("HTTP 200 contained no completion text (private-response)", "empty_completion"),
            ("The model stream ended before its completion event.", "incomplete_stream"),
            ("private-response", "unknown"),
        ]
        for (context, expected) in cases {
            let diagnostics = ReliabilityManager.errorDiagnostics(AIClientError.jsonDecodingError(context: context))
            XCTAssertEqual(diagnostics["decoding_failure"] as? String, expected)
            XCTAssertFalse(String(describing: diagnostics).contains("private-response"))
        }
    }

    func testBreadcrumbsRejectUnknownWorkflowAndScreenValues() {
        XCTAssertNotNil(ReliabilityManager.workflowDiagnostics(workflow: "duplicate_scan", stage: "scanning", outcome: "started"))
        XCTAssertNil(ReliabilityManager.workflowDiagnostics(workflow: "private-folder", stage: "scanning", outcome: "started"))
        XCTAssertNil(ReliabilityManager.workflowDiagnostics(workflow: "organize", stage: "private-stage", outcome: "started"))
        XCTAssertNil(ReliabilityManager.workflowDiagnostics(workflow: "organize", stage: "started", outcome: "private-outcome"))
        XCTAssertNotNil(ReliabilityManager.screenDiagnostics("settings_ai_provider"))
        XCTAssertNil(ReliabilityManager.screenDiagnostics("settings_private-customer"))
    }

    func testProviderStatusAndQuotaHaveDistinctCausesWithoutResponseBody() {
        let body = "private response with a filename and credential"
        let failure = AIClientError.apiError(statusCode: 503, message: body)
        XCTAssertEqual(ReliabilityManager.classify(failure).cause, "http_503")
        let diagnostics = ReliabilityManager.errorDiagnostics(failure)
        XCTAssertEqual(diagnostics["http_status"] as? Int, 503)
        XCTAssertFalse(String(describing: diagnostics).contains(body))
        XCTAssertEqual(
            ReliabilityManager.classify(AIClientError.apiError(statusCode: 429, message: "insufficient quota")).cause,
            "quota_exhausted"
        )
    }

    func testWrappedTimeoutRetainsSystemCode() {
        let failure = AIClientError.networkError(URLError(.timedOut))
        XCTAssertEqual(ReliabilityManager.classify(failure).cause, "timeout")
        XCTAssertEqual(ReliabilityManager.errorDiagnostics(failure)["system_error_code"] as? Int, NSURLErrorTimedOut)
        XCTAssertTrue(ReliabilityManager.shouldIgnore(AIClientError.networkError(URLError(.cancelled))))
    }

    func testLimitHintsDoNotCollectProviderMessages() {
        let cases = [
            ("The model reached its output limit.", "output"),
            ("Anthropic reached max_tokens.", "output"),
            ("Maximum context length exceeded.", "context"),
            ("Request entity too large.", "request_size"),
            ("Rejected.", "unknown"),
        ]
        for (message, expectedHint) in cases {
            let diagnostics = ReliabilityManager.errorDiagnostics(
                AIClientError.apiError(statusCode: 413, message: message + " private-file-name secret-token")
            )
            XCTAssertEqual(diagnostics["limit_hint"] as? String, expectedHint)
            XCTAssertFalse(String(describing: diagnostics).contains("private-file-name"))
            XCTAssertFalse(String(describing: diagnostics).contains("secret-token"))
        }
    }

    func testArbitraryDomainAndDecodingContextAreNotCollected() {
        let failure = NSError(domain: "private-file-name", code: NSURLErrorCancelled)
        XCTAssertFalse(ReliabilityManager.shouldIgnore(failure))
        XCTAssertNil(ReliabilityManager.errorDiagnostics(failure)["system_error_domain"])
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "private response"))
        let diagnostics = ReliabilityManager.errorDiagnostics(decoding)
        XCTAssertEqual(diagnostics["decoding_failure"] as? String, "data_corrupted")
        XCTAssertFalse(String(describing: diagnostics).contains("private response"))
    }

    func testPlanMismatchDoesNotCollectFolderPaths() {
        let failure = OrganizationError.planDirectoryMismatch(expected: "/private/source", actual: "/private/target")
        XCTAssertEqual(ReliabilityManager.classify(failure).cause, "plan_directory_mismatch")
        XCTAssertFalse(String(describing: ReliabilityManager.errorDiagnostics(failure)).contains("/private/"))
    }

    func testFaultSeparatesSortyBugsFromProviderAndSetupFailures() {
        let cases: [(Error, ReliabilityFault)] = [
            (AIClientError.apiError(statusCode: 413, message: ""), .sorty),
            (AIClientError.apiError(statusCode: 503, message: ""), .aiProvider),
            (AIClientError.apiError(statusCode: 429, message: "insufficient quota"), .aiProvider),
            (AIClientError.apiError(statusCode: 401, message: ""), .setup),
            (AIClientError.apiError(statusCode: 404, message: ""), .setup),
            (AIClientError.jsonDecodingError(context: "private response"), .aiOutput),
            (AIClientError.networkError(URLError(.timedOut)), .network),
            (FileSystemError.diskFull(path: "/private/file", underlyingErrno: nil), .system),
            (OrganizationError.noCurrentPlan, .sorty),
            (NSError(domain: "com.example", code: 1), .unknown),
        ]
        for (failure, expected) in cases {
            XCTAssertEqual(ReliabilityManager.classify(failure).fault, expected, "\(failure)")
        }
    }

    func testIssueTitleIsReadableAndBuiltOnlyFromIdentifiers() {
        let title = ReliabilityManager.issueTitle(
            feature: "organize",
            operation: "generate_plan",
            classification: ReliabilityManager.classify(
                AIClientError.apiError(statusCode: 413, message: "private-file-name")
            )
        )
        XCTAssertEqual(title.type, "SortyError")
        XCTAssertEqual(title.value, "Organize › Generate plan — HTTP 413 (request too large)")
    }

    func testEventKindRecognizesSDKHangsCrashesAndWatchdogTerminations() {
        XCTAssertEqual(
            ReliabilityEventKind.inferred(exceptionTypes: ["App Hanging"], isFatal: false, hasUnhandledException: false),
            .hang
        )
        XCTAssertEqual(
            ReliabilityEventKind.inferred(exceptionTypes: ["App Hang Fully Blocked"], isFatal: false, hasUnhandledException: false),
            .hang
        )
        XCTAssertEqual(
            ReliabilityEventKind.inferred(exceptionTypes: ["WatchdogTermination"], isFatal: true, hasUnhandledException: false),
            .watchdogTermination
        )
        XCTAssertEqual(
            ReliabilityEventKind.inferred(exceptionTypes: ["EXC_BAD_ACCESS"], isFatal: true, hasUnhandledException: true),
            .crash
        )
    }

    func testPartialApplyFailureIsClassifiedWithoutPrivateDetails() {
        let failure = FileSystemError.partialApplyFailure(
            operations: [], underlyingDescription: "private filename and provider response"
        )
        XCTAssertEqual(ReliabilityManager.classify(failure).cause, "partial_apply_failure")
        XCTAssertEqual(ReliabilityManager.classify(failure).category, "filesystem")
        XCTAssertFalse(String(describing: ReliabilityManager.errorDiagnostics(failure)).contains("private"))
    }
}
