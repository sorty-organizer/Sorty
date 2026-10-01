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
