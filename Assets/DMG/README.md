# DMG background

`dmgcanvas_bg.tiff` is the Sorty installer background for DMG Canvas.
`dmg-background.png` is the matching preview and PNG alternative.
Both use a 928 × 1128 pixel canvas, matching the supplied reference.

The artwork uses the release app icon's coral and rose palette, a pale
background, a drag cursor trail, and a small rose-glass mascot positioned
to peek above the Applications icon. There is no text baked into the image,
so Finder's icon labels stay clear.
Finder supplies the app and Applications icons separately.

Created with the built-in imagegen tool. Prompt direction: preserve the
reference layout and whitespace, replace its blue glow with Sorty's
coral and rose colors, soften the cursor outlines, and replace the Aside
footer. A follow-up image edit removed the Sorty footer to prevent overlap
with Finder's Applications label.
The mascot uses the release app icon as its reference, with a soft glow
and no folder baked into the artwork. Its placement depends on the saved
Applications icon position in `scripts/dmg-settings.py`.

`dmg-background-base.png` preserves the original gradient from commit
`4ce717d4`, with only the footer area cleared. `mascot-overlay.png` is a
separate transparent layer, centered at x=470 to clear the folder tab,
with its paws at the folder's
front rim near y=697, below its raised tab. The base's blur,
colors, dots, and cursor trail are preserved outside this small overlay.
To recomposite without regenerating the background:

```bash
magick Assets/DMG/dmg-background-base.png Assets/DMG/mascot-overlay.png \
  -geometry +395+575 -compose Over -composite Assets/DMG/dmg-background.png
sips -s format tiff Assets/DMG/dmg-background.png --out Assets/DMG/dmgcanvas_bg.tiff
```

The release workflow runs `scripts/package-dmg.sh` after validating the app.
It combines 464 × 564 and 928 × 1128 representations in a Retina TIFF for
the 464 × 564 Finder window and uses `scripts/dmg-settings.py`
to center Sorty above the Applications shortcut, alongside the cursor trail.
Both icons use a 112-pixel size. The TIFF is also available for
manual use in DMG Canvas. Check the Finder layout before publishing.

The hosted workflow and local release commands all use this same packager.
Packaging reads the committed artwork directly; it does not regenerate or
recompose it. Preserve these values unless intentionally revising the layout:

- Finder window: 464 × 564 logical pixels, at position 200, 200.
- Sorty icon: 224, 140. Applications shortcut: 224, 380.
- Icon size: 112. Label text size: 13.
- Background: 928 × 1128 source pixels, packaged as 1x at 72 DPI and 2x at
  144 DPI in one TIFF.

The release app remains named `Sorty.app`, matching its saved icon location.
Both `Sorty.dmg` and `Sorty.zip` are GitHub release assets; Sparkle uses the ZIP.
