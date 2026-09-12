# Rendering and refresh performance

Keep visible animations, frame rates, Reduce Motion behavior, and file previews intact when reducing rendering work.

## September 12, 2026 changes

- `ThinkingOrbLoaderView` builds the sphere vertices outside its animation timeline. Frames still perform the same projection, depth sorting, shading, and drawing at the existing 60 Hz maximum. Geometry follows the proposed view size.
- `AppKitImageView` assigns scaling, opacity, and layer properties only when their values change. Image identity checks remain in place. This avoids redundant setter calls when parent views update during animation or progress reporting.
- `CometLoader` pauses its timeline when its window is occluded or minimized, retaining its animation phase until the window is visible again. A visible window continues animating when it loses keyboard focus.
- `RefreshManager.pause()` parks timer deadlines and retains each remaining interval. Repeated pause/resume calls are idempotent, and timers scheduled while paused wait for resume. This affects callers that explicitly pause refreshes; it does not automatically suspend background organization or watcher services.

## Validation and limits

`swift build --scratch-path ~/Library/Caches/Sorty/build --target SortyLib` passed. The checkout-local `.build` attempt compiled the sources but failed writing its build database; the configured cache completed successfully.

A standalone SwiftUI ImageRenderer comparison rendered the original and optimized globe at 2x scale. All 30 frames were pixel-identical across sizes 18, 32, 48, 64, and 100 points, three animation times, and light/dark appearance. This validates the drawing math, not full-app layout or frame pacing.

A standalone check compiled the actual RefreshManager source and exercised immediate delivery, parked deadlines, repeated pause/resume, cancellation, and scheduling while paused. Foundation clamps distant timer dates, so the check verifies that the deadline is far in the future rather than requiring exact equality with `Date.distantFuture`.

Whole-app idle CPU, GPU use, memory, battery use, and interaction latency have not been measured for this change. Compare the same signed build configuration, window state, and data before reporting gains. Include visible focused, visible unfocused, occluded, and minimized windows; large file lists; active analysis; and Reduce Motion. Component image comparisons do not replace those runtime checks.
