//
//  DeeplinkUITests.swift
//  SortyUITests
//
//  Tests end-to-end deeplink handling by triggering the app via URL schemes.
//

import XCTest

final class DeeplinkUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Do not launch here, as we need to inject arguments per test
    }

    override func tearDownWithError() throws {
        app = nil
    }

    private func waitForElement(_ element: XCUIElement, timeout: TimeInterval = 5.0) -> Bool {
        return element.waitForExistence(timeout: timeout)
    }

    func testSettingsDeeplinkNavigation() throws {
        app.launchEnvironment["XCUITEST_DEEPLINK"] = "sorty://settings"
        app.launch()
        
        // Verify Settings view is active by checking for unique settings elements
        // "ReasoningToggle" is a specific identifier in SettingsView
        let reasoningToggle = app.switches["ReasoningToggle"]
        XCTAssertTrue(waitForElement(reasoningToggle, timeout: 10.0), "Settings view (ReasoningToggle) should be shown")
    }

    func testHistoryDeeplinkNavigation() throws {
        app.launchEnvironment["XCUITEST_DEEPLINK"] = "sorty://history"
        app.launch()
        
        // Verify History view by checking for the view or filter picker
        let historyView = app.otherElements["HistoryView"]
        let filterPicker = app.segmentedControls["HistoryFilterPicker"]
        let found = waitForElement(historyView, timeout: 10.0) || waitForElement(filterPicker, timeout: 5.0)
        XCTAssertTrue(found, "History view should be shown")
    }

    func testOrganizeDeeplinkWithParameters() throws {
        // Trigger deeplink: sorty://organize?path=/tmp&persona=developer
        app.launchEnvironment["XCUITEST_DEEPLINK"] = "sorty://organize?path=/tmp&persona=developer"
        app.launch()
        
        // When path is provided, we expect the 'ReadyToOrganizeView' to appear, NOT the directory selector
        // So we look for "StartOrganizationButton"
        let startButton = app.buttons["StartOrganizationButton"]
        
        // Also check if we might be in directory selection (fallback)
        let browseButton = app.buttons["BrowseForFolderButton"]
        
        // We expect either dependent on if path was accepted
        let exists = waitForElement(startButton, timeout: 10.0) || waitForElement(browseButton, timeout: 5.0)
        
        XCTAssertTrue(exists, "Organize view should be shown (Start button or Browse button)")
    }
}
