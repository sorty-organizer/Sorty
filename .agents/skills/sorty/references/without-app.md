# Without the Sorty app

Everything here works on a machine without Sorty. Use it when the app is missing, or when the user prefers an agent-only setup. Scripts share the state directory `~/Library/Application Support/Sorty Skill` (override with `SORTY_SKILL_STATE_DIR`), which lives outside the skill folder so skill updates never erase it.

## Fallbacks by feature

| App feature | Agent-only equivalent |
| --- | --- |
| Organize, rename, preview, apply | Agent mode in [agent-mode.md](agent-mode.md) |
| History and undo | `sorty_helper.py history`, then `rollback JOURNAL` |
| Watched folders and background watching | `sorty_watch.py` watchers, optionally installed as a launchd background item |
| Snooze and retry | `sorty_watch.py pause ID --minutes N`, `resume ID`, `run ID` |
| Notify-to-review | Watcher queue plus a desktop notification |
| Finder tags | `sorty_tags.py`, reversible through its tag journal |
| Exclusions | `sorty_profile.py exclude add GLOB`, plus per-scan `--exclude` |
| Learnings | `sorty_profile.py learn add TEXT`, as plain agent-readable lessons |
| Personas | Save lasting instructions with `sorty_profile.py set instructions ...` |
| Exact duplicates | `sorty_helper.py duplicates` |
| Semantic duplicates | The agent compares candidates it can read, labels them as judgment, and never calls them exact |
| HUD and notifications | `osascript` notifications through watchers; otherwise report in chat |
| Deep Scan and image understanding | The agent's own content reading, under the authorization rules |
| Storage destinations | An explicit absolute destination in the plan |

Things that stay app-only: the Finder extension and Services menu, menu bar UI, widgets, Sparkle updates, app-managed provider keys in Keychain, Apple Foundation Models through Sorty, and encrypted or biometric-protected Learnings. Say so plainly instead of imitating them.

## Watchers

A watcher is a saved folder with rules. Each run handles the folder's top-level items once:

- An item must be unchanged for `--settle` seconds (default 60). Partial downloads such as `.crdownload` and `.part` wait.
- Items that existed when the watcher was added are baselined and left alone unless `--include-existing` is passed.
- A rule is `GLOB=DESTINATION`. The glob matches the item name case-insensitively and the first match wins. Relative destinations resolve inside the watched folder; absolute ones are user-chosen storage locations.
- Queue-only watchers, the default, only report. With `--apply`, rule matches move unattended through the helper's validated, journaled apply. Collisions, unmatched items, and new folders are queued for review, never forced.

```sh
python3 scripts/sorty_watch.py add ~/Downloads --id downloads \
  --rule "*.pdf=Documents/PDFs" --rule "*.dmg=Installers" --apply \
  --prompt "Group the rest by project"
python3 scripts/sorty_watch.py run downloads --dry-run
python3 scripts/sorty_watch.py run downloads
python3 scripts/sorty_watch.py queue downloads
python3 scripts/sorty_watch.py queue downloads --resolve "notes.txt"
python3 scripts/sorty_watch.py list
python3 scripts/sorty_watch.py import-profile
```

`import-profile` turns folders imported from the app into queue-only watchers with their saved prompts. Import never grants apply.

When the user asks to review a watcher's queue, treat it like any organize request: scan the folder, plan only the queued items using the watcher's prompt, apply under the normal authorization rules, then `--resolve` the handled items.

### Custom routing scripts

When globs cannot express what the user wants, such as renames, dates in names, or routing by filename content, write a small executable script on the user's machine and pass it with `--script PATH`. Keep it in the state directory, for example `~/Library/Application Support/Sorty Skill/scripts/downloads.py`, not inside the watched folder or the skill. Rules run first; items no rule matches go to the script.

The script reads JSON on stdin:

```json
{"source_root": "/Users/me/Downloads", "prompt": "...", "items": [{"path": "Invoice March.pdf", "kind": "file", "size": 1024, "modified_at": "..."}]}
```

It prints:

```json
{"operations": [{"source": "Invoice March.pdf", "destination": "Finance/2026/invoice-march.pdf"}], "unorganized": [{"path": "x.bin", "reason": "unknown"}]}
```

The watcher, not the script, does the moving. It rejects sources it did not offer, queues collisions and omitted items, and sends everything else through the helper's validation, so extension changes, escapes from the folder, and overwrites are still refused. A script that crashes or prints invalid JSON queues its items and reports an error. Keep scripts deterministic, offline, and standard-library only. Never let a script delete, overwrite, or call a cloud model. Show the user the script and run `run ID --dry-run` before enabling `--apply`.

### Background items

`install ID` writes a per-user launchd agent, `~/Library/LaunchAgents/com.sorty.skill.watch.ID.plist`. It runs the watcher when the folder changes, on its `--interval` timer (default 30 minutes), and at login. Background runs wait briefly for in-flight downloads. `uninstall ID` removes only the launchd agent; `remove ID` also deletes the watcher's config and queue. Apply journals are kept either way.

- Installing a background item is a persistent system change. Get explicit approval, and name the folder, rules, and whether it will apply unattended.
- macOS shows a "Background Items Added" notice. The item appears in System Settings > General > Login Items & Extensions.
- Protected folders such as Downloads, Desktop, and Documents may need the Python binary in the plist to have Full Disk Access or Files and Folders access. If `status` shows a permission error in `last_run`, explain that and point to Privacy & Security; never work around TCC.
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
