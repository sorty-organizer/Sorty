//
//  OptimizedPreviewTree.swift
//  Sorty
//
//  Optimized flat-list rendering for large organization previews.
//  Uses a flattened data structure to avoid recursive view creation
//  and improve scrolling performance.
//

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
        isHighlighted: Bool,
        collisionSuggestion: String?
    )
    case unorganizedHeader(row: FlattenedRow, fileCount: Int)
    case unorganizedFile(
        row: FlattenedRow,
        duplicateInfo: DuplicateInfo?,
        isHighlighted: Bool,
        moveDestinations: [PreviewMoveDestination],
        reason: String?
    )
    case remaining(row: FlattenedRow, count: Int)
}

// MARK: - Preview Plan Insights

/// Files in one folder claiming the same destination filename
/// (case-insensitive, post-rename). The first file keeps the name; every
/// file after it carries a ready-to-accept uniquified suggestion.
struct FilenameCollisionGroup: Equatable {
    let folderID: UUID
    let folderPath: String
    let collidingName: String
    /// Deterministic order: the head keeps `collidingName`.
    let files: [FileItem]
    /// Uniquified suggestion per file after the head, keyed by file ID.
    let suggestedNames: [UUID: String]

    /// Three-or-more-way conflicts block Apply until resolved; two-way
    /// conflicts auto-rename safely on apply.
    var isBlocking: Bool { files.count >= 3 }
}

/// Cheap, read-only derivations over an OrganizationPlan for preview UI.
/// Pure logic (no FS access): the caller supplies existence checks separately.
enum PreviewPlanInsights {
    /// Must match PreviewStore.renderedFilesPerSectionLimit (which is
    /// MainActor-isolated and can't be referenced from this nonisolated enum).
    static let perSectionFileLimit = 500

    /// Files hidden by the per-section render cap. Apply still includes them,
    /// so the preview must say so explicitly instead of applying blind.
    static func hiddenFileCount(in plan: OrganizationPlan) -> Int {
        let limit = Self.perSectionFileLimit
        var hidden = 0
        func visit(_ folder: FolderSuggestion) {
            hidden += max(0, folder.files.count - limit)
            for sub in folder.subfolders { visit(sub) }
        }
        for suggestion in plan.suggestions { visit(suggestion) }
        hidden += max(0, plan.unorganizedFiles.count - limit)
        return hidden
    }

    /// Rename suggestions worth flagging (medium/low confidence only;
    /// high-confidence and unknown-confidence renames stay quiet), sorted by
    /// confidence ascending so the riskiest rename reviews first.
    static func flaggableRenames(in plan: OrganizationPlan) -> [(folderPath: String, mapping: FileRenameMapping)] {
        var result: [(folderPath: String, mapping: FileRenameMapping)] = []
        func visit(_ folder: FolderSuggestion, parentPath: String) {
            let path = parentPath.isEmpty ? folder.folderName : "\(parentPath)/\(folder.folderName)"
            for mapping in folder.fileRenameMappings where mapping.hasRename && mapping.confidenceBand != .high {
                result.append((folderPath: path, mapping: mapping))
            }
            for sub in folder.subfolders { visit(sub, parentPath: path) }
        }
        for suggestion in plan.suggestions { visit(suggestion, parentPath: "") }
        result.sort { ($0.mapping.renameConfidence ?? 1.0) < ($1.mapping.renameConfidence ?? 1.0) }
        return result
    }

    /// Destination filenames claimed by more than one file in the same folder
    /// (case-insensitive, post-rename). These auto-rename on apply.
    static func filenameCollisions(in plan: OrganizationPlan) -> [(folderPath: String, names: [String])] {
        collisionGroups(in: plan).map { (folderPath: $0.folderPath, names: [$0.collidingName]) }
    }

    /// Same-folder final-name collisions with the colliding files and a
    /// ready-to-accept uniquified name per file after the first. Deterministic:
    /// files sort by display name, so the same file always keeps the name.
    static func collisionGroups(in plan: OrganizationPlan) -> [FilenameCollisionGroup] {
        var groups: [FilenameCollisionGroup] = []
        func visit(_ folder: FolderSuggestion, parentPath: String) {
            let path = parentPath.isEmpty ? folder.folderName : "\(parentPath)/\(folder.folderName)"
            let finals = folder.filesWithFinalNames
            let byName = Dictionary(grouping: finals, by: { $0.finalName.lowercased() })
            for key in byName.keys.sorted() {
                guard let entries = byName[key], entries.count > 1 else { continue }
                let ordered = entries
                    .sorted {
                        ($0.file.displayName.lowercased(), $0.file.id.uuidString)
                            < ($1.file.displayName.lowercased(), $1.file.id.uuidString)
                    }
                var taken = Set(finals.map { $0.finalName.lowercased() })
                var suggested: [UUID: String] = [:]
                for entry in ordered.dropFirst() {
                    suggested[entry.file.id] = uniquifiedName(for: entry.finalName, takenLowercased: &taken)
                }
                groups.append(FilenameCollisionGroup(
                    folderID: folder.id,
                    folderPath: path,
                    collidingName: ordered.first?.finalName ?? key,
                    files: ordered.map(\.file),
                    suggestedNames: suggested
                ))
            }
            for sub in folder.subfolders { visit(sub, parentPath: path) }
        }
        for suggestion in plan.suggestions { visit(suggestion, parentPath: "") }
        return groups
    }

    /// Extension-preserving uniquified name (`name_1.ext`), matched
    /// case-insensitively like the apply path. The winner is inserted into
    /// `takenLowercased` so sequential calls never repeat a name.
    static func uniquifiedName(for desired: String, takenLowercased: inout Set<String>) -> String {
        let nsName = desired as NSString
        let ext = nsName.pathExtension
        let base = nsName.deletingPathExtension
        var counter = 1
        while true {
            let candidate = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            counter += 1
            guard takenLowercased.contains(candidate.lowercased()) else {
                takenLowercased.insert(candidate.lowercased())
                return candidate
            }
            guard counter <= 10_000 else {
                takenLowercased.insert(candidate.lowercased())
                return candidate
            }
        }
    }

    /// Apply-confirmation lines for collision groups. Three-or-more-way
    /// conflicts name names explicitly (Apply stays disabled until resolved);
    /// two-way conflicts keep the short auto-rename summary.
    static func collisionConfirmationLines(groups: [FilenameCollisionGroup]) -> [String] {
        var lines: [String] = []
        for group in groups.filter(\.isBlocking).prefix(2) {
            let examples = group.suggestedNames.values.sorted().prefix(2).joined(separator: ", ")
            lines.append(
                "\"\(group.collidingName)\" is claimed by \(group.files.count) files in \(group.folderPath) — "
                    + "accept the inline suggestions (e.g. \(examples)) before applying."
            )
        }
        let twoWayFiles = groups.filter { !$0.isBlocking }.reduce(0) { $0 + $1.files.count }
        if twoWayFiles > 0 {
            var line = "\(twoWayFiles) files would land on the same name and auto-rename on apply."
            if let sample = groups.first(where: { !$0.isBlocking }) {
                line += " E.g. \(sample.collidingName) in \(sample.folderPath)."
            }
            lines.append(line)
        }
        return lines
    }

    /// Folders pointing at absolute storage locations (external drives etc.).
    static func storageDestinationCount(in plan: OrganizationPlan) -> Int {
        var count = 0
        func visit(_ folder: FolderSuggestion) {
            if folder.folderName.hasPrefix("/") { count += 1 }
            for sub in folder.subfolders { visit(sub) }
        }
        for suggestion in plan.suggestions { visit(suggestion) }
        return count
    }

    /// Reason recorded for an unorganized file, matched by display name.
    static func unorganizedReason(for file: FileItem, in plan: OrganizationPlan) -> String? {
        plan.unorganizedDetails.first { $0.filename == file.displayName }?.reason
    }
}

// MARK: - Preview Store

@MainActor
class PreviewStore: ObservableObject {
    private static let automaticExpansionFileLimit = 2_000
    static let renderedFilesPerSectionLimit = 500
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

    /// Same-folder final-name collisions with per-file uniquified suggestions.
    /// Refreshed synchronously on every plan change so inline accept buttons
    /// never offer a stale name.
    @Published private(set) var collisionGroups: [FilenameCollisionGroup] = []
    /// Uniquified suggestion per collided file after the group head.
    @Published private(set) var collisionSuggestions: [UUID: String] = [:]

    /// Existing on-disk folders for quality re-scores (convention-match
    /// context). Cached from PreviewView; empty until the first scan lands.
    private var existingFolderPathsForQuality: [String] = []
    /// Debounced off-main quality re-score after user edits. Never blocks UI.
    private var qualityRescoreTask: Task<Void, Never>?
    private static let qualityRescoreDebounceNanoseconds: UInt64 = 350_000_000
    
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
        refreshCollisionGroups()
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
        refreshCollisionGroups()
        qualityRescoreTask?.cancel()
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
                isHighlighted: highlightedFileID == file.id,
                collisionSuggestion: collisionSuggestions[file.id]
            )
        case .unorganizedHeader:
            return .unorganizedHeader(row: row, fileCount: plan.unorganizedFiles.count)
        case .unorganizedFile(let file):
            return .unorganizedFile(
                row: row,
                duplicateInfo: duplicateMappings[file.id],
                isHighlighted: highlightedFileID == file.id,
                moveDestinations: moveDestinations,
                reason: PreviewPlanInsights.unorganizedReason(for: file, in: plan)
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
            generationStats: updatedPlan.generationStats,
            // Manual edits must not silently drop the plan's quality signals:
            // the assessment can't be re-derived from SortyLib (the evaluator
            // lives in SortyOrganizer), so the latest values carry forward.
            qualityAssessment: updatedPlan.qualityAssessment,
            learningToolCall: updatedPlan.learningToolCall,
            isPartial: updatedPlan.isPartial,
            needsReview: updatedPlan.needsReview,
            parseWarnings: updatedPlan.parseWarnings
        )
        plan = finalPlan
        cachedMoveDestinations = Self.collectMoveDestinations(from: finalPlan.suggestions)
        refreshCollisionGroups()
        folderCountCache.removeAll()
        folderCountCacheValid = false
        updateThrottledFileCount()
        rebuildFlattenedRows()
        cachedPlanVersion = finalPlan.version
        // Quality re-score only — never a full AI organize. Debounced and
        // off-main so rapid edits (drag-drop, typing a rename) never stall.
        scheduleQualityRescore(for: finalPlan)
    }

    /// Caches on-disk folders for re-score convention context. Set once from
    /// the preview host; empty until the scan lands.
    func setExistingFolderPaths(_ paths: [String]) {
        existingFolderPathsForQuality = paths
    }

    /// True when an unresolved 3+-way name conflict blocks Apply.
    var hasBlockingCollisions: Bool {
        collisionGroups.contains(where: \.isBlocking)
    }

    /// Applies the suggested uniquified name for one collided file.
    /// Returns the applied name, or nil when the file has no suggestion.
    @discardableResult
    func acceptCollisionSuggestion(fileID: UUID) -> String? {
        for group in collisionGroups {
            guard let suggestion = group.suggestedNames[fileID] else { continue }
            updateRename(fileID: fileID, folderID: group.folderID, newName: suggestion)
            return suggestion
        }
        return nil
    }

    /// Applies every pending uniquified suggestion. Clears all collision
    /// groups, including blocking ones, in one step.
    func acceptAllCollisionSuggestions() {
        let pending = collisionGroups.flatMap { group in
            group.suggestedNames.map { (group.folderID, $0.key, $0.value) }
        }
        for (folderID, fileID, name) in pending {
            updateRename(fileID: fileID, folderID: folderID, newName: name)
        }
    }

    /// Debounced quality re-score for the edited plan. The detached assessor
    /// runs off-main; a stale result (a newer edit already scheduled its own
    /// re-score) is dropped instead of overwriting fresher state.
    private func scheduleQualityRescore(for editedPlan: OrganizationPlan) {
        qualityRescoreTask?.cancel()
        let existingPaths = existingFolderPathsForQuality
        qualityRescoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.qualityRescoreDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            do {
                let assessment = try await PlanQualityEvaluator.assessOffMain(
                    editedPlan,
                    existingFolderPaths: existingPaths
                )
                try Task.checkCancellation()
                self?.applyRescoredAssessment(assessment, forPlanID: editedPlan.id, version: editedPlan.version)
            } catch is CancellationError {
                return
            } catch {
                // Keep the previous assessment: a failed re-score must never
                // blank the Quality badge.
            }
        }
    }

    /// Writes a re-scored assessment without bumping the plan version, so row
    /// identity and the Edited diff stay stable on quality-only refreshes.
    private func applyRescoredAssessment(
        _ assessment: PlanQualityAssessment,
        forPlanID id: UUID,
        version: Int
    ) {
        guard plan.id == id, plan.version == version else { return }
        var updated = plan
        updated.qualityAssessment = assessment
        plan = updated
    }

    /// Recomputes collision groups and the per-file suggestion map.
    private func refreshCollisionGroups() {
        let groups = PreviewPlanInsights.collisionGroups(in: plan)
        collisionGroups = groups
        var suggestions: [UUID: String] = [:]
        for group in groups {
            for (fileID, name) in group.suggestedNames {
                suggestions[fileID] = name
            }
        }
        collisionSuggestions = suggestions
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

// MARK: - Optimized Preview Tree View

struct OptimizedPreviewTree: View {
    @SortyHotReload private var hotReload
    @ObservedObject var store: PreviewStore
    @ObservedObject var dragDropManager: DragDropManager
    let onPlanChanged: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.flattenedRows, id: \.id) { row in
                        FlattenedRowView(
                            presentation: store.presentation(for: row),
                            store: store,
                            dragDropManager: dragDropManager,
                            onPlanChanged: onPlanChanged
                        )
                        .equatable()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: store.highlightedFileID) { _, highlightedFileID in
                guard let highlightedFileID else { return }
                guard let rowID = store.revealFileAndResolveRowID(highlightedFileID) else { return }
                if reduceMotion {
                    scrollProxy.scrollTo(rowID, anchor: .center)
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        scrollProxy.scrollTo(rowID, anchor: .center)
                    }
                }
            }
        }
    }

    private func findFolderByID(_ id: UUID, in folder: FolderSuggestion) -> FolderSuggestion? {
        if folder.id == id { return folder }
        for sub in folder.subfolders {
            if let found = findFolderByID(id, in: sub) { return found }
        }
        return nil
    }
}

// MARK: - Flattened Row View

struct FlattenedRowView: View, @MainActor Equatable {
    @SortyHotReload private var hotReload
    let presentation: PreviewRowPresentation
    let store: PreviewStore
    @ObservedObject var dragDropManager: DragDropManager
    let onPlanChanged: () -> Void

    static func == (lhs: FlattenedRowView, rhs: FlattenedRowView) -> Bool {
        lhs.presentation == rhs.presentation
    }
    
    var body: some View {
        switch presentation {
        case .folder(let row, let tags, let comment, let fileCount):
            if case .folder(let suggestion) = row.type {
                FlatFolderRowView(
                    suggestion: suggestion,
                    depth: row.depth,
                    isExpanded: row.isExpanded,
                    rowID: row.id,
                    folderTags: tags,
                    folderComment: comment,
                    fileCount: fileCount,
                    store: store,
                    dragDropManager: dragDropManager,
                    onPlanChanged: onPlanChanged
                )
            }
        case .file(
            let row,
            let renameMapping,
            let tags,
            let comment,
            let duplicateInfo,
            let parentSuggestion,
            let isHighlighted,
            let collisionSuggestion
        ):
            if case .file(let file, let parentFolderID) = row.type {
                FlatFileRowView(
                    file: file,
                    depth: row.depth,
                    parentFolderID: parentFolderID,
                    renameMapping: renameMapping,
                    fileTags: tags,
                    fileComment: comment,
                    duplicateInfo: duplicateInfo,
                    parentSuggestion: parentSuggestion,
                    isHighlighted: isHighlighted,
                    collisionSuggestion: collisionSuggestion,
                    store: store,
                    dragDropManager: dragDropManager,
                    onPlanChanged: onPlanChanged
                )
            }
        case .unorganizedHeader(let row, let fileCount):
            FlatUnorganizedHeaderView(
                fileCount: fileCount,
                isExpanded: row.isExpanded,
                store: store,
                dragDropManager: dragDropManager,
                onPlanChanged: onPlanChanged
            )
        case .unorganizedFile(let row, let duplicateInfo, let isHighlighted, let moveDestinations, let reason):
            if case .unorganizedFile(let file) = row.type {
                FlatUnorganizedFileRowView(
                    file: file,
                    dragDropManager: dragDropManager,
                    store: store,
                    duplicateInfo: duplicateInfo,
                    isHighlighted: isHighlighted,
                    moveDestinations: moveDestinations,
                    reason: reason,
                    onPlanChanged: onPlanChanged
                )
            }
        case .remaining(let row, let count):
            HStack(spacing: 8) {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                Text("\(count.formatted()) more files in this section are hidden for performance — Apply moves every one of them, including files you can't see here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.leading, CGFloat(row.depth) * 20 + 12)
            .padding(.vertical, 7)
        }
    }
}

// MARK: - Flat Folder Row View

struct FlatFolderRowView: View {
    @SortyHotReload private var hotReload

    /// Memoizes storage-location matches across rows and body evaluations.
    /// All access runs under the lock, so sharing one instance is safe.
    private final class StorageMatchCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: StorageLocation?] = [:]

        func match(for key: String, compute: () -> StorageLocation?) -> StorageLocation? {
            lock.withLock {
                if let boxed = storage[key] {
                    return boxed
                }
                let result = compute()
                if storage.count > 64 {
                    storage.removeAll()
                }
                storage[key] = result
                return result
            }
        }
    }

    private static let storageMatchCache = StorageMatchCache()

    let suggestion: FolderSuggestion
    let depth: Int
    let isExpanded: Bool
    let rowID: String
    let folderTags: [String]
    let folderComment: String?
    let fileCount: Int
    let store: PreviewStore
    @ObservedObject var dragDropManager: DragDropManager
    let onPlanChanged: () -> Void
    @EnvironmentObject var learningsManager: LearningsManager
    @EnvironmentObject var storageLocationsManager: StorageLocationsManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isDropTarget = false
    @State private var showStorageLocationPicker = false
    @State private var showStoragePopover = false
    @State private var storageLocationPickerErrorMessage: String?

    private var isStorageDestination: Bool {
        suggestion.folderName.hasPrefix("/")
    }

    /// Folder-level placement confidence. Only medium/low surface a pill so
    /// confident folders stay visually quiet.
    private var confidenceBand: RenameConfidenceBand? {
        guard let score = suggestion.confidenceScore,
              score < FileRenameMapping.highConfidenceThreshold else { return nil }
        return score < FileRenameMapping.lowConfidenceThreshold ? .low : .medium
    }

    private var matchedStorageLocation: StorageLocation? {
        guard isStorageDestination else { return nil }
        // Memoized per folder + locations signature. The resolver walks every
        // location per row per body evaluation; the signature rebuild is one
        // string join, and hits skip the resolver entirely.
        let key = suggestion.folderName + "#" + storageLocationsManager.locations.map(\.path).joined(separator: "|")
        return Self.storageMatchCache.match(for: key) {
            storageLocationsManager.locations.lazy
                .filter { StorageLocationPathResolver.isPath(suggestion.folderName, within: $0.path) }
                .max { $0.path.count < $1.path.count }
        }
    }

    private var usedStorageURL: URL? {
        if let matchedStorageLocation {
            return URL(fileURLWithPath: matchedStorageLocation.path, isDirectory: true)
        }
        return StorageLocationPathResolver.absoluteURL(from: suggestion.folderName)
    }

    private var usedStorageDisplayName: String {
        if let matchedStorageLocation {
            return matchedStorageLocation.name
        }
        return usedStorageURL?.lastPathComponent ?? "Storage"
    }

    private var usedStoragePath: String {
        if let matchedStorageLocation {
            return matchedStorageLocation.path
        }
        return usedStorageURL?.path ?? suggestion.folderName
    }

    private var storageLocationPickerErrorIsPresented: Binding<Bool> {
        Binding(
            get: { storageLocationPickerErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    storageLocationPickerErrorMessage = nil
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                FlatFolderRowHeaderContent(
                    folderName: suggestion.folderName,
                    fileCount: fileCount,
                    isExpanded: isExpanded,
                    isDropTarget: isDropTarget,
                    reduceMotion: reduceMotion
                )

                if isStorageDestination {
                    storageLocationDropdown
                }

                if !folderTags.isEmpty {
                    TagDotsView(tags: folderTags)
                }

                if let comment = folderComment, !comment.isEmpty {
                    CommentBubbleButton(comment: comment)
                }

                if let band = confidenceBand {
                    HStack(spacing: 3) {
                        Image(systemName: band == .low ? "exclamationmark.triangle.fill" : "eye.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text("\(band.displayName) (\(Int(((suggestion.confidenceScore ?? 0) * 100).rounded()))%)")
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .foregroundStyle(band == .low ? .orange : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .systemLiquidGlassBackground(cornerRadius: 4, interactive: false)
                    .help("AI placement confidence for this folder is \(band.displayName.lowercased()). Review its files before applying.")
                    .accessibilityLabel("Folder placement confidence: \(band.displayName)")
                }
                
                Spacer()
                
                LiquidGlassReasoningButton(
                    suggestion: suggestion,
                    learningsManager: learningsManager
                )
            }
            .padding(.leading, CGFloat(depth * 16))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)
            .focusable()
            .onKeyPress(.space) {
                toggleExpanded()
                return .handled
            }
            .onKeyPress(.return) {
                toggleExpanded()
                return .handled
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(
                named: isExpanded ? "Collapse \(suggestion.folderName)" : "Expand \(suggestion.folderName)",
                toggleExpanded
            )
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isDropTarget ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.1) : Color.clear)
                    .strokeBorder(isDropTarget ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.55) : Color.clear, lineWidth: 1.5)
            )
            .contextMenu {
                FlatFolderRowContextMenu(
                    isStorageDestination: isStorageDestination,
                    onRevert: revertOrganization,
                    onChangeStorage: showStoragePicker,
                    onReveal: revealStorageLocationInFinder
                )
            }
            .onDrop(of: [.text], delegate: OptimizedFileDropDelegate(
                targetFolderID: suggestion.id,
                store: store,
                draggedFile: $dragDropManager.draggedFile,
                isTargeted: $isDropTarget,
                onPlanChanged: onPlanChanged
            ))
            .fileImporter(
                isPresented: $showStorageLocationPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleStorageLocationImport(result)
            }
            .alert(
                "Couldn't Change Storage Location",
                isPresented: storageLocationPickerErrorIsPresented
            ) {
                Button("OK", role: .cancel) {
                    storageLocationPickerErrorMessage = nil
                }
            } message: {
                Text(storageLocationPickerErrorMessage ?? "Please try selecting the folder again.")
            }

            // Reasoning stays discoverable for folders Sorty is unsure about:
            // the pill above flags them, this line says why.
            if confidenceBand != nil, !suggestion.reasoning.isEmpty {
                Text(suggestion.reasoning)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, CGFloat(depth * 16) + 28)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
    }

    private var storageLocationDropdown: some View {
        Button {
            showStoragePopover.toggle()
        } label: {
            Image(systemName: "externaldrive")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(showStoragePopover ? .primary : .secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("StorageLocationMenuButton")
        .help("Storage location options")
        .popover(isPresented: $showStoragePopover, arrowEdge: .bottom) {
            StorageLocationPopoverContent(
                displayName: usedStorageDisplayName,
                path: usedStoragePath,
                onChangeLocation: {
                    showStoragePopover = false
                    showStorageLocationPicker = true
                },
                onShowInFinder: {
                    showStoragePopover = false
                    revealStorageLocationInFinder()
                },
                onCopyPath: {
                    showStoragePopover = false
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(usedStoragePath, forType: .string)
                }
            )
            .systemLiquidGlassPopover(cornerRadius: 12)
        }
    }

    private func finderIcon(for path: String) -> some View {
        AppKitImageView(
            image: NSWorkspace.shared.icon(forFile: path),
            size: CGSize(width: 12, height: 12),
            cornerRadius: 2
        )
        .frame(width: 12, height: 12)
    }

    private func revealStorageLocationInFinder() {
        guard let usedStorageURL else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: usedStorageURL.path)
    }

    private func toggleExpanded() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
            store.toggleFolder(id: rowID)
        }
    }

    private func revertOrganization() {
        store.revertFolderOrganization(folderID: suggestion.id)
        onPlanChanged()
    }

    private func showStoragePicker() {
        showStorageLocationPicker = true
    }

    private func handleStorageLocationImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let selectedURL = urls.first else { return }
            do {
                try storageLocationsManager.addLocation(url: selectedURL, customName: nil)
            } catch {
                DebugLogger.log("Could not add selected storage location during preview destination change: \(error)")
            }
            store.updateFolderDestination(
                folderID: suggestion.id,
                newDestinationPath: selectedURL.path
            )
            onPlanChanged()
        case .failure(let error):
            storageLocationPickerErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Flat File Row View

struct FlatFileRowView: View {
    @SortyHotReload private var hotReload
    let file: FileItem
    let depth: Int
    let parentFolderID: UUID
    let renameMapping: FileRenameMapping?
    let fileTags: [String]
    let fileComment: String?
    let duplicateInfo: DuplicateInfo?
    let parentSuggestion: FolderSuggestion?
    let isHighlighted: Bool
    /// Uniquified name suggestion when this file collides with another file's
    /// destination name in the same folder. Nil when the name is unique.
    let collisionSuggestion: String?
    let store: PreviewStore
    @ObservedObject var dragDropManager: DragDropManager
    let onPlanChanged: () -> Void
    @EnvironmentObject var learningsManager: LearningsManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    /// Injected for tests (MockAIClient); defaults to the factory in production.
    var injectedAIClient: (any AIClientProtocol)? = nil
    
    @State private var isDragging = false
    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var isRegeneratingName = false
    @FocusState private var isFocused: Bool
    
    private var rowContent: FlatFileRowContent {
        FlatFileRowContent(
            file: file,
            renameMapping: renameMapping,
            renameHelpText: renameMapping.map(renameHelpText),
            fileTags: fileTags,
            fileComment: fileComment,
            duplicateInfo: duplicateInfo,
            parentSuggestion: parentSuggestion,
            learningsManager: learningsManager,
            isHighlighted: isHighlighted,
            isEditingName: $isEditingName,
            editedName: $editedName,
            isRegeneratingName: $isRegeneratingName,
            highlightedFileID: Binding(
                get: { store.highlightedFileID },
                set: { store.highlightedFileID = $0 }
            ),
            isFocused: $isFocused,
            onSave: saveRename,
            onCancel: cancelRename,
            onStartEditing: startEditing,
            onRegenerate: regenerateSuggestedName,
            onReject: rejectRename
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            FlatFileRowSurface(
                content: rowContent,
                depth: depth,
                isHighlighted: isHighlighted,
                isEditingName: isEditingName,
                isDragging: $isDragging,
                hasRename: renameMapping?.hasRename == true,
                onOpen: openFile,
                onReveal: revealInFinder,
                onRegenerate: regenerateSuggestedName,
                onRejectRename: rejectRename,
                onRevertOrganization: revertOrganization,
                onBeginDrag: beginDrag,
                onDisappear: resetInteractionState
            )

            // Medium/low rename confidence surfaces here with the reason
            // inline: previously both lived only in tooltips.
            if let mapping = lowConfidenceMapping {
                HStack(spacing: 4) {
                    Image(systemName: mapping.confidenceBand == .low ? "exclamationmark.triangle.fill" : "eye.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text(mapping.confidenceBand.displayName)
                        .fontWeight(.semibold)
                    if let confidence = mapping.renameConfidence {
                        Text("(\(Int((confidence * 100).rounded()))%)")
                    }
                    if let reason = mapping.renameReason?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !reason.isEmpty {
                        Text("— \(reason)")
                            .truncationMode(.tail)
                    }
                }
                .font(.caption2)
                .foregroundStyle(mapping.confidenceBand == .low ? .orange : .secondary)
                .lineLimit(1)
                .padding(.leading, CGFloat(depth * 16) + 36)
                .help(mapping.renameReason ?? mapping.confidenceBand.displayName)
                .accessibilityLabel("Rename confidence \(mapping.confidenceBand.displayName) for \(file.displayName)")
            }

            // Same-folder destination collision: one-click accept applies the
            // uniquified name; Apply auto-renames 2-way conflicts regardless.
            if let collisionSuggestion {
                CollisionSuggestionRow(
                    suggestion: collisionSuggestion,
                    onAccept: acceptCollisionSuggestion
                )
                .padding(.leading, CGFloat(depth * 16) + 36)
            }
        }
    }

    /// Rename worth flagging: medium/low confidence only, so confident
    /// renames (and renames without a score) stay visually quiet.
    private var lowConfidenceMapping: FileRenameMapping? {
        guard let renameMapping, renameMapping.hasRename,
              renameMapping.confidenceBand != .high else { return nil }
        return renameMapping
    }
    
    private func startEditing(initialValue: String) {
        editedName = initialValue
        isEditingName = true
        isFocused = true
    }

    private func openFile() {
        NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
    }

    private func revealInFinder() {
        NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
    }

    private func rejectRename() {
        store.rejectRename(fileID: file.id, folderID: parentFolderID)
        onPlanChanged()
    }

    /// One-click accept for the inline uniquified collision suggestion.
    private func acceptCollisionSuggestion() {
        HapticFeedbackManager.shared.success()
        store.acceptCollisionSuggestion(fileID: file.id)
        onPlanChanged()
    }

    private func revertOrganization() {
        store.moveFileToUnorganized(fileID: file.id)
        onPlanChanged()
    }

    private func beginDrag() -> NSItemProvider {
        isDragging = true
        dragDropManager.startDrag(file)
        return NSItemProvider(object: file.id.uuidString as NSString)
    }

    private func resetInteractionState() {
        isDragging = false
        isEditingName = false
    }
    
    private func saveRename() {
        if !editedName.isEmpty {
            store.updateRename(fileID: file.id, folderID: parentFolderID, newName: editedName)
            onPlanChanged()
        }
        isEditingName = false
    }

    private func regenerateSuggestedName() {
        guard !isRegeneratingName else { return }
        let previousSuggestion = renameMapping?.suggestedName ?? ""
        withAnimation(.easeInOut(duration: 0.2)) {
            isRegeneratingName = true
        }
        HapticFeedbackManager.shared.selection()

        Task {
            do {
                let client: any AIClientProtocol
                if let injected = injectedAIClient {
                    client = injected
                } else {
                    client = try AIClientFactory.createClient(config: settingsViewModel.config)
                }
                let plan = try await client.analyze(
                    files: [file],
                    customInstructions: renameRegenerationPrompt(),
                    personaPrompt: nil,
                    temperature: 0.8
                )
                let suggestedName = plan.suggestions
                    .lazy
                    .flatMap(\.allFileRenameMappings)
                    .first { $0.originalFile.id == file.id || $0.originalFile.displayName == file.displayName }?
                    .suggestedName
                guard let suggestedName, !suggestedName.isEmpty else {
                    throw AIClientError.invalidResponseFormat
                }
                let normalized = FilenameNormalizer.normalize(
                    suggestedName,
                    originalFilename: file.displayName,
                    options: settingsViewModel.config.renameNamingOptions
                ) ?? suggestedName
                let replacementName = distinctRegeneratedName(normalized, previousSuggestion: previousSuggestion)

                await MainActor.run {
                    store.updateRename(fileID: file.id, folderID: parentFolderID, newName: replacementName)
                    onPlanChanged()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isRegeneratingName = false
                    }
                    HapticFeedbackManager.shared.success()
                }
            } catch {
                await MainActor.run {
                    let fallbackName = distinctRegeneratedName(
                        previousSuggestion.isEmpty ? file.displayName : previousSuggestion,
                        previousSuggestion: previousSuggestion
                    )
                    store.updateRename(fileID: file.id, folderID: parentFolderID, newName: fallbackName)
                    onPlanChanged()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isRegeneratingName = false
                    }
                    HapticFeedbackManager.shared.error()
                }
            }
        }
    }

    private func renameRegenerationPrompt() -> String {
        let currentSuggestion = renameMapping?.suggestedName ?? "None"
        let metadata = file.contentMetadata
        let title = metadata?.documentTitle ?? ""
        let keywords = metadata?.detectedKeywords?.prefix(8).joined(separator: ", ") ?? ""
        let contentPreview = String(
            metadata?.allTextContent?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(900) ?? ""
        )

        return """
        Rename only this one file. Keep it in the current folder.

        Original filename: \(file.displayName)
        Current suggested filename: \(currentSuggestion)
        File extension to preserve: \(file.extension)
        Document title: \(title)
        Keywords: \(keywords)
        Content preview:
        \(contentPreview)

        Requirements:
        - Return Sorty's normal JSON organization response.
        - Use a single folder named ".".
        - Preserve the original file extension.
        - Make the name specific, useful, and concise.
        - Spaces are valid if they improve readability.
        - Do not return the current suggested filename. Generate a meaningfully different name.
        - Include suggested_name, rename_reason, and rename_confidence for this file.
        """
    }

    private func distinctRegeneratedName(_ candidate: String, previousSuggestion: String) -> String {
        guard candidate.caseInsensitiveCompare(previousSuggestion) == .orderedSame else {
            return candidate
        }

        let nsName = candidate as NSString
        let ext = nsName.pathExtension
        let base = nsName.deletingPathExtension
        let revised = "\(base) Revised"
        return ext.isEmpty ? revised : "\(revised).\(ext)"
    }
    
    private func cancelRename() {
        isEditingName = false
    }

    private func renameHelpText(_ mapping: FileRenameMapping) -> String {
        let reason = mapping.renameReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty ? "Sorty suggested rename" : reason
    }
}

// MARK: - Collision Suggestion Row

/// Inline uniquified-name suggestion for a file whose destination name
/// collides with another file in the same folder.
struct CollisionSuggestionRow: View {
    @SortyHotReload private var hotReload
    let suggestion: String
    let onAccept: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Suggested unique name")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(suggestion)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
            Button("Use suggestion") {
                onAccept()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .fixedSize()
            .accessibilityIdentifier("AcceptCollisionSuggestionButton")
            .accessibilityLabel("Use suggested unique name \(suggestion)")
            .accessibilityHint("Renames this file so it no longer collides")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .help("Another file has the same destination name. Use \(suggestion) to give this file a unique name.")
        .transition(.opacity)
    }
}

// MARK: - Flat Unorganized Header View

struct FlatUnorganizedHeaderView: View {
    @SortyHotReload private var hotReload
    let fileCount: Int
    let isExpanded: Bool
    let store: PreviewStore
    @ObservedObject var dragDropManager: DragDropManager
    let onPlanChanged: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTarget = false
    
    var body: some View {
        HStack {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
            Image(systemName: "questionmark.folder")
                .foregroundColor(.orange)
            Text("Unorganized Files")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text("\(fileCount) files")
                .font(.caption)
                .foregroundColor(.secondary)
                .numericTextTransition(animationValue: fileCount)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleExpanded)
        .focusable()
        .onKeyPress(.space) {
            toggleExpanded()
            return .handled
        }
        .onKeyPress(.return) {
            toggleExpanded()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(
            named: isExpanded ? "Collapse unorganized files" : "Expand unorganized files",
            toggleExpanded
        )
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTarget ? Color.orange.opacity(0.1) : Color.clear)
                .strokeBorder(isDropTarget ? Color.orange : Color.clear, lineWidth: 2)
        )
        .onDrop(of: [.text], delegate: OptimizedUnorganizedDropDelegate(
            store: store,
            draggedFile: $dragDropManager.draggedFile,
            isTargeted: $isDropTarget,
            onPlanChanged: onPlanChanged
        ))
    }

    private func toggleExpanded() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
            store.toggleFolder(id: PreviewStore.unorganizedSectionID)
        }
    }
}

// MARK: - Flat Unorganized File Row View

struct FlatUnorganizedFileRowView: View {
    @SortyHotReload private var hotReload
    let file: FileItem
    @ObservedObject var dragDropManager: DragDropManager
    let store: PreviewStore
    let duplicateInfo: DuplicateInfo?
    let isHighlighted: Bool
    let moveDestinations: [PreviewMoveDestination]
    let reason: String?
    let onPlanChanged: () -> Void
    @State private var isDragging = false

    var body: some View {
        HStack {
            FileThumbnailView(url: URL(fileURLWithPath: file.path), size: CGSize(width: 20, height: 20))
            VStack(alignment: .leading, spacing: 1) {
                Text(file.displayName)
                if let reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()

            if let dupInfo = duplicateInfo {
                LiquidGlassDuplicateButton(
                    duplicateInfo: dupInfo,
                    highlightedFileID: Binding(
                        get: { store.highlightedFileID },
                        set: { store.highlightedFileID = $0 }
                    )
                )
            }

            Text(file.formattedSize)
                .foregroundColor(.secondary)

            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.12) : (isDragging ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.1) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isHighlighted ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            
            Button {
                NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            if !moveDestinations.isEmpty {
                Menu("Move to Folder") {
                    ForEach(moveDestinations) { destination in
                        Button(destination.name) {
                            store.moveFile(fileID: file.id, toFolderID: destination.id)
                            onPlanChanged()
                        }
                    }
                }
            }
        }
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
        }
        .focusable()
        .onKeyPress(.return) {
            NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
            return .handled
        }
        .accessibilityAction(named: "Open \(file.displayName)") {
            NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
        }
        .accessibilityAction(named: "Reveal \(file.displayName) in Finder") {
            NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
        }
        .accessibilityActions {
            ForEach(moveDestinations) { destination in
                Button("Move to \(destination.name)") {
                    store.moveFile(fileID: file.id, toFolderID: destination.id)
                    onPlanChanged()
                }
            }
        }
        .opacity(isDragging ? 0.5 : 1.0)
        .onDrag {
            isDragging = true
            dragDropManager.startDrag(file)
            return NSItemProvider(object: file.id.uuidString as NSString)
        }
    }
}

// MARK: - Optimized Drop Delegates

struct OptimizedFileDropDelegate: DropDelegate {
    let targetFolderID: UUID
    let store: PreviewStore
    @Binding var draggedFile: FileItem?
    @Binding var isTargeted: Bool
    let onPlanChanged: () -> Void
    
    func dropEntered(info: DropInfo) {
        isTargeted = true
    }
    
    func dropExited(info: DropInfo) {
        isTargeted = false
    }
    
    func validateDrop(info: DropInfo) -> Bool {
        guard draggedFile != nil else { return false }
        return true
    }
    
    func performDrop(info: DropInfo) -> Bool {
        guard let file = draggedFile else { return false }
        
        store.moveFile(fileID: file.id, toFolderID: targetFolderID)
        onPlanChanged()
        draggedFile = nil
        isTargeted = false
        
        return true
    }
}

struct OptimizedUnorganizedDropDelegate: DropDelegate {
    let store: PreviewStore
    @Binding var draggedFile: FileItem?
    @Binding var isTargeted: Bool
    let onPlanChanged: () -> Void
    
    func dropEntered(info: DropInfo) {
        isTargeted = true
    }
    
    func dropExited(info: DropInfo) {
        isTargeted = false
    }
    
    func validateDrop(info: DropInfo) -> Bool {
        guard let file = draggedFile else { return false }
        return !store.plan.unorganizedFiles.contains { $0.id == file.id }
    }
    
    func performDrop(info: DropInfo) -> Bool {
        guard let file = draggedFile else { return false }
        
        store.moveFileToUnorganized(fileID: file.id)
        onPlanChanged()
        draggedFile = nil
        isTargeted = false
        
        return true
    }
}
