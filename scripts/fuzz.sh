#!/bin/bash
# Compile the real leaf sources without fetching app dependencies or launching Sorty.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/sorty-fuzz.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
flags=(-swift-version 6 -package-name Sorty -O -whole-module-optimization -g -module-cache-path "$scratch/modules")
xcrun swiftc "${flags[@]}" -emit-library -emit-module -module-name SortyFileSystem \
    -emit-module-path "$scratch/SortyFileSystem.swiftmodule" \
    Sources/SortyFileSystem/*.swift -o "$scratch/libSortyFileSystem.dylib"
xcrun swiftc "${flags[@]}" -I "$scratch" -L "$scratch" -lSortyFileSystem \
    -emit-library -emit-module -module-name SortyModels \
    -emit-module-path "$scratch/SortyModels.swiftmodule" \
    Sources/SortyModels/*.swift \
    -o "$scratch/libSortyModels.dylib"
xcrun swiftc "${flags[@]}" -I "$scratch" -L "$scratch" -lSortyFileSystem -lSortyModels \
    -emit-executable -module-name SortyFuzz -emit-module-path "$scratch/SortyFuzz.swiftmodule" \
    -Xlinker -rpath -Xlinker "$scratch" \
    Sources/SortyAI/SortyAIDependencies.swift \
    Sources/SortyAI/ResponseParser.swift \
    Sources/SortyAI/LLMJSONExtractor.swift \
    scripts/fuzz/ParserFuzz.swift \
    scripts/fuzz/ExtractorFuzz.swift \
    scripts/fuzz/main.swift -o "$scratch/sorty-fuzz"
"$scratch/sorty-fuzz" "$@"
