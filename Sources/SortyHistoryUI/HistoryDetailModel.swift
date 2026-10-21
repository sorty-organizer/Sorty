import AppKit
import SwiftUI

// MARK: - Liquid Glass AI Reasoning Card (History)

struct HistoryLearningsFileContext: Identifiable {
    let file: FileItem
    let suggestion: FolderSuggestion

    var id: UUID { file.id }
}

struct HistoryDetailModel {
    let entryID: UUID
    let learningsFileContexts: [HistoryLearningsFileContext]
    let duplicateGroups: [DuplicateInfo]
    let totalDuplicateCount: Int

    init(entryID: UUID, plan: OrganizationPlan?) {
        self.entryID = entryID
        guard let plan else {
            learningsFileContexts = []
            duplicateGroups = []
            totalDuplicateCount = 0
            return
        }

        var allFiles = plan.unorganizedFiles
        var learningContexts: [HistoryLearningsFileContext] = []
        var seenLearningFileIDs: Set<UUID> = []

        func hasRuleContext(_ suggestion: FolderSuggestion) -> Bool {
            if let ruleID = suggestion.ruleId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !ruleID.isEmpty {
                return true
            }
            return suggestion.semanticTags.contains { $0.lowercased().hasPrefix("rule:") }
        }

        func collect(_ suggestion: FolderSuggestion) {
            allFiles.append(contentsOf: suggestion.files)
            if hasRuleContext(suggestion) {
                for file in suggestion.files where seenLearningFileIDs.insert(file.id).inserted {
                    learningContexts.append(
                        HistoryLearningsFileContext(file: file, suggestion: suggestion)
                    )
                }
            }
            for subfolder in suggestion.subfolders {
                collect(subfolder)
            }
        }

        for suggestion in plan.suggestions {
            collect(suggestion)
        }

        var uniqueFiles: [FileItem] = []
        var seenPaths: Set<String> = []
        for file in allFiles {
            let path = URL(fileURLWithPath: file.path).standardizedFileURL.path
            if seenPaths.insert(path).inserted {
                uniqueFiles.append(file)
            }
        }

        var filesByHash: [String: [FileItem]] = [:]
        for file in uniqueFiles {
            guard let hash = file.sha256Hash, !hash.isEmpty else { continue }
            filesByHash[hash, default: []].append(file)
        }

        let groups = filesByHash.values.compactMap { files -> DuplicateInfo? in
            guard files.count > 1, let first = files.first else { return nil }
            return DuplicateInfo(file: first, sharedGroup: files)
        }
        .sorted { $0.duplicateCount > $1.duplicateCount }

        learningsFileContexts = learningContexts
        duplicateGroups = groups
        totalDuplicateCount = groups.reduce(0) { $0 + $1.duplicateCount }
    }
}
