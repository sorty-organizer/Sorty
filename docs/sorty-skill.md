# Sorty skill

The Sorty skill organizes and renames files through your agent using preferences imported from the app. It can find exact duplicates, preview and apply reversible plans, and restore its own recorded moves.

## Set up in the app

1. Open Settings > Experimental > Sorty skill.
2. Click Install Skill, or Import Settings if it is already installed.
3. Choose the skill location and select what to bring over. Use Select All for a section or the entire list.
4. Click Import Selected.

The import sheet uses the report dialog's rounded header and glass background, with onboarding reveal animation and sound. Background motion settles after the entrance and follows accessibility settings. A completion sound and HUD confirm the import.

The app's normal cards and checkboxes let you select:

- naming style, filename formatting, naming instructions, and rename rules;
- whether to open the folder after organization;
- exclusion rules and natural-language exceptions;
- watched-folder paths and their custom prompts;
- learned rules, instructions, corrections, and preferred examples.

Organization mode, content analysis, and whether to rename are task instructions. Tell your agent what you want when you ask it to organize a folder.

The app reads its own data and writes selected values to `references/imported-settings.json` inside the installed skill. No terminal command, browser page, or manual Learnings export is needed. Learnings use the app's authentication and become readable files in the skill. Credentials, bookmarks, consent state, and session history stay in the app.

Imports leave app data unchanged. Reimport replaces the skill's preferences after keeping a private backup. Updating the skill preserves imported settings. Watched folders are copied as saved paths and prompts; background automation requires separate setup.

## Use the skill

Ask your agent to use Sorty to organize a folder, rename files, review exact duplicates, or restore a plan. The current request takes precedence over imported preferences.

The skill uses a Python 3 filesystem helper for scanning, collision checks, apply journals, and rollback. Python is not used for importing app settings. Hidden files, packages, extensions, existing tags, and excluded items are preserved. Imported exclusions are enforced during scanning and apply. Unsupported enabled rule types block agent work until resolved.

Exploratory requests produce a preview. Requests to organize or apply authorize the listed non-destructive moves. Deletion, overwriting, ambiguous collisions, and cloud content uploads require separate approval.

The app and skill keep separate histories. App History restores app operations. The skill's journals restore only its own operations.

## Maintenance

The tracked skill lives in [`.agents/skills/sorty`](../.agents/skills/sorty/). Copy the entire directory when distributing it. The app bundles this directory and lets users choose its installation location.

- [`SKILL.md`](../.agents/skills/sorty/SKILL.md) defines execution and authorization.
- [`import-settings.md`](../.agents/skills/sorty/references/import-settings.md) defines imported preference behavior.
- [`agent-mode.md`](../.agents/skills/sorty/references/agent-mode.md) defines the plan and journal formats.
- [`capabilities.md`](../.agents/skills/sorty/references/capabilities.md) separates agent work from native integration.

Private imported profiles are excluded from source control and packaged skills. After changing import behavior, check selective export, profile preservation during updates, and exclusion enforcement.
