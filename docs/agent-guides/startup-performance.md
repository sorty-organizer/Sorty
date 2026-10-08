# Startup performance

Keep the main thread available to draw Sorty's first window and handle input. Launch-path initializers may create in-memory defaults, register observers, and read small scalar preferences needed for the initial interface. Store decoding, journal replay, bookmark resolution, credential lookup, subprocess probes, AI client creation, and automation startup belong in explicit loading or startup methods.

Apply this rule to dependencies reached through `SortyApp`, `WindowSession`, view-owned objects, and `.shared` properties. A cheap initializer can still trigger an expensive singleton. `Task { @MainActor in ... }` retains main-actor work; making a method `async` does not move its synchronous work off that actor.

`StateObject(wrappedValue:)` takes an escaping autoclosure. Keep construction inside
that expression so `SortyApp.init` does not create managers eagerly. SwiftUI still
constructs them when the scene reads the objects, including environment injection.
Moving a constructor into this autoclosure does not prove it runs after first paint.
`timedLaunchInit` emits a "Manager initialization" signpost in all configurations,
with the manager name on the begin event. Use those intervals in App Launch traces.

Duplicate detection and settings are created when a window opens Duplicates.
Inject them at that destination, rather than at the window root. AppState forwards
scan activity to the menu bar without constructing the detection manager on launch.
Files & Folders bookmark data loads on the first permission check. Async checks read
it at utility priority and preserve grants or revocations made during that read.
The production window receives the app's shared Sparkle manager and history;
default constructor arguments remain available for previews and tests.

The Dock uses the bundle icon directly. The app delegate does not read or decode
an icon file during launch. Widget synchronization constructs its singleton on
first use after startup gating. Legacy uninstall and Learnings defaults cleanup
runs during deferred setup, with the obsolete Learnings key removed only if present.
Sparkle restores its previous check date when the deferred launch check runs.

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

Main-window toolbar items must contain a visible control. Omit unavailable Back
items in the toolbar builder instead of returning `EmptyView()` from an item, and
do not add empty items to force toolbar creation. Sentry issue
[SORTY-MACOS-2J](https://sorty-z1.sentry.io/issues/7780212160/events/71fd2bff1f234ea4a2b5c73a7e7d4add/)
recorded a launch crash on macOS 27.2 in `NSHostingView.updateConstraints` while
SwiftUI replaced the native toolbar and AppKit reentered constraint layout through
its key-view loop. Removing the empty items is a targeted mitigation; the event
does not include the underlying exception reason, and the affected OS still needs
runtime validation.

Help > Restart Onboarding opens the skill introduction first. Continue with App
then opens the main app and records onboarding completion, including on fresh installs.
The skill introduction also appears once for users upgrading from app-only setup.
Its installer is lightweight; agent detection and preference hydration start in
view tasks, after the interface mounts. Restarting preserves the current window position and
disables only the outgoing root crossfade while onboarding changes shared window
chrome. Keep icon rasterization and audio data loading off the main actor, and
cancel pending intro preparation when Get Started is pressed before the outgoing
intro finishes its transition.

File reads, journal replay, and JSON decoding run in detached user-initiated tasks. Published state and persistence writes remain on the main actor. `UserDefaultsDataReader` exposes reads only and uses the documented thread-safe `UserDefaults` read behavior. Do not add write methods to it.

For asynchronous bookmark restoration, snapshot the bookmark, item identity, and generation before leaving the main actor. Accept a result only when its generation and bookmark still match the current item. Keep access ownership explicit. Balance every successful security-scope acquisition with its eventual `stopAccessingSecurityScopedResource()` release, including discarded results. Discard stale results after removal, reauthorization, or reset. Await required access before automation uses a folder. `StorageLocationsManager.refreshAccess(for:)` remains a synchronous main-actor operation for the one-item add-location path. Only bulk restore uses the asynchronous path.

Manual-session restoration reads, decodes, resolves its bookmark, and checks the folder off the main actor. It rechecks the session generation and idle state before publishing the restored folder. The organizer owns a successful security scope until reset and releases scopes from discarded results immediately.

Manual-session snapshots persist direct user instructions only. Assembled AI
request text, exclusions, and supporting context must not populate the editable
Instructions field after restart or Back. Versioned snapshots preserve literal
user text; unversioned snapshots recover the user block and remove known generated
context sections before assigning the field.

The manual window becomes ready without waiting for history, Learnings, storage-location hydration, or automation folder access. Automation still waits for its history and Learnings state plus watched-folder and storage-location access. Sentry and PostHog start after the window session finishes its interactive setup. Provider authentication is not verified on launch: a persisted setup-repair state stays inline and non-modal, Provider Settings refreshes only the selected provider, and an explicit organize action verifies the cached repair state before touching files. `CodexCLIAuthManager` constructs without spawning a subprocess, reading Keychain credentials, or making a network request.

Settings credential hydration uses detached Keychain reads on a cache miss and
rejects results after provider changes, edits, or reset. Preserve that path rather
than adding another detached wrapper.

Manual and Learnings AI clients are configured on first use. The automation organizer and its client exist only while at least one watched folder is active. Sparkle starts after 45 seconds of idle startup time and only when its persisted daily interval has elapsed; PostHog feature flags, Finder menu-action verification, and the initial widget snapshot are similarly deferred. Finder runtime monitoring may start earlier because it only observes the extension heartbeat. Safe Finder registration maintenance runs with the deferred menu-action setup after 30 seconds. It coalesces requests and limits registration attempts to once every five minutes without restarting Finder, staging app copies, or changing signing.

Security-scoped bookmark creation for a newly selected manual folder runs at utility priority. Publication rechecks the selected URL so a result for an earlier selection cannot replace the current folder's bookmark.

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
