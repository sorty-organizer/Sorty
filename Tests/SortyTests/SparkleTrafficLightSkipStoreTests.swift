import Foundation
import XCTest
@testable import SortyLib

final class SparkleTrafficLightSkipStoreTests: XCTestCase {
    func testSkippedVersionsRemainScopedToTheSelectedVersion() throws {
        let suiteName = "test.sparkle-traffic-light-skip.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SparkleTrafficLightSkipStore(userDefaults: defaults)

        store.markSkipped(version: "100", displayVersion: "1.0.0")

        XCTAssertTrue(store.contains(version: "100", displayVersion: "1.0.0"))
        XCTAssertFalse(store.contains(version: "101", displayVersion: "1.0.1"))
    }

    func testClearingOneSkippedVersionPreservesOtherVersions() throws {
        let suiteName = "test.sparkle-traffic-light-skip.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SparkleTrafficLightSkipStore(userDefaults: defaults)

        store.markSkipped(version: "100", displayVersion: "1.0.0")
        store.markSkipped(version: "101", displayVersion: "1.0.1")
        store.clearSkipped(version: "100", displayVersion: "1.0.0")

        XCTAssertFalse(store.contains(version: "100", displayVersion: "1.0.0"))
        XCTAssertTrue(store.contains(version: "101", displayVersion: "1.0.1"))
    }
}
