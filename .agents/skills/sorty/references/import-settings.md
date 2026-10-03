# Import settings

Run helpers relative to this skill's directory. They use Python 3 and its standard library, without a Sorty checkout, hardcoded username, provider SDK, or hosted service.

## Onboarding

```bash
python3 scripts/sorty_profile.py onboard
```

On macOS, this reads the current user's `com.sorty.app` defaults through `defaults export` and replays `~/Library/Application Support/Sorty/WatchedFolders.jsonl`, including removed folders and global disable events. It also reads unmigrated legacy folders. It never resolves or copies security bookmarks.

Give the user the printed localhost URL, including its fragment token. The page offers individual preference, exclusion, and folder choices, plus Learnings sections and natural-language exceptions. Nothing is selected initially. Exclusion AND groups must be selected together. Review values are available before import. The server stops after import or cancellation. Stop the helper if the user abandons setup.

Learnings at rest are encrypted and may require biometric authentication. Use the app's Learnings export, then include its `.learnings` or JSON archive:

```bash
python3 scripts/sorty_profile.py onboard --learnings /path/to/export.learnings
```

Only organization instructions, inferred rules, correction/rejection/positive examples, and learning exclusion patterns are offered. Session history, consent state, provider credentials, and encryption keys are not imported. The selected Learnings become plaintext local JSON; the page discloses this before selection. A malformed or unsupported export stops setup. This migration accepts supported archive versions but does not reproduce the app's typed archive digest verification.

For another machine or a non-macOS agent, supply a preferences export and the copied Sorty support directory. Paths in imported folders still refer to the original machine. Confirm or remap them before use.

```bash
# Run this on the Mac that has Sorty:
defaults export com.sorty.app /path/to/sorty-preferences.plist
# Run onboarding where the agent lives:
python3 scripts/sorty_profile.py onboard --defaults /path/to/sorty-preferences.plist --support-dir /path/to/Sorty --learnings /path/to/export.learnings
```

The full plist may contain private app data. Transfer it privately and retain it only as long as needed. The onboarding helper only persists allowlisted selections. An exported plist alone can import preferences and exclusions; supply the support directory for current watched folders.

## Saved profile and behavior

The profile is versioned JSON at `~/Library/Application Support/Sorty Skill/profile.json` on macOS and `~/.config/sorty-skill/profile.json` elsewhere. Set `SORTY_SKILL_STATE_DIR` for both helpers to use another location. `--profile` selects an onboarding output or a profile to show; use the environment variable too if subsequent organization helpers should read that location. Reimport replaces the profile after saving a private backup. It never changes app state. Missing app data is shown as empty sections.

```bash
python3 scripts/sorty_profile.py show
```

Use selected settings as defaults for future requests:

- `mode`, smart rename, naming style, filename formatting, and rename rules guide planning. Preserve organize-only and rename-only intent. Disabled smart rename means keep original basenames.
- Deep Scan and vision preferences describe desired analysis, but do not authorize file-content reads or cloud uploads. Ask under the skill's authorization rules.
- Duplicate detection adds exact-byte review; it does not authorize deletion. Finder tagging remains native.
- `openFolderAfterOrganization` comes from `automation.autoSelectOrganizedFolders`. After a fully successful apply, open the source root in the OS file manager when true. On macOS use `open` with the exact path as a separate argument. A false or absent value means do not open automatically. Report an opening failure separately from the file operation. The skill opens the root; it does not recreate Sorty's multi-folder Finder selection.
- Saved watched folders retain their path, prompt, mode, enabled/snoozed state, delay, and apply policy. Use the matching folder's prompt and mode when the user asks to organize that folder. Imported automatic-apply settings do not authorize autonomous organization. Background watching or recurring runs need explicit setup in the agent's environment.
- Learnings guide placement and naming. Respect rejected/inactive rules and confidence. Learning exclusion patterns prevent learning from those files; they are distinct from organization exclusions. Natural-language exceptions need the agent to identify matching items and leave them unorganized. If their meaning is unclear, stop before apply and clarify.

The filesystem helper automatically enforces enabled imported extension, filename, folder-name, path, hidden-file, and system-file exclusion rules, including negation and AND groups. It checks protected descendants before moving a directory. Other enabled rule types block scans, duplicate discovery, validation, and apply until the user resolves them or chooses native Sorty. Do not quietly drop a rule or disable it. Even if strict exclusions are off in the app, imported protections remain enforced by the skill.

The helper does not execute imported prompts, custom scripts, or provider configuration. Credentials, access grants, and background services belong to the environment running the agent.
