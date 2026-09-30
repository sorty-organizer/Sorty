# Icon artwork

The menu bar uses seven pink-red activity PNGs in
`Sources/SortyLib/Resources/Images`, named `SortyMenu<Activity>.png`.
The `SortyMenuWhite<Activity>.png` siblings are white alternatives for artwork
review. The active menu bar still uses the pink-red set.
The white PNGs use only white artwork and transparent negative spaces. They are
made with the built-in image editor, using the white Idle icon as the common
style reference. Preserve the mascot's proportions, rounded head, antenna,
curved eyes, and smile when making variants.

Activity symbols are a waving hand for Greeting, a folder with a down arrow for
Organizing, a pencil for Renaming, an eye for Watched Folder, two overlapping
folders for Duplicate Scanning, and an open book for Learning. Both the red and
white Learning icons use the book. Keep props simple enough to read at 20 points.

The white set's prompt asks for the same rounded head, antenna, side ears, happy
curved eyes, and smile as the reference, with every visible part pure white.
The face panel and prop details are transparent openings. Each activity adds
its recognizable white prop on a transparent square canvas. Ask for clean
designed contours rather than a threshold conversion of glass shading.
Avoid gray or dark fills, noisy edges, abstract blobs, extra symbols, and text.
Generate white artwork on a uniform black background, then export the generated
white shapes as transparent PNGs. The image editor's direct transparent output
introduced speckles. Export maps black to transparency and keeps the generated
contours; it does not draw or reconstruct the mascot.
The former SVG set and Python generator have been removed.

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
at 16 points.

App icon sources live in `Assets/AppIcon`. Run
`python3 scripts/generate_app_icons.py` after changing those sources to update
the ICNS files and release asset catalog. The generator adds the Dock margins.
Changing source artwork does not update an existing release ZIP.
