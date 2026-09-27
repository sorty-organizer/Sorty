//
//  FileOperation.swift
//  SortyModels
//
//  Undoable filesystem operations recorded in organization history.
//  Top-level (not nested in FileSystemManager) so history snapshots can
//  reference it without depending on SortyCore. Same shape as before, so
//  previously persisted history files keep decoding.
//

import Foundation

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
