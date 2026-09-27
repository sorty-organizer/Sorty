import Foundation

/// Rewrites storage-like relative aliases (for example "storage/Excel") into approved absolute storage paths.
enum StorageDestinationNormalizer {
    static func normalize(
        plan: OrganizationPlan,
        allowedStorageLocations: [StorageLocation],
        sourceDirectoryURL: URL? = nil
    ) -> OrganizationPlan {
        let canonicalRoots = Array(Set(allowedStorageLocations.map { StorageLocationPathResolver.canonicalPath($0.path) })).sorted()
        guard !canonicalRoots.isEmpty else { return plan }

        let aliasMap = buildAliasMap(locations: allowedStorageLocations)

        let canonicalSourceRoot = sourceDirectoryURL.map { StorageLocationPathResolver.canonicalPath($0.path) }

        var normalizedPlan = plan
        normalizedPlan.suggestions = plan.suggestions.map {
            normalizeFolder($0, aliasMap: aliasMap, canonicalStorageRoots: canonicalRoots, canonicalSourceRoot: canonicalSourceRoot)
        }

        return normalizedPlan
    }

    private static func normalizeFolder(
        _ folder: FolderSuggestion,
        aliasMap: [String: String],
        canonicalStorageRoots: [String],
        canonicalSourceRoot: String?
    ) -> FolderSuggestion {
        var updated = folder
        updated.folderName = normalizeFolderName(
            folder.folderName,
            aliasMap: aliasMap,
            canonicalStorageRoots: canonicalStorageRoots,
            canonicalSourceRoot: canonicalSourceRoot
        )
        updated.subfolders = folder.subfolders.map {
            normalizeFolder($0, aliasMap: aliasMap, canonicalStorageRoots: canonicalStorageRoots, canonicalSourceRoot: canonicalSourceRoot)
        }
        return updated
    }

    private static func normalizeFolderName(
        _ rawFolderName: String,
        aliasMap: [String: String],
        canonicalStorageRoots: [String],
        canonicalSourceRoot: String?
    ) -> String {
        if let absolutePath = StorageLocationPathResolver.normalizedAbsolutePath(from: rawFolderName) {
            // Already within a valid storage root — keep as-is
            if canonicalStorageRoots.contains(where: { StorageLocationPathResolver.isPath(absolutePath, within: $0) }) {
                return absolutePath
            }

            // Absolute path inside source directory — the AI likely meant to reference a
            // storage location by name but mistakenly prepended the source directory path.
            // Strip the source prefix and run the relative portion through alias matching.
            if let sourceRoot = canonicalSourceRoot,
               StorageLocationPathResolver.isPath(absolutePath, within: sourceRoot),
               absolutePath != sourceRoot {
                let prefix = sourceRoot == "/" ? "/" : sourceRoot + "/"
                let relativePortion = String(absolutePath.dropFirst(prefix.count))
                if !relativePortion.isEmpty {
                    let resolved = resolveRelativeAlias(relativePortion, aliasMap: aliasMap)
                    return resolved
                }
            }

            return absolutePath
        }

        let canonicalRelative = StorageLocationPathResolver.canonicalPath(rawFolderName)
        guard !canonicalRelative.isEmpty else { return canonicalRelative }

        if let explicitStoragePath = resolveExplicitStorageMarker(
            canonicalRelative,
            canonicalStorageRoots: canonicalStorageRoots
        ) {
            return explicitStoragePath
        }

        return resolveRelativeAlias(canonicalRelative, aliasMap: aliasMap)
    }

    private static func resolveExplicitStorageMarker(
        _ relativePath: String,
        canonicalStorageRoots: [String]
    ) -> String? {
        guard canonicalStorageRoots.count == 1, let storageRoot = canonicalStorageRoots.first else {
            return nil
        }

        let segments = relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let firstSegment = segments.first else { return nil }

        let explicitAliases = Set([
            "storage",
            "storage location",
            "storage locations",
            "storage-location",
            "storage-locations",
            "storage folder"
        ].map(normalizeAlias))

        guard explicitAliases.contains(normalizeAlias(firstSegment)) else {
            return nil
        }

        guard segments.count > 1 else { return storageRoot }

        var resolvedURL = URL(fileURLWithPath: storageRoot, isDirectory: true)
        for segment in segments.dropFirst() {
            resolvedURL.appendPathComponent(segment, isDirectory: true)
        }
        return StorageLocationPathResolver.canonicalPath(resolvedURL.path)
    }

    private static func resolveRelativeAlias(_ relativePath: String, aliasMap: [String: String]) -> String {
        let canonical = StorageLocationPathResolver.canonicalPath(relativePath)
        guard !canonical.isEmpty else { return canonical }

        // Try normal alias on the whole path
        if let rootPath = aliasMap[normalizeAlias(canonical)] {
            return rootPath
        }

        // Try compact alias (strips spaces for PascalCase matching)
        if let rootPath = aliasMap[compactAlias(canonical)] {
            return rootPath
        }

        let segments = canonical
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let first = segments.first else { return canonical }

        // Try normal alias for first segment
        var rootPath: String? = aliasMap[normalizeAlias(first)]

        // Try compact alias for first segment
        if rootPath == nil {
            rootPath = aliasMap[compactAlias(first)]
        }

        guard let resolvedRoot = rootPath else { return canonical }
        guard segments.count > 1 else { return resolvedRoot }

        var resolvedURL = URL(fileURLWithPath: resolvedRoot, isDirectory: true)
        for segment in segments.dropFirst() {
            resolvedURL.appendPathComponent(segment, isDirectory: true)
        }

        return StorageLocationPathResolver.canonicalPath(resolvedURL.path)
    }

    private static func buildAliasMap(locations: [StorageLocation]) -> [String: String] {
        // Collect root-level storage location aliases only.
        // Avoid implicit subfolder aliasing so storage is used only with explicit intent.
        var rootAliasEntries: [String: Set<String>] = [:]

        func addRootAlias(_ alias: String, rootPath: String) {
            let normalized = normalizeAlias(alias)
            guard !normalized.isEmpty else { return }
            rootAliasEntries[normalized, default: []].insert(rootPath)
        }

        func addRootCompact(_ alias: String, rootPath: String) {
            let compact = compactAlias(alias)
            guard !compact.isEmpty else { return }
            rootAliasEntries[compact, default: []].insert(rootPath)
        }

        for location in locations {
            let rootPath = StorageLocationPathResolver.canonicalPath(location.path)
            addRootAlias(location.name, rootPath: rootPath)
            addRootAlias(URL(fileURLWithPath: rootPath).lastPathComponent, rootPath: rootPath)
            addRootCompact(location.name, rootPath: rootPath)
            addRootCompact(URL(fileURLWithPath: rootPath).lastPathComponent, rootPath: rootPath)
        }

        // Resolve root aliases only when unambiguous.
        var resolved: [String: String] = [:]
        for (alias, roots) in rootAliasEntries where roots.count == 1 {
            if let rootPath = roots.first {
                resolved[alias] = rootPath
            }
        }

        return resolved
    }

    private static func normalizeAlias(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let lowered = trimmed.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        return lowered
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func compactAlias(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
