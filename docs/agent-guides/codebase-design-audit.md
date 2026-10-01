# Shallow module audit

Audited 1 October 2026 from `4e652c66` on `main`, using
[mattpocock's codebase-design skill](https://github.com/mattpocock/skills/tree/main/skills/engineering/codebase-design).
These are deletion candidates, not implemented removals. The deletion test asks
whether removing a module eliminates complexity or merely moves it into callers.
Small files alone are not evidence of a shallow module.

## Ranked candidates

### 1. Delete CoordinatedRefreshGroup

`Sources/SortyCore/Managers/RefreshManager.swift:143` adds timer IDs and a weak
manager reference around `schedule`, `cancel`, `pause`, and `resume`.
Its only production caller is `AnalysisRefreshManager` in
`Sources/SortyLib/Views/AnalysisView.swift:72`. That caller creates its own
`RefreshManager`, creates one group, and schedules one five-second timer.
Stopping cancels the group and then cancels the entire manager again.

The group exposes local-sounding pause/resume methods that actually pause and
resume every timer in the manager. There is no second group to justify the
group interface. Delete the group and its factory; let the caller use
`schedule`, `cancelAll`, `pause`, and `resume` directly. The timer ID list,
weak reference, and duplicate cancellation disappear without spreading logic.
Keep the manager's timer tolerance, interval floor, immediate firing, main
run-loop mode, and remaining-interval handling.

This is the strongest candidate. A later implementation should exercise
start/stop and inactive/active transitions. No runtime validation was performed
for this audit.

### 2. Delete DebugLogger's experiment metadata overload

`Sources/SortyCore/Utilities/DebugLogger.swift:16` requires a hypothesis ID and
accepts session, run, location, and nested data fields. Its only production
caller is `SettingsViewModel.performSave` at line 484, which hardcodes
hypothesis `B` and uses default session/run IDs.

The existing `LogManager.log` already accepts a category and structured data.
Use it at that caller with a Settings category and the existing `hasAPIKey`
and provider fields, then delete the experiment overload. No credential value
needs to be logged. Check diagnostic consumers before changing the serialized
field names. Keep the simple DebugLogger overload for now: replacing its many
callers would repeat the debug level and category throughout the app.

### 3. Consider localizing PromptContextHelper

`Sources/SortyOrganizer/PromptContextHelper.swift:8` has one method and one
production caller, `FolderOrganizer.duplicateDetectionPhase` at line 1862.
It formats duplicate groups and appends recommendations; it is not a pure
pass-through. Moving it to a private FolderOrganizer method would remove the
helper type and its Xcode entries, but the formatting implementation remains.

This is a low-priority locality change, not a meaningful complexity reduction.
Keep the duplicate instructions and hash/path details if moving it. Do not
inflate FolderOrganizer just to reduce the file count.

## Modules that earn their keep

| Module | What deletion would push into callers |
| --- | --- |
| RefreshManager | Timer ownership, coalescing tolerance, cadence validation, pause/resume timing, and cleanup. Its group can go without discarding those contracts. |
| AIClientFactory | Provider/auth routing, protocol selection, availability failures, and detached creation. These decisions would spread into organizer and settings callers. |
| AIKeychainStore and LiveAIKeychainStore | A real seam with ephemeral and live adapters. Direct Core calls would reverse the AI target's dependency direction. |
| SortyFSTelemetry and LiveSortyFSServices | The seam keeps Core analytics out of the file-system target. Removing the small adapter would couple duplicate scanning to Core. |
| UserDefaultsDataReader | The documented read-only Sendable interface for background hydration. Direct access would repeat unchecked concurrency decisions across persisted managers. |
| ExtensionListener | Notification observer ownership, teardown, deferred handoff draining, and single-window routing. Thin forwarding alone does not describe its lifecycle contract. |
| Re-export files | Imports would move into consumers. Removing them does not eliminate runtime complexity. |

## Scope and evidence

Inspected leaf-target adapters, Core utilities, refresh ownership, provider
construction, persistence readers, and organizer prompt formatting. Traced
candidate references across `Sources` and `Tests`, and checked Xcode file
membership. This is a focused source audit, not a claim that every module in
the repo was reviewed. Existing complexity-audit decisions remain applicable.

No app code or tests changed. No build, test run, computer use, or hosted CI
was performed. Source inspection establishes the current caller relationships;
it does not prove a proposed replacement's runtime behavior or performance.
