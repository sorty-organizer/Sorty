//
//  GitHubCopilotAuthManagerTests.swift
//  SortyTests
//
//  Tests for cached Copilot auth state inference.
//

import XCTest
@testable import SortyLib
@testable import SortyCore
@testable import SortyAI

@MainActor
final class GitHubCopilotAuthManagerTests: XCTestCase {
    func testHasValidCachedCopilotTokenReturnsTrueForNonEmptyTokenAndFutureExpiry() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expiry = now.addingTimeInterval(601)

        let result = GitHubCopilotAuthManager.hasValidCachedCopilotToken(
            cachedToken: "cached-token",
            expiry: expiry,
            now: now
        )

        XCTAssertTrue(result)
    }

    func testHasValidCachedCopilotTokenReturnsFalseWhenTokenMissing() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expiry = now.addingTimeInterval(601)

        let result = GitHubCopilotAuthManager.hasValidCachedCopilotToken(
            cachedToken: nil,
            expiry: expiry,
            now: now
        )

        XCTAssertFalse(result)
    }

    func testHasValidCachedCopilotTokenReturnsFalseWhenTokenIsEmpty() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expiry = now.addingTimeInterval(601)

        let result = GitHubCopilotAuthManager.hasValidCachedCopilotToken(
            cachedToken: "",
            expiry: expiry,
            now: now
        )

        XCTAssertFalse(result)
    }

    func testHasValidCachedCopilotTokenReturnsFalseWhenExpiryIsTooClose() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expiry = now.addingTimeInterval(300)

        let result = GitHubCopilotAuthManager.hasValidCachedCopilotToken(
            cachedToken: "cached-token",
            expiry: expiry,
            now: now
        )

        XCTAssertFalse(result)
    }

    func testHasRecoverableAuthStateReturnsTrueWhenAccessTokenExists() {
        let result = GitHubCopilotAuthManager.hasRecoverableAuthState(
            hasAccessToken: true,
            hasValidCachedCopilotToken: false
        )

        XCTAssertTrue(result)
    }

    func testHasRecoverableAuthStateReturnsFalseWhenOnlyCachedCopilotTokenExists() {
        let result = GitHubCopilotAuthManager.hasRecoverableAuthState(
            hasAccessToken: false,
            hasValidCachedCopilotToken: true
        )

        XCTAssertFalse(result)
    }

    func testHasRecoverableAuthStateReturnsFalseWhenNoTokenPathExists() {
        let result = GitHubCopilotAuthManager.hasRecoverableAuthState(
            hasAccessToken: false,
            hasValidCachedCopilotToken: false
        )

        XCTAssertFalse(result)
    }
}
