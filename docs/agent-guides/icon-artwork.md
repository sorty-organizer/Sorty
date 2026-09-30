# Icon artwork

The menu bar uses seven pink-red activity PNGs in
`Sources/SortyLib/Resources/Images`, named `SortyMenu<Activity>.png`.
The `SortyMenuWhite<Activity>.png` siblings are selectable in Advanced Settings
under Show Menu Bar Icon > Icon Style. The choice applies to the menu bar label,
popover mascot, and Finder actions through the shared app-group defaults.
The pink-red set remains the default.
The white PNGs use glossy pearl-white glass, silver-gray highlights, and a dark
face panel with white eyes and smile. They reuse the seven image-generated
glass variants from the icon review, exported at 512 pixels. The 1.2.2 What's
New comparison includes a White column for reviewing this set in the candidate.
Finder Organize and Watch use the white artwork for Apple Native style; Exclude
uses a native Finder symbol. Quick Actions use native symbols in this style.
The white mascot PNGs retain their colors and detail rather than using template
rendering. Existing Quick Actions need reinstalling to update their saved icons.

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
`SortyFinderSync/SortyExcludeMascot.png` through its Xcode Resources phase.
Watch reuses `SortyMenuWatchedFolder.png`. Exclude uses the matching robot with
a shield and minus sign. Keep those resource names when replacing artwork.
The Organize icon references `SortyMenuOrganizing.png` directly.

The scripted bundle fingerprint includes the dedicated Finder PNGs. The Finder
extension cache also checks the colored and white action PNGs and the Xcode project, so
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
