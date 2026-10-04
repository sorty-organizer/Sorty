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

## 4 October 2026 follow-up

Read-only discovery found three stale Swift CI expectations in run 37123906655.
They were updated, not deleted: prompt enumeration is deterministic after
`c0eb5449`, Finder's manual status control was removed by `eb7bf264`, and
Settings now routes to the main window. The retained checks cover prompt
completeness and scan-order independence, searchable Finder setup, and deep-link
selection/clearing across repeated routes.

The following deletion candidates were reviewed before editing. Locations refer
to the pre-cleanup files. No production API exists solely for these tests.

| Exact test and location | Actual signal and remaining proof | History and deletion |
| --- | --- | --- |
| `FeatureSpecificUITests`, `Tests/SortyUITests/FeatureSpecificUITests.swift:11` | No test methods; cannot detect a failure. No proof is needed for an empty fixture. Native CI retains its four explicitly selected `AppUITests` cases. | `3933d218` removed its last methods but left setup, teardown, and stale cross-reference comments. Delete the empty file and Xcode membership. |
| `AppUITests.testAppleFoundationModelAvailability`, `AppUITests.swift:526` | No assertion after clicking an obsolete model button. It usually skips before reaching that click. It never verifies availability or provider selection. | Present since `16520e49`; this was an environment-dependent demonstration with an unfinished assertion comment. Delete the method; do not restore the removed control. |
| `AppUITests.testDeepScanAffectsScanningBehavior`, `AppUITests.swift:559` | Targets a removed `DeepScanToggle` and, if reached, accepts any existing window. Never scans a file. `ContentAnalyzerTests.testDeepScanDisabledSkipsTextFiles` and `testDeepScanDisabledSkipsRTF` exercise the actual analyzer behavior. | Present since `16520e49` as nominal feature integration. Delete the method; no production code or support seam is removed. |
| `AppUITests.testReasoningAffectsOrganizationOptions`, `AppUITests.swift:596` | Targets a removed `ReasoningToggle`, reads back its click, then checks that a window exists. Never organizes or inspects reasoning. No reasoning contract is lost. `PromptBuilderTests.testBudgetTruncationKeepsReasoningJSONContract` retains the independent prompt-tail contract. | Present since `16520e49` as nominal feature integration. Delete the method; no production code or support seam is removed. |

Risk: removing these methods loses no asserted scanning, model availability, or
reasoning-delivery contract. The retained native CI cases are
`testAppHasMainWindow`, `testAllSidebarItemsExistAndAreClickable`,
`testAllViewsLoadWithoutCrash`, and `testRapidNavigationMaintainsStability`.
The executable owner is `.github/workflows/macos-ui.yml`; use its existing
`xcodebuild build-for-testing` and `test-without-building` commands for later UI
validation. No local UI run is claimed for this minor deletion-only batch.

## Finder repair cleanup evidence

The manual Finder repair action was removed in `eb7bf264`. A tracked caller
search confirms `repairFinderSyncExtensionRegistrationAsync` has no caller.
Settings and deferred startup call `prepareFinderIntegrationAsync`; support
reports call `getFinderSyncDiagnosticsAsync`. The obsolete pipeline stages app
copies and re-signs or terminates the app, while the active maintenance path
registers extensions without those actions.

The live diagnostics path still executes `codesign --entitlements`, but
`missingFinderIntegrationAppEntitlements` unconditionally returns an empty list.
Removing that probe and its parser does not change any diagnostics result.
Retain stored staged-app identity validation for uninstall, registration parsing,
heartbeat/process evidence, disabled-extension handling, and the active
registration-maintenance path. Keep `SortyAppRepair.entitlements`: build.sh still
uses it to validate ad-hoc signing independently of runtime repair.

| Exact test and location before cleanup | Actual signal, callers, and remaining proof | History, deletion, and risk |
| --- | --- | --- |
| `FinderIntegrationStatusTests.testParseEntitlementsPlistWithValidXML`, `FinderIntegrationStatusTests.swift:300` | Foundation plist decoding through a wrapper used only by the obsolete codesign probe. No remaining production caller after probe removal. | Added before the Core extraction (`9c2932e7`) for host-entitlement repair. Delete wrapper and method; no parser contract is needed for a deleted input path. |
| `FinderIntegrationStatusTests.testParseEntitlementsPlistWithEmptyStringReturnsNil`, `FinderIntegrationStatusTests.swift:324` | Same removed wrapper, empty input. | Same provenance and deletion; no executable owner remains. |
| `FinderIntegrationStatusTests.testParseEntitlementsPlistWithInvalidXMLReturnsNil`, `FinderIntegrationStatusTests.swift:329` | Same removed wrapper, malformed input. | Same provenance and deletion; no executable owner remains. |
| `FinderIntegrationStatusTests.testFinderSyncDiagnosticsIgnoresMissingHostAppEntitlements`, `FinderIntegrationStatusTests.swift:195` | Supplies a test-only entitlements argument that diagnostics never use to choose a status. Production always supplies an empty list. Registered/disabled/verified status and auto-repair tests retain the actual decision contracts. | Host sandbox requirements were intentionally removed before the current Finder setup. Delete unused diagnostics argument/storage and unreachable signature-repair state together with this obsolete-input test. |

Focused hosted proof: `swift test --filter FinderIntegrationStatusTests` within
Swift CI's compiled package. This batch adds no replacement source-inspection
test. Build/release signing and extension registration remain independent
contracts, not reasons to preserve a runtime wrapper that has no effect.
