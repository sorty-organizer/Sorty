# Without the Sorty app

Everything here works on a machine without Sorty. Use it when the app is missing, or when the user prefers an agent-only setup. Scripts share the state directory `~/Library/Application Support/Sorty Skill` (override with `SORTY_SKILL_STATE_DIR`), which lives outside the skill folder so skill updates never erase it.

## Fallbacks by feature

| App feature | Agent-only equivalent |
| --- | --- |
| Organize, rename, preview, apply | Agent mode in [agent-mode.md](agent-mode.md) |
| History and undo | `sorty_helper.py history`, then `rollback JOURNAL` |
| Watched folders and background watching | `sorty_watch.py` watchers with an AI handler, optionally installed as a launchd background item |
| Snooze and retry | `sorty_watch.py pause ID --minutes N`, `resume ID`, `run ID` |
| Notify-to-review | Watcher queue plus a desktop notification |
| Finder tags | `sorty_tags.py`, reversible through its tag journal |
| Exclusions | `sorty_profile.py exclude add GLOB`, plus per-scan `--exclude` |
| Learnings | `sorty_profile.py learn add TEXT`, as plain agent-readable lessons |
| Exact duplicates | `sorty_helper.py duplicates` |
| Semantic duplicates | The agent compares candidates it can read, labels them as judgment, and never calls them exact |
| HUD and notifications | `osascript` notifications through watchers; otherwise report in chat |
| Deep Scan and image understanding | The agent's own content reading, under the authorization rules |
| Storage destinations | An explicit absolute destination in the plan |

Personas need no fallback: infer the user's style from how the folder is already organized, its contents, saved preferences, and the request.

Things that stay app-only: the Finder extension and Services menu, menu bar UI, widgets, Sparkle updates, app-managed provider keys in Keychain, Apple Foundation Models through Sorty, and encrypted or biometric-protected Learnings. Say so plainly instead of imitating them.

## Watchers

A watcher notices new items in a folder. It never decides where they go; an AI always does, using the folder's existing organization, the items, and the user's request. There are no predefined rules.

Each run handles the folder's top-level items once:

- An item must be unchanged for `--settle` seconds (default 60). Partial downloads such as `.crdownload` and `.part` wait.
- Items that existed when the watcher was added are baselined and left alone unless `--include-existing` is passed.
- Without a handler, new items are queued and the user gets a notification. The agent organizes them in its next session.
- With a handler, the watcher asks that AI command where the items belong. Review-only watchers, the default, queue its suggestions. With `--apply`, its placements are applied unattended through the helper's validated, journaled apply. Collisions, omitted items, and failures are queued, never forced.

```sh
python3 scripts/sorty_watch.py add ~/Downloads --id downloads --prompt "Keep project files with their project"
python3 scripts/sorty_watch.py run downloads --dry-run
python3 scripts/sorty_watch.py run downloads
python3 scripts/sorty_watch.py queue downloads
python3 scripts/sorty_watch.py queue downloads --resolve "notes.txt"
python3 scripts/sorty_watch.py list
python3 scripts/sorty_watch.py import-profile
```

`import-profile` turns folders imported from the app into review-only watchers with their saved prompts. Import never grants apply.

When the user asks to review a watcher's queue, treat it like any organize request: scan the folder, study how it is already organized, plan the queued items to fit that structure and the watcher's prompt, apply under the normal authorization rules, then `--resolve` the handled items.

### AI handlers

For unattended organizing, set up a handler on the user's machine with `--handler "COMMAND"`. It is usually the non-interactive mode of an agent CLI the user already has, restricted to reading. Check the installed CLI's `--help` for the exact flags. For example:

```sh
python3 scripts/sorty_watch.py add ~/Downloads --id downloads --apply \
  --handler "claude -p --allowedTools Read,Glob,Grep --output-format text"
python3 scripts/sorty_watch.py add ~/Downloads --id downloads --apply \
  --handler "codex exec --sandbox read-only -"
```

The handler runs in the watched folder and receives one JSON request on stdin:

- `task`: the organizing instructions and reply format;
- `structure`: a sample of existing folders and file names, two levels deep, so the AI can match the user's style;
- `items`: the new items with kind, size, and modification time;
- `prompt`, `preferences`, and `learnings` from the watcher and the skill profile.

It replies with JSON. Prose or a code fence around it is tolerated.

```json
{"operations": [{"source": "Invoice March.pdf", "destination": "Finance/2026/invoice-march.pdf"}], "unorganized": [{"path": "x.bin", "reason": "unknown format"}]}
```

The watcher, not the handler, does the moving. Snapshots are taken before the handler runs, so a handler that edits files itself fails validation. Sources it was not offered are rejected. Extension changes, escapes from the folder, and overwrites are refused. Omitted items are queued. A handler that crashes, times out (`--handler-timeout`, default 600 seconds), or prints no JSON queues its items and reports an error.

A cloud-model handler that can read file contents is sending contents to a cloud model, so it needs that approval as well. Show the user the exact command, then run `run ID --dry-run` and walk through the suggestions before enabling `--apply`. If the user explicitly asks for a deterministic script instead of a model, the agent may write one that speaks the same JSON protocol. Base it on the folder's actual structure and keep it in the state directory, never in the watched folder or the skill.

### Background items

`install ID` writes a per-user launchd agent, `~/Library/LaunchAgents/com.sorty.skill.watch.ID.plist`. It runs the watcher when the folder changes, on its `--interval` timer (default 30 minutes), and at login. Background runs wait briefly for in-flight downloads. The item keeps the PATH from the moment of install, so the handler's tools still resolve. `uninstall ID` removes only the launchd agent; `remove ID` also deletes the watcher's config and queue. Apply journals are kept either way.

- Installing a background item is a persistent system change. Get explicit approval, and name the folder, the handler, and whether it will apply unattended.
- macOS shows a "Background Items Added" notice. The item appears in System Settings > General > Login Items & Extensions.
- Protected folders such as Downloads, Desktop, and Documents may need the Python binary in the plist, and the handler's CLI, to have Full Disk Access or Files and Folders access. If `status` shows a permission error in `last_run`, explain that and point to Privacy & Security; never work around TCC.
- Check health with `status ID`: `background_loaded`, `last_run`, `queue_count`, and the `background.log` path.
- Off macOS, `install` prints a crontab line instead of changing anything.

## Finder tags

```sh
python3 scripts/sorty_tags.py show FILE ...
python3 scripts/sorty_tags.py set FILE ... --add Red --add "Client:blue" --remove Draft
python3 scripts/sorty_tags.py restore TAG_JOURNAL.jsonl
```

Colors are `none`, `gray`, `green`, `purple`, `blue`, `yellow`, `red`, and `orange`. A tag named after a color gets that color. Existing tags are kept unless removed. Tag changes are a separate step after a move apply, use the files' final paths, and need the same authorization as the moves. `restore` skips items whose tags changed since.

## Exclusions and Learnings

```sh
python3 scripts/sorty_profile.py exclude add "*.key"
python3 scripts/sorty_profile.py exclude add "*/Clients/Private/*"
python3 scripts/sorty_profile.py learn add "Invoices go under Finance/<year>"
python3 scripts/sorty_profile.py learn remove ID
```

A glob without `/` matches item names; a glob with `/` matches absolute paths. Agent exclusions apply to every scan, plan, and watcher run alongside imported rules. Record a learning only when the user states a lasting preference or confirms a correction, and keep each one short and factual. `show` lists both as `agentExclusions` and `agentLearnings`.
