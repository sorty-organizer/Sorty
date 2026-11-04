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
    /// Ties a Keep to this copy of the file, so a later download with the same name is still offered.
    package var keepKey: String { ExpiringFilesManager.keepKey(for: url, added: dateAdded) }
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
    /// Bumped by every refresh so a slow, older scan can't overwrite a newer one.
    private var refreshGeneration = 0

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
        refreshGeneration += 1
        let generation = refreshGeneration
        guard isEnabled else {
            isScanning = false
            candidates = []
            return
        }
        isScanning = true
        let folders = Self.scannedFolders()
        let cutoff = Date().addingTimeInterval(-TimeInterval(ageInDays) * 86_400)
        let kept = Set(defaults.stringArray(forKey: keptKey) ?? [])
        let marks = defaults.dictionary(forKey: marksKey) as? [String: Date] ?? [:]
        let detectsFinished = defaults.bool(forKey: Self.finishedDownloadsKey)
        let startedAt = Date()
        let report = await Task.detached(priority: .utility) {
            let detector = detectsFinished ? FinishedDownloadDetector.live() : nil
            return Self.scanReport(
                folders: folders,
                cutoff: cutoff,
                kept: kept,
                marks: marks,
                finished: detector,
                signals: .live,
                now: Date()
            )
        }.value
        guard generation == refreshGeneration else { return }
        let found = report.candidates
        LabsTelemetry.expiringScanned(
            candidates: found,
            unreadableFolders: report.folderErrors.count,
            finishedDetection: detectsFinished,
            duration: Date().timeIntervalSince(startedAt)
        )
        // Usually a missing Files and Folders permission for Desktop or Downloads.
        for error in report.folderErrors {
            ReliabilityManager.shared.capture(error: error, feature: "labs", operation: "expiring_files_scan")
        }
        isScanning = false
        candidates = found
        // A trash result is shown once; the next scan replaces it with the current state.
        lastResult = nil
        pruneMarks(marks)
    }

    /// Stops offering this copy of the file. A new download with the same name is judged afresh.
    package func keep(_ candidate: ExpiringFileCandidate, from surface: LabsTelemetry.Surface) {
        LabsTelemetry.expiringKept(from: surface, reason: candidate.reason)
        var kept = defaults.stringArray(forKey: keptKey) ?? []
        kept.append(candidate.keepKey)
        defaults.set(Array(kept.suffix(1_000)), forKey: keptKey)
        candidates.removeAll { $0.id == candidate.id }
    }

    /// Moves the chosen files to the Trash, where Finder can put them back. A file
    /// that was replaced or moved since the scan is skipped rather than trashed.
    package func moveToTrash(_ selection: [ExpiringFileCandidate], from surface: LabsTelemetry.Surface) async {
        let offered = candidates.count
        let outcome = await Task.detached(priority: .userInitiated) {
            var trashed: [URL] = []
            var changed = 0
            var failedIDs = Set<String>()
            var firstError: NSError?
            for candidate in selection {
                guard Self.isUnchanged(candidate) else {
                    changed += 1
                    continue
                }
                do {
                    try FileManager.default.trashItem(at: candidate.url, resultingItemURL: nil)
                    trashed.append(candidate.url)
                } catch {
                    failedIDs.insert(candidate.id)
                    if firstError == nil { firstError = error as NSError }
                }
            }
            return (trashed, changed, failedIDs, firstError)
        }.value
        let (trashed, changed, failedIDs, trashError) = outcome
        if let trashError {
            ReliabilityManager.shared.capture(error: trashError, feature: "labs", operation: "expiring_files_trash")
        }
        let failed = failedIDs.count
        LabsTelemetry.expiringTrashed(
            from: surface,
            offered: offered,
            selected: selection.count,
            trashed: trashed.count,
            changed: changed,
            failed: failed,
            finished: selection.filter(\.isFinished).count
        )
        // Failures stay listed for another try. Changed files leave: the next scan judges them afresh.
        let removedIDs = Set(selection.map(\.id)).subtracting(failedIDs)
        candidates.removeAll { removedIDs.contains($0.id) }

        var marks = defaults.dictionary(forKey: marksKey) as? [String: Date] ?? [:]
        trashed.forEach { marks.removeValue(forKey: Self.key(for: $0)) }
        defaults.set(marks, forKey: marksKey)

        var parts = ["Moved \(trashed.count) \(trashed.count == 1 ? "file" : "files") to the Trash."]
        if changed > 0 { parts.append("Skipped \(changed) that changed since the scan.") }
        if failed > 0 { parts.append("\(failed) couldn't be moved.") }
        lastResult = parts.joined(separator: " ")
        if failed > 0 || changed > 0 {
            HapticFeedbackManager.shared.error()
        } else if !trashed.isEmpty {
            HapticFeedbackManager.shared.success()
        }
    }

    /// Drops reminders for files that are gone, so the list doesn't grow forever.
    private func pruneMarks(_ marks: [String: Date]) {
        let live = marks.filter { FileManager.default.fileExists(atPath: $0.key) }
        if live.count != marks.count {
            defaults.set(live, forKey: marksKey)
        }
    }

    /// True while the file at the candidate's path is still the one that was scanned.
    nonisolated static func isUnchanged(_ candidate: ExpiringFileCandidate) -> Bool {
        let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .creationDateKey, .fileSizeKey, .isDirectoryKey]
        // Directory enumeration prefetches metadata onto its URLs. Reconstruct the
        // URL so this safety check reads the current file rather than that cache.
        let currentURL = URL(fileURLWithPath: candidate.url.path)
        guard let values = try? currentURL.resourceValues(forKeys: keys) else { return false }
        let added = values.addedToDirectoryDate ?? values.creationDate
        guard let added, abs(added.timeIntervalSince(candidate.dateAdded)) < 1 else { return false }
        // Package sizes are summed at scan time; only plain files can be compared cheaply.
        return values.isDirectory == true || Int64(values.fileSize ?? 0) == candidate.size
    }

    // MARK: - Scanning

    /// Stable key for stored marks and kept files, whichever way a path is spelled.
    nonisolated static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Path plus the date the file arrived, so Keep sticks to one copy of a file.
    nonisolated static func keepKey(for url: URL, added: Date) -> String {
        "\(key(for: url))|\(Int(added.timeIntervalSince1970))"
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

    /// Lists top-level files in `folders` that are due for review. A file opened
    /// recently counts as in use, so its age runs from that open, not its arrival.
    nonisolated static func scan(
        folders: [URL],
        cutoff: Date,
        kept: Set<String>,
        marks: [String: Date],
        finished: FinishedDownloadDetector? = nil,
        signals: FileSignals = .unavailable,
        now: Date = Date()
    ) -> [ExpiringFileCandidate] {
        scanReport(folders: folders, cutoff: cutoff, kept: kept, marks: marks, finished: finished, signals: signals, now: now)
            .candidates
    }

    /// Candidates plus the folders that couldn't be listed, for diagnostics.
    struct ScanReport: Sendable {
        var candidates: [ExpiringFileCandidate]
        var folderErrors: [NSError]
    }

    nonisolated static func scanReport(
        folders: [URL],
        cutoff: Date,
        kept: Set<String>,
        marks: [String: Date],
        finished: FinishedDownloadDetector?,
        signals: FileSignals,
        now: Date
    ) -> ScanReport {
        var folderErrors: [NSError] = []
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .isDirectoryKey, .isPackageKey, .fileSizeKey]
        var results: [ExpiringFileCandidate] = []
        var seen = Set<String>()
        for folder in folders {
            let contents: [URL]
            do {
                contents = try FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                )
            } catch {
                // A screenshot folder that was deleted isn't a fault worth reporting.
                if FileManager.default.fileExists(atPath: folder.path) { folderErrors.append(error as NSError) }
                continue
            }
            for url in contents {
                let path = key(for: url)
                // The screenshot folder can be Desktop or Downloads under another spelling.
                guard seen.insert(path).inserted, !kept.contains(path),
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isDirectory != true || values.isPackage == true
                else { continue }
                let added = values.addedToDirectoryDate ?? values.creationDate ?? now
                guard !kept.contains(keepKey(for: url, added: added)) else { continue }
                let reason: ExpiringFileCandidate.Reason
                if let expiry = marks[path] {
                    guard expiry <= now else { continue }
                    reason = .markedByYou
                } else if let done = finished?.reason(for: url, addedOn: added, siblings: contents) {
                    reason = done
                } else {
                    let lastActive = max(added, signals.lastOpened(url) ?? added)
                    guard lastActive <= cutoff,
                          let kind = reasonForKind(of: url, isScreenCapture: signals.isScreenCapture(url))
                    else { continue }
                    reason = kind
                }
                let size = values.isDirectory == true ? directorySize(url) : Int64(values.fileSize ?? 0)
                results.append(ExpiringFileCandidate(url: url, reason: reason, dateAdded: added, size: size))
            }
        }
        return ScanReport(candidates: results.sorted { $0.dateAdded < $1.dateAdded }, folderErrors: folderErrors)
    }

    /// Installers, archives and screenshots are offered automatically. Other
    /// files only expire when the user marks them. Spotlight's screen-capture
    /// flag catches screenshots in any language or with a custom name.
    nonisolated static func reasonForKind(of url: URL, isScreenCapture: Bool = false) -> ExpiringFileCandidate.Reason? {
        let fileExtension = url.pathExtension.lowercased()
        if ["dmg", "pkg", "mpkg", "iso"].contains(fileExtension) { return .installer }
        if ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"].contains(fileExtension) { return .archive }
        if isScreenCapture { return .screenshot }
        let name = url.lastPathComponent
        if screenshotPrefixes.contains(where: name.hasPrefix) { return .screenshot }
        return nil
    }

    /// English defaults plus whatever name the user gave screenshots in the Screenshot app.
    nonisolated static var screenshotPrefixes: [String] {
        var prefixes = ["Screenshot ", "Screen Shot ", "CleanShot ", "Screen Recording "]
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "name"), !custom.isEmpty {
            prefixes.append(custom + " ")
        }
        return prefixes
    }

    /// Allocated size of a package such as an app bundle, so the Trash total is honest.
    nonisolated static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: Set(keys)))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Spotlight facts about a file that make the scan smarter. Tests use `.unavailable`.
package struct FileSignals: Sendable {
    package let lastOpened: @Sendable (URL) -> Date?
    package let isScreenCapture: @Sendable (URL) -> Bool

    package init(lastOpened: @escaping @Sendable (URL) -> Date?, isScreenCapture: @escaping @Sendable (URL) -> Bool) {
        self.lastOpened = lastOpened
        self.isScreenCapture = isScreenCapture
    }

    package static let unavailable = FileSignals(lastOpened: { _ in nil }, isScreenCapture: { _ in false })

    package static let live = FileSignals(
        lastOpened: { url in
            guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
            return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        },
        isScreenCapture: { url in
            guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return false }
            return (MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool) == true
        }
    )
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
        return FinishedDownloadDetector(installedApps: apps, lastOpened: FileSignals.live.lastOpened)
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
        if isArchive, siblings.contains(where: { Self.isExtraction($0, of: url, addedOn: added) }) {
            return .extracted
        }
        return nil
    }

    /// True when `sibling` looks like what Archive Utility made from `archive`: same
    /// base name (allowing its " 2" suffix), not an archive itself, and arrived
    /// after the download, so an older folder that shares the name doesn't count.
    static func isExtraction(_ sibling: URL, of archive: URL, addedOn added: Date) -> Bool {
        guard sibling != archive,
              ExpiringFilesManager.reasonForKind(of: sibling) != .archive,
              ExpiringFilesManager.reasonForKind(of: sibling) != .installer
        else { return false }
        let base = archiveBaseName(of: archive)
        let name = sibling.lastPathComponent
        let matches = name == base
            || (name.hasPrefix(base + " ") && Int(name.dropFirst(base.count + 1)) != nil)
        guard matches else { return false }
        let values = try? sibling.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        guard let siblingAdded = values?.addedToDirectoryDate ?? values?.creationDate else { return false }
        // A minute of slack covers clock rounding between the two timestamps.
        return siblingAdded >= added.addingTimeInterval(-60)
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

    /// Exact match, or one name starting with the other when the shorter has at
    /// least four characters, so "Arc" doesn't claim "archiver.dmg".
    static func namesMatch(_ product: String, _ appName: String) -> Bool {
        let app = appName.lowercased().filter { $0.isLetter || $0.isNumber }
        guard product.count >= 3, app.count >= 3 else { return false }
        if product == app { return true }
        guard min(product.count, app.count) >= 4 else { return false }
        return app.hasPrefix(product) || product.hasPrefix(app)
    }
}
