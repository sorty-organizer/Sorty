import Foundation
import Combine
import Darwin

// MARK: - Duplicate Restoration Manager

struct PartialTrashFailure: LocalizedError {
    let underlyingError: Error
    let movedItems: [RestorableDuplicate]

    var errorDescription: String? {
        "Some duplicate files were moved to Trash before cleanup failed: \(underlyingError.localizedDescription)"
    }
}

/// Raised when a file no longer matches the scan that selected it. Trashing it
/// would delete content the user never reviewed, so cleanup stops instead.
struct StaleDuplicateError: LocalizedError {
    enum Reason {
        case missing
        case notRegularFile
        case sizeChanged
        case modificationDateChanged
        case identityChanged
    }

    let path: String
    let reason: Reason

    var errorDescription: String? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        switch reason {
        case .missing:
            return "\(name) was moved or deleted after the scan. Rescan for duplicates before cleaning up."
        case .notRegularFile:
            return "\(name) is no longer a regular file. Rescan for duplicates before cleaning up."
        case .sizeChanged:
            return "\(name) changed size after the scan. Rescan for duplicates before cleaning up."
        case .modificationDateChanged:
            return "\(name) changed after the scan. Rescan for duplicates before cleaning up."
        case .identityChanged:
            return "\(name) was replaced after the scan. Rescan for duplicates before cleaning up."
        }
    }
}

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
    ///
    /// Each path is re-checked against the metadata captured during the scan
    /// before trashing, so a file that was replaced or edited after the scan is
    /// never removed as a duplicate. Stops at the first mismatch; already
    /// completed moves are reported as a `PartialTrashFailure`.
    public func moveToTrash(files: [FileItem]) throws -> [RestorableDuplicate] {
        var deletedItems: [RestorableDuplicate] = []

        for file in files {
            do {
                try Self.validateUnchanged(file)
                let metadata = Self.captureMetadata(for: file)

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
            } catch {
                guard !deletedItems.isEmpty else { throw error }
                // This is an exceptional path: make the completed moves durable
                // before reporting the later failure to the caller.
                Self.writeHistoryFile(restoredItems)
                throw PartialTrashFailure(underlyingError: error, movedItems: deletedItems)
            }
        }

        return deletedItems
    }

    /// Async cleanup path used by the duplicates UI: the filesystem moves run
    /// on a detached task and the restore history is applied on the main actor,
    /// so bulk trashing never blocks the UI. The synchronous `moveToTrash`
    /// remains for callers (and tests) that need an immediate result.
    public func moveToTrashAsync(files: [FileItem]) async throws -> [RestorableDuplicate] {
        // The test override is a main-actor closure that cannot cross into a
        // detached task, so use the synchronous path (which honors it) while
        // an override is installed.
        if Self.trashItemForTesting != nil {
            return try moveToTrash(files: files)
        }

        let outcome = await Task.detached(priority: .userInitiated) {
            DuplicateRestorationManager.performTrashBatch(files: files)
        }.value

        switch outcome {
        case .success(let movedItems):
            restoredItems.append(contentsOf: movedItems)
            if !movedItems.isEmpty {
                saveHistory()
            }
            return movedItems
        case .partial(let movedItems, let failure):
            restoredItems.append(contentsOf: movedItems)
            // Keep the completed moves durable before reporting the failure,
            // but encode and write on a worker instead of the main actor.
            await writeHistoryIfCurrent(restoredItems, generation: historyGeneration)
            throw PartialTrashFailure(underlyingError: failure.underlyingError, movedItems: movedItems)
        case .failure(let failure):
            throw failure.underlyingError
        }
    }

    // MARK: - Trash Validation and Background Work

    /// Re-checks a scanned file against the filesystem. A size or modification
    /// date that no longer matches the scan means the file was replaced or
    /// edited, so it must not be trashed as the duplicate the user reviewed.
    nonisolated static func validateUnchanged(_ file: FileItem) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else {
            throw StaleDuplicateError(path: file.path, reason: .missing)
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw StaleDuplicateError(path: file.path, reason: .notRegularFile)
        }
        if let scannedIdentity = file.fileSystemIdentity,
           FileItem.currentFileSystemIdentity(at: file.path) != scannedIdentity {
            throw StaleDuplicateError(path: file.path, reason: .identityChanged)
        }
        if let size = (attributes[.size] as? NSNumber)?.int64Value, size != file.size {
            throw StaleDuplicateError(path: file.path, reason: .sizeChanged)
        }
        if let modificationDate = file.modificationDate,
           let currentModificationDate = attributes[.modificationDate] as? Date,
           abs(currentModificationDate.timeIntervalSince(modificationDate)) > 0.5 {
            throw StaleDuplicateError(path: file.path, reason: .modificationDateChanged)
        }
    }

    nonisolated static func captureMetadata(
        for file: FileItem
    ) -> RestorableDuplicate.FileMetadata {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        return RestorableDuplicate.FileMetadata(
            creationDate: attributes?[.creationDate] as? Date,
            modificationDate: attributes?[.modificationDate] as? Date,
            permissions: attributes?[.posixPermissions] as? Int,
            ownerAccountID: attributes?[.ownerAccountID] as? Int,
            groupOwnerAccountID: attributes?[.groupOwnerAccountID] as? Int
        )
    }

    private nonisolated static func performTrashBatch(files: [FileItem]) -> TrashBatchOutcome {
        var movedItems: [RestorableDuplicate] = []
        for file in files {
            do {
                movedItems.append(try trashForBackground(file))
            } catch {
                let failure = TrashFailureInfo(error)
                return movedItems.isEmpty
                    ? .failure(failure)
                    : .partial(movedItems: movedItems, failure: failure)
            }
        }
        return .success(movedItems)
    }

    /// Runs on a detached task, so it uses FileManager directly and never
    /// touches the main-actor test override or observable state.
    nonisolated static func trashForBackground(_ file: FileItem) throws -> RestorableDuplicate {
        try validateUnchanged(file)
        let metadata = captureMetadata(for: file)
        let sourceURL = URL(fileURLWithPath: file.path)
        var trashURL: NSURL?
        try FileManager.default.trashItem(at: sourceURL, resultingItemURL: &trashURL)
        return RestorableDuplicate(
            originalPath: file.path,
            deletedPath: file.path,
            trashPath: (trashURL as URL?)?.path,
            metadata: metadata
        )
    }

    /// Sendable failure payload so errors can cross the detached-task boundary
    /// and be rethrown on the main actor.
    private struct TrashFailureInfo: Sendable {
        let domain: String
        let code: Int
        let message: String

        init(_ error: Error) {
            let nsError = error as NSError
            domain = nsError.domain
            code = nsError.code
            message = nsError.localizedDescription
        }

        var underlyingError: NSError {
            NSError(
                domain: domain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private enum TrashBatchOutcome: Sendable {
        case success([RestorableDuplicate])
        case partial(movedItems: [RestorableDuplicate], failure: TrashFailureInfo)
        case failure(TrashFailureInfo)
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
        historyWriteTask?.cancel()
        historyWriteTask = nil
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
            let write = Task.detached(priority: .utility) { [weak self] in
                await previousWrite?.value
                guard !Task.isCancelled, let self else { return }
                await self.writeHistoryIfCurrent(snapshot, generation: generation)
            }
            historyWriteTask = write
            await write.value
        }
    }

    /// Encodes and writes the history on a worker, but only while `generation`
    /// is still current. The generation is re-checked on the main actor
    /// immediately before writing, so a clear that lands while a write was
    /// already queued cannot have that write recreate the history.
    private nonisolated func writeHistoryIfCurrent(
        _ items: [RestorableDuplicate],
        generation: Int
    ) async {
        let isCurrent = await MainActor.run { [weak self] in
            self?.historyGeneration == generation
        }
        guard isCurrent else { return }
        Self.writeHistoryFile(items)
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
