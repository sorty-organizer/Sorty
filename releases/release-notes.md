## Sorty 1.2.1

A maintenance update with a refreshed app icon, faster launch, lower idle CPU use, faster large-folder planning, and reliability fixes.

### New
- Updated the main Sorty app icon with the new release artwork.
- Added in-app support checks and clearer diagnostics for watched folders and Finder integration.

### Improved
- Cut median time to the first visible window from 2,262 ms to 1,127 ms in a same-machine Release comparison with eight runs per build.
- Reduced settled idle CPU from a 51.4% mean to 0% in a 60-second visible-window test with no animated HUD. Minimized-window idle CPU also fell from about 55% to 0%; with an animated HUD, measured CPU was 16.5%, about three times below the previous idle result.
- Capped organization prompts for very large folders. In a 1,000-file deep-scan benchmark, the prompt fell from 132,059 tokens to 11,961, and preparation time fell from 12.1 ms to 5.0 ms. At 200 files, prompt size fell 56%; at 350 files, 74%; and at 500 files, 82%.
- Reduced repeated context in multi-batch AI requests by 81% in a 1,050-file benchmark, and cut repeated text-feature work in the duplicate-detection benchmark by 86%.
- Cut progress-line parsing work by 45%, removed repeated full-list scanning from the 120-frame flight queue benchmark, and reduced 100 Unicode stream-counting runs from 40.6 seconds to about zero.
- Reduced repeated work during organization, AI streaming, duplicate review, and persisted-state loading.

### Fixed
- Fixed organization, cancellation, and undo edge cases, including overlapping runs.
- Fixed Finder action routing, permission recovery, provider errors, and stale status after configuration changes.
