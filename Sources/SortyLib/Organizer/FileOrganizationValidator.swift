//
//  FileOrganizationValidator.swift
//  Sorty
//
//  Validates organization plan before execution
//

import Foundation

struct FileOrganizationValidator {
    static func validateOffMain(
        _ plan: OrganizationPlan,
        at baseURL: URL,
        allowedStorageLocations: [StorageLocation] = [],
        mode: OrganizationMode = .organize
    ) async throws {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try validate(
                plan,
                at: baseURL,
                allowedStorageLocations: allowedStorageLocations,
                mode: mode
            )
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            task.cancel()
        }
    }

    static func validate(
        _ plan: OrganizationPlan,
        at baseURL: URL,
        allowedStorageLocations: [StorageLocation] = [],
        mode: OrganizationMode = .organize
    ) throws {
        let fileManager = FileManager.default
        
        // Check if base directory exists
        guard fileManager.fileExists(atPath: baseURL.path) else {
            throw ValidationError.baseDirectoryNotFound
        }
        
        if mode != .renameOnly {
            // These checks protect AI-created destinations. Rename-only destinations
            // are derived from existing source folders by OrganizationModePlanEnforcer.
            try validateDestinations(plan, at: baseURL, allowedLocations: allowedStorageLocations)
            try checkConflicts(plan, at: baseURL)
        }
        
        // Validate file existence
        try validateFileExistence(plan)
        
        // Large operations are allowed. We keep validation focused on correctness
        // constraints (conflicts, missing files, and storage safety).
    }

    private static func validateDestinations(_ plan: OrganizationPlan, at baseURL: URL, allowedLocations: [StorageLocation]) throws {
        let allowedPaths = Set(allowedLocations.map { StorageLocationPathResolver.resolvedPath($0.path) })

        func checkSuggestion(_ suggestion: FolderSuggestion) throws {
            // Check if this destination is an absolute storage location
            if let absolutePath = StorageLocationPathResolver.normalizedAbsolutePath(from: suggestion.folderName) {
                let resolvedPath = StorageLocationPathResolver.resolvedPath(absolutePath)
                if !isAllowedStorageDestination(resolvedPath, allowedRoots: allowedPaths) {
                    throw ValidationError.invalidStorageLocation(absolutePath)
                }
            }

            // Check subfolders
            for subfolder in suggestion.subfolders {
                try checkSuggestion(subfolder)
            }
        }

        for suggestion in plan.suggestions {
            try checkSuggestion(suggestion)
        }
    }
    
    static func checkConflicts(_ plan: OrganizationPlan, at baseURL: URL) throws {
        var existingPaths: Set<String> = []
        let fileManager = FileManager.default
        
        func checkSuggestion(_ suggestion: FolderSuggestion, parentURL: URL) throws {
            let folderURL: URL
            if let absoluteURL = StorageLocationPathResolver.absoluteURL(from: suggestion.folderName) {
                folderURL = absoluteURL
            } else {
                folderURL = parentURL.appendingPathComponent(suggestion.folderName, isDirectory: true)
            }
            let folderPath = folderURL.path
            
            if existingPaths.contains(folderPath) {
                throw ValidationError.pathConflict(folderPath)
            }
            
            // Allow organizing into existing directories - only reject paths that exist as files
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: folderPath, isDirectory: &isDirectory) {
                if !isDirectory.boolValue {
                    // Path exists but is a file, not a directory - this is a conflict
                    throw ValidationError.pathExists(folderPath)
                }
                // If it's already a directory, that's fine - we can organize into it
            }
            
            existingPaths.insert(folderPath)
            
            // Check subfolders
            for subfolder in suggestion.subfolders {
                try checkSuggestion(subfolder, parentURL: folderURL)
            }
        }
        
        for suggestion in plan.suggestions {
            try checkSuggestion(suggestion, parentURL: baseURL)
        }
    }
    
    static func validateFileExistence(_ plan: OrganizationPlan) throws {
        let fileManager = FileManager.default
        
        func validateFiles(_ suggestion: FolderSuggestion) throws {
            for file in suggestion.files {
                guard let url = file.url else {
                    throw ValidationError.fileNotFound(file.path)
                }
                
                if !fileManager.fileExists(atPath: url.path) {
                    throw ValidationError.fileNotFound(file.path)
                }
            }
            
            for subfolder in suggestion.subfolders {
                try validateFiles(subfolder)
            }
        }
        
        for suggestion in plan.suggestions {
            try validateFiles(suggestion)
        }
        
        for file in plan.unorganizedFiles {
            guard let url = file.url else {
                throw ValidationError.fileNotFound(file.path)
            }
            
            if !fileManager.fileExists(atPath: url.path) {
                throw ValidationError.fileNotFound(file.path)
            }
        }
    }
    
    private static func isAllowedStorageDestination(_ absolutePath: String, allowedRoots: Set<String>) -> Bool {
        for rootPath in allowedRoots where StorageLocationPathResolver.isPath(absolutePath, within: rootPath) {
            return true
        }
        return false
    }
}

enum ValidationError: LocalizedError {
    case baseDirectoryNotFound
    case pathConflict(String)
    case pathExists(String)
    case fileNotFound(String)
    case largeOperation(Int)
    case invalidStorageLocation(String)
    
    var errorDescription: String? {
        switch self {
        case .baseDirectoryNotFound:
            return "Base directory not found"
        case .pathConflict(let path):
            return "Path conflict: \(path)"
        case .pathExists(let path):
            return "Cannot create folder: A file already exists at '\(path)'. Sorty suggested a folder name that conflicts with an existing file."
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .largeOperation(let count):
            return "Large operation detected (\(count) files). Please review carefully."
        case .invalidStorageLocation(let path):
            return "Invalid storage location: \(path). Sorty suggested a path that is not in your approved storage locations list."
        }
    }
}

struct PlanQualityEvaluator {
    private static let vagueNames: Set<String> = [
        "general", "misc", "miscellaneous", "other", "others", "stuff", "unknown", "untitled"
    ]

    static func assess(
        _ plan: OrganizationPlan,
        existingFolderPaths: [String]
    ) -> PlanQualityAssessment {
        let folders = flatten(plan.suggestions)

        var issues: [PlanQualityIssue] = []
        issues.append(contentsOf: excessiveUnorganizedIssues(in: plan))
        issues.append(contentsOf: unorganizedFolderDestinationIssues(in: folders))
        issues.append(contentsOf: duplicateNameIssues(in: folders))
        issues.append(contentsOf: vagueAndSingleFileIssues(in: folders))
        issues.append(contentsOf: mixedTypeIssues(in: folders))
        issues.append(contentsOf: nestingIssues(in: folders))
        issues.append(contentsOf: conventionIssues(in: folders, existingFolderPaths: existingFolderPaths))
        issues.append(contentsOf: explanationIssues(in: folders))

        let score = max(0, 100 - issues.reduce(0) { $0 + $1.deduction })
        return PlanQualityAssessment(score: score, issues: issues)
    }

    static func assessOffMain(
        _ plan: OrganizationPlan,
        existingFolderPaths: [String]
    ) async throws -> PlanQualityAssessment {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let assessment = assess(plan, existingFolderPaths: existingFolderPaths)
            try Task.checkCancellation()
            return assessment
        }
        return try await withTaskCancellationHandler {
            let assessment = try await task.value
            try Task.checkCancellation()
            return assessment
        } onCancel: {
            task.cancel()
        }
    }

    static func existingFolderPathsOffMain(
        at directory: URL,
        maxDepth: Int = 2
    ) async throws -> [String] {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let paths = existingFolderPaths(at: directory, maxDepth: maxDepth)
            try Task.checkCancellation()
            return paths
        }
        return try await withTaskCancellationHandler {
            let paths = try await task.value
            try Task.checkCancellation()
            return paths
        } onCancel: {
            task.cancel()
        }
    }

    private static func excessiveUnorganizedIssues(in plan: OrganizationPlan) -> [PlanQualityIssue] {
        let total = plan.totalFiles
        let count = plan.unorganizedFiles.count
        guard total > 0, count >= 5, Double(count) / Double(total) >= 0.20 else { return [] }

        return [
            PlanQualityIssue(
                kind: .excessiveUnorganizedFiles,
                message: "The plan leaves \(count) of \(total) files unorganized. Ambiguity or a standalone role is not enough: place them in a suitable existing folder, a coherent project folder, or a broad reusable category unless a safety rule explicitly prevents it.",
                folderPaths: [],
                fileIDs: plan.unorganizedFiles.map(\.id),
                deduction: 35
            )
        ]
    }

    private static func unorganizedFolderDestinationIssues(in folders: [FolderRecord]) -> [PlanQualityIssue] {
        folders.compactMap { folder in
            let name = normalizedName(folder.suggestion.folderName)
            guard name == "unorganized" || name == "unorganized file" else { return nil }
            return PlanQualityIssue(
                kind: .unorganizedFolderDestination,
                message: "Folder \"\(folder.path)\" is a disguised unorganized bucket. Choose a useful destination for each file or return genuinely unplaceable files through the `unorganized` field so Sorty leaves them in place.",
                folderPaths: [folder.path],
                fileIDs: folder.files.map(\.id),
                deduction: 35
            )
        }
    }

    static func keepingCertainItems(
        in plan: OrganizationPlan,
        assessment: PlanQualityAssessment
    ) -> OrganizationPlan {
        guard !assessment.passes else {
            var accepted = plan
            accepted.qualityAssessment = assessment
            return accepted
        }

        let uncertainIDs = assessment.uncertainFileIDs
        var uncertainFiles: [FileItem] = []

        func filter(_ folder: FolderSuggestion) -> FolderSuggestion? {
            var updated = folder
            let removed = updated.files.filter { uncertainIDs.contains($0.id) }
            uncertainFiles.append(contentsOf: removed)
            updated.files.removeAll { uncertainIDs.contains($0.id) }
            updated.fileRenameMappings.removeAll { uncertainIDs.contains($0.originalFile.id) }
            updated.fileTagMappings.removeAll { uncertainIDs.contains($0.originalFile.id) }
            updated.subfolders = updated.subfolders.compactMap(filter)
            return updated.files.isEmpty && updated.subfolders.isEmpty ? nil : updated
        }

        var reviewed = plan
        reviewed.suggestions = plan.suggestions.compactMap(filter)
        let existingIDs = Set(reviewed.unorganizedFiles.map(\.id))
        reviewed.unorganizedFiles.append(contentsOf: uncertainFiles.filter { !existingIDs.contains($0.id) })
        reviewed.unorganizedDetails.append(contentsOf: uncertainFiles.map {
            UnorganizedFile(
                filename: $0.displayName,
                reason: "Sorty could not place this file confidently after checking the folder structure twice."
            )
        })
        reviewed.qualityAssessment = assessment
        return reviewed
    }

    static func existingFolderPaths(at directory: URL, maxDepth: Int = 2) -> [String] {
        var paths: [String] = []
        func scan(_ url: URL, depth: Int, prefix: String) {
            guard depth <= maxDepth else { return }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let path = prefix.isEmpty ? child.lastPathComponent : "\(prefix)/\(child.lastPathComponent)"
                paths.append(path)
                scan(child, depth: depth + 1, prefix: path)
            }
        }
        scan(directory, depth: 1, prefix: "")
        return paths
    }

    static func retryInstructions(for assessment: PlanQualityAssessment) -> String {
        assessment.issues.enumerated().map { index, issue in
            "\(index + 1). \(issue.message)"
        }.joined(separator: "\n")
    }

    private struct FolderRecord {
        let path: String
        let depth: Int
        let suggestion: FolderSuggestion
        let files: [FileItem]
    }

    private static func flatten(_ roots: [FolderSuggestion]) -> [FolderRecord] {
        var result: [FolderRecord] = []
        func visit(_ folder: FolderSuggestion, parent: String, depth: Int) -> [FileItem] {
            let path = parent.isEmpty ? folder.folderName : "\(parent)/\(folder.folderName)"
            var files = folder.files
            for child in folder.subfolders {
                files.append(contentsOf: visit(child, parent: path, depth: depth + 1))
            }
            result.append(FolderRecord(path: path, depth: depth, suggestion: folder, files: files))
            return files
        }
        roots.forEach { _ = visit($0, parent: "", depth: 1) }
        return result
    }

    private static func duplicateNameIssues(in folders: [FolderRecord]) -> [PlanQualityIssue] {
        var issues: [PlanQualityIssue] = []
        for index in folders.indices {
            for otherIndex in folders.indices where otherIndex > index {
                let lhs = normalizedName(folders[index].suggestion.folderName)
                let rhs = normalizedName(folders[otherIndex].suggestion.folderName)
                guard lhs == rhs || editDistance(lhs, rhs) <= 2 else { continue }
                let pair = [folders[index], folders[otherIndex]]
                issues.append(PlanQualityIssue(
                    kind: .duplicateFolderNames,
                    message: "Folders \"\(pair[0].path)\" and \"\(pair[1].path)\" have duplicate or nearly identical names. Merge them or give each a distinct purpose.",
                    folderPaths: pair.map(\.path),
                    fileIDs: pair.flatMap(\.files).map(\.id),
                    deduction: 18
                ))
            }
        }
        return issues
    }

    private static func vagueAndSingleFileIssues(in folders: [FolderRecord]) -> [PlanQualityIssue] {
        folders.compactMap { folder in
            let vague = vagueNames.contains(normalizedName(folder.suggestion.folderName))
            let singleFile = folder.files.count == 1 && folder.suggestion.subfolders.isEmpty
            guard vague || singleFile else { return nil }
            let problem = vague && singleFile ? "a vague name and only one file" : vague ? "a vague name" : "only one file"
            return PlanQualityIssue(
                kind: .vagueOrSingleFileFolder,
                message: "Folder \"\(folder.path)\" has \(problem). Use a specific reusable category, merge it, or leave the file in place.",
                folderPaths: [folder.path],
                fileIDs: folder.files.map(\.id),
                deduction: vague ? 14 : 7
            )
        }
    }

    private static func mixedTypeIssues(in folders: [FolderRecord]) -> [PlanQualityIssue] {
        folders.compactMap { folder in
            guard folder.depth == 1, folder.files.count >= 4 else { return nil }
            let families = Set(folder.files.map { typeFamily(for: $0.extension) })
            guard families.count >= 3 else { return nil }
            return PlanQualityIssue(
                kind: .mixedFileTypes,
                message: "Top-level folder \"\(folder.path)\" mixes incompatible file types: \(families.sorted().joined(separator: ", ")). Split it by purpose or leave ambiguous files unchanged.",
                folderPaths: [folder.path],
                fileIDs: folder.files.map(\.id),
                deduction: 14
            )
        }
    }

    private static func nestingIssues(in folders: [FolderRecord]) -> [PlanQualityIssue] {
        folders.compactMap { folder in
            let emptyWrapper = folder.suggestion.files.isEmpty && folder.suggestion.subfolders.count == 1
            guard folder.depth > 2 || emptyWrapper else { return nil }
            return PlanQualityIssue(
                kind: .unnecessaryNesting,
                message: "Folder \"\(folder.path)\" adds a level without improving retrieval. Flatten this branch unless the existing structure requires it.",
                folderPaths: [folder.path],
                fileIDs: folder.files.map(\.id),
                deduction: 10
            )
        }
    }

    private static func explanationIssues(in folders: [FolderRecord]) -> [PlanQualityIssue] {
        folders.compactMap { folder in
            let evidence = folder.suggestion.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            guard evidence.isEmpty else { return nil }
            return PlanQualityIssue(
                kind: .missingExplanation,
                message: "Folder \"\(folder.path)\" has no concrete grouping evidence. Name the shared subject, project, source, date pattern, or compatible file roles.",
                folderPaths: [folder.path],
                fileIDs: folder.files.map(\.id),
                deduction: 10
            )
        }
    }

    private static func conventionIssues(
        in folders: [FolderRecord],
        existingFolderPaths: [String]
    ) -> [PlanQualityIssue] {
        guard !existingFolderPaths.isEmpty else { return [] }
        let existing = existingFolderPaths.map { ($0, normalizedName(URL(fileURLWithPath: $0).lastPathComponent)) }
        return folders.compactMap { folder in
            let proposed = normalizedName(folder.suggestion.folderName)
            guard !existing.contains(where: { $0.1 == proposed }) else { return nil }
            guard let match = existing.first(where: { editDistance($0.1, proposed) <= 2 }) else { return nil }
            return PlanQualityIssue(
                kind: .existingConventionMismatch,
                message: "Folder \"\(folder.path)\" conflicts with the existing \"\(match.0)\" naming convention. Reuse the existing folder when it represents the same category.",
                folderPaths: [folder.path],
                fileIDs: folder.files.map(\.id),
                deduction: 12
            )
        }
    }

    private static func normalizedName(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { token in
                token.count > 3 && token.hasSuffix("s") ? String(token.dropLast()) : token
            }
            .joined(separator: " ")
    }

    private static func typeFamily(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "tif", "tiff", "webp": return "images"
        case "mov", "mp4", "m4v", "avi", "mkv": return "video"
        case "mp3", "m4a", "wav", "aac", "flac": return "audio"
        case "pdf", "doc", "docx", "txt", "rtf", "pages": return "documents"
        case "csv", "xls", "xlsx", "numbers": return "spreadsheets"
        case "zip", "tar", "gz", "7z", "dmg", "pkg": return "archives"
        case "swift", "js", "ts", "py", "json", "yaml", "yml": return "code"
        default: return fileExtension.isEmpty ? "files without extensions" : fileExtension.lowercased()
        }
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        guard lhs != rhs else { return 0 }
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for leftIndex in left.indices {
            var current = [leftIndex + 1]
            for rightIndex in right.indices {
                current.append(Swift.min(
                    Swift.min(current[rightIndex] + 1, previous[rightIndex + 1] + 1),
                    previous[rightIndex] + (left[leftIndex] == right[rightIndex] ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[right.count]
    }
}
