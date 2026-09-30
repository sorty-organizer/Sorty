# OpenCode providers

Sorty shows one OpenCode provider card. Select Zen or Go in API Configuration.
Add the key for each plan in Provider Settings. Sorty stores the keys in separate
Keychain entries. Each model uses its plan's native API endpoint.
Connection checks send a bounded completion to the selected model to validate
the key and model access. These probes can consume a small amount of quota.
The public model-list endpoint alone cannot validate credentials.

Settings and onboarding offer **Use OpenCode credentials** alongside the manual
key field and an [OpenCode sign-in link](https://opencode.ai/auth). First connect
the selected plan with `opencode auth login`, then import its key. The import is
an explicit snapshot into Sorty's Keychain; reconnecting or rotating a key in
OpenCode requires another import. It does not install or start OpenCode.

The reader uses `OPENCODE_AUTH_CONTENT` when set, otherwise
`$XDG_DATA_HOME/opencode/auth.json` or `~/.local/share/opencode/auth.json`.
It selects `opencode` for Zen and `opencode-go` for Go, accepts only `type: api`
entries, and uses `OPENCODE_API_KEY` when the selected entry has no API key.
Stored API keys take precedence over that environment variable. GUI apps may
not inherit shell environment variables. OAuth tokens for upstream providers
are never imported. Read/decode/Keychain errors leave the existing Sorty key
intact, and no credential file is read at launch.

This follows [T3 Code's OpenCode integration](https://github.com/pingdotgg/t3code/blob/c18e5ea6ed741443a8ec4a5d22d4b6939b0ecd21/apps/server/src/provider/Layers/OpenCodeProvider.ts),
which delegates upstream authentication to OpenCode's CLI/server and uses the
SDK's connected-provider inventory. Its
[Go credential reader](https://github.com/pingdotgg/t3code/blob/c18e5ea6ed741443a8ec4a5d22d4b6939b0ecd21/apps/server/src/provider/Layers/openCodeUsageLimits.ts)
provides the file/environment precedence used here. Sorty continues to call
Zen/Go directly rather than starting an agent server; importing a key does not
prove model access, so use Test Connection after importing.

The card and model picker use OpenCode's Zen and Go marks from its
[MIT-licensed icon set](https://github.com/anomalyco/opencode/tree/dev/packages/ui/src/assets/icons/provider).

When an existing Copilot selection is loaded, Sorty uses the saved automation
provider and model if both are usable. If no usable automation choice exists,
Sorty shows a provider error and asks the user to choose one. Incomplete
automation overrides also show an error instead of selecting a default model.

The model picker includes the live catalog's Chat Completions, Messages,
Responses, and Gemini models. The client routes each model using OpenCode's
plan-specific endpoint table. Qwen3.8 Max and MiniMax use Chat Completions on
Zen but Messages on Go. GPT, Grok, and Muse use Responses; Claude uses
Messages; Gemini uses its native generateContent API. Streaming requests use
the corresponding native events and exclude reasoning text from output JSON.

Jev models remain excluded because their SystemOne protocol is not supported.
Unknown model IDs retain the chat-completions path. Catalog caches from the
old chat-only implementation are discarded once so they cannot hide newly
supported models. Offline fallback lists include examples of supported families.

Go's [V2 documentation](https://opencode.ai/v2/docs/console/go) says clients
should send typical coding agent traffic. Sorty sends file organization
requests. OpenCode may reject this traffic; users should check their plan's
terms before using Go with Sorty.

Sources: [Zen models and endpoints](https://opencode.ai/v2/docs/console/models/),
[Go models and endpoints](https://opencode.ai/v2/docs/console/go).
