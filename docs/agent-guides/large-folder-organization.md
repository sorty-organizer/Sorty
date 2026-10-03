# Large-folder organization

All three Organize workflows share the same bounded pipeline:

1. `DirectoryScanner` enumerates incrementally, publishes coarse progress, and limits deep content analysis to 2,000 files per run. It still retains the complete lightweight `FileItem` inventory because every source file must remain addressable through preview and apply.
2. `FolderOrganizer` plans a shared destination taxonomy before multi-batch organization, using source-folder/type counts and representative content evidence. It then sends bounded concurrent AI batches: 350 files for organize-only and 120 files for rename or organize-and-rename. Every batch receives the shared paths, purposes, and examples. Assignments merge in order by file identity. Rename-only skips taxonomy planning.
3. `ResponseParser` indexes the batch inventory by ID, exact name, case-folded name, and extension so ordinary assignments resolve in constant time. Partial-name matching remains a fallback only.
4. `PreviewStore` starts plans above 2,000 files collapsed and renders at most 500 file rows per expanded section. Hidden rows remain in the plan and are included when applying it.
5. `FileSystemManager` builds per-folder rename/tag indexes once, throttles operation progress callbacks, and preserves the full operation journal required for partial-failure recovery and undo.

Streaming AI text is capped at 256,000 retained characters and 48,000 UI-presented characters. Preview-version undo is disabled for plans above 20,000 files to avoid retaining several complete copies of a very large plan.

When changing these paths, keep progress tied to measured work, avoid per-file main-actor publications, and never trade away complete apply coverage for a smaller preview.

Preview notices use compact neutral cards with a title, explanation, and native
bordered action. Orange marks warnings without tinting the entire card. Duplicate
filenames show an inline suggested name with a small Use suggestion button;
Resolve all accepts every pending suggestion. Incomplete-plan warnings and
blocking collision checks remain visible before Apply.

The final plan receives a bounded semantic review of up to 40 questionable
placements, sampled across destinations. One subset repair may follow. See
[Organization quality](organization-quality.md) for evidence handling and failure
behavior. Shared planning and review add AI requests; the existing assignment
token and cost statistics do not include `generateText` calls.
