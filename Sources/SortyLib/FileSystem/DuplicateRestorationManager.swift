import Foundation
import Combine
import Darwin

// MARK: - Duplicate Restoration Manager

/// Tracks duplicate files moved to Trash so History can restore them while they remain there.
@MainActor
public class DuplicateRestorationManager: ObservableObject {
    @Published public private(set) var restoredItems: [RestorableDuplicate] = []

    static var trashItemForTesting: ((URL) throws -> URL?)?

    private let fileManager = FileManager.default
    private let persistenceKey = "DuplicateRestorationHistory"

    public static let shared = DuplicateRestorationManager()

    private init() {
        loadHistory()
    }

    /// Moves duplicate files to macOS Trash and records their resulting locations for undo.
    public func moveToTrash(files: [FileItem]) throws -> [RestorableDuplicate] {
        var deletedItems: [RestorableDuplicate] = []

        for file in files {
            let attributes = try? fileManager.attributesOfItem(atPath: file.path)
            let metadata = RestorableDuplicate.FileMetadata(
                creationDate: attributes?[.creationDate] as? Date,
                modificationDate: attributes?[.modificationDate] as? Date,
                permissions: attributes?[.posixPermissions] as? Int,
                ownerAccountID: attributes?[.ownerAccountID] as? Int,
                groupOwnerAccountID: attributes?[.groupOwnerAccountID] as? Int
            )

            let sourceURL = URL(fileURLWithPath: file.path)
            let resultingTrashURL: URL?
            if let trashItemForTesting = Self.trashItemForTesting {
                resultingTrashURL = try trashItemForTesting(sourceURL)
            } else {
                var trashURL: NSURL?
                try fileManager.trashItem(at: sourceURL, resultingItemURL: &trashURL)
                resultingTrashURL = trashURL as URL?
            }

            let item = RestorableDuplicate(
                originalPath: file.path,
                deletedPath: file.path,
                trashPath: resultingTrashURL?.path,
                metadata: metadata
            )
            deletedItems.append(item)
            restoredItems.append(item)
            saveHistory()
        }

        return deletedItems
    }

    public func canRestore(item: RestorableDuplicate) -> Bool {
        if let trashPath = item.trashPath {
            return fileManager.fileExists(atPath: trashPath)
                && !fileManager.fileExists(atPath: item.deletedPath)
        }

        return fileManager.fileExists(atPath: item.originalPath)
            && !fileManager.fileExists(atPath: item.deletedPath)
    }

    /// Restore a previously deleted duplicate
    public func restore(item: RestorableDuplicate) throws {
        if fileManager.fileExists(atPath: item.deletedPath) {
            throw RestorationError.targetLocationOccupied
        }

        if let trashPath = item.trashPath {
            guard fileManager.fileExists(atPath: trashPath) else {
                throw RestorationError.trashedFileNotFound
            }
            try fileManager.moveItem(atPath: trashPath, toPath: item.deletedPath)
        } else {
            // Legacy entries used the surviving duplicate as the restore source.
            guard fileManager.fileExists(atPath: item.originalPath) else {
                throw RestorationError.originalFileNotFound
            }
            try fileManager.copyItem(atPath: item.originalPath, toPath: item.deletedPath)
        }

        var attributes: [FileAttributeKey: Any] = [:]
        if let creation = item.metadata.creationDate { attributes[.creationDate] = creation }
        if let modification = item.metadata.modificationDate { attributes[.modificationDate] = modification }
        if let perms = item.metadata.permissions { attributes[.posixPermissions] = perms }
        if let owner = item.metadata.ownerAccountID { attributes[.ownerAccountID] = owner }
        if let group = item.metadata.groupOwnerAccountID { attributes[.groupOwnerAccountID] = group }

        try fileManager.setAttributes(attributes, ofItemAtPath: item.deletedPath)

        if let index = restoredItems.firstIndex(where: { $0.id == item.id }) {
            restoredItems.remove(at: index)
            saveHistory()
        }
    }

    /// Delete all stored history data
    public func clearAllData() {
        historySaveTask?.cancel()
        historySaveTask = nil
        historyGeneration &+= 1
        restoredItems.removeAll()
        try? fileManager.removeItem(at: Self.historyFileURL)
        UserDefaults.standard.removeObject(forKey: persistenceKey)
    }

    private func loadHistory() {
        if let data = try? Data(contentsOf: Self.historyFileURL),
           let decoded = try? JSONDecoder().decode([RestorableDuplicate].self, from: data) {
            restoredItems = decoded
            return
        }
        // Legacy UserDefaults payload: adopt once, then persist to file.
        if let data = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode([RestorableDuplicate].self, from: data) {
            restoredItems = decoded
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            saveHistory()
        }
    }

    private var historySaveTask: Task<Void, Never>?
    private var historyWriteTask: Task<Void, Never>?
    private var historyGeneration = 0

    /// Coalesced file write: per-item moveToTrash loops collapse into a
    /// single encode + atomic write on a worker. In-memory state updates
    /// stay synchronous on main; only the encode/write moves off-main.
    /// Writes are chained so rapid saves land in order.
    private func saveHistory() {
        historySaveTask?.cancel()
        let generation = historyGeneration
        historySaveTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, generation == historyGeneration else { return }
            let snapshot = restoredItems
            let previousWrite = historyWriteTask
            let write = Task.detached(priority: .utility) {
                await previousWrite?.value
                guard !Task.isCancelled else { return }
                Self.writeHistoryFile(snapshot)
            }
            historyWriteTask = write
            await write.value
        }
    }

    private nonisolated static var historyFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Sorty/DuplicateRestorationHistory.json")
    }

    private nonisolated static func writeHistoryFile(_ items: [RestorableDuplicate]) {
        let fileURL = historyFileURL
        do {
            let encoded = try JSONEncoder().encode(items)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            LogManager.shared.log(
                "Failed to save duplicate restoration history: \(error.localizedDescription)",
                level: .error,
                category: "DuplicateRestoration"
            )
        }
    }

    enum RestorationError: LocalizedError {
        case originalFileNotFound
        case trashedFileNotFound
        case targetLocationOccupied

        var errorDescription: String? {
            switch self {
            case .originalFileNotFound:
                return "The original file copy could not be found. It may have been moved or deleted."
            case .trashedFileNotFound:
                return "The file is no longer in Trash and cannot be restored."
            case .targetLocationOccupied:
                return "A file already exists at the restoration location."
            }
        }
    }
}

extension URL {
    var finderComment: String? {
        let path = path
        let key = "com.apple.metadata:kMDItemFinderComment"

        let size = getxattr(path, key, nil, 0, 0, 0)
        guard size > 0 else { return nil }

        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { buf in
            getxattr(path, key, buf.baseAddress, size, 0, 0)
        }
        guard result > 0 else { return nil }

        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? String
    }
}
