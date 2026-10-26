//
//  DownloadsInboxManager.swift
//  Sorty
//
//  Menu bar triage queue for new downloads (Labs: Downloads Inbox).
//

import Foundation
import Combine
import SortyFileSystem

/// A file that arrived in Downloads, with the folder Sorty suggests for it.
package struct DownloadsInboxItem: Identifiable, Equatable, Sendable {
    package var id: String { url.path }
    package let url: URL
    package let dateAdded: Date
    package let size: Int64
    package var suggestion: DownloadsInboxSuggestion
}

package struct DownloadsInboxSuggestion: Equatable, Sendable {
    package enum Source: Equatable, Sendable {
        /// A saved routing rule matched.
        case routingRule
        /// The user filed this kind of file there before.
        case remembered
        /// A folder named after the kind of file.
        case fileKind
    }

    package let destination: URL
    package let source: Source

    /// Short destination label for the menu bar, like "Images" or "~/Documents/Taxes".
    package var displayName: String {
        (destination.path as NSString).abbreviatingWithTildeInPath
            .replacingOccurrences(of: "~/Downloads/", with: "")
    }
}

/// The last move, kept so the inbox can undo it.
package struct DownloadsInboxMove: Equatable, Sendable {
    package let originalURL: URL
    package let movedURL: URL
}

/// Watches the Downloads folder and keeps a queue of files that arrived since
/// the inbox was turned on, each with a one-click destination.
///
/// Watching uses a single kernel vnode source on the folder, so an idle inbox
/// costs nothing. Call `refreshEnabledState()` after the Labs flag changes.
@MainActor
package final class DownloadsInboxManager: ObservableObject {
    package static let shared = DownloadsInboxManager()

    nonisolated package static let maximumItems = 20

    @Published package private(set) var items: [DownloadsInboxItem] = []
    @Published package private(set) var lastMove: DownloadsInboxMove?
    @Published package private(set) var lastError: String?

    package let downloadsURL: URL
    private let defaults: UserDefaults
    private var source: DispatchSourceFileSystemObject?
    private var refreshTask: Task<Void, Never>?

    private let sinceKey = "labs.inbox.since"
    private let dismissedKey = "labs.inbox.dismissed"
    private let rememberedKey = "labs.inbox.destinationsByExtension"

    /// Browsers write these while a download is still in progress.
    nonisolated private static let partialDownloadExtensions: Set<String> = [
        "crdownload", "download", "part", "partial", "tmp", "opdownload",
    ]

    package init(
        downloadsURL: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
        defaults: UserDefaults = .standard
    ) {
        self.downloadsURL = downloadsURL
        self.defaults = defaults
    }

    package var isEnabled: Bool { SortyLabsFeature.downloadsInbox.isEnabled }

    /// Starts or stops watching to match the Labs flag.
    package func refreshEnabledState() {
        if isEnabled {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        if defaults.object(forKey: sinceKey) == nil {
            // Only files that arrive from now on join the queue; the existing
            // pile is the Expiring Files feature's job.
            defaults.set(Date(), forKey: sinceKey)
        }
        if source == nil {
            let descriptor = open(downloadsURL.path, O_EVTONLY)
            if descriptor >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor,
                    eventMask: [.write, .rename, .delete],
                    queue: .main
                )
                source.setEventHandler { [weak self] in
                    MainActor.assumeIsolated { self?.scheduleRefresh() }
                }
                source.setCancelHandler { close(descriptor) }
                source.resume()
                self.source = source
            }
        }
        scheduleRefresh(delay: .zero)
    }

    private func stop() {
        source?.cancel()
        source = nil
        refreshTask?.cancel()
        items = []
        lastMove = nil
    }

    /// Coalesces bursts of folder events; a browser download fires several.
    package func scheduleRefresh(delay: Duration = .milliseconds(600)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func refresh() async {
        guard isEnabled else { return }
        let since = defaults.object(forKey: sinceKey) as? Date ?? Date()
        let dismissed = Set(defaults.stringArray(forKey: dismissedKey) ?? [])
        let downloadsURL = downloadsURL
        let found = await Task.detached(priority: .utility) {
            Self.scan(downloadsURL: downloadsURL, since: since, dismissed: dismissed)
        }.value
        guard !Task.isCancelled else { return }

        let routing = SortyLabsFeature.routingRules.isEnabled
            ? RoutingRulesStore.shared.matcherSnapshot() : .empty
        let remembered = defaults.dictionary(forKey: rememberedKey) as? [String: String] ?? [:]
        items = found.map { file in
            DownloadsInboxItem(
                url: file.url,
                dateAdded: file.dateAdded,
                size: file.size,
                suggestion: suggestion(for: file.url, size: file.size, dateAdded: file.dateAdded, routing: routing, remembered: remembered)
            )
        }
    }

    private struct ScannedDownload: Sendable {
        let url: URL
        let dateAdded: Date
        let size: Int64
    }

    nonisolated private static func scan(downloadsURL: URL, since: Date, dismissed: Set<String>) -> [ScannedDownload] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .isDirectoryKey, .isPackageKey, .fileSizeKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: downloadsURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents.compactMap { url -> ScannedDownload? in
            guard !partialDownloadExtensions.contains(url.pathExtension.lowercased()),
                  !dismissed.contains(url.path),
                  let values = try? url.resourceValues(forKeys: Set(keys))
            else { return nil }
            // Folders made by Sorty or the user are destinations, not downloads.
            if values.isDirectory == true, values.isPackage != true { return nil }
            let added = values.addedToDirectoryDate ?? values.creationDate ?? .distantPast
            guard added > since else { return nil }
            return ScannedDownload(url: url, dateAdded: added, size: Int64(values.fileSize ?? 0))
        }
        .sorted { $0.dateAdded > $1.dateAdded }
        .prefix(maximumItems)
        .map { $0 }
    }

    private func suggestion(
        for url: URL,
        size: Int64,
        dateAdded: Date,
        routing: RoutingRuleMatcher,
        remembered: [String: String]
    ) -> DownloadsInboxSuggestion {
        let fileExtension = url.pathExtension.lowercased()
        let file = FileItem(
            path: url.path,
            name: url.deletingPathExtension().lastPathComponent,
            extension: fileExtension,
            size: size,
            creationDate: dateAdded,
            modificationDate: dateAdded
        )
        if let rule = routing.firstMatch(for: file) {
            return DownloadsInboxSuggestion(
                destination: downloadsURL.appendingPathComponent(rule.destination(for: file), isDirectory: true),
                source: .routingRule
            )
        }
        if let path = remembered[fileExtension], FileManager.default.fileExists(atPath: path) {
            return DownloadsInboxSuggestion(destination: URL(fileURLWithPath: path, isDirectory: true), source: .remembered)
        }
        return DownloadsInboxSuggestion(
            destination: downloadsURL.appendingPathComponent(Self.kindFolderName(for: fileExtension), isDirectory: true),
            source: .fileKind
        )
    }

    package static func kindFolderName(for fileExtension: String) -> String {
        if ["dmg", "pkg", "mpkg", "iso"].contains(fileExtension) { return "Installers" }
        guard let category = FileTypeCategory.allCases.first(where: { $0.extensions.contains(fileExtension) }) else {
            return "Other"
        }
        return category.rawValue
    }

    // MARK: - Actions

    /// Moves the file to its suggestion, or to `destination` when the user
    /// picked one. A picked folder is remembered for that file extension.
    package func accept(_ item: DownloadsInboxItem, to destination: URL? = nil) async {
        let target = destination ?? item.suggestion.destination
        let sourceURL = item.url
        do {
            let movedURL = try await Task.detached(priority: .userInitiated) {
                try Self.move(sourceURL, into: target)
            }.value
            if destination != nil, !sourceURL.pathExtension.isEmpty {
                var remembered = defaults.dictionary(forKey: rememberedKey) as? [String: String] ?? [:]
                remembered[sourceURL.pathExtension.lowercased()] = target.path
                defaults.set(remembered, forKey: rememberedKey)
            }
            items.removeAll { $0.id == item.id }
            lastMove = DownloadsInboxMove(originalURL: sourceURL, movedURL: movedURL)
            lastError = nil
        } catch {
            lastError = "Couldn't move \(sourceURL.lastPathComponent): \(error.userFacingMessage)"
        }
    }

    package func undoLastMove() async {
        guard let move = lastMove else { return }
        do {
            try await Task.detached(priority: .userInitiated) {
                guard !FileManager.default.fileExists(atPath: move.originalURL.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try FileManager.default.moveItem(at: move.movedURL, to: move.originalURL)
            }.value
            lastMove = nil
            lastError = nil
            scheduleRefresh(delay: .zero)
        } catch {
            lastError = "Couldn't undo: \(error.userFacingMessage)"
        }
    }

    /// Removes the file from the queue without moving it.
    package func dismiss(_ item: DownloadsInboxItem) {
        var dismissed = defaults.stringArray(forKey: dismissedKey) ?? []
        dismissed.append(item.url.path)
        defaults.set(Array(dismissed.suffix(500)), forKey: dismissedKey)
        items.removeAll { $0.id == item.id }
    }

    /// Moves a file into a folder, creating it, and adds " 2", " 3"… to the
    /// name instead of overwriting.
    nonisolated package static func move(_ sourceURL: URL, into folderURL: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = sourceURL.pathExtension
        var candidate = folderURL.appendingPathComponent(sourceURL.lastPathComponent)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let name = fileExtension.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(fileExtension)"
            candidate = folderURL.appendingPathComponent(name)
            counter += 1
        }
        try fileManager.moveItem(at: sourceURL, to: candidate)
        return candidate
    }
}

/// Entry point the app shell calls once launch hydration finishes, so Labs
/// services never start on the launch path.
@MainActor
public enum SortyLabsServices {
    public static func startEnabledServices() {
        DownloadsInboxManager.shared.refreshEnabledState()
    }
}
