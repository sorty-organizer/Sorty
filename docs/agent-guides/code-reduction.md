# Code reduction

Goal: reduce production code by 20% while preserving behavior. Zero regressions is the acceptance target, not a claim established by a caller search or a passing build.

## Baseline

Starting commit: `6b5a540b66dc2f43a3e308b37d5b7fde713c25a3`. Measured on 2026-10-29 before the first cut:

- Production Swift: 142,441 physical lines across `Sources/**/*.swift`.
- Target: at most 113,952 lines (at least 28,489 net lines removed).
- Count all production Swift, including new helpers. Do not count deleted tests, documentation, blank-line compression, or moving code out of Sources as progress toward the target.
- Keep tests, resources, scripts, and website changes separately accounted for. They have independent behavior and packaging contracts.

Reproduce the production count with:

```sh
find Sources -name '*.swift' -exec wc -l {} +
```

## First cut

Removed four private stored properties with no reads, writes, or bindings anywhere in the repository:

- `AnalysisView.lastMessageTier` and `lastInsightPulseAt`.
- `WatchedFoldersView.selectedFolderForEdit`.
- `LocalRuleInferenceEngine.minConfidenceThreshold`, including its obsolete comment. Rule inference did not use this threshold; this cut does not change the confidence policy.

Net reduction: 6 production lines. Local builds and tests intentionally omitted for this minor change under AGENTS.md. No runtime or zero-regression claim.

Retained `AppState.helpMenuHoverHapticsController`: its initializer installs observers, so absence of direct callers does not make it dead code. Retained `MessageTier`, which still drives the analysis display.

## Finder workflow template consolidation

Replaced four copies of Automator's `document.wflow` XML with one private renderer in `ExtensionCommunication`. The four public install functions retain their shell commands, Info.plist metadata, icon selection, service refresh order, and error handling. Preview keeps its distinct action UUIDs.

- Net reduction: 612 production lines in this batch; 618 since baseline (0.43%).
- Production total: 141,823 lines; 27,871 more lines must be removed to reach the target.
- Executed the original and shared templates in Swift for all four action variants with seven shell-command inputs, including XML metacharacters, empty text, and multiline text. All 28 outputs matched byte-for-byte and parsed as property lists.
- This verifies generated workflow contents, not Finder installation or runtime behavior. [Hosted Swift CI](https://github.com/sorty-organizer/Sorty/actions/runs/40859665068) passed security checks, the app build, and tests.

## Finder service metadata consolidation

The four Quick Action installers now share an Info.plist renderer. Each caller still selects its title, bundle identifier, icon, icon-version metadata, and accepted file types. Watch remains folder-only; Exclude and Preview retain their distinct bundle icon field.

- Net reduction: 91 production lines in this batch; 709 since baseline (0.50%).
- Production total: 141,732 lines; 27,780 more lines must be removed to reach the target.
- Eight executable Swift comparisons covered all four original metadata templates and light/dark watch variants. All generated outputs matched the original UTF-8 bytes and parsed as property lists. The comparison caught and corrected an indentation mismatch before commit.
- An independent source comparison confirmed the installation code outside the metadata extraction was unchanged. Swift parsing and diff checks passed. Finder runtime behavior remains unverified.

## Onboarding notification callbacks

Both screen-panel coordinators now use the existing `NotificationCenter.addMainActorObserver` helper for 19 callbacks. That helper registers on the main operation queue and schedules the supplied block in `Task { @MainActor in ... }`, matching the callbacks it replaces.

- Net reduction: 84 production lines in this batch; 793 since baseline (0.56%).
- Production total: 141,648 lines; 27,696 more lines must be removed to reach the target.
- Compared all 19 registrations in order: notification names, object filters, weak captures, and invoked methods match. All source outside those registrations is identical. Swift parsing and diff checks passed.
- Panel geometry, visibility, animation durations, Reduce Motion handling, observer removal, and dismissal code are unchanged. No new helper or runtime task was introduced. Hosted CI covers integration compilation; panel runtime behavior remains unverified.

## Synthesized model encoders

Removed redundant `encode(to:)` methods from `AIConfig`, `OrganizationPlan`, and `ResponseParser.FileEntry`. Their `Codable` conformances and complete CodingKeys enums remain, so Swift synthesizes their standard keyed encoders. Custom decoding, defaults, migrations, and the FileEntry snake-case wire keys are unchanged.

- Net reduction: 68 production lines in this batch; 861 since baseline (0.60%).
- Production total: 141,580 lines; 27,628 more lines must be removed to reach the target.
- Audited all 59 removed keyed writes against stored properties and CodingKeys: every property is represented once with its existing key; optional values use the same omission behavior as synthesis.
- Retained `AIProvider.encode(to:)` and `SavedSteeringPrompt.encode(to:)`; those are outside this keyed-struct cleanup, and the saved prompt CodingKeys includes a decode-only legacy key.
- No local build or tests for this minor deletion, per AGENTS.md. Hosted integration checks are still required; source equivalence alone does not prove persistence compatibility at runtime.

### Hosted CI follow-up

[The metadata/observer batch](https://github.com/sorty-organizer/Sorty/actions/runs/40860414035) compiled tests and built the app, but failed `DuplicateRestorationManagerTests.testRestoreDuplicate` with `trashedFileNotFound`. Neither that test nor its production owner changed in the batch. Attempt 2 passed the hosted app build and test suite without source changes. The first failure was not reproduced; this does not establish its root cause.

## Organizer run ownership

Six tracked operations now share synchronous run-ownership checks and task cleanup. Each `defer` remains in its original caller, so cleanup still occurs after that caller handles errors and cancellation. No task creation, await, reset, timeout, or error-propagation policy moved into the helpers.

Preview regeneration also reuses the existing `getFilesFromCurrentPlan()` traversal instead of duplicating it. Both reads occur on the main actor before any suspension, so the previously captured plan and the current plan are the same snapshot.

- Net reduction: 63 production lines in this batch; 924 since baseline (0.65%).
- Production total: 141,517 lines; 27,565 more lines must be removed to reach the target.
- Expanded the six cancellation checks and six deferred cleanup calls back to their originals and compared all surrounding source before replacing the preview traversal. They matched exactly. Helpers preserve stale-run suppression clearing and ownership-guarded task clearing.
- Retained the existing cancellation and restart tests, including `testCancelRegenerateReturnsToIdleWithoutError` and `testRegenerateWithModelWhileOrganizingRestartsAnalysis`. Hosted CI must run these against the final commit; caller comparison alone is not runtime evidence.
- Rejected a single generic tracked-task wrapper: these entry points intentionally differ in whether they consume cancellation, preserve suppression, stop timers, and record errors. Clearing the task inside an awaited helper would also move cleanup before the caller's catch block.

## Next investigations

These are candidates, not approved deletions or estimated savings:

1. Compare layer pause/resume code in `OnboardingIntroGlow`, `CompletionCelebrationBackdrop`, `CompletionParticles`, and `CompletionHero`. Preserve each animation's lifecycle, timing, and Reduce Motion behavior; consolidate only genuinely identical semantics.
2. Compare cancellation/task cleanup in `FolderOrganizer+Apply`, `FolderOrganizer+PreviewHistory`, `FolderOrganizer+Incremental`, and `FolderOrganizer+Run`. Preserve run-token ownership and cancellation/error transitions. Similar text alone is insufficient evidence for sharing implementation.
3. Review large modules for repeated implementation behind existing interfaces, starting with `LearningsManager`, `ExtensionCommunication`, and `FileSystemManager`. File size alone is not a reason to delete behavior or split files.

For each larger cut, record the removed behavior-free duplication, net size change, affected contracts, and focused validation. Run the applicable Blacksmith checks for substantive batches. Preserve native controls, persistence, undo, file safety, extension packaging, and provider behavior. Any intentional feature removal needs a separate product decision.

## Indexed dead-code review

Removed an uncalled recursive organizer batching implementation, an unused preview progress snapshot and two unused preview helpers, an unused circular progress view and its private rendering helpers, and an unused model selector row. The active batch request and adaptive retry path, progress controls, circular loader, and model picker remain. Repository-wide caller searches confirmed the removed declarations had no outside callers.

- Net reduction: 314 production lines in this batch; 1,238 since baseline (0.87%).
- Production total: 141,203 lines; 27,251 more lines must be removed to reach the target.
- An isolated Swift package rebuild and 44 existing streaming/preview tests passed. Both existing organizer cancellation tests also passed. These checks do not establish full app or Finder runtime behavior.
- Periphery findings were reviewed rather than applied automatically. Retained framework callbacks, hot-reload properties, lifetime owners, and serialization fields. The index covers SPM; Xcode-only entry points require separate caller review. Hosted integration checks remain required.

## Unused manifest and UI helpers

Removed the unused synchronous batch-manifest wrapper, the unused rename-preview overload that accepted an array, and the unused behind-window SwiftUI modifier and private backdrop view. The organizer still builds batch manifests off-main; the rename preview still uses its cached filename lookup; the fullscreen onboarding panel still owns its AppKit backdrop. Updated comments that referenced the removed helpers.

- Net reduction: 59 production lines; 1,297 since baseline (0.91%). Production total: 141,144 lines; 27,192 remain to reach the target.
- Repository-wide searches and the existing index show no callers for these helpers. No local build or tests for this minor deletion, per AGENTS.md. The preceding substantive deletion batch has 46 passing focused tests and hosted CI queued; these results do not prove runtime behavior for this follow-up.

## Onboarding layer clocks

Four retained onboarding animation views now share `OnboardingLayerClock` for pause/resume state and Core Animation timing updates. Each view still owns its clock. Hero and particle views retain their `isAnimating` pause guard; intro and backdrop views retain their broader pause policy. Visibility, Reduce Motion, animation definitions, and teardown stay in their original owners.

- Net reduction: 42 production lines, including the new helper; 1,339 since baseline (0.94%). Production total: 141,102 lines; 27,150 remain to reach the target.
- Expanded and compared the shared operations with all four original methods: guards, timestamp reads, layer writes, and their order match. A normalized source comparison also confirmed all surrounding code matches after replacing call sites and the pause-state property.
- The helper belongs to the existing SPM onboarding target, which the Xcode app consumes through its local package. No local build or tests for this small extraction under AGENTS.md. Hosted compilation is required; source equivalence does not establish animation appearance or frame timing at runtime.

### Hosted validation status

[The indexed deletion batch](https://github.com/sorty-organizer/Sorty/actions/runs/40863098068) passed security checks, compiled tests, and built the app. Its test run failed `DuplicateRestorationManagerTests.testRestoreDoesNotDependOnSurvivingDuplicate` with `trashedFileNotFound`. Both that test file and `DuplicateRestorationManager.swift` are unchanged from the reduction baseline. The test uses real macOS Trash; restore found the returned Trash path missing. The cause remains unproven, and the test is retained. [The layer-clock batch](https://github.com/sorty-organizer/Sorty/actions/runs/40863467037) passed hosted validation, including the app build and test suite. This successful later run does not establish the earlier Trash failure's cause.

## Provider organization request paths

OpenAI-compatible text and image organization now share prompt construction, request configuration, dispatch, and error reporting. Nil images retain string content and text-only error handling; an empty image dictionary retains multimodal content and image fallback handling. The vision-detail network probe still runs only for image calls. Existing URL/auth validation order, image ordering, request limits, structured-output settings, and OpenRouter fallback policies remain.

Codex text and image calls share response execution, parsing, and statistics. Prompt construction stays in each caller, and temporary images remain owned by the image caller's defer until execution and parsing finish. The shared response body matches both original paths exactly.

- Net reduction: 39 production lines; 1,378 since baseline (0.97%). Production total: 141,063 lines; 27,111 remain to reach the target.
- The final isolated rebuild and all 40 existing request-format and persona/provider tests passed. They cover captured text/image payloads, vision detail, OpenCode formats and headers, OpenRouter streaming and retry behavior, and Codex argument generation. Hosted integration validation remains required. These checks do not establish live provider behavior or a real Codex subprocess round trip.

## Quick Action installation sequence

The four Quick Action installers now share directory preparation, metadata and workflow writes, icon application, service refresh, and installation error handling. Each caller retains its workflow name, shell command, metadata, and success message. Exclude still removes its legacy workflow before replacing the current one; Watch still clears legacy service entries after icon installation; Preview retains its separate workflow identifiers. The metadata autoclosure preserves evaluation after directory creation, including Watch's current icon variant lookup.

- Net reduction: 54 production lines; 1,432 since baseline (1.01%). Production total: 141,009 lines; 27,057 remain to reach the target.
- Specialized the shared helper for all four callers and compared it with the original source. Filesystem operations, metadata expressions, shell literals, icon styles, success/error messages, and refresh ordering match. All surrounding source, including plist renderers and icon generation, also matches. Shell literal relocation performs no shell execution.
- The isolated package rebuild and all 24 existing Finder integration status tests passed. Those tests cover diagnostics and registration status, not installation. Actual workflow installation, Finder menu visibility, and runtime execution remain unverified; hosted integration checks are required.
