# Large-folder organization

All three Organize workflows share the same bounded pipeline:

1. `DirectoryScanner` enumerates incrementally, publishes coarse progress, and limits deep content analysis to 2,000 files per run. It still retains the complete lightweight `FileItem` inventory because every source file must remain addressable through preview and apply.
2. `FolderOrganizer` sends bounded concurrent AI batches: 350 files for organize-only and 120 files for rename or organize-and-rename. Assignments merge in order by file identity. There is no separate taxonomy-planning or placement-review request.
3. `ResponseParser` indexes the batch inventory by ID, exact name, case-folded name, and extension so ordinary assignments resolve in constant time. Partial-name matching remains a fallback only.
4. `PreviewStore` starts plans above 2,000 files collapsed and renders at most 500 file rows per expanded section. Hidden rows remain in the plan and are included when applying it.
5. `FileSystemManager` builds per-folder rename/tag indexes once, throttles operation progress callbacks, and preserves the full operation journal required for partial-failure recovery and undo.

Streaming AI text is capped at 256,000 retained characters and 48,000 UI-presented characters. Preview-version undo is disabled for plans above 20,000 files to avoid retaining several complete copies of a very large plan.

When changing these paths, keep progress tied to measured work, avoid per-file main-actor publications, and never trade away complete apply coverage for a smaller preview.

Preview shows the proposed destinations without structural quality scores,
parse-warning notices, confidence summaries, or filename-collision cards.
Apply uses the normal confirmation and file-system conflict handling.

Main navigation takes its dimensions from the window viewport, including windows
smaller than the former 1,000 by 700 point minimum. HUD, link-hover, and consent
views are overlays so they do not change the sidebar or page size. Settings
uses the same overlay rule and scrolls its category sidebar in short windows.
Learnings fills the available page without imposing a separate minimum size.
The shared link-hover host follows this rule in About, Thanks, What's New,
Accreditations, and Internet Access Policy windows.

Manual-session snapshots store only direct user instructions. Assembled request
context stays inside the AI pipeline. Legacy snapshots recover the user block
and remove generated exclusions before populating the Instructions editor.
See [Organization quality](organization-quality.md) for the retained learning
and measurement behavior.
