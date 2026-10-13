import Foundation

/// App relocation + launch-path helpers owned by SortyLib so SortyApp stays
/// as entry/window glue. App glue calls these; provider auth/network details
/// stay inside the client layer per AGENTS.md.
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
    public static func move(source: URL, destination: URL) async -> String? {
        let script = moveScript(source: source, destination: destination)
        return await Task.detached(priority: .userInitiated) { () -> String? in
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
                guard process.terminationStatus != 0 else { return nil }
                let message = String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return message.isEmpty ? "Move Sorty to Applications in Finder, then reopen it." : message
            } catch {
                return error.localizedDescription
            }
        }.value
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
