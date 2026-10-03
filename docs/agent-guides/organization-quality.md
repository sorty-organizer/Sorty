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

For runs needing several assignment batches, Sorty requests a shared taxonomy
first. Every file contributes to source-folder/type counts. The planner sees up
to 120 group summaries and 160 representative files spanning those groups.
Destinations carry exact paths, purposes, and examples. All batches receive the
same planning context; unseen evidence can justify a new destination. Resume
checkpoints retain that context. A planning failure preserves the bounded batch
workflow and adds a review warning.

Rich prompt metadata prioritizes ambiguous names and available content across
extensions, rather than letting the first extension consume the whole budget.

After structural checks, Sorty reviews at most 40 questionable placements across
destinations. Candidates include generated names, unorganized files, structural
warnings, missing folder purposes, and shared project stems split between
destinations. The reviewer must return one valid decision per local file ID.
Missing, duplicate, or invented IDs invalidate the response.

The reviewer can keep a placement, request more evidence, or flag a contradiction.
Only files requesting evidence receive another local extraction, and only when
Deep Scan is enabled. Cloud placeholders, downloads in progress, directories,
and symlinks are skipped. Extraction reuses the content cache and OCR settings.
One repair request handles the disputed subset. Path safety and complete file
accounting must pass before it joins the original plan. Other assignments and
their rename/tag mappings remain intact. Review failures keep the original plan
with a warning; watched-folder auto-apply waits for review. Rename-only skips
placement review.

Planning and review run through the selected provider. They add requests and
latency. Assignment token/cost statistics currently omit these `generateText`
calls, so they must not be presented as the complete cost of a quality run.

Use `SortyQuality` to report placement expectation matches, acceptance, manual
preview edits, rename calibration, and reverts on a private reviewed corpus.
Structural scores are diagnostics, not measurements of placement accuracy.
Do not claim quality gains from compilation or synthetic tests alone.
