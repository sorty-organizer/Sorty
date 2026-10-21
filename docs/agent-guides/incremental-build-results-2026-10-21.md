# Incremental compilation measurements, October 21, 2026

Measured on Apple Swift 6.2.4, arm64, Debug, macOS 15 deployment target. Most probe rows were captured at `afb6a1e4`; the final command-menu row was captured at `9eb0cb3c` after reverting the Help extraction. These are local compiler measurements, not hosted CI or runtime validation.

## Method

The supplied `probe.sh` appends a comment to one file, builds `SortyApp`, restores that file, and rebuilds before moving on. Each row is the first build's SwiftPM-reported duration. Before values come from the supplied pre-split measurements. Each build uses the warm `/tmp/sorty-split-build` scratch directory and these flags:

```sh
swift build --scratch-path /tmp/sorty-split-build -c debug --product SortyApp -j 14 \
  --disable-sandbox --disable-index-store -debug-info-format none \
  -Xswiftc -gline-tables-only -Xcc -gline-tables-only \
  -Xswiftc -module-cache-path -Xswiftc /tmp/sorty-split-build/ModuleCache \
  -Xcc -fmodules-cache-path=/tmp/sorty-split-build/ModuleCache
```

This comment-edit probe is comparable to the supplied baseline. It does not measure app packaging, signing, launch, behavior-changing body edits, multi-file edits, or UI acceptance. Single samples are sensitive to load and occasional relinking. Repeated outliers are reported separately.

## Original SwiftUI files

| File under `Sources/SortyLib/Views` | Before | After | Change |
| --- | ---: | ---: | ---: |
| `OnboardingView.swift` | 2.95s | 6.81s | +131% |
| `ExclusionRulesView.swift` | 4.30s | 3.23s | -25% |
| `AppCommands.swift` | 3.02s | 3.31s | +10% |
| `DuplicatesView.swift` | 2.98s | 3.29s | +10% |
| `WatchedFoldersView.swift` | 4.02s | 3.25s | -19% |
| `LearningsView.swift` | 4.28s | 3.27s | -24% |
| `OptimizedPreviewTree.swift` | 6.08s | 3.19s | -48% |
| `HistoryDetailSheet.swift` | 3.80s | 3.30s | -13% |
| `Onboarding/CompletionStepView.swift` | 3.48s | 3.27s | -6% |
| `Settings/SkillSetupView.swift` | 4.56s | 3.21s | -30% |
| `Settings/AIProviderSettingsView.swift` | 3.47s | 3.28s | -5% |
| `Onboarding/PermissionsStepView.swift` | 3.21s | 3.27s | +2% |
| `OrganizationCompleteView.swift` | 3.13s | 3.22s | +3% |
| `Settings/PermissionsSettingsView.swift` | 5.19s | 3.23s | -38% |
| `Onboarding/ProviderSelectionStepView.swift` | 3.76s | 3.27s | -13% |
| `OrganizeView.swift` | 3.08s | 3.48s | +13% |
| `ReadyToOrganizeView.swift` | 3.16s | 4.94s | +56% |
| `Settings/TroubleshootingSettingsView.swift` | 4.73s | 3.65s | -23% |
| `AnalysisStreamPreview.swift` | 2.96s | 3.38s | +14% |

## Successors and other refactored files

These files have no independent pre-split baseline. They are measured after extraction to check whether a slow expression moved elsewhere.

| File under `Sources/SortyLib/Views` | Lines | Rebuild |
| --- | ---: | ---: |
| `AddExclusionRuleView+Conditions.swift` | 277 | 3.35s |
| `AddExclusionRuleView+Editing.swift` | 395 | 4.68s |
| `AddExclusionRuleView+Validation.swift` | 178 | 3.32s |
| `AddExclusionRuleView.swift` | 125 | 3.28s |
| `AnalysisInsightsView.swift` | 610 | 3.32s |
| `AppState.swift` | 1822 | 3.34s |
| `CompactStorageLocationRow.swift` | 203 | 3.37s |
| `ContentView.swift` | 491 | 3.32s |
| `DirectoryHeader.swift` | 137 | 3.34s |
| `DirectorySelectionView.swift` | 556 | 3.32s |
| `DuplicatesEmptyStateView.swift` | 129 | 3.28s |
| `DuplicatesHeaders.swift` | 275 | 3.34s |
| `DuplicatesView+Actions.swift` | 369 | 3.21s |
| `ExclusionConditionDraft.swift` | 114 | 3.39s |
| `ExclusionRuleGroups.swift` | 378 | 3.26s |
| `ExclusionRuleRow.swift` | 286 | 3.34s |
| `ExclusionRulesView+NaturalLanguage.swift` | 616 | 3.27s |
| `FlatFileRowView.swift` | 237 | 3.23s |
| `FlatFolderRowView.swift` | 277 | 3.30s |
| `FlatUnorganizedRows.swift` | 192 | 3.32s |
| `FolderHistoryDetailRow.swift` | 328 | 3.32s |
| `HUDNotificationOverlay.swift` | 459 | 3.32s |
| `HistoryDetailModel.swift` | 83 | 3.30s |
| `HistoryDetailSheet+Sections.swift` | 401 | 3.30s |
| `HistoryDuplicateCards.swift` | 231 | 3.29s |
| `HistoryLearningCards.swift` | 132 | 3.29s |
| `HistoryOperationRows.swift` | 190 | 3.28s |
| `InstructionFileReference.swift` | 158 | 3.30s |
| `LearningExclusionRow.swift` | 73 | 3.29s |
| `LearningInsightRows.swift` | 145 | 3.23s |
| `LearningsView+Dashboard.swift` | 239 | 4.62s |
| `LearningsView+RecordDetails.swift` | 292 | 3.33s |
| `LearningsView+Records.swift` | 367 | 4.53s |
| `LearningsView+Settings.swift` | 373 | 3.32s |
| `ModelDirectoryRow.swift` | 228 | 3.29s |
| `Onboarding/CompletionAudioController.swift` | 101 | 3.38s |
| `Onboarding/CompletionCelebrationBackdrop.swift` | 423 | 3.32s |
| `Onboarding/CompletionContent.swift` | 227 | 3.28s |
| `Onboarding/CompletionHero.swift` | 327 | 3.30s |
| `Onboarding/CompletionParticles.swift` | 179 | 3.32s |
| `Onboarding/CompletionTips.swift` | 91 | 3.29s |
| `Onboarding/OnboardingProviderRows.swift` | 198 | 3.31s |
| `Onboarding/PermissionActionButton.swift` | 54 | 3.29s |
| `Onboarding/PermissionDemoVideoView.swift` | 209 | 3.20s |
| `Onboarding/PermissionEducationView.swift` | 207 | 3.26s |
| `Onboarding/PermissionRow.swift` | 238 | 3.32s |
| `Onboarding/PermissionTypes.swift` | 154 | 3.27s |
| `Onboarding/ProviderSelectionControls.swift` | 112 | 3.28s |
| `Onboarding/ProviderSelectionStepView+Configuration.swift` | 366 | 3.30s |
| `Onboarding/ProviderSelectionStepView+Connection.swift` | 352 | 3.28s |
| `Onboarding/WelcomeRevealAudio.swift` | 154 | 3.26s |
| `Onboarding/WelcomeRevealEffects.swift` | 299 | 3.30s |
| `Onboarding/WelcomeStepView.swift` | 336 | 3.31s |
| `OnboardingBackdropBlur.swift` | 274 | 3.31s |
| `OnboardingBottomGradient.swift` | 245 | 3.27s |
| `OnboardingEdgeGlow.swift` | 48 | 3.27s |
| `OnboardingEdgeGlowPresenter.swift` | 283 | 3.35s |
| `OnboardingIntroGlow.swift` | 186 | 3.33s |
| `OnboardingIntroView.swift` | 318 | 3.27s |
| `OnboardingOrbitField.swift` | 676 | 3.32s |
| `OnboardingProgressBar.swift` | 142 | 3.34s |
| `OnboardingStep.swift` | 97 | 3.30s |
| `OnboardingWindowTitleConfigurator.swift` | 211 | 3.26s |
| `OrganizationCompleteView+Actions.swift` | 213 | 3.42s |
| `OrganizationCompleteView+Presentation.swift` | 452 | 3.26s |
| `OrganizationCompletionCards.swift` | 327 | 3.24s |
| `OrganizationErrorView.swift` | 650 | 3.22s |
| `OrganizePreviewObjects.swift` | 45 | 3.27s |
| `OrganizeView+Actions.swift` | 368 | 3.22s |
| `OrganizeView+Content.swift` | 203 | 3.32s |
| `OrganizingStreamSuggestions.swift` | 362 | 3.28s |
| `PartialUndoResultSheet.swift` | 201 | 3.22s |
| `Preview/PreviewActionsView.swift` | 679 | 3.25s |
| `PreviewDropDelegates.swift` | 70 | 3.26s |
| `PreviewHandoffView.swift` | 85 | 3.27s |
| `PreviewRows.swift` | 95 | 3.27s |
| `PreviewStore.swift` | 996 | 3.41s |
| `ReadyToOrganizeView+Instructions.swift` | 345 | 3.34s |
| `ReadyToOrganizeView+Storage.swift` | 200 | 3.30s |
| `RenameGenerationEffects.swift` | 162 | 3.27s |
| `RenameGenerationEventList.swift` | 54 | 3.36s |
| `RenameGenerationRow.swift` | 123 | 3.42s |
| `ScanProgressView.swift` | 284 | 3.28s |
| `Settings/AIProviderRow.swift` | 228 | 3.22s |
| `Settings/AIProviderSettingsView+Actions.swift` | 265 | 3.23s |
| `Settings/AIProviderSettingsView+Authentication.swift` | 220 | 3.25s |
| `Settings/AIProviderSettingsView+Connection.swift` | 239 | 3.25s |
| `Settings/CacheMaintenance.swift` | 180 | 3.22s |
| `Settings/CodexDeviceAuthSheet.swift` | 234 | 3.41s |
| `Settings/MaintenanceActionTile.swift` | 92 | 3.43s |
| `Settings/OpenCodeCredentialLinkView.swift` | 172 | 3.49s |
| `Settings/OrganizationStrategySettingsView.swift` | 659 | 3.48s |
| `Settings/PermissionAnimatedIcon.swift` | 149 | 3.41s |
| `Settings/PermissionSettingsCard.swift` | 281 | 3.54s |
| `Settings/ProviderAuthenticationControl.swift` | 66 | 3.34s |
| `Settings/SettingsView.swift` | 583 | 3.31s |
| `Settings/SkillSetupComponents.swift` | 147 | 3.25s |
| `Settings/SkillSetupView+Actions.swift` | 200 | 3.28s |
| `Settings/SkillSetupView+Import.swift` | 371 | 3.33s |
| `Settings/SkillSetupView+Introduction.swift` | 248 | 3.30s |
| `Settings/SkillSetupView+Steps.swift` | 258 | 3.30s |
| `Settings/SupportHealthCheckRow.swift` | 52 | 3.34s |
| `Settings/SupportHealthChecks.swift` | 34 | 3.30s |
| `Settings/SupportReportsCard.swift` | 244 | 3.31s |
| `Settings/SystemPermissionRevoker.swift` | 42 | 3.36s |
| `SortyEnergyScanIcon.swift` | 240 | 3.38s |
| `SortyUsageDataEraser.swift` | 139 | 3.31s |
| `StorageLocationsView.swift` | 357 | 3.24s |
| `UnavailableDuplicateFilesPopover.swift` | 176 | 3.23s |
| `UnifiedDuplicateGroupDetailView.swift` | 307 | 3.22s |
| `UnifiedDuplicateGroupRow.swift` | 205 | 3.26s |
| `UnifiedFileDetailRow.swift` | 250 | 3.25s |
| `WatchedFolderActivityLabel.swift` | 113 | 3.28s |
| `WatchedFolderCard.swift` | 688 | 3.35s |
| `WatchedFolderConfigView.swift` | 747 | 3.29s |
| `WatchedFolderNerdStats.swift` | 183 | 3.28s |
| `WatchedFolderRecentActions.swift` | 229 | 3.27s |
| `TimelineView.swift` | 484 | 3.88s |
| `PersonaPickerView.swift` | 858 | 3.53s |

## Repeated samples and leaf targets

| File | First after split | Repeat |
| --- | ---: | ---: |
| OnboardingView | 6.81s | 7.62s |
| ReadyToOrganizeView | 4.94s | 3.28s |
| AddExclusionRuleView+Editing | 4.68s | 3.36s |
| LearningsView+Dashboard | 4.62s | 3.28s |
| LearningsView+Records | 4.53s | 3.38s |

The slower samples included relinking. These samples do not isolate linker time from frontend time. A final Help-command extraction measured 5.43s and 8.29s; reverting it returned AppCommands to 3.31s. The final table uses that restored result.

| Leaf target file | Before | After |
| --- | ---: | ---: |
| SortyOrganizer/FolderOrganizer.swift | 6.09s | 0.79s |
| SortyOrganizer/FolderOrganizer+Run.swift | No separate file | 0.77s |
| SortyLearnings/LearningsManager.swift | 1.94s | 1.92s |

## Findings and limits

The 2s SortyLib rebuild target was not reached. The original 19 SwiftUI files had a cross-file median of 3.48s before and about 3.3s after. This is a median across files, not repeated trials of one edit. The 117 successor/refactored files in the main pass had a median of 3.30s and a range of 3.20–4.68s. TimelineView and PersonaPickerView were measured separately after that pass.

The preview tree improved from 6.08s to 3.19s, permission settings from 5.19s to 3.23s, and skill setup from 4.56s to 3.21s. Several files originally near 3s became slightly slower. Onboarding remained a clear regression against the supplied baseline. Do not describe this effort as a uniform rebuild speedup.

A 64-line preview shell and the 1,822-line extracted AppState both rebuilt in roughly 3.2–3.4s. Each observed changed-file build compiled that file and emitted SortyLib. This suggests shared target overhead, but these logs do not establish how much time module emission itself consumes. Further target-boundary work should start with driver/frontend/linker timing and one-file plus multi-file body-edit measurements.

Additional onboarding experiments moved its preview declaration, support types, navigation, and actions into separate files. Root samples remained inconsistent at 5.91–7.40s. Those uncommitted experiments were reverted because they did not establish a reliable improvement. Their temporary files are absent from the final source and the main tables.

Non-UI leaf files were left alone. ModelSelector.swift and AIConfig.swift were not edited. The protected ModelSelector method remained above the type-checking target in the latest pass that recompiled it, at 476ms.

## Validation

The full diagnostic rebuild used `SORTY_TYPECHECK_DIAGNOSTICS=true` and the same Debug flags in `/tmp/sorty-diag`. The command-menu body remained the largest measured unprotected body at 348ms. Other measured unprotected bodies were at most 287ms. Extracting the Help group shortened the menu body to 167ms but worsened edited-file rebuild measurements, so that extraction was reverted. The roughly 300ms target therefore retains this small overrun plus the protected ModelSelector method. Earlier isolated measurements varied with compile concurrency.

The app compiled. The final source passed `swift build --build-tests` with the same flags and `/tmp/sorty-split-build`, omitting `--product` because SwiftPM makes it mutually exclusive with `--build-tests`. The final restored-source test-target build completed in 7.37s. Tests were not executed, and Blacksmith checks were not run.

During the validation sequence, switching back from the test build to the product build re-emitted SortyApp in 2.65s. The next two unchanged product builds compiled nothing and completed in 0.23s and 0.63s. Those no-op results do not represent edited-file performance.

Static comparisons preserved string literals and accessibility modifier lines in the refactored views, including across the completion split. No interactive UI verification, app packaging, signing, or launch was performed.

## Implementation commits

The parent and earlier implementation commits are included for the complete handoff.

- `70a697c6` Split FolderOrganizer into focused extension files.
- `45af84bf` Split preview rows and shorten provider type checking.
- `0ed0da7d` Separate onboarding compilation and simplify settings expressions.
- `ef915dc1` Split watched-folder and permission views into focused files.
- `225ab25e` Split exclusions, Learnings, and history compilation units.
- `d3af9adc` Separate onboarding effects, skill steps, and duplicate views.
- `66e4f97e` Isolate provider, workflow, and streaming view rebuilds.
- `b5d8061d` Shorten directory, storage, and device auth view expressions.
- `903e0024` Split completion screen presentation and actions for incremental builds.
- `c1211e9f` Bound remaining SwiftUI expression type checking.
- `afb6a1e4` Shorten timeline node and persona grid type checking.
- `8fbc9c91` Separate Help commands to shorten menu type checking, subsequently reverted.
- `9eb0cb3c` Restore inline Help commands after rebuild regression.
