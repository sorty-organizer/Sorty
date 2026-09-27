import XCTest
@testable import SortyLib
@testable import SortyCore

final class SettingsSearchTests: XCTestCase {
    func testStrategyCategoryMatchesDeepScanningQuery() {
        XCTAssertTrue(SettingsCategory.strategy.matchesSearch(query: "deep scanning"))
    }

    func testProviderCategoryMatchesApiKeyQuery() {
        XCTAssertTrue(SettingsCategory.provider.matchesSearch(query: "api key"))
    }

    func testUnrelatedCategoryDoesNotMatchQuery() {
        XCTAssertFalse(SettingsCategory.help.matchesSearch(query: "deep scanning"))
    }

    func testRulesFeatureMatchesFileTaggingQuery() {
        let matches = SettingsCategory.rules.featureMatches(query: "file tagging")

        XCTAssertTrue(matches.contains { $0.snippet.title == "Enable File Tagging" })
    }

    func testDeeplinkFeatureMatchesDeeplinkQuery() {
        let matches = SettingsCategory.deeplinks.featureMatches(query: "deeplink")

        XCTAssertEqual(matches.count, 17)
    }

    func testDeeplinkFeatureMatchesSpecificEntryQuery() {
        let matches = SettingsCategory.deeplinks.featureMatches(query: "persona deeplink")

        XCTAssertEqual(matches.first?.snippet.title, "Persona")
    }

    func testDeeplinkCategoryMatchesSortySchemeQuery() {
        XCTAssertTrue(SettingsCategory.deeplinks.matchesSearch(query: "sorty://"))
    }

    func testDeeplinkFeatureMatchesDownloadsWordQuery() {
        let matches = SettingsCategory.deeplinks.featureMatches(query: "downloads")

        XCTAssertTrue(matches.contains { $0.snippet.title == "Organize Folder" })
    }

    func testAutomationCategoryMatchesHyphenSeparatedQuery() {
        XCTAssertTrue(SettingsCategory.automation.matchesSearch(query: "launch-at-login"))
    }

    func testRulesFeatureMatchesFinderTagsQuery() {
        let matches = SettingsCategory.rules.featureMatches(query: "finder tags")

        XCTAssertEqual(matches.first?.snippet.title, "Enable File Tagging")
    }

    func testDeeplinkFeatureMatchPrioritizesSpecificEntry() {
        let matches = SettingsCategory.deeplinks.featureMatches(query: "finder settings")

        XCTAssertEqual(matches.first?.snippet.title, "Finder Settings")
    }

    func testDeeplinkFocusTargetMappingsForKnownSnippets() {
        XCTAssertEqual(SettingsCategory.deeplinks.focusTarget(for: snippet(in: .deeplinks, titled: "Persona")), .deeplinksPersona)
        XCTAssertEqual(SettingsCategory.deeplinks.focusTarget(for: snippet(in: .deeplinks, titled: "Organize Folder")), .deeplinksOrganizeFolder)
        XCTAssertEqual(SettingsCategory.deeplinks.focusTarget(for: snippet(in: .deeplinks, titled: "Exclude from Sorty")), .deeplinksFinderExclude)
    }

    func testCategoriesForGroupPartitionsAllCasesWithoutDuplicates() {
        let grouped = SettingsCategoryGroup.allCases.flatMap(SettingsCategory.categories(for:))
        let visibleCategories = SettingsCategory.allCases

        XCTAssertEqual(Set(grouped), Set(visibleCategories))
        XCTAssertEqual(grouped.count, visibleCategories.count)
    }

    func testRulesFocusTargetMappingsForKnownSnippets() {
        XCTAssertEqual(SettingsCategory.rules.focusTarget(for: snippet(in: .rules, titled: "Content Rules")), .rulesContentRules)
        XCTAssertEqual(SettingsCategory.rules.focusTarget(for: snippet(in: .rules, titled: "Enable File Tagging")), .rulesFileTagging)
        XCTAssertEqual(SettingsCategory.rules.focusTarget(for: snippet(in: .rules, titled: "Organization Style")), .rulesOrganizationStyle)
        XCTAssertEqual(SettingsCategory.notifications.focusTarget(for: snippet(in: .notifications, titled: "System Notifications")), .notificationsSystem)
        XCTAssertEqual(SettingsCategory.advanced.focusTarget(for: snippet(in: .advanced, titled: "Block Internet Connections")), .advancedInternetPrivacy)
        XCTAssertEqual(SettingsCategory.advanced.focusTarget(for: snippet(in: .advanced, titled: "Generate Diagnostic Report")), .advancedErrorLogs)
    }

    func testFocusTargetIsNilForUnknownSnippet() {
        let customSnippet = SettingsFeatureSnippet(title: "Unknown", summary: "Custom")

        XCTAssertNil(SettingsCategory.rules.focusTarget(for: customSnippet))
    }

    func testHelpFocusTargetMappingsForKnownSnippets() {
        XCTAssertEqual(SettingsCategory.help.focusTarget(for: snippet(in: .help, titled: "Support Links")), .helpSupport)
        XCTAssertEqual(SettingsCategory.help.focusTarget(for: snippet(in: .help, titled: "Copy Support Report")), .helpIssueDetails)
    }

    func testEveryVisibleFeatureSnippetHasAFocusTarget() {
        for category in SettingsCategory.allCases {
            for snippet in category.featureSnippets {
                XCTAssertEqual(
                    category.focusTarget(for: snippet)?.category,
                    category,
                    "Misdirected focus target for \(category.rawValue) > \(snippet.title)"
                )
            }
        }
    }

    func testExpandedSettingsIndexFindsSpecificControls() {
        XCTAssertEqual(
            SettingsCategory.strategy.featureMatches(query: "max filename length").first?.snippet.title,
            "Maximum Filename Length"
        )
        XCTAssertEqual(
            SettingsCategory.strategy.featureMatches(query: "filename separator").first?.snippet.title,
            "Filename Separator"
        )
        XCTAssertEqual(
            SettingsCategory.provider.featureMatches(query: "ollama").first?.snippet.title,
            "Ollama"
        )
        XCTAssertEqual(
            SettingsCategory.automation.featureMatches(query: "separate automation model").first?.snippet.title,
            "Use Separate Automation Model"
        )
        XCTAssertEqual(
            SettingsCategory.finder.featureMatches(query: "check finder status").first?.snippet.title,
            "Check Finder Status"
        )
        XCTAssertEqual(
            SettingsCategory.permissions.featureMatches(query: "Open Privacy & Security").first?.snippet.title,
            "Open Privacy & Security"
        )
        XCTAssertEqual(
            SettingsCategory.notifications.featureMatches(query: "processing errors").first?.snippet.title,
            "Processing Errors"
        )
        XCTAssertEqual(
            SettingsCategory.advanced.featureMatches(query: "request timeout").first?.snippet.title,
            "Request Timeout"
        )
        XCTAssertEqual(
            SettingsCategory.help.featureMatches(query: "privacy policy").first?.snippet.title,
            "Privacy Policy"
        )
    }

    func testEveryFocusTargetRoutesToAVisibleCategory() {
        let visibleCategories = Set(SettingsCategory.allCases)

        for target in SettingsFocusTarget.allCases {
            XCTAssertTrue(
                visibleCategories.contains(target.category),
                "\(target.rawValue) routes to a hidden category"
            )
        }
    }

    func testEveryVisibleCategoryFallbackHasAFocusTarget() {
        for category in SettingsCategory.allCases {
            let fallback = SettingsFeatureSnippet(
                title: category.rawValue,
                summary: "Open this section"
            )

            XCTAssertNotNil(
                category.focusTarget(for: fallback),
                "Missing fallback focus target for \(category.rawValue)"
            )
        }
    }

    private func snippet(
        in category: SettingsCategory,
        titled title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> SettingsFeatureSnippet {
        guard let snippet = category.featureSnippets.first(where: { $0.title == title }) else {
            XCTFail("Expected snippet '\(title)' in category '\(category.rawValue)'", file: file, line: line)
            return SettingsFeatureSnippet(title: "Missing", summary: "")
        }
        return snippet
    }
}
