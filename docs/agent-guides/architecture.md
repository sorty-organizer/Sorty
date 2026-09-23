# Architecture & Patterns

## Data Flow
```
User Action → View → ViewModel/Manager → FolderOrganizer → AIClient → Response
                                              ↓
                                      OrganizationPlan → Preview → Apply
```

## Key Components

| Layer | Location | Purpose |
|-------|----------|---------|
| **SortyApp** | `Sources/SortyApp/` | SwiftUI lifecycle, `AppCoordinator` for background tasks |
| **SortyLib** | `Sources/SortyLib/` | All business logic shared by the app, Finder extension, and widgets |
| **SortyFinderSync** | `Sources/SortyFinderSync/` | Finder Sync extension |

### SortyLib Directories

| Directory | Contains |
|-----------|----------|
| `AI/` | AI clients, prompt builders, response parsers |
| `Models/` | Data models (`AIConfig`, `FileItem`, `OrganizationPlan`, `FeatureFlags`) |
| `Views/` | All SwiftUI views |
| `ViewModels/` | View models |
| `Managers/` | `@MainActor ObservableObject` state managers |
| `Organizer/` | Core workflow orchestration (`FolderOrganizer` state machine) |
| `Learnings/` | ML-based preference learning (`LearningsManager`, `LearningsAnalyzer`, `RuleInducer`) |
| `Utilities/` | Keychain, logging, deeplinks, security |
| `DesignSystem/` | Shared design tokens and reusable UI components |
| `FileSystem/` | File system access and scanning |
| `FinderExtension/` | Finder extension IPC helpers |
| `Analytics/` | `AnalyticsManager` (PostHog), `ReliabilityManager` (Sentry), and consent UI |
| `Services/` | App services |

## State Management
All managers are `@MainActor ObservableObject` classes created as `@StateObject` in `SortyApp.swift` and injected via `.environmentObject()` to the view hierarchy.

## AI Client Pattern
New AI providers must:
1. Implement `AIClientProtocol` (in `AI/`)
2. Add a case to `AIProvider` enum
3. Register in `AIClientFactory`

## FolderOrganizer State Machine
`idle → scanning → organizing → ready → applying → completed`

### Plan quality gate

`FolderOrganizer.validationPhase` runs filesystem safety checks first, then scores the proposed structure before preview. `PlanQualityEvaluator` deducts points for duplicate folder names, vague or single-file folders, mixed file-type buckets, needless nesting, and near-matches that ignore an existing folder. Rename-only runs skip structural scoring because they cannot move files or create folders.

A score below 75 triggers one new AI request. The correction prompt lists every measured problem and asks the model to preserve sound placements. Sorty scores the replacement too. If it still fails, `keepingCertainItems` keeps placements that were not implicated and moves affected files to the unorganized review section. It never applies a low-quality placement by default.

### Apple Foundation Model prompt compaction

Apple Foundation Model requests progressively compact file evidence before splitting a large request into smaller batches. Every compaction level retains a bounded record for each file: filename, relative path, extension, byte size, available dates, extracted title, and a short content or OCR cue. Even the smallest fallback must not degrade files to opaque IDs and extensions.

The active persona, direct user instructions, scoped `<learnings_context>`, and rename naming policy are fixed request context. They are included when choosing a compaction level and carried unchanged into every retry and adaptive batch. Reduce per-file evidence lengths or split the batch before removing those instructions.

### Review evidence

AI plans must provide one concise, concrete grouping cue for every folder and a source cue for every proposed rename. The preview shows folder evidence inline and rename evidence beneath every suggestion, including high-confidence renames. Generic explanations such as “more descriptive” or “these files belong together” do not satisfy the prompt contract.

### Semantic learning rules

Placement and filename feedback stay separate. Two matching placement corrections can produce a rule scoped to the selected folder, for example `.mov` files moving from `Media` to `Footage`. Preview edits and explicit rejections also increment the failure count of the exact attributed rule.

Repeated accepted or edited filenames produce a scoped naming convention such as `YYYY-MM-DD {name} Invoice.pdf`. A rejection subtracts support only when the rejected suggestion matches that convention. Unattributed rejections never create broad `AVOID` rules. Repeated rejected renames of exported `.app` bundles produce a narrow protected-name rule instead.

### Organization quality corpus

Real regression cases live in the git-ignored `QualityCorpus/private/` directory. Keep one JSON file per representative folder and record expected moves, non-moves, renames, protected names, uncertain items, final decisions, confidence, preview edits, and reverts. The synthetic case under `QualityCorpus/sample/` documents the format without exposing user data.

Run `make quality-report` before prompt tuning. The report includes placement acceptance, expected-placement matches, rename acceptance/edit/rejection rates, protected-name preservation, ambiguous review handling, reverts, edits per 100 files, and confidence calibration. Use the executable's `--json` option when comparing reports between commits.

`OrganizationPlan.qualityAssessment` records the score, issues, affected file IDs, and whether a retry occurred. Keep this metadata when transforming or exporting a plan so preview and quality reporting can explain why Sorty held a file back.

Multimodal AI requests retry without images only for HTTP 413 or a 400/422 response that identifies a payload or media problem. Other client errors must reach the user unchanged. The shared base64 image cache has a 24 MiB encoded-data limit; larger images are encoded for the request without being retained.

## Deeplinks
URL scheme `sorty://` — see `DeeplinkHandler` for routes:
- `sorty://organize?path=/path&persona=Developer&autostart=true`
- `sorty://settings`

## Finder Extension
Uses App Groups (`group.com.sorty.app`) for IPC. Finder Integration is a core app feature and defaults on for new installs.
Quick Action and Finder Sync repair flows are exposed in-app via Finder Integration settings.
The Finder Sync `.appex` registration repair path is `ExtensionCommunication.repairFinderSyncExtensionRegistration` and should be preferred over external terminal instructions.

### Background Agent
- `LoginItemManager` manages both the main app login item (via `SMAppService.mainApp`) and a background LaunchAgent (`com.sorty.app.background-agent.plist`).
- On sync, it auto-migrates off the legacy agent plist (`com.sorty.app.plist`) that reused the app's service label.
- `backgroundAgentConfigurationIssues(label:bundleProgram:mainAppServiceLabel:)` validates agent configuration at build/test time.

### Finder Sync Menu Icon Rendering (CRITICAL)
- **`isTemplate` does NOT work** in Finder Sync extensions. Finder ignores it for extension-provided menu item images. Do not use `isTemplate = true` for dark/light mode adaptation — this has caused repeated regressions.
- The correct approach (in `finderWatchImage()`): detect appearance via `prefersDarkAppearance()`, render the SF Symbol into a new `NSImage` via `lockFocus` with **proportional scaling and centering** (not force-drawn into the full rect — non-square symbols like "eye" get distorted), then tint with `.sourceAtop` (`drawColor.set()` + `NSRect.fill(using: .sourceAtop)`), and set `isTemplate = false`.
- See `docs/agent-guides/finder-integration.md` → "Menu Icon Rendering" for the full pattern and list of approaches that must NOT be used.
- Asset catalog images (`NSImage(named:)`) are inaccessible from the extension bundle — use SF Symbols rendered at runtime.
- A stale Finder Sync binary can stay active even when workspace code is updated; after deploy, `pkill -f SortyFinderSync`, re-enable `com.sorty.app.SortyFinderSync`, and restart Finder.

## Learnings System
User preference learning stored in `LearningsProfile`. Secured with biometric auth via `SecurityManager`.

## UI Presentation Pitfalls

### Liquid Glass Surfaces
- Use `Sources/SortyLib/Views/AboutView.swift` as the visual reference for a correct liquid glass surface.
- If a view needs to look like the About window, do not assume SwiftUI `.popover` or `.sheet` chrome will preserve that look. The presenter shell can make system glass read like a dark AppKit panel even when `glassEffect` is applied correctly.
- `ModelSelectionPopover` in Settings and Automation Settings intentionally does **not** use the native popover presenter. It is anchored with `modelSelectorTriggerBounds()` and rendered via `modelSelectionOverlay(...)` from `Sources/SortyLib/Views/ModelSelector.swift`.
- When updating liquid glass UI, separate the **glass surface** from the **presentation shell**. If the shell is visually wrong, replace the presenter first instead of stacking more material/glass modifiers.
- For any UI described as "system liquid glass" (especially dropdowns/popovers), use system presentation + system glass only. Do not simulate with custom material.
- **Do not use** `.regularMaterial`, `.thinMaterial`, `.ultraThinMaterial`, or custom gradient/blur backgrounds to approximate glass in these surfaces.
- If `glassEffect` is unavailable for the deployment target, prefer default system chrome (no custom material fallback) instead of trying to mimic glass.
- Reuse shared liquid-glass helpers and keep them system-only; do not add custom material fallback branches.

### Button Styles
All interactive buttons must use Sorty's pill-style button system defined in `Sources/SortyLib/Utilities/ButtonStyles.swift`. Do **not** use `.buttonStyle(.bordered)` or plain system button styles for action buttons.

| Style | Usage | Example |
|-------|-------|---------|
| `.tintedPill(.red, size: .small)` | Destructive/cancel actions | Cancel, Delete |
| `.tintedPill(.indigo, size: .small)` | Model/AI actions | Model picker |
| `.onboardingPill(size: .small)` | Primary/positive actions | Regenerate, Choose Folder |
| `.sortyPrimary` | Main CTA (e.g., Apply) | Apply button |
| `.sortySecondary(size: .small, color:)` | Secondary actions | Reset |

Always pair buttons with `HapticFeedbackManager.shared.tap()` on press, and use `HStack(spacing: 4)` with an SF Symbol icon + `.caption.bold()` text for compact pill button labels.

## Common Tasks
- **Add AI provider**: Create client in `AI/`, implement `AIClientProtocol`, add to `AIProvider` enum + `AIClientFactory`
- **Add settings option**: Update `AIConfig`, `SettingsViewModel`, `SettingsView`
- **Add new view**: Create in `Views/`, add case to `AppState.AppView`, add navigation in `ContentView`
- **Test deeplinks**: Set `XCUITEST_DEEPLINK` environment variable before launch
