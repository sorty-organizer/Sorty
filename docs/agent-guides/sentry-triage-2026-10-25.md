# Sentry triage, 25 October 2026

Read the unresolved macOS and website issue inventories through the authenticated
Sentry API, including feedback issues omitted by the CLI's default error list.
Reviewed the latest production events, their stacks and tags, and the available
feedback messages. GitHub had no open issues. The website's three unresolved
items remain the July ingestion diagnostics; no new website defect was found.

## Gemini setup: source fix

[SORTY-MACOS-3K](https://sorty-z1.sentry.io/issues/7809647988/) reports a 404
after entering a Gemini API key in 1.3.0. Its linked marker is
[3J](https://sorty-z1.sentry.io/issues/7809647965/).

`OpenAIClient.checkHealth()` uses `AIRequestSupport.openAIModelsURL`. Given
Gemini's default base without a trailing slash, the helper constructed
`/v1beta/openai/v1/models`. Google's documented endpoint is
[`/v1beta/openai/models`](https://ai.google.dev/gemini-api/docs/openai#list-models).
The shared helper now preserves that base. Chat generation already handled it
correctly. Replaced a duplicate chat-URL test with model-list cases for the
default base, trailing slash, and full chat endpoint.

This is a confirmed source defect consistent with the feedback. The report
does not contain the failing request URL, so it cannot prove this was the user's
only failure. Authenticated Gemini setup and production recurrence remain
unverified; leave the report open until the fix ships and is exercised.

## Other production issues

All latest production events reviewed since 8 October came from
`com.sorty.app@1.3.0+20261004162224`, before the subsequent fixes on main.

| Issues | Current evidence and disposition |
| --- | --- |
| [2Q](https://sorty-z1.sentry.io/issues/7786650905/) | Latest 25 October hang still waits in Apple Events/administrator authorization. The asynchronous relocation fix is already on main; this old-build recurrence does not test that fix. |
| [3D](https://sorty-z1.sentry.io/issues/7797322010/), [2Y](https://sorty-z1.sentry.io/issues/7787118936/) | HTTP 413. Adaptive splitting is already fixed on main. Released recovery remains unverified. |
| [2D](https://sorty-z1.sentry.io/issues/7770242348/), [2P](https://sorty-z1.sentry.io/issues/7784419701/) | OpenAI/Groq model-list errors still carry the old generic cause. Typed status reporting is already on main. These events cannot recover the discarded HTTP status. |
| [2R](https://sorty-z1.sentry.io/issues/7786668619/), [2V](https://sorty-z1.sentry.io/issues/7786771508/) | Invalid generated JSON. Existing events lack provider/model and decoding detail needed to distinguish causes. Keep open. |
| [2G](https://sorty-z1.sentry.io/issues/7772815841/), [2W](https://sorty-z1.sentry.io/issues/7786783210/) | HTTP 400/404 without the failing provider/model or safe reason. The Gemini feedback identifies a separate setup defect; do not assume every 404 has that cause. |
| [2F](https://sorty-z1.sentry.io/issues/7772736705/), [2E](https://sorty-z1.sentry.io/issues/7772715813/), [2H](https://sorty-z1.sentry.io/issues/7772824312/), [3G](https://sorty-z1.sentry.io/issues/7804585544/) | Timeout, local Ollama connection failure, exhausted quota, and provider HTTP 503. These identify failed dependencies, not an established app defect. |
| [3M](https://sorty-z1.sentry.io/issues/7809724264/) | Preview regeneration skipped first-use preparation. The preview button and menu command now prepare the client through AppState before regeneration. See follow-up below. |
| [3H](https://sorty-z1.sentry.io/issues/7809612745/), [23](https://sorty-z1.sentry.io/issues/7751822643/) | Window-system waits and SwiftUI samples; see the existing 24 October triage. No safe new hang fix follows from these samples. |
| [3F](https://sorty-z1.sentry.io/issues/7799784986/) | Fallback SF Symbol construction inside `MenuBarLabel.init`. Cache the fallback once instead of resolving it on every view initialization. This removes repeated work on the sampled path; it does not establish the cause of the entire hang interval. |
| [3E](https://sorty-z1.sentry.io/issues/7799772394/), [P](https://sorty-z1.sentry.io/issues/7646141334/) and older hangs | Keep open pending a representative trace and post-fix release evidence. Prior duplicate-scan mitigations are documented in the 13 October triage. |
| [2J](https://sorty-z1.sentry.io/issues/7780212160/), [2N](https://sorty-z1.sentry.io/issues/7783850830/), [2S](https://sorty-z1.sentry.io/issues/7786696259/), [2X](https://sorty-z1.sentry.io/issues/7786796652/), [2K](https://sorty-z1.sentry.io/issues/7783847930/), [2M](https://sorty-z1.sentry.io/issues/7783848052/) | Prior toolbar, display-name, async-open, apply-diagnostic, and duplicate-reporting fixes remain on main. No newer build evidence establishes resolution. |
| [2T](https://sorty-z1.sentry.io/issues/7786706059/) | Expected diagnostic-export marker. |

The older [2B feedback](https://sorty-z1.sentry.io/issues/7761042269/) says the
app crashes constantly, without reproduction steps or a linked crash event.
Its associated event is a report marker, not a crash stack. The development
[25 feedback](https://sorty-z1.sentry.io/issues/7757464036/) is similarly broad.
Neither supports another speculative runtime patch.

No Sentry issues were resolved or muted. No local builds, tests, or computer-use
verification were run for the small URL fix, per repository instructions.
The regression test is added but unexecuted; no hosted CI or runtime pass is
claimed. Existing uncommitted 24 October triage notes were preserved.

## Root-cause follow-up

Refreshed the production query, which returned 46 unresolved issue groups, and
retrieved their latest complete events. No newer production build was present
in the reviewed recent groups. The feedback review above remains separate from
this error-group query.

### Regeneration without a client

The captured error identifies `performRegeneratePreview`'s missing-client
guard. Current source supplies a concrete route to that failure: restoring a
ready preview deliberately creates no AI client, and both the preview button
and menu command previously called the organizer directly. The Organize action
already used first-use preparation, but regeneration bypassed it.

Both regeneration controls now use `AppState.regenerateCurrentPreview()`. It
prepares the current directory, checks cancellation, then verifies that the
organizer, plan, and directory still match before starting regeneration. Menu
failures now reach the same error state instead of being discarded by `try?`.
No authentication or client creation was added to launch.

The regression reproduces `clientNotConfigured` with preparation omitted. It
also covers replacement of a preview during preparation. This proves the source
defect and repair, without claiming that restoration was the original user's
exact sequence.

### Menu-bar image construction

[3F event 6fb047da314f4a9f8bdbd85e6cafc0c4](https://sorty-z1.sentry.io/issues/7799784986/events/6fb047da314f4a9f8bdbd85e6cafc0c4/)
samples `MenuBarLabel.init`, `NSImage` symbol construction, and CoreUI glyph
resolution. `@State` retains its storage, but its initial-value expression still
runs when the enclosing view struct is initialized. The label now shares one
fallback image. Activity-driven asynchronous PNG loading and accessibility
labels remain unchanged.

The adjacent 3E and P samples share that trace and show SwiftUI menu construction
and native save-panel setup. No duplicate-hash workers appear in these events.
Their 8 GiB Mac has little reported free memory, but the snapshots do not prove
memory pressure or identify why framework calls were slow. Caching removes
repeated work; a system trace is still needed before declaring the hang fixed.

### Remaining evidence limits

- 2R/2V and 2G/2W have no request provider/model, response structure, or safe
  provider reason in their retained contexts or lifecycle breadcrumbs. Their
  error statuses and sampled reporting stacks cannot identify a unique cause.
- 23/3H show WindowServer waits and SwiftUI work. Changing the sampled button
  style would not address an established root cause.
- The latest P sample waits while AppKit initializes a native save panel. It
  does not identify an expensive Sorty caller. Moving AppKit UI construction to
  a worker would violate its threading contract.
- 24's older Keychain hang originated in the Learnings view's synchronous cold
  profile load. The current view awaits the asynchronous loader. The event does
  not test that newer path.
- Network outages, a stopped local server, exhausted provider quota, and provider
  HTTP 503 require dependency recovery. Retry handling already exists; endless
  retries would not remove those causes.

These groups stay unresolved. A new release containing the source fixes, followed
by recurrence monitoring and targeted system traces, is required to assess
production recovery. No release or Sentry status change was performed.

### Validation

The follow-up changes affect first-use lifecycle behavior, so focused regression
checks were run. With preparation omitted, the new regeneration regression
failed with `clientNotConfigured`. With the fix present, five focused tests
passed: first-use regeneration, preview replacement during preparation, existing
regeneration cancellation, and the two Gemini URL checks.

Concurrent uncommitted work initially prevented the fixed test build. The
passing run used a temporary `git archive` source export containing HEAD plus
only this thread's four source/test patches. It did not create a branch or
worktree, modify the other work, launch the app, or exercise a real AI account.
The same run compiled the app target, including the menu-bar change. This is
source/build evidence, not a production hang reproduction or hosted CI result.

[Blacksmith Swift CI 40159141663](https://github.com/sorty-organizer/Sorty/actions/runs/40159141663)
for `6edffc6c` passed secret scanning, cache checks, fuzzing, test compilation,
and the app build. The test step failed in the unchanged
`WindowSessionTests.testSettingsSectionRoutingAppliesExpectedViewAndFocus`:
the table expects watched-folder aliases to select `.rules`, while the current
router selects `.automation`. Both the router and those expectations predate
this commit. The new regeneration tests did not fail. Full hosted CI is red,
and pre-release validation was skipped. The unrelated routing test was left
unchanged.

## Diagnostic logging follow-up

Commit `e44c4c6e` adds a typed, privacy-filtered request snapshot to handled
errors, model-list failures, and batch breadcrumbs. It records provider and
endpoint category, request settings, file/attachment counts, and adaptive retry
depth. Fixed allowlists retain safe provider codes and decoding hints. Raw model
IDs, custom endpoint URLs, credentials, filenames, prompts, and response bodies
are excluded. Workflow and navigation breadcrumbs add activity context to future
hang reports. The readable titles, fault taxonomy, severity mapping, and
`sorty.handled_error.v2` grouping remain unchanged.

All 15 focused checks passed against an isolated source export, covering privacy,
error classification, retry breadcrumbs, and cancellation.
[Blacksmith Swift CI 40160552764](https://github.com/sorty-organizer/Sorty/actions/runs/40160552764)
passed secret scanning, fuzzing, test compilation, and the app build. Its test
step failed only in the same unchanged settings-routing test described above,
with two `.automation` versus `.rules` assertion failures. Full hosted CI remains
red; pre-release validation was skipped. No additional local verification was
run for this documentation update.

The follow-up production CLI inventory contained no event newer than
25 October at 00:21:24 UTC. This is an error-list snapshot, not a complete feedback
inventory. No Sentry status was changed in this follow-up. The added diagnostics
require a shipped build and new events; they cannot enrich historical reports.
