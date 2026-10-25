import Foundation
import XCTest
@testable import SortyCore

final class AnalyticsEventNameTests: XCTestCase {
    func testReadableNamesFromIdentifiers() {
        XCTAssertEqual(AnalyticsEventName.workflow(workflow: "organize", stage: "plan_ready", outcome: "success"), "Organize Plan Ready")
        XCTAssertEqual(AnalyticsEventName.workflow(workflow: "organize", stage: "plan_generation", outcome: "failed"), "Organize Plan Generation Failed")
        XCTAssertEqual(AnalyticsEventName.workflow(workflow: "duplicate_scan", stage: "cancelled", outcome: "cancelled"), "Duplicate Scan Cancelled")
        XCTAssertEqual(AnalyticsEventName.feature(subfeature: "health_check", action: "completed", outcome: "success"), "Health Check Completed")
        XCTAssertEqual(AnalyticsEventName.feature(subfeature: "custom_personas", action: "persona_selected", outcome: "success"), "Custom Personas Selected")
        XCTAssertEqual(AnalyticsEventName.buttonClicked("apply_changes"), "Apply Changes Clicked")
        XCTAssertEqual(AnalyticsEventName.screenName(screen: "settings", section: "advanced"), "Settings › Advanced")
        XCTAssertEqual(AnalyticsEventName.screenName(screen: "settings_ai_provider", section: "ai_provider"), "Settings › AI Provider")
    }

    func testValidationRejectsUnboundedNames() {
        XCTAssertTrue(AnalyticsEventName.isValid("Organize Plan Ready"))
        XCTAssertFalse(AnalyticsEventName.isValid("app:feature_used"))
        XCTAssertFalse(AnalyticsEventName.isValid("/Users/me/Documents"))
        XCTAssertFalse(AnalyticsEventName.isValid(String(repeating: "A", count: 81)))
    }

    func testCountryCodeComesFromRegionSetting() {
        XCTAssertEqual(AnalyticsManager.countryCode(locale: Locale(identifier: "en_GB")), "GB")
    }
}
