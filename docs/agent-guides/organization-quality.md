# Organization quality

Organization quality means that files land in useful destinations and need few
manual corrections. Folder count, depth, and file extensions alone cannot prove
that a plan is good or bad.

## Organization flow

Organization runs no structural quality-score gate, low-confidence quarantine,
quality retry, shared taxonomy request, or semantic placement-review request.
The preview omits parse-warning notices, confidence summaries, collision
suggestion cards, and quality-based Apply blocking. File-path validation,
filename normalization, and user-configured exclusions still apply.

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

Assignment batches use the existing bounded workflow. Rich prompt metadata
prioritizes ambiguous names and available content across extensions, rather
than letting the first extension consume the whole budget.

Use `SortyQuality` to report placement expectation matches, acceptance, manual
preview edits, rename calibration, and reverts on a private reviewed corpus.
Do not claim quality gains from compilation or synthetic tests alone.
