# Native Sorty routing

Use the installed app when the user asks for it, or when a request needs something only the app has. Most features also have an agent-only fallback in [without-app.md](without-app.md).

## Availability

Check for `/Applications/Sorty.app`, `~/Applications/Sorty.app`, or a running Sorty process without changing system state. Never open a `sorty://` URL when the app is missing. Do the work with the matching fallback in [without-app.md](without-app.md), and mention the app only for the parts listed there as app-only. Do not stop the whole request because one part needs the app.

Open a native route only when the user's request authorizes opening Sorty. Build URLs with a URL encoder. Never concatenate an unescaped path, persona, prompt, rule, or pattern.

## Deeplink contract

| Request | Route |
| --- | --- |
| Organize or scan | `sorty://organize?path=...&persona=...&mode=...&autostart=true` |
| Duplicate review | `sorty://duplicates?path=...&autostart=true` |
| Open a folder | `sorty://open?path=...` |
| History and rollback UI | `sorty://history` |
| Learnings | `sorty://learnings?action=stats|withdraw|export|import|clear&project=...` |
| Persona creation or selection | `sorty://persona?action=...&prompt=...&generate=true` |
| Watched folders | `sorty://watched?action=add|remove&path=...` |
| Rules | `sorty://rules?action=add&type=...&pattern=...` |
| Exclusions | `sorty://exclusions?action=add&pattern=...` |
| Exclude one path | `sorty://exclude?path=...` |
| Storage locations | `sorty://storage?action=add|remove&path=...` |
| Settings | `sorty://settings?section=...` |
| Help | `sorty://help?section=...` |

Supported organization modes are `organize`, `organizeAndRename`, and `renameOnly`. `scan` is an alias that autostarts organization.

Use the `open` command with one fully encoded URL. Opening the app is an external UI action, so follow the current environment's approval rules.

## App-owned data and surfaces

When the app is installed, route these to it instead of editing its data behind its back:

- the app's own watched folders, personas, rules, exclusions, and Learnings. Skill watchers, agent exclusions, and agent Learnings are separate and live in the skill;
- semantic duplicate review with Sorty's visual comparison;
- Finder extension activation or repair;
- provider authentication, Keychain access, Apple Foundation Models, and custom endpoints;
- Learnings encryption, biometric protection, import, export, withdrawal, and clearing;
- interactive preview edits, HUD, widgets, updates, privacy settings, and diagnostics.

Without the app, the Finder extension, menu bar, widgets, updates, app-managed provider keys, and encrypted Learnings are unavailable. Everything else has a fallback.

Do not claim success after opening a route. The app may still require configuration, permission, review, or a final Apply action.
