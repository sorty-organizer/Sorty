# OpenCode providers

Sorty shows one OpenCode provider card. Select Zen or Go in API Configuration.
Add the key for each plan in Provider Settings. Sorty stores the keys in separate
Keychain entries. Each model uses its plan's native API endpoint.
Connection checks send a bounded completion to the selected model to validate
the key and model access. These probes can consume a small amount of quota.
The public model-list endpoint alone cannot validate credentials.

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
