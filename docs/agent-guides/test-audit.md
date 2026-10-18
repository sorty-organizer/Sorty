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

## 18 October 2026 deep audit

Three independent discovery lanes reviewed core/filesystem/organizer tests,
AI/Learnings, and scripts/CI/native UI. Caller searches covered all tracked
sources and tests, then checked historical consumers before selecting cuts.
This is a static audit plus focused execution, not proof of every native UI
interaction or every public library client's usage.

### Deletion evidence

| Exact test or seam before cleanup | Actual signal and surviving owner | History and deletion decision |
| --- | --- | --- |
| `ImageVisionAnalyzerTests.testPrepareImagesForVisionProcessesMultipleImages` and `testPrepareImagesForVisionReportsCompletedAttempts`, `ImageVisionAnalyzerTests.swift:55,75` | Batch aggregation and progress for successful and corrupt images are meaningful. Move both tests to `prepareFilesForVision`, preserving exact attachment keys and completed attempts `[1, 2, 3]`. PDF, resizing, missing/corrupt input, relative-name, unsupported-type, and organizer vision-flow tests remain. | `98087cc5` replaced the sole organizer call with the file/PDF API. Remove the old image-only batch implementation after moving its coverage. This resolves the deferred vision item in the October 4 audit. |
| `ImageVisionAnalyzerTests.testVisionPayloadBudgetUsesEncodedSize`, `ImageVisionAnalyzerTests.swift:11` | The old case covered an unused clamping wrapper. Retain the live encoded-byte contract with fixed expected sizes for input lengths 0 through 4. The organizer still owns its cap, skip accounting, and payload selection. | Helpers came from `ffe9ada2` and `f485b8e1`; the prior complexity audit removed `prepareVisionBatch`. Delete its remaining `totalBase64Bytes`, `clamped`, and duplicate cap, whose only consumers were each other and this test. No live cap or safety check is removed. |
| `StreamingLogicTests.testProgressLineInvalidatesOlderExtractedInsightCache`, `StreamingLogicTests.swift:361` | Preserve the decision-line regression against `currentInsight` and `insightHistory`, the properties the UI actually reads. Keep `InsightsCache`, which extraction still consumes. | `adbb4b6f` switched AnalysisView from `getCachedInsights()` to those published properties. Remove the getter, whose sole remaining caller was this test. |
| `FinderIntegrationStatusTests.testFinderIntegrationAvailabilityStatusFlagsIncompleteFinderSyncSetup` and `testFinderIntegrationAvailabilityStatusReflectsReadyFinderSync`, `FinderIntegrationStatusTests.swift:26,52` | Detect only changes to abandoned presentation states and text. Real registered, disabled, missing, indeterminate, heartbeat, and running-process diagnostics tests remain. No current presentation contract needs replacement proof. | `6ffa92a2` added the mapper for an experimental settings row; `e9d11de0` removed its UI consumers. Delete these two methods plus `FinderIntegrationAvailabilityStatus` and its mapper. Current settings use `FinderSyncDiagnostics.setupState`. |
| `FinderIntegrationStatusTests.testFinderRequestIsConsumedOnlyOnce`, `FinderIntegrationStatusTests.swift:14` | Preserve the consume-once IPC contract by awaiting the live `receiveFromExtensionAsync` twice. Fixture creation now throws and directory cleanup uses `defer`. | `7530e24b` migrated ExtensionListener to the async receiver. Remove the unused synchronous receiver, retaining off-main validation and read/remove ordering in the live path. |

These are internal app implementation leftovers. SwiftPM declares public
library products, so caller counts alone were insufficient; each removed API
also has a documented replacement or a deleted owning flow. No package,
protocol, persistence, migration, or documented external contract was removed.
Risk is loss of a downstream dependency on an undocumented obsolete helper;
repository callers and compiled tests must be checked after removal.

### Genuine bug retained and repaired

`LLMRuleInducer` advertises `{day}` in destination templates, but
`LearningsAnalyzer.applyTemplate` computed the day without substituting it.
The existing matching-rule test now demands the exact
`/Photos/2024/01/01/IMG_20240101_123456.jpg` destination for a
`{year}/{month}/{day}/{filename}` template. The repair belongs in the shared
expander used by both batch analysis and single-file proposals. It needs no
new production hook.

### Retained and deferred

Keep history/profile/snapshot/default-key migrations, quota/auth redaction,
prompt contracts, and all five cache-tooling test files. The cache tests run in
Swift CI and exercise real invalidation, corruption, metadata, signing, and
executable behavior. Documented hidden error-preview routes are maintained
manual tooling, not dead tests.

`ContentAnalyzer.analyzeFiles` still has test-only callers, but scanner progress
and cancellation proof must move to the live scanner boundary before removing
it. Public model mutation/convenience APIs, mapping feedback/JSON helpers,
secure deletion, and organizer reset need more contract/history evidence.
Several native UI tests target retired controls or allow conditional no-op
success. They require supported fixtures and a native UI run before deciding
what to repair or remove. None was deleted to hide a failure.

### Execution

Focused Swift selection:
`swift test --filter 'ImageVisionAnalyzerTests|FolderOrganizerVisionFlowTests|FinderIntegrationStatusTests|StreamingLogicTests|LearningsAnalyzerTests|LearningsRuleScoringTests'`.
Tooling selection matches hosted CI:
`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p 'test_*cache.py'`.

Execution results and hosted run links are recorded below after checks finish.
The imported OpenClaw/Vitest/autoreview commands remain unavailable; independent
subagent diff review and Sorty's actual checks are used instead.

Local results: all 101 selected Swift tests passed after rebuilding the changed
production modules, including the exact-path day regression. Before the fix,
that regression failed with `/Photos/2024/01/{day}/IMG_20240101_123456.jpg`.
All seven cache-tooling tests passed. An earlier sandbox-denied build attempt
ran stale output and is excluded from this proof. `git diff --check` passed;
independent subagent diff review found no blocking issue.

Production: 2 lines added, 143 removed, net -141. Tests: 31 added, 70 removed,
net -39. Documentation is counted separately. Only the two obsolete Finder
presentation test methods were deleted outright; the other affected contracts
were retained at their live owners. Native UI tests were not run. Existing
SortyApp analytics actor-isolation warnings remain outside this cleanup.
Hosted [Swift CI run 39050540535](https://github.com/sorty-organizer/Sorty/actions/runs/39050540535)
passed for code commit `2f2cf615`: all 1,002 package tests, test compilation,
app build, fuzzing, cache-tooling checks, and Gitleaks. The dispatch-only
pre-release validation step did not run on this push. This is build/test proof,
not native UI or release-signing proof. No PR was created; changes were pushed
directly to main.

## 18 October 2026 follow-up

Second pass over production symbols with no callers outside their own tests.
Each removal was proven with `git grep -nw` across `Sources`, `Tests`, and
`scripts`, `git log -S` for the commit that dropped the last caller, and a
confirmed live replacement.

### Deletion evidence

| Removed | Why obsolete | Live path |
| --- | --- | --- |
| `ExtensionCommunication` handoff slot, `receiveFromExtensionAsync`, `ExtensionListener.drainHandoffSlot` | Only writer was `SortyActionExtension`, deleted in `7d574b19` | Finder Sync deeplinks via `DeeplinkHandler` |
| Quick Action uninstall/status probes, `FinderIntegrationStatus`, `appleScriptForOrganizing` | No callers since Finder setup simplification (`eb7bf264`) | `FinderSyncDiagnostics.setupState`/`isOperational` |
| `FinderSyncDiagnostics.isVerifiedWorking`/`needsRepair` | Shorthands; tests now assert `setupState`/`isOperational` directly | Same diagnostics |
| `AutomationManager` front-window, `canOrganizeSelection`, recovery helpers; `FinderAutomation.getFrontmostFinderWindowPath` | No callers since `eb7bf264` | `requestAutomationPermissionCheck`, selection monitoring |
| `NotificationManager.showProcessingComplete` overloads, preview sample, action labels | Superseded completion API | Current completion notifications |
| `ModelCatalog.refreshAllAvailable`, `visionModelPrefixes` | Prefix table replaced in `6ffa92a2` | `matchesProviderVisionPrefixes`, per-provider refresh |
| `CodexCLIAuthManager.startLaunchProbeIfNeeded` | Launch probe removed deliberately in `1fee260a` | On-demand auth checks |
| `FileSystemManager` revert marks | Write-only; never read | `AppCoordinator` `.organizationDidRevert` snapshot refresh |
| `FolderWatcher.startWatching`/`stopWatching`/`reacquireAccessIfNeeded` | Single-folder entry points unused | Batch watcher sync |
| `AIConfig.organizeDeadlineDate`/`globalOrganizeDeadline` | Never wired since `745a604d` | Per-request timeouts |
| `FolderOrganizer.regenerateWithProvider`, `resetToIdleState` | Superseded / test-only | `regenerateWithModel(provider:model:)`, `transition(to:)` |
| `ScopedSecurityAccess`, `StorageLocation.resolveURL(for:)` | Orphaned | Bookmark resolution in storage services |
| `LearningsManager.recordRuleSuccess`, `getPendingRules`, `isRuleInCooldown`, model-directory helpers | Replaced by explicit feedback (`fa4fb449`) | `InferredRule.isEligible()`, `approveRule`/`rejectRule` |
| `LearningsFileManager.secureDelete`/`profileExists`/`storageDirectoryPath`, `LearningsAnalysisResult.toJSON` | Test-only | `deleteAllData`; result is never persisted |
| `FileItem.finalDisplayName`, `FolderSuggestion.filesWithFinalNames`, summary `shouldShowBadge`/`canProvideFeedback` | Test-only | Views read rename mappings and `summary.state` directly |
| Misc: `Constants` enum, `toggleLaunchAtLogin`, `getRecognitionLanguages`, `preferredAvailableSessionID`, `biometryDisplayName`, `authenticateForLearningsAccess`, `computeSampleFingerprint`, exclusion history helpers, history cost totals | No callers | Learnings gate uses `authenticateForSensitiveAction` |

Tests deleted only where they exercised a removed symbol or were strict subsets
of a surviving test (`PreReleaseValidationTests` hidden/system exclusion cases
duplicate `SemanticAnalysisTests`).

### Genuine bugs fixed

- `SortyResources.findSPMBundle` returned nil under `make`'s `.build` symlink to
  the shared cache, so `ResourceLoadingTests` failed locally (18 nil images)
  while CI passed. Lookup now tries the code bundle's sibling first and resolves
  the symlink before enumerating (`0c154e65`).
- Low-confidence learned rules start as `pendingApproval` and are never applied,
  but Learnings rows showed them as "Enabled" with no way to approve. Rows now
  say "Awaiting approval" and offer an Approve button (`3d805719`).
- `testReverseTaggingOperation` could pass while wiping pre-existing tags; it now
  seeds an existing tag and asserts it survives reversal (`cf73e810`).

### Deferred

- `ContentAnalyzer.analyzeFiles` and `LearningsManager.proposeMapping`: test-only
  but guard live behavior; retarget tests before removing.
- `setCrossVolumeProgressHandler`: production reads a handler nobody sets, so
  cross-volume moves report no progress. Wire it up or remove it.
- `SortyUninstaller.cleanupPathCandidates`: test-only, not investigated.
- Native UI tests (`Tests/SortyUITests`) reference stale identifiers
  (`ReasoningToggle`, `ScanDuplicatesButton`, `ConfirmAddRuleButton`,
  "Organization History", the "Success" filter, "Organization Controls"),
  and several make no assertions or always skip. CI only runs four
  `AppUITests` cases on manual dispatch, so they need repair against current
  ids (`HistoryScreen`, `HistoryFilterPicker`, `StartScanAction`, "Undoable")
  or deletion.

### Execution

Local: `swift build --build-tests` clean (only existing SortyApp analytics
actor-isolation warnings); 293 affected tests passed, then the full package
suite: 993 tests, 0 failures, 1 skipped. Production net -1,051 lines, tests net
-157 since `57f3fd41`. Native UI tests were not run. Hosted
[Swift CI run 39097524984](https://github.com/sorty-organizer/Sorty/actions/runs/39097524984)
passed for `3cc5be10` (package tests, app build, fuzzing, Gitleaks).


## 18 October 2026 deep follow-up

Baseline: `9784dbe0` on `main`, clean checkout. Three read-only discovery lanes
traced production entry points, tests, references, and history before deleting.
This pass continues the earlier audit rather than counting its removals again.
Independent preservation reviews checked the model/learnings, scanner/Finder,
and UI boundaries after edits. No new product defect was demonstrated in this
pass, and no failing test was deleted as a substitute for repairing a bug.

### Evidence and coverage ownership

| Removed code or exact test | Evidence of obsolescence | Retained proof and risk |
| --- | --- | --- |
| `AnalysisView.stageIndicator`, `AIReasoningStatus`, `AnalysisRefreshManager`, `RefreshManager` | `df4334d3` removed the rendered stage indicator. The remaining computed property had no caller; timer outputs fed only that property. Removing the manager leaves the generic timer with no source, test, or script consumer. Remove its Xcode file entries too. | Active `StreamingProgressBeam`, progress banner, stream observers, and accessibility labels remain. No checked-in tests exercised the abandoned timer. UI rendering is not claimed by package tests. |
| `AutomationManager` selection monitoring, timers, activation callbacks, settings/state | `4850d163` introduced demand enrollment, but no caller ever used `beginSelectionMonitoring` or `endSelectionMonitoring`. Demand stays zero, and no feature reads its selection state. | Permission activation observer, opt-in migration, and post-organization actions remain. Explicit selection goes through `LiveOrganizerServices.finderSelectionReader` to `FinderAutomation.getSelectedFiles`. `PermissionReliabilityTests` and Finder diagnostics remain. |
| `ContentAnalyzer.analyzeFiles`; `testAnalyzeFilesEmpty`, `testAnalyzeFilesWithProgress`, `testAnalyzeFilesMixedTypes` in `ContentAnalyzerTests.swift` | The three tests were the only batch-API callers. Production `DirectoryScanner` owns its own two-lane enrichment and invokes `analyze(fileURL:)`, including its cache scheduling. | Extend the existing scanner deep-scan test to check exact text, unsupported-file metadata, and actual progress callbacks. Single-file extraction, cache, OCR, UTF-8, and deep-scan-disabled tests remain. Empty-batch behavior needs no proof after deleting that API. |
| `FolderSuggestion.addFile`, `removeFile`, `addTag`; `testAddFileWithoutRename`, `testAddFileWithRename`, `testRemoveFile`, `testAddTagToFile`, `testAddDuplicateTag` in `FolderSuggestionTests.swift` | Helpers originated in `44cd5f74`/`24345996`; their only remaining callers were these exclusive helper tests. Live preview edits arrays, and parsing constructs mappings directly. | Keep nested tag/rename lookup, parser, organizer, and live preview coverage. Remove the unused `preservesOriginalExtension` predicate while retaining the exact sanitized-name assertion. |
| `LearningsManager.acceptMapping`, `rejectMapping`, `editMapping`; `testAcceptMapping`, `testRejectMapping`, `testEditMapping` | Convenience wrappers from `24345996`/`a963c30b` never reached the current app flow. Only these tests called them. | Existing `testAddLabeledExample` owns acceptance. Retarget rejection/edit cases to `addLabeledExample`, preserving category, action, and destination checks. Leave profile persistence, consent, cooldown, and migration tests. |
| `StorageLocationsManager.discoverAllSubfolders`; `testDiscoverAllSubfoldersIncludesMoreThanPromptLimitedSet` | The 200-folder wrapper had exactly one caller, its own test. Current prompt generation independently calls the same discovery service with a 12-folder limit. | Keep prompt discovery and storage access/recovery tests. The removed test guarded only the retired wrapper's larger inventory, not the prompt contract. |
| Provider model-documentation properties, instruction placeholder, unused quality accessor/error enum/monitor accessor/private lost-access helper | No source, test, or script consumer. The provider docs UI stopped consuming the properties in `c3833623`. The lost-access helper survived earlier deletion of its caller. | No stored fields, coding keys, migration, protocol requirements, auth, or scoped-access lifecycle removed. These are undocumented app helpers despite SwiftPM's public library products. |
| Unused Learnings hero, header transition, privacy blur modifier, tour image inventory, preview factories/container | Each entry was declaration-only or reachable solely from another removed helper. Active previews/harnesses use the retained factories. | Keep active privacy masking and `PrivacyPathMaskerTests`, actual tour assets and packaging tests, current Learnings dashboard, and live onboarding/preview helpers. No current rendered UI contract is replaced. |

### Retained and deferred

Keep historical data/defaults/bookmark migrations, current provider routing,
security boundaries, cache tests, and active UI previews. Native UI tests still
have stale identifiers and conditional no-op assertions, as listed in the earlier
pass. Their intended product contracts require repair and native execution;
this audit does not delete them merely because they may fail. Likewise,
`SortyUninstaller` cleanup helpers preserve filesystem safety contracts and
remain pending a real-boundary test migration. Cross-volume progress wiring
remains an earlier unresolved product question.

The earlier deferred `ContentAnalyzer.analyzeFiles` and mapping feedback-wrapper
items are resolved by this pass. No computer use or native UI run was performed.
The imported OpenClaw/Vitest/autoreview tooling is unavailable here; independent
subagent preservation review and the repository's actual Swift checks apply.

### Validation

The freshly compiled affected selection passed all 176 tests. The migrated
scanner case initially failed because it compared raw `/var` fixture paths with
Foundation's `/private/var` enumeration paths. A separate Foundation probe
reproduced that spelling difference. The test now locates each unique filename,
unwrapping both records and preserving the exact content, unsupported-type, and
progress assertions. No production change was needed for that test error.

All seven cache-tooling tests passed using CI's unittest discovery command.
`git diff --check` and `plutil -lint Sorty.xcodeproj/project.pbxproj` passed.
The fresh Swift build compiled the app and tests; existing SortyApp analytics
actor-isolation and package-resource warnings remain. Production: 0 added,
1,186 removed. Tests: 29 added, 182 removed, net -153. Xcode membership and
documentation are separate from those counts.

The full package suite then passed against that fresh build: 983 tests,
0 failures, 1 skip in `AppStateTests.testFilesAndFoldersPermissionPersistsSeparatelyFromSelectedDirectory`
because the test host cannot create security-scoped bookmarks. This is an
existing environment guard, unchanged by the audit. The command was
`swift test --disable-sandbox --skip-build`, after the successful fresh
`swift test --disable-sandbox --filter` selection above.

Code commit `b25d1303` was pushed directly to `main`. Hosted Swift CI
[run 39103590450](https://github.com/sorty-organizer/Sorty/actions/runs/39103590450)
passed: all 983 package tests, test compilation, app build, 20,000-iteration
fuzzing, cache-tooling checks, and Gitleaks. The dispatch-only pre-release
validation step was skipped by workflow policy. Native UI and release-signing
validation remain outside this pass. No PR or branch was created.
