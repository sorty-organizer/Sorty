import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Beam

// How cache size is measured and cleared. Kept in one place so the tile's
// displayed size and the Clear action always cover the same locations.
enum CacheMaintenance {
    /// Filename prefixes for Sorty-owned items in the shared temporary directory.
    static let ownedTemporaryPrefixes = ["sorty-", "Sorty_", "SortyNotificationIcon-"]

    static func cacheDirectories(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.sorty.app",
        cachesDirectory: URL? = nil,
        appSupportDirectory: URL? = nil
    ) -> [URL] {
        var directories: [URL] = []

        let caches = cachesDirectory ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let cachesURL = caches {
            directories.append(cachesURL.appendingPathComponent(bundleIdentifier, isDirectory: true))
            directories.append(cachesURL.appendingPathComponent("Sorty", isDirectory: true))
        }

        let appSupport = appSupportDirectory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        if let appSupportURL = appSupport {
            let sortySupport = appSupportURL.appendingPathComponent("Sorty", isDirectory: true)
            directories.append(sortySupport.appendingPathComponent("Cache", isDirectory: true))
            directories.append(sortySupport.appendingPathComponent("ModelCache", isDirectory: true))
        }

        return directories
    }

    static func ownedTemporaryItems(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return items.filter { item in
            ownedTemporaryPrefixes.contains { item.lastPathComponent.hasPrefix($0) }
        }
    }

    static func totalSize(
        of directories: [URL],
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil
    ) -> Int64 {
        var totalSize: Int64 = 0
        for directory in directories where fileManager.fileExists(atPath: directory.path) {
            totalSize += directorySize(at: directory, fileManager: fileManager)
        }
        let temporary = temporaryDirectory ?? fileManager.temporaryDirectory
        for item in ownedTemporaryItems(in: temporary, fileManager: fileManager) {
            totalSize += size(of: item, fileManager: fileManager)
        }
        return totalSize
    }

    /// Removes cached data and recreates the roots so later writers never hit a missing directory.
    /// Deletes directory contents item-by-item so one locked file can't block everything else.
    @discardableResult
    static func clear(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.sorty.app",
        cachesDirectory: URL? = nil,
        appSupportDirectory: URL? = nil,
        temporaryDirectory: URL? = nil
    ) -> [Error] {
        var deletionErrors: [Error] = []

        let directories = cacheDirectories(
            fileManager: fileManager,
            bundleIdentifier: bundleIdentifier,
            cachesDirectory: cachesDirectory,
            appSupportDirectory: appSupportDirectory
        )
        for directory in directories {
            deletionErrors.append(contentsOf: removeContents(
                of: directory,
                fileManager: fileManager,
                recreateRoot: true
            ))
        }

        let temporary = temporaryDirectory ?? fileManager.temporaryDirectory
        for item in ownedTemporaryItems(in: temporary, fileManager: fileManager) {
            do {
                try fileManager.removeItem(at: item)
            } catch {
                deletionErrors.append(error)
            }
        }

        return deletionErrors
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static func removeContents(
        of directory: URL,
        fileManager: FileManager,
        recreateRoot: Bool
    ) -> [Error] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }

        var deletionErrors: [Error] = []
        if let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for item in items {
                do {
                    try fileManager.removeItem(at: item)
                } catch {
                    deletionErrors.append(error)
                }
            }
        } else {
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                deletionErrors.append(error)
            }
        }

        if recreateRoot {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return deletionErrors
    }

    private static func size(of url: URL, fileManager: FileManager) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if isDirectory.boolValue {
            return directorySize(at: url, fileManager: fileManager)
        }
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func directorySize(at url: URL, fileManager: FileManager = .default) -> Int64 {
        var size: Int64 = 0

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if resourceValues.isDirectory == false {
                    size += Int64(resourceValues.fileSize ?? 0)
                }
            } catch {
                // Skip files we can't access
            }
        }

        return size
    }
}
