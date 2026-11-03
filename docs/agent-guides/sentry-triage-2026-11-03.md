# Sentry triage, 3 November 2026

## Analysis status-message hang

[SORTY-MACOS-4R, event bd480f132dc948808262230ad0a1e496](https://sorty-z1.sentry.io/issues/7826259818/events/bd480f132dc948808262230ad0a1e496/)
reports a main-thread hang of at least two seconds at 05:54:39 UTC on
3 November. Retrieved the complete event through the authenticated Sentry API.
The production release is `com.sorty.app@1.3.0+20261004162224` on macOS 26.5.1.

The captured stack runs from `AnalysisRefreshManager.cycleFunnyMessage` through
`withAnimation`, a Combine published-property update, and SwiftUI graph updates
into `ModelSelectionOverlayModifier.body` at line 1169. Its final frames are
Swift generic-metadata cache lookup and insertion functions, reached through
`View.onChange`. This identifies the sampled update path; it does not establish
why that work exceeded two seconds or prove a deadlock.

Commit `b25d13030e88d00dadea57f28b59f441b540ac44` removed
`AnalysisRefreshManager`, its timer, its observation in `AnalysisView`, and its
lifecycle hooks on 18 October. Current source contains neither the manager nor
`cycleFunnyMessage`. The November event therefore does not test that removal.
The model-selector modifier still exists, but this stack alone does not justify
changing its native popover or presentation behavior.

No additional runtime patch is supported by this event. Leave the issue open
until a build containing the removal has been distributed and exercised. If a
hang recurs on that build, retrieve its full stack and capture a representative
Time Profiler or system trace to distinguish metadata work, repeated SwiftUI
updates, and blocking waits.

This review compared the full production stack with current source and Git
history. No build, tests, installation, or runtime reproduction was performed;
the only repository change is this note. No Sentry issue status was changed.
