//
//  FileSystemManager.swift
//  Sorty
//
//  Safe file operations with undo tracking, conflict handling, and improved revert support
//  Fixed: History revert now properly handles all operations and prevents re-organization
//

import Foundation
import Combine
import Darwin

public actor FileSystemManager {
    private let fileManager = FileManager.default
    private var activeBookmarks: [URL: Int] = [:]

    // Track files that are currently being reverted to prevent re-organization
    private var revertingPaths: Set<String> = []

    // MARK: - Cross-Volume Move Optimization

    private var crossVolumeProgressHandler: (@Sendable (String, Double) -> Void)?
    #if DEBUG
    private var crossVolumeDetectorOverride: (@Sendable (URL, URL) -> Bool)?
    private var availableCapacityOverride: (@Sendable (URL) -> Int64?)?
    #endif

    private static let crossVolumeChunkSize: Int = 1_024 * 1_024 * 4 // 4 MB
    private static let largeFileThreshold: UInt64 = 50 * 1_024 * 1_024 // 50 MB
    /// Upper bound for collision-uniquify attempts. Prevents an unbounded
    /// `while fileExists` loop when a directory is densely populated.
    static let maximumUniqueNameAttempts = 1_000
    /// Retries for a lost check-then-act race (destination appeared between
    /// our existence check and the move).
    private static let conflictingMoveRetryAttempts = 3

    private struct TransferSnapshot: Equatable {
        let itemCount: Int
        let totalBytes: UInt64
        let latestModificationDate: Date?

        func matchesCopiedContent(_ other: TransferSnapshot) -> Bool {
            itemCount == other.itemCount && totalBytes == other.totalBytes
        }
    }

    private func transferSnapshot(at url: URL) throws -> TransferSnapshot {
        let rootValues = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        guard rootValues.isDirectory == true else {
            return TransferSnapshot(
                itemCount: 1,
                totalBytes: UInt64(max(rootValues.fileSize ?? 0, 0)),
                latestModificationDate: rootValues.contentModificationDate
            )
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw FileSystemError.crossVolumeCopyVerificationFailed(url.path)
        }

        var itemCount = 1
        var totalBytes: UInt64 = 0
        var latestModificationDate = rootValues.contentModificationDate
        for case let itemURL as URL in enumerator {
            try Task.checkCancellation()
            let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            // Never follow symlinks while snapshotting: directory cycles
            // would loop forever and escaping links would inflate the totals.
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            itemCount += 1
            if values.isDirectory != true {
                totalBytes += UInt64(max(values.fileSize ?? 0, 0))
            }
            if let date = values.contentModificationDate,
               latestModificationDate == nil || date > latestModificationDate! {
                latestModificationDate = date
            }
        }
        return TransferSnapshot(
            itemCount: itemCount,
            totalBytes: totalBytes,
            latestModificationDate: latestModificationDate
        )
    }

    public func setCrossVolumeProgressHandler(_ handler: (@Sendable (String, Double) -> Void)?) {
        crossVolumeProgressHandler = handler
    }

    #if DEBUG
    func setCrossVolumeDetectorForTesting(_ detector: (@Sendable (URL, URL) -> Bool)?) {
        crossVolumeDetectorOverride = detector
    }

    func setAvailableCapacityForTesting(_ provider: (@Sendable (URL) -> Int64?)?) {
        availableCapacityOverride = provider
    }
    #endif

    private func isCrossVolume(from source: URL, to destination: URL) -> Bool {
        #if DEBUG
        if let crossVolumeDetectorOverride {
            return crossVolumeDetectorOverride(source, destination)
        }
        #endif

        let sourceValues = try? source.resourceValues(forKeys: [.volumeIdentifierKey])
        // The destination may not exist yet, so walk up to the nearest
        // existing ancestor for a meaningful destination volume.
        var probe = destination.deletingLastPathComponent()
        var destValues: URLResourceValues?
        while destValues == nil {
            if fileManager.fileExists(atPath: probe.path) {
                destValues = try? probe.resourceValues(forKeys: [.volumeIdentifierKey])
                break
            }
            let parent = probe.deletingLastPathComponent()
            guard parent.path != probe.path else { break }
            probe = parent
        }

        guard let sourceVolume = sourceValues?.volumeIdentifier as? NSObject,
              let destVolume = destValues?.volumeIdentifier as? NSObject else {
            // Volume identity unknown: take the safe copy-then-verify path
            // rather than assuming a same-volume rename will work.
            return true
        }

        return !sourceVolume.isEqual(destVolume)
    }

    /// Maps a filesystem write failure to a storage-specific error when the
    /// underlying cause is disk-full, read-only media, or quota — instead of
    /// mislabeling all of them `permissionDenied`. Preserves errno and path.
    private func storageError(for error: Error, path: String) -> FileSystemError? {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            switch Int32(nsError.code) {
            case ENOSPC:
                return .diskFull(path: path, underlyingErrno: ENOSPC)
            case EROFS:
                return .readOnlyFileSystem(path: path, underlyingErrno: EROFS)
            case EDQUOT:
                return .quotaExceeded(path: path, underlyingErrno: EDQUOT)
            default:
                break
            }
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteOutOfSpaceError:
                return .diskFull(path: path, underlyingErrno: ENOSPC)
            case NSFileWriteVolumeReadOnlyError:
                return .readOnlyFileSystem(path: path, underlyingErrno: EROFS)
            default:
                break
            }
        }
        // FileHandle writes surface the raw errno value.
        if (error as? POSIXError)?.code == .ENOSPC {
            return .diskFull(path: path, underlyingErrno: ENOSPC)
        }
        return nil
    }

    /// The errno captured right after a failed `createFile`, mapped the same way.
    private func storageErrorForCurrentErrno(path: String) -> FileSystemError? {
        switch errno {
        case ENOSPC:
            return .diskFull(path: path, underlyingErrno: ENOSPC)
        case EROFS:
            return .readOnlyFileSystem(path: path, underlyingErrno: EROFS)
        case EDQUOT:
            return .quotaExceeded(path: path, underlyingErrno: EDQUOT)
        default:
            return nil
        }
    }

    private func isFileExistsError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteFileExistsError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EEXIST) {
            return true
        }
        return false
    }

    private func copyWithProgress(from source: URL, to destination: URL, progressHandler: (@Sendable (Double) -> Void)?) async throws {
        let sourceAttributes = try fileManager.attributesOfItem(atPath: source.path)
        let fileSize = (sourceAttributes[.size] as? UInt64) ?? 0
        let sourceSnapshot = try transferSnapshot(at: source)
        let stagingURL = destination.deletingLastPathComponent().appendingPathComponent(
            ".sorty-transfer-\(UUID().uuidString)-\(destination.lastPathComponent)"
        )

        // Staging lives next to the destination (same volume), so the final
        // staging->destination move is atomic and a mid-copy ENOSPC only ever
        // leaves a hidden partial file that this defer removes.
        defer {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        if fileSize > Self.largeFileThreshold {
            guard let readHandle = FileHandle(forReadingAtPath: source.path) else {
                throw FileSystemError.fileNotFound(path: source.path, underlyingErrno: errno)
            }

            guard fileManager.createFile(atPath: stagingURL.path, contents: nil),
                  let writeHandle = FileHandle(forWritingAtPath: stagingURL.path) else {
                try? readHandle.close()
                throw storageErrorForCurrentErrno(path: stagingURL.path) ?? FileSystemError.permissionDenied(path: stagingURL.path, underlyingErrno: errno)
            }

            do {
                var bytesWritten: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    let chunk = try readHandle.read(upToCount: Self.crossVolumeChunkSize) ?? Data()
                    if chunk.isEmpty { break }
                    try writeHandle.write(contentsOf: chunk)
                    bytesWritten += UInt64(chunk.count)
                    let progress = Double(bytesWritten) / Double(fileSize)
                    progressHandler?(min(progress, 1.0))
                }
                try writeHandle.synchronize()
                try writeHandle.close()
                try readHandle.close()
                guard copyfile(
                    source.path,
                    stagingURL.path,
                    nil,
                    copyfile_flags_t(COPYFILE_METADATA)
                ) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } catch {
                try? writeHandle.close()
                try? readHandle.close()
                // Partial staging content is removed by the defer above.
                throw storageError(for: error, path: stagingURL.path) ?? error
            }
        } else {
            try Task.checkCancellation()
            do {
                try fileManager.copyItem(at: source, to: stagingURL)
            } catch {
                throw storageError(for: error, path: stagingURL.path) ?? error
            }
            progressHandler?(1.0)
        }

        try Task.checkCancellation()
        let currentSourceSnapshot = try transferSnapshot(at: source)
        let destinationSnapshot = try transferSnapshot(at: stagingURL)
        guard currentSourceSnapshot == sourceSnapshot,
              sourceSnapshot.matchesCopiedContent(destinationSnapshot) else {
            throw FileSystemError.crossVolumeCopyVerificationFailed(source.path)
        }
        // Extra size check so a truncated staging copy can never replace the
        // source. Directory metadata sizes vary by volume, so single files
        // compare raw sizes while directories rely on the snapshot byte totals.
        if sourceSnapshot.itemCount <= 1 {
            let stagedSize = (try? fileManager.attributesOfItem(atPath: stagingURL.path)[.size] as? UInt64) ?? UInt64.max
            guard stagedSize == fileSize else {
                throw FileSystemError.crossVolumeCopyVerificationFailed(source.path)
            }
        }

        do {
            try fileManager.moveItem(at: stagingURL, to: destination)
        } catch {
            // Lost the arrival race: let the caller uniquify and retry.
            if isFileExistsError(error) {
                throw CocoaError(.fileWriteFileExists)
            }
            throw storageError(for: error, path: destination.path) ?? error
        }
        // Only delete the source after the destination is verified on disk.
        guard fileManager.fileExists(atPath: destination.path) else {
            throw FileSystemError.crossVolumeCopyVerificationFailed(source.path)
        }
        do {
            try fileManager.removeItem(at: source)
        } catch {
            // Copy succeeded but the source survives: surface the failure so
            // the caller records a partial apply instead of claiming success.
            throw FileSystemError.partialApplyFailure(
                operations: [],
                underlyingDescription: "Copied to \(destination.path) but could not remove source \(source.path): \(error.localizedDescription)"
            )
        }
    }

    /// Start accessing a security-scoped resource and track it
    private func startAccessing(_ url: URL) -> Bool {
        if url.startAccessingSecurityScopedResource() {
            activeBookmarks[url, default: 0] += 1
            return true
        }
        return false
    }

    /// Resolve folder destinations, including absolute storage locations.
    private func resolveDestinationFolderURL(
        folderName: String,
        parentURL: URL,
        requestSecurityScope: Bool = true
    ) throws -> URL {
        if let absoluteURL = StorageLocationPathResolver.absoluteURL(from: folderName) {
            let resolvedURL = URL(fileURLWithPath: StorageLocationPathResolver.resolvedPath(absoluteURL.path), isDirectory: true)
            if requestSecurityScope {
                _ = startAccessing(resolvedURL)
            }
            return resolvedURL
        }

        let sanitizedName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let directURL = parentURL.appendingPathComponent(sanitizedName, isDirectory: true)

        // If exact path exists as a directory, use it
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: directURL.path, isDirectory: &isDir) && isDir.boolValue {
            try validateRelativeDestination(directURL, staysInside: parentURL)
            return directURL
        }

        // Fuzzy match: find existing directory with similar name (ignoring spaces/case)
        if let matchURL = findSimilarDirectory(named: sanitizedName, in: parentURL) {
            DebugLogger.log("Fuzzy matched folder '\(sanitizedName)' → existing '\(matchURL.lastPathComponent)'")
            try validateRelativeDestination(matchURL, staysInside: parentURL)
            return matchURL
        }

        try validateRelativeDestination(directURL, staysInside: parentURL)
        return directURL
    }

    private func validateRelativeDestination(_ destinationURL: URL, staysInside parentURL: URL) throws {
        let parentPath = parentURL.resolvingSymlinksInPath().standardizedFileURL.path
        let destinationPath = destinationURL.resolvingSymlinksInPath().standardizedFileURL.path

        guard destinationPath == parentPath || destinationPath.hasPrefix(parentPath + "/") else {
            throw FileSystemError.destinationEscapesBaseDirectory(destinationURL.path)
        }
    }

    private func findSimilarDirectory(named name: String, in parentURL: URL) -> URL? {
        let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !normalized.isEmpty else { return nil }

        guard let items = try? fileManager.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var fuzzyMatch: URL?
        for item in items {
            guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else { continue }

            // Prefer the existing directory's exact on-disk name: the scan
            // folds separators/case/unicode when comparing, but the move path
            // must reuse the real name verbatim instead of creating a
            // near-duplicate folder.
            if item.lastPathComponent == name {
                return item
            }
            if fuzzyMatch == nil {
                let itemNormalized = item.lastPathComponent.lowercased().filter { $0.isLetter || $0.isNumber }
                if itemNormalized == normalized {
                    fuzzyMatch = item
                }
            }
        }

        return fuzzyMatch
    }

    /// Stop accessing all tracked security-scoped resources
    private func stopAccessingAll() {
        for (url, accessCount) in activeBookmarks {
            for _ in 0..<accessCount {
                url.stopAccessingSecurityScopedResource()
            }
        }
        activeBookmarks.removeAll()
    }

    public struct FileOperation: Codable, Hashable, Sendable {
        public let id: UUID
        public let type: OperationType
        public let sourcePath: String
        public let destinationPath: String?
        public let timestamp: Date
        public let metadata: OperationMetadata?

        public enum OperationType: String, Codable, Sendable {
            case createFolder
            case moveFile
            case renameFile
            case deleteFile
            case copyFile
            case tagFile
        }

        public struct OperationMetadata: Codable, Hashable, Sendable {
            public var originalFilename: String?
            public var newFilename: String?
            public var wasCreatedDuringOrganization: Bool
            public var parentFolderPath: String?
            public var originalTags: [String]?
            public var newTags: [String]?
            public var originalComment: String?
            public var newComment: String?

            public init(
                originalFilename: String? = nil,
                newFilename: String? = nil,
                wasCreatedDuringOrganization: Bool = false,
                parentFolderPath: String? = nil,
                originalTags: [String]? = nil,
                newTags: [String]? = nil,
                originalComment: String? = nil,
                newComment: String? = nil
            ) {
                self.originalFilename = originalFilename
                self.newFilename = newFilename
                self.wasCreatedDuringOrganization = wasCreatedDuringOrganization
                self.parentFolderPath = parentFolderPath
                self.originalTags = originalTags
                self.newTags = newTags
                self.originalComment = originalComment
                self.newComment = newComment
            }
        }

        public init(
            id: UUID = UUID(),
            type: OperationType,
            sourcePath: String,
            destinationPath: String?,
            timestamp: Date = Date(),
            metadata: OperationMetadata? = nil
        ) {
            self.id = id
            self.type = type
            self.sourcePath = sourcePath
            self.destinationPath = destinationPath
            self.timestamp = timestamp
            self.metadata = metadata
        }
    }
    
    /// Result of a restore/undo operation
    public struct RestoreResult: Sendable {
        public let successfulOperations: Int
        public let missingFiles: [String]  // File paths that couldn't be restored because they no longer exist
        public let retryableFailedOperationIDs: [UUID]

        public init(
            successfulOperations: Int,
            missingFiles: [String],
            retryableFailedOperationIDs: [UUID] = []
        ) {
            self.successfulOperations = successfulOperations
            self.missingFiles = missingFiles
            self.retryableFailedOperationIDs = retryableFailedOperationIDs
        }

        public var hasIssues: Bool { !missingFiles.isEmpty || !retryableFailedOperationIDs.isEmpty }
        
        public var summaryMessage: String {
            if missingFiles.isEmpty {
                return "Successfully restored \(successfulOperations) operations."
            } else {
                return "Restored \(successfulOperations) operations. \(missingFiles.count) file(s) couldn't be restored because they no longer exist."
            }
        }
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func protectedCleanupFolders(
        for operations: [FileOperation],
        protectedOperationIDs: Set<UUID>
    ) -> Set<String> {
        guard !protectedOperationIDs.isEmpty else {
            return []
        }

        var protectedFolders: Set<String> = []

        for operation in operations where protectedOperationIDs.contains(operation.id) {
            let folderPath: String?
            switch operation.type {
            case .moveFile, .renameFile, .copyFile:
                folderPath = operation.destinationPath.map {
                    URL(fileURLWithPath: $0).deletingLastPathComponent().path
                }
            case .createFolder:
                folderPath = operation.sourcePath
            case .deleteFile, .tagFile:
                folderPath = nil
            }

            guard var currentPath = folderPath.map(normalizedPath) else {
                continue
            }

            while true {
                protectedFolders.insert(currentPath)
                let parentPath = normalizedPath((currentPath as NSString).deletingLastPathComponent)
                if parentPath == currentPath {
                    break
                }
                currentPath = parentPath
            }
        }

        return protectedFolders
    }

    public init() {}

    // MARK: - Revert Protection

    /// Check if a path is currently being reverted
    public func isPathBeingReverted(_ path: String) -> Bool {
        return revertingPaths.contains(path) || revertingPaths.contains { path.isSubpath(of: $0) }
    }

    /// Mark paths as being reverted to prevent re-organization
    private func markPathsAsReverting(_ paths: [String]) {
        for path in paths {
            revertingPaths.insert(path)
        }
    }

    /// Clear revert marks after completion
    private func clearRevertMarks(_ paths: [String]) {
        for path in paths {
            revertingPaths.remove(path)
        }
    }

    // MARK: - Folder Creation

    func createFolders(_ plan: OrganizationPlan, at baseURL: URL, dryRun: Bool = false, exclusionManager: ExclusionRulesManager? = nil) async throws -> [FileOperation] {
        var operations: [FileOperation] = []

        for suggestion in plan.suggestions {
            let ops = try await createFolderRecursive(suggestion, parentURL: baseURL, dryRun: dryRun, exclusionManager: exclusionManager)
            operations.append(contentsOf: ops)
        }

        return operations
    }
    
    private func createFolderRecursive(_ suggestion: FolderSuggestion, parentURL: URL, dryRun: Bool, exclusionManager: ExclusionRulesManager?) async throws -> [FileOperation] {
        var operations: [FileOperation] = []
        
        let folderURL = try resolveDestinationFolderURL(folderName: suggestion.folderName, parentURL: parentURL)

        // Check exclusions
        if let manager = exclusionManager {
            let item = FileItem(path: folderURL.path, name: folderURL.lastPathComponent, extension: folderURL.pathExtension)
            if await manager.shouldExclude(item) {
                DebugLogger.log("Skipping excluded folder creation: \(folderURL.path)")
                return operations
            }
        }

        if !dryRun {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    // Folder already exists, continue with subfolders
                } else {
                    // Conflict: File exists where folder should be
                    let backupBaseName = folderURL.lastPathComponent
                    let backupURL = folderURL.deletingLastPathComponent()
                        .appendingPathComponent("\(backupBaseName)_file_backup_\(UUID().uuidString.prefix(8))")
                    try fileManager.moveItem(at: folderURL, to: backupURL)

                    // Record this move for undo
                    operations.append(FileOperation(
                        id: UUID(),
                        type: .moveFile,
                        sourcePath: folderURL.path,
                        destinationPath: backupURL.path,
                        timestamp: Date(),
                        metadata: FileOperation.OperationMetadata(wasCreatedDuringOrganization: true)
                    ))

                    try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

                    operations.append(FileOperation(
                        id: UUID(),
                        type: .createFolder,
                        sourcePath: folderURL.path,
                        destinationPath: nil,
                        timestamp: Date(),
                        metadata: FileOperation.OperationMetadata(wasCreatedDuringOrganization: true)
                    ))
                }
            } else {
                try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
                operations.append(FileOperation(
                    id: UUID(),
                    type: .createFolder,
                    sourcePath: folderURL.path,
                    destinationPath: nil,
                    timestamp: Date(),
                    metadata: FileOperation.OperationMetadata(wasCreatedDuringOrganization: true)
                ))
            }
        }

        // Create subfolders
        for subfolder in suggestion.subfolders {
            let subOps = try await createFolderRecursive(subfolder, parentURL: folderURL, dryRun: dryRun, exclusionManager: exclusionManager)
            operations.append(contentsOf: subOps)
        }
        
        return operations
    }

    // MARK: - File Moving with Rename Support

    func moveFiles(_ plan: OrganizationPlan, at baseURL: URL, dryRun: Bool = false, exclusionManager: ExclusionRulesManager? = nil) async throws -> [FileOperation] {
        var operations: [FileOperation] = []
        // Shared across suggestions so two files targeting the same name in
        // one run never share a destination.
        var reserved = Set<String>()

        for suggestion in plan.suggestions {
            let ops = try await moveFilesInSuggestion(suggestion, parentURL: baseURL, dryRun: dryRun, exclusionManager: exclusionManager, reserved: &reserved)
            operations.append(contentsOf: ops)
        }

        return operations
    }

    private func resolvedFinalFilename(
        for file: FileItem,
        mapping: FileRenameMapping?,
        sourceURL: URL,
        destinationFolderURL: URL
    ) -> (name: String, metadata: FileOperation.OperationMetadata?) {
        guard let mapping,
              mapping.shouldApplyRename,
              let proposedName = mapping.suggestedName else {
            return (sourceURL.lastPathComponent, nil)
        }

        let sanitization = FilenameSanitizer.sanitize(
            proposedName,
            preservingExtension: sourceURL.pathExtension,
            enforceExtension: true
        )

        guard let safeName = sanitization.sanitizedName, !safeName.isEmpty else {
            return (sourceURL.lastPathComponent, nil)
        }

        let metadata = FileOperation.OperationMetadata(
            originalFilename: sourceURL.lastPathComponent,
            newFilename: safeName,
            wasCreatedDuringOrganization: false,
            parentFolderPath: destinationFolderURL.path
        )
        return (safeName, metadata)
    }

    private func operationType(
        from sourceURL: URL,
        to destinationURL: URL,
        renameMetadata: FileOperation.OperationMetadata?
    ) -> FileOperation.OperationType {
        renameMetadata == nil ? .moveFile : .renameFile
    }

    private func renameMappingsByFileID(
        in suggestion: FolderSuggestion
    ) -> [UUID: FileRenameMapping] {
        Dictionary(
            suggestion.fileRenameMappings.map { ($0.originalFile.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    private func finalFilenamesByFileID(
        in suggestion: FolderSuggestion
    ) -> [UUID: String] {
        let mappings = renameMappingsByFileID(in: suggestion)
        return Dictionary(
            uniqueKeysWithValues: suggestion.files.map { file in
                (file.id, mappings[file.id]?.finalFilename ?? file.displayName)
            }
        )
    }
    
    private func moveFilesInSuggestion(_ suggestion: FolderSuggestion, parentURL: URL, dryRun: Bool, exclusionManager: ExclusionRulesManager?, reserved: inout Set<String>) async throws -> [FileOperation] {
        var operations: [FileOperation] = []
        let renameMappings = renameMappingsByFileID(in: suggestion)
        
        let folderURL = try resolveDestinationFolderURL(folderName: suggestion.folderName, parentURL: parentURL)

        // Process files with potential renaming
        for file in suggestion.files {
            guard let sourceURL = file.url else { continue }

            // Check exclusions
            if let manager = exclusionManager {
                if await manager.shouldExclude(file) {
                    DebugLogger.log("Skipping excluded file move: \(sourceURL.path)")
                    continue
                }
            }

            let resolvedName = resolvedFinalFilename(
                for: file,
                mapping: renameMappings[file.id],
                sourceURL: sourceURL,
                destinationFolderURL: folderURL
            )
            let finalFilename = resolvedName.name
            let renameMetadata = resolvedName.metadata

            var destinationURL = folderURL.appendingPathComponent(finalFilename)

            // Skip if source and destination are identical
            if sourceURL.standardizedFileURL.path == destinationURL.standardizedFileURL.path {
                continue
            }

            if !dryRun {
                // Create destination directory if needed
                if !fileManager.fileExists(atPath: folderURL.path) {
                    try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
                }

                // Verify source exists
                guard fileManager.fileExists(atPath: sourceURL.path) else {
                    continue
                }

                // Move file, uniquifying against disk + batch reservations and
                // retrying races. Records the actual destination below so the
                // preview never silently disagrees with what landed on disk.
                destinationURL = try await moveFileResolvingConflicts(
                    from: sourceURL,
                    proposedDestination: destinationURL,
                    reserved: &reserved
                )
            }

            // Record the operation
            let operationType = operationType(
                from: sourceURL,
                to: destinationURL,
                renameMetadata: renameMetadata
            )

            operations.append(FileOperation(
                id: UUID(),
                type: operationType,
                sourcePath: sourceURL.path,
                destinationPath: destinationURL.path,
                timestamp: Date(),
                metadata: renameMetadata
            ))
        }

        // Process subfolders
        for subfolder in suggestion.subfolders {
            let subOps = try await moveFilesInSuggestion(subfolder, parentURL: folderURL, dryRun: dryRun, exclusionManager: exclusionManager, reserved: &reserved)
            operations.append(contentsOf: subOps)
        }
        
        return operations
    }

    // MARK: - File Tagging

    func tagFiles(_ plan: OrganizationPlan, at baseURL: URL, dryRun: Bool = false, exclusionManager: ExclusionRulesManager? = nil) async throws -> [FileOperation] {
        // Tagging is now gated by the caller using this method
        var operations: [FileOperation] = []

        for suggestion in plan.suggestions {
            let ops = try await tagFilesInSuggestion(suggestion, parentURL: baseURL, dryRun: dryRun, exclusionManager: exclusionManager)
            operations.append(contentsOf: ops)
        }

        return operations
    }
    
    private func normalizeFinderTag(_ tag: String) -> String {
        switch tag.lowercased() {
        case "important", "urgent", "critical", "high priority":
            return "Red"
        case "in progress", "pending", "todo", "needs attention", "review":
            return "Orange"
        case "draft", "temporary", "temp", "wip":
            return "Yellow"
        case "complete", "done", "verified", "approved", "final":
            return "Green"
        case "reference", "info", "documentation", "docs":
            return "Blue"
        case "creative", "design", "media", "art":
            return "Purple"
        case "archive", "old", "inactive", "deprecated":
            return "Gray"
        case "red", "orange", "yellow", "green", "blue", "purple", "gray":
            return tag.capitalized
        default:
            return tag
        }
    }

    private func setFinderComment(_ comment: String?, for url: URL) throws {
        let path = url.path
        let key = "com.apple.metadata:kMDItemFinderComment"

        guard let comment = comment, !comment.isEmpty else {
            let rc = removexattr(path, key, 0)
            if rc != 0 && errno != ENOENT && errno != 93 {
                DebugLogger.log("Failed to remove Finder comment for \(path): errno \(errno)")
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: comment,
            format: .binary,
            options: 0
        )

        let rc: Int32 = data.withUnsafeBytes { buf in
            setxattr(path, key, buf.baseAddress!, buf.count, 0, 0)
        }
        if rc != 0 {
            DebugLogger.log("Failed to set Finder comment for \(path): errno \(errno)")
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func applyTagsAndComment(to url: URL, tags: [String], comment: String?, dryRun: Bool) -> FileOperation? {
        let hasComment = comment != nil && !(comment ?? "").isEmpty
        guard !tags.isEmpty || hasComment else { return nil }

        if dryRun {
            return FileOperation(
                type: .tagFile,
                sourcePath: url.path,
                destinationPath: nil,
                metadata: FileOperation.OperationMetadata(
                    newTags: tags,
                    newComment: comment
                )
            )
        }

        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let resourceValues = try? url.resourceValues(forKeys: [.tagNamesKey])
        let originalTags = resourceValues?.tagNames ?? []
        let originalComment = url.finderComment

        var finalTags = originalTags
        if !tags.isEmpty {
            let normalizedTags = tags.map { normalizeFinderTag($0) }
            var newTagsSet = Set(originalTags)
            for tag in normalizedTags {
                newTagsSet.insert(tag)
            }
            finalTags = Array(newTagsSet)

            let nsURL = url as NSURL
            do {
                try nsURL.setResourceValue(finalTags, forKey: .tagNamesKey)
                #if DEBUG
                if let verifyValues = try? url.resourceValues(forKeys: [.tagNamesKey]),
                   let verifyTags = verifyValues.tagNames {
                    DebugLogger.log("Tags verified for \(url.lastPathComponent): \(verifyTags)")
                }
                #endif
            } catch {
                DebugLogger.log("Tagging failed for \(url.path): \(error.localizedDescription)")
            }
        }

        if hasComment {
            try? setFinderComment(comment, for: url)
        }

        return FileOperation(
            type: .tagFile,
            sourcePath: url.path,
            destinationPath: nil,
            metadata: FileOperation.OperationMetadata(
                originalTags: originalTags,
                newTags: finalTags,
                originalComment: originalComment,
                newComment: comment
            )
        )
    }

    private func tagFilesInSuggestion(_ suggestion: FolderSuggestion, parentURL: URL, dryRun: Bool, exclusionManager: ExclusionRulesManager?) async throws -> [FileOperation] {
        var operations: [FileOperation] = []
        let finalFilenames = finalFilenamesByFileID(in: suggestion)
        
        let folderURL = try resolveDestinationFolderURL(folderName: suggestion.folderName, parentURL: parentURL)

        if let folderOp = applyTagsAndComment(to: folderURL, tags: suggestion.tags, comment: suggestion.comment, dryRun: dryRun) {
            operations.append(folderOp)
        }

        // Look for tag mappings in this suggestion
        for mapping in suggestion.fileTagMappings {
            // Check exclusions
            if let manager = exclusionManager {
                if await manager.shouldExclude(mapping.originalFile) {
                    continue
                }
            }

            // Find the file name (use the new name if it was renamed)
            let finalFilename = finalFilenames[mapping.originalFile.id] ?? mapping.originalFile.displayName
            
            let fileURL = folderURL.appendingPathComponent(finalFilename)
            
            if let op = applyTagsAndComment(to: fileURL, tags: mapping.tags, comment: mapping.comment, dryRun: dryRun) {
                operations.append(op)
            }
        }

        // Recurse
        for subfolder in suggestion.subfolders {
            let subOps = try await tagFilesInSuggestion(subfolder, parentURL: folderURL, dryRun: dryRun, exclusionManager: exclusionManager)
            operations.append(contentsOf: subOps)
        }
        
        return operations
    }

    // MARK: - Apply Organization
    
    func validateOperation(_ operation: FileOperation, exclusionManager: ExclusionRulesManager?) async -> Bool {
        guard let manager = exclusionManager else { return true }
        let matcher = await manager.matcherSnapshot()
        let sourceURL = URL(fileURLWithPath: operation.sourcePath)
        let sourceValues = try? sourceURL.resourceValues(forKeys: [
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .labelNumberKey,
        ])
        let shouldExcludeSource = matcher.shouldExcludeFile(
            at: sourceURL,
            size: Int64(sourceValues?.fileSize ?? 0),
            creationDate: sourceValues?.creationDate,
            modificationDate: sourceValues?.contentModificationDate,
            finderLabelNumber: sourceValues?.labelNumber
        )
        if shouldExcludeSource {
            DebugLogger.log("Operation BLOCKED: Source \(operation.sourcePath) is excluded.")
            return false
        }
        
        if let destPath = operation.destinationPath {
            let destURL = URL(fileURLWithPath: destPath)
            let destinationValues = try? destURL.resourceValues(forKeys: [
                .fileSizeKey,
                .creationDateKey,
                .contentModificationDateKey,
                .labelNumberKey,
            ])
            let shouldExcludeDest = matcher.shouldExcludeFile(
                at: destURL,
                size: Int64(destinationValues?.fileSize ?? 0),
                creationDate: destinationValues?.creationDate,
                modificationDate: destinationValues?.contentModificationDate,
                finderLabelNumber: destinationValues?.labelNumber
            )
            if shouldExcludeDest {
                DebugLogger.log("Operation BLOCKED: Destination \(destPath) is excluded.")
                return false
            }
        }
        
        return true
    }

    private struct OperationResult {
        let operations: [FileOperation]
        let processedCount: Int
    }

    private struct OrganizationProgress {
        private static let minimumOperationInterval = 250
        private static let minimumTimeInterval: TimeInterval = 0.15

        let totalOperations: Int
        let handler: (@Sendable (Double, String) -> Void)?
        private(set) var completedOperations = 0
        private var lastReportedOperations = 0
        private var lastReportedAt = Date.distantPast

        init(
            totalOperations: Int,
            handler: (@Sendable (Double, String) -> Void)?
        ) {
            self.totalOperations = totalOperations
            self.handler = handler
        }

        mutating func report(_ message: String) {
            completedOperations += 1
            let now = Date()
            let shouldReport = completedOperations == 1
                || completedOperations >= totalOperations
                || completedOperations - lastReportedOperations >= Self.minimumOperationInterval
                || now.timeIntervalSince(lastReportedAt) >= Self.minimumTimeInterval
            guard shouldReport else { return }

            let rawProgress = totalOperations > 0
                ? Double(completedOperations) / Double(totalOperations)
                : 1.0
            lastReportedOperations = completedOperations
            lastReportedAt = now
            handler?(min(rawProgress, 1.0), message)
        }
    }
    
    func applyOrganization(
        _ plan: OrganizationPlan, 
        at baseURL: URL, 
        dryRun: Bool = false, 
        enableTagging: Bool = true,
        strictExclusions: Bool = true,
        exclusionManager: ExclusionRulesManager? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> [FileOperation] {
        _ = startAccessing(baseURL)
        defer { stopAccessingAll() }

        var allOperations: [FileOperation] = []
        var allFailures: [OperationFailure] = []

        do {
            let totalFiles = plan.suggestions.reduce(0) { $0 + countFiles(in: $1) }
            let totalFolders = plan.suggestions.reduce(0) { $0 + countFolders(in: $1) }
            let totalOps = totalFiles + totalFolders + (enableTagging ? totalFiles + totalFolders : 0)
            allOperations.reserveCapacity(totalFiles + totalFolders)
            var operationProgress = OrganizationProgress(totalOperations: totalOps, handler: progress)

            if !dryRun {
                progress?(0.02, "Validating files...")
                let validationIssues = await preValidatePlan(plan, at: baseURL)
                if !validationIssues.isEmpty {
                    DebugLogger.log("Pre-validation found \(validationIssues.count) issue(s): \(validationIssues.joined(separator: ", "))")
                    throw FileSystemError.preValidationFailed(validationIssues)
                }
            }

            progress?(0.05, "Creating folder structure...")

            for suggestion in plan.suggestions {
                let result = try await createFoldersWithProgress(
                    suggestion,
                    currentURL: baseURL,
                    dryRun: dryRun,
                    exclusionManager: exclusionManager,
                    operationProgress: &operationProgress,
                    failures: &allFailures
                )
                allOperations.append(contentsOf: result.operations)
            }

            if !allFailures.isEmpty {
                throw FileSystemError.partialFailure(
                    successCount: allOperations.count,
                    failures: allFailures
                )
            }

            progress?(0.1, "Moving files...")

            // Shared across suggestions so two files targeting the same name
            // in one run never share a destination.
            var reservedDestinations = Set<String>()
            for suggestion in plan.suggestions {
                let result = try await moveFilesInSuggestionWithProgress(
                    suggestion,
                    parentURL: baseURL,
                    dryRun: dryRun,
                    exclusionManager: exclusionManager,
                    operationProgress: &operationProgress,
                    failures: &allFailures,
                    reserved: &reservedDestinations
                )
                allOperations.append(contentsOf: result.operations)
            }

            if !allFailures.isEmpty {
                throw FileSystemError.partialFailure(
                    successCount: allOperations.count,
                    failures: allFailures
                )
            }

            if enableTagging {
                progress?(0.8, "Applying tags...")
                let movedDestinations = allOperations.reduce(into: [String: URL]()) { destinations, operation in
                    guard operation.type == .moveFile || operation.type == .renameFile,
                          let destinationPath = operation.destinationPath else {
                        return
                    }
                    destinations[normalizedPath(operation.sourcePath)] = URL(fileURLWithPath: destinationPath)
                }

                for suggestion in plan.suggestions {
                    let result = try await tagFilesWithProgress(
                        suggestion,
                        currentURL: baseURL,
                        movedDestinations: movedDestinations,
                        dryRun: dryRun,
                        exclusionManager: exclusionManager,
                        operationProgress: &operationProgress
                    )
                    allOperations.append(contentsOf: result.operations)
                }
            }

            if !dryRun {
                progress?(0.9, "Cleaning up empty folders...")

                let fileOps = allOperations.filter { $0.type == .moveFile || $0.type == .renameFile }
                let sourceFolders = Set(fileOps.compactMap { URL(fileURLWithPath: $0.sourcePath).deletingLastPathComponent().path })
                let sortedFolders = sourceFolders.sorted { $0.components(separatedBy: "/").count > $1.components(separatedBy: "/").count }

                for folderPath in sortedFolders {
                    if folderPath != baseURL.path && folderPath.hasPrefix(baseURL.path) {
                        _ = try? removeEmptyFolder(at: folderPath)
                    }
                }

                var newlyCreatedFolders = Set<String>()
                for suggestion in plan.suggestions {
                    let paths = collectFolderPaths(suggestion, parentURL: baseURL)
                    newlyCreatedFolders.formUnion(paths)
                }
                try? cleanupEmptySubdirectories(at: baseURL, excluding: newlyCreatedFolders)

                if !allFailures.isEmpty {
                    DebugLogger.log("Organization completed with \(allFailures.count) failure(s)")
                    for failure in allFailures {
                        DebugLogger.log("  - \(failure.sourcePath): \(failure.error)")
                    }
                }
            }

            if allFailures.isEmpty {
                progress?(1.0, "Organization complete!")
            } else {
                progress?(1.0, "Complete with \(allFailures.count) skipped file(s)")
            }

            return allOperations
        } catch {
            guard !dryRun, !allOperations.isEmpty else {
                throw error
            }

            if !allFailures.isEmpty {
                DebugLogger.log("Organization failed after \(allOperations.count) recorded operation(s) and \(allFailures.count) skipped file(s)")
                for failure in allFailures {
                    DebugLogger.log("  - \(failure.sourcePath): \(failure.error)")
                }
            }

            throw FileSystemError.partialApplyFailure(
                operations: allOperations,
                underlyingDescription: error.localizedDescription
            )
        }
    }
    
    private func createFoldersWithProgress(
        _ suggestion: FolderSuggestion,
        currentURL: URL,
        dryRun: Bool,
        exclusionManager: ExclusionRulesManager? = nil,
        operationProgress: inout OrganizationProgress,
        failures: inout [OperationFailure]
    ) async throws -> OperationResult {
        var operations: [FileOperation] = []
        var processedCount = 0
        
        try Task.checkCancellation()
        
        let folderURL = try resolveDestinationFolderURL(folderName: suggestion.folderName, parentURL: currentURL)
        
        if let manager = exclusionManager {
            let item = FileItem(path: folderURL.path, name: folderURL.lastPathComponent, extension: folderURL.pathExtension)
            if await manager.shouldExclude(item) {
                DebugLogger.log("Skipping excluded folder creation: \(folderURL.path)")
                return OperationResult(operations: operations, processedCount: processedCount)
            }
        }
        
        if !dryRun {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory)
            
            do {
                if exists && !isDirectory.boolValue {
                    let backupName = "\(folderURL.lastPathComponent)_backup_\(UUID().uuidString.prefix(8))"
                    let backupURL = currentURL.appendingPathComponent(backupName)
                    try await withRetry {
                        try fileManager.moveItem(at: folderURL, to: backupURL)
                    }
                    operations.append(FileOperation(
                        id: UUID(),
                        type: .moveFile,
                        sourcePath: folderURL.path,
                        destinationPath: backupURL.path,
                        timestamp: Date(),
                        metadata: FileOperation.OperationMetadata(wasCreatedDuringOrganization: true)
                    ))
                    DebugLogger.log("Moved conflicting file to \(backupName)")
                }
                
                if !exists || !isDirectory.boolValue {
                    try await withRetry {
                        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
                    }
                    operations.append(FileOperation(
                        type: .createFolder,
                        sourcePath: folderURL.path,
                        destinationPath: nil,
                        metadata: .init(wasCreatedDuringOrganization: true)
                    ))
                }
            } catch {
                DebugLogger.log("Failed to create folder \(folderURL.path): \(error.localizedDescription)")
                failures.append(OperationFailure(
                    sourcePath: folderURL.path,
                    destinationPath: nil,
                    error: error.localizedDescription,
                    isRetryable: false
                ))
                operationProgress.report("Skipped folder \(suggestion.folderName) (permission denied)...")
                processedCount += 1
                return OperationResult(operations: operations, processedCount: processedCount)
            }
        }
        operationProgress.report("Creating folder \(suggestion.folderName)...")
        processedCount += 1
        
        for subfolder in suggestion.subfolders {
            let subResult = try await createFoldersWithProgress(
                subfolder,
                currentURL: folderURL,
                dryRun: dryRun,
                exclusionManager: exclusionManager,
                operationProgress: &operationProgress,
                failures: &failures
            )
            operations.append(contentsOf: subResult.operations)
            processedCount += subResult.processedCount
        }
        
        return OperationResult(operations: operations, processedCount: processedCount)
    }
    
    private func moveFilesInSuggestionWithProgress(
        _ suggestion: FolderSuggestion,
        parentURL: URL,
        dryRun: Bool,
        exclusionManager: ExclusionRulesManager? = nil,
        operationProgress: inout OrganizationProgress,
        failures: inout [OperationFailure],
        reserved: inout Set<String>
    ) async throws -> OperationResult {
        var operations: [FileOperation] = []
        var processedCount = 0
        let renameMappings = renameMappingsByFileID(in: suggestion)
        
        let folderURL = try resolveDestinationFolderURL(folderName: suggestion.folderName, parentURL: parentURL)

        for file in suggestion.files {
            try Task.checkCancellation()
            guard let sourceURL = file.url else { continue }
            
            if let manager = exclusionManager {
                if await manager.shouldExclude(file) {
                    DebugLogger.log("Skipping excluded file move: \(sourceURL.path)")
                    operationProgress.report("Skipped \(sourceURL.lastPathComponent) (excluded)...")
                    processedCount += 1
                    continue
                }
            }
            
            let resolvedName = resolvedFinalFilename(
                for: file,
                mapping: renameMappings[file.id],
                sourceURL: sourceURL,
                destinationFolderURL: folderURL
            )
            let finalFilename = resolvedName.name
            let renameMetadata = resolvedName.metadata

            var destinationURL = folderURL.appendingPathComponent(finalFilename)
            let progressMessage = progressMessage(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                finalFilename: finalFilename,
                renameMetadata: renameMetadata
            )
            
            if sourceURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path {
                if !dryRun {
                    do {
                        if !fileManager.fileExists(atPath: folderURL.path) {
                            try await withRetry {
                                try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
                            }
                        }

                        guard fileManager.fileExists(atPath: sourceURL.path) else {
                            failures.append(OperationFailure(
                                sourcePath: sourceURL.path,
                                destinationPath: destinationURL.path,
                                error: "Source file no longer exists",
                                isRetryable: false
                            ))
                            operationProgress.report("Skipped \(finalFilename) (not found)...")
                            processedCount += 1
                            continue
                        }

                        // Uniquifies against disk + batch reservations, retries
                        // check-then-act races, and returns the actual
                        // destination, which is what gets recorded below.
                        destinationURL = try await moveFileResolvingConflicts(
                            from: sourceURL,
                            proposedDestination: destinationURL,
                            reserved: &reserved
                        )
                        
                        let operationType = operationType(
                            from: sourceURL,
                            to: destinationURL,
                            renameMetadata: renameMetadata
                        )
                        operations.append(FileOperation(
                            id: UUID(),
                            type: operationType,
                            sourcePath: sourceURL.path,
                            destinationPath: destinationURL.path,
                            timestamp: Date(),
                            metadata: renameMetadata
                        ))
                    } catch {
                        let isRetryable = isRetryableError(error)
                        failures.append(OperationFailure(
                            sourcePath: sourceURL.path,
                            destinationPath: destinationURL.path,
                            error: error.localizedDescription,
                            isRetryable: isRetryable
                        ))
                        DebugLogger.log("Failed to move \(sourceURL.lastPathComponent): \(error.localizedDescription)")
                    }
                } else {
                    let operationType = operationType(
                        from: sourceURL,
                        to: destinationURL,
                        renameMetadata: renameMetadata
                    )
                    operations.append(FileOperation(
                        id: UUID(),
                        type: operationType,
                        sourcePath: sourceURL.path,
                        destinationPath: destinationURL.path,
                        timestamp: Date(),
                        metadata: renameMetadata
                    ))
                }
            }
            
            operationProgress.report(progressMessage)
            processedCount += 1
        }

        for subfolder in suggestion.subfolders {
            let subResult = try await moveFilesInSuggestionWithProgress(
                subfolder,
                parentURL: folderURL,
                dryRun: dryRun,
                exclusionManager: exclusionManager,
                operationProgress: &operationProgress,
                failures: &failures,
                reserved: &reserved
            )
            operations.append(contentsOf: subResult.operations)
            processedCount += subResult.processedCount
        }
        
        return OperationResult(operations: operations, processedCount: processedCount)
    }

    private func progressMessage(
        sourceURL: URL,
        destinationURL: URL,
        finalFilename: String,
        renameMetadata: FileOperation.OperationMetadata?
    ) -> String {
        guard renameMetadata != nil else {
            return "Organizing \(finalFilename)..."
        }

        let sourceParent = sourceURL.deletingLastPathComponent().standardizedFileURL.path
        let destinationParent = destinationURL.deletingLastPathComponent().standardizedFileURL.path
        if sourceParent == destinationParent {
            return "Renaming \(finalFilename)..."
        }
        return "Organizing and renaming \(finalFilename)..."
    }

    private func tagFilesWithProgress(
        _ suggestion: FolderSuggestion,
        currentURL: URL,
        movedDestinations: [String: URL],
        dryRun: Bool,
        exclusionManager: ExclusionRulesManager? = nil,
        operationProgress: inout OrganizationProgress
    ) async throws -> OperationResult {
        var operations: [FileOperation] = []
        var processedCount = 0
        let finalFilenames = finalFilenamesByFileID(in: suggestion)
        
        try Task.checkCancellation()
        
        let folderURL = try resolveDestinationFolderURL(folderName: suggestion.folderName, parentURL: currentURL)

        if let folderOp = applyTagsAndComment(to: folderURL, tags: suggestion.tags, comment: suggestion.comment, dryRun: dryRun) {
            operations.append(folderOp)
            operationProgress.report("Tagging \(suggestion.folderName)...")
            processedCount += 1
        }
        
        for mapping in suggestion.fileTagMappings {
            try Task.checkCancellation()
            
            if let manager = exclusionManager {
                if await manager.shouldExclude(mapping.originalFile) {
                    continue
                }
            }
            
            let finalFilename = finalFilenames[mapping.originalFile.id] ?? mapping.originalFile.displayName
            let sourcePath = mapping.originalFile.url.map { normalizedPath($0.path) }
            let fileURL = sourcePath.flatMap { movedDestinations[$0] }
                ?? folderURL.appendingPathComponent(finalFilename)
            
            if let op = applyTagsAndComment(to: fileURL, tags: mapping.tags, comment: mapping.comment, dryRun: dryRun) {
                operations.append(op)
            }
            operationProgress.report("Tagging \(finalFilename)...")
            processedCount += 1
        }
        
        for subfolder in suggestion.subfolders {
            let subResult = try await tagFilesWithProgress(
                subfolder,
                currentURL: folderURL,
                movedDestinations: movedDestinations,
                dryRun: dryRun,
                exclusionManager: exclusionManager,
                operationProgress: &operationProgress
            )
            operations.append(contentsOf: subResult.operations)
            processedCount += subResult.processedCount
        }
        
        return OperationResult(operations: operations, processedCount: processedCount)
    }
    
    private func collectFolderPaths(_ suggestion: FolderSuggestion, parentURL: URL) -> Set<String> {
        var paths = Set<String>()
        let folderURL: URL
        do {
            folderURL = try resolveDestinationFolderURL(
                folderName: suggestion.folderName,
                parentURL: parentURL,
                requestSecurityScope: false
            )
        } catch {
            return paths
        }
        paths.insert(folderURL.path)
        for subfolder in suggestion.subfolders {
            let subPaths = collectFolderPaths(subfolder, parentURL: folderURL)
            paths.formUnion(subPaths)
        }
        return paths
    }
    
    private func countFiles(in folder: FolderSuggestion) -> Int {
        return folder.files.count + folder.subfolders.reduce(0) { $0 + countFiles(in: $1) }
    }
    
    private func countFolders(in folder: FolderSuggestion) -> Int {
        return 1 + folder.subfolders.reduce(0) { $0 + countFolders(in: $1) }
    }
    
    /// Recursively find and remove empty subdirectories, excluding newly created folders
    private func cleanupEmptySubdirectories(at baseURL: URL, excluding protectedPaths: Set<String>) throws {
        let contents = try fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey])
        let protected = Set(protectedPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })

        for item in contents {
            // Skip hidden files/folders
            if item.lastPathComponent.hasPrefix(".") {
                continue
            }

            if protected.contains(item.resolvingSymlinksInPath().path) {
                continue
            }

            let resourceValues = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            // Never descend into or remove app bundles, photo libraries, and
            // other packages: they are opaque to the user even though they are
            // directories on disk.
            guard resourceValues?.isPackage != true else { continue }
            let isDirectory = resourceValues?.isDirectory ?? false

            if isDirectory {
                // Recursively clean up subdirectories first
                try? cleanupEmptySubdirectories(at: item, excluding: protectedPaths)

                // Then try to remove this folder if it's empty
                _ = try? removeEmptyFolder(at: item.path)
            }
        }
    }

    // MARK: - Reverse Operations (Undo/Revert)
    
    /// Pre-flight check for restore operations - returns list of files that are missing at destination
    func preflightRestore(_ operations: [FileOperation]) -> [String] {
        var missingFiles: [String] = []
        
        for operation in operations {
            switch operation.type {
            case .moveFile, .renameFile:
                if let destinationPath = operation.destinationPath {
                    if !fileManager.fileExists(atPath: destinationPath) {
                        // File no longer exists at destination - can't restore
                        missingFiles.append(URL(fileURLWithPath: destinationPath).lastPathComponent)
                    }
                }
            case .createFolder, .deleteFile, .copyFile, .tagFile:
                // These don't require the file to exist for undo
                break
            }
        }
        
        return missingFiles
    }

    /// Reverses a set of operations - returns result with details about skipped files
    func reverseOperations(_ operations: [FileOperation]) async throws -> RestoreResult {
        // Collect all paths involved and ensure we have access if they are security-scoped
        var involvedPaths: [String] = []
        for op in operations {
            involvedPaths.append(op.sourcePath)
            if let dest = op.destinationPath {
                involvedPaths.append(dest)
            }
        }
        
        // Start accessing all involved paths that might be security-scoped
        for path in involvedPaths {
            _ = startAccessing(URL(fileURLWithPath: path))
        }
        defer { stopAccessingAll() }

        // Mark paths as reverting to prevent re-organization by watched folders
        markPathsAsReverting(involvedPaths)

        defer {
            // Always clear revert marks when done
            clearRevertMarks(involvedPaths)
        }

        // Reverse in opposite order of creation
        let reversedOps = operations.reversed()

        // Track folders that may need cleanup
        var foldersToCleanup: Set<String> = []
        
        // Track results
        var successCount = 0
        var missingFiles: [String] = []
        var retryableFailedOperationIDs: [UUID] = []

        // First pass: move files back
        for operation in reversedOps {
            do {
                switch operation.type {
            case .moveFile, .renameFile:
                if let destinationPath = operation.destinationPath {
                    // Check if the moved file still exists at destination
                    if fileManager.fileExists(atPath: destinationPath) {
                        // Ensure the original directory exists
                        let originalDir = URL(fileURLWithPath: operation.sourcePath).deletingLastPathComponent()
                        if !fileManager.fileExists(atPath: originalDir.path) {
                            try fileManager.createDirectory(at: originalDir, withIntermediateDirectories: true)
                        }

                        // Determine final source path (handle conflicts)
                        var finalSourcePath = operation.sourcePath
                        if fileManager.fileExists(atPath: finalSourcePath) {
                            var isDirectory: ObjCBool = false
                            if fileManager.fileExists(atPath: finalSourcePath, isDirectory: &isDirectory), isDirectory.boolValue {
                                _ = try? removeEmptyFolder(at: finalSourcePath)
                            }
                        }
                        if fileManager.fileExists(atPath: finalSourcePath) {
                            // Original location is occupied by something else
                            let uniqueURL = try generateUniqueURL(for: URL(fileURLWithPath: finalSourcePath))
                            finalSourcePath = uniqueURL.path
                        }

                        // Move file back, preserving the remote/external copy until a
                        // cross-volume restore has been fully staged and verified.
                        let destinationURL = URL(fileURLWithPath: destinationPath)
                        let finalSourceURL = URL(fileURLWithPath: finalSourcePath)
                        if isCrossVolume(from: destinationURL, to: finalSourceURL) {
                            let handler = crossVolumeProgressHandler
                            try await copyWithProgress(
                                from: destinationURL,
                                to: finalSourceURL
                            ) { progress in
                                handler?(destinationURL.lastPathComponent, progress)
                            }
                        } else {
                            try fileManager.moveItem(at: destinationURL, to: finalSourceURL)
                        }
                        successCount += 1

                        // Mark parent folder for potential cleanup
                        let parentFolder = URL(fileURLWithPath: destinationPath).deletingLastPathComponent().path
                        foldersToCleanup.insert(parentFolder)
                    } else {
                        // File no longer exists - track as missing
                        let filename = URL(fileURLWithPath: destinationPath).lastPathComponent
                        missingFiles.append(filename)
                        retryableFailedOperationIDs.append(operation.id)
                        DebugLogger.log("Cannot restore - file no longer exists: \(destinationPath)")
                    }
                }

            case .createFolder:
                // Mark for cleanup (will be handled in second pass)
                foldersToCleanup.insert(operation.sourcePath)

            case .deleteFile:
                // Cannot undo deletion without backup - log warning
                DebugLogger.log("Cannot undo deletion: \(operation.sourcePath)")
                missingFiles.append(URL(fileURLWithPath: operation.sourcePath).lastPathComponent)

            case .copyFile:
                // Remove the copy if it exists
                if let destinationPath = operation.destinationPath,
                   fileManager.fileExists(atPath: destinationPath) {
                    try fileManager.removeItem(atPath: destinationPath)
                    successCount += 1
                }
                
            case .tagFile:
                let tagURL = URL(fileURLWithPath: operation.sourcePath)
                guard fileManager.fileExists(atPath: tagURL.path) else {
                    missingFiles.append(tagURL.lastPathComponent)
                    retryableFailedOperationIDs.append(operation.id)
                    break
                }
                var tagFailures = 0
                var attemptedRestores = 0
                if let originalTags = operation.metadata?.originalTags {
                    attemptedRestores += 1
                    do {
                        try (tagURL as NSURL).setResourceValue(originalTags, forKey: .tagNamesKey)
                    } catch {
                        tagFailures += 1
                        DebugLogger.log("Failed to restore tags for \(tagURL.path): \(error.localizedDescription)")
                    }
                }
                if operation.metadata?.newComment != nil {
                    attemptedRestores += 1
                    do {
                        try setFinderComment(operation.metadata?.originalComment, for: tagURL)
                    } catch {
                        tagFailures += 1
                        DebugLogger.log("Failed to restore comment for \(tagURL.path): \(error.localizedDescription)")
                    }
                }
                if attemptedRestores == 0 {
                    // No tag/comment payload recorded; nothing to restore.
                    break
                }
                if tagFailures == 0 {
                    successCount += 1
                } else {
                    missingFiles.append(tagURL.lastPathComponent)
                    retryableFailedOperationIDs.append(operation.id)
                }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failedPath = operation.destinationPath ?? operation.sourcePath
                missingFiles.append(URL(fileURLWithPath: failedPath).lastPathComponent)
                retryableFailedOperationIDs.append(operation.id)
                DebugLogger.log("Cannot restore \(failedPath): \(error.localizedDescription)")
            }
        }

        let protectedFolders = protectedCleanupFolders(
            for: operations,
            protectedOperationIDs: Set(retryableFailedOperationIDs)
        )

        // Second pass: cleanup empty folders (sorted by depth, deepest first)
        let sortedFolders = foldersToCleanup.sorted { path1, path2 in
            path1.components(separatedBy: "/").count > path2.components(separatedBy: "/").count
        }

        for folderPath in sortedFolders {
            if protectedFolders.contains(normalizedPath(folderPath)) {
                continue
            }
            guard removeEmptyFolderIfEmpty(at: folderPath) else {
                if let operation = operations.first(where: { $0.type == .createFolder && normalizedPath($0.sourcePath) == normalizedPath(folderPath) }) {
                    missingFiles.append(URL(fileURLWithPath: folderPath).lastPathComponent)
                    retryableFailedOperationIDs.append(operation.id)
                }
                continue
            }

            if operations.contains(where: { $0.type == .createFolder && normalizedPath($0.sourcePath) == normalizedPath(folderPath) }) {
                successCount += 1
            }
        }
        
        return RestoreResult(
            successfulOperations: successCount,
            missingFiles: missingFiles,
            retryableFailedOperationIDs: retryableFailedOperationIDs
        )
    }

    /// Undoes a single file operation (move file back, remove created folder if empty, restore tags)
    public func restoreSingleOperation(
        _ operation: FileOperation,
        protectedSiblingOperations: [FileOperation] = []
    ) async throws -> RestoreResult {
        _ = startAccessing(URL(fileURLWithPath: operation.sourcePath))
        if let dest = operation.destinationPath {
            _ = startAccessing(URL(fileURLWithPath: dest))
        }
        defer { stopAccessingAll() }

        var successCount = 0
        var missingFiles: [String] = []
        var retryableFailedOperationIDs: [UUID] = []
        let protectedFolders = protectedCleanupFolders(
            for: protectedSiblingOperations,
            protectedOperationIDs: Set(protectedSiblingOperations.map(\.id))
        )

        switch operation.type {
        case .moveFile, .renameFile:
            if let destinationPath = operation.destinationPath {
                if fileManager.fileExists(atPath: destinationPath) {
                    let originalDir = URL(fileURLWithPath: operation.sourcePath).deletingLastPathComponent()
                    if !fileManager.fileExists(atPath: originalDir.path) {
                        try fileManager.createDirectory(at: originalDir, withIntermediateDirectories: true)
                    }

                    var finalSourcePath = operation.sourcePath
                    if fileManager.fileExists(atPath: finalSourcePath) {
                        var isDirectory: ObjCBool = false
                        if fileManager.fileExists(atPath: finalSourcePath, isDirectory: &isDirectory), isDirectory.boolValue {
                            _ = try? removeEmptyFolder(at: finalSourcePath)
                        }
                    }
                    if fileManager.fileExists(atPath: finalSourcePath) {
                        let uniqueURL = try generateUniqueURL(for: URL(fileURLWithPath: finalSourcePath))
                        finalSourcePath = uniqueURL.path
                    }

                    let destinationURL = URL(fileURLWithPath: destinationPath)
                    let finalSourceURL = URL(fileURLWithPath: finalSourcePath)
                    if isCrossVolume(from: destinationURL, to: finalSourceURL) {
                        let handler = crossVolumeProgressHandler
                        try await copyWithProgress(
                            from: destinationURL,
                            to: finalSourceURL
                        ) { progress in
                            handler?(destinationURL.lastPathComponent, progress)
                        }
                    } else {
                        try fileManager.moveItem(at: destinationURL, to: finalSourceURL)
                    }
                    successCount += 1

                    let parentFolder = URL(fileURLWithPath: destinationPath).deletingLastPathComponent().path
                    if !protectedFolders.contains(normalizedPath(parentFolder)) {
                        _ = try? removeEmptyFolder(at: parentFolder)
                    }
                } else {
                    let filename = URL(fileURLWithPath: destinationPath).lastPathComponent
                    missingFiles.append(filename)
                    retryableFailedOperationIDs.append(operation.id)
                }
            }

        case .createFolder:
            if removeEmptyFolderIfEmpty(at: operation.sourcePath) {
                successCount += 1
            } else {
                missingFiles.append(URL(fileURLWithPath: operation.sourcePath).lastPathComponent)
                retryableFailedOperationIDs.append(operation.id)
            }

        case .deleteFile:
            missingFiles.append(URL(fileURLWithPath: operation.sourcePath).lastPathComponent)

        case .copyFile:
            if let destinationPath = operation.destinationPath,
               fileManager.fileExists(atPath: destinationPath) {
                try fileManager.removeItem(atPath: destinationPath)
                successCount += 1
            }

        case .tagFile:
            let url = URL(fileURLWithPath: operation.sourcePath)
            if fileManager.fileExists(atPath: url.path) {
                var singleFailures = 0
                var singleAttempted = 0
                if let originalTags = operation.metadata?.originalTags {
                    singleAttempted += 1
                    do {
                        try (url as NSURL).setResourceValue(originalTags, forKey: .tagNamesKey)
                    } catch {
                        singleFailures += 1
                        DebugLogger.log("Failed to restore tags for \(url.path): \(error.localizedDescription)")
                    }
                }
                if operation.metadata?.newComment != nil {
                    singleAttempted += 1
                    do {
                        try setFinderComment(operation.metadata?.originalComment, for: url)
                    } catch {
                        singleFailures += 1
                        DebugLogger.log("Failed to restore comment for \(url.path): \(error.localizedDescription)")
                    }
                }
                if singleAttempted > 0, singleFailures == 0 {
                    successCount += 1
                } else if singleAttempted > 0 {
                    missingFiles.append(url.lastPathComponent)
                    retryableFailedOperationIDs.append(operation.id)
                }
            } else {
                missingFiles.append(url.lastPathComponent)
                retryableFailedOperationIDs.append(operation.id)
            }
        }

        return RestoreResult(
            successfulOperations: successCount,
            missingFiles: missingFiles,
            retryableFailedOperationIDs: retryableFailedOperationIDs
        )
    }

    /// Remove only the requested folder when it contains no significant files.
    @discardableResult
    private func removeEmptyFolder(at path: String) throws -> Bool {
        removeEmptyFolderIfEmpty(at: path)
    }

    private func removeEmptyFolderIfEmpty(at path: String) -> Bool {
        guard fileManager.fileExists(atPath: path) else { return true }

        // Packages (.app, .photoslibrary, ...) are never cleanup candidates,
        // even when they look like empty directories.
        if (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
            return false
        }

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: path)

            // Safe list of disposable files
            let disposableFiles: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini"]
            
            // Check if there are any files that are NOT in the disposable list
            let hasSignificantContent = contents.contains { filename in
                !disposableFiles.contains(filename)
            }

            if !hasSignificantContent {
                // Only remove the known disposable files
                for item in contents {
                    if disposableFiles.contains(item) {
                        let itemPath = (path as NSString).appendingPathComponent(item)
                        try? fileManager.removeItem(atPath: itemPath)
                    }
                }

                // Double check if folder is truly empty now
                if let remaining = try? fileManager.contentsOfDirectory(atPath: path), remaining.isEmpty {
                     try fileManager.removeItem(atPath: path)
                }
                return !fileManager.fileExists(atPath: path)
            }

        } catch {
            // Folder might not be empty or we don't have permission
            DebugLogger.log("Could not remove folder: \(path) - \(error.localizedDescription)")
        }

        return false
    }

    // MARK: - Retry and Validation Helpers
    
    private struct RetryConfig {
        let maxAttempts: Int
        let baseDelay: UInt64
        let maxDelay: UInt64
        
        static let `default` = RetryConfig(
            maxAttempts: 3,
            baseDelay: 100_000_000, // 100ms
            maxDelay: 1_000_000_000 // 1s
        )
    }
    
    private func isRetryableError(_ error: Error) -> Bool {
        let nsError = error as NSError
        switch nsError.domain {
        case NSCocoaErrorDomain:
            switch nsError.code {
            case NSFileWriteNoPermissionError,
                 NSFileReadNoPermissionError:
                return false
            case 640, // NSFileBusyError constant value
                 NSFileWriteVolumeReadOnlyError:
                return true
            default:
                return nsError.code >= 500
            }
        case NSPOSIXErrorDomain:
            switch nsError.code {
            case Int(EBUSY), Int(EAGAIN), Int(EINTR), Int(ETXTBSY):
                return true
            case Int(EACCES), Int(EPERM), Int(EROFS):
                return false
            default:
                return false
            }
        default:
            return false
        }
    }
    
    private func withRetry<T>(
        config: RetryConfig = .default,
        operation: () throws -> T
    ) async throws -> T {
        var lastError: Error?
        var delay = config.baseDelay
        
        for attempt in 1...config.maxAttempts {
            do {
                return try operation()
            } catch {
                lastError = error
                
                if !isRetryableError(error) || attempt == config.maxAttempts {
                    throw error
                }
                
                DebugLogger.log("Retry attempt \(attempt)/\(config.maxAttempts) after error: \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, config.maxDelay)
            }
        }
        
        throw lastError ?? FileSystemError.fileNotFound()
    }
    
    private func checkFileAccessibility(at url: URL) -> (accessible: Bool, issue: String?) {
        let path = url.path
        
        guard fileManager.fileExists(atPath: path) else {
            return (false, "File does not exist: \(url.lastPathComponent)")
        }
        
        guard fileManager.isReadableFile(atPath: path) else {
            return (false, "Cannot read file: \(url.lastPathComponent)")
        }
        
        let resourceValues = try? url.resourceValues(forKeys: [.isWritableKey, .isReadableKey, .volumeIsReadOnlyKey])
        
        if resourceValues?.volumeIsReadOnly == true {
            return (false, "Volume is read-only for: \(url.lastPathComponent)")
        }
        
        return (true, nil)
    }
    
    private func checkDestinationWritable(at url: URL) -> (writable: Bool, issue: String?) {
        let parentDir = url.deletingLastPathComponent()
        let parentPath = parentDir.path
        
        if fileManager.fileExists(atPath: parentPath) {
            guard fileManager.isWritableFile(atPath: parentPath) else {
                return (false, "Cannot write to destination folder: \(parentDir.lastPathComponent)")
            }
        } else {
            var ancestorPath = parentPath
            while !fileManager.fileExists(atPath: ancestorPath) && ancestorPath != "/" {
                ancestorPath = (ancestorPath as NSString).deletingLastPathComponent
            }
            guard fileManager.isWritableFile(atPath: ancestorPath) else {
                return (false, "Cannot create destination folder: \(parentDir.lastPathComponent)")
            }
        }
        
        return (true, nil)
    }
    
    func preValidatePlan(_ plan: OrganizationPlan, at baseURL: URL) async -> [String] {
        var issues: [String] = []
        
        let baseCheck = checkDestinationWritable(at: baseURL)
        if !baseCheck.writable, let issue = baseCheck.issue {
            issues.append(issue)
        }
        
        for suggestion in plan.suggestions {
            let suggestionIssues = await preValidateSuggestion(suggestion, parentURL: baseURL)
            issues.append(contentsOf: suggestionIssues)
        }

        var capacityRequirements: [String: DestinationCapacityRequirement] = [:]
        for suggestion in plan.suggestions {
            collectDestinationCapacityRequirements(
                for: suggestion,
                parentURL: baseURL,
                requirements: &capacityRequirements
            )
        }
        for requirement in capacityRequirements.values {
            guard let availableBytes = availableCapacity(at: requirement.destinationURL),
                  availableBytes < requirement.requiredBytes else {
                continue
            }
            issues.append(
                "Not enough free space on \(requirement.volumeName): needs \(Self.formattedByteCount(requirement.requiredBytes)), but only \(Self.formattedByteCount(availableBytes)) is available"
            )
        }
        
        return issues
    }

    private struct DestinationCapacityRequirement {
        let destinationURL: URL
        let volumeName: String
        var requiredBytes: Int64
    }

    private func collectDestinationCapacityRequirements(
        for suggestion: FolderSuggestion,
        parentURL: URL,
        requirements: inout [String: DestinationCapacityRequirement]
    ) {
        guard let folderURL = try? resolveDestinationFolderURL(
            folderName: suggestion.folderName,
            parentURL: parentURL,
            requestSecurityScope: false
        ) else {
            return
        }

        for file in suggestion.files {
            guard let sourceURL = file.url,
                  fileManager.fileExists(atPath: sourceURL.path),
                  isCrossVolume(from: sourceURL, to: folderURL) else {
                continue
            }
            let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? max(file.size, 0)
            let volume = destinationVolume(for: folderURL)
            if var existing = requirements[volume.key] {
                existing.requiredBytes += size
                requirements[volume.key] = existing
            } else {
                requirements[volume.key] = DestinationCapacityRequirement(
                    destinationURL: folderURL,
                    volumeName: volume.name,
                    requiredBytes: size
                )
            }
        }

        for subfolder in suggestion.subfolders {
            collectDestinationCapacityRequirements(
                for: subfolder,
                parentURL: folderURL,
                requirements: &requirements
            )
        }
    }

    private func destinationVolume(for url: URL) -> (key: String, name: String) {
        var existingURL = url
        while !fileManager.fileExists(atPath: existingURL.path), existingURL.path != "/" {
            existingURL.deleteLastPathComponent()
        }
        let values = try? existingURL.resourceValues(forKeys: [.volumeURLKey, .volumeNameKey])
        let volumeURL = values?.volume ?? existingURL
        return (
            key: volumeURL.standardizedFileURL.path,
            name: values?.volumeName ?? volumeURL.lastPathComponent
        )
    }

    private func availableCapacity(at url: URL) -> Int64? {
        #if DEBUG
        if let availableCapacityOverride {
            return availableCapacityOverride(url)
        }
        #endif

        var existingURL = url
        while !fileManager.fileExists(atPath: existingURL.path), existingURL.path != "/" {
            existingURL.deleteLastPathComponent()
        }
        return try? existingURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
    }

    private static func formattedByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    private func preValidateSuggestion(_ suggestion: FolderSuggestion, parentURL: URL) async -> [String] {
        var issues: [String] = []
        
        let folderURL: URL
        do {
            folderURL = try resolveDestinationFolderURL(
                folderName: suggestion.folderName,
                parentURL: parentURL,
                requestSecurityScope: false
            )
        } catch {
            issues.append(error.localizedDescription)
            return issues
        }

        let destinationCheck = checkDestinationWritable(at: folderURL)
        if !destinationCheck.writable, let issue = destinationCheck.issue {
            issues.append(issue)
        }

        let requestsFinderMetadata = !suggestion.tags.isEmpty
            || suggestion.comment?.isEmpty == false
            || suggestion.fileTagMappings.contains { mapping in
                !mapping.tags.isEmpty || mapping.comment?.isEmpty == false
            }
        if requestsFinderMetadata {
            let profile = StorageEnvironmentInspector.profile(for: folderURL)
            if !profile.supportedFileSystemActions.contains(.finderTags) {
                issues.append(
                    "\(profile.provider.displayName) does not support Finder tags or comments through its mounted folder: \(folderURL.lastPathComponent)"
                )
            }
        }
        
        for file in suggestion.files {
            guard let sourceURL = file.url else { continue }
            
            let sourceCheck = checkFileAccessibility(at: sourceURL)
            if !sourceCheck.accessible, let issue = sourceCheck.issue {
                issues.append(issue)
            }
        }
        
        for subfolder in suggestion.subfolders {
            let subIssues = await preValidateSuggestion(subfolder, parentURL: folderURL)
            issues.append(contentsOf: subIssues)
        }
        
        return issues
    }

    // MARK: - Helpers

    /// Generate a unique filename by appending a counter. Capped so a densely
    /// populated directory cannot spin forever; throws after the cap.
    private func generateUniqueURL(for url: URL) throws -> URL {
        var reserved = Set<String>()
        return try uniqueDestinationURL(for: url, reserved: &reserved)
    }

    /// Reservation key for a destination path. Lowercased because the common
    /// macOS volumes are case-insensitive: `Report.pdf` and `report.pdf`
    /// collide on disk even though the strings differ.
    private func reservedDestinationKey(for url: URL) -> String {
        normalizedPath(url.path).lowercased()
    }

    /// Returns an available destination, checking both the disk and the
    /// intra-batch reservation set, and reserves the result. Two files in one
    /// plan targeting the same name therefore land on different paths instead
    /// of the second silently overwriting (or failing on) the first.
    private func uniqueDestinationURL(for url: URL, reserved: inout Set<String>) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let filename = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        var candidate = url
        var counter = 0
        while fileManager.fileExists(atPath: candidate.path)
            || reserved.contains(reservedDestinationKey(for: candidate)) {
            counter += 1
            guard counter <= Self.maximumUniqueNameAttempts else {
                throw FileSystemError.uniqueNameExhausted(url.lastPathComponent)
            }
            let newName = ext.isEmpty ? "\(filename)_\(counter)" : "\(filename)_\(counter).\(ext)"
            candidate = directory.appendingPathComponent(newName)
        }

        reserved.insert(reservedDestinationKey(for: candidate))
        return candidate
    }

    /// Moves a file, uniquifying against disk + batch reservations and
    /// retrying when another process wins a check-then-act race
    /// (`fileWriteFileExists`/`EEXIST` on the move itself). Returns the actual
    /// destination used, which callers record so the plan's preview never
    /// silently disagrees with what landed on disk.
    private func moveFileResolvingConflicts(
        from sourceURL: URL,
        proposedDestination: URL,
        reserved: inout Set<String>
    ) async throws -> URL {
        var destination = try uniqueDestinationURL(for: proposedDestination, reserved: &reserved)
        var attempts = 0
        while true {
            do {
                if isCrossVolume(from: sourceURL, to: destination) {
                    DebugLogger.log("Cross-volume move detected: \(sourceURL.path) → \(destination.path)")
                    let fileName = sourceURL.lastPathComponent
                    let handler = crossVolumeProgressHandler
                    try await copyWithProgress(from: sourceURL, to: destination) { progress in
                        handler?(fileName, progress)
                    }
                } else {
                    try await withRetry {
                        try fileManager.moveItem(at: sourceURL, to: destination)
                    }
                }
                return destination
            } catch {
                guard isFileExistsError(error), attempts < Self.conflictingMoveRetryAttempts else {
                    throw error
                }
                attempts += 1
                destination = try uniqueDestinationURL(for: proposedDestination, reserved: &reserved)
            }
        }
    }
}

// MARK: - Errors

enum FileSystemError: LocalizedError {
    case fileNotFound(path: String? = nil, underlyingErrno: Int32? = nil)
    case permissionDenied(path: String? = nil, underlyingErrno: Int32? = nil)
    case diskFull(path: String?, underlyingErrno: Int32?)
    case readOnlyFileSystem(path: String?, underlyingErrno: Int32?)
    case quotaExceeded(path: String?, underlyingErrno: Int32?)
    case uniqueNameExhausted(String)
    case partialFailure(successCount: Int, failures: [OperationFailure])
    case partialApplyFailure(operations: [FileSystemManager.FileOperation], underlyingDescription: String)
    case preValidationFailed([String])
    case crossVolumeCopyVerificationFailed(String)
    case destinationEscapesBaseDirectory(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path, let errnoValue):
            var message = path.map { "File not found: \($0)" } ?? "File not found"
            if let errnoValue { message += " (errno \(errnoValue))" }
            return message
        case .permissionDenied(let path, let errnoValue):
            var message = path.map { "Permission denied: \($0)" } ?? "Permission denied"
            if let errnoValue { message += " (errno \(errnoValue))" }
            return message
        case .diskFull(let path, _):
            return path.map { "Disk is full while writing: \($0)" } ?? "Disk is full"
        case .readOnlyFileSystem(let path, _):
            return path.map { "Destination is on a read-only volume: \($0)" } ?? "Destination is on a read-only volume"
        case .quotaExceeded(let path, _):
            return path.map { "Storage quota exceeded while writing: \($0)" } ?? "Storage quota exceeded"
        case .uniqueNameExhausted(let name):
            return "Could not find an available name for \(name) after \(FileSystemManager.maximumUniqueNameAttempts) attempts"
        case .partialFailure(let successCount, let failures):
            return "Partial failure: \(successCount) succeeded, \(failures.count) failed"
        case .partialApplyFailure(let operations, let underlyingDescription):
            return "Organization stopped after \(operations.count) completed operation(s): \(underlyingDescription)"
        case .preValidationFailed(let issues):
            return "Pre-validation failed: \(issues.joined(separator: ", "))"
        case .crossVolumeCopyVerificationFailed(let path):
            return "Cross-volume copy verification failed for: \(path)"
        case .destinationEscapesBaseDirectory(let path):
            return "Destination folder resolves outside the selected directory: \(path)"
        }
    }
}

public struct OperationFailure: Sendable {
    public let sourcePath: String
    public let destinationPath: String?
    public let error: String
    public let isRetryable: Bool
}

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
