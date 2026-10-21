# Repeated build-speed comparison, October 21, 2026

Compared `51d278ad14abc67eaf9873280eaae5ab3a4dd72b`, immediately before the first FolderOrganizer split, with `45127fc315ceef94e853f8ced98182bda807e531`, after the file, expression, and UI-module changes. These are whole-revision comparisons; intervening unrelated commits prevent attributing every difference solely to the splits.

## Method

Sources were exported with `git archive` into two temporary directories. The main checkout was not modified for probes. Builds ran sequentially on the same Mac using Apple Swift 6.2.4, arm64, Debug, 14 jobs and the flags below. Each snapshot had a separate initially empty scratch directory. Dependencies came from each revision's package resolution.

```sh
swift build --package-path "$SNAPSHOT" --scratch-path "$SCRATCH" \
  -c debug --product SortyApp -j 14 --disable-sandbox --disable-index-store \
  -debug-info-format none -Xswiftc -gline-tables-only -Xcc -gline-tables-only \
  -Xswiftc -module-cache-path -Xswiftc "$SCRATCH/ModuleCache" \
  -Xcc "-fmodules-cache-path=$SCRATCH/ModuleCache"
```

After the initial build, three unchanged builds were timed. For each listed file, append a distinct comment, build, restore the original bytes, and build again. Repeat five times. Report only the five comment-edit builds, excluding the restore builds. Times below are Python monotonic elapsed seconds around the full Swift command, including startup and planning, rather than SwiftPM's shorter printed duration. All runs succeeded.

The fixed run order was baseline then final, without thermal or background-load control. Medians reduce outlier influence but are not confidence intervals. Comment changes exercise incremental compilation and module emission, not semantic body edits, public API changes, packaging, signing, launch, tests, or hosted CI.

## Repeated incremental results

| Edited file | Before median | After median | Less time | Speedup |
| --- | ---: | ---: | ---: | ---: |
| `OptimizedPreviewTree.swift` | 6.833s | 1.147s | 83.2% | 5.96x |
| `PermissionsSettingsView.swift` | 3.601s | 1.507s | 58.2% | 2.39x |
| `OnboardingView.swift` | 4.035s | 1.577s | 60.9% | 2.56x |
| `AppCommands.swift` | 3.861s | 1.343s | 65.2% | 2.88x |
| `FolderOrganizer.swift` | 2.837s | 1.168s | 58.8% | 2.43x |

Every one of the 50 measured edit builds compiled exactly the edited Swift file. Logs also showed emission of its owning module. No unchanged downstream source files compiled. This was already true before the refactor; the gain is reduced cost of compiling the file and emitting its module.

Unchanged-build medians were 0.683s before and 0.623s after, with zero source files compiled. Three samples and startup outliers do not establish a meaningful no-op speedup.

## Raw samples

Elapsed seconds in run order.

| File | Before, five samples | After, five samples |
| --- | --- | --- |
| `OptimizedPreviewTree.swift` | 6.915, 7.409, 6.784, 6.772, 6.833 | 1.147, 1.135, 1.152, 1.170, 1.143 |
| `PermissionsSettingsView.swift` | 5.181, 3.587, 3.601, 3.561, 3.753 | 1.513, 1.506, 1.513, 1.507, 1.503 |
| `OnboardingView.swift` | 4.035, 4.125, 3.711, 4.107, 3.762 | 1.559, 1.593, 1.577, 1.562, 1.586 |
| `AppCommands.swift` | 3.841, 3.861, 3.892, 3.826, 3.879 | 1.371, 1.345, 1.316, 1.310, 1.343 |
| `FolderOrganizer.swift` | 2.837, 5.439, 2.519, 2.545, 3.425 | 1.174, 1.168, 1.174, 1.161, 1.153 |

No-op samples: before 1.678, 0.683, 0.641s; after 2.799, 0.623, 0.620s.

## Clean builds

After the incremental probes, `swift package --package-path "$SNAPSHOT" --scratch-path "$SCRATCH" clean` removed build products while retaining dependency resolution. One subsequent clean build per revision took **60.339s before and 56.084s after**, a **7.1% reduction**, or **1.08x**. Both succeeded. This is one sequential pair, so the smaller clean-build gain is less certain than the repeated incremental results.

Initial builds into empty scratch directories, including dependency setup, took 87.049s before and 68.853s after. These setup-inclusive runs are not the clean compile comparison above. The earlier thread's 74s to 60s claim was not reproduced under this method.

Temporary source exports and build caches were removed after measurement. The earlier single-sample measurements remain in [the original report](incremental-build-results-2026-10-21.md) for historical context.
