# Icon artwork

The menu bar uses seven pink-red activity PNGs in
`Sources/SortyLib/Resources/Images`, named `SortyMenu<Activity>.png`.
The `SortyMenuWhite<Activity>.png` siblings are white alternatives for artwork
review. The active menu bar still uses the pink-red set.
Regenerate the white PNGs and their SVG sources with
`python3 scripts/generate_white_menu_icons.py`. These flat white shapes use
transparent face panels and prop details, based on the existing SVG mascot.
The generator requires `rsvg-convert` from librsvg.
The white Learning icon uses an open book to make the activity recognizable.

Finder Sync bundles `SortyFinderSync/SortyWatchMascot.png` and
`SortyFinderSync/SortyExcludeMascot.png` through its Xcode Resources phase.
Watch reuses `SortyMenuWatchedFolder.png`. Exclude uses the matching robot with
a shield and minus sign. Keep those resource names when replacing artwork.
The Organize icon references `SortyMenuOrganizing.png` directly.

The scripted bundle fingerprint includes the dedicated Finder PNGs. The Finder
extension cache also checks all three action PNGs and the Xcode project, so
artwork changes trigger an extension rebuild on the next build.

The Exclude artwork was made with the built-in image editor using the current
Watch PNG as the style reference and the old Exclude PNG as the symbol reference.
The prompt asked for the same glossy pink-red robot behind a prominent shield
with a white horizontal minus, centered on a transparent background and readable
at 16 points. The white set is rendered from SVG instead of generated retouches.

App icon sources live in `Assets/AppIcon`. Run
`python3 scripts/generate_app_icons.py` after changing those sources to update
the ICNS files and release asset catalog. The generator adds the Dock margins.
Changing source artwork does not update an existing release ZIP.
