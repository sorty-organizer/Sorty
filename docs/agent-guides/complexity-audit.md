# Complexity audit decisions

The 1 October 2026 repo-wide ponytail audit is a list of candidates, not proof
that each replacement preserves behavior. Line counts alone do not justify
removing a feature or a safety check.

## Implemented

- Remove the repo-local SwiftData and UIKit auditor skills. Sorty persists to
  files and defaults and uses SwiftUI and AppKit.
- Remove the generic design-principles and design-philosophy skills. Keep
  `swiftui-pro`, UI patterns, and view refactoring for code guidance, with
  AGENTS.md defining Sorty's design constraints.
- Remove the animation-generation skill. Keep its earlier audit as historical
  context, with a notice that its proposals are not an implementation checklist.
- Remove the corresponding entries from `skills-lock.json`.
- Remove BuildInfo's runtime Git subprocess and repository search. Packaged
  builds use `commit.txt`; other launches can supply `GIT_COMMIT` or show
  `unknown`. Short hashes use `prefix(9)`.
- Share the identical Package.swift compiler and linker settings. Keep the
  library-specific concurrency and warning flags, plus the hot-reload and
  diagnostic opt-ins.
- Use one helper for default-enabled flags while honoring persisted `false`
  values, including the legacy Finder preference.
- Replace the workflow transition if-chain with a tuple switch. Preserve
  cancellation, error, retry, incremental apply, and apply re-entry rejection.
- Condense the fast-loop guide into a command table and operational notes.
  Keep cache recovery, hot-reload limits, signing, release evidence, and visual
  acceptance guidance. Correct its outdated module map.

The skill cleanup had no app build or UI verification, as required for minor
changes by AGENTS.md. For the workflow refactor, an isolated Swift 6 executable
compared all 64 source/destination pairs against the original implementation,
including two distinct errors. Every comparison passed. The evaluated package
graph and flags matched the original manifest in normal, diagnostics, hot, and
combined hot/diagnostics modes. Existing workflow regression tests remain.
No full app build, test suite, hosted CI, or live UI acceptance is claimed.

## Follow-up caller audit, 1 October 2026

The follow-up scanned app and test declarations, website dependencies, build
scripts, and package boundaries. Each deletion below followed a tracked-tree
caller search and inspection of the active path. A missing textual reference
alone does not justify deleting framework callbacks, previews, manual tools,
or a protocol implementation.

Implemented UI cuts:

- Delete `OnboardingProgressRow`, `StepCard`, `applyIdentifier`, the unused
  duplicates directory selector, and the unused Shortcuts launcher. None has
  an app or test caller. The active duplicates empty state still opens the
  directory picker.
- Delete the preview's local rename fallback and old file-icon switch. The
  active row still regenerates names through `AIClientProtocol` and uses the
  existing row presentation for icons.
- Delete `DragDropManager`'s unused target state and validity cache, its unused
  setters, and the store reference and invalidation calls that only served
  that cache. Drop delegates still validate and perform drops, track hover
  locally, and clear the shared `draggedFile` after a drop.

Implemented catalog and AI cuts:

- Delete `ModelCatalog.searchAllProviders`, `performDebouncedSearch`, their
  task and published result state, and the unused synchronous decoder wrapper.
  `ModelSelector` owns the active search and debounce. Catalog fetching still
  decodes through the existing off-main implementation.
- Delete `sseDataPayload`, `prepareVisionBatch`, and `clearVisionBatch`. No app
  or test calls them. Streaming still uses `SSEDataBuffer`; vision preparation
  still uses the injected organizer service and `ImageVisionAnalyzer`.
- Delete `SparkleUpdateFeed`. Its constant has no callers; the updater's feed
  remains configured by the packaged `SUFeedURL`.

These batches remove 357 production lines and no dependencies. Keep website
`clsx` and `tailwind-merge`, which serve the shared `cn` helper, and `shadcn`,
whose stylesheet is imported by `globals.css`. No dependency removal was
established by this caller audit. Existing public callbacks, launch hydration,
provider credential paths, and the earlier Keep decisions remain untouched.

No tests were removed. No local build, test run, computer use, or hosted CI was
run for these minor dead-code cuts, following AGENTS.md. Live UI and
accessibility behavior remain unverified. Line counts measure source reduction,
not build or runtime performance.

## Keep

| Candidate | Reason |
| --- | --- |
| Xcode file lists | The project builds app, Finder, and widget targets and compiles asset catalogs. SPM is not a drop-in replacement for that packaging. |
| Build scripts and Makefile commands | Bundle assembly, signing, safe shutdown, resource compilation, and separate hot/coverage caches are outside SPM's incremental compiler. |
| Hot reload | Already gated by `SORTY_HOT_RELOAD` and `make hot`. |
| Quality support | Independent of the app graph; removing it from tests would remove the corpus evaluator's test dependency. |
| Next.js and PostHog skills | The repo includes a Next.js website and the app uses PostHog. |
| SwiftUI and AppKit accessibility guidance | Both frameworks have production callers. Keep the shared accessibility skill too. |
| CostCalculator pricing | Replacing every model's estimate with a baseline changes displayed costs, including local models. |
| Path validators and canonicalization | File URLs, tilde expansion, relative paths, symlinks, and trust-boundary rejection have distinct contracts. |
| Keychain caches and provider auth APIs | NSCache does not replace locking or negative-cache expiry. Sync and async auth paths have different callers. |
| Telemetry and keychain adapters | They preserve the documented leaf-target dependencies. Calling Core directly would reverse those dependencies. |
| State, hashing, and progress locks | Cancellation and cross-task mutations require synchronization. A single caller does not make a lock redundant. |
| Resource fallback lookup | Xcode and packaged SwiftPM apps place resources differently. |
| UserDefaultsDataReader | Read-only background-loading boundary required by the startup guide. |
| UI, onboarding audio, credits, and vendored visuals | Replacements proposed in the audit change behavior or appearance. They need a specific product decision and appropriate runtime evidence. |
| Test matrices | Unicode, learning scores, parsing, resources, and persistence are app contracts. Retain unless a stronger test demonstrably covers the same risk. |
| One-type files and re-exports | Merging files or adding imports at every caller does not by itself remove runtime complexity. |
| Sparkle key and version scripts | Manual tools need no source callers. Version bumping has an active release caller. |

The proposed 16,323-line and five-dependency reductions remain unverified.
No build-speed or runtime-performance improvement is claimed.
