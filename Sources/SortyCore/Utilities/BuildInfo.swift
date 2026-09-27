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
    
    /// Git commit hash (full)
    /// Tries multiple methods to detect the commit hash
    package static var commit: String {
        // Method 1: Try to read from embedded file (set during Xcode build phase)
        if let commitPath = Bundle.main.path(forResource: "commit", ofType: "txt"),
           let commitHash = try? String(contentsOfFile: commitPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !commitHash.isEmpty {
            return commitHash
        }
        
        // Method 2: Try environment variable (set during build)
        if let envCommit = ProcessInfo.processInfo.environment["GIT_COMMIT"],
           !envCommit.isEmpty {
            return envCommit
        }
        
        // Method 3: Try running git command (works in development environment)
        if let gitCommit = getGitCommitHash() {
            return gitCommit
        }
        
        // Final fallback
        return "unknown"
    }
    
    /// Short commit hash (first 9 characters)
    package static var shortCommit: String {
        let full = commit
        if full == "unknown" {
            return "unknown"
        }
        if full.count > 9 {
            return String(full.prefix(9))
        }
        return full
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
    
    /// Attempts to get the git commit hash by running git command
    /// This works when running from Xcode or in development, but not in release builds
    private static func getGitCommitHash() -> String? {
        // Find the source directory by checking common locations
        let possiblePaths = [
            // When running from Xcode, the source is often at the project root
            Bundle.main.bundleURL.deletingLastPathComponent().path,
            // Check parent directories
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().path,
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path,
            // Common development paths
            FileManager.default.currentDirectoryPath
        ]
        
        for basePath in possiblePaths {
            let gitPath = "\(basePath)/.git"
            if FileManager.default.fileExists(atPath: gitPath) {
                return runGitCommand(in: basePath)
            }
        }
        
        return nil
    }
    
    private static func runGitCommand(in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "HEAD"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   output.count >= 7 {
                    return output
                }
            }
        } catch {
            // Silently fail - we'll use the fallback
        }
        
        return nil
    }
}
