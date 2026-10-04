# Sorty skill

The Sorty skill is intended to replace the app's core file workflow with a conversation in your agent. It organizes and renames files using imported preferences, finds exact duplicates, previews and applies reversible plans, and restores its own recorded moves. You can explain your intent and refine a plan before applying it. Once installed, these workflows work without the app. Native features such as Finder integration and background watching still need the app or separate automation.

The introduction states this direction before setup, then explains the conversational workflow, preference import, and when to keep the app. It does not claim complete native feature parity or measured accuracy gains.

## Set up in the app

1. Open Settings > Experimental > Sorty skill.
2. Click Set Up Skill, or Import Settings if it is already installed. Review Setup opens the same flow when another skill is present.
3. Read the introduction, then choose an agent from the row of glass icon tiles. Codex, Claude Code, OpenCode, and Pi use their logos or mark; Other uses a folder icon and opens the folder picker. A checkmark marks the selection, and "Settings found" indicates an existing configuration directory. The installation path updates with your choice. The setup window opens at 780 × 620 points and can be resized. The welcome text stays visible without scrolling; longer configuration steps scroll above navigation. Hovering over Get Started changes the introduction's folder icon to the Sorty app icon.
4. Choose what to share under Preferences, Exclusions, Watched folders, and Learnings. Each category starts with a selection count and Select all action. Click anywhere across the Choose individual settings row to expand or collapse the compact checklist; categories with more than eight items also offer search by name or detail. The checklist is bounded by the space between the heading and navigation, so expanding it keeps the window size and navigation in place. Short checklists open at their content height. Longer checklists show a scrollbar and a Scroll for more cue while items remain below the viewport; the cue disappears at the bottom. The category column and selection summary stay visible while the checklist scrolls. Select all applies to the entire category, including items hidden by search. The sidebar also lets you select or deselect every category at once. Unlock Learnings to review them before selecting.
5. Review the destination and selected settings, then scroll to the bottom of the review, including the import disclosures. Install and Import, or Import Settings for an existing installation, stays disabled until you reach the bottom. If the entire review fits, import is enabled immediately. Returning to Review requires reaching the bottom again. Confirm replacement if another skill occupies the location.
6. The completion screen shows a sample request, Copy Request, and the reimport reminder without scrolling. Copy the request into a new agent chat, then click Done.

Setup opens in its own resizable window with native Liquid Glass on macOS 26. It reuses the onboarding's full-screen backdrop, edge glow, and full-window color field. Each step explains the choice before presenting its controls. The background changes as you advance and stays still between steps. Reduce Motion disables transitions. Reduce Transparency uses a solid background and hides the screen effects. Screen effects also hide when the setup window is inactive. The window stays open after import to explain the next action, and cannot close while an import is in progress.

Choose at least one setting to import. Reimporting replaces the previous imported selection, so include every preference you want the agent to keep using.

Changing headings and action labels use text transitions, selection counts use numeric transitions, and step icons use symbol replacement. Reduce Motion disables these animations.

### Agent locations

The agent row uses 64-point glass tiles and bundled SVG artwork, separate from
the provider logos. Codex's terminal mark and Claude Code's pixel mascot come
from [Lobe Icons](https://github.com/lobehub/lobe-icons/tree/master/packages/static-svg/icons).
OpenCode's light and dark marks come from its
[brand assets](https://github.com/anomalyco/opencode/tree/dev/packages/console/app/src/asset/brand).
Pi uses the compact monochrome badge from its [press kit](https://pi.dev/press-kit).
The SVG sources, vector PDF renderings, and upstream license notices live in
`Resources/Images/AgentIcons`. Icon canvases trim unused padding and share a
centered 32-point area. Render SVG changes with `rsvg-convert --format pdf`,
keeping the original aspect ratio. The UI loads the vector PDFs to avoid AppKit
SVG sizing differences. Codex and Pi follow the text color, OpenCode uses the
matching appearance asset, and Claude Code keeps its original color. Other
keeps the native folder icon.
OpenCode's SVG keeps the original filled paths without redundant clipping or
luminance masks, which can disappear when its PDF is displayed by AppKit.
The welcome folder badge has a small optical offset inside its centered tile.

| Agent | Default skills folder | Environment override |
| --- | --- | --- |
| Codex | `~/.codex/skills` | `CODEX_HOME`, then `skills` |
| Claude Code | `~/.claude/skills` | `CLAUDE_CONFIG_DIR`, then `skills` |
| OpenCode | `~/.config/opencode/skills` | `OPENCODE_CONFIG_DIR`, then `skills`; otherwise `XDG_CONFIG_HOME`, then `opencode/skills` |
| Pi | `~/.pi/agent/skills` | `PI_CODING_AGENT_DIR`, then `skills` |

Sorty checks these configuration directories without launching agents or reading
credentials. A found folder does not prove an agent is installed. Every agent
remains selectable before its folder exists; installation creates the selected
skills folder only when you confirm. Environment overrides apply when inherited
by the Sorty process. For a different shell environment or a project-specific
location, use Choose Folder and select the parent of the `sorty` skill directory.

All choices receive the same portable `sorty/SKILL.md`, supporting scripts, and
selected imported preferences. The locations and format follow the
[Claude Code skills documentation](https://code.claude.com/docs/en/skills),
[OpenCode skills documentation](https://opencode.ai/docs/skills/), and
[Pi skills documentation](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/skills.md).
Pi's user directory and override are defined in its
[configuration source](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/config.ts).
OpenCode's configuration-root precedence is defined in its
[global paths source](https://github.com/anomalyco/opencode/blob/dev/packages/core/src/global.ts).

The review card fits the install location and selected settings. The review content scrolls when it exceeds the available space.

During import, a centered Sorty icon, status message, and indeterminate progress bar replace the review controls. Reduce Motion shows a static status instead. Completion appears only after the import succeeds; failures return to review with an error.

The preferences step uses category navigation and native checkboxes to select:

- naming style, filename formatting, naming instructions, and rename rules;
- whether to open the folder after organization;
- exclusion rules and natural-language exceptions;
- watched-folder paths and their custom prompts;
- learned rules, instructions, corrections, and preferred examples.

Choose **Import nothing** to clear all selections and continue without copying app settings. Review then offers **Install Skill**, or **Finish Setup** if it is already installed. Existing imported settings stay in place.

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
