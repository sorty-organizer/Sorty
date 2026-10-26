//
//  ExpiringFilesManager.swift
//  Sorty
//
//  Offers stale installers, archives and screenshots for the Trash (Labs: Expiring Files).
//

import Foundation
import Combine

/// A file Sorty thinks has outlived its use, waiting for the user's review.
package struct ExpiringFileCandidate: Identifiable, Equatable, Sendable {
    package enum Reason: String, Sendable {
        case installer = "Installer"
        case archive = "Archive"
        case screenshot = "Screenshot"
        case markedByYou = "Marked to expire"
    }

    package var id: String { url.path }
    package let url: URL
    package let reason: Reason
    package let dateAdded: Date
    package let size: Int64
}

/// Finds short-lived files at the top level of Downloads, the Desktop and the
/// screenshot folder once they pass an age limit, and moves the ones the user
/// approves to the Trash. Nothing is removed without that review.
@MainActor
package final class ExpiringFilesManager: ObservableObject {
    package static let shared = ExpiringFilesManager()

    package static let defaultAgeInDays = 14
    package static let ageInDaysKey = "labs.expiring.days"

    @Published package private(set) var candidates: [ExpiringFileCandidate] = []
    @Published package private(set) var isScanning = false
    @Published package private(set) var lastResult: String?

    private let defaults: UserDefaults
    private let keptKey = "labs.expiring.kept"
    private let marksKey = "labs.expiring.marks"

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    package var isEnabled: Bool { SortyLabsFeature.expiringFiles.isEnabled }

    package var ageInDays: Int {
        let stored = defaults.integer(forKey: Self.ageInDaysKey)
        return stored > 0 ? stored : Self.defaultAgeInDays
    }

    package var totalSize: Int64 {
        candidates.reduce(0) { $0 + $1.size }
    }

    /// Asks to offer this file for the Trash after `days`, whatever kind it is.
    package func markToExpire(_ url: URL, afterDays days: Int) {
        var marks = defaults.dictionary(forKey: marksKey) as? [String: Date] ?? [:]
        marks[Self.key(for: url)] = Date().addingTimeInterval(TimeInterval(days) * 86_400)
        defaults.set(marks, forKey: marksKey)
    }

    /// Rescans the watched locations. Cheap: top-level listings only.
    package func refresh() async {
        guard isEnabled else {
            candidates = []
            return
        }
        isScanning = true
        defer { isScanning = false }
        let folders = Self.scannedFolders()
        let cutoff = Date().addingTimeInterval(-TimeInterval(ageInDays) * 86_400)
        let kept = Set(defaults.stringArray(forKey: keptKey) ?? [])
        let marks = defaults.dictionary(forKey: marksKey) as? [String: Date] ?? [:]
        candidates = await Task.detached(priority: .utility) {
            Self.scan(folders: folders, cutoff: cutoff, kept: kept, marks: marks)
        }.value
    }

    /// Never offers this file again.
    package func keep(_ candidate: ExpiringFileCandidate) {
        var kept = defaults.stringArray(forKey: keptKey) ?? []
        kept.append(Self.key(for: candidate.url))
        defaults.set(Array(kept.suffix(1_000)), forKey: keptKey)
        candidates.removeAll { $0.id == candidate.id }
    }

    /// Moves the chosen files to the Trash, where Finder can put them back.
    package func moveToTrash(_ selection: [ExpiringFileCandidate]) async {
        let urls = selection.map(\.url)
        let failures = await Task.detached(priority: .userInitiated) {
            urls.filter { (try? FileManager.default.trashItem(at: $0, resultingItemURL: nil)) == nil }
        }.value
        let trashedIDs = Set(urls.map(\.path)).subtracting(failures.map(\.path))
        candidates.removeAll { trashedIDs.contains($0.id) }

        var marks = defaults.dictionary(forKey: marksKey) as? [String: Date] ?? [:]
        urls.filter { trashedIDs.contains($0.path) }.forEach { marks.removeValue(forKey: Self.key(for: $0)) }
        defaults.set(marks, forKey: marksKey)

        let trashedCount = trashedIDs.count
        lastResult = failures.isEmpty
            ? "Moved \(trashedCount) \(trashedCount == 1 ? "file" : "files") to the Trash."
            : "Moved \(trashedCount) to the Trash. \(failures.count) couldn't be moved."
    }

    // MARK: - Scanning

    /// Stable key for stored marks and kept files, whichever way a path is spelled.
    nonisolated static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Downloads, the Desktop, and the screenshot folder when it is set elsewhere.
    nonisolated static func scannedFolders() -> [URL] {
        let fileManager = FileManager.default
        var folders = [
            fileManager.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
            fileManager.urls(for: .desktopDirectory, in: .userDomainMask)[0],
        ]
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let url = URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
            if !folders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                folders.append(url)
            }
        }
        return folders
    }

    nonisolated static func scan(
        folders: [URL],
        cutoff: Date,
        kept: Set<String>,
        marks: [String: Date],
        now: Date = Date()
    ) -> [ExpiringFileCandidate] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .isDirectoryKey, .isPackageKey, .fileSizeKey]
        var results: [ExpiringFileCandidate] = []
        for folder in folders {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in contents where !kept.contains(key(for: url)) {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isDirectory != true || values.isPackage == true
                else { continue }
                let added = values.addedToDirectoryDate ?? values.creationDate ?? now
                let reason: ExpiringFileCandidate.Reason
                if let expiry = marks[key(for: url)] {
                    guard expiry <= now else { continue }
                    reason = .markedByYou
                } else {
                    guard added <= cutoff, let kind = reasonForKind(of: url) else { continue }
                    reason = kind
                }
                results.append(ExpiringFileCandidate(
                    url: url,
                    reason: reason,
                    dateAdded: added,
                    size: Int64(values.fileSize ?? 0)
                ))
            }
        }
        return results.sorted { $0.dateAdded < $1.dateAdded }
    }

    /// Installers, archives and screenshots are offered automatically. Other
    /// files only expire when the user marks them.
    nonisolated static func reasonForKind(of url: URL) -> ExpiringFileCandidate.Reason? {
        let fileExtension = url.pathExtension.lowercased()
        if ["dmg", "pkg", "mpkg", "iso"].contains(fileExtension) { return .installer }
        if ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"].contains(fileExtension) { return .archive }
        let name = url.lastPathComponent
        let screenshotPrefixes = ["Screenshot ", "Screen Shot ", "CleanShot ", "Screen Recording "]
        if screenshotPrefixes.contains(where: name.hasPrefix) { return .screenshot }
        return nil
    }
}
