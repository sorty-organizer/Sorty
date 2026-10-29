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

## Next investigations

These are candidates, not approved deletions or estimated savings:

1. Compare layer pause/resume code in `OnboardingIntroGlow`, `CompletionCelebrationBackdrop`, `CompletionParticles`, and `CompletionHero`. Preserve each animation's lifecycle, timing, and Reduce Motion behavior; consolidate only genuinely identical semantics.
2. Compare cancellation/task cleanup in `FolderOrganizer+Apply`, `FolderOrganizer+PreviewHistory`, `FolderOrganizer+Incremental`, and `FolderOrganizer+Run`. Preserve run-token ownership and cancellation/error transitions. Similar text alone is insufficient evidence for sharing implementation.
3. Review large modules for repeated implementation behind existing interfaces, starting with `LearningsManager`, `ExtensionCommunication`, and `FileSystemManager`. File size alone is not a reason to delete behavior or split files.

For each larger cut, record the removed behavior-free duplication, net size change, affected contracts, and focused validation. Run the applicable Blacksmith checks for substantive batches. Preserve native controls, persistence, undo, file safety, extension packaging, and provider behavior. Any intentional feature removal needs a separate product decision.
