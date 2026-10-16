#!/bin/bash
# Compile the real leaf sources without fetching app dependencies or launching Sorty.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/sorty-fuzz.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 6 -package-name Sorty -O -g \
    -module-cache-path "$scratch/modules" \
    Sources/SortyFileSystem/FilenameSanitizer.swift \
    Sources/SortyFileSystem/StorageLocationPathResolver.swift \
    Sources/SortyFileSystem/RenameRuleEngine.swift \
    scripts/fuzz/main.swift -o "$scratch/sorty-fuzz"
"$scratch/sorty-fuzz" "$@"
