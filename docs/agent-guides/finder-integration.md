# Finder Integration

## Basics
- Finder Sync extension target: `SortyFinderSync` (embedded `.appex`).
- IPC uses app group `group.com.sorty.app`.
- Finder Integration is a core app feature. The legacy defaults key `finderIntegrationEnabled` remains for migration and diagnostics, but new installs default to enabled.
- Automatic setup: `ExtensionCommunication.prepareFinderIntegrationAsync`.
- Finder selection and window AppleScripts run through `/usr/bin/osascript` off the main actor. Each short query has a process deadline; the Automation permission request waits for the user's decision.

## Settings and setup

Settings > Finder Integration explains the right-click actions first:

- Organize with Sorty creates a plan to review before moving files.
- Watch with Sorty adds a folder to Watched Folders.
- Exclude from Sorty keeps a file or folder out of organization plans.

The extension card shows one setup state and an **Open macOS Extensions**
button. macOS 15+ puts Finder extensions under System Settings > General >
Login Items & Extensions > Finder. The page checks again when Sorty becomes
active, including after returning from System Settings. See [Apple's extension settings guide](https://support.apple.com/guide/mac-help/change-login-items-extensions-settings-mtusr003/mac).

There is no troubleshooting checklist or manual repair control on this page.
Automation permission is separate: Finder Sync sends selected paths directly
to Sorty, so its menu actions do not require permission to script Finder.
Finder selection and window automation still use Automation permission in
Settings > Permissions.

## Automatic maintenance

`prepareFinderIntegrationAsync` runs after 30 seconds of deferred startup and
when the Finder settings page opens or Sorty becomes active while it is visible.
It restores compatible Quick Action workflows and refreshes Services using the
existing registry throttle. It also adds missing extension registrations and
removes stale enabled registrations after macOS accepts the preferred copy.

Concurrent setup requests share one task. Registration repair attempts are
limited to once every five minutes per app process. Status checks still run
when returning from macOS Settings. Maintenance does not restart Finder, kill
extensions, copy an app into Applications, or alter signing. It preserves
macOS's enable/disable choice. A disabled extension requires the user to enable
Sorty in macOS Extensions.

`finderSyncDiagnostics` distinguishes registration from runtime confirmation.
An enabled registration is sufficient for the settings label **Enabled in
Finder**; a recent heartbeat or matching process is needed to call it verified.
A quiet, lazily loaded extension must not trigger repeated repair.
Missing extensions and invalid signatures are packaging problems; automatic
maintenance cannot repair those by changing the installed app's signature.

The older `repairFinderSyncExtensionRegistrationAsync` API remains available
for explicit developer recovery. It can stage development builds in
`~/Applications/Sorty.app`, alter signing, terminate the extension, and restart
Finder. Do not use it for background maintenance.

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
- In a release ZIP, `SortyFinderSync.appex/Contents/Info.plist` must identify
  `com.sorty.app.SortyFinderSync`, name `SortyFinderSync` as its executable,
  and declare the `com.apple.FinderSync` extension point. A signed `.appex`
  with the host app's `Info.plist` will not register with Finder.
- Verify extension target builds:
  - `xcodebuild -project Sorty.xcodeproj -target SortyFinderSync -configuration Debug -destination 'platform=macOS' build`
- Watch icon assets (used by Quick Actions, NOT by Finder Sync):
  - `Resources/Assets.xcassets/WatchIcon.imageset/eye_black.png` (light mode)
  - `Resources/Assets.xcassets/WatchIcon.imageset/eye_white.png` (dark mode)
- If behavior is stale after rebuilding, kill the old extension (`pkill -f SortyFinderSync`), re-enable `com.sorty.app.SortyFinderSync`, and restart Finder.
