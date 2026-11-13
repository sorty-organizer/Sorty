//
//  IncomingPathValidator.swift
//  Sorty
//
//  Central validation for untrusted filesystem paths arriving via deeplinks,
//  Finder extension IPC (DistributedNotificationCenter + app-group defaults),
//  and Quick Action URL schemes. Rejects non-existent paths, non-directories,
//  and sensitive system roots unless the user explicitly picked the folder.
//

import Foundation

/// Capability probe for security-scoped bookmark access. Replaces
/// `APP_SANDBOX_CONTAINER_ID` environment sniffing, which is spoofable and
/// wrong under ad-hoc/dev signatures.
public enum SandboxEnvironment {
    /// True when the process is actually sandboxed (MAS / sandboxed dev build).
    public static var isSandboxed: Bool {
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            return true
        }
        // Direct sandbox check: sandboxed processes have a container home.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if home.contains("/Library/Containers/") {
            return true
        }
        return false
    }
}

public enum IncomingPathValidationError: LocalizedError, Equatable, Sendable {
    case empty
    case doesNotExist(String)
    case notDirectory(String)
    case blockedSystemPath(String)
    case protectedLinkPath(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "No folder path was provided."
        case .doesNotExist(let path):
            return "Folder does not exist: \(path)"
        case .notDirectory(let path):
            return "Not a folder: \(path)"
        case .blockedSystemPath(let path):
            return "Sorty cannot open this system folder: \(path)"
        case .protectedLinkPath(let path):
            return "Links can't open this folder: \(path). Choose it in Sorty instead."
        case .unreadable(let path):
            return "Sorty cannot read this folder: \(path)"
        }
    }
}

public struct IncomingPathValidator {
    /// System roots that must never be selected via deeplink/IPC without an
    /// explicit user pick in an NSOpenPanel.
    private static let blockedPrefixes: [String] = [
        "/System",
        "/private/etc",
        "/private/bin",
        "/private/sbin",
        "/private/usr/bin",
        "/private/usr/sbin",
        "/private/usr/lib",
        "/private/var/db",
        "/private/var/log",
        "/private/var/root",
        "/etc",
        "/bin",
        "/sbin",
        "/usr/bin",
        "/usr/sbin",
        "/usr/lib",
        "/var/db",
        "/var/log",
        "/var/root",
        "/Library/System",
    ]

    private static let blockedExact: Set<String> = [
        "/", "/System", "/Library", "/private", "/etc",
        "/bin", "/sbin", "/usr", "/var",
    ]

    /// Same protection applied to the symlink-resolved path. `/private` is
    /// expanded into its sensitive subtrees here instead of blocking the whole
    /// tree, because `/tmp` and `/var/folders` legitimately resolve into
    /// `/private/tmp` and `/private/var/folders` and must stay selectable.
    private static let resolvedBlockedPrefixes: [String] = [
        "/System",
        "/private/etc",
        "/private/bin",
        "/private/sbin",
        "/private/usr/bin",
        "/private/usr/sbin",
        "/private/usr/lib",
        "/private/var/db",
        "/private/var/log",
        "/private/var/root",
        "/Library/System",
    ]

    private static let resolvedBlockedExact: Set<String> = [
        "/", "/System", "/Library", "/private", "/private/etc", "/private/var",
        "/bin", "/sbin", "/usr",
    ]

    /// Standardize without resolving symlinks twice; callers compare
    /// standardized paths.
    public static func standardizedURL(for path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL
    }

    public static func isBlockedSystemPath(_ standardizedPath: String) -> Bool {
        if blockedExact.contains(standardizedPath) {
            return true
        }
        for prefix in blockedPrefixes {
            if standardizedPath == prefix || standardizedPath.hasPrefix(prefix + "/") {
                return true
            }
        }
        return false
    }

    /// True when the fully symlink-resolved path lands in a protected system
    /// tree. `standardizedFileURL` alone does not follow symlinks, so a symlink
    /// whose target is `/System` or `/private` must be resolved before the
    /// blocklist is applied.
    private static func isBlockedResolvedPath(_ resolvedPath: String) -> Bool {
        if resolvedBlockedExact.contains(resolvedPath) {
            return true
        }
        for prefix in resolvedBlockedPrefixes {
            if resolvedPath == prefix || resolvedPath.hasPrefix(prefix + "/") {
                return true
            }
        }
        return false
    }

    /// Validates that `path` exists, is a readable directory, and is not a
    /// sensitive system root. Returns the standardized URL on success.
    public static func validatedDirectoryURL(
        for path: String?
    ) -> Result<URL, IncomingPathValidationError> {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.empty)
        }
        // NOTE: callers pass URLComponents-decoded values or URL.path, both of
        // which are already percent-decoded exactly once. Do NOT call
        // removingPercentEncoding here: a second decode turns "%252e" into "."
        // and re-enables traversal.
        guard !path.contains("\0") else {
            return .failure(.blockedSystemPath(path))
        }
        let url = standardizedURL(for: path)
        let standardizedPath = url.path
        if isBlockedSystemPath(standardizedPath) {
            return .failure(.blockedSystemPath(standardizedPath))
        }
        // Standardizing does not follow symlinks; resolve them so a link into
        // a protected tree cannot bypass the blocklist above.
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        if isBlockedResolvedPath(resolvedPath) {
            return .failure(.blockedSystemPath(resolvedPath))
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: standardizedPath, isDirectory: &isDirectory) else {
            return .failure(.doesNotExist(standardizedPath))
        }
        guard isDirectory.boolValue else {
            return .failure(.notDirectory(standardizedPath))
        }
        guard FileManager.default.isReadableFile(atPath: standardizedPath) else {
            return .failure(.unreadable(standardizedPath))
        }
        return .success(url)
    }

    /// Validates a folder named by a `sorty://` link. Any web page or local
    /// process can open these links, so on top of `validatedDirectoryURL` this
    /// refuses app data, login items, and credential folders that a link could
    /// otherwise turn into a watched folder or move destination. Folders the
    /// user picks inside Sorty go through `validatedDirectoryURL` only.
    public static func validatedLinkDirectoryURL(
        for path: String?,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> Result<URL, IncomingPathValidationError> {
        let result = validatedDirectoryURL(for: path)
        guard case .success(let url) = result else { return result }
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        for candidate in Set([url.path, resolvedPath])
        where isProtectedFromLinks(candidate, homeDirectoryPath: homeDirectoryPath) {
            return .failure(.protectedLinkPath(candidate))
        }
        return result
    }

    /// True for `~/Library` (except cloud storage), dot-folders in the home
    /// folder, and the shared `/Applications` and `/Library` trees.
    public static func isProtectedFromLinks(_ standardizedPath: String, homeDirectoryPath: String) -> Bool {
        func isWithin(_ root: String) -> Bool {
            standardizedPath == root || standardizedPath.hasPrefix(root + "/")
        }
        if isWithin("/Applications") || isWithin("/Library") {
            return true
        }
        let home = URL(fileURLWithPath: homeDirectoryPath).standardizedFileURL.path
        guard home != "/", standardizedPath.hasPrefix(home + "/") else { return false }
        let relative = standardizedPath.dropFirst(home.count + 1)
        if relative.hasPrefix(".") {
            return true
        }
        let library = home + "/Library"
        guard isWithin(library) else { return false }
        // iCloud Drive and File Provider folders (Dropbox, Google Drive,
        // OneDrive) live under ~/Library and are ordinary user documents.
        return !(isWithin(library + "/Mobile Documents") || isWithin(library + "/CloudStorage"))
    }

    /// Off-main variant for IPC/deeplink observers: fileExists/readability
    /// probes run on a utility worker so notification delivery never blocks
    /// the main thread. Hop back to MainActor only for confirmed URLs.
    public static func validatedDirectoryURLIfValidAsync(path: String?) async -> URL? {
        if case .success(let url) = await validatedDirectoryURLAsync(for: path) {
            return url
        }
        return nil
    }

    /// Off-main typed variant for callers that need the rejection reason.
    public static func validatedDirectoryURLAsync(
        for path: String?
    ) async -> Result<URL, IncomingPathValidationError> {
        await Task.detached(priority: .utility) {
            validatedDirectoryURL(for: path)
        }.value
    }
}
