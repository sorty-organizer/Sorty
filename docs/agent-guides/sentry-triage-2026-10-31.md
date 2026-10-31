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
