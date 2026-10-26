//
//  RoutingRule.swift
//  Sorty
//
//  Deterministic "files like this go there" rules (Labs: Routing Rules).
//

import Foundation
import Combine

/// Sends every file that matches its conditions to one destination folder,
/// without asking the AI.
///
/// Conditions reuse the exclusion engine: ungrouped conditions are OR
/// alternatives, and conditions sharing a `conditionGroupID` must all match.
public struct RoutingRule: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The sentence the user typed. Shown as the rule's title.
    public var sourceText: String
    public var conditions: [ExclusionRule]
    /// Folder path relative to the organized folder. Supports `{YYYY}`, `{MM}`,
    /// `{DD}` and `{Month}`, filled from the file's creation date.
    public var destinationTemplate: String
    public var isEnabled: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        sourceText: String,
        conditions: [ExclusionRule],
        destinationTemplate: String,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceText = sourceText
        self.conditions = conditions
        self.destinationTemplate = Self.sanitizedTemplate(destinationTemplate)
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    /// Keeps destinations inside the organized folder: drops leading `/` and
    /// `~/`, empty and `.` components, and refuses `..`.
    public static func sanitizedTemplate(_ template: String) -> String {
        let components = template
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != "~" }
        guard !components.contains("..") else { return "" }
        return components.joined(separator: "/")
    }

    /// The destination folder for one file, with date tokens filled in.
    public func destination(for file: FileItem, calendar: Calendar = .current) -> String {
        let date = file.creationDate ?? file.modificationDate ?? Date()
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let monthName = calendar.monthSymbols[max(0, (parts.month ?? 1) - 1)]
        return destinationTemplate
            .replacingOccurrences(of: "{YYYY}", with: String(format: "%04d", parts.year ?? 0))
            .replacingOccurrences(of: "{MM}", with: String(format: "%02d", parts.month ?? 0))
            .replacingOccurrences(of: "{DD}", with: String(format: "%02d", parts.day ?? 0))
            .replacingOccurrences(of: "{Month}", with: monthName)
    }

    /// One line describing the conditions, for rule rows and previews.
    public var conditionSummary: String {
        conditions.map(\.displayDescription).joined(separator: conditions.contains { $0.conditionGroupID != nil } ? " and " : " or ")
    }
}

/// An immutable, concurrency-safe snapshot of the enabled routing rules.
/// The first matching rule wins, in the order the user saved them.
public struct RoutingRuleMatcher: Sendable {
    public static let empty = RoutingRuleMatcher(rules: [])

    private let entries: [(rule: RoutingRule, matcher: ExclusionMatcher)]

    public init(rules: [RoutingRule], referenceDate: Date = Date()) {
        entries = rules
            .filter { $0.isEnabled && !$0.conditions.isEmpty && !$0.destinationTemplate.isEmpty }
            .map { ($0, ExclusionMatcher(rules: $0.conditions, referenceDate: referenceDate)) }
            .filter { !$0.1.isEmpty }
    }

    public var isEmpty: Bool { entries.isEmpty }

    public func firstMatch(for file: FileItem) -> RoutingRule? {
        guard !file.isDirectory else { return nil }
        return entries.first { $0.matcher.shouldExclude(file) }?.rule
    }
}

/// Saved routing rules. Loads lazily on first use so launch never decodes them.
@MainActor
public final class RoutingRulesStore: ObservableObject {
    public static let shared = RoutingRulesStore()

    @Published public private(set) var rules: [RoutingRule] = []

    private let userDefaults: UserDefaults
    private let storageKey = "routingRules"

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([RoutingRule].self, from: data) {
            rules = decoded
        }
    }

    public func matcherSnapshot() -> RoutingRuleMatcher {
        RoutingRuleMatcher(rules: rules)
    }

    public func add(_ rule: RoutingRule) {
        rules.append(rule)
        save()
    }

    public func update(_ rule: RoutingRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        save()
    }

    public func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}
