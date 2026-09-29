## Sorty 1.2.2

New OpenCode provider choices, safer file operations, and optional in-app bug reports.

### New
- Added OpenCode Zen and OpenCode Go as AI provider choices.
- Added an optional in-app bug report form for users who choose to share a report with Sentry. The form can include a report area to help route the issue.

### Improved
- Moved several settings and learnings reads off the main actor so opening those screens does not wait on keychain or profile loading.
- Separated file system, model, AI, learnings, and organization code into smaller modules for maintainability.

### Fixed
- Guarded organization and undo against missing or replaced files, ambiguous paths, and overlapping operations.
- Isolated concurrent AI batch streams and improved recovery from partial renames and cancelled model reads.
- Fixed Finder automation and widget target integration issues.
- Kept internal telemetry separate from user reports and limited bug-report controls to the sharing choice.
