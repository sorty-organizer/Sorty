//
//  StorageLocation.swift
//  Sorty
//
//  Model for local, cloud, and external locations Sorty can organize across.
//

import Foundation
import AppKit
import Combine

public enum StorageProviderKind: String, Codable, Hashable, Sendable {
    case local
    case externalVolume
    case iCloudDrive
    case googleDrive
    case dropbox
    case oneDrive
    case box
    case fileProvider

    public var displayName: String {
        switch self {
        case .local: return "Local storage"
        case .externalVolume: return "External volume"
        case .iCloudDrive: return "iCloud Drive"
        case .googleDrive: return "Google Drive"
        case .dropbox: return "Dropbox"
        case .oneDrive: return "OneDrive"
        case .box: return "Box"
        case .fileProvider: return "Cloud File Provider"
        }
    }
}

public enum StorageOrganizationCapability: String, Codable, Hashable, Sendable {
    case createFiles
    case createFolders
    case moveItems
    case renameItems
    case trashItems
    case finderTags
    case makeAvailableOffline
    case evictLocalCopy
    case starItems
    case createShortcuts
    case customMetadata
}

public struct StorageCapabilityProfile: Hashable, Sendable {
    public let provider: StorageProviderKind
    public let isReadOnly: Bool
    public let supportedFileSystemActions: Set<StorageOrganizationCapability>
    public let providerActionsRequiringIntegration: Set<StorageOrganizationCapability>
    public let conventions: [String]

    public var promptContext: String {
        let supported = supportedFileSystemActions
            .map(\.promptName)
            .sorted()
            .joined(separator: ", ")
        var lines = [
            "  Environment: \(provider.displayName)\(isReadOnly ? " (read-only)" : "")",
            "  Available filesystem actions: \(supported.isEmpty ? "read only" : supported)",
        ]
        if !providerActionsRequiringIntegration.isEmpty {
            let gated = providerActionsRequiringIntegration
                .map(\.promptName)
                .sorted()
                .joined(separator: ", ")
            lines.append(
                "  Provider-native actions requiring a connected account: \(gated). Do not include these in a plan unless Sorty reports the provider integration as connected."
            )
        }
        lines.append(contentsOf: conventions.map { "  Convention: \($0)" })
        return lines.joined(separator: "\n")
    }
}

private extension StorageOrganizationCapability {
    var promptName: String {
        switch self {
        case .createFiles: return "create files"
        case .createFolders: return "create folders"
        case .moveItems: return "move files and folders"
        case .renameItems: return "rename files and folders"
        case .trashItems: return "move items to Trash"
        case .finderTags: return "apply Finder tags"
        case .makeAvailableOffline: return "make available offline"
        case .evictLocalCopy: return "remove local download"
        case .starItems: return "star files and folders"
        case .createShortcuts: return "create shortcuts"
        case .customMetadata: return "apply provider metadata"
        }
    }
}

/// RAII-style wrapper for security-scoped resource access
public class ScopedSecurityAccess {
    public let url: URL
    private let didAccess: Bool
    private var didCleanup = false

    public init(url: URL, didAccess: Bool) {
        self.url = url
        self.didAccess = didAccess
    }
    
    deinit {
        cleanup()
    }
    
    public func cleanup() {
        if didAccess && !didCleanup {
            didCleanup = true
            url.stopAccessingSecurityScopedResource()
        }
    }
}

/// A local, cloud, or external location that can participate in organization.
public struct StorageLocation: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var path: String
    public var name: String
    public var description: String? // User-provided description for AI context (e.g., "Archive for old projects")
    public var isEnabled: Bool
    public var bookmarkData: Data?
    public var accessStatus: FolderAccessStatus = .unknown
    
    public init(
        id: UUID = UUID(),
        path: String,
        name: String? = nil,
        description: String? = nil,
        isEnabled: Bool = true,
        bookmarkData: Data? = nil
    ) {
        let canonicalPath = StorageLocationPathResolver.canonicalPath(path)
        self.id = id
        self.path = canonicalPath
        self.name = name ?? URL(fileURLWithPath: canonicalPath).lastPathComponent
        self.description = description
        self.isEnabled = isEnabled
        self.bookmarkData = bookmarkData
    }
    
    public var url: URL {
        URL(fileURLWithPath: path)
    }
    
    public var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }
    
    /// Returns the prompt context for AI to understand this storage location
    public var promptContext: String {
        let canonicalPath = StorageLocationPathResolver.canonicalPath(path)
        var context = "- \(name)"
        context += "\n  Exact path: \(canonicalPath)"
        if let desc = description, !desc.isEmpty {
            context += "\n  Purpose: \(desc)"
        } else {
            context += "\n  Purpose: Infer conservatively from the location name and its known subfolders."
        }
        return context + "\n" + capabilityProfile.promptContext
    }

    public var capabilityProfile: StorageCapabilityProfile {
        StorageEnvironmentInspector.profile(for: url)
    }
}

public enum StorageEnvironmentInspector {
    public static func profile(for url: URL) -> StorageCapabilityProfile {
        let provider = providerKind(for: url)
        let values = try? url.resourceValues(forKeys: [
            .volumeIsReadOnlyKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
        ])
        let isReadOnly = values?.volumeIsReadOnly == true
        var fileSystemActions: Set<StorageOrganizationCapability> = []
        if !isReadOnly {
            fileSystemActions = [
                .createFiles,
                .createFolders,
                .moveItems,
                .renameItems,
                .trashItems,
            ]
            if provider == .local || provider == .externalVolume || provider == .iCloudDrive {
                fileSystemActions.insert(.finderTags)
            }
        }

        let providerActions: Set<StorageOrganizationCapability>
        let conventions: [String]
        switch provider {
        case .googleDrive:
            providerActions = [.starItems, .createShortcuts, .customMetadata]
            conventions = [
                "Starred is per-user Google Drive metadata, not a Finder tag.",
                "Shared-drive items have exactly one parent; use a Drive shortcut when an item should appear in another location.",
                "Respect the current user's Drive capabilities and shared-drive role before moving or deleting items.",
            ]
        case .dropbox:
            providerActions = [.customMetadata]
            conventions = [
                "Dropbox custom properties require an authenticated Dropbox metadata integration.",
                "Treat online-only placeholders as unavailable until the provider downloads them.",
            ]
        case .oneDrive, .box, .fileProvider:
            providerActions = [.customMetadata]
            conventions = [
                "Provider-native metadata requires an authenticated provider adapter.",
                "Treat online-only placeholders as unavailable until the provider downloads them.",
            ]
        case .iCloudDrive:
            providerActions = []
            conventions = [
                "Treat evicted iCloud items as unavailable until downloaded.",
                "Finder tags are supported through macOS resource metadata.",
            ]
        case .externalVolume:
            providerActions = []
            conventions = [
                "Preserve file metadata during cross-volume transfers and verify the copy before deleting the source.",
                "Check destination capacity and availability immediately before applying a plan.",
            ]
        case .local:
            providerActions = []
            conventions = ["Use native macOS file and Finder metadata operations."]
        }

        return StorageCapabilityProfile(
            provider: provider,
            isReadOnly: isReadOnly,
            supportedFileSystemActions: fileSystemActions,
            providerActionsRequiringIntegration: providerActions,
            conventions: conventions
        )
    }

    public static func providerKind(for url: URL) -> StorageProviderKind {
        let components = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
        let path = components.joined(separator: "/")
        if path.contains("googledrive") || path.contains("google drive") {
            return .googleDrive
        }
        if path.contains("dropbox") {
            return .dropbox
        }
        if path.contains("onedrive") || path.contains("one drive") {
            return .oneDrive
        }
        if path.contains("cloudstorage/box") {
            return .box
        }
        if components.contains("mobile documents") || path.contains("icloud") {
            return .iCloudDrive
        }
        if components.contains("cloudstorage") {
            return .fileProvider
        }

        let values = try? url.resourceValues(forKeys: [
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
        ])
        if values?.volumeIsRemovable == true || values?.volumeIsInternal == false {
            return .externalVolume
        }
        return .local
    }
}

/// Manager for persisting storage locations
@MainActor
public class StorageLocationsManager: ObservableObject {
    @Published public private(set) var locations: [StorageLocation] = []
    @Published public private(set) var hasLoadedPersistedState = false
    private let userDefaults = UserDefaults.standard
    private let persistedDataReader = UserDefaultsDataReader(.standard)
    private let storageKey = "storageLocations"
    private var activeSecurityScopedURLs: [UUID: URL] = [:]
    private let subfolderDiscovery = StorageSubfolderDiscoveryService()
    private var loadTask: Task<[StorageLocation], Never>?
    private var hasPendingChanges = false
    private var loadGeneration = 0
    private var restoreTask: Task<Void, Never>?
    private var lastAccessValidationAt: Date?
    private var accessNeedsRefresh = true
    private let accessValidationLifetime: TimeInterval = 5 * 60

    private struct BookmarkRestoreSnapshot: Sendable {
        let id: UUID
        let bookmarkData: Data?
        let path: String
    }

    private struct BookmarkRestoreResult: Sendable {
        let id: UUID
        let originalBookmark: Data?
        let status: FolderAccessStatus
        let newBookmark: Data?
        let resolvedPath: String?
        let url: URL?
        let didAccess: Bool
    }
    
    public init() {
        setupNotificationObservers()
    }

    /// Decodes locations away from the main actor. In-memory additions are merged before saving.
    public func loadPersistedState() async {
        guard !hasLoadedPersistedState else { return }

        let generation = loadGeneration
        let task: Task<[StorageLocation], Never>
        if let loadTask {
            task = loadTask
        } else {
            let persistedDataReader = persistedDataReader
            let storageKey = storageKey
            task = Task.detached(priority: .userInitiated) {
                guard let data = persistedDataReader.data(forKey: storageKey),
                      let decoded = try? JSONDecoder().decode([StorageLocation].self, from: data) else {
                    return []
                }
                return Self.normalizedLocations(decoded)
            }
            loadTask = task
        }

        let persistedLocations = await task.value
        guard !hasLoadedPersistedState, generation == loadGeneration else { return }

        var seenPaths: Set<String> = []
        var merged: [StorageLocation] = []
        for location in persistedLocations + locations {
            let path = StorageLocationPathResolver.canonicalPath(location.path)
            guard seenPaths.insert(path).inserted else { continue }
            var normalized = location
            normalized.path = path
            merged.append(normalized)
        }
        locations = merged
        hasLoadedPersistedState = true
        loadTask = nil

        if hasPendingChanges {
            hasPendingChanges = false
            saveLocations()
        }
    }
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addMainActorObserver(forName: .clearAllUsageData, object: nil, queue: .main) { [weak self] in
            self?.clearAll()
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addMainActorObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] in
            self?.accessNeedsRefresh = true
        }
        workspaceCenter.addMainActorObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] in
            self?.accessNeedsRefresh = true
        }
    }
    
    public var enabledLocations: [StorageLocation] {
        var deduped: [StorageLocation] = []
        var seenPaths: Set<String> = []

        for location in locations where location.isEnabled && location.exists && location.accessStatus != .lost {
            let canonicalPath = StorageLocationPathResolver.canonicalPath(location.path)
            guard seenPaths.insert(canonicalPath).inserted else { continue }

            var normalizedLocation = location
            normalizedLocation.path = canonicalPath
            deduped.append(normalizedLocation)
        }

        return deduped
    }

    public func clearAll() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        restoreTask?.cancel()
        restoreTask = nil
        hasLoadedPersistedState = true
        hasPendingChanges = false
        stopAllSecurityScopedAccess()
        lastAccessValidationAt = nil
        accessNeedsRefresh = true
        locations.removeAll()
        userDefaults.removeObject(forKey: storageKey)
    }
    
    public func addLocation(_ location: StorageLocation) {
        var normalized = location
        normalized.path = StorageLocationPathResolver.canonicalPath(location.path)

        // Avoid duplicates, even if path formatting differs (e.g. trailing slash)
        guard !locations.contains(where: { StorageLocationPathResolver.pathsEqual($0.path, normalized.path) }) else { return }
        locations.append(normalized)
        accessNeedsRefresh = true
        saveLocations()
    }
    
    public func addLocation(url: URL, description: String? = nil, customName: String? = nil) throws {
        let canonicalPath = StorageLocationPathResolver.canonicalPath(url.path)
        guard !locations.contains(where: { StorageLocationPathResolver.pathsEqual($0.path, canonicalPath) }) else {
            throw StorageLocationError.duplicateLocation
        }

        // For picker URLs, explicitly starting security scope improves bookmark reliability
        // for folders outside default sandbox access (for example Downloads/Desktop/external volumes).
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let bookmarkData = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        var location = StorageLocation(
            path: url.path,
            name: customName ?? url.lastPathComponent,
            description: description,
            isEnabled: true,
            bookmarkData: bookmarkData
        )
        location.accessStatus = .unknown
        locations.append(location)
        saveLocations()
        refreshAccess(for: location)
    }
    
    public func removeLocation(_ location: StorageLocation) {
        stopSecurityScopedAccess(for: location.id)
        locations.removeAll { $0.id == location.id }
        accessNeedsRefresh = true
        saveLocations()
    }
    
    public func updateLocation(_ location: StorageLocation) {
        let normalizedPath = StorageLocationPathResolver.canonicalPath(location.path)
        if locations.contains(where: { $0.id != location.id && StorageLocationPathResolver.pathsEqual($0.path, normalizedPath) }) {
            return
        }

        if let index = locations.firstIndex(where: { $0.id == location.id }) {
            var normalized = location
            normalized.path = normalizedPath
            let accessChanged = locations[index].bookmarkData != normalized.bookmarkData
                || locations[index].path != normalized.path
            locations[index] = normalized
            if accessChanged {
                stopSecurityScopedAccess(for: location.id)
                accessNeedsRefresh = true
            }
            saveLocations()
        }
    }
    
    public func toggleEnabled(for location: StorageLocation) {
        if var updated = locations.first(where: { $0.id == location.id }) {
            updated.isEnabled.toggle()
            updateLocation(updated)
        }
    }
    
    /// Generates prompt context for all enabled storage locations
    public func generatePromptContext() async -> String? {
        let enabled = enabledLocations
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !enabled.isEmpty else { return nil }
        let validPaths = enabled.map(\.path)
        let existingSubfoldersByRoot = await withTaskGroup(
            of: (String, [String]).self,
            returning: [String: [String]].self
        ) { group in
            for location in enabled {
                group.addTask { [subfolderDiscovery] in
                    let subfolders = await subfolderDiscovery.discover(
                        for: location,
                        maxDepth: 3,
                        maxCount: 12
                    )
                    return (location.path, subfolders)
                }
            }

            var result: [String: [String]] = [:]
            for await (path, subfolders) in group where !subfolders.isEmpty {
                result[path] = subfolders
            }
            return result
        }
        
        var prompt = """
        ## ORGANIZATION LOCATIONS
        
        The following local, cloud, and external directories are approved organization locations.
        Treat them as first-class sources and destinations. Apply the user's instructions and each
        location's stated purpose consistently, regardless of where the location is stored.
        For every file, actively compare the source folder with these locations before choosing a
        destination. An enabled writable location is permission to use it when its name, purpose, or
        existing subfolders are a better semantic match; the user does not need to explicitly request
        storage in the current instruction. Do not use a location merely because it is available.
        
        """
        
        for location in enabled {
            prompt += location.promptContext + "\n"
        }

        let quotedPaths = validPaths.map { "\"\($0)\"" }.joined(separator: ", ")
        prompt += "\nVALID_STORAGE_PATHS = [\(quotedPaths)]\n"

        if !existingSubfoldersByRoot.isEmpty {
            prompt += "\nKNOWN_STORAGE_SUBFOLDERS (use these EXACT absolute paths as folder names when routing files here):\n"
            for location in enabled {
                guard let subfolders = existingSubfoldersByRoot[location.path], !subfolders.isEmpty else { continue }
                prompt += "- \(location.name):\n"
                for subfolder in subfolders {
                    prompt += "  - \(subfolder)\n"
                }
            }
        }
        
        let examplePath = validPaths.first ?? "/Users/me/Archive"
        prompt += """
        
        STORAGE LOCATION RULES:
        1. Storage destinations must use absolute paths from VALID_STORAGE_PATHS or their subfolders.
        2. ONLY use the storage roots listed above. Any absolute path outside those roots will be rejected.
        3. FIRST check KNOWN_STORAGE_SUBFOLDERS. When an existing subfolder matches the file's purpose, use its EXACT absolute path as the folder "name" in JSON.
        4. Never use relative placeholders such as "storage", "storage location", "archive", "Spreadsheets", or any other relative name as folder names when targeting storage.
        5. Match files to organization locations based on their name, stated purpose/description, and known subfolders.
        6. Prefer a well-matched organization location over creating a parallel local category in the source directory. When no organization location is a defensible match, organize within the source directory using relative paths.
        7. Files and folders may move into, out of, or within these locations when the plan calls for it.
        8. Consider all enabled locations on every plan. Use zero or more according to the content and the user's request; explicit mention of storage is not required.
        9. Use the FULL absolute path as the folder "name" in JSON (e.g. "name": "/Users/me/Archive/Documents").
           Do NOT split the path into a nested folder hierarchy. Do NOT use PascalCase variants of folder names.
        10. Existing and new subfolders may be used in any location just as they can in the source directory.
        11. A read-only location may be used as a source but never as a destination. Only propose actions listed as available filesystem actions.
        
        REQUIRED JSON FORMAT when routing files to storage:
        {"folders":[{"name":"\(examplePath)","files":[{"filename":"example.xlsx"}]}]}
        The folder "name" MUST be the absolute path copied from VALID_STORAGE_PATHS above — NOT a relative name.
        """
        
        return prompt
    }

    /// Returns known subfolders for each enabled storage location.
    /// Keys are canonical root paths; values are lists of discovered subfolder absolute paths.
    public func discoverAllSubfolders() async -> [String: [String]] {
        let enabled = enabledLocations
        return await withTaskGroup(
            of: (String, [String]).self,
            returning: [String: [String]].self
        ) { group in
            for location in enabled {
                group.addTask { [subfolderDiscovery] in
                    let subfolders = await subfolderDiscovery.discover(
                        for: location,
                        maxDepth: 3,
                        maxCount: 200
                    )
                    return (location.path, subfolders)
                }
            }

            var result: [String: [String]] = [:]
            for await (path, subfolders) in group where !subfolders.isEmpty {
                result[path] = subfolders
            }
            return result
        }
    }
    
    /// Resolves a storage location URL with security-scoped access
    /// Returns a wrapper that ensures balanced access (call .cleanup() when done).
    /// Renews stale bookmarks so access survives across launches.
    public func resolveURL(for location: StorageLocation) -> ScopedSecurityAccess? {
        guard let bookmarkData = location.bookmarkData else {
            return ScopedSecurityAccess(url: location.url, didAccess: false)
        }

        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmarkData,
                              options: .withSecurityScope,
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)

            if isStale {
                do {
                    let renewed = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    if let index = locations.firstIndex(where: { $0.id == location.id }) {
                        locations[index].bookmarkData = renewed
                        saveLocations()
                    }
                } catch {
                    DebugLogger.log("Failed to renew stale storage bookmark: \(error.localizedDescription)")
                }
            }

            if url.startAccessingSecurityScopedResource() {
                return ScopedSecurityAccess(url: url, didAccess: true)
            }
            // startAccessing returns false outside the sandbox even for valid
            // bookmarks; only mark lost when actually sandboxed.
            if SandboxEnvironment.isSandboxed {
                markAccessLost(for: location.id)
            } else {
                return ScopedSecurityAccess(url: url, didAccess: false)
            }
        } catch {
            markAccessLost(for: location.id)
            DebugLogger.log("Failed to resolve storage location bookmark: \(error)")
        }

        return nil
    }
    
    /// Restores access to all security-scoped bookmarks off the main actor.
    /// Snapshots identity before leaving, accepts results only for matching items,
    /// and balances every acquisition. Callers await this before automation uses locations.
    public func restoreSecurityScopedAccess() async {
        await loadPersistedState()
        if let restoreTask {
            await restoreTask.value
            return
        }
        if canReuseValidatedAccess {
            return
        }

        let generation = loadGeneration
        let snapshots: [BookmarkRestoreSnapshot] = locations.map {
            BookmarkRestoreSnapshot(id: $0.id, bookmarkData: $0.bookmarkData, path: $0.path)
        }
        guard !snapshots.isEmpty else {
            lastAccessValidationAt = Date()
            accessNeedsRefresh = false
            return
        }

        let task = Task { [weak self] in
            let results = await Task.detached(priority: .utility) {
                Self.resolveBookmarks(snapshots)
            }.value
            guard let self else {
                for result in results where result.didAccess {
                    result.url?.stopAccessingSecurityScopedResource()
                }
                return
            }
            self.applyBookmarkRestoreResults(results, generation: generation)
        }
        restoreTask = task
        await task.value
        restoreTask = nil
    }

    /// Re-checks all locations and repairs stale bookmarks where possible.
    /// Safe to call repeatedly; each location has at most one long-lived access session.
    public func refreshAccessStatus() async {
        accessNeedsRefresh = true
        await restoreSecurityScopedAccess()
    }

    private var canReuseValidatedAccess: Bool {
        guard !accessNeedsRefresh,
              let lastAccessValidationAt,
              Date().timeIntervalSince(lastAccessValidationAt) < accessValidationLifetime else {
            return false
        }
        return locations.allSatisfy { location in
            guard location.exists else { return false }
            guard location.bookmarkData != nil else { return true }
            guard let activeURL = activeSecurityScopedURLs[location.id] else { return false }
            return location.accessStatus == .valid
                && StorageLocationPathResolver.canonicalPath(activeURL.path)
                    == StorageLocationPathResolver.canonicalPath(location.path)
        }
    }

    private nonisolated static func resolveBookmarks(
        _ snapshots: [BookmarkRestoreSnapshot]
    ) -> [BookmarkRestoreResult] {
        var results: [BookmarkRestoreResult] = []
        results.reserveCapacity(snapshots.count)

        for snapshot in snapshots {
            guard !Task.isCancelled else { break }
            guard let bookmarkData = snapshot.bookmarkData else {
                let exists = FileManager.default.fileExists(atPath: snapshot.path)
                results.append(
                    BookmarkRestoreResult(
                        id: snapshot.id,
                        originalBookmark: nil,
                        status: exists ? .valid : .lost,
                        newBookmark: nil,
                        resolvedPath: nil,
                        url: nil,
                        didAccess: false
                    )
                )
                continue
            }

            var isStale = false
            do {
                let resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                var newBookmark: Data? = nil
                if isStale {
                    newBookmark = try? resolvedURL.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                }
                guard resolvedURL.startAccessingSecurityScopedResource() else {
                    // Outside the sandbox, startAccessing returns false for
                    // valid bookmarks; keep the location usable without a
                    // held session.
                    if SandboxEnvironment.isSandboxed {
                        results.append(
                            BookmarkRestoreResult(
                                id: snapshot.id,
                                originalBookmark: bookmarkData,
                                status: .lost,
                                newBookmark: nil,
                                resolvedPath: nil,
                                url: nil,
                                didAccess: false
                            )
                        )
                    } else {
                        results.append(
                            BookmarkRestoreResult(
                                id: snapshot.id,
                                originalBookmark: bookmarkData,
                                status: .valid,
                                newBookmark: newBookmark,
                                resolvedPath: StorageLocationPathResolver.canonicalPath(resolvedURL.path),
                                url: nil,
                                didAccess: false
                            )
                        )
                    }
                    continue
                }

                results.append(
                    BookmarkRestoreResult(
                        id: snapshot.id,
                        originalBookmark: bookmarkData,
                        status: .valid,
                        newBookmark: newBookmark,
                        resolvedPath: StorageLocationPathResolver.canonicalPath(resolvedURL.path),
                        url: resolvedURL,
                        didAccess: true
                    )
                )
            } catch {
                results.append(
                    BookmarkRestoreResult(
                        id: snapshot.id,
                        originalBookmark: bookmarkData,
                        status: .lost,
                        newBookmark: nil,
                        resolvedPath: nil,
                        url: nil,
                        didAccess: false
                    )
                )
            }
        }
        return results
    }

    private func applyBookmarkRestoreResults(
        _ results: [BookmarkRestoreResult],
        generation: Int
    ) {
        guard generation == loadGeneration else {
            for result in results where result.didAccess {
                result.url?.stopAccessingSecurityScopedResource()
            }
            return
        }

        var didChange = false
        for result in results {
            guard let index = locations.firstIndex(where: { $0.id == result.id }),
                  locations[index].bookmarkData == result.originalBookmark else {
                if result.didAccess {
                    result.url?.stopAccessingSecurityScopedResource()
                }
                continue
            }

            stopSecurityScopedAccess(for: result.id)

            if result.didAccess, let url = result.url {
                activeSecurityScopedURLs[result.id] = url
            }

            if locations[index].accessStatus != result.status {
                locations[index].accessStatus = result.status
                didChange = true
            }
            if let newBookmark = result.newBookmark,
               locations[index].bookmarkData != newBookmark {
                locations[index].bookmarkData = newBookmark
                didChange = true
            }
            if let resolvedPath = result.resolvedPath,
               locations[index].path != resolvedPath {
                locations[index].path = resolvedPath
                didChange = true
            }
        }

        if didChange {
            saveLocations()
        }
        lastAccessValidationAt = Date()
        accessNeedsRefresh = false
    }
    
    /// Re-authorizes a storage location by creating a new security-scoped bookmark from a freshly-picked URL
    public func reauthorizeLocation(_ location: StorageLocation, with url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            DebugLogger.log("Failed to access security-scoped resource for reauthorization: \(url.path)")
            return
        }

        do {
            let newBookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            var updated = location
            updated.bookmarkData = newBookmarkData
            updated.path = url.path
            updated.accessStatus = .valid
            stopSecurityScopedAccess(for: location.id)
            updateLocation(updated)
            activeSecurityScopedURLs[location.id] = url
            lastAccessValidationAt = Date()

            DebugLogger.log("Successfully reauthorized storage location: \(location.name)")
        } catch {
            url.stopAccessingSecurityScopedResource()
            accessNeedsRefresh = true
            DebugLogger.log("Failed to create bookmark during reauthorization: \(error)")
        }
    }

    private func refreshAccess(for location: StorageLocation) {
        guard let index = locations.firstIndex(where: { $0.id == location.id }) else { return }
        guard let bookmarkData = location.bookmarkData else {
            locations[index].accessStatus = location.exists ? .valid : .lost
            saveLocations()
            return
        }

        stopSecurityScopedAccess(for: location.id)
        var isStale = false
        do {
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard resolvedURL.startAccessingSecurityScopedResource() else {
                locations[index].accessStatus = .lost
                saveLocations()
                return
            }

            activeSecurityScopedURLs[location.id] = resolvedURL
            locations[index].path = StorageLocationPathResolver.canonicalPath(resolvedURL.path)
            locations[index].accessStatus = .valid

            if isStale {
                locations[index].bookmarkData = try resolvedURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
            saveLocations()
            lastAccessValidationAt = Date()
        } catch {
            locations[index].accessStatus = .lost
            accessNeedsRefresh = true
            saveLocations()
            DebugLogger.log("Failed to refresh storage location bookmark: \(error)")
        }
    }

    private func stopSecurityScopedAccess(for id: UUID) {
        guard let url = activeSecurityScopedURLs.removeValue(forKey: id) else { return }
        url.stopAccessingSecurityScopedResource()
    }

    private func markAccessLost(for id: UUID) {
        stopSecurityScopedAccess(for: id)
        accessNeedsRefresh = true
        guard let index = locations.firstIndex(where: { $0.id == id }),
              locations[index].accessStatus != .lost else {
            return
        }
        locations[index].accessStatus = .lost
        saveLocations()
    }

    private func stopAllSecurityScopedAccess() {
        for url in activeSecurityScopedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs.removeAll()
    }

    private nonisolated static func normalizedLocations(
        _ decoded: [StorageLocation]
    ) -> [StorageLocation] {
        var normalized: [StorageLocation] = []
        var seenPaths: Set<String> = []

        for var location in decoded {
            location.path = StorageLocationPathResolver.canonicalPath(location.path)
            guard seenPaths.insert(location.path).inserted else { continue }
            normalized.append(location)
        }
        return normalized
    }

    private func saveLocations() {
        guard hasLoadedPersistedState else {
            hasPendingChanges = true
            return
        }
        if let encoded = try? JSONEncoder().encode(locations) {
            userDefaults.set(encoded, forKey: storageKey)
        }
    }
}

private actor StorageSubfolderDiscoveryService {
    private struct CacheKey: Hashable {
        let locationID: UUID
        let path: String
        let maxDepth: Int
        let maxCount: Int
    }

    private struct CacheEntry {
        let subfolders: [String]
        let createdAt: ContinuousClock.Instant
    }

    private let cacheLifetime: Duration = .seconds(15)
    private var cache: [CacheKey: CacheEntry] = [:]

    func discover(
        for location: StorageLocation,
        maxDepth: Int,
        maxCount: Int
    ) async -> [String] {
        let key = CacheKey(
            locationID: location.id,
            path: location.path,
            maxDepth: maxDepth,
            maxCount: maxCount
        )
        let clock = ContinuousClock()
        if let cached = cache[key], cached.createdAt.duration(to: clock.now) < cacheLifetime {
            return cached.subfolders
        }

        let subfolders = await Task.detached(priority: .utility) {
            Self.scan(location: location, maxDepth: maxDepth, maxCount: maxCount)
        }.value
        cache[key] = CacheEntry(subfolders: subfolders, createdAt: clock.now)
        return subfolders
    }

    private nonisolated static func scan(
        location: StorageLocation,
        maxDepth: Int,
        maxCount: Int
    ) -> [String] {
        let rootURL: URL
        var accessedURL: URL?

        if let bookmarkData = location.bookmarkData {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), resolvedURL.startAccessingSecurityScopedResource() {
                rootURL = resolvedURL
                accessedURL = resolvedURL
            } else {
                rootURL = location.url
            }
        } else {
            rootURL = location.url
        }
        defer { accessedURL?.stopAccessingSecurityScopedResource() }

        var discovered: [String] = []
        let fileManager = FileManager()

        func scanDirectory(_ directoryURL: URL, depth: Int) {
            guard !Task.isCancelled,
                  depth <= maxDepth,
                  discovered.count < maxCount else {
                return
            }

            guard let contents = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                return
            }

            let subdirectories = contents.compactMap { item -> URL? in
                guard !Task.isCancelled,
                      let values = try? item.resourceValues(
                        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                      ),
                      values.isDirectory == true,
                      values.isSymbolicLink != true else {
                    return nil
                }
                return item
            }
            .sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent)
                    == .orderedAscending
            }

            for subdirectory in subdirectories {
                guard !Task.isCancelled else { return }
                discovered.append(StorageLocationPathResolver.canonicalPath(subdirectory.path))
                guard discovered.count < maxCount else { break }
                scanDirectory(subdirectory, depth: depth + 1)
                guard discovered.count < maxCount else { break }
            }
        }

        scanDirectory(rootURL, depth: 1)
        return discovered
    }
}

public enum StorageLocationError: LocalizedError, Equatable {
    case duplicateLocation

    public var errorDescription: String? {
        switch self {
        case .duplicateLocation:
            return "That folder is already a storage location."
        }
    }
}
