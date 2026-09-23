# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.1] - 2026-09-23

### New

- Updated the main Sorty app icon with the new release artwork.
- Added in-app support checks and clearer diagnostics for watched folders and Finder integration.

### Improved

- Cut median time to the first visible window from 2,262 ms to 1,127 ms in a same-machine Release comparison with eight runs per build.
- Reduced settled idle CPU from a 51.4% mean to 0% in a 60-second visible-window test with no animated HUD. Minimized-window idle CPU also fell from about 55% to 0%; with an animated HUD, measured CPU was 16.5%, about three times below the previous idle result.
- Capped organization prompts for very large folders. In a 1,000-file deep-scan benchmark, the prompt fell from 132,059 tokens to 11,961, and preparation time fell from 12.1 ms to 5.0 ms. At 200 files, prompt size fell 56%; at 350 files, 74%; and at 500 files, 82%.
- Reduced repeated context in multi-batch AI requests by 81% in a 1,050-file benchmark, and cut repeated text-feature work in the duplicate-detection benchmark by 86%.
- Cut progress-line parsing work by 45%, removed repeated full-list scanning from the 120-frame flight queue benchmark, and reduced 100 Unicode stream-counting runs from 40.6 seconds to about zero.
- Reduced repeated work during organization, AI streaming, duplicate review, and persisted-state loading.

### Fixed

- Fixed organization, cancellation, and undo edge cases, including overlapping runs.
- Fixed Finder action routing, permission recovery, provider errors, and stale status after configuration changes.

## [1.2.0] - 2026-07-11

### New

- **Cloud and External Storage Organization** — Organize supported Google Drive, external-drive, and cross-volume destinations with provider-aware actions, capacity checks, and atomic transfers.
- **AI Clarification Before Improve** — Let Sorty ask a focused follow-up question when an instruction needs more detail before it rewrites the prompt.
- **Expanded Generation Stats** — Inspect model, provider, token, timing, throughput, retry, file, data-volume, and estimated-cost details, then copy the full summary when troubleshooting.
- **Finder Integration Diagnostics** — See whether the correct Finder extension is registered and active, with heartbeat monitoring and recovery for stale installations.
- **Sensitive Action Protection** — Optionally require authentication before revealing secrets, changing network privacy settings, or deleting usage data.
- **Privacy-Safe Paths** — Usernames are masked in file paths shown on privacy-sensitive screens and logs.

### Improved

- **Focused Organization Experience** — Streamlined the app around organization, duplicates, exclusions, watched folders, history, and passive learnings, with clearer Organize Only, Organize & Rename, and Rename Only flows.
- **Measured Progress and Live Movement** — Image analysis now reports completed work, indeterminate stages no longer show invented percentages, and file movement stays visually prominent while organization is running.
- **Native Mac Design** — Refined onboarding, What’s New, organization, duplicates, storage locations, watched folders, settings, and support with native Liquid Glass controls, larger click targets, calmer spacing, and smoother motion.
- **Smarter Organization Decisions** — Improved prompts, image analysis, retries, OpenRouter compatibility, storage destination normalization, and preference attribution for more reliable plans.
- **Cloud and Finder Reliability** — Moved storage discovery off the main actor and strengthened cloud scanning, Finder actions, volume handling, reference folders, file watching, rollback behavior, and unavailable-file reporting.
- **Learnings and History Portability** — Hardened profile transfer and history import/export while keeping learnings passive and easier to understand.
- **Performance and Download Size** — Reduced background rendering and unbounded image-cache growth, and removed obsolete bundled resources from the universal download.
- **Updates and Downloads** — Standardized the universal archive as `Sorty.zip`, added guided installation from fresh downloads, and strengthened the Sparkle bridge from 1.1.2 to 1.2.0.

### Fixed

- **Fresh-Download Installation and Launch** — Sorty can move itself into Applications, clear quarantine during that move, reopen the installed copy, and recover a visible main window instead of appearing to launch silently.
- **In-App Update Safety** — Fixed live bundle-replacement crashes and hardened the packaged-release smoke test so updates from 1.1.2 install the refreshed 1.2.0 build through Sparkle.
- **Finder Extension Recovery** — Fixed stale, duplicate, or mismatched Finder registrations, background-agent label collisions, right-click action routing, and unsupported-volume handling after upgrades.
- **Storage Safety** — Fixed partial cross-volume moves, insufficient-capacity handling, cloud metadata failures, and unavailable storage destinations so operations fail safely.
- **Analysis and Generation Feedback** — Fixed image-analysis results and progress reporting, generation handoff flashes, movement-stage timing, and copyable statistics so the UI reflects work Sorty has actually completed.
- **AI, Organization, and History Reliability** — Fixed malformed OpenRouter JSON handling, Improve-popover crashes, rename prompt leakage, history CSV typing, and import/export edge cases.
- **Compatibility and Lifecycle Stability** — Fixed macOS 15 compile blockers, onboarding window layering and accessibility behavior, main-window restoration, and several background-automation edge cases.

## [1.1.2] - 2026-03-01

### Added

- **Preview Learnings Capture** — Sorty now records accepted placements, manual moves, rejections, and rename feedback directly from the preview workflow to improve future suggestions.
- **Automation Coverage Tests** — Added deeplink tests for exclusions, scan, and storage routes, plus case-insensitive host matching.
- **Settings Navigation Tests** — Added search matching and settings focus-target tests across Help/Rules sections and deeplink aliases.
- **Agent Guides** — Added dedicated Finder Integration and Xcode Project guides under `docs/agent-guides/`.
- **Build Performance Optimizations** — Added `--skip-update` and linker deduplication skipping for faster debug builds.
- **Git Info Injection Toggle** — Made git commit info injection skippable via `SKIP_GIT_INJECT=true` for rapid development loops.
- **Folder Watcher Reliability** — Added `refreshSnapshot()` method for precise baseline updates after in-app file operations.
- **Internal Move Detection** — Folder watcher now detects and ignores internal file moves within watched directories to prevent false triggers.
- **Self-Event Filtering** — Folder watcher ignores file system events generated by Sorty itself to reduce noise.
- **About View Polish** — Added hover effects, haptics, and glass background support for macOS 26+ in the About window.
- **Rendering Optimizations** — Switched shimmer effects and progress indicators to `drawingGroup()` for smoother animations.

### Changed

- **Streamlined Analysis View** — Consolidated the analysis stage into a clean, distraction-free interface.
- **Simplified Preview Tree** — Refined the folder and file preview with a cleaner UI and removed legacy destination picker and validation overlays.
- **Cleaned Up Settings** — Removed redundant vision-specific batching and OCR language options from organization strategy.
- **Duplicate Files Landing Experience** — Reworked the no-directory state with a full base page and clearer call-to-action flow.
- **Onboarding Responsiveness** — Tightened layout spacing and improved text scaling/truncation across Welcome, Demo, Feature Tour, and Completion steps.
- **Help & Support Card Refresh** — Redesigned support links into compact icon actions with improved hover/tap feedback and haptics.
- **Learnings Terminology** — Updated the impact metric label from "Rejected" to "Reverted" for clearer intent.
- **Release Pipeline Simplification** — GitHub Actions now builds/releases a single universal artifact (`Sorty-universal.zip`), and CI Make targets now forward legacy arch-specific commands to universal builds.
- **Build Script Cleanup** — Removed explicit `PRODUCT_NAME` override from Xcode build scripting to align with target defaults.
- **Copyright Refresh** — Updated copyright display to 2026 in app/docs surfaces touched by this release.
- **CI Build Process** — GitHub Actions now builds all products first before running tests for better validation coverage.
- **History View Defaults** — Watched folder automations are now shown by default in the history view.
- **Sparkle Update Channels** — Updater now allows all update channels instead of restricting to default only.
- **About Window Styling** — Enhanced window appearance with transparent titlebar and background effects for macOS 26+.

### Removed

- **Sorting Lab and AI Console** — Removed immersive spatial visualization and live console logging to focus on the streamlined workflow.
- **Manual Rename and Rename Summary** — Simplified the preview experience by removing manual steering and batch rename review panels.
- **Quick Rename Mode** — Removed the specialized rename-only mode in favor of a unified organization flow.
- **Accidental Workspace Artifact** — Removed stray `To solve the compound inequality.txt` from the repository.

### Fixed

- **Preview Feedback Reliability** — Fixed learnings capture timing so preview corrections and rename decisions are recorded before plan mutations.
- **Automation Reliability** — Replaced pause/resume cycles with targeted snapshot refreshes to prevent missed events during organization operations.

## [1.1.1] - 2026-02-13

### Added

- **Delete All Data** — New option in Troubleshooting settings to completely wipe usage history, watched folders, and local caches for a fresh start.

### Changed

- **Improved Reset Flow** — The "Reset All Settings" action now returns you to the onboarding experience immediately, eliminating the need for an app restart.
- **URL Normalization** — Custom AI provider endpoints now automatically handle missing URI schemes (e.g., prepending `https://` if omitted).

### Fixed

- **Session Stability** — Fixed a potential `NSGenericException` crash when changing AI configurations rapidly.
- **Release Integrity** — Resolved issues with code signing entitlements in production builds.
- **UI Polishing** — Fixed a visual artifact with the completion checkmark and resolved an issue where the menu bar mascot would fail to load in release builds.

## [1.1.0] - 2026-02-11

### Highlights

**Sorty v1.1** is a major evolution, featuring a complete visual redesign and powerful new ways to automate your digital life. This release introduces **Batch Organization**, **Automated Scheduling**, and a **Redesigned Workspace Health** engine to keep your machine in peak condition.

### Added


- **Naming Presets** — Create reuseable naming schemes for your folders using AI-powered templates.
- **Conflict Resolution Engine** — New UI for handling filename collisions, letting you choose between overwrite, skip, or keep both.
- **CLI Installer** — A one-click setup to install the `sorty` tool to your path, enabling powerful scripting integrations.
- **Sparkle Updates** — Seamless in-app update experience to get the latest features as soon as they drop.
- **Privacy Mode** — New option to blur sensitive paths and hide API keys, perfect for screensharing or streaming.

### Changed

- **Visual Identity (v2)** — A complete branding overhaul including our new mascot, Sorty! The app now features a modern "Glassmorphism" design system.
- **Interactive Onboarding** — A redesigned first-run experience with a simulated demo and narrated walkthrough.
- **Categorized Settings** — A much-needed overhaul of the settings panel, separating AI configuration, automation, and system preferences.
- **Enhanced AI Preview** — Every suggested move now shows "Reasoning Badges" that explain *why* the AI made its decision.
- **Semantic Duplicates** — The duplicate detector now uses lightweight content analysis to find matches that have different filenames.
- **Performance** — Optimized directory scanning engine that is up to 40% faster on large SSDs.

### Fixed

- **Memory Management** — Fixed several leaks in the Folder Watcher during long-running background sessions.
- **Finder Integration** — Resolved communication delays between the Finder Extension and the main application.
- **Notification Persistence** — Fixed an issue where background organization notifications would sometimes fail to appear.

## [1.0.5] - 2026-01-31

## [1.0.4] - 2026-01-29

## [1.0.2] - 2026-01-28

### Fixed

- **CI Test Stability** — Fixed flaky `HistoryTests.testPersistence` test that was failing intermittently in GitHub Actions due to unreliable `UserDefaults.synchronize()` timing. Tests now use isolated UserDefaults suites for deterministic behavior.

## [1.0.1] - 2026-01-28

### Fixed

- **Notification App Icon** — System notifications now consistently display the Sorty app icon. Previously, notifications often appeared without any icon.

## [1.0.0] - 2026-01-27

### Highlights

**Sorty** is a native macOS app that uses AI to organize your files intelligently. Point it at a messy folder, and it will analyze the contents and suggest a clean folder structure based on what's actually in your files—not just their names or extensions.

### Features

- **AI-Powered Organization** — Works with OpenAI, Anthropic, Groq, Ollama, GitHub Copilot, or Apple's on-device Foundation Models. Understands file content, not just filenames.

- **Learnings Profile** — Sorty watches how you organize files and learns your preferences. Over time, its suggestions get smarter.

- **Custom Personas** — Create specialized AI profiles for different workflows. A "Developer" persona organizes differently than a "Photographer" persona.

- **Vision Support** — For AI providers that support it, Sorty can analyze image content when deciding where files belong.

- **Finder Extension** — Right-click any folder in Finder to start organizing.

- **Workspace Health** — Monitor folder health with clutter detection, duplicate scanning, and actionable cleanup suggestions.

- **Interactive Preview** — Review every suggested move before anything happens. Tweak, approve, or reject individual changes.

- **Full Undo** — Every organization is tracked in history. Roll back any operation completely.

- **Watched Folders** — Monitor folders for changes and organize automatically in the background.

- **CLI Tools** — Two command-line utilities: `learnings` for managing your learning profile, and `sorty` for scripting and automation.

- **Deeplinks** — Control Sorty via `sorty://` URLs for Shortcuts, automation, and external integrations.

- **Menu Bar & Keyboard Shortcuts** — Full keyboard navigation with standard macOS shortcuts.

### Requirements

- macOS 15.0 or later
- For AI features: API key for your preferred provider, or Apple Intelligence enabled for on-device processing
