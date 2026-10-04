import XCTest

final class OnboardingWorkflowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testProviderStepConfirmsAdvanceWithoutCredentials() throws {
        launchApp(environment: [
            "XCUITEST_FORCE_ONBOARDING": "1",
            "XCUITEST_DISABLE_STORED_PROVIDER_CREDENTIALS": "1"
        ])

        XCTAssertTrue(app.staticTexts["Sorty can be a skill"].waitForExistence(timeout: 5))
        let skillContinue = app.buttons["skill-import.continue"]
        XCTAssertTrue(skillContinue.waitForExistence(timeout: 5))
        let skillIsReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: skillContinue
        )
        XCTAssertEqual(XCTWaiter.wait(for: [skillIsReady], timeout: 5), .completed)
        skillContinue.click()
        XCTAssertTrue(app.staticTexts["Use Sorty in your agent"].waitForExistence(timeout: 3))
        skillContinue.click()
        XCTAssertTrue(app.staticTexts["Choose a skills folder"].waitForExistence(timeout: 3))
        app.buttons["skill-onboarding.continue-app"].click()

        XCTAssertTrue(app.otherElements["OnboardingView"].waitForExistence(timeout: 5))

        let advanceButton = app.buttons["OnboardingAdvanceButton"]
        XCTAssertTrue(advanceButton.waitForExistence(timeout: 3))
        XCTAssertTrue(advanceButton.isEnabled)
        advanceButton.click()

        let continueWithoutAI = app.buttons["Continue without AI"]
        XCTAssertTrue(continueWithoutAI.waitForExistence(timeout: 3))
        continueWithoutAI.click()

        XCTAssertTrue(app.otherElements["Permissions Step"].waitForExistence(timeout: 3))
    }

    func testCompletionHealthCheckFailureCanRetrySuccessfully() throws {
        launchApp(environment: [
            "XCUITEST_FORCE_ONBOARDING": "1",
            "XCUITEST_ASSUME_FILES_PERMISSION": "1",
            "XCUITEST_PROVIDER_HEALTHCHECK": "fail_once_then_succeed"
        ])

        let continueWithApp = app.buttons["skill-onboarding.continue-app"]
        XCTAssertTrue(continueWithApp.waitForExistence(timeout: 5))
        continueWithApp.click()

        XCTAssertTrue(app.otherElements["OnboardingView"].waitForExistence(timeout: 5))

        let advanceButton = app.buttons["OnboardingAdvanceButton"]
        XCTAssertTrue(advanceButton.waitForExistence(timeout: 3))
        advanceButton.click()

        let ollamaButton = app.buttons["OnboardingProvider_ollama"]
        XCTAssertTrue(ollamaButton.waitForExistence(timeout: 3))
        ollamaButton.click()
        advanceButton.click()
        advanceButton.click()
        advanceButton.click()

        let completeButton = app.buttons["OnboardingCompleteButton"]
        XCTAssertTrue(completeButton.waitForExistence(timeout: 5))
        completeButton.click()

        let retryButton = app.buttons["OnboardingCompletionRetryButton"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 5))
        retryButton.click()

        XCTAssertTrue(app.buttons["OrganizeSidebarItem"].waitForExistence(timeout: 8))
    }

    func testStartupRepairRedirectsToProviderSettings() throws {
        launchApp(environment: [
            "XCUITEST_FORCE_SETUP_REPAIR": "1",
            "XCUITEST_DISABLE_STORED_PROVIDER_CREDENTIALS": "1"
        ])

        XCTAssertTrue(app.staticTexts["Setup Repair"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Select Provider"].waitForExistence(timeout: 5))
    }

    private func launchApp(environment: [String: String]) {
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment = environment
        app.launch()
    }
}
