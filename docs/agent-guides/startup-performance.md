# Startup performance

Keep the main thread available to draw Sorty's first window and handle input. Launch-path initializers may create in-memory defaults, register observers, and read small scalar preferences needed for the initial interface. Store decoding, journal replay, bookmark resolution, credential lookup, subprocess probes, AI client creation, and automation startup belong in explicit loading or startup methods.

Apply this rule to dependencies reached through `SortyApp`, `WindowSession`, view-owned objects, and `.shared` properties. A cheap initializer can still trigger an expensive singleton. `Task { @MainActor in ... }` retains main-actor work; making a method `async` does not move its synchronous work off that actor.

## Loading contract

`SortyApp.configureGlobalsIfNeeded()` starts these loads in parallel from a view task:

- `SettingsViewModel.loadPersistedState()` reads and decodes `aiConfig`.
- `OrganizationHistory.loadPersistedState()` reads the lightweight History index. Complete
  session plans, responses, operations, and restoration records live in per-session files and
  are loaded through `details(for:)` into a bounded cache when an action needs them.
- `WatchedFoldersManager.loadPersistedState()` replays the append-only watched-folder journal.
- `StorageLocationsManager.loadPersistedState()` reads and normalizes saved storage locations.
- `LearningsManager.loadPersistedState()` restores its model selection and resolves saved reference-model directories.
- `ExclusionRulesManager.loadPersistedState()` restores rules and compiles the matcher before any organization scan uses it.
- `PersonaManager.loadPersistedState()` restores the selected built-in or custom persona and custom prompts.
- `CustomPersonaStore.loadPersistedState()` restores custom personas.
- `NamingPresetManager.loadPersistedState()` restores custom naming presets.
- `SteeringPromptManager.loadPersistedState()` restores saved steering prompts and removes obsolete placeholder prompts.

The main content observes the managers as persisted state arrives. Settings persistence is disabled until hydration completes, so an early view mutation cannot overwrite saved configuration. `configureGlobalsIfNeeded()` must await exclusion hydration before it publishes globals that consume the matcher. Every `FolderOrganizer` scan entry point must do the same. Empty loading state must never mean that a user's rules can be skipped.

`ExclusionRulesManager` starts empty with `hasLoaded == false`. Views may use their explicit loading or preview state during that interval, but callers that need real matching must wait for `loadPersistedState()`. `AppCoordinator` takes its initial matcher from that hydrated instance and keeps following `$compiledMatcher` changes.

`LoginItemManager` keeps construction free of `SMAppService` queries. Its registration observation starts from `configureGlobalsIfNeeded()`, and startup reconciliation runs off the main actor.

The loaders are idempotent. A second caller awaits the existing task. Bookmark restores are also coalesced, including repeated requests for the same saved location. Hold or merge edits made during hydration before saving. Clearing or resetting a store invalidates an in-flight result so deleted data cannot reappear. Preserve these contracts when adding another loader.

`Task.yield()` only offers the executor a scheduling opportunity. Neither it nor SwiftUI `onAppear` proves that a frame has reached the display. Keep synchronous work after suspension points short as well; replacing a blocking initializer with a blocking view task merely moves the stall.

## Threading rules

Help > Restart Onboarding uses the same timed welcome reveal, audio cue, and
orbit entrance as a first launch. It preserves the current window position and
disables only the outgoing root crossfade while onboarding changes shared window
chrome. Keep icon rasterization and audio data loading off the main actor, and
cancel pending intro preparation when Get Started is pressed before the outgoing
intro finishes its transition.

File reads, journal replay, and JSON decoding run in detached user-initiated tasks. Published state and persistence writes remain on the main actor. `UserDefaultsDataReader` exposes reads only and uses the documented thread-safe `UserDefaults` read behavior. Do not add write methods to it.

For asynchronous bookmark restoration, snapshot the bookmark, item identity, and generation before leaving the main actor. Accept a result only when its generation and bookmark still match the current item. Keep access ownership explicit. Balance every successful security-scope acquisition with its eventual `stopAccessingSecurityScopedResource()` release, including discarded results. Discard stale results after removal, reauthorization, or reset. Await required access before automation uses a folder. `StorageLocationsManager.refreshAccess(for:)` remains a synchronous main-actor operation for the one-item add-location path. Only bulk restore uses the asynchronous path.

Manual-session restoration reads, decodes, resolves its bookmark, and checks the folder off the main actor. It rechecks the session generation and idle state before publishing the restored folder. The organizer owns a successful security scope until reset and releases scopes from discarded results immediately.

The manual window becomes ready without waiting for history, Learnings, storage-location hydration, or automation folder access. Automation still waits for its history and Learnings state plus watched-folder and storage-location access. Sentry and PostHog start after the window session finishes its interactive setup, and so does the once-per-launch Codex CLI probe (`CodexCLIAuthManager.startLaunchProbeIfNeeded()`). `CodexCLIAuthManager` and `SubscriptionAuthManager` construct without spawning a subprocess; the probe runs at utility priority, `CodexSubscriptionClient.resolveCodexExecutablePath()` caches its lookup briefly, and `SubscriptionAuthManager` mirrors Codex state through Combine instead of probing again.

`SortyAppDelegate` resolves the app-group container for the build auto-close monitor off the main thread after `applicationDidFinishLaunching`. `containerURL(forSecurityApplicationGroupIdentifier:)` consults the container manager and must not run in the delegate initializer.

`PersonaManager`, `CustomPersonaStore`, `NamingPresetManager`, and `SteeringPromptManager` use the same lightweight initialization and pending-change merge contract as the other loaders. A picker or preview can display defaults or mocks before those stores hydrate. An organizer scan waits for persona and custom-persona hydration. Naming and steering are view-driven, so a pre-hydration custom preset reference falls back to a built-in preset until the view refreshes.

## Verification

Use focused tests while developing:

```sh
swift test --filter 'SettingsViewModelStartupTests|HistoryTests|FolderWatcherTests|StorageLocationsReliabilityTests'
```

For substantive startup changes, run `make dev` to verify the app target and Swift 6 isolation checks. Focus tests on stored-state restoration, edits or resets during loading, dependent operations waiting for hydration, stale bookmark results, and balanced security-scope ownership. `StartupHydrationTests` cover hydration, reset, and bookmark-less races. They do not replace manual reauthorization, removal, reset, stale-bookmark recreation, or volume-rename checks. Documentation-only changes do not need a build. Local checks do not replace required Blacksmith checks.

For launch-time acceptance:

- Use `make daily` to build and launch the optimized local app with the usual
  signing identity and Finder extension. It explicitly disables hot reload and
  skips tests; it is not a release validation command. `make now` and `make hot`
  overwrite the same bundle with development builds. Confirm the bundle being
  measured, including whether it contains InjectionLite, before changing startup
  code in response to slow Dock launches.
- Compare the same signed Release configuration and persisted data, outside a debugger or hot-reload process. Record the exact build and app path.
- Measure launch request to first visible frame, then separately to usable controls. Distinguish process launch from reopening a window in an already-running app.
- Report repeated run values and medians. Keep warm-cache launches separate from the first launch after reboot; preserve real user data and quit gracefully after hydration finishes.
- Use Instruments App Launch and Time Profiler to attribute delays. Add signposts for expensive startup phases when the trace cannot distinguish them.
- Treat `SortyLaunch:` constructor logs as diagnostics. The `MainWindowRootView.onAppear` smoke marker proves that the view lifecycle ran, not that the window was painted or interactive. The analytics `launchDuration` and reliability launch span also cover different initialization intervals, not Dock-click-to-first-frame time.
- State missing evidence plainly. Builds, tests, and source inspection cannot establish a measured launch-time reduction.

See Apple's [Reducing your app's launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time) for first-frame measurement and separate startup-activity instrumentation.
