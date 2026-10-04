# Code and test audit, 4 October 2026

Discovery inventoried the app targets, unit/UI tests, website, scripts, and local
packages, then traced callers, tests, CI routing, and history for the changes
below. This is a repository-wide discovery pass with focused owner reviews,
not a claim that every line or runtime path was exercised.

## Bugs fixed

- Single-file cross-volume moves checked size but missed same-size source edits
  before deleting the source. Fresh modification-time and file-identity checks
  now reject those copies and remove their staging files.
- Directory transfers checked total bytes and the newest timestamp, skipped
  hidden files/package contents, and could accept an edited older child. Fresh
  per-path attributes now include all children; unreadable directories fail the
  snapshot instead of producing an incomplete verification result.
- Finder status text referred to a deleted Repair button and promised Finder
  restarts. It now describes automatic registration and macOS Extensions setup.
- Three existing Blacksmith failures asserted retired behavior: unsorted prompt
  input, the manual Finder status button, and settings remaining on Organize.
  Retained tests now enforce deterministic complete prompts, the visible Finder
  setup control, and current Settings routing/selection clearing.

Transfer verification compares metadata and sizes, not content hashes. It does
not provide a filesystem lock against a writer editing after verification.

## Ranked complexity cuts

- `delete:` Abandoned Finder repair, app staging, re-signing, and verification
  polling. Replace with the existing registration-maintenance path.
  [ExtensionCommunication](../../Sources/SortyCore/FinderExtension/ExtensionCommunication.swift)
- `delete:` Uncalled filesystem creation/move/tagging implementations and global
  scope-release helper. Keep the active progress-aware apply path and per-call
  scope ownership.
  [FileSystemManager](../../Sources/SortyFS/FileSystemManager.swift)
- `delete:` Uncalled onboarding phase accents, ambient-pulse aliases, and
  completion fanfare, including its permanently inactive render branch. Keep
  the soundtrack, synthesized fallback melody/bass, preparation, and fade.
  [OnboardingAudioManager](../../Sources/SortyLib/Utilities/OnboardingAudioManager.swift)
- `delete:` Uncalled async batch/cache-invalidation hooks, Learnings scan-state
  refresh helper, and Finder four-character-code converter. Replace with nothing.
  [FolderOrganizer](../../Sources/SortyOrganizer/FolderOrganizer.swift),
  [LearningsManager](../../Sources/SortyLearnings/LearningsManager.swift),
  [FinderAutomation](../../Sources/SortyCore/FinderExtension/FinderAutomation.swift)

No dependency deletion was established. Keep leaf-target telemetry/keychain
adapters, provider routing, path validation, startup hydration, signing assets,
and stored staged-app identity validation for uninstall. They have real callers
or independent safety/packaging contracts.

## Test decisions and proof

[Test-audit evidence](test-audit.md) records the seven removed test methods and
empty UI fixture, their actual signal, history, remaining proof, and validation
ownership. Keep config/security/storage/architecture and packaging tests; simple
assertions are not evidence that a contract is redundant.

The two new transfer regressions were extracted unchanged into a temporary
SwiftPM test target against the actual SortyFileSystem/SortyModels/SortyFS
sources, without mocks or a new production hook. The single-file test failed
before repair with the source missing and an obsolete destination present.
The directory table failed for all three cases: an older child, a hidden child,
and an app-bundle child. Both pass after repair. The existing
`testCrossVolumeCopyVerifiesContentMetadataAndTree` also passed there, covering
normal copy/rename, modification metadata, progress, tree content, and undo.
Three focused tests passed. Temporary harness files and logs live outside git.

Local app builds and native UI tests were not run for deletion-only batches.
`git diff --check` passed. Hosted [Swift CI run 37175669349](https://github.com/sorty-organizer/Sorty/actions/runs/37175669349)
passed for code commit `90a654f6`: full compilation, app packaging, unit suite,
prerelease validation, and the security-check job. The earlier dispatched run,
37175507732, was cancelled by concurrent main-branch work.
The imported OpenClaw/Vitest/autoreview commands are absent, as already recorded
in test-audit.md. Changes received a caller audit and manual diff review; no
unavailable check is claimed.

## Follow-ups kept separate

- ContentAnalyzer.analyzeFiles and ImageVisionAnalyzer.prepareImagesForVision
  appear to serve tests alone. Retain until progress/cancellation coverage is
  traced and preserved at the live scanner/prepareFilesForVision boundaries.
- Several unselected UI tests still refer to retired controls. Retain until each
  persistence/accessibility contract has a current owner and supported fixture.
- Dependabot alert
  [84](https://github.com/sorty-organizer/Sorty/security/dependabot/84) concerns
  transitive `braces@3.0.3`. Commit `6ed22ecd` already mitigates
  [GHSA-vfj7-8cjw-p6xm](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm)
  with a pnpm patch limiting parser nesting and recursive compile, expand, and
  stringify AST traversal. The lockfile applies the patch to micromatch's
  dependency, and website CI installs with `--frozen-lockfile`. On October 5,
  source review confirmed this wiring; no local verification was run. The
  advisory still lists no patched release. Keep the patch until an upstream
  fix is available, then replace it with the fixed dependency version.

## Measured changes

Production: 58 lines added, 874 deleted; net -816.
Tests: 84 lines added, 210 deleted; net -126.
Xcode test membership: four lines deleted. Documentation is counted separately.
These counts include this audit's changes only; concurrent UI work is excluded.
No PR was created; coherent commits were pushed to main.

net: -942 production/test lines, -0 deps possible.
