# SwiftUI Quality Baseline

Use this baseline when changing Sorty's macOS SwiftUI surfaces.

## Interaction and accessibility

- Use native `Button`, `Toggle`, `TextField`, and `Menu` controls for standard
  interactions. A gesture-only surface must also provide keyboard and named
  accessibility actions.
- Use `.accessibilityElement(children: .contain)` when a container has child
  controls. Combining the container hides those controls from VoiceOver.
- Keep decorative animation, icons, and particle effects out of the
  accessibility tree. Do not hide adjacent status text.
- Prefer semantic text styles to fixed point sizes for user-facing text. Fixed
  sizes remain appropriate for decorative symbols and tightly specified art.
- Verify VoiceOver order, Full Keyboard Access, Voice Control names, increased
  contrast, and Reduce Motion in the running app.

## Motion and rendering

- Reduce Motion must stop continuous schedules and repeating tasks, not only
  freeze the rendered phase. Pause or remove `TimelineView` clocks and disable
  auto-rotating content while the setting is active.
- Keep `TimelineView` refresh rates proportional to the effect. Loading pulses
  do not need display-rate updates.
- Avoid sorting, filtering, formatting, or allocating large collections inside
  per-frame closures. Precompute stable inputs outside the render loop.
- Build focus-ring strokes and blur layers only while the target is active.
  Transparent effects still add rendering work across dense Settings pages.
- Update Settings sidebar selection in the click event. Keep the shared route
  synchronized without publishing unchanged values or deferring local selection
  to a second update pass.
- Treat build duration as build-system evidence only. Performance claims require
  repeated measurements of the same running-app workflow.

## State and concurrency

- Managers that publish UI state remain `@MainActor` and are injected from the
  app root.
- Store tasks whose results can outlive or supersede an interaction. Cancel the
  previous task before starting a replacement and check cancellation before
  mutating state.
- Prefer duration-based sleeps such as `Task.sleep(for: .milliseconds(150))`.
- Keep blocking file and network work away from the main actor, then return to
  the main actor for observable state changes.

## Verification

- `make dev` verifies compilation, assembly, and signing; it does not verify the
  rendered interface.
- `Tests/SortyUITests/AppAccessibilityTests.swift` runs system accessibility
  audits for onboarding and every primary screen when the UI-test target is
  available.
- Use targeted XCTest assertions for observable controls and state. A test that
  only logs a missing control is not a regression test.
- Record any UI-test runner, permission, or runtime-measurement limitation in the
  handoff instead of treating a successful build as equivalent evidence.
