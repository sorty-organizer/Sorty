//
//  ExpiringFilesManager.swift
//  Sorty
//
//  Offers stale installers, archives and screenshots for the Trash (Labs: Expiring Files).
//

import Foundation
import Combine
import CoreServices

/// A file Sorty thinks has outlived its use, waiting for the user's review.
package struct ExpiringFileCandidate: Identifiable, Equatable, Sendable {
    package enum Reason: String, Sendable {
        case installer = "Installer"
        case archive = "Archive"
        case screenshot = "Screenshot"
        case markedByYou = "Marked to expire"
        case installed = "App installed"
        case extracted = "Already extracted"
    }

    /// True when the file was offered early because you're done with it, not for its age.
    package var isFinished: Bool { reason == .installed || reason == .extracted }

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
    /// Sub-option of Expiring Files: offer installers and archives as soon as
    /// their app is installed or their contents are extracted.
    package static let finishedDownloadsKey = "labs.expiring.finished"

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
        let detectsFinished = defaults.bool(forKey: Self.finishedDownloadsKey)
        candidates = await Task.detached(priority: .utility) {
            let detector = detectsFinished ? FinishedDownloadDetector.live() : nil
            return Self.scan(folders: folders, cutoff: cutoff, kept: kept, marks: marks, finished: detector)
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
        finished: FinishedDownloadDetector? = nil,
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
                } else if let done = finished?.reason(for: url, addedOn: added, siblings: contents) {
                    reason = done
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

/// Spots downloads you've already used: an installer whose app now sits in
/// Applications, or an archive that was opened and extracted next to itself.
/// Only files Finder recorded as opened qualify, so untouched downloads wait
/// for the normal age limit.
package struct FinishedDownloadDetector: Sendable {
    package struct InstalledApp: Sendable {
        package let name: String
        package let added: Date
        package init(name: String, added: Date) {
            self.name = name
            self.added = added
        }
    }

    package let installedApps: [InstalledApp]
    /// Last time the file was opened, from Spotlight's `kMDItemLastUsedDate`.
    package let lastOpened: @Sendable (URL) -> Date?

    package init(installedApps: [InstalledApp], lastOpened: @escaping @Sendable (URL) -> Date?) {
        self.installedApps = installedApps
        self.lastOpened = lastOpened
    }

    /// Reads apps from /Applications and ~/Applications, and open dates from Spotlight.
    package static func live() -> FinishedDownloadDetector {
        let fileManager = FileManager.default
        let folders = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .creationDateKey]
        let apps = folders.flatMap { folder in
            ((try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? [])
                .filter { $0.pathExtension == "app" }
                .compactMap { url -> InstalledApp? in
                    let values = try? url.resourceValues(forKeys: keys)
                    guard let added = values?.addedToDirectoryDate ?? values?.creationDate else { return nil }
                    return InstalledApp(name: url.deletingPathExtension().lastPathComponent, added: added)
                }
        }
        return FinishedDownloadDetector(installedApps: apps) { url in
            guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
            return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        }
    }

    package func reason(for url: URL, addedOn added: Date, siblings: [URL]) -> ExpiringFileCandidate.Reason? {
        let fileExtension = url.pathExtension.lowercased()
        let isInstaller = ["dmg", "pkg", "mpkg"].contains(fileExtension)
        let isArchive = ExpiringFilesManager.reasonForKind(of: url) == .archive
        guard isInstaller || isArchive,
              let opened = lastOpened(url), opened >= added
        else { return nil }

        let product = Self.productName(of: url)
        // The app must have arrived after the download, so an older copy doesn't count.
        if installedApps.contains(where: { $0.added >= added && Self.namesMatch(product, $0.name) }) {
            return .installed
        }
        if isArchive, siblings.contains(where: { $0 != url && Self.archiveBaseName(of: $0) == Self.archiveBaseName(of: url) }) {
            return .extracted
        }
        return nil
    }

    /// "Slack-4.41.105-arm64.dmg" -> "slack": drops versions and platform words.
    package static func productName(of url: URL) -> String {
        let noise: Set<String> = ["arm64", "x64", "x86", "64", "amd64", "universal", "mac", "macos", "osx", "darwin",
                                  "intel", "apple", "silicon", "setup", "installer", "install", "latest", "release", "stable"]
        let tokens = archiveBaseName(of: url)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let kept = tokens.prefix { token in
            guard let first = token.first, !first.isNumber else { return false }
            return !(token.first == "v" && token.dropFirst().first?.isNumber == true)
        }.filter { !noise.contains($0.lowercased()) }
        return kept.joined().lowercased()
    }

    /// File name without archive extensions, so "a.tar.gz" and the folder "a" compare equal.
    static func archiveBaseName(of url: URL) -> String {
        var name = url.lastPathComponent
        let extensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "pkg", "mpkg"]
        while let dot = name.lastIndex(of: "."), extensions.contains(name[name.index(after: dot)...].lowercased()) {
            name = String(name[..<dot])
        }
        return name
    }

    static func namesMatch(_ product: String, _ appName: String) -> Bool {
        let app = appName.lowercased().filter { $0.isLetter || $0.isNumber }
        guard product.count >= 3, app.count >= 3 else { return false }
        return app.hasPrefix(product) || product.hasPrefix(app)
    }
}
