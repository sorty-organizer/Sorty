# Icon artwork

The menu bar uses seven pink-red activity PNGs in
`Sources/SortyLib/Resources/Images`, named `SortyMenu<Activity>.png`.
The `SortyMenuWhite<Activity>.png` siblings are selectable in Advanced Settings
under Show Menu Bar Icon > Icon Style. The choice applies to the menu bar label,
popover mascot, and Finder actions through the shared app-group defaults.
The pink-red set remains the default.
The settings selector previews the pink-red and white Idle mascots at 14 points
beside their labels, with equal-width segments and the native control's intrinsic
height. Its text baseline aligns with the Icon Style title above the description.
The row uses the standard 8-point vertical padding.
The preview draws from the full-resolution PNG with high interpolation
at the display's backing scale rather than relying on segmented-control downsampling.
The white PNGs use glossy pearl-white glass, silver-gray highlights, and a dark
face panel with white eyes and smile. They reuse the seven image-generated
glass variants from the icon review, exported at 512 pixels. The 1.2.2 What's
New comparison includes a White column for reviewing this set in the candidate.
Apple Native Finder actions use distinct SF Symbols at 16 points: `folder.fill`
for Organize, `eye` for Watch, and `minus.circle.fill` for Exclude. Quick Actions
use the same symbols. The shared robot silhouette obscured the different props
at menu size, so Finder uses symbols rather than white mascot artwork in this
style. Finder Sync rasterizes the symbols with a white tint in dark appearance
and black in light appearance to avoid relying on template tinting across the
process boundary. The menu bar and popover keep their white mascot artwork.
Changing the style broadcasts the selected value to running Finder Sync
instances, so newly opened action menus use it without waiting for defaults to
reach disk. Installed Quick Action icons are rewritten automatically. Finder may
cache an existing toolbar button image until it reloads the extension; the setting
does not restart Finder.

Activity symbols are a waving hand for Greeting, a folder with a down arrow for
Organizing, a pencil for Renaming, an eye for Watched Folder, two overlapping
folders for Duplicate Scanning, and an open book for Learning. Keep props simple
enough to read at 20 points.

For new variants, use the white Idle image as the style reference. Preserve its
rounded head, antenna, side ears, dark face panel, happy curved eyes, and smile.
Ask for the same pearl-white glossy glass material on the activity prop, with
charcoal markings for contrast, a transparent background, and safe margins.
Avoid flat stencils, threshold conversions, speckles, text, and extra symbols.
The former SVG set and Python generator have been removed.

Finder Sync bundles `SortyFinderSync/SortyWatchMascot.png` and
`SortyFinderSync/SortyExcludeMascot.png` through its Xcode Resources phase
for the colorful Sorty style.
Watch reuses `SortyMenuWatchedFolder.png`. Exclude uses the matching robot with
a shield and minus sign. Keep those resource names when replacing artwork.
The Organize icon references `SortyMenuOrganizing.png` directly.

The scripted bundle fingerprint includes the dedicated Finder PNGs. The Finder
extension cache also checks the colored action PNGs and the Xcode project, so
artwork changes trigger an extension rebuild on the next build.

The Exclude artwork was made with the built-in image editor using the current
Watch PNG as the style reference and the old Exclude PNG as the symbol reference.
The prompt asked for the same glossy pink-red robot behind a prominent shield
with a white horizontal minus, centered on a transparent background and readable
at 16 points.

App icon sources live in `Assets/AppIcon`. Run
`python3 scripts/generate_app_icons.py` after changing those sources to update
the ICNS files and release asset catalog. The generator adds the Dock margins.
Changing source artwork does not update an existing release ZIP.

The What's New tour loads `Sources/SortyLib/Resources/AppIcons/AppIcon-Release.png`.
Keep that copy in sync with `Assets/AppIcon/AppIcon-Release.png` when replacing
the release artwork. The first tour page fits the icon into a 380-point square
with 10 points of space above and below it, inside the 400-point image area.
