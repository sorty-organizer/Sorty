//
//  FolderSuggestion.swift
//  Sorty
//
//  AI-Generated Folder Organization Suggestion with Smart Renaming Support
//

import Foundation

/// Represents a file with its suggested rename
public struct FileRenameMapping: Codable, Identifiable, Hashable, Sendable {
    public static let lowConfidenceThreshold = 0.3
    public static let highConfidenceThreshold = 0.75

    public var id: UUID
    public var originalFile: FileItem
    public var suggestedName: String?
    public var renameReason: String?
    public var renameConfidence: Double?
    public var isSelected: Bool?

    public init(
        id: UUID = UUID(),
        originalFile: FileItem,
        suggestedName: String? = nil,
        renameReason: String? = nil,
        renameConfidence: Double? = nil,
        isSelected: Bool? = nil
    ) {
        self.id = id
        self.originalFile = originalFile
        if let suggestedName, !suggestedName.isEmpty {
            let sanitized = FilenameSanitizer.sanitize(
                suggestedName,
                preservingExtension: originalFile.extension,
                enforceExtension: true
            )
            self.suggestedName = sanitized.sanitizedName
        } else {
            self.suggestedName = nil
        }
        self.renameReason = renameReason
        if let renameConfidence {
            self.renameConfidence = min(max(renameConfidence, 0.0), 1.0)
        } else {
            self.renameConfidence = nil
        }
        self.isSelected = isSelected
    }

    /// Returns the final filename (suggested or original)
    public var finalFilename: String {
        if shouldApplyRename, let suggested = suggestedName, !suggested.isEmpty {
            return suggested
        }
        return originalFile.displayName
    }

    /// Check if this file has a rename suggestion
    public var hasRename: Bool {
        suggestedName != nil && suggestedName != originalFile.displayName
    }

    public var preservesOriginalExtension: Bool {
        let originalExtension = originalFile.extension.lowercased()
        let suggestedExtension = (suggestedName as NSString?)?.pathExtension.lowercased() ?? ""
        return originalExtension == suggestedExtension
    }

    public var isLowConfidence: Bool {
        confidenceBand == .low
    }

    public var isAutoSkippedForLowConfidence: Bool {
        isLowConfidence && hasRename && !shouldApplyRename
    }

    public var confidenceBand: RenameConfidenceBand {
        guard let renameConfidence else { return .high }
        if renameConfidence < Self.lowConfidenceThreshold { return .low }
        if renameConfidence < Self.highConfidenceThreshold { return .medium }
        return .high
    }

    public var shouldApplyRename: Bool {
        hasRename && (isSelected ?? (confidenceBand == .high))
    }
}

public enum RenameConfidenceBand: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low

    public var displayName: String {
        switch self {
        case .high: return "High confidence"
        case .medium: return "Review suggested"
        case .low: return "Low confidence"
        }
    }
}

public struct FolderSuggestion: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var folderName: String
    public var description: String
    public var files: [FileItem]
    public var subfolders: [FolderSuggestion]
    public var reasoning: String

    // Smart renaming support
    public var fileRenameMappings: [FileRenameMapping]
    
    // Tagging support
    public var fileTagMappings: [FileTagMapping]

    // Folder metadata
    public var tags: [String]
    public var comment: String?

    // Semantic analysis metadata
    public var semanticTags: [String]
    public var confidenceScore: Double?

    // Learnings & Rule support
    public var ruleId: String?

    public init(
        id: UUID = UUID(),
        folderName: String,
        description: String = "",
        files: [FileItem] = [],
        subfolders: [FolderSuggestion] = [],
        reasoning: String = "",
        fileRenameMappings: [FileRenameMapping] = [],
        fileTagMappings: [FileTagMapping] = [],
        tags: [String] = [],
        comment: String? = nil,
        semanticTags: [String] = [],
        confidenceScore: Double? = nil,
        ruleId: String? = nil
    ) {
        self.id = id
        self.folderName = folderName
        self.description = description
        self.files = files
        self.subfolders = subfolders
        self.reasoning = reasoning
        self.fileRenameMappings = fileRenameMappings
        self.fileTagMappings = fileTagMappings
        self.tags = tags
        self.comment = comment
        self.semanticTags = semanticTags
        self.confidenceScore = confidenceScore
        self.ruleId = ruleId
    }

    public var totalFileCount: Int {
        files.count + subfolders.reduce(0) { $0 + $1.totalFileCount }
    }

    /// Number of files with rename suggestions in this folder
    public var renameCount: Int {
        let directRenames = fileRenameMappings.filter(\.shouldApplyRename).count
        let subfolderRenames = subfolders.reduce(0) { $0 + $1.renameCount }
        return directRenames + subfolderRenames
    }

    /// Get all file rename mappings including from subfolders
    public var allFileRenameMappings: [FileRenameMapping] {
        var mappings = fileRenameMappings
        for subfolder in subfolders {
            mappings.append(contentsOf: subfolder.allFileRenameMappings)
        }
        return mappings
    }

    /// Get rename mapping for a specific file
    public func renameMapping(for file: FileItem) -> FileRenameMapping? {
        if let mapping = fileRenameMappings.first(where: { $0.originalFile.id == file.id }) {
            return mapping
        }
        for subfolder in subfolders {
            if let mapping = subfolder.renameMapping(for: file) {
                return mapping
            }
        }
        return nil
    }

    /// Get tags for a specific file
    public func tags(for file: FileItem) -> [String] {
        if let mapping = fileTagMappings.first(where: { $0.originalFile.id == file.id }) {
            return mapping.tags
        }
        for subfolder in subfolders {
            let tags = subfolder.tags(for: file)
            if !tags.isEmpty { return tags }
        }
        return []
    }

    /// Get comment for a specific file
    public func comment(for file: FileItem) -> String? {
        if let mapping = fileTagMappings.first(where: { $0.originalFile.id == file.id }) {
            return mapping.comment
        }
        for subfolder in subfolders {
            if let comment = subfolder.comment(for: file) {
                return comment
            }
        }
        return nil
    }

    /// Returns files with their final names (renamed or original)
    public var filesWithFinalNames: [(file: FileItem, finalName: String)] {
        let mappingsByFileID = Dictionary(
            fileRenameMappings.map { ($0.originalFile.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        return files.map { file in
            let mapping = mappingsByFileID[file.id]
            let finalName = mapping?.finalFilename ?? file.displayName
            return (file, finalName)
        }
    }

    // MARK: - Mutating Helpers

    /// Add a file to this folder
    public mutating func addFile(
        _ file: FileItem,
        suggestedName: String? = nil,
        renameReason: String? = nil,
        renameConfidence: Double? = nil
    ) {
        files.append(file)
        if suggestedName != nil {
            let mapping = FileRenameMapping(
                originalFile: file,
                suggestedName: suggestedName,
                renameReason: renameReason,
                renameConfidence: renameConfidence
            )
            fileRenameMappings.append(mapping)
        }
    }

    /// Remove a file from this folder
    public mutating func removeFile(_ file: FileItem) {
        files.removeAll { $0.id == file.id }
        fileRenameMappings.removeAll { $0.originalFile.id == file.id }
    }

    /// Update rename suggestion for a file
    public mutating func updateRename(
        for file: FileItem,
        newName: String?,
        reason: String? = nil,
        confidence: Double? = nil
    ) {
        var sanitizedName: String?
        if let newName, !newName.isEmpty {
            let result = FilenameSanitizer.sanitize(
                newName,
                preservingExtension: file.extension,
                enforceExtension: true
            )
            sanitizedName = result.sanitizedName
        } else {
            sanitizedName = nil
        }

        // Treat no-op rename as "no rename" to avoid forcing unchanged mappings.
        if sanitizedName == file.displayName {
            sanitizedName = nil
        }

        if let index = fileRenameMappings.firstIndex(where: { $0.originalFile.id == file.id }) {
            fileRenameMappings[index].suggestedName = sanitizedName
            fileRenameMappings[index].renameReason = reason ?? fileRenameMappings[index].renameReason
            fileRenameMappings[index].isSelected = sanitizedName != nil
            if let confidence {
                fileRenameMappings[index].renameConfidence = min(max(confidence, 0.0), 1.0)
            }
        } else if sanitizedName != nil {
            let mapping = FileRenameMapping(
                originalFile: file,
                suggestedName: sanitizedName,
                renameReason: reason,
                renameConfidence: confidence,
                isSelected: true
            )
            fileRenameMappings.append(mapping)
        }
    }

    public mutating func setRenameSelected(for fileID: UUID, isSelected: Bool) {
        guard let index = fileRenameMappings.firstIndex(where: { $0.originalFile.id == fileID }) else {
            return
        }
        fileRenameMappings[index].isSelected = isSelected
    }
}

/// Represents a file with its suggested tags
public struct FileTagMapping: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var originalFile: FileItem
    public var tags: [String]
    public var comment: String?

    public init(
        id: UUID = UUID(),
        originalFile: FileItem,
        tags: [String] = [],
        comment: String? = nil
    ) {
        self.id = id
        self.originalFile = originalFile
        self.tags = tags
        self.comment = comment
    }
}

public extension FolderSuggestion {
    mutating func addTag(_ tag: String, for file: FileItem) {
        if let index = fileTagMappings.firstIndex(where: { $0.originalFile.id == file.id }) {
            if !fileTagMappings[index].tags.contains(tag) {
                fileTagMappings[index].tags.append(tag)
            }
        } else {
            let mapping = FileTagMapping(
                originalFile: file,
                tags: [tag]
            )
            fileTagMappings.append(mapping)
        }
    }
}
