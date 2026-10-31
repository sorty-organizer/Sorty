# CI performance

Swift CI runs security scanning, a combined cache-check/fuzz job, and the app
build/test job independently on Blacksmith. Fuzzing uses macOS because its
harness compiles Apple-platform sources with `xcrun`. Cache checks share that
runner because several exercise Apple Archive, code signing, and Xcode tools. App compilation and packaging stay on the same runner to share outputs.
Swift test workers are explicitly limited to the runner's CPU count; `-j` also
limits compilation jobs.

The security scan uses a blobless full-history checkout. It retains commit
history for Gitleaks and fetches file contents as needed. Build-only jobs retain
shallow checkouts because they do not inspect history.

## Baseline and measurement

[Swift CI run 40876506678](https://github.com/sorty-organizer/Sorty/actions/runs/40876506678)
completed successfully on October 29, 2026, in 167 seconds from workflow creation
to completion. The build/test job took 139 seconds, including 47 seconds of
fuzzing and 2 seconds of Python cache checks before compilation. Splitting those
checks removes 49 seconds from that job's serial path. This is an opportunity,
not a measured end-to-end speedup: runner queues, cache state, and the parallel
fuzz job can change the result.

Compare hosted runs with similar source changes and cache state. Inspect job
`started_at`/`completed_at` and step timestamps through the Actions API; separate
queue time, checkout/toolchain/cache setup, compilation, packaging, and tests.
Main pushes already save compatible dependency and compiler caches that PRs can
restore through the shared composite actions. Check cache hits before changing
keys or adding machines.

## Applying the article

Source: Owen Gretzinger,
[How I made our CI 20x faster](https://x.com/owengretzinger/status/2116291924219060319).

Sorty already uses Blacksmith for native CI, runs security checks independently,
and seeds compiler caches on main. This change separates independent checks and
makes test concurrency explicit. It preserves every existing check and does not
add affected-test skipping or sharding: the baseline test execution took only
17 seconds, so duplicating compilation across shards is not justified yet.

The article's Oxlint, TypeScript checker, and Vitest isolation changes concern a
JavaScript server. They do not apply to the Swift app. Website toolchain changes
need separate compatibility and lint-coverage measurements. Keep the website's
Next.js lint rules until a replacement demonstrates equivalent coverage.

Do not add a local Swift pre-push build: repository instructions prohibit local
CI substitutes and verification for minor changes. Hosted Blacksmith checks
remain the source of build and test confidence. Runner upgrades and additional
shards should follow timing and cost measurements rather than the article's
reported speedup.
