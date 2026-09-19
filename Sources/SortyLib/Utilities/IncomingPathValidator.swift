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

public enum IncomingPathValidationError: LocalizedError, Equatable {
    case empty
    case doesNotExist(String)
    case notDirectory(String)
    case blockedSystemPath(String)
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
        "/private",
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
        "/private/var/db",
    ]

    private static let blockedExact: Set<String> = [
        "/", "/System", "/Library", "/private", "/etc",
        "/bin", "/sbin", "/usr", "/var",
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

    /// Non-throwing convenience for observers that must drop invalid IPC silently.
    public static func validatedDirectoryURLIfValid(path: String?) -> URL? {
        if case .success(let url) = validatedDirectoryURL(for: path) {
            return url
        }
        return nil
    }
}
