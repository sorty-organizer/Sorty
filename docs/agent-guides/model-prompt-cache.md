# Model prompt caching

Sorty sends reusable system instructions before the changing file list and image attachments. Model prompt caches reuse an identical input prefix; they do not reuse an organization plan or skip analysis of current files.

Claude requests mark system text blocks with `cache_control: {"type": "ephemeral"}` for text, vision, and text-generation calls. Organization requests with a persona use two blocks: base instructions, then persona instructions. Each has a cache breakpoint, so changing a persona can still reuse the base prefix, while subsequent batches can reuse both. This uses the provider's default five-minute cache lifetime. The same markers are sent for Claude models routed through OpenCode. Other OpenCode models keep their existing request format because accepting the Messages API does not imply support for Claude's cache controls.

The shared organization prompt places reusable tagging, mode, and rename guidance before task instructions, learnings, storage destinations, and existing-folder context. These sections keep their stated instruction priorities. This extends the stable prefix across batches for providers that cache automatically, including OpenAI. File-dependent custom naming examples can still limit reuse in rename modes.

## Other providers

- Direct OpenAI requests to `api.openai.com` send a stable `prompt_cache_key` derived from a SHA-256 hash of the system text. This helps cache routing on older models; newer models handle routing automatically. The key contains no raw instructions, filenames, or credentials.
- OpenRouter requests send that same stable value as `session_id`. It keeps requests with the same system instructions on a warm provider across changing file batches, retries, and recreated clients. This applies to all routed models, including OpenAI, Gemini, DeepSeek, and Z.AI. Provider fallback remains enabled, and provider errors can still change routing. OpenRouter's session log groups requests that share this key, including separate Sorty runs with identical instructions.
- Direct Gemini and Gemini through OpenCode retain automatic caching. They use the shared stable-prefix ordering without Claude cache parameters or explicit cache creation and storage fees.
- Groq, Ollama, and custom OpenAI-compatible endpoints also receive the deterministic shared prompt. Sorty sends no undocumented cache parameters to these endpoints; actual reuse depends on their serving implementation.

Routing keys do not include the file list or a per-client UUID, because both would prevent reuse across batches. Different models remain separate provider cache scopes. Changing system instructions produces a new key.

File listings use path order, with deep-scanned files first when content metadata is enabled. Equal-count summaries sort by name. Directory manifests also use a fixed path order. This keeps unchanged inputs stable across filesystem enumeration orders and makes metadata budget selection repeatable.

Cache hits still depend on the provider, model, minimum prefix length, request timing, and unchanged instructions. A system override changes the base prefix; a persona change changes the second prefix. Cache writes can cost more than ordinary input tokens, so Sorty caches reusable instructions rather than each changing file batch. No measured hit-rate or latency improvement is claimed by these changes.

References: [Claude prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching), [OpenAI prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching), [OpenRouter prompt caching and sticky routing](https://openrouter.ai/docs/guides/best-practices/prompt-caching), [Gemini context caching](https://ai.google.dev/gemini-api/docs/caching).
