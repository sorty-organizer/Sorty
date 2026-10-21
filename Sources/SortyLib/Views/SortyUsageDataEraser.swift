import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

struct SortyUsageDataEraser {
    struct Locations {
        let applicationSupportDirectory: URL?
        let cachesDirectory: URL?
        let temporaryDirectory: URL
        let appGroupContainer: URL?
    }

    static func erase(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.sorty.app",
        locations: Locations? = nil
    ) -> [Error] {
        let locations = locations ?? defaultLocations(fileManager: fileManager)
        var failures: [Error] = []

        let removableRoots = ownedRoots(
            bundleIdentifier: bundleIdentifier,
            locations: locations
        )
        for root in removableRoots where fileManager.fileExists(atPath: root.path) {
            do {
                try fileManager.removeItem(at: root)
            } catch {
                failures.append(error)
            }
        }

        if let appGroupContainer = locations.appGroupContainer {
            failures.append(contentsOf: removeContents(
                of: appGroupContainer,
                fileManager: fileManager
            ))
        }

        failures.append(contentsOf: removeOwnedTemporaryItems(
            from: locations.temporaryDirectory,
            fileManager: fileManager
        ))
        return failures
    }

    static func ownedRoots(
        bundleIdentifier: String,
        locations: Locations
    ) -> [URL] {
        var roots: [URL] = []

        if let applicationSupportDirectory = locations.applicationSupportDirectory {
            roots.append(applicationSupportDirectory.appendingPathComponent("Sorty", isDirectory: true))
            roots.append(applicationSupportDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true))
        }

        if let cachesDirectory = locations.cachesDirectory {
            roots.append(cachesDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true))
            roots.append(cachesDirectory.appendingPathComponent("Sorty", isDirectory: true))
        }

        var seenPaths = Set<String>()
        return roots.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
    }

    private static func defaultLocations(fileManager: FileManager) -> Locations {
        Locations(
            applicationSupportDirectory: fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first,
            cachesDirectory: fileManager.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first,
            temporaryDirectory: fileManager.temporaryDirectory,
            appGroupContainer: fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: SortyWidgetSnapshotStore.appGroupIdentifier
            )
        )
    }

    private static func removeContents(
        of directory: URL,
        fileManager: FileManager
    ) -> [Error] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        do {
            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).compactMap { item in
                do {
                    try fileManager.removeItem(at: item)
                    return nil
                } catch {
                    return error
                }
            }
        } catch {
            return [error]
        }
    }

    private static func removeOwnedTemporaryItems(
        from directory: URL,
        fileManager: FileManager
    ) -> [Error] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        let prefixes = ["sorty-", "Sorty_", "SortyNotificationIcon-"]
        do {
            let items = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { item in
                prefixes.contains { item.lastPathComponent.hasPrefix($0) }
            }

            return items.compactMap { item in
                do {
                    try fileManager.removeItem(at: item)
                    return nil
                } catch {
                    return error
                }
            }
        } catch {
            return [error]
        }
    }
}
