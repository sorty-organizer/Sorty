import Foundation
import SortyFileSystem

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

    /// Exit status of the move script when the existing app in Applications
    /// could not be set aside. App Management blocks this for root as well.
    nonisolated static let replaceStepStatus = 10
    /// Exit status when the running copy could not be moved into place.
    nonisolated static let moveStepStatus = 11

    /// Builds the privileged move. An existing copy at `destination` is renamed
    /// aside first, so a blocked or failed step never leaves a half-deleted app
    /// in Applications; it is restored if the move fails and sent to the
    /// user's Trash once the new copy is in place.
    public static func moveScript(source: URL, destination: URL, trashDirectory: URL? = nil) -> String {
        let token = UUID().uuidString
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent)-replaced-\(token).app")
        let trash = (trashDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true))
            .appendingPathComponent("\(destination.deletingPathExtension().lastPathComponent) (replaced \(token.prefix(8))).app")
        let shell = """
        set -u; src=$1; dst=$2; bak=$3; trash=$4; \
        if [ -e "$dst" ]; then /bin/mv "$dst" "$bak" || exit \(replaceStepStatus); fi; \
        if ! /bin/mv "$src" "$dst"; then [ -e "$bak" ] && /bin/mv "$bak" "$dst"; exit \(moveStepStatus); fi; \
        /usr/bin/xattr -dr com.apple.quarantine "$dst" || true; \
        if [ -e "$bak" ]; then /bin/mv "$bak" "$trash" || /bin/rm -rf "$bak" || true; fi
        """
        return """
        set shellCode to \(appleScriptString(shell))
        set sourcePath to \(appleScriptString(source.path))
        set destinationPath to \(appleScriptString(destination.path))
        set backupPath to \(appleScriptString(backup.path))
        set trashPath to \(appleScriptString(trash.path))
        do shell script "/bin/sh -c " & quoted form of shellCode & " sorty-move " & quoted form of sourcePath & " " & quoted form of destinationPath & " " & quoted form of backupPath & " " & quoted form of trashPath with administrator privileges
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
                return .failed(message: error.userFacingMessage, reason: "launch_failed")
            }
        }.value
    }

    /// Maps osascript's stderr to a result. Cancelling the password prompt is
    /// AppleScript error -128 and must not be reported as a failure. A shell
    /// failure ends with its exit status in parentheses, which names the step.
    nonisolated static func classifyMoveFailure(_ output: String) -> AppMoveResult {
        let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.contains("(-128)") { return .cancelled }
        if output.contains("(-60005)") || output.contains("(-60007)") {
            return .failed(
                message: "Sorty needs an administrator password to move into Applications.",
                reason: "not_authorized"
            )
        }
        let isPermissionError = output.localizedCaseInsensitiveContains("Operation not permitted")
            || output.localizedCaseInsensitiveContains("Permission denied")
        if output.hasSuffix("(\(replaceStepStatus))") {
            return .failed(
                message: isPermissionError
                    ? "macOS didn’t let Sorty replace the copy already in Applications. Allow Sorty under Privacy & Security › App Management, or drag this copy into Applications in Finder."
                    : "Sorty couldn’t set aside the copy already in Applications. Drag this copy into Applications in Finder instead.",
                reason: isPermissionError ? "replace_blocked" : "replace_failed"
            )
        }
        if output.hasSuffix("(\(moveStepStatus))") {
            if output.localizedCaseInsensitiveContains("No such file") {
                return .failed(
                    message: "Sorty couldn’t find its own app file. Move Sorty to Applications in Finder, then reopen it.",
                    reason: "source_missing"
                )
            }
            return .failed(
                message: isPermissionError
                    ? "macOS didn’t let Sorty move itself out of its current folder. Drag Sorty into Applications in Finder instead."
                    : "Sorty couldn’t move itself into Applications. Drag Sorty into Applications in Finder instead.",
                reason: isPermissionError ? "source_blocked" : "move_failed"
            )
        }
        return .failed(
            message: "Sorty couldn’t move itself into Applications. Drag Sorty into Applications in Finder, then reopen it.",
            reason: isPermissionError ? "permission_denied" : "script_failed"
        )
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
