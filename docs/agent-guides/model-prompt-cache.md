# Model prompt caching

Sorty sends reusable system instructions before the changing file list and image attachments. Model prompt caches reuse an identical input prefix; they do not reuse an organization plan or skip analysis of current files.

Claude requests mark the system text block with `cache_control: {"type": "ephemeral"}` for text, vision, and text-generation calls. This uses the provider's default five-minute cache lifetime. The same marker is sent for Claude models routed through OpenCode. Other OpenCode models keep their existing request format because accepting the Messages API does not imply support for Claude's cache controls.

File listings use path order, with deep-scanned files first when content metadata is enabled. Equal-count summaries sort by name. Directory manifests also use a fixed path order. This keeps unchanged inputs stable across filesystem enumeration orders and makes metadata budget selection repeatable.

Cache hits still depend on the provider, model, minimum prefix length, request timing, and unchanged instructions. A changed persona or system override changes the cached prefix. Cache writes can cost more than ordinary input tokens, so Sorty caches reusable instructions rather than each changing file batch. No measured hit-rate or latency improvement is claimed by this change.

References: [Claude prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching), [OpenAI prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching).
