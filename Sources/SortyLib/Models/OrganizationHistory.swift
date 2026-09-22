//
//  OrganizationHistory.swift
//  Sorty
//
//  Organization history and analytics with undo support
//

import Foundation
import Combine

public enum OrganizationStatus: String, Codable, Sendable {
    case completed
    case failed
    case cancelled
    case skipped // Superseded by "Try Another"
    case undo // Reverted
    case partiallyUndone // Partially reverted (some files could not be restored)
    case duplicatesCleanup // New: Duplicate removal session

    public var displayName: String {
        switch self {
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        case .undo: "Undo"
        case .partiallyUndone: "Partially Undone"
        case .duplicatesCleanup: "Duplicates Cleanup"
        }
    }
}

public enum OrganizationEntrySource: String, Codable, Sendable {
    case manual
    case watchedFolder
}

public enum DuplicateCleanupMode: String, Codable, Sendable {
    case safeDeletion
    case directDelete
    case trash
}

public struct OrganizationHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let directoryPath: String
    public let filesOrganized: Int
    public let foldersCreated: Int
    public let plan: OrganizationPlan?
    public let success: Bool // Legacy format, kept for decoding old entries
    public var status: OrganizationStatus // New detailed status
    public let errorMessage: String?
    public let rawAIResponse: String?
    public var operations: [FileSystemManager.FileOperation]?
    public var isUndone: Bool
    public var source: OrganizationEntrySource
    
    // Undo result tracking
    public var undoRestoredCount: Int?
    public var undoFailedFiles: [String]?
    
    // Duplicate Specific Fields
    public var duplicatesDeleted: Int?
    public var recoveredSpace: Int64?
    public var restorableItems: [RestorableDuplicate]?
    public var duplicateCleanupMode: DuplicateCleanupMode?
    public let storedPlanAvailable: Bool
    public let storedOperationCount: Int
    public let storedRestorableItemCount: Int
    public let storedEstimatedTimeSaved: TimeInterval?
    public let storedEstimatedCost: Decimal?
    public let storedGenerationModelName: String?
    public let storedHasBillableCost: Bool

    public var displayName: String {
        let directoryURL = URL(fileURLWithPath: directoryPath).standardizedFileURL
        let directoryName = directoryURL.lastPathComponent
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL

        if let generatedName = plan?.sessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !generatedName.isEmpty {
            return String(generatedName.prefix(60))
        }

        guard UUID(uuidString: directoryName) != nil,
              directoryURL.deletingLastPathComponent() == temporaryDirectory else {
            return directoryName.isEmpty ? directoryPath : directoryName
        }

        if let planName = planFallbackName {
            return planName
        }

        let identifier = String(id.uuidString.prefix(8))
        switch status {
        case .failed: return "Failed Organization \(identifier)"
        case .cancelled: return "Cancelled Organization \(identifier)"
        case .duplicatesCleanup: return "Duplicate Cleanup \(identifier)"
        case .skipped: return "Skipped Organization \(identifier)"
        case .undo: return "Undone Organization \(identifier)"
        case .partiallyUndone: return "Partially Undone \(identifier)"
        case .completed:
            return source == .watchedFolder
                ? "Watched Folder Run \(identifier)"
                : "Organization \(identifier)"
        }
    }

    private var planFallbackName: String? {
        guard let suggestions = plan?.suggestions else { return nil }
        let names = suggestions
            .lazy
            .map(\.folderName)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." }
            .prefix(2)
        guard !names.isEmpty else { return nil }

        let summary = names.joined(separator: " & ")
        return String("\(summary) Organization".prefix(60))
    }

    public var hasApplicablePlan: Bool {
        guard !success, storedPlanAvailable, status != .duplicatesCleanup else {
            return false
        }

        return storedOperationCount == 0
    }
    
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        directoryPath: String,
        filesOrganized: Int,
        foldersCreated: Int,
        plan: OrganizationPlan? = nil,
        success: Bool = true,
        status: OrganizationStatus? = nil,
        errorMessage: String? = nil,
        rawAIResponse: String? = nil,
        operations: [FileSystemManager.FileOperation]? = nil,
        isUndone: Bool = false,
        source: OrganizationEntrySource = .manual,
        undoRestoredCount: Int? = nil,
        undoFailedFiles: [String]? = nil,
        duplicatesDeleted: Int? = nil,
        recoveredSpace: Int64? = nil,
        restorableItems: [RestorableDuplicate]? = nil,
        duplicateCleanupMode: DuplicateCleanupMode? = nil,
        storedPlanAvailable: Bool? = nil,
        storedOperationCount: Int? = nil,
        storedRestorableItemCount: Int? = nil,
        storedEstimatedTimeSaved: TimeInterval? = nil,
        storedEstimatedCost: Decimal? = nil,
        storedGenerationModelName: String? = nil,
        storedHasBillableCost: Bool? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.directoryPath = directoryPath
        self.filesOrganized = filesOrganized
        self.foldersCreated = foldersCreated
        self.plan = plan
        self.success = success
        
        // Migrate legacy success boolean to status if status not provided
        if let providedStatus = status {
            self.status = providedStatus
        } else {
            if isUndone {
                 self.status = .undo
            } else if success {
                self.status = .completed
            } else {
                self.status = .failed
            }
        }
        
        self.errorMessage = errorMessage
        self.rawAIResponse = rawAIResponse
        self.operations = operations
        self.isUndone = isUndone
        self.source = source
        self.undoRestoredCount = undoRestoredCount
        self.undoFailedFiles = undoFailedFiles
        self.duplicatesDeleted = duplicatesDeleted
        self.recoveredSpace = recoveredSpace
        self.restorableItems = restorableItems
        self.duplicateCleanupMode = duplicateCleanupMode
        self.storedPlanAvailable = storedPlanAvailable ?? (plan != nil)
        self.storedOperationCount = storedOperationCount ?? operations?.count ?? 0
        self.storedRestorableItemCount = storedRestorableItemCount ?? restorableItems?.count ?? 0
        self.storedEstimatedTimeSaved = storedEstimatedTimeSaved
            ?? plan?.generationStats?.estimatedTimeSaved
        self.storedEstimatedCost = storedEstimatedCost
            ?? plan?.generationStats?.computedCost
        self.storedGenerationModelName = storedGenerationModelName
            ?? plan?.generationStats?.compactModelName
        self.storedHasBillableCost = storedHasBillableCost
            ?? plan?.generationStats?.hasBillableCost ?? false
    }
    
    // Custom decoding to handle migration from old format
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        directoryPath = try container.decode(String.self, forKey: .directoryPath)
        filesOrganized = try container.decode(Int.self, forKey: .filesOrganized)
        foldersCreated = try container.decode(Int.self, forKey: .foldersCreated)
        plan = try container.decodeIfPresent(OrganizationPlan.self, forKey: .plan)
        
        // Handle legacy 'success'
        let successVal = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        success = successVal
        
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        rawAIResponse = try container.decodeIfPresent(String.self, forKey: .rawAIResponse)
        operations = try container.decodeIfPresent([FileSystemManager.FileOperation].self, forKey: .operations)
        isUndone = try container.decodeIfPresent(Bool.self, forKey: .isUndone) ?? false
        source = try container.decodeIfPresent(OrganizationEntrySource.self, forKey: .source) ?? .manual
        undoRestoredCount = try container.decodeIfPresent(Int.self, forKey: .undoRestoredCount)
        undoFailedFiles = try container.decodeIfPresent([String].self, forKey: .undoFailedFiles)
        
        // Decode status if present, otherwise infer
        if let decodedStatus = try container.decodeIfPresent(OrganizationStatus.self, forKey: .status) {
            status = decodedStatus
        } else {
            // Infer
            if isUndone {
                status = .undo
            } else if successVal {
                status = .completed
            } else {
                status = .failed
            }
        }

        duplicatesDeleted = try container.decodeIfPresent(Int.self, forKey: .duplicatesDeleted)
        recoveredSpace = try container.decodeIfPresent(Int64.self, forKey: .recoveredSpace)
        restorableItems = try container.decodeIfPresent([RestorableDuplicate].self, forKey: .restorableItems)
        duplicateCleanupMode = try container.decodeIfPresent(DuplicateCleanupMode.self, forKey: .duplicateCleanupMode)
        storedPlanAvailable = try container.decodeIfPresent(Bool.self, forKey: .storedPlanAvailable)
            ?? (plan != nil)
        storedOperationCount = try container.decodeIfPresent(Int.self, forKey: .storedOperationCount)
            ?? operations?.count ?? 0
        storedRestorableItemCount = try container.decodeIfPresent(Int.self, forKey: .storedRestorableItemCount)
            ?? restorableItems?.count ?? 0
        storedEstimatedTimeSaved = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .storedEstimatedTimeSaved
        ) ?? plan?.generationStats?.estimatedTimeSaved
        storedEstimatedCost = try container.decodeIfPresent(
            Decimal.self,
            forKey: .storedEstimatedCost
        ) ?? plan?.generationStats?.computedCost
        storedGenerationModelName = try container.decodeIfPresent(
            String.self,
            forKey: .storedGenerationModelName
        ) ?? plan?.generationStats?.compactModelName
        storedHasBillableCost = try container.decodeIfPresent(
            Bool.self,
            forKey: .storedHasBillableCost
        ) ?? plan?.generationStats?.hasBillableCost ?? false
    }

    public var summary: OrganizationHistoryEntry {
        OrganizationHistoryEntry(
            id: id,
            timestamp: timestamp,
            directoryPath: directoryPath,
            filesOrganized: filesOrganized,
            foldersCreated: foldersCreated,
            success: success,
            status: status,
            errorMessage: errorMessage,
            isUndone: isUndone,
            source: source,
            undoRestoredCount: undoRestoredCount,
            duplicatesDeleted: duplicatesDeleted,
            recoveredSpace: recoveredSpace,
            duplicateCleanupMode: duplicateCleanupMode,
            storedPlanAvailable: storedPlanAvailable,
            storedOperationCount: storedOperationCount,
            storedRestorableItemCount: storedRestorableItemCount,
            storedEstimatedTimeSaved: storedEstimatedTimeSaved,
            storedEstimatedCost: storedEstimatedCost,
            storedGenerationModelName: storedGenerationModelName,
            storedHasBillableCost: storedHasBillableCost
        )
    }
}

private struct OrganizationHistorySnapshot: Codable {
    let schemaVersion: Int
    let entries: [OrganizationHistoryEntry]
}

private final class OrganizationHistoryRepository: @unchecked Sendable {
    static let legacyHistoryKey = "organizationHistory"
    static let fileName = "organization-history.json"
    static let backupFileName = "organization-history.json.bak"
    private static let detailsDirectoryName = "Sessions"
    private static let schemaVersion = 2
    private static let maximumEntryCount = 100

    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let storageDirectory: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults = .standard,
        storageDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.storageDirectory = storageDirectory ?? Self.defaultStorageDirectory(fileManager: fileManager)
    }

    var primaryFileURL: URL? {
        storageDirectory?.appendingPathComponent(Self.fileName)
    }

    var backupFileURL: URL? {
        storageDirectory?.appendingPathComponent(Self.backupFileName)
    }

    private var detailsDirectoryURL: URL? {
        storageDirectory?.appendingPathComponent(Self.detailsDirectoryName, isDirectory: true)
    }

    func loadEntries() -> [OrganizationHistoryEntry] {
        guard let primaryFileURL else {
            LogManager.shared.log(
                "History file store unavailable; using legacy UserDefaults fallback",
                level: .warning,
                category: "OrganizationHistory"
            )
            return loadLegacyEntries()
        }

        if fileManager.fileExists(atPath: primaryFileURL.path) {
            do {
                let entries = try readEntries(from: primaryFileURL)
                migrateDetailsIfNeeded(entries)
                return retainedEntries(entries).map(\.summary)
            } catch {
                LogManager.shared.log(
                    "Primary history store unreadable at \(primaryFileURL.path): \(error.localizedDescription)",
                    level: .warning,
                    category: "OrganizationHistory"
                )

                if let recoveredEntries = recoverFromBackup() {
                    migrateDetailsIfNeeded(recoveredEntries)
                    return retainedEntries(recoveredEntries).map(\.summary)
                }

                return []
            }
        }

        if let recoveredEntries = recoverFromBackup() {
            migrateDetailsIfNeeded(recoveredEntries)
            return retainedEntries(recoveredEntries).map(\.summary)
        }

        let legacyEntries = loadLegacyEntries()
        guard !legacyEntries.isEmpty else {
            return []
        }

        if saveEntries(legacyEntries) {
            userDefaults.removeObject(forKey: Self.legacyHistoryKey)
            LogManager.shared.log(
                "Migrated \(legacyEntries.count) history entr\(legacyEntries.count == 1 ? "y" : "ies") from UserDefaults to file store",
                category: "OrganizationHistory"
            )
        } else {
            LogManager.shared.log(
                "History migration fell back to UserDefaults because file storage could not be written",
                level: .warning,
                category: "OrganizationHistory"
            )
        }

        return retainedEntries(legacyEntries).map(\.summary)
    }

    @discardableResult
    func saveEntries(_ entries: [OrganizationHistoryEntry]) -> Bool {
        let entries = retainedEntries(entries)
        guard let primaryFileURL, let backupFileURL else {
            persistLegacyFallback(entries)
            return false
        }

        do {
            try ensureStorageDirectoryExists()
            try persistDetails(from: entries)
            try removeUnretainedDetails(retaining: Set(entries.map(\.id)))

            let snapshot = OrganizationHistorySnapshot(
                schemaVersion: Self.schemaVersion,
                entries: entries.map(\.summary)
            )
            let data = try encoder.encode(snapshot)
            let tempURL = primaryFileURL.deletingLastPathComponent()
                .appendingPathComponent(".\(Self.fileName).\(UUID().uuidString).tmp")

            do {
                try writeVerifiedTemp(data, to: tempURL)
                try replacePrimary(with: tempURL, at: primaryFileURL)
                try verifyFileSize(at: primaryFileURL, expectedByteCount: data.count)
                try mirrorBackup(from: primaryFileURL, to: backupFileURL)
                userDefaults.removeObject(forKey: Self.legacyHistoryKey)
                return true
            } catch {
                try? cleanupFileIfPresent(at: tempURL)
                if let recoveredEntries = recoverFromBackup() {
                    LogManager.shared.log(
                        "Recovered history store from backup after failed write; preserved \(recoveredEntries.count) entries",
                        level: .warning,
                        category: "OrganizationHistory"
                    )
                }
                throw error
            }
        } catch {
            LogManager.shared.log(
                "Failed to persist history file store, using UserDefaults fallback: \(error.localizedDescription)",
                level: .warning,
                category: "OrganizationHistory"
            )
            persistLegacyFallback(entries)
            return false
        }
    }

    func clear() {
        if let primaryFileURL {
            try? cleanupFileIfPresent(at: primaryFileURL)
        }
        if let backupFileURL {
            try? cleanupFileIfPresent(at: backupFileURL)
        }
        if let detailsDirectoryURL {
            try? cleanupFileIfPresent(at: detailsDirectoryURL)
        }
        userDefaults.removeObject(forKey: Self.legacyHistoryKey)
    }

    func loadDetails(for summary: OrganizationHistoryEntry) -> OrganizationHistoryEntry {
        guard let detailsDirectoryURL else { return summary }
        let fileURL = detailsDirectoryURL.appendingPathComponent("\(summary.id.uuidString).json")
        guard let data = try? Data(contentsOf: fileURL),
              var details = try? decoder.decode(OrganizationHistoryEntry.self, from: data) else {
            return summary
        }
        details.status = summary.status
        details.isUndone = summary.isUndone
        details.undoRestoredCount = summary.undoRestoredCount
        return details
    }

    private func migrateDetailsIfNeeded(_ entries: [OrganizationHistoryEntry]) {
        guard entries.contains(where: Self.hasDetails) else { return }
        _ = saveEntries(entries)
    }

    private func persistDetails(from entries: [OrganizationHistoryEntry]) throws {
        guard let detailsDirectoryURL else { return }
        try fileManager.createDirectory(at: detailsDirectoryURL, withIntermediateDirectories: true)
        for entry in entries where Self.hasDetails(entry) {
            let fileURL = detailsDirectoryURL.appendingPathComponent("\(entry.id.uuidString).json")
            let data = try encoder.encode(entry)
            try data.write(to: fileURL, options: .atomic)
        }
    }

    private func removeUnretainedDetails(retaining retainedIDs: Set<UUID>) throws {
        guard let detailsDirectoryURL,
              fileManager.fileExists(atPath: detailsDirectoryURL.path) else { return }
        for fileURL in try fileManager.contentsOfDirectory(
            at: detailsDirectoryURL,
            includingPropertiesForKeys: nil
        ) where fileURL.pathExtension == "json" {
            guard let id = UUID(uuidString: fileURL.deletingPathExtension().lastPathComponent),
                  !retainedIDs.contains(id) else { continue }
            try cleanupFileIfPresent(at: fileURL)
        }
    }

    private func retainedEntries(_ entries: [OrganizationHistoryEntry]) -> [OrganizationHistoryEntry] {
        Array(entries.sorted { $0.timestamp > $1.timestamp }.prefix(Self.maximumEntryCount))
    }

    private static func hasDetails(_ entry: OrganizationHistoryEntry) -> Bool {
        entry.plan != nil
            || entry.rawAIResponse != nil
            || entry.operations != nil
            || entry.undoFailedFiles != nil
            || entry.restorableItems != nil
    }

    private func loadLegacyEntries() -> [OrganizationHistoryEntry] {
        guard
            let data = userDefaults.data(forKey: Self.legacyHistoryKey),
            let decoded = try? decoder.decode([OrganizationHistoryEntry].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private func persistLegacyFallback(_ entries: [OrganizationHistoryEntry]) {
        guard let encoded = try? encoder.encode(entries) else {
            return
        }
        userDefaults.set(encoded, forKey: Self.legacyHistoryKey)
    }

    private func ensureStorageDirectoryExists() throws {
        guard let storageDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }

        if !fileManager.fileExists(atPath: storageDirectory.path) {
            try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        }
    }

    private func writeVerifiedTemp(_ data: Data, to tempURL: URL) throws {
        try cleanupFileIfPresent(at: tempURL)

        guard fileManager.createFile(atPath: tempURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let handle = try FileHandle(forWritingTo: tempURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        try verifyFileSize(at: tempURL, expectedByteCount: data.count)
    }

    private func verifyFileSize(at url: URL, expectedByteCount: Int) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue == expectedByteCount else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func replacePrimary(with tempURL: URL, at primaryFileURL: URL) throws {
        if fileManager.fileExists(atPath: primaryFileURL.path) {
            _ = try fileManager.replaceItemAt(
                primaryFileURL,
                withItemAt: tempURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: tempURL, to: primaryFileURL)
        }
    }

    private func mirrorBackup(from primaryFileURL: URL, to backupFileURL: URL) throws {
        let stagingURL = backupFileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(Self.backupFileName).\(UUID().uuidString).tmp")

        try cleanupFileIfPresent(at: stagingURL)
        try fileManager.copyItem(at: primaryFileURL, to: stagingURL)

        do {
            if fileManager.fileExists(atPath: backupFileURL.path) {
                _ = try fileManager.replaceItemAt(
                    backupFileURL,
                    withItemAt: stagingURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: stagingURL, to: backupFileURL)
            }
        } catch {
            try? cleanupFileIfPresent(at: stagingURL)
            throw error
        }
    }

    private func recoverFromBackup() -> [OrganizationHistoryEntry]? {
        guard let primaryFileURL, let backupFileURL,
              fileManager.fileExists(atPath: backupFileURL.path) else {
            return nil
        }

        do {
            let entries = try readEntries(from: backupFileURL)
            try ensureStorageDirectoryExists()

            let recoveryTempURL = primaryFileURL.deletingLastPathComponent()
                .appendingPathComponent(".\(Self.fileName).recovery.\(UUID().uuidString).tmp")
            try cleanupFileIfPresent(at: recoveryTempURL)
            try fileManager.copyItem(at: backupFileURL, to: recoveryTempURL)
            try replacePrimary(with: recoveryTempURL, at: primaryFileURL)

            LogManager.shared.log(
                "Recovered history store from backup at \(backupFileURL.path)",
                level: .warning,
                category: "OrganizationHistory"
            )
            return entries
        } catch {
            LogManager.shared.log(
                "Failed to recover history store from backup: \(error.localizedDescription)",
                level: .error,
                category: "OrganizationHistory"
            )
            return nil
        }
    }

    private func readEntries(from fileURL: URL) throws -> [OrganizationHistoryEntry] {
        let data = try Data(contentsOf: fileURL)

        if let snapshot = try? decoder.decode(OrganizationHistorySnapshot.self, from: data) {
            return snapshot.entries
        }

        return try decoder.decode([OrganizationHistoryEntry].self, from: data)
    }

    private func cleanupFileIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private static func defaultStorageDirectory(fileManager: FileManager) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Sorty/History", isDirectory: true)
    }
}

@MainActor
public class OrganizationHistory: ObservableObject {
    private static let maximumEntryCount = 100
    public struct ImportResult: Equatable, Sendable {
        public let added: Int
        public let updated: Int
        public let unchanged: Int
        public let omittedByRetentionLimit: Int

        public var changed: Int { added + updated }
    }

    @Published public private(set) var entries: [OrganizationHistoryEntry] = [] {
        didSet { revision &+= 1 }
    }

    /// Monotonic change counter for `entries`, used by views to cache derived
    /// snapshots (session records, impact summaries) across view rebuilds
    /// without comparing full entry arrays.
    public private(set) var revision: UInt64 = 0
    @Published public private(set) var hasLoadedPersistedState = false
    private let repository: OrganizationHistoryRepository
    private var loadTask: Task<[OrganizationHistoryEntry], Never>?
    private var persistenceTask: Task<Void, Never>?
    private var hasPendingChanges = false
    private var loadGeneration = 0
    private var detailCache: [UUID: OrganizationHistoryEntry] = [:]
    private var detailCacheOrder: [UUID] = []
    private let detailCacheLimit = 8
    
    public init(userDefaults: UserDefaults = .standard, storageDirectory: URL? = nil) {
        self.repository = OrganizationHistoryRepository(
            userDefaults: userDefaults,
            storageDirectory: storageDirectory
        )
        setupNotificationObservers()
    }

    /// Loads and decodes history away from the main actor, then publishes retained entries.
    /// Entries created during loading are merged before the first save.
    public func loadPersistedState() async {
        guard !hasLoadedPersistedState else { return }

        let generation = loadGeneration
        let task: Task<[OrganizationHistoryEntry], Never>
        if let loadTask {
            task = loadTask
        } else {
            let repository = repository
            let pendingPersistence = persistenceTask
            task = Task.detached(priority: .utility) {
                await pendingPersistence?.value
                return repository.loadEntries()
            }
            loadTask = task
        }

        let persistedEntries = await task.value
        guard !hasLoadedPersistedState, generation == loadGeneration else { return }

        var mergedByID = Dictionary(uniqueKeysWithValues: persistedEntries.map { ($0.id, $0) })
        for entry in entries {
            mergedByID[entry.id] = entry.summary
        }
        entries = Array(
            mergedByID.values
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(Self.maximumEntryCount)
        )
        hasLoadedPersistedState = true
        loadTask = nil

        if hasPendingChanges {
            hasPendingChanges = false
            saveHistory()
        }
    }
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addMainActorObserver(forName: .clearAllUsageData, object: nil, queue: .main) { [weak self] in
            self?.clearHistory()
        }
    }
    
    public func addEntry(_ entry: OrganizationHistoryEntry) {
        var cleanEntry = entry
        cleanEntry.isUndone = false // Enforce clean state for new entries
        entries.insert(cleanEntry.summary, at: 0)
        cacheDetails(cleanEntry)
        trimToRetentionLimit()
        saveHistory(details: [cleanEntry])
    }
    
    public func updateEntry(_ entry: OrganizationHistoryEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry.summary
            if Self.containsDetails(entry) {
                cacheDetails(entry)
            }
            saveHistory(details: Self.containsDetails(entry) ? [entry] : [])
        }
    }

    public func details(for entry: OrganizationHistoryEntry) async -> OrganizationHistoryEntry {
        if Self.containsDetails(entry) { return entry }
        if let cached = detailCache[entry.id] {
            touchCachedDetails(entry.id)
            return cached
        }
        let repository = repository
        let pendingPersistence = persistenceTask
        let details = await Task.detached(priority: .utility) {
            await pendingPersistence?.value
            return repository.loadDetails(for: entry)
        }.value
        cacheDetails(details)
        return details
    }
    
    public func clearHistory() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        hasLoadedPersistedState = true
        hasPendingChanges = false
        detailCache.removeAll()
        detailCacheOrder.removeAll()
        entries.removeAll()
        enqueuePersistence { repository in
            repository.clear()
        }
    }

    @discardableResult
    public func importEntries(_ importedEntries: [OrganizationHistoryEntry]) -> ImportResult {
        guard !importedEntries.isEmpty else {
            return ImportResult(added: 0, updated: 0, unchanged: 0, omittedByRetentionLimit: 0)
        }

        var mergedByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var added = 0
        var updated = 0
        var unchanged = 0

        for entry in importedEntries {
            if let existing = mergedByID[entry.id] {
                if existing == entry {
                    unchanged += 1
                    continue
                }
                updated += 1
            } else {
                added += 1
            }
            mergedByID[entry.id] = entry
            cacheDetails(entry)
        }

        let sorted = mergedByID.values.sorted { $0.timestamp > $1.timestamp }
        let retained = Array(sorted.prefix(Self.maximumEntryCount))
        let retainedIDs = Set(retained.map(\.id))
        detailCache = detailCache.filter { retainedIDs.contains($0.key) }
        detailCacheOrder.removeAll { !retainedIDs.contains($0) }
        entries = retained.map(\.summary)
        saveHistory(details: retained.filter(Self.containsDetails))
        return ImportResult(
            added: added,
            updated: updated,
            unchanged: unchanged,
            omittedByRetentionLimit: sorted.count - retained.count
        )
    }
    
    public var totalFilesOrganized: Int {
        entries.filter { $0.status == .completed }.reduce(0) { $0 + $1.filesOrganized }
    }
    
    public var totalFoldersCreated: Int {
        entries.filter { $0.status == .completed }.reduce(0) { $0 + $1.foldersCreated }
    }

    public var totalSessions: Int {
        entries.count
    }

    public var revertedCount: Int {
        entries.filter { $0.status == .undo || $0.status == .partiallyUndone || $0.isUndone }.count
    }
    
    public var successRate: Double {
        let completed = entries.filter { $0.status == .completed }.count
        let total = entries.count
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
    
    public var failedCount: Int {
        entries.filter { $0.status == .failed }.count
    }
    
    public var successCount: Int {
        entries.filter { $0.status == .completed }.count
    }

    public var totalRecoveredSpace: Int64 {
        entries.compactMap { $0.recoveredSpace }.reduce(0, +)
    }

    public var totalTimeSaved: TimeInterval {
        entries.filter { $0.status == .completed }
            .compactMap(\.storedEstimatedTimeSaved)
            .reduce(0, +)
    }

    public var totalEstimatedCost: Decimal {
        entries.compactMap(\.storedEstimatedCost)
            .reduce(0, +)
    }

    private static func containsDetails(_ entry: OrganizationHistoryEntry) -> Bool {
        entry.plan != nil
            || entry.rawAIResponse != nil
            || entry.operations != nil
            || entry.undoFailedFiles != nil
            || entry.restorableItems != nil
    }

    private func cacheDetails(_ entry: OrganizationHistoryEntry) {
        guard Self.containsDetails(entry) else { return }
        detailCache[entry.id] = entry
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        }
        touchCachedDetails(entry.id)
        while detailCacheOrder.count > detailCacheLimit, let oldest = detailCacheOrder.first {
            detailCacheOrder.removeFirst()
            detailCache.removeValue(forKey: oldest)
            if let index = entries.firstIndex(where: { $0.id == oldest }) {
                entries[index] = entries[index].summary
            }
        }
    }

    private func touchCachedDetails(_ id: UUID) {
        detailCacheOrder.removeAll { $0 == id }
        detailCacheOrder.append(id)
    }

    private func trimToRetentionLimit() {
        guard entries.count > Self.maximumEntryCount else { return }
        let removedIDs = Set(entries.dropFirst(Self.maximumEntryCount).map(\.id))
        entries.removeLast(entries.count - Self.maximumEntryCount)
        detailCache = detailCache.filter { !removedIDs.contains($0.key) }
        detailCacheOrder.removeAll { removedIDs.contains($0) }
    }

    private func saveHistory(details: [OrganizationHistoryEntry] = []) {
        guard hasLoadedPersistedState else {
            hasPendingChanges = true
            return
        }
        var detailsByID = detailCache
        for entry in details {
            detailsByID[entry.id] = entry
        }
        let snapshot = entries.map { detailsByID.removeValue(forKey: $0.id) ?? $0 }
        enqueuePersistence { repository in
            _ = repository.saveEntries(snapshot)
        }
    }

    /// Queues disk work behind earlier history operations without blocking the main actor.
    private func enqueuePersistence(
        _ operation: @escaping @Sendable (OrganizationHistoryRepository) -> Void
    ) {
        let previousTask = persistenceTask
        let repository = repository
        persistenceTask = Task.detached(priority: .utility) {
            await previousTask?.value
            guard !Task.isCancelled else { return }
            operation(repository)
        }
    }

    func waitForPendingPersistence() async {
        await persistenceTask?.value
    }

    public nonisolated static func loadPersistedEntries(
        userDefaults: UserDefaults = .standard,
        storageDirectory: URL? = nil
    ) -> [OrganizationHistoryEntry] {
        OrganizationHistoryRepository(
            userDefaults: userDefaults,
            storageDirectory: storageDirectory
        ).loadEntries()
    }

    var storageFileURL: URL? {
        repository.primaryFileURL
    }

    var backupStorageFileURL: URL? {
        repository.backupFileURL
    }
}



/// Represents a duplicate file that has been safely deleted and can be restored
public struct RestorableDuplicate: Codable, Identifiable, Sendable, Hashable, Equatable {
    public let id: UUID
    public let originalPath: String
    public let deletedPath: String
    public let trashPath: String?
    public let deletedDate: Date
    public let metadata: FileMetadata
    
    public struct FileMetadata: Codable, Sendable, Hashable, Equatable {
        public let creationDate: Date?
        public let modificationDate: Date?
        public let permissions: Int?
        public let ownerAccountID: Int?
        public let groupOwnerAccountID: Int?
    }
    
    public init(
        id: UUID = UUID(),
        originalPath: String,
        deletedPath: String,
        trashPath: String? = nil,
        deletedDate: Date = Date(),
        metadata: FileMetadata
    ) {
        self.id = id
        self.originalPath = originalPath
        self.deletedPath = deletedPath
        self.trashPath = trashPath
        self.deletedDate = deletedDate
        self.metadata = metadata
    }
}
