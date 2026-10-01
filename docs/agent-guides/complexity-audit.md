# Complexity audit decisions

The 1 October 2026 repo-wide ponytail audit is a list of candidates, not proof
that each replacement preserves behavior. Line counts alone do not justify
removing a feature or a safety check.

## Implemented

- Remove the repo-local SwiftData and UIKit auditor skills. Sorty persists to
  files and defaults and uses SwiftUI and AppKit.
- Remove the generic design-principles and design-philosophy skills. Keep
  `swiftui-pro`, UI patterns, and view refactoring for code guidance, with
  AGENTS.md defining Sorty's design constraints.
- Remove the animation-generation skill. Keep its earlier audit as historical
  context, with a notice that its proposals are not an implementation checklist.
- Remove the corresponding entries from `skills-lock.json`.

These edits affect agent guidance only. No app build or UI verification was
run for this batch, as required for minor changes by AGENTS.md.

## Keep

| Candidate | Reason |
| --- | --- |
| Xcode file lists | The project builds app, Finder, and widget targets and compiles asset catalogs. SPM is not a drop-in replacement for that packaging. |
| Build scripts and Makefile commands | Bundle assembly, signing, safe shutdown, resource compilation, and separate hot/coverage caches are outside SPM's incremental compiler. |
| Hot reload | Already gated by `SORTY_HOT_RELOAD` and `make hot`. |
| Quality support | Independent of the app graph; removing it from tests would remove the corpus evaluator's test dependency. |
| Next.js and PostHog skills | The repo includes a Next.js website and the app uses PostHog. |
| SwiftUI and AppKit accessibility guidance | Both frameworks have production callers. Keep the shared accessibility skill too. |
| CostCalculator pricing | Replacing every model's estimate with a baseline changes displayed costs, including local models. |
| Path validators and canonicalization | File URLs, tilde expansion, relative paths, symlinks, and trust-boundary rejection have distinct contracts. |
| Keychain caches and provider auth APIs | NSCache does not replace locking or negative-cache expiry. Sync and async auth paths have different callers. |
| Telemetry and keychain adapters | They preserve the documented leaf-target dependencies. Calling Core directly would reverse those dependencies. |
| State, hashing, and progress locks | Cancellation and cross-task mutations require synchronization. A single caller does not make a lock redundant. |
| Resource fallback lookup | Xcode and packaged SwiftPM apps place resources differently. |
| UserDefaultsDataReader | Read-only background-loading boundary required by the startup guide. |
| UI, onboarding audio, credits, and vendored visuals | Replacements proposed in the audit change behavior or appearance. They need a specific product decision and appropriate runtime evidence. |
| Test matrices | Unicode, learning scores, parsing, resources, and persistence are app contracts. Retain unless a stronger test demonstrably covers the same risk. |
| One-type files and re-exports | Merging files or adding imports at every caller does not by itself remove runtime complexity. |
| Sparkle key and version scripts | Manual tools need no source callers. Version bumping has an active release caller. |

The proposed 16,323-line and five-dependency reductions remain unverified.
No build-speed or runtime-performance improvement is claimed.
