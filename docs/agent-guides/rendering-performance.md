# Rendering and refresh performance

Keep visible animations, frame rates, Reduce Motion behavior, and file previews intact when reducing rendering work.

## September 12, 2026 changes

- `ThinkingOrbLoaderView` builds the sphere vertices outside its animation timeline. Frames still perform the same projection, depth sorting, shading, and drawing at the existing 60 Hz maximum. Geometry follows the proposed view size.
- `AppKitImageView` assigns scaling, opacity, and layer properties only when their values change. Image identity checks remain in place. This avoids redundant setter calls when parent views update during animation or progress reporting.
- `CometLoader` pauses its timeline when Sorty is inactive or its window is occluded or minimized. Occlusion and minimization retain the animation phase until the window is visible again. The visibility observer does not track app activation; SwiftUI freezes the timeline date while that schedule is paused.
- `RefreshManager.pause()` parks timer deadlines and retains each remaining interval. Repeated pause/resume calls are idempotent, and timers scheduled while paused wait for resume. This affects callers that explicitly pause refreshes; it does not automatically suspend background organization or watcher services.

## Validation and limits

`swift build --scratch-path ~/Library/Caches/Sorty/build --target SortyLib` passed. The checkout-local `.build` attempt compiled the sources but failed writing its build database; the configured cache completed successfully.

A standalone SwiftUI ImageRenderer comparison rendered the original and optimized globe at 2x scale. All 30 frames were pixel-identical across sizes 18, 32, 48, 64, and 100 points, three animation times, and light/dark appearance. This validates the drawing math, not full-app layout or frame pacing.

A standalone check compiled the actual RefreshManager source and exercised immediate delivery, parked deadlines, repeated pause/resume, cancellation, and scheduling while paused. Foundation clamps distant timer dates, so the check verifies that the deadline is far in the future rather than requiring exact equality with `Date.distantFuture`.

Whole-app idle CPU, GPU use, memory, battery use, and interaction latency have not been measured for this change. Compare the same signed build configuration, window state, and data before reporting gains. Include visible focused, visible unfocused, occluded, and minimized windows; large file lists; active analysis; and Reduce Motion. Component image comparisons do not replace those runtime checks.

## Battery and periodic wakeup work, September 12, 2026

- `LoadingDotsView`, `BouncingSpinner`, `FocusedInstructionBeamBorder`, and the circular progress shimmer pause their timelines when their window is hidden, occluded, or minimized. Visible frame rates, drawing code, and Reduce Motion behavior stay the same. The progress shimmer also parks its timeline at zero progress, where its trimmed arcs have no visible length.
- The instruction editor cycles suggestions every seven seconds only while its text is empty, its window is visible, Sorty is active, and it has multiple suggestions. Typing, hiding the window, or deactivating Sorty cancels the sleep task. Clearing the editor, restoring the window, or reactivating Sorty resumes cycling at the preserved suggestion index.
- Finder selection monitoring remains demand-gated, stops while Sorty is inactive, and refreshes immediately when monitoring starts. Its repeating check now runs every eight seconds with 30% timer tolerance instead of every two seconds.
- Other refresh timers retain their existing intervals and tolerance.
- Streaming display preparation walks only the 48,000-character display suffix and 1,000-character preview suffix. Progress counting stops at its existing target, and stops entirely once progress reaches 80%. The short-response insight check reads at most 21 characters. All boundaries use Swift characters, preserving composed Unicode text.
- The widget uses event-driven `WidgetCenter.reloadTimelines` updates and no longer requests an unchanged snapshot every 30 minutes.
- Folder scanning and the AI request allow idle system sleep. The apply phase keeps its separate sleep-preventing activity while it changes files.
- Rolling credits update at 15 Hz instead of 60 Hz. The glass loader updates at 20 Hz, pauses when its window is hidden or minimized, and bounds shader sampling to the effect's visible radius.
- Directory scanning yields every 50 files under normal conditions and every 10 files under memory pressure. It publishes enumeration progress and samples process memory every 1,000 files. A dispatch-source memory-pressure monitor pauses scans as soon as the scanner actor next yields.

Validation for this pass:

- `swift test --scratch-path ~/Library/Caches/Sorty/build --disable-sandbox --filter StreamingLogicTests` passed all 48 tests. New cases cover composed Unicode at truncation boundaries and long-response progress with live insights enabled and disabled. The first checkout-local build encountered a database write error and ran an older test binary, so its result was excluded.
- A temporary native SwiftUI window rendered the actual dots, spinner, and instruction-border source with frame counters. Over two seconds, the visible counts were 24, 61, and 244. Hidden and minimized counts were zero for all three. After restoring the window, all three resumed at their original rates. This checks component lifecycle behavior, not the full app's layout or energy use.
- An optimized standalone benchmark compared the original and changed streaming-payload functions on the same 248,000-byte Unicode response and asserted identical output. Median time across five batches of 100 calls was 0.2651 seconds before and 0.04584 seconds after, about 83% less time for this operation. This does not measure total analysis time or battery life.

Full-app power measurements remain outstanding. Background organization, file watching, network requests, and visible animations retain their existing behavior. These source-level wakeup reductions do not establish a battery-life delta without matched signed Release measurements.
