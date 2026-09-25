# App icon sizing

The Debug and Release PNGs are full-bleed source artwork. Before packaging them
for macOS, scale the **whole tile** to 824 × 824 pixels and center it on a
transparent 1024 × 1024 canvas. This leaves a 100-pixel margin on each side.
Shrinking the robot inside the tile does not fix an oversized Dock icon.

Run `python3 scripts/generate_app_icons.py` from the repository root after changing
either source PNG. It requires ImageMagick and regenerates both variant ICNS
files, their copies in `Resources`, and the release app icon asset catalog.
Each ICNS representation uses the same padded canvas, including Retina sizes.
The script always reads the full-bleed sources, so rerunning it does not add
padding repeatedly.

The build script selects `Assets/AppIcon/AppIcon-{Debug,Release}.icns`. Xcode
selects the corresponding copy in `Resources`. The PNGs used inside the app
remain full-bleed because their views control the surrounding spacing.

The Icon Composer document is editable artwork, not the packaged Dock icon.
Its layer scale changes the artwork inside the background; it does not provide
the transparent margin required by these ICNS assets.
