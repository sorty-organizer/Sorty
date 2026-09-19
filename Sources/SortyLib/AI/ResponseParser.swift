//
//  ResponseParser.swift
//  Sorty
//
//  Parses AI JSON responses into OrganizationPlan
//  Updated to support Smart Renaming feature
//

import Foundation

struct ResponseParser {
    // MARK: - Response Models

    private struct FileLookup {
        let files: [FileItem]
        private let exactNames: [String: FileItem]
        private let foldedNames: [String: FileItem]
        private let extensions: [String: FileItem]

        init(files: [FileItem]) {
            self.files = files
            var exactNames: [String: FileItem] = [:]
            var foldedNames: [String: FileItem] = [:]
            var extensions: [String: FileItem] = [:]
            exactNames.reserveCapacity(files.count * 2)
            foldedNames.reserveCapacity(files.count * 2)

            for file in files {
                if exactNames[file.displayName] == nil {
                    exactNames[file.displayName] = file
                }
                if exactNames[file.name] == nil {
                    exactNames[file.name] = file
                }

                let displayKey = file.displayName.lowercased()
                let nameKey = file.name.lowercased()
                if foldedNames[displayKey] == nil {
                    foldedNames[displayKey] = file
                }
                if foldedNames[nameKey] == nil {
                    foldedNames[nameKey] = file
                }

                let extensionKey = file.extension.lowercased()
                if !extensionKey.isEmpty, extensions[extensionKey] == nil {
                    extensions[extensionKey] = file
                }
            }

            self.exactNames = exactNames
            self.foldedNames = foldedNames
            self.extensions = extensions
        }

        func resolve(_ filename: String) -> FileItem? {
            let candidates = ResponseParser.normalizedFilenameCandidates(from: filename)
            guard !candidates.isEmpty else { return nil }

            for candidate in candidates {
                if let exact = exactNames[candidate] {
                    return exact
                }
            }
            for candidate in candidates {
                if let folded = foldedNames[candidate.lowercased()] {
                    return folded
                }
            }
            for candidate in candidates where candidate.count <= 5 && !candidate.contains(".") {
                if let extensionMatch = extensions[candidate.lowercased()] {
                    return extensionMatch
                }
            }

            // Suffix/path match comes before any fuzzy logic, so qualified
            // paths bind to their exact file instead of a substring sibling.
            // Example: "docs/report.pdf" must prefer docs/report.pdf over report.pdf.
            let loweredCandidates = candidates.map { $0.lowercased() }
            var suffixMatches: [FileItem] = []
            var seenSuffixIDs = Set<UUID>()
            for file in files {
                let fileLower = file.displayName.lowercased()
                let nameLower = file.name.lowercased()
                let matchesSuffix = loweredCandidates.contains { candidate in
                    guard !candidate.isEmpty else { return false }
                    return fileLower.hasSuffix("/" + candidate)
                        || nameLower.hasSuffix("/" + candidate)
                        || fileLower == candidate
                        || nameLower == candidate
                }
                if matchesSuffix, seenSuffixIDs.insert(file.id).inserted {
                    suffixMatches.append(file)
                }
            }
            if suffixMatches.count == 1, let unique = suffixMatches.first {
                return unique
            }
            if suffixMatches.count > 1 {
                // Ambiguous suffix (e.g. two folders each hold report.pdf):
                // fall through to no match rather than first-match-wins.
                return nil
            }

            // Last-resort substring match requires a unique hit. Returning the
            // first of several "contains" hits misbinds siblings such as
            // report.pdf vs report_final.pdf, so ambiguity resolves to nil.
            var substringMatches: [FileItem] = []
            var seenSubstringIDs = Set<UUID>()
            for candidate in candidates where candidate.count > 3 {
                let lowered = candidate.lowercased()
                for file in files {
                    let displayLower = file.displayName.lowercased()
                    let nameLower = file.name.lowercased()
                    if displayLower.contains(lowered) || lowered.contains(displayLower)
                        || nameLower.contains(lowered) || lowered.contains(nameLower) {
                        if seenSubstringIDs.insert(file.id).inserted {
                            substringMatches.append(file)
                        }
                    }
                }
            }
            if substringMatches.count == 1, let unique = substringMatches.first {
                return unique
            }
            return nil
        }
    }

    private struct LossyArray<Element: Decodable>: Decodable {
        let elements: [Element]
        let droppedCount: Int

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var decoded: [Element] = []
            var dropped = 0

            while !container.isAtEnd {
                let elementDecoder = try container.superDecoder()
                if let element = try? Element(from: elementDecoder) {
                    decoded.append(element)
                } else {
                    dropped += 1
                }
            }

            elements = decoded
            droppedCount = dropped
        }
    }

    /// Counts of response entries the parser could not map to real files.
    /// Surfaced on the plan so partial/hallucinated output is never silent.
    struct ParseDiagnostics {
        var unresolvedFilenames: [String] = []
        var hallucinatedIDs: [Int] = []
        var droppedElements: Int = 0

        var hasIssues: Bool {
            !unresolvedFilenames.isEmpty || !hallucinatedIDs.isEmpty || droppedElements > 0
        }
    }

    struct AIResponse: Decodable {
        let sessionName: String?
        let folders: [FolderResponse]
        let folderAssignments: [FolderResponse]?
        let unorganized: [UnorganizedFileResponse]?
        let unorganizedIDs: [Int]?
        let notes: String?
        let learningToolCall: LearningToolCall?
        let droppedElementCount: Int

        enum CodingKeys: String, CodingKey {
            case folders, unorganized, notes
            case sessionName = "session_name"
            case folderAssignments = "folder_assignments"
            case unorganizedIDs = "unorganized_ids"
            case learningToolCall = "learning_action"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName)
            let foldersLossy = try container.decodeIfPresent(LossyArray<FolderResponse>.self, forKey: .folders)
            folders = foldersLossy?.elements ?? []
            let assignmentsLossy = try container.decodeIfPresent(
                LossyArray<FolderResponse>.self,
                forKey: .folderAssignments
            )
            folderAssignments = assignmentsLossy?.elements
            unorganized = try container.decodeIfPresent([UnorganizedFileResponse].self, forKey: .unorganized)
            unorganizedIDs = try container.decodeIfPresent([Int].self, forKey: .unorganizedIDs)
            notes = try container.decodeIfPresent(String.self, forKey: .notes)
            learningToolCall = try container.decodeIfPresent(
                LearningToolCall.self,
                forKey: .learningToolCall
            )
            droppedElementCount = (foldersLossy?.droppedCount ?? 0) + (assignmentsLossy?.droppedCount ?? 0)
        }
    }


    struct FolderResponse: Decodable {
        let name: String
        let description: String?
        let reasoning: String?
        let subfolders: [FolderResponse]?
        let files: [FileEntry]
        let tags: [String]?
        let comment: String?
        let semanticTags: [String]?
        let confidence: Double?
        let ruleId: String?
        let fileIDs: [Int]?
        let renameSuggestions: [RenameSuggestionResponse]?
        let droppedNestedCount: Int

        // Support both array of strings and array of FileEntry objects
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
            let subfoldersLossy = try container.decodeIfPresent(
                LossyArray<FolderResponse>.self,
                forKey: .subfolders
            )
            subfolders = subfoldersLossy?.elements
            tags = try container.decodeIfPresent([String].self, forKey: .tags)
            comment = try container.decodeIfPresent(String.self, forKey: .comment)
            semanticTags = try container.decodeIfPresent([String].self, forKey: .semanticTags)
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
            ruleId = try container.decodeIfPresent(String.self, forKey: .ruleId)
            fileIDs = try container.decodeIfPresent([Int].self, forKey: .fileIDs)
            let renamesLossy = try container.decodeIfPresent(
                LossyArray<RenameSuggestionResponse>.self,
                forKey: .renameSuggestions
            )
            renameSuggestions = renamesLossy?.elements
            droppedNestedCount = (subfoldersLossy?.droppedCount ?? 0) + (renamesLossy?.droppedCount ?? 0)

            // Try to decode files as FileEntry array first
            if let fileEntries = try? container.decode([FileEntry].self, forKey: .files) {
                files = fileEntries
            } else if let fileStrings = try? container.decode([String].self, forKey: .files) {
                // Fallback: convert string array to FileEntry array
                files = fileStrings.map { FileEntry(filename: $0) }
            } else {
                files = []
            }
        }

        enum CodingKeys: String, CodingKey {
            case name, description, reasoning, subfolders, files
            case tags, comment
            case semanticTags = "semantic_tags"
            case confidence
            case ruleId = "rule_id"
            case fileIDs = "file_ids"
            case renameSuggestions = "rename_suggestions"
        }
    }

    struct RenameSuggestionResponse: Decodable {
        let fileID: Int
        let suggestedName: String?
        let renameReason: String?
        let renameConfidence: Double?

        enum CodingKeys: String, CodingKey {
            case fileID = "file_id"
            case suggestedName = "suggested_name"
            case renameReason = "rename_reason"
            case renameConfidence = "rename_confidence"
        }
    }


    /// Represents a file entry in the AI response with optional rename suggestion
    struct FileEntry: Codable {
        let filename: String
        let suggestedName: String?
        let renameReason: String?
        let renameConfidence: Double?
        let tags: [String]?
        let comment: String?

        init(
            filename: String,
            suggestedName: String? = nil,
            renameReason: String? = nil,
            renameConfidence: Double? = nil,
            tags: [String]? = nil,
            comment: String? = nil
        ) {
            self.filename = filename
            self.suggestedName = suggestedName
            self.renameReason = renameReason
            self.renameConfidence = renameConfidence
            self.tags = tags
            self.comment = comment
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(filename, forKey: .filename)
            try container.encodeIfPresent(suggestedName, forKey: .suggestedName)
            try container.encodeIfPresent(renameReason, forKey: .renameReason)
            try container.encodeIfPresent(renameConfidence, forKey: .renameConfidence)
            try container.encodeIfPresent(tags, forKey: .tags)
            try container.encodeIfPresent(comment, forKey: .comment)
        }

        // Support both simple string and object format
        init(from decoder: Decoder) throws {
            // Try to decode as a simple string first
            if let container = try? decoder.singleValueContainer(),
               let simpleFilename = try? container.decode(String.self) {
                self.filename = simpleFilename
                self.suggestedName = nil
                self.renameReason = nil
                self.renameConfidence = nil
                self.tags = nil
                self.comment = nil
                return
            }

            // Otherwise decode as object
            let container = try decoder.container(keyedBy: CodingKeys.self)
            filename = try container.decode(String.self, forKey: .filename)
            suggestedName = try container.decodeIfPresent(String.self, forKey: .suggestedName)
            renameReason = try container.decodeIfPresent(String.self, forKey: .renameReason)
            renameConfidence = try container.decodeIfPresent(Double.self, forKey: .renameConfidence)
            tags = try container.decodeIfPresent([String].self, forKey: .tags)
            comment = try container.decodeIfPresent(String.self, forKey: .comment)
        }

        enum CodingKeys: String, CodingKey {
            case filename
            case suggestedName = "suggested_name"
            case renameReason = "rename_reason"
            case renameConfidence = "rename_confidence"
            case tags
            case comment
        }
    }


    struct UnorganizedFileResponse: Decodable {
        let filename: String
        let reason: String

        init(filename: String, reason: String) {
            self.filename = filename
            self.reason = reason
        }

        init(from decoder: Decoder) throws {
            if let container = try? decoder.singleValueContainer(),
               let simpleFilename = try? container.decode(String.self) {
                self.filename = simpleFilename
                self.reason = "Marked as unorganized by AI response"
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let decodedFilename = try? container.decode(String.self, forKey: .filename) {
                self.filename = decodedFilename
            } else if let fallbackFilename = try? container.decode(String.self, forKey: .file) {
                self.filename = fallbackFilename
            } else {
                throw DecodingError.keyNotFound(
                    CodingKeys.filename,
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing filename")
                )
            }

            let decodedReason = (try? container.decode(String.self, forKey: .reason))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let decodedReason, !decodedReason.isEmpty {
                self.reason = decodedReason
            } else {
                self.reason = "Marked as unorganized by AI response"
            }
        }

        enum CodingKeys: String, CodingKey {
            case filename
            case reason
            case file
        }
    }

    // MARK: - Parsing

    /// Strip progress preamble lines (lines starting with ">> ") from before the JSON
    static func stripProgressPreamble(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        var pastPreamble = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !pastPreamble && trimmed.hasPrefix(">> ") {
                if let jsonStart = embeddedJSONStart(inProgressLine: line) {
                    let jsonPortion = String(line[jsonStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !jsonPortion.isEmpty {
                        pastPreamble = true
                        result.append(jsonPortion)
                    }
                }
                continue
            }
            if !pastPreamble && trimmed.isEmpty {
                continue
            }
            pastPreamble = true
            result.append(line)
        }
        return result.joined(separator: "\n")
    }

    private static func embeddedJSONStart(inProgressLine line: String) -> String.Index? {
        let lowered = line.lowercased()
        guard lowered.contains("ready to output organization structure") else { return nil }

        let objectStart = line.firstIndex(of: "{")
        let arrayStart = line.firstIndex(of: "[")

        switch (objectStart, arrayStart) {
        case let (.some(lhs), .some(rhs)):
            return lhs < rhs ? lhs : rhs
        case let (.some(lhs), .none):
            return lhs
        case let (.none, .some(rhs)):
            return rhs
        case (.none, .none):
            return nil
        }
    }

    static func parseResponse(
        _ jsonString: String,
        originalFiles: [FileItem],
        mode: OrganizationMode = .organize
    ) throws -> OrganizationPlan {
        // Strip progress preamble lines before JSON
        var cleanedJSON = stripProgressPreamble(jsonString)

        // Clean the JSON string - remove markdown code blocks if present
        cleanedJSON = cleanedJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedJSON.hasPrefix("```json") {
            cleanedJSON = String(cleanedJSON.dropFirst(7))
        }
        if cleanedJSON.hasPrefix("```") {
            cleanedJSON = String(cleanedJSON.dropFirst(3))
        }
        if cleanedJSON.hasSuffix("```") {
            cleanedJSON = String(cleanedJSON.dropLast(3))
        }
        cleanedJSON = cleanedJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanedJSON = sanitizeJSONPayload(cleanedJSON)

        guard let jsonData = cleanedJSON.data(using: .utf8) else {
            throw ParserError.invalidJSON
        }
        let fileLookup = FileLookup(files: originalFiles)

        // Check for ultra-compact format first
        if let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            if let compactFolders = jsonObject["f"] as? [[String: Any]] {
                // Parse ultra-compact format: {"f":[{"n":"Folder","files":[]}]}
                var unresolvedCompact = 0
                let suggestions = compactFolders.compactMap { dict -> FolderSuggestion? in
                    guard let name = dict["n"] as? String,
                          let fileNames = dict["files"] as? [String] else { return nil }

                    var files: [FileItem] = []
                    for fileName in fileNames {
                        if let file = fileLookup.resolve(fileName) {
                            files.append(file)
                        } else {
                            unresolvedCompact += 1
                        }
                    }

                    return FolderSuggestion(
                        folderName: name,
                        files: files,
                        reasoning: "Generated from ultra-compact format"
                    )
                }

                guard !suggestions.isEmpty else {
                    throw ParserError.missingRequiredFields
                }

                // Identify unorganized files
                let organizedIds = Set(suggestions.flatMap { $0.files }.map { $0.id })
                let unorganizedFiles = originalFiles.filter { !organizedIds.contains($0.id) }
                let isPartialCompact = unresolvedCompact > 0 || !unorganizedFiles.isEmpty
                var compactWarnings: [String] = []
                if unresolvedCompact > 0 {
                    compactWarnings.append("\(unresolvedCompact) filename(s) could not be matched to scanned files and were skipped.")
                }
                if !unorganizedFiles.isEmpty {
                    compactWarnings.append("\(unorganizedFiles.count) file(s) were not mapped by the AI and kept unorganized.")
                }
                var compactNotes = "Processed via ultra-compact strategy"
                if isPartialCompact {
                    compactNotes += ". Partial plan: \(compactWarnings.joined(separator: " ")) Retry with fewer files or clearer filenames if mappings look wrong."
                }

                return OrganizationPlan(
                    suggestions: suggestions,
                    unorganizedFiles: unorganizedFiles,
                    notes: compactNotes,
                    timestamp: Date(),
                    version: 1,
                    isPartial: isPartialCompact,
                    needsReview: isPartialCompact,
                    parseWarnings: compactWarnings
                )
            }
        }

        let decoder = JSONDecoder()
        // Do NOT use convertFromSnakeCase here as we handle it in CodingKeys

        let response: AIResponse

        do {
            response = try decoder.decode(AIResponse.self, from: jsonData)
        } catch {
            // Try with default key strategy
            let defaultDecoder = JSONDecoder()
            response = try defaultDecoder.decode(AIResponse.self, from: jsonData)
        }

        let fileIdIndex = Dictionary(uniqueKeysWithValues: originalFiles.enumerated().map { ($0.offset + 1, $0.element) })

        var folderDiagnostics = ParseDiagnostics()
        folderDiagnostics.droppedElements += response.droppedElementCount
        let folderSuggestions: [FolderSuggestion] = response.folders.map { folder in
            convertFolderResponse(
                folder,
                fileLookup: fileLookup,
                fileIdIndex: fileIdIndex,
                mode: mode,
                diagnostics: &folderDiagnostics
            )
        }
        var assignmentDiagnostics = ParseDiagnostics()
        assignmentDiagnostics.droppedElements += response.droppedElementCount
        let assignmentSuggestions: [FolderSuggestion] = (response.folderAssignments ?? []).map { folder in
            convertFolderResponse(
                folder,
                fileLookup: fileLookup,
                fileIdIndex: fileIdIndex,
                mode: mode,
                diagnostics: &assignmentDiagnostics
            )
        }
        let folderAssignmentCount = collectAssignedFileIDs(from: folderSuggestions).count
        let compactAssignmentCount = collectAssignedFileIDs(from: assignmentSuggestions).count

        // Some models emit both schemas in one response. Prefer the schema that
        // actually maps more input files instead of blindly choosing `folders`.
        let parsedSuggestions: [FolderSuggestion]
        var diagnostics: ParseDiagnostics
        if folderSuggestions.isEmpty || compactAssignmentCount > folderAssignmentCount {
            parsedSuggestions = assignmentSuggestions
            diagnostics = assignmentDiagnostics
        } else {
            parsedSuggestions = folderSuggestions
            diagnostics = folderDiagnostics
        }

        let hasExplicitUnorganizedFiles = !(response.unorganized ?? []).isEmpty ||
            !(response.unorganizedIDs ?? []).isEmpty
        guard !parsedSuggestions.isEmpty || hasExplicitUnorganizedFiles else {
            throw ParserError.missingRequiredFields
        }

        let assignedFileIDs = collectAssignedFileIDs(from: parsedSuggestions)

        var unorganizedDetails = (response.unorganized ?? []).map { unorg in
            UnorganizedFile(filename: unorg.filename, reason: unorg.reason)
        }
        if let unorganizedIDs = response.unorganizedIDs {
            for id in unorganizedIDs {
                if let file = fileIdIndex[id] {
                    unorganizedDetails.append(
                        UnorganizedFile(
                            filename: file.displayName,
                            reason: "Marked as unorganized in compact file_ids response"
                        )
                    )
                } else if !diagnostics.hallucinatedIDs.contains(id) {
                    diagnostics.hallucinatedIDs.append(id)
                }
            }
        }

        var unorganizedFiles: [FileItem] = []
        var seenUnorganizedIDs: Set<UUID> = []
        var unresolvedUnorganized = 0

        for detail in unorganizedDetails {
            guard let file = fileLookup.resolve(detail.filename) else {
                unresolvedUnorganized += 1
                continue
            }
            guard !assignedFileIDs.contains(file.id) else { continue }
            guard seenUnorganizedIDs.insert(file.id).inserted else { continue }
            unorganizedFiles.append(file)
        }
        if unresolvedUnorganized > 0 {
            diagnostics.unresolvedFilenames.append("\(unresolvedUnorganized) unorganized filename(s) could not be resolved")
        }

        // A response containing named folders but no usable assignments is not
        // an organization plan. Let the caller retry or use partial extraction
        // instead of presenting every input as accidentally unorganized.
        if !originalFiles.isEmpty, assignedFileIDs.isEmpty, seenUnorganizedIDs.isEmpty {
            throw ParserError.missingRequiredFields
        }

        // Unmapped fallback: files the model never mentioned stay visible, but
        // they are counted distinctly from explicitly unorganized files and mark
        // the plan partial instead of silently valid.
        var unmappedCount = 0
        for file in originalFiles where !assignedFileIDs.contains(file.id) {
            guard seenUnorganizedIDs.insert(file.id).inserted else { continue }
            unmappedCount += 1
            unorganizedFiles.append(file)
            unorganizedDetails.append(
                UnorganizedFile(
                    filename: file.displayName,
                    reason: "Unmapped: AI response did not assign this file; kept unorganized for review."
                )
            )
        }

        var parseWarnings: [String] = []
        if diagnostics.droppedElements > 0 {
            parseWarnings.append("\(diagnostics.droppedElements) malformed folder/rename entr\(diagnostics.droppedElements == 1 ? "y was" : "ies were") dropped during decoding.")
        }
        if !diagnostics.hallucinatedIDs.isEmpty {
            parseWarnings.append("\(diagnostics.hallucinatedIDs.count) file ID(s) referenced by the AI do not exist in this batch (\(diagnostics.hallucinatedIDs.prefix(8).map(String.init).joined(separator: ", "))\(diagnostics.hallucinatedIDs.count > 8 ? ", …" : "")).")
        }
        if !diagnostics.unresolvedFilenames.isEmpty {
            let sample = diagnostics.unresolvedFilenames.prefix(3).joined(separator: "; ")
            parseWarnings.append("\(diagnostics.unresolvedFilenames.count) filename reference(s) could not be matched (\(sample)\(diagnostics.unresolvedFilenames.count > 3 ? "; …" : "")).")
        }
        if unmappedCount > 0 {
            parseWarnings.append("\(unmappedCount) of \(originalFiles.count) file(s) were unmapped by the AI and kept unorganized.")
        }
        let isPartial = unmappedCount > 0 || diagnostics.hasIssues || unresolvedUnorganized > 0
        var notes = response.notes ?? ""
        if !parseWarnings.isEmpty {
            let retryHint = "Partial plan — review unmapped items before applying. Retry with fewer files or clearer filenames if mappings look wrong."
            notes = notes.isEmpty ? retryHint : "\(notes) \(retryHint)"
        }

        return OrganizationPlan(
            sessionName: response.sessionName,
            suggestions: parsedSuggestions,
            unorganizedFiles: unorganizedFiles,
            unorganizedDetails: unorganizedDetails,
            notes: notes,
            timestamp: Date(),
            version: 1,
            learningToolCall: response.learningToolCall,
            isPartial: isPartial,
            needsReview: isPartial,
            parseWarnings: parseWarnings
        )
    }

    private static func collectAssignedFileIDs(from suggestions: [FolderSuggestion]) -> Set<UUID> {
        var ids: Set<UUID> = []

        func walk(_ folder: FolderSuggestion) {
            for file in folder.files {
                ids.insert(file.id)
            }
            for subfolder in folder.subfolders {
                walk(subfolder)
            }
        }

        for suggestion in suggestions {
            walk(suggestion)
        }

        return ids
    }

    private static func convertFolderResponse(
        _ folder: FolderResponse,
        fileLookup: FileLookup,
        fileIdIndex: [Int: FileItem],
        mode: OrganizationMode,
        diagnostics: inout ParseDiagnostics
    ) -> FolderSuggestion {
        var files: [FileItem] = []
        var renameMappings: [FileRenameMapping] = []
        var seenFileIds: Set<UUID> = []

        func storeRenameMapping(_ mapping: FileRenameMapping) {
            renameMappings.removeAll { $0.originalFile.id == mapping.originalFile.id }
            renameMappings.append(mapping)
        }

        diagnostics.droppedElements += folder.droppedNestedCount

        if let fileIDs = folder.fileIDs {
            for id in fileIDs {
                guard let file = fileIdIndex[id] else {
                    if !diagnostics.hallucinatedIDs.contains(id) {
                        diagnostics.hallucinatedIDs.append(id)
                    }
                    continue
                }
                guard !seenFileIds.contains(file.id) else { continue }
                seenFileIds.insert(file.id)
                files.append(file)
            }
        }

        for fileEntry in folder.files {
            if let file = fileLookup.resolve(fileEntry.filename) {
                if seenFileIds.insert(file.id).inserted {
                    files.append(file)
                }

                // Parse-level safeguard: strip all rename fields in organize-only mode.
                if mode != .organize,
                   let mapping = makeRenameMapping(
                       for: file,
                       suggestedName: fileEntry.suggestedName,
                       renameReason: fileEntry.renameReason,
                       renameConfidence: fileEntry.renameConfidence
                   ) {
                    storeRenameMapping(mapping)
                }

                // Add tags if present
                if let tags = fileEntry.tags, !tags.isEmpty {
                    // We'll collect these into a temporary list and add to FolderSuggestion logic below
                    // NOTE: FolderSuggestion doesn't have a mutable 'addTag' during init easily without
                    // accumulating them first. Let's create the FileTagMapping here.
                }
            } else {
                diagnostics.unresolvedFilenames.append(fileEntry.filename)
            }
        }

        if mode != .organize {
            for rename in folder.renameSuggestions ?? [] {
                guard let file = fileIdIndex[rename.fileID] else {
                    if !diagnostics.hallucinatedIDs.contains(rename.fileID) {
                        diagnostics.hallucinatedIDs.append(rename.fileID)
                    }
                    continue
                }
                if seenFileIds.insert(file.id).inserted {
                    files.append(file)
                }
                if let mapping = makeRenameMapping(
                    for: file,
                    suggestedName: rename.suggestedName,
                    renameReason: rename.renameReason,
                    renameConfidence: rename.renameConfidence
                ) {
                    storeRenameMapping(mapping)
                }
            }
        }
        
        // Collect tag and comment mappings
        var tagMappings: [FileTagMapping] = []
        for fileEntry in folder.files {
           if let file = fileLookup.resolve(fileEntry.filename) {
               let tags = fileEntry.tags ?? []
               let comment = fileEntry.comment
               if !tags.isEmpty || (comment != nil && !comment!.isEmpty) {
                   tagMappings.append(FileTagMapping(originalFile: file, tags: tags, comment: comment))
               }
           }
        }

        let subfolders = (folder.subfolders ?? []).map { subfolder in
            convertFolderResponse(
                subfolder,
                fileLookup: fileLookup,
                fileIdIndex: fileIdIndex,
                mode: mode,
                diagnostics: &diagnostics
            )
        }

        return FolderSuggestion(
            folderName: folder.name,
            description: folder.description ?? "",
            files: files,
            subfolders: subfolders,
            reasoning: folder.reasoning ?? folder.description ?? "",
            fileRenameMappings: renameMappings,
            fileTagMappings: tagMappings,
            tags: folder.tags ?? [],
            comment: folder.comment,
            semanticTags: folder.semanticTags ?? [],
            confidenceScore: folder.confidence,
            ruleId: folder.ruleId
        )
    }

    private static func makeRenameMapping(
        for file: FileItem,
        suggestedName: String?,
        renameReason: String?,
        renameConfidence: Double?
    ) -> FileRenameMapping? {
        var clampedConfidence = renameConfidence.map { min(max($0, 0.0), 1.0) }
        let cleanedName = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanedReason = renameReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanedName.isEmpty && !hasConcreteRenameEvidence(cleanedReason) {
            clampedConfidence = min(clampedConfidence ?? FileRenameMapping.lowConfidenceThreshold, 0.29)
        }
        guard !cleanedName.isEmpty || !cleanedReason.isEmpty || clampedConfidence != nil else {
            return nil
        }

        return FileRenameMapping(
            originalFile: file,
            suggestedName: cleanedName.isEmpty ? nil : cleanedName,
            renameReason: cleanedReason.isEmpty ? nil : cleanedReason,
            renameConfidence: clampedConfidence
        )
    }

    private static func hasConcreteRenameEvidence(_ reason: String) -> Bool {
        let normalized = reason.lowercased()
        guard normalized.count >= 12 else { return false }
        let vagueReasons = [
            "more descriptive",
            "clearer name",
            "better name",
            "improved filename",
            "easier to understand"
        ]
        return !vagueReasons.contains { normalized == $0 || normalized.hasPrefix("\($0).") }
    }

    private static func normalizedFilenameCandidates(from raw: String) -> [String] {
        var candidates: [String] = []
        var seen: Set<String> = []

        func appendCandidate(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return }
            candidates.append(trimmed)
        }

        appendCandidate(raw)

        let strippedQuotes = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        appendCandidate(strippedQuotes)

        let slashNormalized = strippedQuotes.replacingOccurrences(of: "\\", with: "/")
        appendCandidate(slashNormalized)

        if slashNormalized.hasPrefix("./") {
            appendCandidate(String(slashNormalized.dropFirst(2)))
        }

        if let lastPathComponent = slashNormalized.split(separator: "/").last {
            appendCandidate(String(lastPathComponent))
        }

        if let decoded = slashNormalized.removingPercentEncoding {
            appendCandidate(decoded)
            if let decodedLastPathComponent = decoded.split(separator: "/").last {
                appendCandidate(String(decodedLastPathComponent))
            }
        }

        return candidates
    }

    private static func sanitizeJSONPayload(_ payload: String) -> String {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let extracted = extractLikelyJSONObject(from: trimmed) ?? trimmed
        return removeTrailingCommas(in: extracted)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractLikelyJSONObject(from text: String) -> String? {
        let candidates = LLMJSONExtractor.objectCandidates(in: text)
        guard !candidates.isEmpty else { return nil }

        if let preferred = candidates.last(where: { candidate in
            let lower = candidate.lowercased()
            return lower.contains("\"folders\"") ||
                lower.contains("\"folder_assignments\"") ||
                lower.contains("\"unorganized\"") ||
                lower.contains("\"f\"")
        }) {
            return preferred
        }

        return candidates.max(by: { $0.count < $1.count })
    }

    private static func removeTrailingCommas(in json: String) -> String {
        json.replacingOccurrences(
            of: #",\s*([\}\]])"#,
            with: "$1",
            options: .regularExpression
        )
    }

    /// Extract partial results even if parsing fails
    static func extractPartialResults(
        _ jsonString: String,
        originalFiles: [FileItem],
        mode: OrganizationMode = .organize
    ) -> OrganizationPlan? {
        // Try to extract folder names and file assignments even from malformed JSON
        var suggestions: [FolderSuggestion] = []
        var assignedFiles: Set<UUID> = []
        let workingJSON = stripProgressPreamble(jsonString)
        let fileIdIndex = Dictionary(uniqueKeysWithValues: originalFiles.enumerated().map { ($0.offset + 1, $0.element) })
        let fileLookup = FileLookup(files: originalFiles)

        for segment in folderObjectSegments(in: workingJSON) {
            if let data = sanitizeJSONPayload(segment).data(using: .utf8),
               let folder = try? JSONDecoder().decode(FolderResponse.self, from: data) {
                var segmentDiagnostics = ParseDiagnostics()
                let suggestion = convertFolderResponse(
                    folder,
                    fileLookup: fileLookup,
                    fileIdIndex: fileIdIndex,
                    mode: mode,
                    diagnostics: &segmentDiagnostics
                )
                let suggestionFileIDs = collectAssignedFileIDs(from: [suggestion])
                if suggestionFileIDs.contains(where: { !assignedFiles.contains($0) }) {
                    assignedFiles.formUnion(suggestionFileIDs)
                    suggestions.append(suggestion)
                }
                continue
            }

            guard let folderName = stringValue(forKey: "name", in: segment) else { continue }
            let fileNames = fileNames(in: segment)
            let fileIDs = integerValues(forKey: "file_ids", in: segment)
            var folderFiles: [FileItem] = []

            for fileName in fileNames {
                guard let file = fileLookup.resolve(fileName),
                      assignedFiles.insert(file.id).inserted else { continue }
                folderFiles.append(file)
            }
            for id in fileIDs {
                guard let file = fileIdIndex[id],
                      assignedFiles.insert(file.id).inserted else { continue }
                folderFiles.append(file)
            }

            if !folderFiles.isEmpty {
                suggestions.append(FolderSuggestion(
                    folderName: folderName,
                    files: folderFiles,
                    reasoning: "Extracted from partial response"
                ))
            }
        }

        guard !suggestions.isEmpty else { return nil }

        // Unassigned files go to unorganized
        let unorganizedFiles = originalFiles.filter { !assignedFiles.contains($0.id) }
        let partialWarning = "\(unorganizedFiles.count) of \(originalFiles.count) file(s) unmapped in partial extraction."

        return OrganizationPlan(
            suggestions: suggestions,
            unorganizedFiles: unorganizedFiles,
            notes: "Partial extraction - some organization data may be missing. \(partialWarning) Retry with fewer files if mappings look wrong.",
            timestamp: Date(),
            version: 1,
            isPartial: true,
            needsReview: true,
            parseWarnings: [partialWarning]
        )
    }

    private static func folderObjectSegments(in text: String) -> [String] {
        ["folders", "folder_assignments"].flatMap { key in
            objectSegments(inArrayForKey: key, text: text)
        }
    }

    private static func objectSegments(inArrayForKey key: String, text: String) -> [String] {
        var segments: [String] = []
        var searchStart = text.startIndex
        let marker = "\"\(key)\""

        while searchStart < text.endIndex,
              let keyRange = text.range(of: marker, range: searchStart..<text.endIndex),
              let arrayStart = arrayStart(after: keyRange.upperBound, in: text) {
            var index = text.index(after: arrayStart)
            var objectStart: String.Index?
            var objectDepth = 0
            var arrayDepth = 1
            var isInsideString = false
            var isEscaping = false

            while index < text.endIndex, arrayDepth > 0 {
                let character = text[index]

                if isInsideString {
                    if isEscaping {
                        isEscaping = false
                    } else if character == "\\" {
                        isEscaping = true
                    } else if character == "\"" {
                        isInsideString = false
                    }
                    index = text.index(after: index)
                    continue
                }

                switch character {
                case "\"":
                    isInsideString = true
                case "[":
                    arrayDepth += 1
                case "]":
                    arrayDepth -= 1
                case "{":
                    if objectDepth == 0 {
                        objectStart = index
                    }
                    objectDepth += 1
                case "}":
                    if objectDepth > 0 {
                        objectDepth -= 1
                        if objectDepth == 0, let objectStart {
                            segments.append(String(text[objectStart...index]))
                        }
                    }
                default:
                    break
                }

                index = text.index(after: index)
            }

            if objectDepth > 0, let objectStart {
                segments.append(String(text[objectStart...]))
            }

            if index > keyRange.upperBound {
                searchStart = index
            } else {
                searchStart = keyRange.upperBound
            }
        }

        return segments
    }

    private static func arrayStart(after start: String.Index, in text: String) -> String.Index? {
        guard let colon = text[start...].firstIndex(of: ":") else { return nil }
        var index = text.index(after: colon)
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        return index < text.endIndex && text[index] == "[" ? index : nil
    }

    private static func stringValue(forKey key: String, in object: String) -> String? {
        if let data = sanitizeJSONPayload(object).data(using: .utf8),
           let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = dictionary[key] as? String {
            return value
        }

        let pattern = "\\\"\(NSRegularExpression.escapedPattern(for: key))\\\"\\s*:\\s*\\\"([^\\\"]+)\\\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: object, range: NSRange(object.startIndex..., in: object)),
              let valueRange = Range(match.range(at: 1), in: object) else { return nil }
        return String(object[valueRange])
    }

    private static func fileNames(in object: String) -> [String] {
        if let payload = arrayPayload(forKey: "files", in: object),
           let data = payload.data(using: .utf8),
           let values = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return values.compactMap { value in
                if let filename = value as? String {
                    return filename
                }
                return (value as? [String: Any])?["filename"] as? String
            }
        }

        guard let remainder = arrayRemainder(forKey: "files", in: object) else { return [] }
        return partialFileNames(in: remainder)
    }

    private static func partialFileNames(in arrayRemainder: String) -> [String] {
        let filenamePattern = #"\"filename\"\s*:\s*\"([^\"]+)\""#
        if let regex = try? NSRegularExpression(pattern: filenamePattern) {
            let matches = regex.matches(
                in: arrayRemainder,
                range: NSRange(arrayRemainder.startIndex..., in: arrayRemainder)
            )
            let filenames = matches.compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: arrayRemainder) else { return nil }
                return String(arrayRemainder[range])
            }
            if !filenames.isEmpty {
                return filenames
            }
        }

        var values: [String] = []
        var index = arrayRemainder.startIndex
        var arrayDepth = 0
        var objectDepth = 0
        var stringStart: String.Index?
        var isEscaping = false

        while index < arrayRemainder.endIndex {
            let character = arrayRemainder[index]
            if let start = stringStart {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    if arrayDepth == 1, objectDepth == 0 {
                        values.append(String(arrayRemainder[start..<index]))
                    }
                    stringStart = nil
                }
            } else {
                switch character {
                case "\"":
                    stringStart = arrayRemainder.index(after: index)
                case "[":
                    arrayDepth += 1
                case "]":
                    arrayDepth -= 1
                case "{":
                    objectDepth += 1
                case "}":
                    objectDepth = max(0, objectDepth - 1)
                default:
                    break
                }
            }
            index = arrayRemainder.index(after: index)
        }

        return values
    }

    private static func integerValues(forKey key: String, in object: String) -> [Int] {
        if let payload = arrayPayload(forKey: key, in: object),
           let data = payload.data(using: .utf8),
           let values = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return values.compactMap { ($0 as? NSNumber)?.intValue }
        }

        guard let remainder = arrayRemainder(forKey: key, in: object),
              let regex = try? NSRegularExpression(pattern: #"\d+"#) else { return [] }
        return regex.matches(in: remainder, range: NSRange(remainder.startIndex..., in: remainder)).compactMap { match in
            guard let range = Range(match.range, in: remainder) else { return nil }
            return Int(remainder[range])
        }
    }

    private static func arrayRemainder(forKey key: String, in object: String) -> String? {
        let marker = "\"\(key)\""
        guard let keyRange = object.range(of: marker),
              let start = arrayStart(after: keyRange.upperBound, in: object) else { return nil }
        return String(object[start...])
    }

    private static func arrayPayload(forKey key: String, in object: String) -> String? {
        let marker = "\"\(key)\""
        guard let keyRange = object.range(of: marker),
              let start = arrayStart(after: keyRange.upperBound, in: object) else { return nil }

        var index = start
        var depth = 0
        var isInsideString = false
        var isEscaping = false

        while index < object.endIndex {
            let character = object[index]

            if isInsideString {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else {
                if character == "\"" {
                    isInsideString = true
                } else if character == "[" {
                    depth += 1
                } else if character == "]" {
                    depth -= 1
                    if depth == 0 {
                        return String(object[start...index])
                    }
                }
            }

            index = object.index(after: index)
        }

        return nil
    }
}

// MARK: - Errors

enum ParserError: LocalizedError {
    case invalidJSON
    case missingRequiredFields
    case fileNotFound
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Invalid JSON response from AI"
        case .missingRequiredFields:
            return "Response missing required fields"
        case .fileNotFound:
            return "Referenced file not found in original list"
        case .emptyResponse:
            return "Empty response from AI"
        }
    }
}
