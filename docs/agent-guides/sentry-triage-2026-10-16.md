# Sentry triage, 16 October 2026

[Event 4d4774e2c76e4f9b9ee48b6a84a64513](https://sorty-z1.sentry.io/issues/7796112962/events/4d4774e2c76e4f9b9ee48b6a84a64513/)
is a development-build crash on macOS 27.0.1 in Sorty 1.3.0, build 2673.
The exception is an out-of-bounds `__NSCFArray` access inside Carbon resource-map
handling, reached through `NSWorkspace.setIcon(_:forFile:options:)`.

Three worker threads were inside `setIcon` simultaneously. The local app binary
matches the event UUID, `832B272C-D670-3717-9717-0FFD8C4991EB`. Symbolication
against that binary identifies the crashing caller as
`refreshInstalledQuickActionIconsAsync` → `refreshInstalledQuickActionIcons` →
`applyQuickActionIcon`, at the `setIcon` call. Sentry itself lacks this build's
dSYM; the available release dSYM has a different UUID and must not be uploaded
as a match.

Concurrent icon updates are the supported cause to address: the shared
`applyQuickActionIcon` helper now holds one process-wide lock while rendering
and applying icons and writing workflow icon resources. This covers all install
and refresh callers without moving the background work onto the main thread.
It prevents overlapping Sorty calls into the resource-map code seen in the crash.

No local build, tests, or UI verification was run for this small synchronization
change, per repository instructions. The crash has not been reproduced after
the change, and recurrence prevention remains unverified. The Sentry issue
remains open pending runtime evidence.
