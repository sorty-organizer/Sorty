import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

// MARK: - Flattened Row Model

struct FlattenedRow: Identifiable, Equatable {
    let id: String
    let depth: Int
    let type: RowType
    let isExpanded: Bool

    enum RowType: Equatable {
        case folder(FolderSuggestion)
        case file(FileItem, parentFolderID: UUID)
        case unorganizedHeader
        case unorganizedFile(FileItem)
        case remainingFiles(count: Int)
    }
    
    static func == (lhs: FlattenedRow, rhs: FlattenedRow) -> Bool {
        lhs.id == rhs.id && lhs.depth == rhs.depth && lhs.isExpanded == rhs.isExpanded && lhs.type == rhs.type
    }
}

struct PreviewMoveDestination: Identifiable, Equatable {
    let id: UUID
    let name: String
}

enum PreviewRowPresentation: Equatable {
    case folder(
        row: FlattenedRow,
        tags: [String],
        comment: String?,
        fileCount: Int
    )
    case file(
        row: FlattenedRow,
        renameMapping: FileRenameMapping?,
        tags: [String],
        comment: String?,
        duplicateInfo: DuplicateInfo?,
        parentSuggestion: FolderSuggestion?,
        isHighlighted: Bool
    )
    case unorganizedHeader(row: FlattenedRow, fileCount: Int)
    case unorganizedFile(
        row: FlattenedRow,
        duplicateInfo: DuplicateInfo?,
        isHighlighted: Bool,
        moveDestinations: [PreviewMoveDestination]
    )
    case remaining(row: FlattenedRow, count: Int)
}

// MARK: - Preview Store

@MainActor
class PreviewStore: ObservableObject {
    private static let automaticExpansionFileLimit = 2_000
    private static let renderedFilesPerSectionLimit = 500
    static let unorganizedSectionID = "unorganized-header"

    @Published private(set) var flattenedRows: [FlattenedRow] = []
    @Published private(set) var plan: OrganizationPlan
    @Published var expandedFolders: Set<String> = []
    @Published var highlightedFileID: UUID? = nil
    
    /// Pre-computed rename mappings to avoid expensive lookups during rendering
    @Published private(set) var renameMappings: [UUID: FileRenameMapping] = [:]
    
    @Published private(set) var tagMappings: [UUID: [String]] = [:]
    @Published private(set) var folderTagMappings: [UUID: [String]] = [:]
    @Published private(set) var folderCommentMappings: [UUID: String] = [:]
    @Published private(set) var fileCommentMappings: [UUID: String] = [:]

    /// Duplicate file mappings - maps file ID to its duplicate info
    @Published private(set) var duplicateMappings: [UUID: DuplicateInfo] = [:]
    
    /// Count of user edits captured for learning this session (moves, rejections, renames)
    @Published private(set) var editsCapturedCount: Int = 0
    
    /// Triggers a brief pulse animation when a new edit is captured
    @Published private(set) var editCapturedPulse: Bool = false
    
    /// Cached folder counts to avoid recalculation during scrolling
    private var folderCountCache: [UUID: Int] = [:]
    private var folderCountCacheValid = false
    
    /// Throttled file count display to prevent excessive UI updates
    @Published private(set) var throttledTotalFileCount: Int = 0
    
    private var folderIDToPath: [UUID: String] = [:]
    private var knownFolderIDs: Set<String> = []
    
    /// Plan version tracking for cache invalidation
    private var cachedPlanVersion: Int = -1
    private var cachedMoveDestinations: [PreviewMoveDestination] = []
    
    /// Cached row presentations keyed by row id. presentation(for:) runs per
    /// row on every tree body evaluation; without this, tags, comments, and
    /// counts rebuild for rows that didn't change. Cleared whenever the
    /// visible rows or their metadata refresh.
    private var presentationCache: [String: (planVersion: Int, highlighted: Bool, presentation: PreviewRowPresentation)] = [:]

    /// Throttling support
    private var throttleWorkItem: DispatchWorkItem?
    private let throttleInterval: TimeInterval = 0.2 // 200ms
    
    /// Weak reference to learnings manager for recording user actions in the preview
    weak var learningsManager: LearningsManager?
    
    init(plan: OrganizationPlan) {
        self.plan = plan
        cachedMoveDestinations = Self.collectMoveDestinations(from: plan.suggestions)
        expandAllFolders()
        rebuildFlattenedRows()
        cachedPlanVersion = plan.version
        throttledTotalFileCount = plan.totalFiles
    }
    
    func updatePlan(_ newPlan: OrganizationPlan) {
        guard newPlan != plan else { return }

        // Identity and version are the normal revision signal. Equality keeps
        // malformed same-version updates correct while allowing exact repeats
        // to return above without publishing or rebuilding rows.
        self.plan = newPlan

        cachedMoveDestinations = Self.collectMoveDestinations(from: newPlan.suggestions)
        refreshExpandedFolders(for: newPlan)
        folderCountCache.removeAll()
        folderCountCacheValid = false
        updateThrottledFileCount()
        
        rebuildFlattenedRows()
        cachedPlanVersion = newPlan.version
    }
    
    /// Get cached file count for a folder (avoids recalculation during scrolling)
    func getCachedFileCount(for folderID: UUID, compute: () -> Int) -> Int {
        if folderCountCacheValid, let cached = folderCountCache[folderID] {
            return cached
        }
        let count = compute()
        folderCountCache[folderID] = count
        folderCountCacheValid = true
        return count
    }
    
    /// Update file count with throttling to prevent excessive UI updates
    private func updateThrottledFileCount() {
        // Cancel any pending update
        throttleWorkItem?.cancel()
        
        // Create new work item
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.throttledTotalFileCount = self.plan.totalFiles
        }
        
        throttleWorkItem = workItem
        
        // Schedule update after throttle interval
        DispatchQueue.main.asyncAfter(deadline: .now() + throttleInterval, execute: workItem)
        
        // Immediately update for the first change or if significant
        if throttledTotalFileCount == 0 || abs(plan.totalFiles - throttledTotalFileCount) > 100 {
            throttledTotalFileCount = plan.totalFiles
            workItem.cancel()
        }
    }
    
    /// Record that a user edit was captured for learning
    /// Increments counter and triggers a brief pulse animation
    private func recordEditCaptured() {
        guard learningsManager?.consentManager.canCollectData == true else { return }
        guard learningsManager?.sessionLearningPaused != true else { return }
        editsCapturedCount += 1
        
        // Trigger pulse animation
        withAnimation(.easeOut(duration: 0.15)) {
            editCapturedPulse = true
        }
        
        // Reset pulse after brief delay
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            withAnimation(.easeIn(duration: 0.1)) {
                editCapturedPulse = false
            }
        }
    }
    
    /// Reset edit capture count (called when plan resets or regenerates)
    func resetEditsCaptured() {
        editsCapturedCount = 0
        editCapturedPulse = false
    }
    
    private func expandAllFolders() {
        var ids = collectFolderIDs(from: plan)
        if plan.unorganizedFiles.count > 8 {
            ids.remove(Self.unorganizedSectionID)
        }
        expandedFolders = plan.totalFiles <= Self.automaticExpansionFileLimit ? ids : []
        knownFolderIDs = ids
    }

    private func refreshExpandedFolders(for plan: OrganizationPlan) {
        let currentIDs = collectFolderIDs(from: plan)
        let newIDs = currentIDs.subtracting(knownFolderIDs)
        expandedFolders = expandedFolders.intersection(currentIDs)
        if plan.totalFiles <= Self.automaticExpansionFileLimit {
            expandedFolders.formUnion(newIDs)
        }
        if plan.unorganizedFiles.count > 8, newIDs.contains(Self.unorganizedSectionID) {
            expandedFolders.remove(Self.unorganizedSectionID)
        }
        knownFolderIDs = currentIDs
    }

    private func collectFolderIDs(from plan: OrganizationPlan) -> Set<String> {
        var ids = Set<String>()
        func traverse(_ folder: FolderSuggestion) {
            ids.insert(folder.id.uuidString)
            for sub in folder.subfolders {
                traverse(sub)
            }
        }
        for suggestion in plan.suggestions {
            traverse(suggestion)
        }
        if !plan.unorganizedFiles.isEmpty {
            ids.insert(Self.unorganizedSectionID)
        }
        return ids
    }
    
    private var lastExpandedFolders: Set<String> = []
    private var lastPlanID: UUID?
    
    private func rebuildFlattenedRows() {
        let planChanged = cachedPlanVersion != plan.version || lastPlanID != plan.id

        if !planChanged && expandedFolders == lastExpandedFolders {
            return
        }
        lastPlanID = plan.id
        lastExpandedFolders = expandedFolders
        presentationCache.removeAll(keepingCapacity: true)

        var rows: [FlattenedRow] = []
        var visibleFiles: [FileItem] = []
        visibleFiles.reserveCapacity(min(plan.totalFiles, Self.renderedFilesPerSectionLimit))

        func processFolder(_ folder: FolderSuggestion, depth: Int) {
            let id = folder.id.uuidString
            let isExpanded = expandedFolders.contains(id)
            
            rows.append(FlattenedRow(
                id: id,
                depth: depth,
                type: .folder(folder),
                isExpanded: isExpanded
            ))
            
            if isExpanded {
                // Add subfolders
                for subfolder in folder.subfolders {
                    processFolder(subfolder, depth: depth + 1)
                }
                
                // Add files
                let visibleFileCount = min(folder.files.count, Self.renderedFilesPerSectionLimit)
                for file in folder.files.prefix(visibleFileCount) {
                    visibleFiles.append(file)
                    rows.append(FlattenedRow(
                        id: "\(folder.id.uuidString)-\(file.id.uuidString)",
                        depth: depth + 1,
                        type: .file(file, parentFolderID: folder.id),
                        isExpanded: false
                    ))
                }
                if folder.files.count > visibleFileCount {
                    rows.append(FlattenedRow(
                        id: "\(folder.id.uuidString)-remaining",
                        depth: depth + 1,
                        type: .remainingFiles(count: folder.files.count - visibleFileCount),
                        isExpanded: false
                    ))
                }
            }
        }
        
        for suggestion in plan.suggestions {
            processFolder(suggestion, depth: 0)
        }
        
        if !plan.unorganizedFiles.isEmpty {
            let isExpanded = expandedFolders.contains(Self.unorganizedSectionID)
            rows.append(FlattenedRow(
                id: Self.unorganizedSectionID,
                depth: 0,
                type: .unorganizedHeader,
                isExpanded: isExpanded
            ))

            if isExpanded {
                let visibleFileCount = min(plan.unorganizedFiles.count, Self.renderedFilesPerSectionLimit)
                for file in plan.unorganizedFiles.prefix(visibleFileCount) {
                    visibleFiles.append(file)
                    rows.append(FlattenedRow(
                        id: "unorganized-\(file.id.uuidString)",
                        depth: 1,
                        type: .unorganizedFile(file),
                        isExpanded: false
                    ))
                }
                if plan.unorganizedFiles.count > visibleFileCount {
                    rows.append(FlattenedRow(
                        id: "unorganized-remaining",
                        depth: 1,
                        type: .remainingFiles(count: plan.unorganizedFiles.count - visibleFileCount),
                        isExpanded: false
                    ))
                }
            }
        }

        var tagsByFolderID: [UUID: [String]] = [:]
        var commentsByFolderID: [UUID: String] = [:]

        func cacheFolderMetadata(for folder: FolderSuggestion) {
            if !folder.tags.isEmpty {
                tagsByFolderID[folder.id] = folder.tags
            }
            if let comment = folder.comment, !comment.isEmpty {
                commentsByFolderID[folder.id] = comment
            }
            for subfolder in folder.subfolders {
                cacheFolderMetadata(for: subfolder)
            }
        }

        for suggestion in plan.suggestions {
            cacheFolderMetadata(for: suggestion)
        }

        self.folderTagMappings = tagsByFolderID
        self.folderCommentMappings = commentsByFolderID
        refreshVisibleFileMetadata(visibleFiles)
        self.duplicateMappings = computeDuplicateMappings(for: visibleFiles)
        self.flattenedRows = rows
    }

    private func refreshVisibleFileMetadata(_ visibleFiles: [FileItem]) {
        let visibleFileIDs = Set(visibleFiles.map(\.id))
        var visibleRenames: [UUID: FileRenameMapping] = [:]
        var visibleTags: [UUID: [String]] = [:]
        var visibleComments: [UUID: String] = [:]

        func collect(from folder: FolderSuggestion) {
            for mapping in folder.fileRenameMappings where visibleFileIDs.contains(mapping.originalFile.id) {
                visibleRenames[mapping.originalFile.id] = mapping
            }
            for mapping in folder.fileTagMappings where visibleFileIDs.contains(mapping.originalFile.id) {
                visibleTags[mapping.originalFile.id] = mapping.tags
                if let comment = mapping.comment, !comment.isEmpty {
                    visibleComments[mapping.originalFile.id] = comment
                }
            }
            for subfolder in folder.subfolders {
                collect(from: subfolder)
            }
        }

        for suggestion in plan.suggestions {
            collect(from: suggestion)
        }
        renameMappings = visibleRenames
        tagMappings = visibleTags
        fileCommentMappings = visibleComments
    }

    /// Computes duplicate mappings by grouping files with the same hash
    private func computeDuplicateMappings(for visibleFiles: [FileItem]) -> [UUID: DuplicateInfo] {
        // Group by hash (only files that have a hash)
        var hashGroups: [String: [FileItem]] = [:]
        for file in visibleFiles {
            guard let hash = file.sha256Hash, !hash.isEmpty else { continue }
            hashGroups[hash, default: []].append(file)
        }

        // Create duplicate info for files that have duplicates
        var duplicateInfo: [UUID: DuplicateInfo] = [:]
        for (_, files) in hashGroups where files.count > 1 {
            for file in files {
                duplicateInfo[file.id] = DuplicateInfo(
                    file: file,
                    sharedGroup: files,
                    isExactMatch: true,
                    similarity: 1.0
                )
            }
        }

        return duplicateInfo
    }

    func presentation(for row: FlattenedRow) -> PreviewRowPresentation {
        let highlighted = isRowHighlighted(row)
        if let cached = presentationCache[row.id],
           cached.planVersion == plan.version, cached.highlighted == highlighted {
            return cached.presentation
        }
        let built = buildPresentation(for: row)
        presentationCache[row.id] = (plan.version, highlighted, built)
        return built
    }

    private func isRowHighlighted(_ row: FlattenedRow) -> Bool {
        switch row.type {
        case .file(let file, _), .unorganizedFile(let file):
            return highlightedFileID == file.id
        case .folder, .unorganizedHeader, .remainingFiles:
            return false
        }
    }

    private func buildPresentation(for row: FlattenedRow) -> PreviewRowPresentation {
        switch row.type {
        case .folder(let suggestion):
            return .folder(
                row: row,
                tags: folderTagMappings[suggestion.id] ?? [],
                comment: folderCommentMappings[suggestion.id],
                fileCount: getCachedFileCount(for: suggestion.id) { suggestion.totalFileCount }
            )
        case .file(let file, let parentFolderID):
            let visibleTags = (tagMappings[file.id] ?? []).filter {
                $0.lowercased() != "duplicate"
            }
            return .file(
                row: row,
                renameMapping: renameMappings[file.id],
                tags: visibleTags,
                comment: fileCommentMappings[file.id],
                duplicateInfo: duplicateMappings[file.id],
                parentSuggestion: folderSuggestion(for: parentFolderID),
                isHighlighted: highlightedFileID == file.id
            )
        case .unorganizedHeader:
            return .unorganizedHeader(row: row, fileCount: plan.unorganizedFiles.count)
        case .unorganizedFile(let file):
            return .unorganizedFile(
                row: row,
                duplicateInfo: duplicateMappings[file.id],
                isHighlighted: highlightedFileID == file.id,
                moveDestinations: moveDestinations
            )
        case .remainingFiles(let count):
            return .remaining(row: row, count: count)
        }
    }

    private func buildChildRows(for folder: FolderSuggestion, depth: Int) -> [FlattenedRow] {
        var rows: [FlattenedRow] = []

        for subfolder in folder.subfolders {
            let id = subfolder.id.uuidString
            let isExpanded = expandedFolders.contains(id)

            rows.append(FlattenedRow(
                id: id,
                depth: depth,
                type: .folder(subfolder),
                isExpanded: isExpanded
            ))

            if isExpanded {
                rows.append(contentsOf: buildChildRows(for: subfolder, depth: depth + 1))
            }
        }

        let visibleFileCount = min(folder.files.count, Self.renderedFilesPerSectionLimit)
        for file in folder.files.prefix(visibleFileCount) {
            rows.append(FlattenedRow(
                id: "\(folder.id.uuidString)-\(file.id.uuidString)",
                depth: depth,
                type: .file(file, parentFolderID: folder.id),
                isExpanded: false
            ))
        }
        if folder.files.count > visibleFileCount {
            rows.append(FlattenedRow(
                id: "\(folder.id.uuidString)-remaining",
                depth: depth,
                type: .remainingFiles(count: folder.files.count - visibleFileCount),
                isExpanded: false
            ))
        }

        return rows
    }

    private func applyIncrementalToggle(id: String, wasExpanded: Bool) -> Bool {
        guard let rowIndex = flattenedRows.firstIndex(where: { $0.id == id }) else { return false }
        guard case .folder(let folder) = flattenedRows[rowIndex].type else { return false }

        let depth = flattenedRows[rowIndex].depth

        if wasExpanded {
            var removalIndex = rowIndex + 1
            while removalIndex < flattenedRows.count, flattenedRows[removalIndex].depth > depth {
                removalIndex += 1
            }
            if removalIndex > rowIndex + 1 {
                flattenedRows.removeSubrange((rowIndex + 1)..<removalIndex)
            }
            flattenedRows[rowIndex] = FlattenedRow(
                id: id,
                depth: depth,
                type: .folder(folder),
                isExpanded: false
            )
            return true
        } else {
            let childRows = buildChildRows(for: folder, depth: depth + 1)
            flattenedRows[rowIndex] = FlattenedRow(
                id: id,
                depth: depth,
                type: .folder(folder),
                isExpanded: true
            )
            if !childRows.isEmpty {
                flattenedRows.insert(contentsOf: childRows, at: rowIndex + 1)
            }
            return true
        }
    }
    
    func toggleFolder(id: String) {
        let wasExpanded = expandedFolders.contains(id)
        if wasExpanded {
            expandedFolders.remove(id)
        } else {
            expandedFolders.insert(id)
        }

        if cachedPlanVersion == plan.version, applyIncrementalToggle(id: id, wasExpanded: wasExpanded) {
            lastExpandedFolders = expandedFolders
            presentationCache.removeAll(keepingCapacity: true)
            let visibleFiles = visibleFilesInRows()
            refreshVisibleFileMetadata(visibleFiles)
            duplicateMappings = computeDuplicateMappings(for: visibleFiles)
        } else {
            rebuildFlattenedRows()
        }
    }

    private func visibleFilesInRows() -> [FileItem] {
        flattenedRows.compactMap { row in
            switch row.type {
            case .file(let file, _), .unorganizedFile(let file):
                return file
            case .folder, .unorganizedHeader, .remainingFiles:
                return nil
            }
        }
    }

    func revealFileAndResolveRowID(_ fileID: UUID) -> String? {
        var didExpandAnyFolder = false

        if let folderPath = folderPathForFile(fileID: fileID) {
            for folderID in folderPath {
                let folderRowID = folderID.uuidString
                if !expandedFolders.contains(folderRowID) {
                    expandedFolders.insert(folderRowID)
                    didExpandAnyFolder = true
                }
            }
        }

        if didExpandAnyFolder {
            rebuildFlattenedRows()
        }

        return flattenedRows.first { row in
            switch row.type {
            case .file(let file, _):
                return file.id == fileID
            case .unorganizedFile(let file):
                return file.id == fileID
            case .folder, .unorganizedHeader, .remainingFiles:
                return false
            }
        }?.id
    }

    func folderSuggestion(for folderID: UUID) -> FolderSuggestion? {
        for suggestion in plan.suggestions {
            if let matched = folderSuggestion(for: folderID, in: suggestion) {
                return matched
            }
        }
        return nil
    }

    var moveDestinations: [PreviewMoveDestination] {
        cachedMoveDestinations
    }

    private static func collectMoveDestinations(
        from folders: [FolderSuggestion]
    ) -> [PreviewMoveDestination] {
        func collect(_ folders: [FolderSuggestion], parentPath: String) -> [PreviewMoveDestination] {
            folders.flatMap { folder in
                let path = parentPath.isEmpty ? folder.folderName : "\(parentPath)/\(folder.folderName)"
                return [PreviewMoveDestination(id: folder.id, name: path)]
                    + collect(folder.subfolders, parentPath: path)
            }
        }
        return collect(folders, parentPath: "")
    }
    
    func moveFileToUnorganized(fileID: UUID) {
        guard let file = findFile(by: fileID) else { return }
        
        // Record rejection before mutating the plan
        learningsManager?.recordRejection(originalPath: file.path)
        if let ruleID = attributedRuleID(for: fileID) {
            learningsManager?.recordRuleFailure(ruleId: ruleID)
        }
        recordEditCaptured()
        
        var updatedPlan = plan
        for i in 0..<updatedPlan.suggestions.count {
            updatedPlan.suggestions[i] = removeFileFromFolder(file, from: updatedPlan.suggestions[i])
        }
        
        if !updatedPlan.unorganizedFiles.contains(where: { $0.id == fileID }) {
            updatedPlan.unorganizedFiles.append(file)
        }
        
        updateInternalPlan(updatedPlan)
    }

    private func attributedRuleID(for fileID: UUID) -> String? {
        func find(in folder: FolderSuggestion) -> String? {
            if folder.files.contains(where: { $0.id == fileID }) {
                return folder.ruleId
            }
            return folder.subfolders.lazy.compactMap(find).first
        }

        return plan.suggestions.lazy.compactMap(find).first
    }
    
    func updateRename(fileID: UUID, folderID: UUID, newName: String) {
        // Record rename edit before mutating the plan
        if let file = findFile(by: fileID),
           let mapping = renameMappings[fileID], mapping.hasRename {
            learningsManager?.recordRenameFeedback(
                originalName: file.displayName,
                suggestedName: mapping.suggestedName,
                finalName: newName,
                folderPath: folderIDToPath[folderID],
                action: .edit,
                confidence: mapping.renameConfidence
            )
            recordEditCaptured()
        }
        
        var updatedPlan = plan
        for i in 0..<updatedPlan.suggestions.count {
            if let updated = updateRenameInFolder(updatedPlan.suggestions[i], targetID: folderID, fileID: fileID, newName: newName) {
                updatedPlan.suggestions[i] = updated
                updateInternalPlan(updatedPlan)
                return
            }
        }
    }
    
    func rejectRename(fileID: UUID, folderID: UUID) {
        // Record rename rejection before mutating the plan
        if let file = findFile(by: fileID),
           let mapping = renameMappings[fileID], mapping.hasRename {
            learningsManager?.recordRenameFeedback(
                originalName: file.displayName,
                suggestedName: mapping.suggestedName,
                finalName: nil,
                folderPath: folderIDToPath[folderID],
                action: .reject,
                confidence: mapping.renameConfidence
            )
            recordEditCaptured()
        }
        
        var updatedPlan = plan
        for i in 0..<updatedPlan.suggestions.count {
            if let updated = rejectRenameInFolder(updatedPlan.suggestions[i], targetID: folderID, fileID: fileID) {
                updatedPlan.suggestions[i] = updated
                updateInternalPlan(updatedPlan)
                return
            }
        }
    }

    func setRenameSelected(fileID: UUID, folderID: UUID, isSelected: Bool) {
        var updatedPlan = plan
        for i in 0..<updatedPlan.suggestions.count {
            guard updatedPlan.suggestions[i].id == folderID else { continue }
            updatedPlan.suggestions[i].setRenameSelected(for: fileID, isSelected: isSelected)
            updateInternalPlan(updatedPlan)
            return
        }
        // Fallback: search nested folders
        for i in 0..<updatedPlan.suggestions.count {
            if let updated = setRenameSelectedInFolder(
                updatedPlan.suggestions[i], targetID: folderID, fileID: fileID, isSelected: isSelected
            ) {
                updatedPlan.suggestions[i] = updated
                updateInternalPlan(updatedPlan)
                return
            }
        }
    }

    private func setRenameSelectedInFolder(
        _ folder: FolderSuggestion, targetID: UUID, fileID: UUID, isSelected: Bool
    ) -> FolderSuggestion? {
        if folder.id == targetID {
            var copy = folder
            copy.setRenameSelected(for: fileID, isSelected: isSelected)
            return copy
        }
        var copy = folder
        for idx in copy.subfolders.indices {
            if let updated = setRenameSelectedInFolder(
                copy.subfolders[idx], targetID: targetID, fileID: fileID, isSelected: isSelected
            ) {
                copy.subfolders[idx] = updated
                return copy
            }
        }
        return nil
    }
    
    func revertFolderOrganization(folderID: UUID) {
        var updatedPlan = plan
        var filesToMove: [FileItem] = []
        
        func collectFilesFromFolder(_ folder: FolderSuggestion) {
            filesToMove.append(contentsOf: folder.files)
            for subfolder in folder.subfolders {
                collectFilesFromFolder(subfolder)
            }
        }
        
        for i in 0..<updatedPlan.suggestions.count {
            if let folder = findFolderByID(folderID, in: updatedPlan.suggestions[i]) {
                collectFilesFromFolder(folder)
                updatedPlan.suggestions[i] = removeFolderFromSuggestion(updatedPlan.suggestions[i], targetID: folderID)
                break
            }
        }
        
        // Record rejections for all files being reverted from this folder
        for file in filesToMove {
            learningsManager?.recordRejection(originalPath: file.path)
        }
        
        updatedPlan.suggestions.removeAll { $0.files.isEmpty && $0.subfolders.isEmpty && $0.id == folderID }
        
        for file in filesToMove {
            if !updatedPlan.unorganizedFiles.contains(where: { $0.id == file.id }) {
                updatedPlan.unorganizedFiles.append(file)
            }
        }
        
        updateInternalPlan(updatedPlan)
    }

    func updateFolderDestination(folderID: UUID, newDestinationPath: String) {
        let canonicalPath = StorageLocationPathResolver.canonicalPath(newDestinationPath)
        var updatedPlan = plan

        for i in 0..<updatedPlan.suggestions.count {
            if let updated = updateDestinationInFolder(updatedPlan.suggestions[i], targetID: folderID, newDestinationPath: canonicalPath) {
                updatedPlan.suggestions[i] = updated
                updateInternalPlan(updatedPlan)
                return
            }
        }
    }
    
    private func findFolderByID(_ id: UUID, in folder: FolderSuggestion) -> FolderSuggestion? {
        if folder.id == id { return folder }
        for subfolder in folder.subfolders {
            if let found = findFolderByID(id, in: subfolder) { return found }
        }
        return nil
    }
    
    private func removeFolderFromSuggestion(_ folder: FolderSuggestion, targetID: UUID) -> FolderSuggestion {
        var updatedFolder = folder
        updatedFolder.subfolders.removeAll { $0.id == targetID }
        updatedFolder.subfolders = updatedFolder.subfolders.map { removeFolderFromSuggestion($0, targetID: targetID) }
        return updatedFolder
    }
    
    private func updateRenameInFolder(_ folder: FolderSuggestion, targetID: UUID, fileID: UUID, newName: String) -> FolderSuggestion? {
        var updatedFolder = folder
        if folder.id == targetID {
            if let file = updatedFolder.files.first(where: { $0.id == fileID }) {
                updatedFolder.updateRename(for: file, newName: newName)
                return updatedFolder
            }
        }
        
        for i in 0..<updatedFolder.subfolders.count {
            if let updated = updateRenameInFolder(updatedFolder.subfolders[i], targetID: targetID, fileID: fileID, newName: newName) {
                updatedFolder.subfolders[i] = updated
                return updatedFolder
            }
        }
        return nil
    }
    
    private func rejectRenameInFolder(_ folder: FolderSuggestion, targetID: UUID, fileID: UUID) -> FolderSuggestion? {
        var updatedFolder = folder
        if folder.id == targetID {
            if let file = updatedFolder.files.first(where: { $0.id == fileID }) {
                updatedFolder.updateRename(for: file, newName: nil)
                return updatedFolder
            }
        }
        
        for i in 0..<updatedFolder.subfolders.count {
            if let updated = rejectRenameInFolder(updatedFolder.subfolders[i], targetID: targetID, fileID: fileID) {
                updatedFolder.subfolders[i] = updated
                return updatedFolder
            }
        }
        return nil
    }

    private func updateDestinationInFolder(_ folder: FolderSuggestion, targetID: UUID, newDestinationPath: String) -> FolderSuggestion? {
        var updatedFolder = folder
        if folder.id == targetID {
            updatedFolder.folderName = newDestinationPath
            return updatedFolder
        }

        for i in 0..<updatedFolder.subfolders.count {
            if let updated = updateDestinationInFolder(updatedFolder.subfolders[i], targetID: targetID, newDestinationPath: newDestinationPath) {
                updatedFolder.subfolders[i] = updated
                return updatedFolder
            }
        }

        return nil
    }
    
    private func updateInternalPlan(_ updatedPlan: OrganizationPlan) {
        let finalPlan = OrganizationPlan(
            id: updatedPlan.id,
            suggestions: updatedPlan.suggestions,
            unorganizedFiles: updatedPlan.unorganizedFiles,
            unorganizedDetails: updatedPlan.unorganizedDetails,
            notes: updatedPlan.notes,
            timestamp: Date(),
            version: updatedPlan.version + 1,
            generationStats: updatedPlan.generationStats
        )
        plan = finalPlan
        cachedMoveDestinations = Self.collectMoveDestinations(from: finalPlan.suggestions)
        folderCountCache.removeAll()
        folderCountCacheValid = false
        updateThrottledFileCount()
        rebuildFlattenedRows()
        cachedPlanVersion = finalPlan.version
    }
    
    func moveFile(fileID: UUID, toFolderID: UUID) {
        guard let file = findFile(by: fileID) else { return }
        
        // Record the manual correction (user moved file to a different folder)
        let destFolderPath = folderIDToPath[toFolderID] ?? ""
        let destPath = destFolderPath.isEmpty ? file.displayName : "\(destFolderPath)/\(file.displayName)"
        learningsManager?.recordCorrection(originalPath: file.path, newPath: destPath)
        recordEditCaptured()
        
        var updatedPlan = plan
        
        // Remove from current location
        for i in 0..<updatedPlan.suggestions.count {
            updatedPlan.suggestions[i] = removeFileFromFolder(file, from: updatedPlan.suggestions[i])
        }
        updatedPlan.unorganizedFiles.removeAll { $0.id == fileID }
        
        // Add to new location
        for i in 0..<updatedPlan.suggestions.count {
            updatedPlan.suggestions[i] = addFileToFolder(file, to: updatedPlan.suggestions[i], targetId: toFolderID)
        }
        
        updateInternalPlan(updatedPlan)
    }
    
    private func findFile(by id: UUID) -> FileItem? {
        for suggestion in plan.suggestions {
            if let file = findFileInFolder(id, in: suggestion) {
                return file
            }
        }
        return plan.unorganizedFiles.first { $0.id == id }
    }
    
    private func findFileInFolder(_ id: UUID, in folder: FolderSuggestion) -> FileItem? {
        if let file = folder.files.first(where: { $0.id == id }) {
            return file
        }
        for subfolder in folder.subfolders {
            if let file = findFileInFolder(id, in: subfolder) {
                return file
            }
        }
        return nil
    }

    private func folderPathForFile(fileID: UUID) -> [UUID]? {
        for suggestion in plan.suggestions {
            if let path = folderPathForFile(fileID: fileID, in: suggestion, ancestors: []) {
                return path
            }
        }
        return nil
    }

    private func folderPathForFile(fileID: UUID, in folder: FolderSuggestion, ancestors: [UUID]) -> [UUID]? {
        let nextAncestors = ancestors + [folder.id]
        if folder.files.contains(where: { $0.id == fileID }) {
            return nextAncestors
        }

        for subfolder in folder.subfolders {
            if let found = folderPathForFile(fileID: fileID, in: subfolder, ancestors: nextAncestors) {
                return found
            }
        }

        return nil
    }

    private func folderSuggestion(for folderID: UUID, in folder: FolderSuggestion) -> FolderSuggestion? {
        if folder.id == folderID {
            return folder
        }
        for subfolder in folder.subfolders {
            if let matched = folderSuggestion(for: folderID, in: subfolder) {
                return matched
            }
        }
        return nil
    }
    
    private func removeFileFromFolder(_ file: FileItem, from folder: FolderSuggestion) -> FolderSuggestion {
        var updatedFolder = folder
        updatedFolder.files.removeAll { $0.id == file.id }
        updatedFolder.subfolders = updatedFolder.subfolders.map { subfolder in
            removeFileFromFolder(file, from: subfolder)
        }
        return updatedFolder
    }
    
    private func addFileToFolder(_ file: FileItem, to folder: FolderSuggestion, targetId: UUID) -> FolderSuggestion {
        var updatedFolder = folder
        
        if folder.id == targetId {
            if !updatedFolder.files.contains(where: { $0.id == file.id }) {
                updatedFolder.files.append(file)
            }
        } else {
            updatedFolder.subfolders = updatedFolder.subfolders.map { subfolder in
                addFileToFolder(file, to: subfolder, targetId: targetId)
            }
        }
        
        return updatedFolder
    }
}
