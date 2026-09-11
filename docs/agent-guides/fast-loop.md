# Fast Development Loop Guide

Optimized workflows for rapid iteration on Sorty.

## Quick Reference

| Goal | Command | Typical Time |
|------|---------|-------------|
| Build + launch (no tests) | `make now` | ~3-5s no-op; changed files vary |
| Build only (no tests) | `make dev` | ~3-5s no-op; changed files vary |
| Hot reload running Debug app | `make hot` | One changed Swift file |
| Local diagnostic build + tests | `make build` | test-suite dependent |
| Harness mode (targeted view) | `make harness` | ~3-5s no-op |
| Profile slow expressions | `make build-profile` | ~90s clean diagnostic build |
| Inspect build cache | `make cache-status` | <1s |
| Force cache pruning | `make cache-prune` | varies |
| Benchmark all builds | `make benchmark` | ~5-10min |

## Hot reload

Sorty vendors the InjectionLite runtime at InjectionNext 2.0.1's exact
submodule revision, with protection against saves arriving during injection.
The Debug app watches the project, recompiles a saved Swift
file, loads it, and redraws observing SwiftUI views in the same process. There
is no companion application or Xcode session.

### Start the workflow

1. Run `make hot` from the repository root.
2. Keep that Sorty process running.
3. Save Swift files from Codex or another editor.

The first run builds the vendored runtime and downloads its dependencies. Later
starts reuse a dedicated hot-reload SwiftPM cache, separate from normal builds because the two
modes have different dependencies, compiler flags, and ABI. Startup reports
four stages: preparing the runtime, recording
compile commands, relinking the app, and starting the source watcher. It exports
Swift's private default-argument helpers and writes InjectionLite's compile-command
cache along the way. Hot and normal builds do not reuse compiled products.

`make hot` stays attached to the running app so watcher activity, compiler
errors, link results, and load results remain visible in that terminal. Quit
Sorty or press Control-C to stop the session.

Saves received during an injection wait until that injection finishes. Repeated
saves of a pending file coalesce into one pass using its latest contents.

### What reloads

- SwiftUI body and function implementation changes reload in place.
- Current navigation, window sessions, selected folders, and other app-owned
  observable state stay alive because the process does not restart.
- AppKit method changes take effect the next time that method runs.

A normal build is still required after adding, removing, or reordering stored
properties; changing function signatures; adding, renaming, or deleting source
files; changing packages or build settings; or editing the Finder Sync extension
or widget targets.

### Troubleshooting

- The recursive `os_unfair_lock` crash on `InjectionQueue`, reported by make as
  `[hot] Error 9`, is addressed by the vendored save queue. Quit any older hot
  process and start `make hot` again to build and load the fix.
- If no save is detected, quit Sorty and run `make hot` again from the repository
  root so the compile-command cache is refreshed.
- If a save reports a compile error, fix or revert that file. The running app
  continues using its previous implementation.
- If a structural change does not load, quit the hot session, run `make now`,
  then start a fresh `make hot` session.
- Finder extension and widget edits still use their normal target builds because
  they run in separate processes.
- Normal `make now`, Xcode Debug, and Release app builds neither link nor start
  InjectionLite. Only `make hot` opts the Sorty app into the runtime.

## Harness Mode

The preview harness launches the app with minimal dependency initialization, targeting a specific view for rapid visual feedback.

## Mid-generation error previews

To inspect an error screen without producing a real failure, select a folder, enter one of these exact phrases in the Instructions box, and submit normally:

- `sorty-error-preview://credentials`
- `sorty-error-preview://network`
- `sorty-error-preview://permissions`
- `sorty-error-preview://generic`

These routes only replace the workflow content with the existing `ErrorView`. They do not start analysis, contact the configured provider, record an error, or transition `FolderOrganizer` into its error state.

### Usage

```bash
# Launch harness (default view)
make harness
```

### How It Works

- Sets `SORTY_HARNESS_MODE=1` environment variable
- `FeatureFlags.harnessMode` gates heavy startup (folder watchers, AI prewarm, notification setup)
- Skips tests automatically for maximum speed

## Build Speed Optimizations

These are already configured — no action needed:

- **Index store disabled** for local SwiftPM debug builds (`Makefile`)
- **Parallel compilation** using all CPU cores (`-j $(CORES)`)
- **Batch mode** for debug builds (SPM manages incremental compilation internally)
- **Test target** depends only on `SortyLib` (not the executable target)
- **Concurrency checking** set to `minimal` to reduce type-check overhead
- **FinderSync extension cached** — only rebuilds when source files change (~33s saved on incremental builds)
- **Expensive SwiftUI expressions split into dedicated view types** so the compiler solves smaller generic graphs.
- **Compatibility fingerprints** reset compiled outputs only when the Swift/Xcode toolchain changes. SwiftPM and Xcode handle package, project, plist, entitlement, and script changes incrementally.
- **Content-addressed asset catalog cache** reuses `Assets.car` when the catalog, SDK, and `actool` are unchanged.
- **Scheduled cache pruning**: oversized build caches are pruned at most once per day by default, including `make now`, instead of growing unchecked or doing expensive cleanup every run.

## Cache Hygiene

The scripted build path uses `scripts/build_cache.sh` before compiling:

- Clears compiled outputs only when the Swift/Xcode toolchain is incompatible.
- Preserves package checkouts and binary artifacts by default; incomplete Sparkle artifacts are still detected and repaired.
- Prunes stale logs, asset-catalog entries, inactive configurations, and inactive Finder/Xcode outputs before considering opt-in dependency removal.
- Keeps pruning cheap for the fast loop by using `BUILD_CACHE_PRUNE_INTERVAL_SECONDS=86400` by default.
- Uses `BUILD_CACHE_MAX_SIZE_MB=8192`, `BUILD_CACHE_TARGET_SIZE_MB=6144`, and `BUILD_CACHE_STALE_DAYS=30` unless overridden.

Useful commands:

```bash
make cache-status
make cache-prune
```

Useful overrides:

```bash
BUILD_CACHE_PRUNE_INTERVAL_SECONDS=0 make now
BUILD_CACHE_MAX_SIZE_MB=4096 BUILD_CACHE_TARGET_SIZE_MB=3072 make cache-prune
BUILD_CACHE_PRUNE_DEPENDENCIES_WHEN_OVERSIZED=true make cache-prune
```

### Type-Checker Performance

Large SwiftUI result-builder expressions and modifier chains can dominate type checking. Extract semantically distinct sections into small dedicated `View` types with explicit inputs. In particular, move arithmetic and animation chains out of `ForEach` closures into a row view instead of merely moving the same expression into another computed `some View` property.

## Benchmarking

```bash
# Capture a baseline before making changes
make benchmark-save

# After changes, compare against baseline
make benchmark-compare

# Raw benchmark (outputs to .build/benchmark-results.json)
make benchmark
```

The benchmark script measures:
1. Clean debug build
2. Incremental build (single file touch)
3. Full test build + run
4. Release build

## Profiling Slow Files

```bash
make build-profile
```

This runs an isolated clean build with Swift frontend debug-time diagnostics, deduplicates batched compiler entries, prints the slowest project function bodies and expressions, then removes the temporary build and diagnostic log. It never invalidates the normal development cache.

## Future: Modularization

SortyLib is a monolithic target (more than 220 Swift files). Splitting stable non-UI layers into smaller targets would reduce the invalidation surface and allow more target-level parallelism, but target boundaries should follow dependency analysis rather than file count alone:

- **SortyCore** — Models/, Utilities/, Services/
- **SortyAI** — AI/ (depends on SortyCore)
- **SortyOrganizer** — Organizer/, FileSystem/, Learnings/ (depends on SortyCore, SortyAI)
- **SortyUI** — Views/, ViewModels/, DesignSystem/, Managers/ (depends on all above)

## Tips

- **Use `make now` as your default** — it's the fastest path to a running app
- **Touch only what you're editing** — incremental builds only recompile changed files
- **Prefer `make cache-prune` before `make clean`** when the cache is too large or stale
- **Use `make test-fast`** for a local unit-test diagnostic pass; Blacksmith remains the merge/release gate
- **Close Xcode** when using SPM builds — Xcode's indexer competes for resources
- **For liquid glass changes, do a visual check** — compile/test success is not enough. Compare against `AboutView` if the goal is “system liquid glass”, because native `.popover` or `.sheet` chrome can look wrong even when `glassEffect` compiles.

### Liquid Glass Regression Guard

Before merging any dropdown/popover changes that should be "system liquid glass":
- Verify no custom material was introduced in that path (`.regularMaterial`, `.thinMaterial`, `.ultraThinMaterial`).
- Verify the implementation uses system presentation and `glassEffect` where available.
- If `glassEffect` is unavailable on the target OS, keep default system presentation (no custom material simulation).
- Do a runtime visual check; build success alone is not sufficient.
