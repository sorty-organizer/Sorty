//
//  FeatureSpecificUITests.swift
//  SortyUITests
//
//  Tests for specific feature areas: Duplicates, Watched Folders,
//  Exclusion Rules, and Personas.
//

import XCTest

final class FeatureSpecificUITests: XCTestCase {

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

    // MARK: - Duplicates Feature Tests
    // Covered by AppUITests.testDuplicatesScanButtonIntegration (ScanDuplicatesButton
    // existence + valid state), AppUITests.testDuplicateDetectionIntegration
    // (ScanDuplicatesButton isEnabled when detection is on), and
    // AppAccessibilityTests.testDuplicatesViewCoreElementsExist (a11y probe).

    // MARK: - Watched Folders Feature Tests
    // Covered by AppUITests.testWatchedFoldersViewShowsCorrectEmptyState
    // (AddWatchedFolderButton existence + content) and
    // AppUITests.testKeyUIElementsHaveAccessibilityIdentifiers.

    // MARK: - Exclusion Rules Feature Tests
    // Covered by AppUITests.testExclusionRulesWorkflow and
    // AppUITests.testCompleteExclusionRuleCreationAndVerification.

    // MARK: - Learnings Feature Tests
    // Covered by AppUITests.testAllViewsLoadWithoutCrash and
    // AppUITests.testAllSidebarItemsExistAndAreClickable.

    // MARK: - Help / Deep Link Tests
    // Covered by AppUITests.testAppHasMainWindow; real routing is verified in
    // DeeplinkUITests (settings/history/organize).
}
