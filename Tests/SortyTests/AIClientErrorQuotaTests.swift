import Foundation
import XCTest
@testable import SortyLib

/// A 429 carrying a free-tier/quota body must surface as a usage-limit error,
/// not a transient "rate limit exceeded, wait and retry" error.
@MainActor
final class AIClientErrorQuotaTests: XCTestCase {
    private static let freeTierBody =
        "Free tier requests on this model are rate-limited. Upgrade to paid credits at https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E..."

    func testFreeTier429IsQuotaExhausted() {
        let error = AIClientError.apiError(statusCode: 429, message: Self.freeTierBody)

        XCTAssertTrue(error.isQuotaExhausted)
        XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("free-tier"))
        XCTAssertFalse(error.localizedDescription.localizedCaseInsensitiveContains("wait a moment"))
    }

    func testGeneric429IsNotQuotaExhausted() {
        let error = AIClientError.apiError(statusCode: 429, message: "Too many requests")

        XCTAssertFalse(error.isQuotaExhausted)
        XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("Rate limit exceeded"))
    }

    func testNon429WithQuotaWordingIsNotQuotaExhausted() {
        let error = AIClientError.apiError(statusCode: 403, message: Self.freeTierBody)

        XCTAssertFalse(error.isQuotaExhausted)
    }
}
