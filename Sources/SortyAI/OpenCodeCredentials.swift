import Foundation

/// Reads only Zen/Go API credentials. Upstream OAuth sessions belong to OpenCode
/// and must never be sent to Sorty's direct API endpoints.
public enum OpenCodeCredentials {
    public enum ImportError: LocalizedError {
        case unsupportedProvider
        case unreadableFile
        case invalidFile
        case missingKey
        case configurationChanged
        case missingCLI

        public var errorDescription: String? {
            switch self {
            case .unsupportedProvider: return "Select OpenCode Zen or Go first."
            case .unreadableFile: return "Couldn't read OpenCode credentials. Connect your plan in OpenCode, then try again."
            case .invalidFile: return "OpenCode credentials couldn't be decoded. Connect your plan in OpenCode again."
            case .missingKey: return "No API key was found for this plan. Run opencode auth login and select OpenCode Zen or Go, or get a key from OpenCode sign-in."
            case .configurationChanged: return "Provider settings changed during import. Try again."
            case .missingCLI: return "OpenCode CLI is not installed. Install it from opencode.ai, then try signing in again."
            }
        }
    }

    public static func authFileURL(environment: [String: String], homeDirectory: URL) -> URL {
        let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".local/share", isDirectory: true)
        return dataHome.appendingPathComponent("opencode/auth.json")
    }

    /// Uses a login shell like the existing Codex terminal flow. No keys or
    /// user-provided strings are interpolated into this script.
    public static func prepareLoginScript() throws -> URL {
        // This probe runs in the caller's detached task and uses the same login
        // shell and fallback path as the command below.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "command -v opencode >/dev/null 2>&1 || [ -x \"$HOME/.opencode/bin/opencode\" ]"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { throw ImportError.missingCLI }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sorty-opencode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("connect.command")
        let script = """
        #!/bin/zsh -l
        if command -v opencode >/dev/null 2>&1; then
            exec opencode auth login
        elif [ -x "$HOME/.opencode/bin/opencode" ]; then
            exec "$HOME/.opencode/bin/opencode" auth login
        else
            printf '%s\\n' 'OpenCode CLI is not installed. Install it from https://opencode.ai, then run opencode auth login.'
            exit 1
        fi
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    public static func loadAPIKey(
        for provider: AIProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> String {
        guard provider == .openCodeZen || provider == .openCodeGo else {
            throw ImportError.unsupportedProvider
        }
        let data: Data
        if let content = environment["OPENCODE_AUTH_CONTENT"], !content.isEmpty {
            data = Data(content.utf8)
        } else {
            let url = authFileURL(environment: environment, homeDirectory: homeDirectory)
            do {
                data = try Data(contentsOf: url)
            } catch {
                if (error as NSError).domain == NSCocoaErrorDomain,
                   (error as NSError).code == NSFileReadNoSuchFileError {
                    data = Data("{}".utf8)
                } else {
                    throw ImportError.unreadableFile
                }
            }
        }
        return try apiKey(for: provider, data: data, environment: environment)
    }

    static func apiKey(for provider: AIProvider, data: Data, environment: [String: String]) throws -> String {
        let providerID: String
        switch provider {
        case .openCodeZen: providerID = "opencode"
        case .openCodeGo: providerID = "opencode-go"
        default: throw ImportError.unsupportedProvider
        }
        guard let auth = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ImportError.invalidFile
        }
        let entry = auth[providerID] as? [String: Any]
        // OpenCode overlays stored API keys on OPENCODE_API_KEY. A Go entry
        // never supplies Zen's key, or vice versa.
        let rawKey = entry?["type"] as? String == "api"
            ? entry?["key"] as? String : nil
        let key = (rawKey ?? environment["OPENCODE_API_KEY"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { throw ImportError.missingKey }
        return key
    }
}
