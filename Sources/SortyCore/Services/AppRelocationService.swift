import Foundation

/// App relocation + launch-path helpers owned by SortyLib so SortyApp stays
/// as entry/window glue. App glue calls these; provider auth/network details
/// stay inside the client layer per AGENTS.md.
public enum AppMoveResult: Equatable, Sendable {
    case moved
    /// The user dismissed the administrator password prompt.
    case cancelled
    /// `reason` is a fixed analytics identifier; `message` is shown to the user only.
    case failed(message: String, reason: String)
}

@MainActor
public enum AppRelocationService {
    public static let applicationsPath = "/Applications"

    /// Returns the app's real on-disk location, resolving Gatekeeper app
    /// translocation back to the original path when necessary.
    public static func originalBundleURL() -> URL {
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard bundleURL.path.contains("/AppTranslocation/") else { return bundleURL }

        guard
            let handle = dlopen(
                "/System/Library/Frameworks/Security.framework/Security",
                RTLD_LAZY
            )
        else {
            return bundleURL
        }
        defer { dlclose(handle) }

        typealias CreateOriginalPath = @convention(c) (
            CFURL,
            UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> Unmanaged<CFURL>?
        guard let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else {
            return bundleURL
        }
        let createOriginalPath = unsafeBitCast(symbol, to: CreateOriginalPath.self)
        guard let original = createOriginalPath(bundleURL as CFURL, nil)?.takeRetainedValue() else {
            return bundleURL
        }
        return (original as URL).resolvingSymlinksInPath()
    }

    public static func isInApplicationsFolder(_ url: URL) -> Bool {
        let path = url.path
        if path.hasPrefix(applicationsPath + "/") { return true }
        let userApplicationsPath = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .path
        return path.hasPrefix(userApplicationsPath + "/")
    }

    public static func destinationForMove(from sourceURL: URL) -> URL {
        URL(fileURLWithPath: applicationsPath, isDirectory: true)
            .appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
    }

    public static func appleScriptString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    public static func moveScript(source: URL, destination: URL) -> String {
        """
        set sourcePath to \(appleScriptString(source.path))
        set destinationPath to \(appleScriptString(destination.path))
        do shell script "/bin/rm -rf " & quoted form of destinationPath & " && /bin/mv " & quoted form of sourcePath & " " & quoted form of destinationPath & " && (/usr/bin/xattr -dr com.apple.quarantine " & quoted form of destinationPath & " || /usr/bin/true)" with administrator privileges
        """
    }

    /// Authorization can wait for user input; never block the app's main thread.
    public static func move(source: URL, destination: URL) async -> AppMoveResult {
        let script = moveScript(source: source, destination: destination)
        return await Task.detached(priority: .userInitiated) { () -> AppMoveResult in
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript", isDirectory: false)
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            do {
                try process.run()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus != 0 else { return .moved }
                let output = String(decoding: errorData, as: UTF8.self)
                return classifyMoveFailure(output)
            } catch {
                return .failed(message: error.localizedDescription, reason: "launch_failed")
            }
        }.value
    }

    /// Maps osascript's stderr to a result. Cancelling the password prompt is
    /// AppleScript error -128 and must not be reported as a failure.
    nonisolated static func classifyMoveFailure(_ output: String) -> AppMoveResult {
        let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.contains("(-128)") { return .cancelled }
        let fallback = "Move Sorty to Applications in Finder, then reopen it."
        let reason: String
        if output.contains("(-60005)") || output.contains("(-60007)") {
            reason = "not_authorized"
        } else if output.localizedCaseInsensitiveContains("Operation not permitted")
            || output.localizedCaseInsensitiveContains("Permission denied") {
            reason = "permission_denied"
        } else if output.localizedCaseInsensitiveContains("No such file") {
            reason = "source_missing"
        } else {
            reason = "script_failed"
        }
        return .failed(message: output.isEmpty ? fallback : output, reason: reason)
    }

    /// Waits for this instance to exit, then opens the moved copy. Opening
    /// while the old instance is still running would just re-activate it.
    public static func relaunch(at destinationURL: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let quotedPath =
            "'" + destinationURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; "
                + "/usr/bin/open \(quotedPath)",
        ]
        try? process.run()
    }

    /// Decodes the persisted watched-folder list for the quit-warning count
    /// so app glue does not do JSON decoding inline.
    public static func activeWatchedAutoOrganizeFolderCount(
        defaults: UserDefaults = .standard
    ) -> Int {
        if defaults.object(forKey: "activeWatchedFolderCount") != nil {
            return defaults.integer(forKey: "activeWatchedFolderCount")
        }
        guard let data = defaults.data(forKey: "watchedFolders"),
              let folders = try? JSONDecoder().decode([WatchedFolder].self, from: data)
        else {
            return 0
        }
        return folders.filter(\.isEnabled).count
    }
}
