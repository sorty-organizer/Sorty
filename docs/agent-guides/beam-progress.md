# Beam Progress UI

Sorty's organization analysis screen uses the Beam playground card shape for
the visible progress surface in `Sources/SortyLib/Views/AnalysisView.swift`.
The What’s New CTA uses the same package’s small ocean beam with a capsule
shape in `Sources/SortyLib/Views/WhatsNew/WhatsNewTourView.swift`.
The folder-selection CTA applies that same button-sized treatment directly to
the styled `Button` in `DirectorySelectionView.swift`, activating only after
the control appears and while its window is active.
Prominent onboarding and empty-state pill actions use the shared
`onboardingBeamBorder(...)` wrapper. It deliberately maps every pill to Beam's
README-recommended `.small` capsule variant; text fields continue to use a
line-style or focused-border treatment instead of the button beam.

Important implementation details:

- Keep the main progress surface as the Beam playground-style medium card:
  `RoundedRectangle(cornerRadius: 16)`, `Color(white: 0.08)`, `370x90`, and
  `.beam(.medium, palette: .colorful, theme: .dark, cornerRadius: 16)`.
- Do not restore the old circular progress ring for the analysis screen.
- Do not add the small square elapsed-time pill below the card. It was removed
  because it was visually noisy and did not match the requested reference.
- Sorty's `make now` path builds a manual SwiftPM app bundle. In that bundle,
  SwiftPM leaves Beam's shader sources uncompiled. `scripts/build.sh` must
  compile the package's `.metal` resources into
  `Contents/Resources/Beam_Beam.bundle/default.metallib`. Sorty's vendored
  Beam 0.1.0 loader checks that signed macOS resource location before falling
  back to `Bundle.module`. Otherwise `.beam(...)` can build successfully but
  render no border in a shipped app.
- The progress card uses only Beam's shader border. Do not layer an animated
  fallback over it: the previous 12 fps gradient competed with the 30 fps
  shader and produced visibly stepped motion.
- The card stops its decorative effect while hidden, inactive, or under
  Reduce Motion. Its width transition also respects Reduce Motion.
- Qualify this as `SwiftUI.TimelineView`; Sorty has its own `TimelineView`
  type for history, and an unqualified reference resolves to the wrong type.

If this UI needs further tuning, keep a single animation driver. Avoid adding animated
blurred strokes, large drawing groups, or multiple timeline layers around this
card; they make the analysis screen lag during active organization.
