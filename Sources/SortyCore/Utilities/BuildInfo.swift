//
//  BuildInfo.swift
//  Sorty
//
//  Utility for accessing build information
//

import Foundation

public struct BuildInfo {
    /// App version from Info.plist (e.g., "1.0.0")
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    
    /// Build number from Info.plist (e.g., "1")
    package static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    
    /// Commit embedded by the build, or supplied through the runtime environment.
    package static var commit: String {
        if let commitPath = Bundle.main.path(forResource: "commit", ofType: "txt"),
           let commitHash = try? String(contentsOfFile: commitPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !commitHash.isEmpty {
            return commitHash
        }
        
        if let envCommit = ProcessInfo.processInfo.environment["GIT_COMMIT"],
           !envCommit.isEmpty {
            return envCommit
        }
        
        return "unknown"
    }
    
    /// Short commit hash (first 9 characters)
    package static var shortCommit: String {
        String(commit.prefix(9))
    }

    /// Full version string (e.g., "1.0.0 (1)")
    package static var fullVersion: String {
        "\(version) (\(build))"
    }
    
    /// Whether we have a valid commit hash
    package static var hasValidCommit: Bool {
        let c = commit
        return c != "unknown" && c.count >= 7
    }
}
