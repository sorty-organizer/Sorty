//
//  ProjectClusterDetector.swift
//  Sorty
//
//  Finds loose files that belong to one project, trip or event (Labs: Project Detection).
//

import Foundation
import SortyAI
import SortyModels

/// A group of files that share a distinctive name token, such as "tokyo" or
/// "acme", across more than one kind of file.
struct ProjectCluster: Equatable, Sendable {
    let label: String
    let fileNames: [String]
}

/// Groups files by distinctive words in their names so the AI keeps, say, a
/// trip's photos and its booking PDFs together instead of splitting them by type.
///
/// A word qualifies when it appears in at least three files, spans at least two
/// file categories, and is not common to most of the folder.
enum ProjectClusterDetector {
    static let maximumClusters = 8
    static let maximumListedFiles = 30

    private static let ignoredTokens: Set<String> = [
        "img", "dsc", "dscn", "pxl", "mvimg", "scan", "scanned", "screenshot", "screen", "shot",
        "copy", "final", "draft", "file", "files", "document", "doc", "untitled", "image",
        "photo", "video", "new", "the", "and", "for", "with", "from", "version", "edit",
        "edited", "export", "exported", "download", "downloads", "page", "part", "temp",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december", "jan", "feb", "mar", "apr",
        "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "cleanshot", "pdf",
    ]

    static func detect(in files: [FileItem]) -> [ProjectCluster] {
        let candidates = files.filter { !$0.isDirectory }
        guard candidates.count >= 3 else { return [] }

        var filesByToken: [String: [Int]] = [:]
        for (index, file) in candidates.enumerated() {
            for token in Set(tokens(in: file.name)) {
                filesByToken[token, default: []].append(index)
            }
        }

        // Words shared by most of the folder describe the folder, not a project.
        let maximumShare = candidates.count >= 8 ? max(3, candidates.count * 2 / 5) : candidates.count
        let ranked = filesByToken
            .filter { $0.value.count >= 3 && $0.value.count <= maximumShare }
            .sorted { lhs, rhs in
                lhs.value.count == rhs.value.count ? lhs.key < rhs.key : lhs.value.count > rhs.value.count
            }

        var claimed = Set<Int>()
        var clusters: [ProjectCluster] = []
        for (token, indices) in ranked where clusters.count < maximumClusters {
            let members = indices.filter { !claimed.contains($0) }
            guard members.count >= 3 else { continue }
            let categories = Set(members.map { category(for: candidates[$0]) })
            guard categories.count >= 2 else { continue }
            claimed.formUnion(members)
            clusters.append(ProjectCluster(
                label: token,
                fileNames: members.map { candidates[$0].displayName }
            ))
        }
        return clusters
    }

    /// Prompt section asking the AI to keep each cluster in one folder, or nil
    /// when nothing qualifies.
    static func promptContext(clusters: [ProjectCluster], protectedProjectFolders: [String]) -> String? {
        var sections: [String] = []
        if !clusters.isEmpty {
            let lines = clusters.map { cluster in
                let listed = cluster.fileNames.prefix(maximumListedFiles)
                    .map(PromptBuilder.promptSafeFilename)
                    .joined(separator: ", ")
                let overflow = cluster.fileNames.count > maximumListedFiles
                    ? ", and \(cluster.fileNames.count - maximumListedFiles) more" : ""
                return "- \"\(cluster.label)\" (\(cluster.fileNames.count) files): \(listed)\(overflow)"
            }
            sections.append("""
            PROJECT CLUSTERS: Each group below shares a project, trip, client or event. Put every file in a group into the same destination folder, even when the file types differ, unless the user's instructions say otherwise. Name that folder after what the group is about.
            \(lines.joined(separator: "\n"))
            """)
        }
        if !protectedProjectFolders.isEmpty {
            let listed = protectedProjectFolders.prefix(20).joined(separator: ", ")
            sections.append("PROTECTED PROJECTS: These code projects stay where they are and are not in the file list. Do not create folders with the same names: \(listed)")
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// Lowercased words from a file name, split on punctuation, digits and camelCase.
    static func tokens(in name: String) -> [String] {
        let base = (name as NSString).deletingPathExtension
        var words: [String] = []
        var current = ""
        var previousWasLower = false
        for character in base {
            if character.isLetter {
                if character.isUppercase, previousWasLower, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(character)
                previousWasLower = character.isLowercase
            } else {
                if !current.isEmpty { words.append(current) }
                current = ""
                previousWasLower = false
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
            .map { $0.lowercased() }
            .filter { $0.count >= 3 && !ignoredTokens.contains($0) }
    }

    private static func category(for file: FileItem) -> FileTypeCategory {
        let fileExtension = file.extension.lowercased()
        return FileTypeCategory.allCases.first { $0.extensions.contains(fileExtension) } ?? .other
    }
}
