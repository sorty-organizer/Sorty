# Sorty skill for agents

The Sorty skill lets an agent handle file-organization requests with Sorty's
safety boundaries. It builds and applies reversible filesystem plans directly.
Selected app preferences, exclusions, watched-folder configurations, and
exported Learnings can move into a separate skill profile. Python 3 is the only
helper dependency. The skill can run in Codex, Claude Code, or another agent
with filesystem and terminal access.

The tracked skill lives in [`.agents/skills/sorty`](../.agents/skills/sorty/).
That directory is the source of truth for the skill and its helper.

## What it can do

Ask `$sorty` to:

- organize files without renaming them;
- rename files without moving them;
- organize and rename in one plan;
- scan for byte-identical duplicates;
- preview, validate, and apply a proposed plan;
- roll back moves and renames recorded by the skill;
- import selected app settings through a local onboarding page;
- open the relevant Sorty screen for exclusions, personas, Learnings, watched
  folders, storage locations, history, settings, or duplicate review.

The fallback handles local scanning, SHA-256 duplicate checks, collision-safe
moves and renames, cross-volume verification, append-only journals, and
rollback. It does not recreate the macOS app. Sorty still owns Finder actions,
Finder tags, semantic duplicate review, background watching, widgets, HUD
notifications, interactive previews, provider credentials, Keychain access,
Learnings security, updates, and diagnostics.

## Install the skill

Codex discovers personal skills under `~/.codex/skills`. Link the repository
copy so edits remain tracked in Git:

```bash
ln -s "/absolute/path/to/Sorty/.agents/skills/sorty" ~/.codex/skills/sorty
```

Do not replace an existing `~/.codex/skills/sorty` entry until you have checked
where it points. Restart Codex if the skill does not appear after installation.

Repository contributors can inspect the skill directly without creating the
personal link.

For Claude Code, copy the complete `sorty` directory into
`~/.claude/skills/sorty`, following its
[personal skill convention](https://code.claude.com/docs/en/skills#choose-where-skills-load).
Other agents can load `SKILL.md` and run the bundled
helpers. Copy the scripts, assets, and references together, not just the entrypoint.

## Import your app settings

From the installed skill directory, run:

```bash
python3 scripts/sorty_profile.py onboard
```

Open the printed local URL. Review the saved values and select individual
preferences, exclusions, and folders. Nothing is selected by default. Click
Import to save the selected settings. Cancelling leaves the skill profile
unchanged. Reimport backs up the previous profile before replacing it.

To include Learnings, export your profile from Sorty's Learnings page and run:

```bash
python3 scripts/sorty_profile.py onboard --learnings /path/to/export.learnings
```

Learnings are encrypted in the app. This flow uses its authenticated export
and stores the selected instructions and examples as private local plaintext
JSON. It does not import consent, credentials, bookmarks, or session history.

On macOS, settings and watched folders are discovered for the current user.
For another computer, pass `--defaults /path/to/sorty-preferences.plist` and
`--support-dir /path/to/copied/Sorty`. Create the plist on the original Mac with
`defaults export com.sorty.app /path/to/sorty-preferences.plist`. Imported paths
may need remapping. Keep transferred app data private.

The profile lives in `~/Library/Application Support/Sorty Skill/profile.json`
on macOS and `~/.config/sorty-skill/profile.json` elsewhere. Both helpers honor
`SORTY_SKILL_STATE_DIR`. The agent reads this profile before planning and uses
preferences such as naming style and opening the folder after organization.
Imported exclusions are enforced during scans and apply validation. Unsupported
enabled exclusion types block agent work until resolved. Natural-language
exceptions are evaluated by the agent before it builds a plan.

Watched folders import as saved configurations. Importing does not create a
background watcher or authorize scheduled work. See the
[import reference](../.agents/skills/sorty/references/import-settings.md) for
setting semantics, portable imports, and limitations.

## Use it

Codex can select the skill automatically for file-organization requests, or you
can invoke it explicitly:

```text
Use $sorty to organize my Downloads folder without renaming anything.
Use $sorty to preview cleaner names for the files in this folder.
Use $sorty to find exact duplicates here.
Use $sorty to open Sorty's watched-folder settings for this folder.
Use $sorty to roll back the last plan it applied.
```

Wording controls whether the request is read-only. "How would you organize
this?" and "suggest a structure" request a preview. "Organize this folder" or
"apply this plan" authorizes the listed non-destructive moves and renames.

The skill asks separately before it deletes or trashes duplicates, overwrites
or merges a destination, resolves an ambiguous collision, sends file contents
to a cloud model, or clears saved Sorty data.

## Native app or agent fallback

| Request | Execution path |
| --- | --- |
| Organize or rename local files | Agent by default, native Sorty when requested |
| Find exact duplicates | Agent by default, native Sorty when requested |
| Import saved preferences, exclusions, folders, or exported Learnings | Local onboarding and agent profile |
| Review similar files visually | Native Sorty |
| Edit an interactive preview | Native Sorty |
| Change Finder tags | Native Sorty |
| Manage watched folders, personas, Learnings, providers, or storage | Native Sorty |
| Roll back work | The path that originally applied the work |

Native workflows open through Sorty's `sorty://` deeplinks. Opening a screen is
not proof that the operation finished. Sorty may still need a permission,
provider configuration, review, or final Apply action.

The app and the skill keep separate histories. Sorty's History restores work
applied by the app. The agent fallback restores only operations recorded in its
own journal under `~/Library/Application Support/Sorty Skill/`.

## Safety model

The skill resolves the exact source folder before applying a plan. It rejects a
filesystem root, a home directory, and unresolved path variables as apply
roots. It inventories first, preserves hidden files and packages by default,
honors exclusions, and refuses silent overwrites.

Every considered item belongs in the plan or appears as unorganized with a
reason. Existing timestamps, extended attributes, and Finder tags move with a
file unless the request explicitly changes them.

Exact duplicates mean identical bytes confirmed with SHA-256. Similar names,
sizes, dates, images, or model judgments are not proof that files are exact
duplicates.

## Maintaining the skill

Keep the entrypoint concise and route detailed behavior through its reference
files:

- [`SKILL.md`](../.agents/skills/sorty/SKILL.md) defines routing and authorization.
- [`capabilities.md`](../.agents/skills/sorty/references/capabilities.md) maps
  Sorty features to native or agent execution.
- [`native-routing.md`](../.agents/skills/sorty/references/native-routing.md)
  records the supported deeplinks.
- [`agent-mode.md`](../.agents/skills/sorty/references/agent-mode.md) defines the
  plan, journal, apply, and rollback contracts.

When Sorty gains a user-facing capability, update the capability map and check
whether the app's deeplink contract also changed. Run the skill validator and
the focused helper tests after changing behavior. Documentation-only edits do
not require an app build.
