# Agent skill routing

Use a skill when its capability matters to the requested task. Read its entrypoint once, then load only relevant references. This guidance does not change the repository's build or test policy.

- **Repo-local skills (`.agents/skills/`):** `sorty` (bundled user-facing file-organization skill), `sorty-release` (release checklist), and `test-audit` (test authoring and pruning gate).
- **Shared global skills (`~/.agents/skills/`):** Swift/SwiftUI/AppKit skills (`swiftui-pro`, `swift-concurrency-pro`, `swift-testing-pro`, `swift-accessibility-skill`, `appkit-accessibility-auditor`, `swiftui-performance-audit`, `swiftui-liquid-glass`, `swiftui-ui-patterns`, `swiftui-view-refactor`, `app-intents`, `swift-focusengine-pro`), `unslop`, `agents-md`, and the explicit-only `ponytail*` commands.

`swift-concurrency-pro` is the sole concurrency entrypoint (retaining diagnostic/migration references under `references/migration/`). `swift-accessibility-skill` is the SwiftUI/UIKit accessibility entrypoint; keep `appkit-accessibility-auditor` for AppKit-specific audits. Ponytail commands are explicit-only and scoped to one request.

For UI refinement, preserve the native control, interaction, visual identity, motion, and Reduce Motion behavior. Keep keyboard and assistive input usable, test the specific reported behavior when authorized, and distinguish build, install, and runtime evidence. During shared-checkout work, coordinate Git writes and builds, stage exact task paths, and revert only the current task's edits.
