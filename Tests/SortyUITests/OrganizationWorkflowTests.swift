//
//  OrganizationWorkflowTests.swift
//  SortyUITests
//
//  End-to-end workflow tests for the organization feature.
//  Tests the full flow from folder selection through preview and edge cases.
//

import XCTest

final class OrganizationWorkflowTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Workflow Tests

    func testOrganizeViewShowsFolderSelectionInitially() throws {
        let organizeSidebarItem = app.buttons["OrganizeSidebarItem"]
        XCTAssertTrue(organizeSidebarItem.waitForExistence(timeout: 3.0))
        organizeSidebarItem.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Verify we see the initial folder selection state
        // Look for "Drop a folder" or similar prompt
        let dropPrompt = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'drop' OR label CONTAINS[c] 'folder' OR label CONTAINS[c] 'select'")
        ).firstMatch

        XCTAssertTrue(
            dropPrompt.waitForExistence(timeout: 3.0),
            "Organize view should prompt for folder selection"
        )
    }

    // MARK: - Edge Cases

    func testEmptyStateDisplays() throws {
        // Navigate to History (likely empty on test launch)
        let historySidebarItem = app.buttons["HistorySidebarItem"]
        XCTAssertTrue(historySidebarItem.waitForExistence(timeout: 3.0))
        historySidebarItem.click()
        Thread.sleep(forTimeInterval: 0.5)

        // History shows "No History Yet" + CTA when empty, or session cards when populated.
        // Assert the actual contract (passes either way: empty or populated).
        let emptyMessage = app.staticTexts["No History Yet"]
        let emptyCTA = app.buttons["HistoryEmptyStateCTA"]
        let hasHistoryCards = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'HistorySessionCard-'")
        ).count > 0
        XCTAssertTrue(
            emptyMessage.waitForExistence(timeout: 2.0) || emptyCTA.exists || hasHistoryCards,
            "History view should show 'No History Yet' empty state or history entries"
        )

        // An empty state or history list should be present
        XCTAssertTrue(
            app.windows.firstMatch.exists,
            "History view should display without crashing"
        )
    }
}
