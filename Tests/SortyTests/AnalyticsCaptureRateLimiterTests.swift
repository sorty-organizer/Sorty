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
}
