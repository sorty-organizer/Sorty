# Fast development loop

Use `make help` for the complete command list. Minor changes do not require a
local build or launch. Local diagnostics do not replace Blacksmith checks for
merge or release confidence.

| Goal | Command |
| --- | --- |
| Debug build, no tests | `make dev` |
| Debug build and launch, no tests | `make now` |
| Full symbols for LLDB, separate scratch directory | `make debug` |
| Reload Swift implementations in the running Debug app | `make hot` |
| Build and run unit tests | `make build` |
| Local fast-test diagnostics | `make test-fast` |
| Preview harness | `make harness` |
| Accent prototype harness | `make harness-accent` |
| Profile slow expressions in an isolated cache | `make build-profile` |
| Inspect or prune build caches | `make cache-status` / `make cache-prune` |
| Recover a poisoned Clang module cache | `make cache-clear-module` |
| Capture or compare build benchmarks | `make benchmark-save` / `make benchmark-compare` |
| Score the private quality corpus | `make quality-report` |

Build times depend on changed files, toolchain, and cache state. A successful
build does not prove the visible result. See [startup performance](startup-performance.md)
for launch timing and persisted-state requirements.

## App packaging and Finder

The fast loop skips Finder Sync. After extension edits, use
`make now ENABLE_FINDER_EXTENSION=true`. An app without the extension cannot
provide Finder actions. Release packaging includes it.

Keep `PRESERVE_APP_BUNDLE=true` during normal iteration. The build script stages
and signs changed bundles before replacing the app and waits for active file
operations during shutdown. SwiftPM does not replace asset-catalog and Metal
compilation, app-only video/audio staging, signing, or extension packaging.

Build metadata comes from embedded `commit.txt`, with `GIT_COMMIT` available as
a runtime override. If neither is present, Sorty shows `unknown` without running
Git or searching for a source checkout.

## Module boundaries

Follow the target map in [AGENTS.md](../../AGENTS.md). The dependency chain is
`SortyFileSystem -> SortyModels -> SortyAI`, with Learnings, file-system services,
and Organizer in separate targets. Core injects app services; Lib owns views;
App owns lifecycle and window glue. Interface changes can rebuild consumers.

`SortyQuality` depends only on `SortyQualitySupport`. Quality reports do not
compile the app's UI or telemetry dependencies. Preview mocks and harness
activation are Debug-only.

## Hot reload

Run `make hot` from the repository root, keep the process running, and save Swift
files. The vendored InjectionLite runtime recompiles implementation changes and
loads them into that process. Saves during injection coalesce and wait for the
current injection. Quit Sorty or press Control-C to end the session.

SwiftUI bodies, function implementations, and AppKit methods can reload while
preserving app-owned state. Use a normal build after changing stored properties,
signatures, file membership, dependencies, compiler settings, Finder, or widgets.
If a save fails to compile, the app keeps its previous implementation. If saves
are not detected, restart `make hot` to refresh its compile-command cache.

Normal builds do not link or start InjectionLite. Hot builds have their own
cache because their dependencies, flags, and ABI differ. The vendored runtime
also fixes recursive `os_unfair_lock` failures on `InjectionQueue`; restart an
older hot process after updating it.

## Cache recovery and limits

Make shares a normal SwiftPM scratch directory through `SORTY_BUILD_DIR`, the
`.build` symlink, and `SWIFTPM_BUILD_DIR`, with matching indexing settings.
The Debug fast loop and Make test commands retain source-line tables, but omit
full variable/type DWARF and dSYMs. This changes the compiler signature once;
dependencies remain cached. `make debug` keeps full symbols in
`<SORTY_BUILD_DIR>-debugger`, so debugger builds do not invalidate the fast loop.
Make Debug and Release commands use `<SORTY_BUILD_DIR>/ModuleCache` for SDK
modules; the compiler keys incompatible module variants itself. After a successful
build with that path, maintenance removes the old cache for that configuration.
Coverage, profiling, hot reload, and universal Xcode builds use separate settings
or caches. Prefer an isolated scratch path for diagnostics with different flags.

Build-cache maintenance preserves package checkouts and binary artifacts,
invalidates incompatible compiled outputs, repairs incomplete Sparkle artifacts,
and prunes stale logs and resource outputs. Resource keys include content hashes,
shader headers, and compiler recipes. Unchanged video/audio resources stay out of
SwiftPM restaging. Bundle fingerprints read resource metadata in batches and
rehash only changed groups. Metadata changes alone do not trigger packaging when
resource contents still match. Media keys include inode, size, mtime, and ctime
so replacing a file or preserving its mtime cannot hide a content change.
Scheduled maintenance removes indexes when build flags disable indexing and
expires old fingerprint records. Active Debug/current-configuration outputs
and dependencies remain protected, so the size budget is a soft limit. See [build_cache.sh](../../scripts/build_cache.sh) and
[build.sh](../../scripts/build.sh) for the implementation.

| Override | Default |
| --- | --- |
| `BUILD_CACHE_PRUNE_INTERVAL_SECONDS` | `86400` |
| `BUILD_CACHE_MAX_SIZE_MB` | `4096` |
| `BUILD_CACHE_TARGET_SIZE_MB` | `3072` |
| `BUILD_CACHE_STALE_DAYS` | `30` |

After successful local builds, inactive configurations and unused `.xctest`
bundles move into LZFSE-compressed Apple Archives under `.sorty-cache/cold`.
The active configuration, compiler objects, package checkouts, and dependencies
stay expanded. `make now` restores Debug if needed; `make daily` restores Release;
Make test commands restore the test bundle before SwiftPM checks it. Packing and
restoration preserve nanosecond timestamps, permissions, symlinks, and contents.
Archives carry SHA-256 digests and are verified before originals are removed and
before restored files are published. A SwiftPM scratch lock prevents packing
during compilation. A damaged archive stays available for inspection while the
compiler rebuilds missing outputs.

Set `SORTY_COLD_BUILD_CACHE=false` to disable packing and restoration. A bare
`swift build -c release` can rebuild an archived configuration; use `make daily`
to restore it first, or call
`python3 scripts/cold_build_cache.py restore "$SORTY_BUILD_DIR" release`.
Packing runs once per newly built inactive output. It adds compression time to
that build, and profile switching adds extraction time; repeated Debug builds
leave the cold outputs alone. Hosted CI keeps everything expanded.

October's local snapshot fell from 2,723 MB to 1,952 MB. Release outputs compressed
from 730 MiB to 250 MiB, and the test bundle from 206 MiB to 43 MiB. Concurrent
source changes prevent treating those builds as a controlled compile-speed
comparison. Measure cold, warm, and changed-source builds separately.

Use `BUILD_CACHE_PRUNE_INTERVAL_SECONDS=0 make now` to force maintenance, or
`make cache-prune`. Dependency eviction under size pressure is opt-in through
`BUILD_CACHE_PRUNE_DEPENDENCIES_WHEN_OVERSIZED=true`. Prefer pruning to `make clean`.

Foundation errors such as `Bundle.main` or `RunLoop.main` being missing can mean
a poisoned Clang module cache. Another recognized signature is `expected
identifier` with macro `major` in `AvailabilityInternalLegacy.h`, sometimes
reported through PostHog's `PLCrashHostInfo.m`. Scripted builds clear the affected
module cache and retry once serially. Use `make cache-clear-module` for manual
recovery before changing valid source or vendored dependencies.

## Compiler and release diagnostics

Use `make build-profile` for a separate profiling cache, or
`SORTY_TYPECHECK_DIAGNOSTICS=true make dev` for Debug expressions and bodies over
100 ms. The latter changes compiler flags and can trigger recompilation. Split
large SwiftUI expressions into views with explicit inputs when diagnostics
identify a hotspot. Moving code to another file alone does not prove faster builds.

Hosted caches use per-commit keys with compatible toolchain/manifest restore
prefixes. Swift CI and release unit tests share the same cache namespace and
paths; universal Xcode builds retain a separate cache. Restore/save actions keep
the existing cache schema and save completed compiler work after a build attempt, even if compilation,
runtime tests, or later packaging checks fail. The next run always invokes the
compiler to finish incomplete work before executing tests or packaging. Cache hits never skip test execution.
Hosted builds disable local disk-budget pruning and reset only host-specific
maintenance stamps after restoration, preserving compiled products and source
timestamps. Explicit cache saves happen before later release validation and
publication. See the [cache action documentation](https://github.com/actions/cache#using-a-combination-of-restore-and-save-actions).
[ci_source_cache.py](../../scripts/ci_source_cache.py) restores source
timestamps only when contents match, preserving Swift's incremental inputs.
Release retains both architectures, whole-module optimization, and no Thin LTO.
Test discovery builds the bundle; execution uses `--skip-build`. Regular CI
batches whole XCTest classes across workers instead of launching a process for
every test, which is how [SwiftPM's parallel runner works](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/Commands/SwiftTestCommand.swift).
Each batch must execute exactly its discovered count, and any missing tests or
failed batch fails the job. Logs remain under `.build/logs/ci-shard-*.log`.
Release tests stay serial because they share Trash and Keychain services.
Both test workflows use the compact symbol profile and the poison-cache recovery
wrapper. Universal releases retain full dSYMs and optimization settings.

Use the Release workflow's `validate_only=true` on `main` to exercise universal
builds, signing, ZIP packaging, launch, and appcast validation without publication.
See the [release procedure](../../CONTRIBUTING.md#release-process) and
[Sentry package notes](../../Packages/sentry-cocoa/README.md).

September's split-architecture experiment passed validation but took 7m19s,
compared with universal runs of 6m03s and 6m24s. These were different commits,
not a controlled benchmark. Keep the universal workflow until a same-commit
comparison demonstrates a gain. Evidence: [split run](https://github.com/sorty-organizer/Sorty/actions/runs/36244786875),
[universal run](https://github.com/sorty-organizer/Sorty/actions/runs/36241273072),
[restored universal run](https://github.com/sorty-organizer/Sorty/actions/runs/36245314799).

## Error previews and visual acceptance

Submit one of these exact instruction strings after choosing a folder:
`sorty-error-preview://credentials`, `sorty-error-preview://network`,
`sorty-error-preview://permissions`, or `sorty-error-preview://generic`.
They display the existing ErrorView without running organization, contacting a
provider, recording an error, or changing organizer state.

For glass or popover changes, follow AGENTS.md's system-glass helpers and inspect
the visible result on the affected presentation paths. Build success alone is
not visual acceptance. Honor Reduce Motion and keep loading state accurate.
