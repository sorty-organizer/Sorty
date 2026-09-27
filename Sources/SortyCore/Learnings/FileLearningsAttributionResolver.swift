import Foundation

public enum LearningsAttributionScope: String, Sendable {
    case fileRuleMatch
    case folderRuleGuidance
}

public enum LearningsAttributionKind: String, Sendable {
    case learnedRule
    case ruleEvidence
}

public struct LearningsAttributionItem: Sendable, Hashable {
    public let kind: LearningsAttributionKind
    public let title: String
    public let detail: String

    public init(kind: LearningsAttributionKind, title: String, detail: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

public struct FileLearningsAttribution: Sendable {
    public let rule: InferredRule?
    public let scope: LearningsAttributionScope?
    public let items: [LearningsAttributionItem]

    public init(rule: InferredRule?, scope: LearningsAttributionScope?, items: [LearningsAttributionItem]) {
        self.rule = rule
        self.scope = scope
        self.items = items
    }

    public var hasContent: Bool {
        !items.isEmpty
    }

    public static let empty = FileLearningsAttribution(rule: nil, scope: nil, items: [])
}

public enum FileLearningsAttributionResolver {
    public static func resolve(
        file: FileItem,
        suggestion: FolderSuggestion,
        profile: LearningsProfile?
    ) -> FileLearningsAttribution {
        guard let profile else {
            return .empty
        }

        let explicitRuleID = resolvedRuleID(for: suggestion)
        let allRules = profile.inferredRules
        let heuristicRules = allRules.filter(isEligibleForHeuristicAttribution)

        let resolvedRule: InferredRule?

        // Explicit model-supplied rule IDs must still pass eligibility filtering,
        // so disabled, rejected, or cooling-down rules are never shown as attribution.
        // Unknown or ineligible IDs fall back to heuristic matching instead of being
        // displayed as raw ID strings.
        if let explicitRuleID,
           let matchedExplicit = allRules.first(where: { $0.id == explicitRuleID }),
           isEligibleForHeuristicAttribution(matchedExplicit) {
            resolvedRule = matchedExplicit
        } else if let heuristicMatch = bestHeuristicRule(file: file, suggestion: suggestion, rules: heuristicRules) {
            resolvedRule = heuristicMatch
        } else {
            resolvedRule = nil
        }

        guard let rule = resolvedRule else {
            return .empty
        }

        let scope = attributionScope(for: file, rule: rule)
        var items: [LearningsAttributionItem] = []

        let confidence = String(describing: rule.confidenceLevel).capitalized
        let ruleTitle = scope == .fileRuleMatch ? "Learned Rule Matched File" : "Learned Rule Guided Folder"
        items.append(
            LearningsAttributionItem(
                kind: .learnedRule,
                title: ruleTitle,
                detail: "\(rule.explanation)\nConfidence: \(confidence) • Support: \(rule.supportCount)"
            )
        )

        if let evidence = normalizedEvidenceText(from: rule) {
            items.append(
                LearningsAttributionItem(
                    kind: .ruleEvidence,
                    title: "Rule Evidence",
                    detail: evidence
                )
            )
        }

        return FileLearningsAttribution(rule: rule, scope: scope, items: items)
    }

    private static func isEligibleForHeuristicAttribution(_ rule: InferredRule) -> Bool {
        guard rule.isEnabled else { return false }

        switch rule.status {
        case .rejected:
            return false
        case .cooldown:
            if let until = rule.cooldownUntil {
                return until <= Date()
            }
            return false
        case .active, .pendingApproval:
            return true
        }
    }

    private static func bestHeuristicRule(
        file: FileItem,
        suggestion: FolderSuggestion,
        rules: [InferredRule]
    ) -> InferredRule? {
        guard !rules.isEmpty else { return nil }

        let scored = rules.compactMap { rule -> (InferredRule, Int)? in
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else {
                return nil
            }

            let score = heuristicScore(rule: rule, regex: regex, file: file, suggestion: suggestion)
            return score >= 55 ? (rule, score) : nil
        }

        return scored.max {
            if $0.1 == $1.1 {
                if $0.0.priority == $1.0.priority {
                    return $0.0.supportCount < $1.0.supportCount
                }
                return $0.0.priority < $1.0.priority
            }
            return $0.1 < $1.1
        }?.0
    }

    private static func heuristicScore(
        rule: InferredRule,
        regex: NSRegularExpression,
        file: FileItem,
        suggestion: FolderSuggestion
    ) -> Int {
        var score = 0

        if matches(regex: regex, text: file.displayName) {
            score += 65
        }

        if matches(regex: regex, text: file.path) {
            score += 55
        }

        if matches(regex: regex, text: suggestion.folderName) {
            score += 28
        }

        if !suggestion.description.isEmpty, matches(regex: regex, text: suggestion.description) {
            score += 14
        }

        let normalizedFolderName = normalizedFolderName(from: suggestion.folderName)
        if !normalizedFolderName.isEmpty,
           rule.template.localizedCaseInsensitiveContains(normalizedFolderName) {
            score += 24
        }

        if let evidence = rule.evidenceDescription,
           !normalizedFolderName.isEmpty,
           evidence.localizedCaseInsensitiveContains(normalizedFolderName) {
            score += 10
        }

        score += min(max(rule.priority, 0), 100) / 10
        score += min(rule.supportCount, 10)

        return score
    }

    private static func matches(regex: NSRegularExpression, text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func normalizedFolderName(from folderName: String) -> String {
        if folderName.hasPrefix("/") {
            return URL(fileURLWithPath: folderName).lastPathComponent
        }
        return folderName
    }

    private static func resolvedRuleID(for suggestion: FolderSuggestion) -> String? {
        if let directRuleID = normalizedRuleID(suggestion.ruleId) {
            return directRuleID
        }

        for tag in suggestion.semanticTags {
            if tag.lowercased().hasPrefix("rule:") {
                let extracted = String(tag.dropFirst("rule:".count))
                if let semanticRuleID = normalizedRuleID(extracted) {
                    return semanticRuleID
                }
            }
        }

        return nil
    }

    private static func normalizedRuleID(_ rawRuleID: String?) -> String? {
        guard let rawRuleID else { return nil }
        let trimmed = rawRuleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func attributionScope(for file: FileItem, rule: InferredRule?) -> LearningsAttributionScope {
        guard let rule else { return .folderRuleGuidance }
        guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else {
            return .folderRuleGuidance
        }

        let fileDisplayName = file.displayName
        let filePath = file.path

        let displayNameRange = NSRange(fileDisplayName.startIndex..<fileDisplayName.endIndex, in: fileDisplayName)
        if regex.firstMatch(in: fileDisplayName, options: [], range: displayNameRange) != nil {
            return .fileRuleMatch
        }

        let filePathRange = NSRange(filePath.startIndex..<filePath.endIndex, in: filePath)
        if regex.firstMatch(in: filePath, options: [], range: filePathRange) != nil {
            return .fileRuleMatch
        }

        return .folderRuleGuidance
    }

    private static func normalizedEvidenceText(from rule: InferredRule) -> String? {
        let trimmed = rule.evidenceDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

}
