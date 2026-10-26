# Agent skill routing

Use a skill when its capability matters to the requested task. Read its entrypoint once, then load only relevant references. This guidance does not change the repository's build or test policy.

Unslop has a compact writing checklist; its longer examples are optional. Ponytail and its helper commands are explicit-only in Codex. The main Ponytail skill is scoped to one request and does not impose test artifacts, response limits, or persistent modes. Claude's per-user `skillOverrides` applies the same manual-only selection policy on this Mac.

`swift-concurrency-pro` is the sole concurrency entrypoint. The former expert's three diagnostic/migration references remain under its `references/migration/` directory. `swift-accessibility-skill` is the SwiftUI/UIKit accessibility entrypoint and retains the retired SwiftUI audit checklist. Keep the separate AppKit auditor for AppKit-specific audits.

For UI refinement, preserve the native control, interaction, visual identity, and motion. Keep keyboard and assistive input usable. Test the specific reported behavior when authorized; report runtime uncertainty accurately. During shared-checkout work, coordinate Git writes and builds, inspect exact staged paths, and reverse only the current task's edits.

These are intentional local customizations to installed skills. An upstream skill update can overwrite them; review the diff before accepting an update. Source entries in `skills-lock.json` record upstream provenance, not a new upstream version for these customizations. Retired entrypoints are removed from that lockfile. Git history preserves their previous contents and the original material remains in the selected surviving references.
