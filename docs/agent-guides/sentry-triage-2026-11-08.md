# Sentry release triage, 8 November 2026

## Outcome

Every 1.3.0 issue (`com.sorty.app@1.3.0+20261004162224`) is now resolved or
archived, and 1.3.1 has no unresolved issues.

- 66 issues were set to **resolved in `com.sorty.app@1.3.1+20261105122310`**.
  Late events from 1.3.0 installs no longer reopen them; a recurrence on 1.3.1
  or later shows as Regressed and alerts.
  - 26 `<unlabeled event>` handled errors, previously open or archived. 1.3.1
    titles these and groups them under the `sorty.handled_error.v2`
    fingerprint, so the old groups receive no new-build events.
  - Crashes 4G (pooled AI session invalidation, `3982c953`) and 4E (Codex
    SIGPIPE, `c9c7bc4f`).
  - Feedback and diagnostic events 3J and 2T. 1.3.1 files each report as its
    own warning-level issue.
  - 36 app-hang groups. Each actionable stack has a fix in 1.3.1: sounds off
    the main thread (4N), detached cache eviction (4Q), scan and Learnings
    stat calls (2N, 4D), the removed `AnalysisRefreshManager` timer (4R, 4Y),
    the split action-button view (4S), and relocation authorization (2Q). The
    rest end in SwiftUI, AttributeGraph, AppKit or ImageIO internals with no
    Sorty frame to change.
- 2J was already resolved in 1.3.1.
- SORTY-MACOS-23 (575 events) was **archived until escalating**. On macOS,
  Sentry captures the stack after the hang ends, so the main thread is idle in
  `mach_msg2_trap`. That group collects every hang that recovered before
  sampling, so it has no actionable stack, and resolving it would regress on
  every release.

## Policy for each release

1. After a release has been out a few days, list the previous release's
   unresolved and archived issues.
2. For each issue: if the new build fixes it, or the issue is a superseded
   grouping or feedback, resolve it **in the new release** (`inRelease`), never
   plain "resolved". Plain resolution reopens on any late event from older
   installs.
3. If an issue is still reproducible and fixable, fix it, then resolve it in
   the release that ships the fix.
4. Archive known-unactionable noise, such as SORTY-MACOS-23, until escalating,
   not as resolved.
5. Change fingerprints only with a new version prefix
   (`sorty.handled_error.vN`), then resolve the old groups in that release.

## Follow-up: SORTY-MACOS-54 (1.3.1)

New hang at `ApplicationMover.moveAndRelaunch`, the "Sorty couldn't be moved"
alert. `NSAlert.runModal()` ran inside a main-actor `Task`, so the main
dispatch queue stayed blocked while the alert was open. Alerts shown from a
`Task` now go through `ModalAlertPresenter.present(_:)`, which schedules them on
the main run loop. The uninstall-failure alert in `AppState` had the same
pattern and uses it too. Resolve 54 in the release that ships this fix.

The event's breadcrumbs show why the move failed: the user approved the admin
prompt, then `rm`/`mv` returned "Operation not permitted" (`permission_denied`)
while Sorty ran translocated from a quarantined download. Onboarding was
already complete, so an older copy was probably in Applications. Release builds
are ad-hoc signed with no Team ID, so macOS App Management can block replacing
that copy even as root, and the old `rm -rf` could leave it half-deleted. The
move script now renames the existing copy aside (restoring it if the move
fails, trashing it on success), and its exit status names the failed step
(`replace_blocked` vs `source_blocked`). The alert offers Finder and the App
Management pane instead of raw shell output. Developer ID signing would remove
the App Management block for Sorty replacing Sorty; that is a release decision,
not a code change.
