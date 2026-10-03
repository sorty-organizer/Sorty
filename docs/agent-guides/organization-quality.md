# Organization quality

Organization quality means that files land in useful destinations and need few
manual corrections. Folder count, depth, and file extensions alone cannot prove
that a plan is good or bad.

## Structural checks

Mixed file types, specific single-file folders, deep hierarchies, and large flat
folders are advisory issues with zero score deduction. They do not trigger a
retry or quarantine files. These shapes can represent coherent projects,
user-requested hierarchies, or archives. Vague names, invalid paths, duplicate
destinations, and file accounting still receive correctness checks.

## Learning evidence

A completed monitoring window without corrections marks the session `unreviewed`.
It does not add positive examples or increase rule success counts. Sorty can
still ask a placement question after monitoring ends.

Explicit `Useful` feedback on a completed, unreverted session without placement
corrections records positive examples scoped to that session's source folder.
Rule successes are counted once per session, even if the feedback repeats.
Prior `Not useful` feedback prevents automatic placement reinforcement. Existing
correction, exclusion, consent, and pause checks remain in force.

## Evidence and measurement

Use `SortyQuality` to report placement expectation matches, acceptance, manual
preview edits, rename calibration, and reverts on a private reviewed corpus.
Structural scores are diagnostics, not measurements of placement accuracy.
Do not claim quality gains from compilation or synthetic tests alone.
