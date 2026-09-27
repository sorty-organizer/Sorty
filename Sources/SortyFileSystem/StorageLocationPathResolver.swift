import Foundation

/// Normalizes and resolves storage location paths used in AI plans.
package enum StorageLocationPathResolver {
    package static func canonicalPath(_ rawPath: String) -> String {
        if let absolute = normalizedAbsolutePath(from: rawPath) {
            return absolute
        }

        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let standardized = (trimmed as NSString).standardizingPath
        return trimTrailingSlash(from: standardized.isEmpty ? trimmed : standardized)
    }

    package static func normalizedAbsolutePath(from rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.isFileURL {
            return normalizeAbsolutePath(url.path)
        }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return normalizeAbsolutePath(trimmed)
        }

        return nil
    }

    package static func absoluteURL(from rawPath: String) -> URL? {
        guard let path = normalizedAbsolutePath(from: rawPath) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    package static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    package static func isPath(_ childPath: String, within parentPath: String) -> Bool {
        let child = canonicalPath(childPath)
        let parent = canonicalPath(parentPath)

        if child == parent {
            return true
        }

        let parentPrefix = parent == "/" ? "/" : parent + "/"
        return child.hasPrefix(parentPrefix)
    }

    /// Resolves existing symbolic links before comparing or using filesystem paths.
    package static func resolvedPath(_ rawPath: String) -> String {
        let canonical = canonicalPath(rawPath)
        guard !canonical.isEmpty else { return canonical }
        return URL(fileURLWithPath: canonical).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func normalizeAbsolutePath(_ rawAbsolutePath: String) -> String {
        let expanded = (rawAbsolutePath as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        return trimTrailingSlash(from: standardized)
    }

    private static func trimTrailingSlash(from path: String) -> String {
        guard path.count > 1 else { return path }

        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }

        return result
    }
}
