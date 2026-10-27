# Sentry triage, 27 October 2026

Reviewed every unresolved macOS issue first seen after the 25 October triage
(3N through 49) through the authenticated API, using each issue's latest event.
App frames in the development-build crashes are unsymbolicated, and no matching
dSYM exists locally. Causes below come from system frames, exception text, and
the only matching source sites.

## Fixed in source

| Issue | Evidence | Fix |
| --- | --- | --- |
| [46](https://sorty-z1.sentry.io/issues/7814318949/) | `-[NSConcreteTask terminate]: task not launched`, thrown from an async task. | `runCodex` called `process.terminate()` in its cancellation and generic catch blocks. Cancellation can land before `process.run()`, and terminating an unlaunched `Process` raises. Both now check `isRunning`. Every other `terminate()` site runs only after a successful `run()`. |
| [3Z](https://sorty-z1.sentry.io/issues/7812089925/) | SIGPIPE on a thread inside `withCheckedThrowingContinuation` → `FileHandle.write` → `write`. | The only stdin writes in the app are Codex's prompt and model-list requests. If the CLI exits before reading, the write killed Sorty. Both input pipes now set `F_SETNOSIGPIPE`, so the write throws EPIPE into the existing error handling. |
| [49](https://sorty-z1.sentry.io/issues/7814361344/) | Duplicates move to Trash failed with `NSCocoaErrorDomain` 3328 (`NSFeatureUnsupportedError`). | This usually means the volume has no Trash (a network share or some external disks). The failure is legitimate, but the alert said "Something went wrong." `userFacingMessage` now maps 3328 to a plain sentence, and partial-trash failures use that text instead of `localizedDescription`. Trashing is still refused on these volumes; no permanent-delete fallback was added. |

| [40](https://sorty-z1.sentry.io/issues/7812105685/) | Main thread blocked in `NSSound.play` → `AVAudioPlayer.play` while CoreAudio waited to start the output device (HAL `StartAndWaitForState`). This typically happens when Bluetooth audio wakes up. | The three one-shot "Glass" sounds (completion notifications, onboarding reveal, skill setup) now go through `SoundEffectPlayer`, which creates and plays the sound on a serial background queue. The skill intro already starts `AVAudioPlayer` off the main thread. The onboarding soundtrack still starts on the main actor because it is timed to visual cues. |
| [47](https://sorty-z1.sentry.io/issues/7814343781/) | Ollama `/api/tags` decoding hit `key_not_found`. The event has no response body. | Model entries accept `name` or `model`, since compatible servers may send only one, and skip entries with neither. A response without `models` now throws `unexpectedOllamaResponse` ("didn't respond like Ollama"), classified as configuration rather than decoding. |

## Already fixed

[3Q](https://sorty-z1.sentry.io/issues/7811111842/) `Task created in a session
that has been invalidated` crashed a local build at 04:54 UTC on 25 October.
Commit `3982c953`, "Fix pooled AI session invalidation race," landed four
minutes later.

## Not patched

- [44](https://sorty-z1.sentry.io/issues/7813445154/)/[45](https://sorty-z1.sentry.io/issues/7813445188/)
  (HTTP 501 from OpenAI and Codex model listing),
  [48](https://sorty-z1.sentry.io/issues/7814353393/) (HTTP 502 during
  generation), and [43](https://sorty-z1.sentry.io/issues/7812907551/) (Ollama
  not running): server or dependency responses. A 501 on `/models` points to a
  proxy that does not implement model listing.
- 3N, 3P, [3Y](https://sorty-z1.sentry.io/issues/7812088769/): model-catalog
  refreshes without an API key. These are expected setup states, already
  reported as warnings on main.
- 3S, 3V, 3W, [42](https://sorty-z1.sentry.io/issues/7812863621/):
  development-build bug reports sent while testing the feedback form. Their
  events have only the category title.
- 44, 45, and 47–49 appear as `<unlabeled event>` because production 1.3.0
  predates the readable handled-error titles on main.

## Validation

None of these runtime paths were exercised. A standalone `swiftc` compile
confirmed that `F_SETNOSIGPIPE` reads back as set, and `make dev` built the
40/47 follow-up without errors. No Sentry statuses were changed.
