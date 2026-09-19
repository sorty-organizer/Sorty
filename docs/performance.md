# Sorty Performance: v1.2.0 → HEAD benchmark

A/B benchmark of the post-1.2.0 performance program against the last release.
Baseline `v1.2.0` = `9e3de29a` (2026-07-11). HEAD = `cc47c6f6` (2026-09-14).
Delta: 1,316 commits, 733 files changed, 125 `perf/*` commits.

Measured 2026-09-19 on arm64 (8 cores, Swift 6.3.3) using clean detached
worktrees for both revisions. All claims below come from these runs, not from
commit messages. Component guides with prior microbenchmarks:
`docs/agent-guides/startup-performance.md`, `docs/agent-guides/rendering-performance.md`.

## Headline results

| Metric | v1.2.0 | HEAD | Delta |
|---|---|---|---|
| Launch to first window, median of 5 (Release, same machine/data) | 2299 ms | 854 ms | ~63% faster |
| Idle CPU, visible window, 60 s `ps` sampling | ~50% (46–50% across 2 runs) | 0.0% settled | ~50 pts eliminated |
| Idle CPU, minimized window | ~55% | 0.0% | timers now pause when hidden |
| Idle CPU with animated HUD on screen | — | ~16% | still ~3× below v1.2.0 plain idle |
| Test throughput, 5 perf-area suites (warm) | 64 tests / 20.0 s | 103 tests / 22.5 s | ~30% less per test, 61% more coverage |

## 1. Launch (Release .app, adhoc-signed, `make daily` equivalent)

Both apps built with identical env (`BUILD_CONFIG=release`,
`ENABLE_ADHOC_SIGNING=true`, `SKIP_TESTS=true`, no hot reload) into separate
scratch dirs. Timing: spawn `Contents/MacOS/Sorty`, poll for first window via
System Events every 50 ms, 5 runs each, kill between runs.

- v1.2.0 (`releases/Sorty.app`, 42 MB, 165 s build): 7137 / 7768 / 1980 / 2299 / 1571 ms
- HEAD (47 MB, 288 s build): 3683 / 998 / 751 / 782 / 854 ms
- Ranges do not overlap even excluding first (cold) runs.

Startup mechanism (verified by grep at both revisions): v1.2.0 decodes stores
synchronously in `init` (e.g. `Sources/SortyLib/Models/WatchedFolder.swift:82`)
with zero `loadPersistedState` call sites and a sync
`configureGlobalsIfNeeded`. HEAD has 22 `loadPersistedState` sites across 12
files; `Sources/SortyApp/SortyApp.swift:963` fans them out as parallel async
loads, and the manual window no longer gates on history/Learnings/storage
hydration. Caveat: v1.2.0 ran first (colder caches), which flatters HEAD by an
unquantified fraction — not by 3×.

## 2. Idle CPU and memory (`ps %cpu,rss`, 12 samples over 60 s)

| Run | v1.2.0 visible | v1.2.0 minimized | HEAD visible | HEAD minimized |
|---|---|---|---|---|
| 1 (+30 s settle) | 50.4%, 105 MB | 54.9%, 50 MB | 0.0%, 155 MB | 0.0%, 138 MB |
| 2 recheck (+20 s settle, visible) | 46.4%, 143 MB | — | 16.5%, 150 MB | — |

v1.2.0's ~50% reproduces across runs and persists while minimized — the
signature of unpausable render timers, matching the pre-fix code: 60 Hz
`RollingCreditsView.swift:616`, 30 Hz pill/beam `ButtonStyles.swift:574`,
2 s Finder polls `AutomationManager.swift:30`, per-batch `task_info` in
`DirectoryScanner.swift:353`. HEAD's 0.0% run was fully settled; its 16.5%
recheck had the move-suggestion HUD animating
(`SortyMove: showing suggestion HUD`). No log evidence of background work
explaining v1.2.0's burn in either run. RSS is flat or drifting in both; no
memory regression (HEAD holds slightly more cache while burning ~zero CPU).

Timer/Hz deltas confirmed by grep at both revisions: Finder poll 2 s → 8 s +
30% tolerance (`AutomationManager.swift:32`), credits 60 Hz → 15 Hz with
suspension gate (`RollingCreditsView.swift:627`), pill idle 30 Hz → 10 Hz with
one timeline deleted (`ButtonStyles.swift:416`), `task_info` per-batch →
per-1000 (`DirectoryScanner.swift:838`, up to 100× fewer syscalls), widget
30-min poll → `.never` + event-driven (`SortyWidgets.swift:35`).

## 3. Hot-loop microbenchmarks (same inputs, old vs new shapes)

Standalone ports of the exact diff hot loops, medians:

| Loop | Old | New | Measured |
|---|---|---|---|
| Progress-line parse (`FolderOrganizer.swift:1240`, `37fe3c5a`) | `buffer += chunk; firstIndex` rescan O(B²) | fragment-wise + 16 KB cap | 45% less; drops 100 KB junk line by design, keeps 200/200 normal lines |
| Flight queue (`OrganizingFlightStageView.swift:50`, `37d3bfe5`) | `flatMap`+filter per animation tick O(n) | prebuilt queue + cursor O(1) | ~100% less over 120 frames × 2000 files |
| Duplicate features (`SemanticDuplicateDetector.swift:605`, `6a1e294a`) | re-tokenize per pair O(P²·T) | cache `TextFeatures` once O(P·T) | 86% less, identical groups |
| Stream counting (`FolderOrganizer.swift`, `ea631773`/`a321fc2a`) | per-chunk Swift `String.count` (O(n) grapheme walk) on ~280 KB Unicode | byte counter O(1) | 40.6 s → ~0 s /100 iters |

Related structural wins (code-inspection, same complexity class as above):
`ebbd2a7f` move-destination recompute per access → cached
(`OptimizedPreviewTree.swift:598`); `400615c0` move-match O(R×A) → O(R+A)
dict (`LearningsFSMonitor.swift:396`); `b0b65445` full history plans decoded
at launch → summary scalars + on-demand `Sessions/<uuid>.json`
(`OrganizationHistory.swift:305`); streaming UI walk unbounded → 48 K-char
suffix + 256 KB retention (`FolderOrganizer.swift:653`).

## 4. Test-suite throughput (warm builds, same filter)

Filter `StreamingLogicTests|DuplicateDetectorTests|DirectoryScannerTests|HistoryTests|FolderWatcherTests`,
`swift test --scratch-path <separate> --disable-sandbox --parallel`:

- v1.2.0: 64 tests (StreamingLogic 35, History 9, DirectoryScanner 9,
  Duplicates 7, ReferenceDirectoryScanner 2, FolderWatcher 2), 20.0 s, clean.
- HEAD: 103 tests (StreamingLogic 48, History 16, DirectoryScanner 13,
  DuplicateDetector 10, FolderWatcher 11, ReferenceDirectoryScanner 5),
  22.5 s, clean — 61% more tests in 12%
  more wall time, ~30% less per test (0.313 s → 0.218 s).

Throughput, not a same-code speedup: test bodies differ (new perf-regression
coverage included). Cold full build+test walls are not comparable because the
HEAD cold run could not compile (next section). Both runs' trailing
"0 tests" line is the empty swift-testing runner, not the XCTest result.

## 5. Incidental findings (pre-existing, not perf)

- HEAD cannot `swift test` clean: `SparkleUpdateManager.swift:57`
  `markSkipped(version:displayVersion:)` (and `:50` `contains`) require two
  args, but `SparkleTrafficLightSkipStoreTests.swift:12` calls the 1-arg form
  (source changed in `cc47c6f6`, test last touched in `e9dd5c39`). App
  benchmarks used `SKIP_TESTS=true`; test-timing used a worktree-local patch.
- v1.2.0 full Release `swift test`: 882 tests, 21 failures, all one
  resource-bundling artifact (`ResourceLoadingTests.swift:122`,
  `testWhatsNewTourImagesLoadFromResources` — SPM vs asset-catalog layout).
- Reverted/superseded along the way: `dac02a17` transition scoping undone by
  `3f5445c2`; `0ac2a877` partially regressed (`settingsViewModel` back to env
  object); `0a35e6e9` shared clock superseded by `fc2ad718` gated clocks.

## 6. Not measured

GPU compositor time and battery drain were not separately traced (no root for
`powermetrics`, no Instruments export parsed). The 50%-to-0% idle-CPU delta
sets the energy direction; a controlled drain test would quantify it.
Per-startup-phase attribution (which deferred load buys how many ms) needs
Instruments App Launch + Time Profiler signposts on the signed Release builds,
which are preserved at `sorty-v120`/`sorty-head` worktree outputs.

## Reproducing

```sh
# worktrees (detached, clean)
git worktree add --detach <tmp>/sorty-v120 9e3de29a
git worktree add --detach <tmp>/sorty-head cc47c6f6
# Release apps, identical env (mirrors `make daily` + SKIP_TESTS=true)
(cd <tmp>/sorty-v120 && export FAST_DEV_MODE=true ENABLE_FINDER_EXTENSION=true \
  ENABLE_ADHOC_SIGNING=true ENABLE_SPARKLE_SIGNING=false PRESERVE_APP_BUNDLE=true \
  SKIP_GIT_INJECT=true SORTY_HOT_RELOAD=false APP_ICON_VARIANT=release \
  SKIP_TESTS=true BUILD_CONFIG=release SORTY_VERBOSE=false \
  SORTY_BUILD_DIR=<tmp>/v120-appbuild BUILD_FLAGS="-j 8 --disable-sandbox" \
  && ./scripts/build.sh)
# same for sorty-head; then launch each binary, poll for first Sorty window,
# and sample `ps -o %cpu,rss -p $(pgrep -x Sorty)` while visible/minimized.
```

## 7. Post-spike addendum (2026-09-20): prompt/budget work ported from `spike/jev-vercel-gateway`

After closing the Jev spike, the non-Jev changes were ported to main
(`b793eb4f`). A/B measured with a temporary XCTest probe (same synthetic
deep-scanned folders, `includeContentMetadata: true`, 5 runs, median) on a
clean detached worktree at `f9bfd0b5` (before) vs main HEAD (after).
Probe files were deleted after the runs; only the numbers below remain.

### 7a. Organization-prompt size vs folder size (`PromptBuilder.buildOrganizationPrompt`)

| Files | Before tokens | After tokens | Saving |
|---|---|---|---|
| 50 | 7,545 | 7,545 | 0% — byte-identical output under budget |
| 200 | 27,125 | 11,961 | 56% |
| 350 | 46,786 | 11,961 | 74% |
| 500 | 66,464 | 11,961 | 82% |
| 1000 | 132,059 | 11,961 | 91% |

Before grows ~264 tokens/file with no bound (a 1000-file deep-scanned folder
sends 132k tokens). After caps at the 12k main-path budget with full metadata
for the first 80 files and path-only lines beyond. Prompt build time is flat:
5.0 ms at 1000 files after vs 12.1 ms before. Behavior below the budget is
unchanged (identical chars at 50 files), so normal folders see zero quality
delta; oversized folders now degrade to a flagged partial plan instead of an
unbounded request.

### 7b. Batch manifest (1050-file folder, 3 × 350-file batches)

Full 400-entry manifest measured at 4,562 tokens. Old shape repeats it per
batch: 13,686 tokens. New shape swaps in a 60-entry batch-scoped manifest per
batch: 2,627 tokens total — 81% less (computed from the measured manifest;
the swap code only runs on multi-batch folders).

### 7c. §4 filter re-run on the new HEAD

`StreamingLogicTests|DuplicateDetectorTests|DirectoryScannerTests|HistoryTests|FolderWatcherTests`
(warm cache, execution only): 103 tests, 0 failures in ~3 s. Not comparable to
the §4 22.5 s wall (that included the test-bundle build); execution-only
per-test is ~0.03 s.

### 7d. Behavioral notes (test expectations updated, not regressions)

- `ResponseParserTests.testValidJSONParsing`: unmapped files now mark the plan
  partial with a review hint in notes (`isPartial`/`needsReview`, 1
  `parseWarnings` entry) instead of a silently valid plan. Test asserts the new
  contract.
- `StreamingLogicTests.testInvalidStateTransitions`: `completed → applying`
  (re-apply/undo/redo/restore) and `completed/ready/organizing → scanning`
  are deliberate extensions from the ported workflow commit; the test now
  covers the new table including the `applying → applying` guard.
- §5's "HEAD cannot `swift test` clean" is fixed on main: the stale
  `SparkleTrafficLightSkipStoreTests` 1-arg calls now pass `displayVersion`.
  (The A/B "before" worktree needed the same worktree-local patch — the
  breakage predates the port.)

Launch/idle (§1–2) were not re-measured: the port touches no launch-path or
timer code, so no delta is expected there.
