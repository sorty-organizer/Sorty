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

## Battery work, September 12, 2026

- `LoadingDotsView`, `BouncingSpinner`, `FocusedInstructionBeamBorder`, and the circular progress shimmer pause their timelines when their window is hidden, occluded, or minimized. Visible frame rates, drawing code, and Reduce Motion behavior stay the same. The progress shimmer also parks its timeline at zero progress, where its trimmed arcs have no visible length.
- The instruction editor cycles suggestions only while its text is empty, its window is visible, and it has multiple suggestions. Typing or hiding the window cancels the sleep task. Clearing the editor or restoring the window resumes cycling at the existing 3.5-second interval.
- Refresh and Finder-selection timers allow macOS to coalesce wakeups with 10% tolerance, capped at 0.5 seconds. Their repeating intervals and immediate refresh behavior stay intact.
- Streaming display preparation walks only the 48,000-character display suffix and 1,000-character preview suffix. Progress counting stops at its existing target, and stops entirely once progress reaches 80%. The short-response insight check reads at most 21 characters. All boundaries use Swift characters, preserving composed Unicode text.

Validation for this pass:

- `swift test --scratch-path ~/Library/Caches/Sorty/build --disable-sandbox --filter StreamingLogicTests` passed all 48 tests. New cases cover composed Unicode at truncation boundaries and long-response progress with live insights enabled and disabled. The first checkout-local build encountered a database write error and ran an older test binary, so its result was excluded.
- A temporary native SwiftUI window rendered the actual dots, spinner, and instruction-border source with frame counters. Over two seconds, the visible counts were 24, 61, and 244. Hidden and minimized counts were zero for all three. After restoring the window, all three resumed at their original rates. This checks component lifecycle behavior, not the full app's layout or energy use.
- An optimized standalone benchmark compared the original and changed streaming-payload functions on the same 248,000-byte Unicode response and asserted identical output. Median time across five batches of 100 calls was 0.2651 seconds before and 0.04584 seconds after, about 83% less time for this operation. This does not measure total analysis time or battery life.

Full-app power measurements remain outstanding. Background organization, file watching, network requests, and visible animations retain their existing behavior.
