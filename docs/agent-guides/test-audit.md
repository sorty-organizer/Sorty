# Test audit

Keep tests that exercise Sorty's behavior, persistence, security, packaging,
provider routing, or a credible regression. Remove tests that only read back
their own assignments, test Foundation directly, or duplicate stronger checks.

## September 30, 2026 cleanup

This deletion-only batch removes eight methods. No production code or test-only
production hooks are removed. Locations below refer to the pre-cleanup files.

| Test and location | Actual signal and retained proof | History |
| --- | --- | --- |
| `AppStateTests.testOnboardingPersistence`, `AppStateTests.swift:69` | Reads back its own UserDefaults writes without constructing AppState. Fresh-install, incomplete-setup, and version-update tests exercise the real owner, including completion and relaunch. | Added in `910cbb4b`; `6ffd802a` replaced the original AppState exercise with direct defaults calls. |
| `AppStateTests.testAllAppViewCases`, `AppStateTests.swift:257` | Reads back a plain `currentView` assignment for a copied list of enum cases. Setup-repair routing and window-session tests retain behavioral navigation checks. | Added in `910cbb4b`. |
| `AppStateTests.testSidebarToggle`, `AppStateTests.swift:271` | Tests Swift's Bool toggle on a plain published property. `testDefaultInitialization` retains the default contract. | Added in `910cbb4b`. |
| `AppStateTests.testDirectoryPickerToggle`, `AppStateTests.swift:283` | Reads back a plain Bool assignment. `testDefaultInitialization` retains the default contract. This test never calls the picker-request or onboarding-completion methods. | Added in `910cbb4b`. |
| `ResourceLoadingTests.testBundleResolverDoesNotCrashOnMissingResources`, `ResourceLoadingTests.swift:141` | Calls Foundation's Bundle lookup directly. The retained invalid-image test exercises Sorty's missing-image path; tour, icon, and menu image tests exercise resource loading. | Added in release preparation `add38f16`. |
| `ResourceLoadingIntegrationTests.testSettingsViewModelCanInitialize`, `ResourceLoadingTests.swift:160` | Checks a nonoptional value for nil. Startup tests retain hydration, credential, and reset behavior. | Added in release preparation `add38f16`. |
| `ResponseParserEdgeCaseTests.testParseJSONWithExtraFields`, `PreReleaseValidationTests.swift:598` | Accepts any parser error, so rejecting the entire fixture passes. It establishes no extra-field acceptance contract. | Added in prerelease batch `f4c754e6`. |
| `ResponseParserEdgeCaseTests.testParseValidOrganizationResponse`, `PreReleaseValidationTests.swift:651` | Checks only folder count. `ResponseParserTests.testValidJSONParsing` checks assignments, folder name, session name, partial-plan warnings, and unmapped files; sibling cases exercise multiple folders. | Added in prerelease batch `f4c754e6`. |

Production callers remain intact: app commands and MainWindowRootView use
AppState; settings views and SortyApp construct SettingsViewModel; artwork and
Finder code use SortyResources; AI clients invoke ResponseParser. No removed
method is called by production code. Each deletion removes only its test body
and, where empty, its section heading.

Retain provider factory construction tests, parser rejection and Unicode cases,
bookmark checks, and resource packaging checks. Their observable contracts are
distinct even when an individual assertion looks trivial.

## Validation

Risk is limited to losing the weak signals described above. Sorty's minor-change
policy skips local build and test runs for this batch. Swift CI and release CI
discover the remaining suite through the `SortyTests` SwiftPM target.

If execution is needed after a later behavioral change, the focused command is
`swift test --filter 'AppStateTests|ResourceLoadingTests|ResourceLoadingIntegrationTests|SettingsViewModelStartupTests|ResponseParserTests|ResponseParserEdgeCaseTests'`.

The imported test-audit skill references OpenClaw, Vitest, and autoreview tools
that are absent here. Use Sorty's repository policies and review the diff; do
not invent replacement commands or claim those checks ran.
