# OpenCode providers

Sorty shows one OpenCode provider card. Select Zen or Go in API Configuration.
Add the key for each plan in Provider Settings. Sorty stores the keys in separate
Keychain entries and sends requests to the plan's `/chat/completions` endpoint.
The card and model picker use OpenCode's Zen and Go marks from its
[MIT-licensed icon set](https://github.com/anomalyco/opencode/tree/dev/packages/ui/src/assets/icons/provider).

When an existing Copilot selection is loaded, Sorty uses the saved automation
provider and model if both are usable. If no usable automation choice exists,
Sorty shows a provider error and asks the user to choose one. Incomplete
automation overrides also show an error instead of selecting a default model.

The model picker shows the plan's live `/models` response minus models
documented for non-chat endpoints (Responses, Messages, Gemini-native,
SystemOne), which Sorty's OpenAI-compatible client does not send. Unknown
model IDs stay included so newly added chat models appear without an app
update; only add to the exclusion lists when the endpoint tables document
a model or family as non-chat. The fallback list uses the same
chat-compatible model IDs when catalog refresh is unavailable.

Go's [V2 documentation](https://opencode.ai/v2/docs/console/go) says clients
should send typical coding agent traffic. Sorty sends file organization
requests. OpenCode may reject this traffic; users should check their plan's
terms before using Go with Sorty.

Sources: [Zen models and endpoints](https://opencode.ai/v2/docs/console/models/),
[Go models and endpoints](https://opencode.ai/v2/docs/console/go).
