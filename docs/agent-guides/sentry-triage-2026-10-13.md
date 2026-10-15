# Sentry triage, 13 October 2026

Live review covered unresolved macOS issues last seen since 8 October and all
unresolved website issues. The recent macOS events are production events from
1.3.0, build 20261004162224. These source changes have not shipped in that build.

| Issues | Evidence | Action and remaining work |
| --- | --- | --- |
| [2N](https://sorty-z1.sentry.io/issues/7783850830/) | Main thread in `setScannedFiles`, `FileItem.displayName`, URL directory detection, and `lstat`. | Give name-formatting URLs an explicit directory hint to avoid filesystem probing. Production recurrence still needs monitoring after release. |
| [2S](https://sorty-z1.sentry.io/issues/7786696259/) | Duplicate file button blocked in synchronous `NSWorkspace.open` and Launch Services IPC. | Use the asynchronous open API. Runtime validation remains outstanding. |
| [2Q](https://sorty-z1.sentry.io/issues/7786650905/) | Move-to-Applications HUD action executes `NSAppleScript` synchronously, waiting in administrator authorization. | Script execution now uses an asynchronous subprocess with a duplicate-move guard, preserving authorization, error reporting, and move/relaunch ordering. Runtime validation remains outstanding. Do not run the destructive move script as a diagnostic. |
| [23](https://sorty-z1.sentry.io/issues/7751822643/) | SwiftUI display-list dictionary updates during layout. | Still open. Stack alone does not identify the expensive view or establish a safe fix. Needs a representative UI trace. |
| [2R](https://sorty-z1.sentry.io/issues/7786668619/), [2V](https://sorty-z1.sentry.io/issues/7786771508/) | JSON response decoding failures during generation and regeneration. | Still open. Current events omit provider/model and the fixed decoding failure category. No response content should be uploaded. |
| [2G](https://sorty-z1.sentry.io/issues/7772815841/), [2W](https://sorty-z1.sentry.io/issues/7786783210/), [2Y](https://sorty-z1.sentry.io/issues/7787118936/) | Provider HTTP 400, 404, and 413 respectively. | Still open. Need safe provider/model, request-size, and error-code diagnostics to distinguish unsupported models, invalid parameters, and request limits. Blind retries will not fix these statuses. |
| [2F](https://sorty-z1.sentry.io/issues/7772736705/) | `NSURLErrorTimedOut` during generation. | Still open. A timeout alone does not establish a client defect. |
| [2D](https://sorty-z1.sentry.io/issues/7770242348/), [2P](https://sorty-z1.sentry.io/issues/7784419701/) | OpenAI and Groq model-list fetch failures, without underlying status. | Missing credentials and HTTP statuses now retain safe typed failures. Existing events cannot recover the discarded status. |
| [2K](https://sorty-z1.sentry.io/issues/7783847930/), [2M](https://sorty-z1.sentry.io/issues/7783848052/) | Same-time HTTP 500 during Codex stale fallback and OpenAI provider refresh. | Provider failure; stale models remain available. The fallback boundary now reports only errors it consumes; rethrown failures are reported once by the outer refresh. |
| [2X](https://sorty-z1.sentry.io/issues/7786796652/) | Unclassified apply failure; partial operations exist. | Filesystem errors now get fixed typed causes, including partial apply, without collecting associated paths or descriptions. Partial-operation history and undo behavior are preserved. The original underlying failure is unavailable. |
| [2T](https://sorty-z1.sentry.io/issues/7786706059/) | Informational diagnostic-report generation. | Expected telemetry, not an application error. |
| [2J](https://sorty-z1.sentry.io/issues/7780212160/) | Previously reviewed AppKit toolbar crash; no newer event. | Existing empty-toolbar mitigation is on main. Released verification remains outstanding. |

All handled errors now get a bounded, sanitized message containing feature,
operation, category, and cause. Their fingerprints remain unchanged. This fixes
the `<unlabeled event>` presentation without sending paths, provider responses,
prompts, or raw error descriptions.

The website has only three old ingestion/allowlist verification events from
29 July, with no new unresolved errors.

No issues were marked resolved or muted. No local build, tests, or computer-use
verification was run for the small URL, open-API, and event-message changes. Hosted [Swift CI run 38349696995](https://github.com/sorty-organizer/Sorty/actions/runs/38349696995)
passed for commit `7e7e1d99`, including security checks, test compilation, app
build, and tests. Pre-release validation was skipped by that workflow.
A focused privacy test covers partial-apply classification without raw details.

## Follow-up, 15 October 2026

Fifteen new hang issues ([2Z](https://sorty-z1.sentry.io/issues/7793427679/)
through [3B](https://sorty-z1.sentry.io/issues/7794032537/), plus recurrences of
[Q](https://sorty-z1.sentry.io/issues/7646194145/), [Y](https://sorty-z1.sentry.io/issues/7648829635/),
and [23](https://sorty-z1.sentry.io/issues/7751822643/)) came from one 1.3.0
session on an 8 GB MacBook Air with about 150 MB free memory. Every event shows
two duplicate-scan workers in `computeSampleFingerprintResult` reads while the
main thread is doing ordinary SwiftUI work in `DuplicatesView`,
`DuplicatesHeaderNew`, `ScanProgressViewNew`, `AppKitImageView.updateNSView`,
and window chrome. The main thread is slow, not blocked by one bad call.

- `DuplicatesHeaderNew` called `NSWorkspace.icon(forFile:)` in its body. Each
  4 Hz progress tick evaluated it twice through `ViewThatFits`, and the new
  image identity forced `AppKitImageView` to reassign its image. The icon is now
  cached by path.
- Hash reads now set `F_NOCACHE`, so scanning large folders does not fill the
  unified buffer cache and evict app pages under memory pressure.

Recurrence needs monitoring after the next release. The generic SwiftUI frames
in these issues will group under different titles, so judge by Duplicates-scan
sessions on low-memory Macs rather than individual issue IDs.
