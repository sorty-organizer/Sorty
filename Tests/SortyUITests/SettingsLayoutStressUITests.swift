import XCTest

final class SettingsLayoutStressUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    private func waitForElement(_ element: XCUIElement, timeout: TimeInterval = 5.0) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    private func navigateToSettings() {
        let settingsSidebarItem = app.buttons["SettingsSidebarItem"]
        XCTAssertTrue(waitForElement(settingsSidebarItem, timeout: 8.0), "Settings sidebar item should exist")
        settingsSidebarItem.click()

        // The Settings view should show the category list.
        XCTAssertTrue(waitForElement(app.buttons["Organization Controls"], timeout: 8.0), "Settings categories should render")
    }

    private func resizeMainWindow(deltaWidth: CGFloat, deltaHeight: CGFloat) {
        let window = app.windows.firstMatch
        XCTAssertTrue(waitForElement(window, timeout: 8.0), "Main window should exist")

        // Drag bottom-right corner by a delta to resize.
        let bottomRight = window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
        let destination = bottomRight.withOffset(CGVector(dx: deltaWidth, dy: deltaHeight))
        bottomRight.press(forDuration: 0.1, thenDragTo: destination)

        // Give AppKit/SwiftUI a moment to settle.
        Thread.sleep(forTimeInterval: 0.4)
    }

    func testSettingsStressResizeAndSwitchCategories() {
        navigateToSettings()

        // Exercise sizes that tend to reveal layout feedback loops.
        resizeMainWindow(deltaWidth: -350, deltaHeight: -250)
        resizeMainWindow(deltaWidth: 700, deltaHeight: 500)

        let categories = [
            "Organization Controls",
            "AI Provider",
            "Analysis & Naming",
            "Finder Integration",
            "Advanced"
        ]

        for _ in 0..<3 {
            for category in categories {
                let button = app.buttons[category]
                XCTAssertTrue(button.exists, "Category button should exist: \(category)")
                button.click()
                Thread.sleep(forTimeInterval: 0.15)

                // Header should match selected category.
                XCTAssertTrue(app.staticTexts[category].exists, "Category header should be visible: \(category)")
            }
        }
    }
}
