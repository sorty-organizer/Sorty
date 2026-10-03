//
//  FileItem.swift
//  Sorty
//
//  File and Directory Model
//

import Foundation
import Darwin

public enum CloudFileStatus: String, Codable, Sendable {
    case local
    case cloudOnly
    case downloading
    case synced
}

public struct FileItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var path: String
    /// Path relative to the directory selected for organization.
    /// This keeps nested-folder context without exposing the absolute path.
    public var relativePath: String?
    public var name: String
    public var `extension`: String
    public var size: Int64
    public var isDirectory: Bool
    public var creationDate: Date?
    public var modificationDate: Date?
    public var lastAccessDate: Date?

    // Deep scanning metadata
    public var contentMetadata: ContentMetadata?

    // For duplicate detection (SHA-256)
    public var sha256Hash: String?
    /// Device and inode captured when this file was scanned for duplicates.
    public var fileSystemIdentity: String?

    // AI-Driven Smart Renaming - suggested filename from AI
    public var suggestedFilename: String?

    // Semantic Content Analysis - OCR extracted text from images
    public var ocrText: String?

    // Semantic duplicate detection - embedding/fingerprint for near-duplicate detection
    public var contentFingerprint: String?

    // Image dimensions for duplicate comparison
    public var imageWidth: Int?
    public var imageHeight: Int?

    // Cloud storage status
    public var cloudStatus: CloudFileStatus?

    // macOS Finder metadata
    public var finderComment: String?
    public var finderTags: [String]?
    public var finderLabelNumber: Int?

    public init(
        id: UUID = UUID(),
        path: String,
        relativePath: String? = nil,
        name: String,
        extension: String = "",
        size: Int64 = 0,
        isDirectory: Bool = false,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        lastAccessDate: Date? = nil,
        contentMetadata: ContentMetadata? = nil,
        sha256Hash: String? = nil,
        fileSystemIdentity: String? = nil,
        suggestedFilename: String? = nil,
        ocrText: String? = nil,
        contentFingerprint: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        cloudStatus: CloudFileStatus? = nil,
        finderComment: String? = nil,
        finderTags: [String]? = nil,
        finderLabelNumber: Int? = nil
    ) {
        self.id = id
        self.path = path
        self.relativePath = relativePath
        self.name = name
        self.extension = `extension`
        self.size = size
        self.isDirectory = isDirectory
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.lastAccessDate = lastAccessDate
        self.contentMetadata = contentMetadata
        self.sha256Hash = sha256Hash
        self.fileSystemIdentity = fileSystemIdentity
        self.suggestedFilename = suggestedFilename
        self.ocrText = ocrText
        self.contentFingerprint = contentFingerprint
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.cloudStatus = cloudStatus
        self.finderComment = finderComment
        self.finderTags = finderTags
        self.finderLabelNumber = finderLabelNumber
    }

    public var url: URL? {
        URL(fileURLWithPath: path)
    }

    public static func currentFileSystemIdentity(at path: String) -> String? {
        var fileStatus = stat()
        guard lstat(path, &fileStatus) == 0,
              (fileStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        return "\(fileStatus.st_dev):\(fileStatus.st_ino)"
    }

    public var displayName: String {
        let url = URL(fileURLWithPath: path)

        let baseName = name.isEmpty
            ? url.deletingPathExtension().lastPathComponent
            : name

        let ext = `extension`.isEmpty
            ? url.pathExtension
            : `extension`

        if ext.isEmpty { return baseName }
        if baseName.isEmpty { return url.lastPathComponent }
        return "\(baseName).\(ext)"
    }

    /// Generated names need more content evidence than descriptive labels.
    /// Shared by prompt budgeting and the bounded placement reviewer.
    package var hasAmbiguousOrganizationName: Bool {
        let stem = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedPrefixes = ["img_", "dsc_", "dscn", "screenshot", "screen shot", "scan", "untitled", "document", "download", "file-"]
        return stem.isEmpty || UUID(uuidString: stem) != nil
            || !stem.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) })
            || generatedPrefixes.contains(where: { stem == $0 || stem.hasPrefix($0) })
    }

    package var organizationEvidencePriority: Int {
        let hasContent = contentMetadata?.isEmpty == false || ocrText?.isEmpty == false
        return (hasAmbiguousOrganizationName ? 4 : 0)
            + (hasContent ? 2 : 0)
            + (finderComment?.isEmpty == false ? 1 : 0)
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// The visible Finder label color, when Finder assigned one to this item.
    public var finderTagColorName: String? {
        finderLabelNumber.flatMap(FinderTagColor.init(rawValue:))?.name
    }

    /// Returns the suggested filename if available, otherwise the original display name
    public var finalDisplayName: String {
        if let suggested = suggestedFilename, !suggested.isEmpty {
            return suggested
        }
        return displayName
    }

    /// Check if this file has semantic content (OCR or extracted text)
    public var hasSemanticContent: Bool {
        if let ocr = ocrText, !ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if let metadata = contentMetadata {
            if let preview = metadata.textPreview, !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            if let metadataOCR = metadata.ocrText, !metadataOCR.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        }
        return false
    }

    /// Get all available text content for AI analysis
    public var semanticTextContent: String? {
        var parts: [String] = []

        if let ocr = ocrText, !ocr.isEmpty {
            parts.append("OCR: \(ocr)")
        }

        if let metadata = contentMetadata {
            if let title = metadata.documentTitle {
                parts.append("Title: \(title)")
            }
            if let preview = metadata.textPreview {
                parts.append("Content: \(preview)")
            }
            if let metadataOCR = metadata.ocrText, !metadataOCR.isEmpty {
                parts.append("OCR: \(metadataOCR)")
            }
            if let keywords = metadata.keywords {
                parts.append("Keywords: \(keywords.joined(separator: ", "))")
            }
            if let detected = metadata.detectedKeywords, !detected.isEmpty {
                parts.append("Detected: \(detected.joined(separator: ", "))")
            }
        }

        if let comment = finderComment, !comment.isEmpty {
            parts.append("Finder Comment: \(comment)")
        }

        if let tags = finderTags, !tags.isEmpty {
            parts.append("Tags: \(tags.joined(separator: ", "))")
        }

        if let finderTagColorName {
            parts.append("Finder Color: \(finderTagColorName)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " | ")
    }

    /// Resolution string for images (e.g., "1920x1080")
    public var resolutionString: String? {
        guard let width = imageWidth, let height = imageHeight else { return nil }
        return "\(width)x\(height)"
    }

    /// Total pixels for resolution comparison
    public var totalPixels: Int? {
        guard let width = imageWidth, let height = imageHeight else { return nil }
        return width * height
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id
    }
}
