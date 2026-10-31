# Sentry triage, 31 October 2026

Reviewed the latest events for all ten new macOS groups (4A–4K; no 4I)
since the 27 October triage. An all-status inventory found no additional new
ignored groups or website groups. Every retrieved event came from production
`com.sorty.app@1.3.0+20261004162224`, released on 4 October.

## Source fix

[4D](https://sorty-z1.sentry.io/issues/7819683865/) samples
`FolderOrganizer.aiAnalysisPhase` → `LearningsManager.selectModelDirectoryContext`
→ `URL.init` → `initFileURLWithPath:` → `stat`. The fallback extension extraction
used the filesystem-inferencing URL initializer on the main actor, even though
its filter already establishes that these items are files.

The initializer now passes `isDirectory: false`, avoiding that directory probe.
The extension array is evaluated once and reused for category and extension
sets; the previous lazy sequence evaluated the mapping twice. Matching and
ranking behavior stay the same. This removes the sampled filesystem probe;
it does not prove all organization hangs are fixed.

## Other new groups

| Issue | Evidence and disposition |
| --- | --- |
| [4G](https://sorty-z1.sentry.io/issues/7821743598/) | Prewarming created a task in an invalidated URLSession. Main already wraps pooled sessions in `AISession`, retaining the handle through request creation and retiring it after callers release it. This old release does not exercise that fix. |
| [4E](https://sorty-z1.sentry.io/issues/7819685847/) | SIGPIPE, but its reported crashing thread is in CoreGraphics glyph rendering and an unfair lock. No pipe writer is identified in the retained thread stacks. Main already protects Codex stdin pipes from SIGPIPE; this event cannot establish the same cause or confirm that fix. |
| [4A](https://sorty-z1.sentry.io/issues/7819665199/) | Directory selection waits during `NSOpenPanel.init` in ViewBridge. No expensive app operation appears inside that wait. No speculative panel or threading change. |
| [4H](https://sorty-z1.sentry.io/issues/7821750355/) | Native outline expansion samples `DuplicatesView.resultsView`, with intervening SwiftUI framework work. The sample does not establish which data or operation made expansion slow. No speculative duplicates redesign. |
| [4B](https://sorty-z1.sentry.io/issues/7819666280/), [4C](https://sorty-z1.sentry.io/issues/7819667830/) | Codex model refresh returned HTTP 501 and 500. Retained tags identify server responses, without enough detail to establish an app defect. |
| [4F](https://sorty-z1.sentry.io/issues/7821739944/), [4J](https://sorty-z1.sentry.io/issues/7821770406/) | Groq and OpenRouter model refreshes failed to connect. No new application cause is established. |
| [4K](https://sorty-z1.sentry.io/issues/7821775385/) | Plan generation returned HTTP 402. The event does not preserve a provider reason; billing or credit exhaustion cannot be confirmed from the status alone. |

## Validation and next evidence

No local build, test, or UI verification was run for this minor change, as
required by the repository instructions. The fix needs a shipped build and
recurrence monitoring. No Sentry status was changed and no release was made.
The unresolved UI waits need a recurrence trace; the SIGPIPE needs a stack
identifying the writer before another targeted patch is justified.

## Diagnostic follow-up

New reports from a build containing this follow-up can carry:

- `last_ui_operation` context and `sorty.ui_operation` breadcrumbs before folder
  panel construction/presentation and duplicate-section expansion/collapse.
  Only fixed operation/phase names and bucketed group counts are recorded.
  This context describes the last action, not proof it caused the hang.
- `sorty.cli_stdin` breadcrumbs immediately before and after both Codex stdin
  writes, with model-list/generation, write phase, and a numeric POSIX error on
  failure. The callback runs synchronously on the writer thread. It collects
  no input bytes, process arguments, paths, or CLI output. This may identify a
  recent writer in a crash; it cannot guarantee attribution for every SIGPIPE.
- `last_memory_pressure` context and breadcrumbs from kernel memory-pressure
  notifications. These describe the last delivered notification, not a memory
  measurement at the exact crash time. No timer, process list, or system trace
  is collected.
- Diagnostic version 3 accepts fixed provider codes from nested and top-level
  JSON errors, including billing, permission, and availability codes. It marks
  whether a reason was recognized and records a fixed payload-shape category.
  Bodies larger than 64 KiB are not parsed. Unknown codes and free-text messages
  stay excluded; an HTTP 402 without a recognized code remains unexplained.

All collection remains gated by reliability consent and internet privacy mode.
The pipe sink is installed after authorized Sentry startup and removed on stop;
the memory-pressure source is cancelled on stop. Existing bounded breadcrumb
storage applies. No screenshots, window titles, filenames, prompts, response
bodies, credentials, or raw system traces were added.

Extended the existing provider privacy test for top-level billing errors,
unknown codes, free text, and oversized payloads; added an allowlist/count-bucket
check for UI context. Local builds and tests were not run for this focused
instrumentation change under the repository's minor-change rule. These checks
are authored coverage, not passing-test evidence. Live collection still needs
a shipped build with consent and fresh events.
