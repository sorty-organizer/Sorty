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

The release workflow runs `scripts/package-dmg.sh` after validating the app.
It scales the PNG to a 464 × 564 Finder window and uses `scripts/dmg-settings.py`
to center Sorty above the Applications shortcut, alongside the cursor trail.
Both icons use a 112-pixel size. The TIFF is also available for
manual use in DMG Canvas. Check the Finder layout before publishing.
