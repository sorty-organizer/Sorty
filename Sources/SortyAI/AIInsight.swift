//
//  AIInsight.swift
//  SortyAI
//
//  Reasoning insights extracted from streaming AI content.
//  Lives here so extractors and organizers share one definition.
//

import Foundation

/// AI reasoning insight extracted from streaming content
public struct AIInsight: Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let category: Category
    public let timestamp: Date
    public let filePath: String? // Optional path for thumbnails

    public enum Category: String, Sendable {
        case file = "File"
        case folder = "Folder"
        case constraint = "Constraint"
        case decision = "Decision"
        case pattern = "Pattern"
        case general = "Analyzing"


    }

    public init(text: String, category: Category, filePath: String? = nil, stableSeed: String? = nil) {
        self.text = text
        self.category = category
        self.timestamp = Date()
        self.filePath = filePath
        self.id = Self.makeStableID(text: text, category: category, filePath: filePath, stableSeed: stableSeed)
    }

    private static func makeStableID(
        text: String,
        category: Category,
        filePath: String?,
        stableSeed: String?
    ) -> String {
        let normalizedText = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedPath = filePath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let normalizedSeed = stableSeed?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        let base = "\(category.rawValue.lowercased())|\(normalizedPath)|\(normalizedText)|\(normalizedSeed)"
        var hash: UInt64 = 1469598103934665603
        for byte in base.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return "insight-\(String(hash, radix: 16))"
    }
}
