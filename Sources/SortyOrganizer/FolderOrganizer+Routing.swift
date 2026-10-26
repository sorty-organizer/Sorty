//
//  FolderOrganizer+Routing.swift
//  Sorty
//
//  Applies saved routing rules before the AI sees a folder (Labs: Routing Rules).
//

import Foundation
import SortyModels

extension FolderOrganizer {
    /// Files a routing rule already placed, and the files still left for the AI.
    struct RoutingPartition {
        var suggestions: [FolderSuggestion] = []
        var remaining: [FileItem]
        var routedCount = 0
    }

    /// Splits scanned files into rule-routed folders and the rest.
    ///
    /// Routing only runs in organize mode, when the Labs flag is on. Rename-only
    /// runs keep files where they are, so routing would contradict them.
    func partitionFilesByRoutingRules(_ files: [FileItem]) -> RoutingPartition {
        guard SortyLabsFeature.routingRules.isEnabled,
              aiConfig?.mode != .renameOnly
        else { return RoutingPartition(remaining: files) }

        let matcher = RoutingRulesStore.shared.matcherSnapshot()
        guard !matcher.isEmpty else { return RoutingPartition(remaining: files) }

        var partition = RoutingPartition(remaining: [])
        var routedByDestination: [String: (rule: RoutingRule, files: [FileItem])] = [:]
        var destinationOrder: [String] = []
        for file in files {
            guard let rule = matcher.firstMatch(for: file) else {
                partition.remaining.append(file)
                continue
            }
            let destination = rule.destination(for: file)
            if routedByDestination[destination] == nil {
                destinationOrder.append(destination)
                routedByDestination[destination] = (rule, [])
            }
            routedByDestination[destination]?.files.append(file)
            partition.routedCount += 1
        }

        let routedSuggestions = destinationOrder.compactMap { destination -> FolderSuggestion? in
            guard let entry = routedByDestination[destination] else { return nil }
            return FolderSuggestion(
                folderName: destination,
                description: "Routed by your rule",
                files: entry.files,
                reasoning: "Matched the routing rule \"\(entry.rule.sourceText)\".",
                semanticTags: ["routing-rule:\(entry.rule.id.uuidString)"],
                confidenceScore: 1
            )
        }
        Self.mergeSuggestions(routedSuggestions, into: &partition.suggestions)
        return partition
    }

    /// Adds rule-routed folders to an AI plan, merging into folders the AI
    /// also chose so one destination never appears twice.
    nonisolated static func mergingRoutedSuggestions(
        _ routed: [FolderSuggestion],
        into plan: OrganizationPlan
    ) -> OrganizationPlan {
        guard !routed.isEmpty else { return plan }
        var merged = plan
        mergeSuggestions(routed, into: &merged.suggestions)
        return merged
    }
}
