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

## Finder extension in the fast loop

`make now`, `make dev`, `make daily`, `make hot`, and preview harnesses skip
Finder Sync by default. Use `make now ENABLE_FINDER_EXTENSION=true` after
editing the extension or when testing Finder integration. An app built without
the extension does not provide Finder actions. Release builds still include it.

Keep `PRESERVE_APP_BUNDLE=true` and avoid `make clean` during normal iteration.
Unchanged signed bundles are reused; changed bundles are staged and signed
before replacing the published app. Safe shutdown still waits for active file
operations rather than interrupting them for a faster build.

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
- **One normal SwiftPM cache** for `make now`, `make build`, `make test`, and local CI diagnostics, with matching indexing flags. Local CI honors `SORTY_BUILD_DIR` instead of creating a second cache in `.build`. Coverage, profiling, and hot reload still have distinct compiler settings and may require compilation.
- **Parallel compilation** using all CPU cores (`-j $(CORES)`)
- **Batch mode** for debug builds (SPM manages incremental compilation internally)
- **Test target** depends on `SortyLib` and the independent `SortyQualitySupport` library
- **Concurrency checking** set to `minimal` to reduce type-check overhead
- **FinderSync is opt-in for the fast loop** with `ENABLE_FINDER_EXTENSION=true`
- **Expensive SwiftUI expressions split into dedicated view types** so the compiler solves smaller generic graphs.
- **Compatibility fingerprints** reset compiled outputs only when the Swift/Xcode toolchain changes. SwiftPM and Xcode handle package, project, plist, entitlement, and script changes incrementally.
- **Batched fingerprint hashing** starts one hashing process per group of inputs instead of one per file. Content changes still invalidate the cache even when file size and modification time are unchanged.
- **Sentry downloads only the linked variant** through `Packages/sentry-cocoa`. It uses the same upstream 9.23.0 binary, checksum, and linker helper. The six unused binary variants no longer consume cache space or download time. SwiftPM removes them when resolving the changed package graph.
- **Content-addressed resource caches** reuse `Assets.car` and Beam `default.metallib` when their inputs and toolchains are unchanged. Metal keys include shader headers and the build recipe.
- **Scheduled cache pruning**: oversized build caches are pruned at most once per day by default, including `make now`, instead of growing unchecked or doing expensive cleanup every run.

## Cache Hygiene

The scripted build path uses `scripts/build_cache.sh` before compiling:

- Clears compiled outputs only when the Swift/Xcode toolchain is incompatible.
- Preserves package checkouts and binary artifacts by default; incomplete Sparkle artifacts are still detected and repaired.
- Prunes stale logs, asset-catalog and Metal entries, inactive configurations, and inactive Finder/Xcode outputs before considering opt-in dependency removal.
- Under size pressure, evicts older resource outputs while preserving the most recently used entry for each compiler. Cache hits refresh their age.
- Measures the full cache once before eviction, then measures only each eviction candidate. A final full measurement reports actual disk usage.
- Keeps pruning cheap for the fast loop by using `BUILD_CACHE_PRUNE_INTERVAL_SECONDS=86400` by default.
- Uses `BUILD_CACHE_MAX_SIZE_MB=8192`, `BUILD_CACHE_TARGET_SIZE_MB=6144`, and `BUILD_CACHE_STALE_DAYS=30` unless overridden.

CI disables SwiftPM indexing and allows the standard dependency download cache. Local builds keep the shared `SORTY_BUILD_DIR` scratch directory and also allow dependency download reuse. Archives retain compiled products, package checkouts, and binary artifacts, but exclude indexes and logs. CI and release unit tests share a toolchain-specific cache; universal Xcode builds use a separate cache without falling back to SwiftPM test outputs. Editor builds in Xcode keep their own indexing settings.

Each successful commit saves a fresh build cache. Restore first prefers the same
toolchain and package manifests, then the most recent build for that toolchain
and build family. The commit suffix matters because GitHub caches are immutable;
a manifest-only key keeps restoring the first build indefinitely.

`scripts/ci_source_cache.py` stores tracked-file hashes and timestamps alongside
the compiled outputs. After checkout and cache restore, it restores timestamps
only for files with identical contents. Changed and new files retain their fresh
timestamps, so the compiler rebuilds them. Missing or invalid snapshots fall back
to normal builds. This avoids invalidating every source solely because checkout
gave it a new timestamp.

Use the Release workflow's `validate_only=true` input on `main` to exercise the
universal build, signed ZIP, launch smoke test, and appcast validation without
publishing a release. This also populates the release cache on the default
branch. GitHub lets tag runs restore default-branch caches, but a new tag cannot
restore a cache saved only under a different tag. See the
[release procedure](../../CONTRIBUTING.md#release-process).

The release jobs transfer the packaged ZIP once and extract it for validation.
They do not upload a second copy of the unpacked app, and artifact compression
is disabled because the ZIP is already compressed.

See [GitHub's cache access rules](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache),
[artifact compression guidance](https://github.com/actions/upload-artifact#altering-compressions-level-speed-v-size),
and the [Sentry package update procedure](../../Packages/sentry-cocoa/README.md).

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

## Module boundaries and compile hotspots

`SortyQualitySupport` contains the corpus models and evaluator. `SortyQuality`
depends only on that library, so running a quality report does not compile
`SortyLib` or its UI and telemetry dependencies. The app does not depend on the
corpus library. Preview mocks and harness activation are Debug-only.

The large screen files separate existing views into files for setup, saved
prompts, errors, history details, streaming, progress, and insights. Supporting
organization models, learning exclusion monitoring, and duplicate restoration
also have their own files. The rename stream list has a separate view body and
an explicitly typed enumerated collection to limit type inference.

File extraction alone does not prove faster builds. Swift already tracks
intra-module dependencies. A future Core/AI/Organizer/UI split needs an acyclic
dependency graph and measurements of changed-file rebuilds before adopting it.
Keep manager state and cancellation logic together until a measured hotspot
justifies changing those boundaries.

## CI and release choices

- Compilation jobs in Swift CI and Release use Xcode 26.3. Update both
  workflows together after validating a newer toolchain. The packaging job uses
  the runner toolchain for its small Swift validation scripts.
- Test discovery compiles the test bundle; execution uses `--skip-build`.
  Swift CI separately assembles the app to exercise packaging. Release has one
  universal app build plus a Debug test build with different compiler settings.
- Release tests remain serial because they use shared Trash and
  Keychain services. Sharding requires an audited isolation list first.
- Reuse a successful release test run with `reuse_test_run` when the existing
  source comparison permits it. Do not reuse tests across product changes.
- Sentry receives its symbols in a separate Ubuntu job after publication.
  Failure remains visible in the workflow and can be retried without building
  the app again. `validate_only` skips this upload.
- Publishing remains serialized because releases update the shared Sparkle
  feed. The publisher still runs on macOS for Sparkle's signing tool, signature
  validation, and launch testing. Published asset verification remains enabled.
- Release triggers are version tags and manual dispatches. GitHub does not
  evaluate path filters for tag pushes, so adding them would not save work.

See [Swift's incremental compilation model](https://github.com/swiftlang/swift/blob/main/docs/Driver.md),
[GitHub cache reuse](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching),
and [tag and path filter rules](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onpushpull_requestpull_request_targetpathspaths-ignore).

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

- Release disables Thin LTO while retaining whole-module Swift optimization
  and both arm64 and x86_64. This removes an optimization pass, but its effect
  on build duration, app size, and runtime has not yet been measured.
- Architecture builds stay together. Combining separate builds would require
  merging and validating every nested Mach-O binary and its matching symbols,
  then signing the assembled app. A `lipo` of only the main executable is not
  sufficient.

We tried parallel arm64 and x86_64 runners in September 2026. The
[publish-free split run](https://github.com/sorty-organizer/Sorty/actions/runs/36244786875)
passed signing, launch, appcast, and symbol checks, but took 7m19s end to end.
Both architecture caches restored; their xcodebuild steps took 198s and 231s.
The earlier [universal run](https://github.com/sorty-organizer/Sorty/actions/runs/36241273072)
took 6m03s end to end, with 213s in xcodebuild. After restoring that workflow,
another [publish-free run](https://github.com/sorty-organizer/Sorty/actions/runs/36245314799)
passed in 6m24s. These runs used different commits, so this is not a controlled
compiler benchmark. They do not support the projected two-minute release.
Keep the universal workflow until a same-commit comparison shows a useful
wall-clock gain.

To see warnings for Debug expressions and function bodies taking over 100 ms:

```bash
SORTY_TYPECHECK_DIAGNOSTICS=true make dev
```

This opts both app targets into compiler diagnostics and removes SortyLib's
warning suppression for that invocation. Normal builds stay quiet. Changing
compiler flags can rebuild targets, so use `make build-profile` for a separate
profiling cache.

Do not infer a release speedup from an exact-key cache miss. Inspect the restore
step, build step, and cache save separately. Keep per-commit keys with compatible
restore prefixes, and run publish-free validation on `main` before a release to
make warm universal outputs available to the tag. Directory timestamps alone
cannot detect edits to existing resources; bundle reuse retains content hashes,
including Beam shader headers and the bundled Sorty skill.

## Validation on 26 September 2026

Commit `c0e58011` passed [Swift CI](https://github.com/sorty-organizer/Sorty/actions/runs/36241274880)
and [publish-free Release validation](https://github.com/sorty-organizer/Sorty/actions/runs/36241273072)
on Blacksmith. The release run exercised both architectures, 1,126 tests with
one skipped, signed ZIP packaging, app launch, Sparkle validation, and symbol
archive transfer. It did not publish a GitHub release or Sentry release.

The local Debug build assembled and signed successfully. One unchanged
`make dev` invocation reported 2 seconds and reused the signed app. A preceding
source rebuild reused both the asset and Metal caches. These are individual
observations, not a controlled before-and-after benchmark or a promise that
source edits build in 2 seconds. The release cache restored through its existing
compatible prefix; no manifest-only cache key was needed.
