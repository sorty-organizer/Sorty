# Fuzzing

Run on macOS with Xcode command-line tools:

```sh
bash scripts/fuzz.sh
bash scripts/fuzz.sh --seed 42 --iterations 100000
bash scripts/fuzz.sh --iterations 0  # Fixed boundary corpus only
```

The runner compiles the actual filesystem and model modules, `ResponseParser`,
and the shared JSON extractor with Swift 6. It uses a temporary directory for
its executable, libraries, and compiler cache, then removes them on exit. It does not launch
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
- Complete and partial organization plans account for every input exactly once.
  Qualified paths select the correct file even when basenames collide, while
  ambiguous bare names remain unresolved. Exact names outrank stem aliases.
- Compact IDs select their indexed input. Partial recovery rejects boolean and
  fractional IDs and stops at metadata rather than treating its numbers as IDs.
- Streaming recovery decodes escaped filenames, and organize mode discards
  rename suggestions.
- JSON extraction handles reversed delimiters without crashing, and quoted
  brackets or escaped quotes do not split otherwise valid objects and arrays.

This is a seeded mutation and property fuzzer, not a coverage-guided engine.
It combines a fixed corpus with mutations involving Unicode, combining marks,
emoji, separators, whitespace, dots, and byte-length boundaries. Regex patterns
are bounded fixtures, not arbitrary patterns that could stall Foundation.
It does not cover network providers, filesystem apply/undo, concurrency, or UI.

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

## Parser findings

The parser cases failed against the original implementation before repair:

- A qualified path could resolve through its basename before checking the
  relative-path index. Duplicate basenames and stem aliases also selected the
  first scanned file. Lookup now prioritizes qualified paths and exact names,
  and leaves ambiguous references unresolved with the existing review warnings.
- Streaming ID recovery coerced booleans and fractions through `NSNumber`, or
  scraped numbers from later metadata. Completed lists now decode integers;
  unfinished lists stop at the first invalid token. Partial rename IDs require
  a complete integer token too.
- Partial string arrays returned raw JSON escapes, so filenames containing
  escaped slashes, quotes, or backslashes were lost. Recovery now decodes string
  literals, including folder names. `./` references are also tried before
  interpreting backslashes as separators.

The extractor lives in `LLMJSONExtractor.swift` so this runner compiles the
same implementation as provider requests without linking the networking code
that previously shared its file. SwiftPM discovers it in the existing SortyAI
target; the Xcode app links that package product.

The extractor check also reproduced a process crash for `] [` and `} {`.
Fallback extraction now searches for a closing delimiter after its opening
delimiter, rather than constructing an invalid Swift range.

For the parser repair, seed 42 with 100 mutations failed seven contracts against
the original parser. The repaired implementation passed 70,006 parser cases and
5,004 extractor cases with 5,000 mutations of that seed. These are local
diagnostics, not a claim that the full hosted suite passed.
