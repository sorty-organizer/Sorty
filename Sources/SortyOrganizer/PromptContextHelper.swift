import Foundation
import SortyFileSystem
import SortyModels
import SortyAI
import SortyLearnings
import SortyFS

enum PromptContextHelper {
    static func duplicateContext(from groups: [DuplicateGroup]) -> String {
        guard !groups.isEmpty else { return "" }

        var context = "\n\nDUPLICATE FILES DETECTED:\n"
        for group in groups {
            context += "- The following files are identical (SHA-256 hash: \(group.hash)):\n"
            for file in group.files {
                context += "  • \(file.displayName) (\(file.path))\n"
            }
        }

        context += "\nRECOMMENDATION FOR DUPLICATES:\n"
        context += "1. If you suggest moving duplicates, try to consolidate them or use a 'Duplicates' folder.\n"
        context += "2. You can suggest better names for them, but keep them in mind for organization.\n"
        return context
    }
}

/// Compact planning and review contracts. AI text never changes file identity
/// or authorizes a destination; the organizer validates every repaired plan.
enum OrganizationPlacementReview {
    static let taxonomyHeading = "## SHARED DESTINATION TAXONOMY"
    static let candidateLimit = 40

    struct Destination: Codable, Sendable {
        let path: String
        let purpose: String
        let examples: [String]
    }

    struct Taxonomy: Codable, Sendable {
        let destinations: [Destination]
    }

    struct Placement: Sendable {
        let file: FileItem
        let destination: String
        let purpose: String
    }

    enum Verdict: String, Codable, Sendable {
        case keep
        case repair
        case needsEvidence = "needs_evidence"
    }

    struct Decision: Codable, Sendable {
        let fileID: Int
        let verdict: Verdict
        let reason: String

        enum CodingKeys: String, CodingKey {
            case fileID = "file_id"
            case verdict, reason
        }
    }

    struct Review: Codable, Sendable {
        let decisions: [Decision]
    }

    static func evidence(for file: FileItem, limit: Int = 600) -> String {
        let values = [
            file.contentMetadata?.documentTitle,
            file.finderComment,
            file.finderTags?.joined(separator: ", "),
            file.contentMetadata?.textPreview,
            file.contentMetadata?.ocrText,
            file.ocrText,
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return String(values.joined(separator: " | ").prefix(limit))
    }

    /// Every file contributes to counts. Examples span source folders and
    /// extensions instead of sampling only the first enumeration batch.
    static func planningPrompt(files: [FileItem], instructions: String, personaPrompt: String?) -> String {
        let groups = Dictionary(grouping: files) { file in
            let parent = file.relativePath ?? file.displayName
            return "\((parent as NSString).deletingLastPathComponent)|\(file.extension.lowercased())"
        }
        let keys = groups.keys.sorted {
            let lhs = groups[$0]?.count ?? 0
            let rhs = groups[$1]?.count ?? 0
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
        let summaries = keys.prefix(120).map { "\($0): \(groups[$0]?.count ?? 0) files" }
        var samples: [FileItem] = []
        let sortedGroups = keys.map { key in
            (groups[key] ?? []).sorted {
                if $0.organizationEvidencePriority != $1.organizationEvidencePriority {
                    return $0.organizationEvidencePriority > $1.organizationEvidencePriority
                }
                return $0.path < $1.path
            }
        }
        for offset in 0..<160 {
            for group in sortedGroups where offset < group.count && samples.count < 160 {
                samples.append(group[offset])
            }
            if samples.count == 160 { break }
        }
        let examples = samples.map {
            "\(String(($0.relativePath ?? $0.displayName).prefix(160))) | \(evidence(for: $0, limit: 180))"
        }
        return """
        Plan reusable destinations for one organization run containing \(files.count) files.
        Follow direct instructions, persona, learnings, reference folders, and existing conventions in that order.
        Keep related project files together across extensions. Folder count and depth have no preset target.
        Return only JSON: {"destinations":[{"path":"Project/Category","purpose":"Shared subject or file role","examples":["observed filename"]}]}.
        Do not assign files, rename files, or call learning tools. Paths must follow the approved storage rules.
        The overview is bounded: \(min(keys.count, 120)) of \(keys.count) source-folder/type groups and \(samples.count) representative files are shown.
        Unseen files may justify additional destinations during assignment.

        \(PromptBuilder.preservedContext(customInstructions: instructions, personaPrompt: personaPrompt))

        Source folder and extension counts:
        \(summaries.joined(separator: "\n"))
        Representative evidence:
        \(examples.joined(separator: "\n"))
        """
    }

    static func taxonomyContext(from response: String) throws -> String {
        guard response.utf8.count <= 64_000 else { throw AIClientError.invalidResponse }
        let taxonomy = try JSONDecoder().decode(Taxonomy.self, from: Data(response.utf8))
        guard !taxonomy.destinations.isEmpty, taxonomy.destinations.count <= 256 else {
            throw AIClientError.invalidResponse
        }
        var seen: Set<String> = []
        let destinations = try taxonomy.destinations.map { destination in
            let components = destination.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !destination.path.isEmpty, destination.path.count <= 500,
                  !components.contains(".."), !components.contains("."),
                  FilenameNormalizer.invalidFolderNameComponents(in: destination.path).isEmpty,
                  !destination.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(destination.path.lowercased()).inserted else {
                throw AIClientError.invalidResponse
            }
            return Destination(path: destination.path,
                               purpose: String(destination.purpose.prefix(240)),
                               examples: destination.examples.prefix(3).map { String($0.prefix(120)) })
        }
        let data = try JSONEncoder().encode(Taxonomy(destinations: destinations))
        return """
        \(taxonomyHeading)
        Use these shared paths, purposes, and examples consistently in every batch.
        Reuse exact path spelling whenever the purpose fits. Add a destination only when file evidence or higher-priority user instructions require it.
        This proposed taxonomy never overrides direct instructions, persona preferences, exclusions, or approved storage paths.
        \(String(decoding: data, as: UTF8.self))
        """
    }

    static func placements(in plan: OrganizationPlan) -> [Placement] {
        var result: [Placement] = []
        func visit(_ folder: FolderSuggestion, parent: String) {
            let path = parent.isEmpty ? folder.folderName : parent + "/" + folder.folderName
            let purpose = [folder.description, folder.reasoning].filter { !$0.isEmpty }.joined(separator: " ")
            result.append(contentsOf: folder.files.map { Placement(file: $0, destination: path, purpose: purpose) })
            for child in folder.subfolders { visit(child, parent: path) }
        }
        for folder in plan.suggestions { visit(folder, parent: "") }
        result.append(contentsOf: plan.unorganizedFiles.map { Placement(file: $0, destination: "unorganized", purpose: "No destination chosen") })
        return result
    }

    static func candidates(in plan: OrganizationPlan) -> [Placement] {
        let flaggedIDs = Set((plan.qualityAssessment?.issues ?? []).flatMap(\.fileIDs))
        let allPlacements = placements(in: plan)
        let genericStems: Set<String> = ["invoice", "report", "photo", "image", "screenshot", "file", "scan", "document", "untitled"]
        func projectStem(_ file: FileItem) -> String? {
            guard !file.hasAmbiguousOrganizationName,
                  let stem = file.name.lowercased().split(whereSeparator: { !$0.isLetter }).first,
                  stem.count >= 3, !genericStems.contains(String(stem)) else { return nil }
            return String(stem)
        }
        var stemDestinations: [String: Set<String>] = [:]
        for placement in allPlacements {
            if let stem = projectStem(placement.file) {
                stemDestinations[stem, default: []].insert(placement.destination)
            }
        }
        let suspicious = allPlacements.filter {
            flaggedIDs.contains($0.file.id) || $0.file.hasAmbiguousOrganizationName
                || $0.destination == "unorganized" || $0.purpose.isEmpty
                || projectStem($0.file).map { (stemDestinations[$0]?.count ?? 0) > 1 } == true
        }.sorted {
            if $0.file.organizationEvidencePriority != $1.file.organizationEvidencePriority {
                return $0.file.organizationEvidencePriority > $1.file.organizationEvidencePriority
            }
            return $0.file.path < $1.file.path
        }
        let groups = Dictionary(grouping: suspicious, by: \.destination)
        let keys = groups.keys.sorted()
        var selected: [Placement] = []
        for offset in 0..<candidateLimit {
            for key in keys where selected.count < candidateLimit {
                if let group = groups[key], offset < group.count { selected.append(group[offset]) }
            }
            if selected.count == candidateLimit { break }
        }
        return selected
    }

    static func reviewPrompt(candidates: [Placement], plan: OrganizationPlan, instructions: String, personaPrompt: String?) -> String {
        let destinations = Array(Set(placements(in: plan).map { "\($0.destination): \(String($0.purpose.prefix(160)))" })).sorted().prefix(100)
        let lines = candidates.enumerated().map { index, placement in
            "\(index + 1)|file:\(placement.file.relativePath ?? placement.file.displayName)|destination:\(placement.destination)|purpose:\(String(placement.purpose.prefix(240)))|evidence:\(evidence(for: placement.file))"
        }
        return """
        Review only the listed file placements against their evidence and the user's organization preferences.
        A mixed-type project, a single-file project, a deep requested hierarchy, or a flat archive can be correct.
        Do not infer an error from file extension, folder size, or depth alone.
        Use keep when the placement is supported, repair when evidence contradicts it, and needs_evidence when more content is necessary.
        Return exactly one decision for every listed local file_id, with a brief concrete reason.
        Return only JSON: {"decisions":[{"file_id":1,"verdict":"keep","reason":"Shared project identifier"}]}.
        \(PromptBuilder.preservedContext(customInstructions: instructions, personaPrompt: personaPrompt))
        Existing destinations:
        \(destinations.joined(separator: "\n"))
        Placements to review:
        \(lines.joined(separator: "\n"))
        """
    }

    static func decisions(from response: String, candidateCount: Int) throws -> [Decision] {
        guard response.utf8.count <= 32_000 else { throw AIClientError.invalidResponse }
        let review = try JSONDecoder().decode(Review.self, from: Data(response.utf8))
        guard candidateCount > 0, review.decisions.count == candidateCount,
              Set(review.decisions.map(\.fileID)) == Set(1...candidateCount),
              review.decisions.allSatisfy({ !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw AIClientError.invalidResponse
        }
        return review.decisions.sorted { $0.fileID < $1.fileID }
    }

    /// Set aside only repair candidates. Reuse the targeted merge so all other
    /// assignments, rename mappings, and tag mappings stay intact.
    static func settingAside(_ files: [FileItem], in plan: OrganizationPlan) -> OrganizationPlan {
        let ids = Set(files.map(\.id))
        func prune(_ folder: FolderSuggestion) -> FolderSuggestion? {
            var result = folder
            result.files.removeAll { ids.contains($0.id) }
            result.fileRenameMappings.removeAll { ids.contains($0.originalFile.id) }
            result.fileTagMappings.removeAll { ids.contains($0.originalFile.id) }
            result.subfolders = folder.subfolders.compactMap(prune)
            return result.files.isEmpty && result.subfolders.isEmpty ? nil : result
        }
        var result = plan
        result.suggestions = plan.suggestions.compactMap(prune)
        result.unorganizedFiles.removeAll { ids.contains($0.id) }
        result.unorganizedFiles.append(contentsOf: files)
        let names = Set(files.map(\.displayName))
        result.unorganizedDetails.removeAll { names.contains($0.filename) }
        result.unorganizedDetails.append(contentsOf: files.map {
            UnorganizedFile(filename: $0.displayName, reason: "Placement needs review against the file evidence.")
        })
        return result
    }
}
