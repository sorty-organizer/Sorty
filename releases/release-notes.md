## Sorty 1.3.0

Meet the Sorty skill: organize files through your agent, import selected preferences and Learnings, or continue with the native app.

### New
- Added the Sorty skill for Codex, Claude Code, OpenCode, Pi, and custom agent folders. Organize, rename, find exact duplicates, and restore recorded moves through a conversation, without keeping the app installed.
- Added guided skill setup with selective import of preferences, exclusions, saved watched folders, and Learnings. Credentials, bookmarks, consent, and app history stay in the app.
- Added skill-first onboarding with a Continue with App option and optional app removal after skill setup.
- Added OpenCode Zen and OpenCode Go, including reuse of existing OpenCode sign-in credentials.
- Added a drag-to-install DMG and optional in-app Sentry bug reports with an area label.

### Improved
- Refreshed the seven menu bar activity icons and added white mascot and Apple Native icon styles, including matching Finder actions.
- Made internet-blocked cloud providers visibly disabled, with explanations in Settings and onboarding. Local providers remain selectable.
- Reworked preview notices and filename suggestions, and aligned provider authentication controls with History.
- Refined organization prompts and Learnings relevance while keeping generated prompt text out of saved Instructions.
- Moved settings and Learnings reads off the main actor, paused hidden decorative rendering, and isolated watched-folder countdown updates to visible labels.

### Fixed
- Guarded organization and undo against missing or replaced files, ambiguous paths, and overlapping operations.
- Preserved sources edited during cross-volume copies and checked copied children before deleting source trees.
- Isolated concurrent AI batch streams and improved recovery from partial renames and cancelled model reads.
- Fixed Finder routing, widget integration, settings layout overflow, and a launch crash in diagnostic logging.
- Fixed skill setup selection flicker, import transitions, and uninstall recovery when macOS protects app containers.
- Kept internal telemetry separate from user reports and limited bug-report controls to the sharing choice.
