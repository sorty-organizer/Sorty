# Sentry hang triage, 24 October 2026

## SORTY-MACOS-3H

The supplied Sentry report records one hang of at least 2,000 ms in production
Sorty 1.3.0, build 20261004162224, at 2026-10-23 16:47:11.621 UTC.
The full event is [362b5852c75a4bc0a9fc2629d995f0db](https://sorty-z1.sentry.io/issues/7809612745/events/362b5852c75a4bc0a9fc2629d995f0db/),
and its trace ID is `067544aff0534865ad9c4c0ebd1d8136`. The initial review used
the pasted report. A follow-up retrieved the full event and all three adjacent
SORTY-MACOS-23 hang events in the same trace through the authenticated Sentry API.

The sampled main thread is evaluating `DirectorySelectionView.dropZone`.
Line 254 in the local `v1.3.0` tag is `.buttonStyle(.plain)`. This identifies
the sampled rendering location, but does not establish that the button style
caused the delay. The full stack ends in SwiftUI `LinkDestination`, through
`Button`, `View.modifier`, and `View.buttonStyle`. There is no time profile.

The device is an 8 GiB M1 MacBook Air running macOS 15.8.1. Sentry reports
68.8 MiB free memory and 163.3 MiB app memory usage. Low free memory is a
diagnostic lead, not proof of memory pressure, paging, or an app memory leak.
The app had been running for about 90 minutes, so this is not evidence of a
launch hang. The handled-error entries shown in the report
precede the hang and do not establish a causal link.

## Source review

The current view, its release version, drop-zone modifier, workflow container,
accent lookup, icon sweep, window visibility reader, and Beam lifecycle were
reviewed. No synchronous file scan, network request, or wait was found in the
drop-zone view construction. The folder picker runs in a button action, while
dragged items load through an item-provider callback. Neither action appears in
the supplied stack. The drop-zone glass branch requires macOS 26 and therefore
does not apply to this macOS 15 event.

The shared icon highlight is a single appearance animation. The Browse button's
Beam already gates activity on presentation, Reduce Motion, window visibility,
and control activation. These observations do not rule out rendering costs or
framework problems, but do not demonstrate a defect that warrants changing
these effects. Later view-expression extraction on main is a compilation
refactor, not a verified fix for this hang.

## Adjacent events and narrowed diagnosis

All four events share the same app start time and trace. The three earlier
events show these main-thread paths:

| UTC time | Event | Sampled path |
| --- | --- | --- |
| 16:46:37.406 | `706c634eb9d5499face2bef1ef675435` | Status-bar tracking-area handling, ending in `_NSEnableMouseMovedEventsForWindow`. |
| 16:46:57.869 | `9f3e289e1ca44e8592a0d2246a6532ab` | Mouse-event window lookup, blocked in `_CGSFindWindow` and `mach_msg2_trap`. |
| 16:47:03.183 | `dc1245f5167e40d8aecd34d433955c54` | Status-bar window movement and display-change handling, blocked in `SLSIsDisplayChangedSeedValid` and `mach_msg2_trap`. |
| 16:47:11.621 | `362b5852c75a4bc0a9fc2629d995f0db` | SwiftUI construction of the directory-selection button. |

No duplicate-scan/hash workers appear in these events. The earlier duplicate
scan diagnosis documented on 15 October therefore cannot be assigned to this
session. Other threads are primarily framework wait loops, Sentry monitoring,
and networking. The retained breadcrumbs are lifecycle transitions and do not
identify an organization or scan action during the hang interval.

Two earlier samples demonstrate synchronous waits on the window system. A
window-system responsiveness problem is a stronger lead than a defect in the
sampled button style. These snapshots do not identify why the window server was
slow, establish that all four events have one cause, or measure how long any
individual frame ran. Low memory remains a possible contributor, not a proven
cause. Source review of the release and current menu-bar label found
activity-driven image loading rather than a repeating icon timer; the controller
also suppresses unchanged activity publications.

The remaining evidence is a system trace during recurrence, including
WindowServer scheduling, CPU use, memory pressure, paging, and the app's main
thread. Time Profiler alone may miss time spent waiting on another process.
Apple's [hang analysis guide](https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app)
explains how main-run-loop work affects responsiveness.

No runtime fix is claimed. No build, tests, or computer-use verification was
performed for this documentation-only triage. Keep the issue unresolved until
the cause and remediation are supported by further evidence.
