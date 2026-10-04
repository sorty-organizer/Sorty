# Private organization quality corpus

Keep real cases in `QualityCorpus/private/`. Git ignores that directory because filenames, paths, expected destinations, and extracted evidence may be sensitive. The committed `sample/` case is synthetic and documents the schema.

Each JSON file describes one representative folder after a run. Add one decision per file. Cover expected moves, expected non-moves, useful renames, protected names, and cases that should remain uncertain. Record the final preview outcome instead of silently changing the expected answer to match the model.

Run the report with:

```sh
make quality-report
```

Set `QUALITY_CORPUS=QualityCorpus/sample` to verify the synthetic example. Run the executable directly with `--json` for a machine-readable report. Keep generated reports in `QualityCorpus/reports/`, which Git also ignores.

The report tracks placement acceptance and expectation matches, rename accepts, edits, rejections, reverts, manual edits per 100 files, protected-name preservation, ambiguous review handling, and confidence calibration. A 90% confidence bin is calibrated when about 90% of its suggestions are accepted without edits.

## Preview replay

Add `replayDirectory` to each case. It can be absolute or relative to the case
JSON file. Label eligible files with `sourcePath` values relative to that
directory. Optional `replayInstructions` supplies the organization instructions.
Use a fixed copy of the source folder so comparisons across models see the same
files. Scanner-excluded files must not appear as eligible labels; a missing
observation fails the replay instead of silently shrinking the denominator.

Run the production scan, planning, assignment, and review pipeline with:

```sh
swift run SortyQuality --corpus QualityCorpus/private \
  --replay --config /path/to/AIConfig.json \
  --output QualityCorpus/reports/model-name
```

The config uses Sorty's `AIConfig` JSON schema. Set `SORTY_QUALITY_API_KEY` in the
environment to override its API key without saving a key in the config. Replay
uses the selected provider and can incur API charges. It creates previews only;
it never applies moves, renames, or tags. It uses temporary history storage and
does not attach a learning observer or persist the app's manual session. Content
extraction uses the normal cache. Each replay starts without the app's personal
learning profile, persona, or storage-location adapters, so it measures the
configured pipeline and supplied instructions rather than reproducing every
piece of a saved app session.

The output contains observed case files and `_summary/report.json`. Expectations
stay unchanged, and the reviewed input corpus is never overwritten. Report the
output directory as a corpus to compare models. Replays measure expectation
matches, project preservation, review requirements, and total preview latency.
They do not invent human acceptance, manual edits, reverts, or rename calibration.
Planning/review text calls are absent from assignment cost statistics; compare
full cost using provider usage records rather than those partial estimates.

## Multiple valid destinations and project boundaries

A decision can include `acceptableDestinations`, an array of valid folder paths.
When nonempty it replaces `expectedDestination` for placement scoring. Annotate
related files with the same `expectedProjectPath`, such as `Projects/Acme`.
A project counts as preserved when all its observed files remain in that path
or its descendants. At least two labeled files are required for this metric.
This checks project boundaries even when related files use different subfolders.
