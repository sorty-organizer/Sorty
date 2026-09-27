# Finder Integration

## Basics
- Finder Sync extension target: `SortyFinderSync` (embedded `.appex`).
- IPC uses app group `group.com.sorty.app`.
- Finder Integration is a core app feature. The legacy defaults key `finderIntegrationEnabled` remains for migration and diagnostics, but new installs default to enabled.
- In-app repair path: `ExtensionCommunication.repairFinderSyncExtensionRegistration`.
- Finder selection and window AppleScripts run through `/usr/bin/osascript` off the main actor. Each short query has a process deadline; the Automation permission request waits for the user's decision.

## Preferred Repair Flow
1. Open `Settings -> Finder Integration`.
2. Use `Install/Reinstall` for Quick Action.
3. Use `Repair Finder Sync` (or `Activate Extension`) for the `.appex`.
4. Use `Open Extensions` and confirm `com.sorty.app.SortyFinderSync` is enabled.

## Extension Isolation
- If Sorty is running from `/Applications` or `~/Applications`, Finder Sync is registered from that app bundle directly.
- If Sorty is running from a non-Applications path (for example, a workspace `releases/` build), repair stages the app in `~/Applications/Sorty.app` and registers Finder Sync from there so Finder can activate right-click menus.
- On launch the app auto-repairs the extension registration if it doesn't match the current build (`autoRepairFinderSyncIfNeeded`).
- Repair also kills any stale `SortyFinderSync` process and force-removes the old `pluginkit` registration before re-adding.

## Runtime Diagnostics & Auto-Repair
- On launch the app calls `autoRepairFinderSyncIfNeeded` which evaluates `shouldAutoRepairFinderSync(diagnostics:currentPath:)`.
- `finderSyncDiagnostics(entries:preferredPath:heartbeat:runningProcessPath:appBundleMissingEntitlements:)` is the central diagnostic function returning a `FinderSyncDiagnostics` struct with a `FinderSyncStatusKind`.
- Status kinds: `missing`, `signatureInvalid`, `notRegistered`, `disabled`, `indeterminate`, `activeElsewhere`, `needsCleanup`, `registered`, `verified`.
- A `verified` status requires either a recent `FinderSyncRuntimeHeartbeat` from the extension or a matching running process path.
- The Finder Sync extension posts distributed notifications (`SortyFinderSyncHeartbeat`) on launch and periodically, cached via `UserDefaults` with a 180-second staleness threshold.
- `parseFinderSyncRegistrationEntries(from:)` parses `pluginkit` output to determine registration state; `+` = enabled, `-` = disabled, no marker = indeterminate.
- Auto-repair must not re-enable a `.disabled` extension. That state represents the user's macOS Extensions choice.

## Toolbar integration

Sorty provides a Finder toolbar item. Keep the complete Finder Sync toolbar contract together:

- `toolbarItemName`
- `toolbarItemImage`
- `toolbarItemToolTip`
- a non-empty menu for `.toolbarItemMenu`

Implementing only `menu(for:)` leaves Finder with an incomplete extension toolbar item. On affected macOS versions, Finder can repeatedly add and remove its `NSPopUpButton`, driving an `NSToolbarView` layout loop. Returning `nil` from `.toolbarItemMenu` does not fix construction because Finder reads the toolbar properties before the user clicks the item.

Mount and unmount notifications may recalculate monitored roots, but assign `directoryURLs` only when the set changed. Reassigning an identical set needlessly rebuilds Finder extension state.

## Menu Icon Rendering (CRITICAL — do not regress)

Finder Sync extensions **do NOT honor `isTemplate`** on `NSMenuItem` images.
Setting `isTemplate = true` on an SF Symbol or any `NSImage` will **not** make it
automatically tint white in dark mode / black in light mode. This has caused
repeated regressions — do not attempt `isTemplate`-based approaches.

### Correct pattern (used in `finderWatchImage()`)
1. Detect dark/light mode via `prefersDarkAppearance()` (checks `NSApp.effectiveAppearance` and `AppleInterfaceStyle` user default).
2. Pick the draw color: `NSColor.white` for dark mode, `NSColor.black` for light mode.
3. Create the SF Symbol with a `SymbolConfiguration` (e.g. `pointSize: 14, weight: .medium`).
4. **Scale proportionally and center**: compute an aspect-ratio-preserving scale from the symbol's `.size` to the 16×16 menu icon size, and center the draw rect. Do NOT force-draw into the full 16×16 rect — SF Symbols like "eye" are wider than tall and will appear squished/compressed.
5. Create a new 16×16 `NSImage`, `lockFocus`, draw the symbol into the centered rect with `.sourceOver`, then **tint** with `drawColor.set()` + `NSRect.fill(using: .sourceAtop)`.
6. Set `rendered.isTemplate = false`.

### Why `.sourceAtop` is required
- `drawColor.set()` before `.sourceOver` does **not** colorize SF Symbols — they draw with their own internal colors and ignore the graphics context fill.
- `.sourceAtop` fills only opaque pixels, effectively tinting the already-drawn symbol.

### What NOT to do
- ❌ `image.isTemplate = true` — Finder ignores it.
- ❌ `templateMenuIcon()` / force-setting `.size` on SF Symbol copies — distorts the glyph.
- ❌ `normalizedMenuIcon()` with `isTemplate: true` — `lockFocus`/`unlockFocus` bakes pixels and breaks template tinting even if Finder did honor it.
- ❌ `NSImage(named: "WatchIcon")` from asset catalog — the extension bundle cannot access the host app's asset catalog.
- ❌ Drawing the SF Symbol into the full `NSRect(origin: .zero, size: menuIconSize)` — non-square symbols (e.g. "eye") get distorted. Always compute a proportional draw rect.

## Troubleshooting
- Verify extension target builds:
  - `xcodebuild -project Sorty.xcodeproj -target SortyFinderSync -configuration Debug -destination 'platform=macOS' build`
- Watch icon assets (used by Quick Actions, NOT by Finder Sync):
  - `Resources/Assets.xcassets/WatchIcon.imageset/eye_black.png` (light mode)
  - `Resources/Assets.xcassets/WatchIcon.imageset/eye_white.png` (dark mode)
- If behavior is stale after rebuilding, kill the old extension (`pkill -f SortyFinderSync`), re-enable `com.sorty.app.SortyFinderSync`, and restart Finder.
