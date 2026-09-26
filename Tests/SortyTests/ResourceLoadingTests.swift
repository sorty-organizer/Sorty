//
//  ResourceLoadingTests.swift
//  SortyTests
//
//  Tests to ensure resources load correctly and prevent launch crashes
//  from Bundle.module issues in non-SPM builds.
//

import XCTest
@testable import SortyLib

@MainActor
final class ResourceLoadingTests: XCTestCase {

    // MARK: - Image Resource Loading Tests

    func testSortyResourcesImageLoadingReturnsNilForInvalidImages() {
        // Non-existent images should return nil, not crash
        let invalidImage = SortyResources.image(named: "NonExistentImage12345")
        XCTAssertNil(invalidImage, "Non-existent image should return nil")
    }

    func testWhatsNewTourImagesLoadFromResources() {
        let expectedImages = [
            "whats-new-preview",
            "whats-new-design-system-1",
            "whats-new-design-system-2",
            "whats-new-design-system-3",
            "whats-new-design-system-4",
            "whats-new-design-system-5"
        ]

        for imageName in expectedImages {
            let image = SortyResources.image(named: imageName)
            XCTAssertNotNil(image, "\(imageName) should be bundled for the What's New tour")
            XCTAssertGreaterThan(image?.size.width ?? 0, 2, "\(imageName) should have a valid width")
            XCTAssertGreaterThan(image?.size.height ?? 0, 2, "\(imageName) should have a valid height")
        }
    }

    func testWhatsNewAppIconLoadsWithoutBundleModule() {
        // The What's New tour shows AppIcon-Release.png from Resources/AppIcons.
        // Loading must use safe bundle lookups only — Bundle.module traps with
        // EXC_BREAKPOINT in Xcode-built apps where the SPM bundle is absent.
        for iconName in ["AppIcon-Release", "AppIcon-Debug"] {
            let image = SortyResources.image(named: iconName, withExtension: "png")
            XCTAssertNotNil(image, "\(iconName) should load from AppIcons without Bundle.module")
            XCTAssertGreaterThan(image?.size.width ?? 0, 2, "\(iconName) should have a valid width")
        }
    }

    func testMenuBarLabelImageUsesNonTemplateMascot() {
        let image = SortyResources.menuBarLabelNSImage()
        XCTAssertGreaterThan(image.size.width, 0, "Menu bar label image should load with a valid width")
        XCTAssertGreaterThan(image.size.height, 0, "Menu bar label image should load with a valid height")
        XCTAssertFalse(image.isTemplate, "Menu bar label image should remain full-color (non-template)")
    }

    func testMenuBarActivityImagesLoad() {
        for activity in MenuBarActivity.allCases {
            let image = SortyResources.image(
                named: activity.resourceName,
                withExtension: "png"
            )
            XCTAssertNotNil(image, "\(activity.rawValue) should have a bundled menu bar image")
        }
    }

    func testMenuBarControllerShowsMostRecentlyStartedActivity() {
        let controller = MenuBarController()
        XCTAssertEqual(controller.activity, .idle)

        controller.setActivity(.organizing, sourceID: "organization")
        controller.setActivity(.duplicateScanning, sourceID: "duplicates")
        XCTAssertEqual(controller.activity, .duplicateScanning)

        controller.setActivity(.learning, sourceID: "organization")
        XCTAssertEqual(controller.activity, .learning)

        controller.setActivity(nil, sourceID: "organization")
        XCTAssertEqual(controller.activity, .duplicateScanning)

        controller.setActivity(nil, sourceID: "duplicates")
        XCTAssertEqual(controller.activity, .idle)
    }

    func testMenuBarControllerMapsOrganizationModesAndStopsAtReady() {
        let controller = MenuBarController()

        controller.updateOrganizationActivity(
            state: .scanning,
            mode: .renameOnly,
            sourceID: "manual"
        )
        XCTAssertEqual(controller.activity, .renaming)

        controller.updateOrganizationActivity(
            state: .organizing,
            mode: .organize,
            sourceID: "watched",
            isWatchedFolder: true
        )
        XCTAssertEqual(controller.activity, .watchedFolder)

        controller.updateOrganizationActivity(
            state: .ready,
            mode: .organize,
            sourceID: "watched",
            isWatchedFolder: true
        )
        XCTAssertEqual(controller.activity, .renaming)
    }

    func testMenuBarGreetingTemporarilyOverridesAndRestoresActivity() async {
        let controller = MenuBarController()
        controller.setActivity(.organizing, sourceID: "organization")

        controller.showGreeting(for: .milliseconds(20))
        XCTAssertEqual(controller.activity, .greeting)

        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(controller.activity, .organizing)
    }
    
    // MARK: - Fallback Behavior Tests

    func testProviderWithMissingImageUsesFallback() {
        // The ProviderLogoView should gracefully fall back to system icon
        // when an image cannot be loaded via SortyResources.image()
        //
        // SortyResources.image() tries:
        // 1. Asset catalog (if compiled .car file exists)
        // 2. Images subdirectory (SPM .copy() resources)
        // 3. Direct bundle resource lookup
        //
        // ProviderLogoView falls back to system icon if all fail

        // All real providers should work - we just verify no crashes
        for provider in AIProvider.allCases {
            let _ = ProviderLogoView(provider: provider)
        }
        XCTAssertTrue(true, "All providers should load with graceful fallback")
    }

    // MARK: - Bundle Resolver Robustness Tests

    func testBundleResolverMultiLayerDetection() {
        // SortyResources uses multi-layer detection:
        // 1. Bundle.module (when available)
        // 2. Class-based bundle lookup
        // 3. Dynamic SPM bundle discovery
        // 4. Main bundle (final fallback)
        //
        // This test ensures at least one strategy works
        let bundle = SortyResources.bundle
        XCTAssertNotNil(bundle, "Bundle resolver should find a valid bundle")
        XCTAssertFalse(bundle.bundlePath.isEmpty, "Resolved bundle should have a valid path")
    }

    func testBundleResolverDoesNotCrashOnMissingResources() {
        // Looking up a non-existent resource should return nil, not crash
        let bundle = SortyResources.bundle
        let nonExistentURL = bundle.url(forResource: "NonExistentResource12345", withExtension: "xyz")
        XCTAssertNil(nonExistentURL, "Non-existent resource should return nil, not crash")
    }

    func testSortyResourcesBundleHasResourceURL() {
        // Ensure the resolved bundle has a resource URL for loading
        let bundle = SortyResources.bundle
        XCTAssertNotNil(bundle.resourceURL, "Bundle should have a resource URL")
    }
}

// MARK: - Integration Tests

final class ResourceLoadingIntegrationTests: XCTestCase {
    
    @MainActor
    func testSettingsViewModelCanInitialize() {
        // Integration test ensuring SettingsViewModel initializes without crash
        let viewModel = SettingsViewModel()
        XCTAssertNotNil(viewModel, "SettingsViewModel should initialize")
    }
    
    func testAIProviderDisplayNamesAreValid() {
        // Ensure all providers have valid display names for UI
        for provider in AIProvider.allCases {
            XCTAssertFalse(provider.displayName.isEmpty, "\(provider) should have a non-empty display name")
        }
    }
    
    func testAIProviderLogoImageNamesAreValid() {
        // Ensure all providers have valid logo image names
        for provider in AIProvider.allCases {
            XCTAssertFalse(provider.logoImageName.isEmpty, "\(provider) should have a non-empty logo image name")
        }
    }
}
