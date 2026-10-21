# Capability map

Use this map to route current Sorty behavior. Recheck `README.md`, `CHANGELOG.md`, and the relevant source before updating it because the product changes frequently.

| Capability | Skill path | Boundary |
| --- | --- | --- |
| Organize, rename, organize and rename | Native or agent | Agent mode uses a source-bound JSON plan and the planning quality rules |
| Metadata inventory | Native or agent | Content reads need disclosure and authorization |
| Deep Scan and image understanding | Native preferred | Cloud content transfer needs approval |
| Interactive preview and corrections | Native | Agent mode presents a textual plan |
| Exact duplicates | Native or agent | Agent mode uses SHA-256 |
| Semantic duplicates | Native preferred | Without the app, the agent may flag likely matches as judgment, never as exact |
| Exclusions and "only" matching | Native or agent | Non-matching items stay untouched |
| Finder tags and label colors | Native or agent | `sorty_tags.py` writes the tag xattr with a restore journal |
| Personas | Native | The agent infers style from the folder's existing organization, contents, and request instead |
| Imported Learnings | Agent | Selected exported instructions and examples guide future plans |
| Passive Learnings | Native | Encryption, consent, and biometric controls stay app-owned |
| Agent Learnings and exclusions | Agent | `sorty_profile.py learn` and `exclude`, plain JSON in the skill |
| Saved watched folders | Agent | `sorty_watch.py add`, or `import-profile` for imported folders |
| Background watching | Native or agent | `sorty_watch.py install` registers a launchd item; an AI handler decides placements; needs explicit approval |
| Snooze, retry, notify-to-review | Native or agent | Watcher `pause`, `run`, queue, and desktop notifications |
| Naming and completion preferences | Agent | Select in the app; task instructions determine what to do |
| Storage destinations | Native preferred | Agent mode accepts an explicit absolute destination |
| History and rollback | Native or agent | `sorty_helper.py history`; histories are separate and agent journals only its own work |
| Finder extension and Services | Native | Route to Finder settings or the matching deeplink |
| Menu bar, shortcuts, deeplinks, widgets | Native | The skill may open routes but does not recreate UI surfaces |
| AI providers and local models | Native | Agent mode uses the active agent's model |
| Privacy, Keychain, permissions, diagnostics | Native | Never imitate security state |
| HUD and native notifications | Native or agent | Watchers post plain desktop notifications; never fake the HUD |
| Updates and release management | Native | Sparkle remains app-owned |

When a request crosses paths, split it clearly. For example, agent mode may find exact duplicates, while native Sorty handles visual review. When the app is missing, use the agent path for every row that has one. See [without-app.md](without-app.md).
