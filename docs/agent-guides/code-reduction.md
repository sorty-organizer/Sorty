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
- This verifies generated workflow contents, not Finder installation or runtime behavior. [Hosted Swift CI](https://github.com/sorty-organizer/Sorty/actions/runs/40859665068) passed security checks, the app build, tests, and pre-release validation.

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

## Next investigations

These are candidates, not approved deletions or estimated savings:

1. Compare layer pause/resume code in `OnboardingIntroGlow`, `CompletionCelebrationBackdrop`, `CompletionParticles`, and `CompletionHero`. Preserve each animation's lifecycle, timing, and Reduce Motion behavior; consolidate only genuinely identical semantics.
2. Compare cancellation/task cleanup in `FolderOrganizer+Apply`, `FolderOrganizer+PreviewHistory`, `FolderOrganizer+Incremental`, and `FolderOrganizer+Run`. Preserve run-token ownership and cancellation/error transitions. Similar text alone is insufficient evidence for sharing implementation.
3. Review large modules for repeated implementation behind existing interfaces, starting with `LearningsManager`, `ExtensionCommunication`, and `FileSystemManager`. File size alone is not a reason to delete behavior or split files.

For each larger cut, record the removed behavior-free duplication, net size change, affected contracts, and focused validation. Run the applicable Blacksmith checks for substantive batches. Preserve native controls, persistence, undo, file safety, extension packaging, and provider behavior. Any intentional feature removal needs a separate product decision.
