# Fuzzing

Run on macOS with Xcode command-line tools:

```sh
bash scripts/fuzz.sh
bash scripts/fuzz.sh --seed 42 --iterations 100000
bash scripts/fuzz.sh --iterations 0  # Fixed boundary corpus only
```

The runner compiles the actual `FilenameSanitizer`, `StorageLocationPathResolver`,
and `RenameRuleEngine` sources with Swift 6. It uses a temporary directory for
its executable and compiler cache, then removes both on exit. It does not launch
Sorty, fetch package dependencies, call AI providers, or modify user files.

## Contracts

- Accepted filenames contain no separators or NUL and fit within 255 UTF-8 bytes.
- Sanitizing an accepted filename again with the same options gives the same name.
- Ordinary and compound extensions survive truncation with a nonempty basename.
- Safe Unicode filenames remain accepted and unchanged. Empty names, reserved
  names, and extension-only names remain rejected.
- Path containment agrees with standardized URL path components, including
  sibling prefixes and traversal. These are lexical checks, not symlink checks.
- Literal rename rules match standard-library replacement behavior. Invalid
  regexes leave filenames intact, and chained rules apply captures in order.

This is a seeded mutation and property fuzzer, not a coverage-guided engine.
It combines a fixed corpus with mutations involving Unicode, combining marks,
emoji, separators, whitespace, dots, and byte-length boundaries. Regex patterns
are bounded fixtures, not arbitrary patterns that could stall Foundation.
It does not cover AI response parsing, filesystem apply/undo, concurrency, or UI.

## Failures and replay

A failed contract exits with status 1 and prints its first input as JSON, the
output, and a replay command. Swift crashes also fail the command. Keep the
reported seed and iteration count to reproduce the generated sequence in the
same revision. Argument errors exit with status 2.

The fixed cross-product runs even with zero random iterations. Put a discovered
filename or extension in its seed arrays to preserve a regression. Keep
assertions at the production owner rather than adding duplicate tests at every
caller. Acceptance checks prevent an implementation that rejects everything
from passing the safety properties.

Swift CI runs 20,000 mutations on Blacksmith macOS before compiling the full app
suite. Local fuzz runs provide focused diagnostic evidence; hosted CI remains
the source of build and test confidence.

## Initial findings

The first run against the original sanitizer failed before these repairs:

- Extension metadata could reintroduce separators or NUL after the filename
  had already been scrubbed. Extension normalization now scrubs them too.
- `report.txt` with `tar.gz` became `report.tar.gz`, then `report.tar.tar.gz`.
  Full suffix matching now preserves compound extensions across repeated calls
  and truncation.
- A basename consisting of one grapheme larger than the byte budget became
  `.txt` and was accepted. Truncation now rejects names when no complete
  basename fits, or when the extension alone exhausts the budget.
- Removing an extension could expose whitespace or another extension, causing
  preview and apply to disagree. Extensionless targets now remove the complete
  dotted suffix, and final trimming runs after adjustment and truncation.
