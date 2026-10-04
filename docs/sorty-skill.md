# Sorty skill

The Sorty skill organizes and renames files through your agent using preferences imported from the app. It can find exact duplicates, preview and apply reversible plans, and restore its own recorded moves.

## Set up in the app

1. Open Settings > Experimental > Sorty skill.
2. Click Set Up Skill, or Import Settings if it is already installed. Review Setup opens the same flow when another skill is present.
3. Read the introduction, then choose the folder where your agent loads skills. The default is Codex's skills folder. Location shows one heading and explanation above the installation path and folder picker. The setup window opens at 780 × 620 points and can be resized; longer steps scroll above the navigation buttons. Hovering over Get Started changes the introduction's folder icon to the Sorty app icon.
4. Choose what to share under Preferences, Exclusions, Watched folders, and Learnings. The compact category column stays visible while the options scroll independently. Select an entire section, the full list, or individual items. Unlock Learnings to review them before selecting.
5. Review the destination and selected settings in the scrollable summary, then click Install and Import, or Import Settings for an existing installation. The summary's glass panel stays fixed while its contents scroll; import details remain visible below it. Confirm replacement if another skill occupies the location.
6. The completion screen gives you a sample request to copy into a new agent chat.

Setup opens in its own resizable window with native Liquid Glass on macOS 26. It reuses the onboarding's full-screen backdrop, edge glow, and full-window color field. Each step explains the choice before presenting its controls. The background changes as you advance and stays still between steps. Reduce Motion disables transitions. Reduce Transparency uses a solid background and hides the screen effects. Screen effects also hide when the setup window is inactive. The window stays open after import to explain the next action, and cannot close while an import is in progress.

Choose at least one setting to import. Reimporting replaces the previous imported selection, so include every preference you want the agent to keep using.

Changing headings and action labels use text transitions, selection counts use numeric transitions, and step icons use symbol replacement. Reduce Motion disables these animations.

During import, a centered Sorty icon, status message, and indeterminate progress bar replace the review controls. Reduce Motion shows a static status instead. Completion appears only after the import succeeds; failures return to review with an error.

The preferences step uses category navigation and native checkboxes to select:

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
