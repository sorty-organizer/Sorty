//
//  ContentMetadata.swift
//  SortyModels
//
//  Content metadata extracted from files (PDF text, EXIF, OCR, media).
//  Lives here so model types can reference it without depending on SortyCore.
//

import Foundation

/// Metadata extracted from file content
public struct ContentMetadata: Codable, Hashable, Sendable {
    public var textPreview: String?          // First ~200 chars of text content
    public var documentTitle: String?         // Title from document metadata
    public var exifData: [String: String]?    // Camera, date, GPS for images
    public var pageCount: Int?               // For documents
    public var author: String?               // Author metadata
    public var creationDate: Date?           // Document creation date
    public var keywords: [String]?           // Keywords/tags if available
    public var ocrText: String?              // OCR extracted text from images
    public var ocrConfidence: Float?         // OCR confidence score
    public var detectedKeywords: [String]?   // Keywords detected in OCR text
    public var duration: TimeInterval?       // Duration in seconds for audio/video
    public var mediaInfo: [String: String]?  // Codec, bitrate, title, artist, album, genre

    public init(
        textPreview: String? = nil,
        documentTitle: String? = nil,
        exifData: [String: String]? = nil,
        pageCount: Int? = nil,
        author: String? = nil,
        creationDate: Date? = nil,
        keywords: [String]? = nil,
        ocrText: String? = nil,
        ocrConfidence: Float? = nil,
        detectedKeywords: [String]? = nil,
        duration: TimeInterval? = nil,
        mediaInfo: [String: String]? = nil
    ) {
        self.textPreview = textPreview
        self.documentTitle = documentTitle
        self.exifData = exifData
        self.pageCount = pageCount
        self.author = author
        self.creationDate = creationDate
        self.keywords = keywords
        self.ocrText = ocrText
        self.ocrConfidence = ocrConfidence
        self.detectedKeywords = detectedKeywords
        self.duration = duration
        self.mediaInfo = mediaInfo
    }

    public var isEmpty: Bool {
        textPreview == nil
            && documentTitle == nil
            && exifData == nil
            && pageCount == nil
            && author == nil
            && creationDate == nil
            && keywords == nil
            && ocrText == nil
            && ocrConfidence == nil
            && detectedKeywords == nil
            && duration == nil
            && mediaInfo == nil
    }

    /// All available text content (document text + OCR)
    public var allTextContent: String? {
        var parts: [String] = []
        if let preview = textPreview { parts.append(preview) }
        if let ocr = ocrText { parts.append(ocr) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Summary for AI prompt
    public var summary: String {
        var parts: [String] = []

        if let title = documentTitle {
            parts.append("Title: \"\(title)\"")
        }
        if let preview = textPreview {
            let trimmed = preview.prefix(500).replacingOccurrences(of: "\n", with: " ")
            parts.append("Content: \"\(trimmed)...\"")
        }
        if let ocr = ocrText {
            let trimmed = ocr.prefix(400).replacingOccurrences(of: "\n", with: " ")
            parts.append("OCR: \"\(trimmed)...\"")
        }
        if let detected = detectedKeywords, !detected.isEmpty {
            parts.append("Detected: \(detected.joined(separator: ", "))")
        }
        if let exif = exifData {
            if let camera = exif["camera"] {
                parts.append("Camera: \(camera)")
            }
            if let date = exif["dateTime"] {
                parts.append("Taken: \(date)")
            }
        }
        if let pages = pageCount {
            parts.append("\(pages) pages")
        }
        if let duration = duration {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            parts.append("Duration: \(minutes)m \(seconds)s")
        }
        if let info = mediaInfo {
            if let artist = info["artist"] {
                parts.append("Artist: \(artist)")
            }
            if let title = info["title"] {
                parts.append("Track: \(title)")
            }
        }

        return parts.isEmpty ? "" : "[\(parts.joined(separator: ", "))]"
    }
}
