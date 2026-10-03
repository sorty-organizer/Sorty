# Agent mode

Agent mode covers local, reversible filesystem work in an agent environment. Native Sorty is optional. Read the saved skill profile before planning, following [import-settings.md](import-settings.md).

## Plan format

Write UTF-8 JSON with this shape:

```json
{
  "version": 2,
  "source_root": "/absolute/source/folder",
  "mode": "organizeAndRename",
  "operations": [
    {
      "source": "Inbox/report draft.pdf",
      "destination": "Documents/Reports/quarterly-report.pdf",
      "expected": {
        "kind": "file",
        "size": 48102,
        "device": 16777234,
        "inode": 912345,
        "modified_ns": 1788163200000000000
      }
    }
  ],
  "tags": [],
  "exclusions": ["**/.git/**", "Archive/**"],
  "duplicate_groups": [],
  "unorganized": [
    {"path": "mystery.bin", "reason": "No reliable category"}
  ],
  "warnings": []
}
```

`source` paths must resolve inside `source_root`. Relative destinations resolve inside that root. Absolute destinations are allowed for a user-selected storage location, but the helper still refuses collisions. Keep `tags` empty in agent mode because Finder tag mutation belongs to native Sorty. Existing tags and other extended attributes move with the file.

Modes enforce intent:

- `organize`: a destination may change the parent directory, but the basename must stay unchanged.
- `renameOnly`: a destination must stay in the same parent directory.
- `organizeAndRename`: both may change.

Operations are one-to-one moves. Do not use a directory operation when the plan only intends to move some descendants. Do not plan a source and one of its descendants separately.

Copy the matching `scan` item's `snapshot` object into the operation's `expected` field. Apply rejects the plan if the item was replaced or changed after scanning. Never synthesize these values. Extension changes are rejected unless the operation includes `"allow_extension_change": true`; use that field only when the user explicitly asked to change file types or extensions.

## Workflow

1. Run `scan` with explicit exclusion globs. The scanner also enforces imported exclusions, skips hidden entries, and treats packages as single items by default.
2. Use names, extensions, sizes, dates, current folders, and the user's instructions to create the plan. Follow [planning-quality.md](planning-quality.md). Ask before reading contents or extracting image/document data.
3. Run `validate` after planning and again immediately before apply. Present moves, renames, unorganized items, warnings, and collisions.
4. Apply only under the authorization rules in `SKILL.md`.
5. Keep the returned journal path. Report counts and any incomplete operation.
6. For rollback, inspect the journal first. The helper restores completed operations in reverse order and refuses occupied original paths.

## Apply and recovery

The helper writes a `pending` journal row before each move and a `completed` row after it. A cross-volume move copies to a temporary sibling, verifies content, publishes the destination without overwrite, then removes the source. File verification uses SHA-256. Directory verification compares a deterministic tree manifest with file hashes.

Relative destinations must remain inside `source_root` after resolving existing parent symlinks. The helper also rejects stale source snapshots, control characters, dot segments, case-insensitive destination collisions, silent extension changes, occupied destinations, and plans that move a directory into itself.

If apply stops, rerun neither apply nor rollback blindly. Inspect the last journal rows and filesystem state. A pending row with only the source present did not publish. A pending row with only the destination present likely published before completion was recorded. Resolve that row before continuing.

Rollback never deletes an occupied original path and never overwrites. It records restored operations in the same journal.

## Duplicate handling

`duplicates` groups regular files by size, then confirms byte equality with SHA-256. Treat hard links as one stored object and report their paths without proposing deletion. A duplicate report is evidence, not deletion authorization.

Do not call filename, size, date, perceptual, embedding, or model similarity an exact duplicate. Route semantic duplicates to native Sorty.
