//
//  RenameRuleEngine.swift
//  Sorty
//
//  Applies user-defined rename rules before or instead of AI rename suggestions.
//

import Foundation

public enum RenameRuleApplicationMode: String, Codable, CaseIterable, Sendable {
    case beforeAI
    case rulesOnly

    public var displayName: String {
        switch self {
        case .beforeAI:
            return "Apply Rules Before AI"
        case .rulesOnly:
            return "Use Rules Only"
        }
    }

    public var description: String {
        switch self {
        case .beforeAI:
            return "Rule-based rename candidates are applied first, then Sorty suggestions can improve them."
        case .rulesOnly:
            return "Only custom rules rename files. Sorty suggestions are ignored."
        }
    }
}

public struct RenameRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var pattern: String
    public var replacement: String
    public var isRegex: Bool

    public init(
        id: UUID = UUID(),
        pattern: String,
        replacement: String,
        isRegex: Bool = true
    ) {
        self.id = id
        self.pattern = pattern
        self.replacement = replacement
        self.isRegex = isRegex
    }
}

public enum RenameRuleEngine {
    public static func applyRules(
        to filename: String,
        rules: [RenameRule]
    ) -> String {
        var transformed = filename

        for rule in rules {
            guard !rule.pattern.isEmpty else { continue }

            if rule.isRegex {
                if let regex = try? NSRegularExpression(pattern: rule.pattern) {
                    let range = NSRange(location: 0, length: (transformed as NSString).length)
                    transformed = regex.stringByReplacingMatches(
                        in: transformed,
                        options: [],
                        range: range,
                        withTemplate: rule.replacement
                    )
                }
            } else {
                transformed = transformed.replacingOccurrences(
                    of: rule.pattern,
                    with: rule.replacement
                )
            }
        }

        return transformed
    }
}
