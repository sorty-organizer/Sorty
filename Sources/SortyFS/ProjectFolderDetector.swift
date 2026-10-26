//
//  ProjectFolderDetector.swift
//  Sorty
//
//  Recognizes folders that only work as a whole (Labs: Project Detection).
//

import Foundation

/// Spots code repositories and build projects by their marker files, so
/// scanning can leave them intact instead of scattering their files.
package enum ProjectFolderDetector {
    /// Files or folders whose presence marks a project root.
    static let rootMarkers = [
        ".git", "Package.swift", "package.json", "Cargo.toml", "go.mod",
        "pyproject.toml", "setup.py", "Gemfile", "pom.xml", "build.gradle",
        "build.gradle.kts", "CMakeLists.txt", "Makefile", "composer.json",
        "pubspec.yaml", "Podfile", ".hg", ".svn",
    ]

    /// Extensions of folders that are themselves a project bundle.
    static let projectFolderExtensions: Set<String> = [
        "xcodeproj", "xcworkspace", "playground", "swiftpm",
    ]

    /// True when the folder is a project root. Costs a few `stat` calls.
    package static func isProjectRoot(_ url: URL, fileManager: FileManager = .default) -> Bool {
        if projectFolderExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        return rootMarkers.contains {
            fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }
}
