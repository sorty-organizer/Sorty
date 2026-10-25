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
| [3M](https://sorty-z1.sentry.io/issues/7809724264/) | Preview regeneration without a configured AI client. Investigate restoration and first-use preparation; no causal startup change is established by the captured stack alone. |
| [3H](https://sorty-z1.sentry.io/issues/7809612745/), [23](https://sorty-z1.sentry.io/issues/7751822643/) | Window-system waits and SwiftUI samples; see the existing 24 October triage. No safe new hang fix follows from these samples. |
| [3E](https://sorty-z1.sentry.io/issues/7799772394/), [3F](https://sorty-z1.sentry.io/issues/7799784986/), [P](https://sorty-z1.sentry.io/issues/7646141334/) and older hangs | Keep open pending a representative trace and post-fix release evidence. Prior duplicate-scan mitigations are documented in the 13 October triage. |
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
