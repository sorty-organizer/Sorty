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

During scheduled local maintenance, inactive configurations move into
LZFSE-compressed Apple Archives under `.sorty-cache/cold`.
The active configuration, compiler objects, package checkouts, and dependencies
stay expanded. `make now` restores Debug if needed; `make daily` restores Release;
Make test commands restore legacy archived test bundles before SwiftPM checks them. Packing and
restoration preserve nanosecond timestamps, permissions, symlinks, and contents.
Archives carry SHA-256 digests and are verified before originals are removed and
before restored files are published. A SwiftPM scratch lock prevents packing
during compilation. A damaged archive stays available for inspection while the
compiler rebuilds missing outputs.

Scheduled local maintenance also applies transparent LZFSE filesystem compression
to SDK modules, downloaded dependency files, and Debug test bundles with files
of at least 1 MiB. Test bundles remain readable between app builds and tests,
avoiding repeated packing, extraction, or relinking. Files stay at
their original paths and remain directly readable, including through memory
mapping. Compiler objects stay expanded. Compression runs under the SwiftPM
scratch lock, verifies SHA-256, permissions, timestamps, and metadata before
replacing anything, and preserves all platform slices and vendor signatures.
The compression flag changes deliberately; macOS also assigns copied files its
current process provenance. Other extended attributes are checked individually.
Already-compressed and hard-linked files are skipped. A failed verification
leaves the affected originals intact. CI skips this operation.

On October 3, SDK modules and dependency artifacts fell from 784 MiB to 360 MiB,
about 54% less allocated storage. The passes saved 169 MiB and 248 MiB,
respectively. Subsequent maintenance took 0.08 seconds. An unchanged `make dev`
after compression took 2.30 seconds and reused the signed app. Maintenance
preserves ancestor directory timestamps too, avoiding framework-copy invalidation.
These figures cover those cache trees, not the whole cache, which other builds
can change concurrently. Force maintenance with `make cache-prune`, or run
`python3 scripts/cold_build_cache.py compact "$SORTY_BUILD_DIR" debug` directly.

String catalogs use a separate content cache of native `xcstringstool` output.
Its key includes the entire catalog, table name, compiler recipe, and toolchain.
Each hit verifies all generated files before copying them, preserving every
localization. Corrupt output is compiled again. Maintenance retains the latest
entry per table, so InfoPlist and Localizable can both remain cached. An October 3
measurement of the real Localizable catalog took 0.47 seconds to compile and
0.06 seconds for a verified cache hit. This measures catalog work, not the
entire changed-source build.

Bundle assembly clones the SwiftPM executable with `cp -c`. On APFS, the
compiler output and staged executable initially share disk blocks; linkage and
signing edits affect only the staged file. macOS falls back to a normal copy
when cloning is unavailable. A 103 MB executable copied in 0.103 seconds and
cloned in 0.0034 seconds. Signing rewrites the full file, so local builds then
reconstruct its exact signed bytes on another compiler-output clone, writing
only changed 128 KB blocks. SHA-256 verification precedes atomic replacement;
native `copyfile` preserves permissions, timestamps, ACLs, and extended
attributes. The app passes strict signature verification before publication.
The measured 103 MB executable needed only 451 KB of private APFS allocation
after this 0.107-second step, saving about 103 MB of physical storage. Its signed
bytes remained identical and compiler output stayed untouched. Shared blocks
are not reflected as a reduction in `du` totals. CI skips this local operation.

Set `SORTY_COLD_BUILD_CACHE=false` to disable compression, packing, and restoration. A bare
`swift build -c release` can rebuild an archived configuration; use `make daily`
to restore it first, or call
`python3 scripts/cold_build_cache.py restore "$SORTY_BUILD_DIR" release`.
Packing runs only when maintenance is due. Profile switching adds extraction
time; builds between maintenance passes do not pack outputs. Hosted CI keeps
everything expanded.

October's local snapshot fell from 2,723 MB to 1,952 MB. Release outputs compressed
from 730 MiB to 250 MiB, and the test bundle from 206 MiB to 43 MiB. Concurrent
source changes prevent treating those builds as a controlled compile-speed
comparison. An unchanged `make now` after the migration took 2.53 seconds and
reused the signed bundle. Restoring the real Release archive took 2.64 seconds;
packing it took 3.54 seconds. Measure cold, warm, and changed-source builds separately.

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

Hosted caches separate dependency downloads, incremental outputs, and Xcode's
compilation result store. Dependencies use manifest/lockfile keys and are saved
only after successful compilation. Output snapshots include the toolchain,
workspace path, commit, run ID, and retry attempt. Restore prefers the same
commit, then the same dependencies, then the latest compatible toolchain.
A retry can save repaired or more complete outputs without colliding with an
immutable earlier snapshot. Existing v6 archives seed the new layers on the
first run, avoiding a forced cold rebuild.

Swift CI and release unit tests share the `spm-tests` namespace; universal
Xcode builds use `xcode-release`. The two composite actions own identical
restore/save paths for each layer. Dependencies and compilation results are
excluded from output snapshots, so subsequent source edits upload compiler
outputs without duplicating downloads or the compilation store. Cache snapshots
save before test execution. Cache hits never skip compilation or tests.
Hosted builds disable local disk-budget pruning and reset only host-specific
maintenance stamps after restoration.

Tag caches cannot be restored by a different release tag. Run release validation
on `main` before tagging to populate caches in the default branch scope, which
later tags can restore. Manual validation also checks packaging without publishing.
See [GitHub's cache scope rules](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache).

[ci_source_cache.py](../../scripts/ci_source_cache.py) restores source
timestamps only when contents match, preserving Swift's incremental inputs.
It also restores directory timestamps when every child is tracked and its
contents match. Catalog folders recreated by checkout can otherwise invalidate
asset compilation and generated Swift symbols. Changed, added, removed, and
untracked children keep their fresh timestamps.
Release retains both architectures, whole-module optimization, and no Thin LTO.
Test discovery builds the bundle; execution uses `--skip-build`. Regular CI
runs tests in parallel. Release tests stay serial because they share Trash and
Keychain services. The uninstall removal helper exits immediately after all
targets disappear; its 30-second retry budget applies only to failed deletions.
Both test workflows use the compact symbol profile and the poison-cache recovery
wrapper. Universal releases retain full dSYMs and optimization settings.

Universal CI also enables Xcode's native compilation cache under
`.build/CompilationCache.noindex`, saved as its own cache layer.
It can replay compiled results for previously seen inputs after ordinary build
outputs have been replaced by later edits. Xcode keeps the store between runs
and limits it to 4 GB. Compiler cache remarks remain in the full build log.
Local `make now` uses SwiftPM and scheduled compression.
See [Apple's compilation cache settings](https://developer.apple.com/documentation/xcode/build-settings-reference).

The October 3 [optimized compiler benchmark](https://github.com/sorty-organizer/Sorty/actions/runs/37045348328)
compiled the real arm64 SortyLib release command in 117.48 seconds with replay
disabled, then replayed identical inputs in 0.995 seconds. All 116 object files
matched byte for byte. This measures one compilation command, not a complete
release or first-time changed inputs. The [warm universal build](https://github.com/sorty-organizer/Sorty/actions/runs/37042682572)
took 28 seconds, with a 12-second restore of the 1.89 GB compressed cache.
The larger store trades CI space and transfer time for reuse across previously
compiled inputs. New inputs still need normal compilation.

On October 2, hosted run [36962297044](https://github.com/sorty-organizer/Sorty/actions/runs/36962297044)
restored its cache in 4 seconds, compiled changed inputs in a 16-second step, and
executed all 953 tests in a 16-second step. The previous test step took 46 seconds;
removing unconditional uninstall retries eliminated its 33-second delay.
The universal build in [36962299766](https://github.com/sorty-organizer/Sorty/actions/runs/36962299766)
passed in 50 seconds with the small source change, versus 227 seconds for the
preceding build. Repeating only the universal job with identical sources took
33 seconds; the exact cache hit skipped upload. The release test step executed
all 953 tests in 12 seconds. Existing SettingsSearch and WindowSession assertions still fail;
both workflows save compiler caches despite those failures. These are observed
step timings, not promises for large changes or incompatible toolchains.

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
