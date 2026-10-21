import Foundation
import SwiftUI
import Combine
import SortyLearnings
import SortyFileSystem
import SortyModels
import SortyAI
import SortyFS

extension FolderOrganizer {
    func boundedVisionSelection(
        from files: [FileItem],
        batchSize: Int,
        strategy: VisionBatchStrategy,
        fileBatchSize: Int? = nil
    ) -> (selected: [FileItem], total: Int) {
        if let fileBatchSize, files.count > fileBatchSize {
            var selected: [FileItem] = []
            var total = 0
            for start in stride(from: 0, to: files.count, by: fileBatchSize) {
                let end = min(start + fileBatchSize, files.count)
                let selection = boundedVisionSelection(
                    from: Array(files[start..<end]),
                    batchSize: batchSize,
                    strategy: strategy
                )
                selected.append(contentsOf: selection.selected)
                total += selection.total
            }
            return (selected, total)
        }

        let safeBatchSize = max(1, batchSize)
        var selected: [FileItem] = []
        selected.reserveCapacity(min(safeBatchSize, files.count))
        var total = 0

        func isVisionImage(_ file: FileItem) -> Bool {
            visionImageExtensions.contains(file.extension.lowercased())
        }

        switch strategy {
        case .firstN:
            for file in files where isVisionImage(file) {
                total += 1
                if selected.count < safeBatchSize {
                    selected.append(file)
                }
            }
        case .random:
            for file in files where isVisionImage(file) {
                total += 1
                if selected.count < safeBatchSize {
                    selected.append(file)
                } else {
                    let replacementIndex = Int.random(in: 0..<total)
                    if replacementIndex < safeBatchSize {
                        selected[replacementIndex] = file
                    }
                }
            }
        case .noText:
            for file in files where isVisionImage(file) {
                total += 1
                selected.append(file)
                if selected.count > safeBatchSize * 2 {
                    selected.sort(by: visionPriority)
                    selected.removeLast(selected.count - safeBatchSize)
                }
            }
            selected.sort(by: visionPriority)
            if selected.count > safeBatchSize {
                selected.removeLast(selected.count - safeBatchSize)
            }
        }

        return (selected, total)
    }

    func prepareVisionPayload(
        for files: [FileItem],
        baseDirectory: URL
    ) async throws -> [String: Data] {
        guard !files.isEmpty else { return [:] }

        aiAnalysisActivity = .preparingImages
        // One batched call: prepareFilesForVision already fans out internally
        // over a bounded TaskGroup. The old per-file loop re-entered it for
        // every file, paying setup/teardown per image and sorting each
        // single-entry result.
        try checkCancellation()
        let prepared = await visionAnalyzer.prepareFilesForVision(
            files: files,
            baseDirectoryURL: baseDirectory
        )

        var payload: [String: Data] = [:]
        payload.reserveCapacity(prepared.count)
        var preparedByteCount = 0
        var byteSkippedNames = Set<String>()
        for (name, data) in prepared.sorted(by: { $0.key < $1.key }) {
            try checkCancellation()
            guard preparedByteCount + VisionPayloadBudget.encodedByteCount(for: data) <= Self.maximumPreparedVisionBytes else {
                visionPreparationByteLimitSkipCount += 1
                byteSkippedNames.insert(name)
                continue
            }
            payload[name] = data
            preparedByteCount += VisionPayloadBudget.encodedByteCount(for: data)
            preparedVisionAttachmentNames.insert(name)
        }
        // Per-file failure accounting from the merged result: a file failed
        // when none of its attachments (or byte-limit skips) materialized.
        // Attachment keys are approximate (PDF pages append " [Page N]"), so
        // this stays a diagnostic counter, not control flow.
        var failedFileCount = 0
        for file in files {
            let key = Self.visionAttachmentName(for: file)
            let materialized = prepared.keys.contains {
                $0 == key || $0 == file.displayName || $0.hasPrefix(key + " [Page ")
            }
            let byteSkipped = byteSkippedNames.contains {
                $0 == key || $0 == file.displayName || $0.hasPrefix(key + " [Page ")
            }
            if !materialized, !byteSkipped {
                failedFileCount += 1
            }
        }
        visionPreparationFailureCount += failedFileCount

        if let summary = visionAnalysisSummary {
            visionAnalysisSummary = VisionAnalysisSummary(
                analyzedCount: preparedVisionAttachmentNames.count,
                totalImageCount: summary.totalImageCount,
                skippedCount: max(
                    0,
                    summary.totalImageCount
                        - preparedVisionAttachmentNames.count
                        - visionPreparationFailureCount
                ),
                failedCount: visionPreparationFailureCount,
                warningMessage: visionPreparationByteLimitSkipCount > 0
                    ? "Some images were skipped to keep encoded vision payloads below 32 MB per request."
                    : nil
            )
        }
        aiAnalysisActivity = .requesting
        ModelLog.debug(
            "Prepared \(payload.count) vision attachments using \(preparedByteCount) bytes for the next AI request"
        )
        return payload
    }

    private func visionPriority(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
                let lhsHasOCR = !(lhs.contentMetadata?.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let rhsHasOCR = !(rhs.contentMetadata?.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                if lhsHasOCR != rhsHasOCR {
                    return !lhsHasOCR
                }
                let lhsDate = lhs.modificationDate ?? lhs.creationDate ?? .distantPast
                let rhsDate = rhs.modificationDate ?? rhs.creationDate ?? .distantPast
                return lhsDate > rhsDate
    }

    /// Builds one request's instructions: the base prompt plus a vision
    /// context that lists exactly the attachments being sent.
    nonisolated static func requestInstructions(
        base: String,
        visionImages: [String: Data]
    ) -> String {
        guard !visionImages.isEmpty else { return base }
        return base + "\n\n" + visionPromptInstructions(for: visionImages.keys.sorted())
    }

    /// Removes a previously appended vision context block so callers can
    /// rebuild it from the attachments their own request sends.
    nonisolated static func strippingVisionContext(from instructions: String) -> String {
        guard let range = instructions.range(of: "## AI VISION CONTEXT") else {
            return instructions
        }
        return String(instructions[..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Attachments whose keys belong to `files`. PDF pages decorate the base
    /// attachment name with " [Page N]", so the decorated form matches too.
    nonisolated static func visionImages(
        in images: [String: Data],
        keyedBy files: [FileItem]
    ) -> [String: Data] {
        guard !images.isEmpty else { return [:] }
        let names = files.map { visionAttachmentName(for: $0) }
        guard !names.isEmpty else { return [:] }
        return images.filter { key, _ in
            names.contains { key == $0 || key.hasPrefix($0 + " [Page ") }
        }
    }

    /// The subset of `visionFiles` whose attachments belong to `files`.
    nonisolated static func visionFiles(
        in visionFiles: [FileItem],
        matching files: [FileItem]
    ) -> [FileItem] {
        guard !visionFiles.isEmpty else { return [] }
        let names = files.map { visionAttachmentName(for: $0) }
        guard !names.isEmpty else { return [] }
        return visionFiles.filter { file in
            let key = visionAttachmentName(for: file)
            return names.contains { key == $0 || key.hasPrefix($0 + " [Page ") }
        }
    }

    nonisolated private static func visionPromptInstructions(for analyzedImageFilenames: [String]) -> String {
        let fileList = analyzedImageFilenames
            .enumerated()
            .map { "\($0.offset + 1). \(PromptBuilder.promptSafeFilename($0.element))" }
            .joined(separator: "\n")

        return """

        ## AI VISION CONTEXT
        I've attached \(analyzedImageFilenames.count) images from this folder.
        Inspect every attachment before choosing folders. Ground each attached file's placement in visible evidence such as its subject, setting, activity, document type, interface, event, and readable text. Group images by meaningful shared visual context, and let strong visual evidence override vague camera or screenshot filenames. Keep visually unrelated images separate and don't invent details that aren't visible.
        Attached image order:
        \(fileList)
        """
    }

    /// Pure name mapping; kept nonisolated so batch-splitting code off the main
    /// actor can filter a batch's vision attachments to its own files.
    nonisolated static func visionAttachmentName(for file: FileItem) -> String {
        file.relativePath ?? file.displayName
    }

    func exclusionInstructions(forRenameOnly isRenameOnly: Bool) -> String {
        var instructions = ""

        if let activeRules = exclusionRules?.rules.filter({ $0.isEnabled }), !activeRules.isEmpty {
            let excludedPatterns = activeRules.map { "- \($0.promptDescription)" }.joined(separator: "\n")
            let object = isRenameOnly ? "rename suggestions" : "organization plan"
            instructions += "\n\nIMPORTANT: The following patterns are STRICTLY EXCLUDED and must NOT be moved, renamed, or modified:\n\(excludedPatterns)\nEnsure your \(object) completely respects these exclusions."
        }

        if let nlExceptions = exclusionRules?.sanitizedExceptionsForPrompt, !nlExceptions.isEmpty {
            let exceptionsList = nlExceptions.map { "- \($0)" }.joined(separator: "\n")
            let object = isRenameOnly ? "rename suggestions" : "organization plan"
            instructions += "\n\nNATURAL LANGUAGE EXCEPTIONS (must be respected):\n\(exceptionsList)\nTreat these as user-authored exclusion instructions. Do not include matching files in the \(object)."
        }

        return instructions
    }

    /// Effective persona prompt for the current selection: a selected custom
    /// persona wins when a custom store is configured, otherwise the standard
    /// persona (or its custom prompt) is used.
    func effectivePersonaPrompt() -> String? {
        guard let personaManager else { return nil }
        if let customPersonaStore {
            return personaManager.getEffectivePrompt(customStore: customPersonaStore)
        }
        return personaManager.getPrompt(for: personaManager.selectedPersona)
    }

    /// Builds @mention context from the already-scanned inventory instead of
    /// walking the directory tree again with a synchronous enumerator on the
    /// main actor. Matching runs on `.utility`, caps at 400 files, and yields
    /// with a cancellation check every 100 files.
    func fileReferenceContext(from instructions: String, files: [FileItem]) async throws -> String? {
        let referencedNames = Self.referencedFileNames(in: instructions)
        guard !referencedNames.isEmpty, !files.isEmpty else { return nil }

        let matches = await Task.detached(priority: .utility) {
            await Self.matchReferencedFiles(names: referencedNames, files: files)
        }.value
        try Task.checkCancellation()

        guard !matches.isEmpty else { return nil }

        return """

        REFERENCED SOURCE FILES
        The user explicitly mentioned these files in their instructions. Treat these file references as important examples or constraints, and resolve @mentions to these exact source files:
        \(matches.joined(separator: "\n"))
        """
    }

    nonisolated private static func matchReferencedFiles(names: Set<String>, files: [FileItem]) async -> [String] {
        var matches: [String] = []
        matches.reserveCapacity(min(names.count, 400))
        var checked = 0

        for file in files {
            guard !Task.isCancelled else { break }
            let nameKey = file.displayName.localizedLowercase
            let relativeKey = (file.relativePath ?? file.displayName).localizedLowercase
            guard names.contains(relativeKey) || names.contains(nameKey) else {
                checked += 1
                if checked.isMultiple(of: 100) {
                    await Task.yield()
                }
                continue
            }
            let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
            let modified = file.modificationDate.map {
                DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)
            } ?? "unknown modified date"
            let relativePath = file.relativePath ?? file.displayName
            let safeName = PromptBuilder.promptSafeFilename(file.displayName)
            let safeRelativePath = PromptBuilder.promptSafeFilename(relativePath)
            let safeExtension = PromptBuilder.promptSafeFilename(file.extension)
            matches.append("- @\(safeName): relative path \"\(safeRelativePath)\", extension \"\(safeExtension)\", size \(size), modified \(modified)")
            if matches.count >= 400 { break }
            checked += 1
            if checked.isMultiple(of: 100) {
                await Task.yield()
            }
        }

        return matches
    }

    nonisolated private static let fileReferenceRegex =
        try? NSRegularExpression(pattern: #"@(?:"([^"]+)"|([^\s,;()\[\]{}]+))"#)

    nonisolated private static func referencedFileNames(in instructions: String) -> Set<String> {
        guard let regex = fileReferenceRegex else { return [] }

        let nsRange = NSRange(instructions.startIndex..<instructions.endIndex, in: instructions)
        return Set(regex.matches(in: instructions, range: nsRange).compactMap { match in
            let quotedRange = match.range(at: 1)
            let bareRange = match.range(at: 2)
            let selectedRange = quotedRange.location != NSNotFound ? quotedRange : bareRange
            guard let range = Range(selectedRange, in: instructions) else { return nil }

            let token = String(instructions[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token.localizedLowercase
        })
    }

    func validationPhase(
        plan: OrganizationPlan,
        files: [FileItem],
        directory: URL,
        instructions: String,
        personaPrompt: String?,
        temperature: Double?,
        imagePayload: [String: Data]
    ) async throws -> OrganizationPlan {
        updateState(
            .organizing,
            stage: aiConfig?.mode == .renameOnly ? "Checking name suggestions..." : "Checking organization plan...",
            progress: 0.85
        )
        await MainActor.run {
            isStreaming = false
            aiAnalysisActivity = .validating
        }
        retryAttemptCount = 0

        guard let client = aiClient else {
            throw OrganizationError.clientNotConfigured
        }

        let allowedLocations = storageLocationsManager?.enabledLocations ?? []
        let hierarchyNormalizedPlan = Self.normalizingDestinationHierarchy(in: plan)
        let normalizedInputPlan = normalizeStorageDestinations(
            in: hierarchyNormalizedPlan,
            allowedLocations: allowedLocations,
            sourceDirectoryURL: directory
        )

        var validatedPlanFromRetry: OrganizationPlan? = nil
        do {
            try await validator.validateOffMain(
                normalizedInputPlan,
                at: directory,
                allowedStorageLocations: allowedLocations,
                mode: aiConfig?.mode ?? .organize
            )
        } catch let validationError as ValidationError {
            if let retryPlan = await retryWithValidationEnhancement(
                files: files,
                client: client,
                validationError: validationError,
                directory: directory,
                instructions: instructions,
                personaPrompt: personaPrompt,
                temperature: temperature,
                imagePayload: imagePayload,
                allowedStorageLocations: allowedLocations
            ) {
                validatedPlanFromRetry = retryPlan
            } else {
                throw validationError
            }
        }

        let planAfterValidation = validatedPlanFromRetry ?? normalizedInputPlan

        try checkCancellation()

        var validatedPlan = planAfterValidation
        if let exclusionRules = exclusionRules {
            let enforcer = ExclusionEnforcer(exclusionManager: exclusionRules)
            self.exclusionEnforcer = enforcer

            let validationResult = enforcer.validate(planAfterValidation)

            if validationResult.hasViolations {
                OrganizerServices.log("Exclusion violations detected: \(validationResult.violationCount) files", category: "FolderOrganizer")

                if let retryPlan = await retryWithExclusionEnhancement(
                    files: files,
                    client: client,
                    violations: validationResult.violations,
                    instructions: instructions,
                    personaPrompt: personaPrompt,
                    temperature: temperature,
                    imagePayload: imagePayload
                ) {
                    let retryValidation = enforcer.validate(retryPlan)
                    if retryValidation.hasViolations {
                        OrganizerServices.log("Retry still has \(retryValidation.violationCount) violations, stripping", category: "FolderOrganizer")
                        validatedPlan = retryValidation.cleanedPlan ?? retryPlan
                    } else {
                        validatedPlan = retryPlan
                    }
                } else {
                    validatedPlan = validationResult.cleanedPlan ?? planAfterValidation
                }
            }
        }

        return normalizeRenameSuggestions(in: applyRenameRuleConfiguration(to: validatedPlan))
    }

    func applyRenameRuleConfiguration(
        to plan: OrganizationPlan,
        config suppliedConfig: AIConfig? = nil
    ) -> OrganizationPlan {
        guard let config = suppliedConfig ?? aiConfig else { return plan }
        guard config.mode == .renameOnly || config.mode == .organizeAndRename else { return plan }
        guard !config.renameRules.isEmpty else { return plan }

        var updatedPlan = plan
        updatedPlan.suggestions = updatedPlan.suggestions.map {
            applyRenameRules(in: $0, rules: config.renameRules, mode: config.renameRuleMode)
        }
        return updatedPlan
    }

    func normalizeRenameSuggestions(
        in plan: OrganizationPlan,
        config suppliedConfig: AIConfig? = nil
    ) -> OrganizationPlan {
        guard let config = suppliedConfig ?? aiConfig else { return plan }
        guard config.mode == .renameOnly || config.mode == .organizeAndRename else { return plan }

        var updatedPlan = plan
        updatedPlan.suggestions = updatedPlan.suggestions.map {
            normalizeRenameSuggestions(in: $0, options: config.renameNamingOptions)
        }
        return updatedPlan
    }

    private func normalizeRenameSuggestions(
        in folder: FolderSuggestion,
        options: RenameNamingOptions
    ) -> FolderSuggestion {
        var updated = folder
        var existingNames = Set(updated.files.map(\.displayName))

        for index in updated.fileRenameMappings.indices {
            let mapping = updated.fileRenameMappings[index]
            guard mapping.hasRename, let suggestedName = mapping.suggestedName else { continue }
            guard let normalized = FilenameNormalizer.normalize(
                suggestedName,
                originalFilename: mapping.originalFile.displayName,
                options: options
            ) else {
                updated.fileRenameMappings[index].suggestedName = nil
                continue
            }

            existingNames.remove(mapping.originalFile.displayName)
            let uniqueName = FilenameNormalizer.uniqued(normalized, against: &existingNames)
            updated.fileRenameMappings[index].suggestedName =
                uniqueName == mapping.originalFile.displayName ? nil : uniqueName
        }

        updated.subfolders = updated.subfolders.map {
            normalizeRenameSuggestions(in: $0, options: options)
        }
        return updated
    }

    private func applyRenameRules(
        in folder: FolderSuggestion,
        rules: [RenameRule],
        mode: RenameRuleApplicationMode
    ) -> FolderSuggestion {
        var updated = folder
        var mappingIndices = Dictionary(
            updated.fileRenameMappings.enumerated().map {
                ($0.element.originalFile.id, $0.offset)
            },
            uniquingKeysWith: { _, latest in latest }
        )

        func updateRename(
            for file: FileItem,
            newName: String?,
            reason: String?
        ) {
            let sanitizedName: String?
            if let newName, !newName.isEmpty {
                sanitizedName = FilenameSanitizer.sanitize(
                    newName,
                    preservingExtension: file.extension,
                    enforceExtension: true
                ).sanitizedName
            } else {
                sanitizedName = nil
            }
            let finalName = sanitizedName == file.displayName ? nil : sanitizedName

            if let index = mappingIndices[file.id] {
                updated.fileRenameMappings[index].suggestedName = finalName
                updated.fileRenameMappings[index].isSelected = finalName != nil
                if let reason {
                    updated.fileRenameMappings[index].renameReason = reason
                }
            } else if finalName != nil {
                mappingIndices[file.id] = updated.fileRenameMappings.count
                updated.fileRenameMappings.append(FileRenameMapping(
                    originalFile: file,
                    suggestedName: finalName,
                    renameReason: reason
                ))
            }
        }

        for file in updated.files {
            let existing = mappingIndices[file.id].map { updated.fileRenameMappings[$0] }
            let transformed = RenameRuleEngine.applyRules(to: file.displayName, rules: rules)
            let sanitization = FilenameSanitizer.sanitize(
                transformed,
                preservingExtension: file.extension,
                enforceExtension: true
            )
            let ruleCandidate = sanitization.sanitizedName
            let shouldUseRule = ruleCandidate != nil && ruleCandidate != file.displayName

            switch mode {
            case .rulesOnly:
                if let ruleCandidate, shouldUseRule {
                    updateRename(for: file, newName: ruleCandidate, reason: "Applied custom rename rule")
                } else {
                    updateRename(for: file, newName: nil, reason: nil)
                }
            case .beforeAI:
                if existing?.hasRename == true {
                    continue
                }
                if let ruleCandidate, shouldUseRule {
                    updateRename(for: file, newName: ruleCandidate, reason: "Applied custom rename rule")
                }
            }
        }

        updated.subfolders = updated.subfolders.map {
            applyRenameRules(in: $0, rules: rules, mode: mode)
        }
        return updated
    }

    func normalizeStorageDestinations(
        in plan: OrganizationPlan,
        allowedLocations: [StorageLocation],
        sourceDirectoryURL: URL? = nil
    ) -> OrganizationPlan {
        if !allowedLocations.isEmpty {
            let originalFolders = plan.suggestions.map(\.folderName)
            ModelLog.debug("[StorageNorm] Before normalization — folders: \(originalFolders)")
            ModelLog.debug("[StorageNorm] Allowed locations: \(allowedLocations.map { "\($0.name) → \($0.path)" })")
            if let srcDir = sourceDirectoryURL {
                ModelLog.debug("[StorageNorm] Source directory: \(srcDir.path)")
            }
        }

        let normalizedPlan = StorageDestinationNormalizer.normalize(
            plan: plan,
            allowedStorageLocations: allowedLocations,
            sourceDirectoryURL: sourceDirectoryURL
        )

        if normalizedPlan != plan {
            let changedFolders = zip(plan.suggestions, normalizedPlan.suggestions)
                .filter { $0.0.folderName != $0.1.folderName }
                .map { "\"\($0.0.folderName)\" → \"\($0.1.folderName)\"" }
            OrganizerServices.log(
                "Normalized storage destination aliases: \(changedFolders.joined(separator: ", "))",
                category: "FolderOrganizer"
            )
            ModelLog.debug("[StorageNorm] After normalization — changed: \(changedFolders)")
        } else if !allowedLocations.isEmpty {
            ModelLog.debug("[StorageNorm] No changes after normalization")
        }

        return normalizedPlan
    }

    func resolvePlanFolderURL(folderName: String, baseURL: URL) -> URL {
        if let absoluteURL = StorageLocationPathResolver.absoluteURL(from: folderName) {
            return absoluteURL
        }
        return baseURL.appendingPathComponent(folderName, isDirectory: true)
    }
}
