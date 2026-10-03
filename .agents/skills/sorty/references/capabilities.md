# Capability map

Use this map to route current Sorty behavior. Recheck `README.md`, `CHANGELOG.md`, and the relevant source before updating it because the product changes frequently.

| Capability | Skill path | Boundary |
| --- | --- | --- |
| Organize, rename, organize and rename | Native or agent | Agent mode uses a source-bound JSON plan and the planning quality rules |
| Metadata inventory | Native or agent | Content reads need disclosure and authorization |
| Deep Scan and image understanding | Native preferred | Cloud content transfer needs approval |
| Interactive preview and corrections | Native | Agent mode presents a textual plan |
| Exact duplicates | Native or agent | Agent mode uses SHA-256 |
| Semantic duplicates | Native | Requires Sorty's semantic and visual review |
| Exclusions and "only" matching | Native or agent | Non-matching items stay untouched |
| Finder tags and label colors | Native | Agent mode preserves existing metadata only |
| Personas | Native | Agent may follow temporary instructions without persisting a persona |
| Imported Learnings | Agent | Selected exported instructions and examples guide future plans |
| Passive Learnings | Native | Encryption, consent, and biometric controls stay app-owned |
| Saved watched folders | Agent | Import paths, prompts, modes, and policy through onboarding |
| Background watching | Native or separately configured automation | Import does not start a service or authorize runs |
| Organization preferences | Agent | Select individual settings during onboarding; explicit requests override defaults |
| Storage destinations | Native preferred | Agent mode accepts an explicit absolute destination |
| History and rollback | Native or agent | Histories are separate; agent journals only its own work |
| Finder extension and Services | Native | Route to Finder settings or the matching deeplink |
| Menu bar, shortcuts, deeplinks, widgets | Native | The skill may open routes but does not recreate UI surfaces |
| AI providers and local models | Native | Agent mode uses the active Codex model |
| Privacy, Keychain, permissions, diagnostics | Native | Never imitate security state |
| HUD and native notifications | Native | Do not substitute an inline or textual fake |
| Updates and release management | Native | Sparkle remains app-owned |

When a request crosses paths, split it clearly. For example, agent mode may find exact duplicates, while native Sorty handles visual review and deletion approval.
