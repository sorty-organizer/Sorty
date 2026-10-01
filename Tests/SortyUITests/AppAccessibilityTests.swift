//
//  AppAccessibilityTests.swift
//  SortyUITests
//
//  Tests for verifying proper accessibility identifiers
//  are set on all major UI elements.
//

import XCTest

@MainActor
final class AppAccessibilityTests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        launchApp()
    }

    override func tearDown() async throws {
        app = nil
    }

    private func launchApp(environment: [String: String] = [:]) {
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment = ["XCUITEST_FORCE_MAIN_APP": "1"].merging(environment) { _, new in new }
        app.launch()
    }

    private func navigate(to sidebarIdentifier: String, screenIdentifier: String) throws {
        let sidebarItem = app.buttons[sidebarIdentifier]
        XCTAssertTrue(sidebarItem.waitForExistence(timeout: 5))
        sidebarItem.click()
        XCTAssertTrue(
            app.otherElements[screenIdentifier].waitForExistence(timeout: 5),
            "\(screenIdentifier) should appear before its accessibility audit"
        )
    }

    private func auditCurrentScreen() throws {
        try app.performAccessibilityAudit()
    }

    func testOnboardingAccessibilityAudit() throws {
        app.terminate()
        launchApp(environment: [
            "XCUITEST_FORCE_MAIN_APP": "0",
            "XCUITEST_FORCE_ONBOARDING": "1",
            "XCUITEST_DISABLE_STORED_PROVIDER_CREDENTIALS": "1"
        ])
        XCTAssertTrue(app.otherElements["OnboardingView"].waitForExistence(timeout: 5))

        try auditCurrentScreen()
    }

    func testOrganizerAccessibilityAudit() throws {
        try navigate(to: "OrganizeSidebarItem", screenIdentifier: "OrganizerScreen")
        try auditCurrentScreen()
    }

    func testPreviewAccessibilityAudit() throws {
        app.terminate()
        launchApp(environment: ["XCUITEST_SEED_PREVIEW": "1"])
        XCTAssertTrue(app.otherElements["OrganizationPreviewScreen"].waitForExistence(timeout: 8))

        try auditCurrentScreen()
    }

    func testHistoryAccessibilityAudit() throws {
        try navigate(to: "HistorySidebarItem", screenIdentifier: "HistoryScreen")
        try auditCurrentScreen()
    }

    func testDuplicatesAccessibilityAudit() throws {
        try navigate(to: "DuplicatesSidebarItem", screenIdentifier: "DuplicatesScreen")
        try auditCurrentScreen()
    }

    func testWatchedFoldersAccessibilityAudit() throws {
        try navigate(to: "WatchedFoldersSidebarItem", screenIdentifier: "WatchedFoldersScreen")
        try auditCurrentScreen()
    }

    func testSettingsAccessibilityAudit() throws {
        try navigate(to: "SettingsSidebarItem", screenIdentifier: "SettingsScreen")
        try auditCurrentScreen()
    }

    // MARK: - Sidebar Navigation Identifiers
    // Covered by AppUITests.testAllSidebarItemsExistAndAreClickable (same 7 identifiers
    // + isEnabled + content routing) and AppUITests.testAllViewsLoadWithoutCrash.

    // MARK: - Duplicates View Accessibility

    func testDuplicatesViewCoreElementsExist() throws {
        try navigate(to: "DuplicatesSidebarItem", screenIdentifier: "DuplicatesScreen")

        let scanButton = app.buttons["ScanDuplicatesButton"]
        XCTAssertTrue(
            scanButton.waitForExistence(timeout: 3.0),
            "Scan Duplicates button should exist with accessibility identifier"
        )
    }

    // MARK: - Organize View Accessibility

    func testOrganizeViewCoreElementsExist() throws {
        try navigate(to: "OrganizeSidebarItem", screenIdentifier: "OrganizerScreen")

        XCTAssertTrue(
            app.buttons["BrowseForFolderButton"].waitForExistence(timeout: 3),
            "Organize view should expose its folder picker as a button"
        )
    }

}
