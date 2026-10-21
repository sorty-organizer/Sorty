import Foundation
import SwiftUI
import Combine
import SortyLearnings
import SortyFileSystem
import SortyModels
import SortyAI
import SortyFS

// MARK: - Incremental Organization (for watched folders)
extension FolderOrganizer {
    public func organizeIncremental(
        directory: URL,
        specificFiles: [String]? = nil,
        customPrompt: String? = nil,
        temperature: Double? = nil,
        providerOverride: AIProvider? = nil,
        modelOverride: String? = nil,
        mode: OrganizationMode = .organize,
        historySource: OrganizationEntrySource = .manual,
        autoApply: Bool = true
    ) async throws {
        guard !isOperationInProgress() else {
            ModelLog.debug("Incremental organization blocked: Already in progress")
            return
        }
        // Claim before the first await so a run started while this one loads
        // persisted state cannot cancel it and then clobber its task/state.
        guard let runToken = claimOrganizeRun() else {
            ModelLog.debug("Incremental organization blocked: another run is active")
            return
        }
        defer { releaseOrganizeRun(runToken) }

        await exclusionRules?.loadPersistedState()
        await personaManager?.loadPersistedState()
        await customPersonaStore?.loadPersistedState()

        cancelInternal(preservingToken: runToken)
        isCancellationRequested = false
        currentRunInstructions = customPrompt ?? customInstructions
        modelExcludedCurrentRun = false

        currentTask = Task {
            try await performIncrementalOrganization(
                directory: directory,
                specificFiles: specificFiles,
                customPrompt: customPrompt,
                temperature: temperature,
                providerOverride: providerOverride,
                modelOverride: modelOverride,
                mode: mode,
                historySource: historySource,
                autoApply: autoApply,
                runToken: runToken
            )
        }
        defer {
            // Only the run that still owns the token may clear the task; a
            // superseded run must not clobber the winner.
            if isCurrentOrganizeRun(runToken) {
                currentTask = nil
            }
        }

        do {
            try await currentTask?.value
        } catch where Self.isCancellationError(error) {
            guard isCurrentOrganizeRun(runToken) else {
                // A superseded run must not reset the newer run's state;
                // consume any pending suppression so it cannot mute a later
                // legitimate cancellation.
                suppressCancellationReset = false
                throw CancellationError()
            }
            resetToIdleUnlessCancellationResetIsSuppressed(source: historySource)
        }
    }

    private func performIncrementalOrganization(
        directory: URL,
        specificFiles: [String]?,
        customPrompt: String?,
        temperature: Double?,
        providerOverride: AIProvider? = nil,
        modelOverride: String? = nil,
        mode: OrganizationMode,
        historySource: OrganizationEntrySource = .manual,
        autoApply: Bool,
        runToken: UInt64
    ) async throws {
        // Clear any apply-failure flag left by an earlier run so a pre-apply
        // failure here still records its own history entry.
        performApplyRecordedFailure = false
        OrganizerServices.captureWorkflow(
            workflow: "organize",
            stage: "started",
            outcome: "started",
            properties: [
                "entry_source": historySource.rawValue,
                "has_custom_instructions": !(customPrompt?.isEmpty ?? true),
                "mode": mode.rawValue,
            ]
        )

        // Build a client for this run so watched-folder action choices never mutate
        // or inherit the main Organize page's selected mode.
        guard let defaultClient = aiClient else {
            throw OrganizationError.clientNotConfigured
        }

        var operationConfig = aiConfig ?? defaultClient.config
        operationConfig.mode = mode
        operationConfig.enableSmartRename = mode != .organize

        let client: AIClientProtocol
        if let providerOverride {
            guard let modelOverride,
                  !modelOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIClientError.apiError(
                    statusCode: 400,
                    message: "Choose an automation model for \(providerOverride.displayName) before running this folder."
                )
            }
            operationConfig.provider = providerOverride
            operationConfig.model = modelOverride
            operationConfig.requiresAPIKey = providerOverride.typicallyRequiresAPIKey
            operationConfig.apiKey = nil
            if providerOverride.typicallyRequiresAPIKey,
               let apiKey = OrganizerServices.keychainReader(providerOverride.keychainKey) {
                operationConfig.apiKey = apiKey
            }
            // Preserve a custom endpoint when the folder override matches the
            // global provider (same pattern as generatePlanWithProvider).
            if [.openAICompatible, .ollama].contains(providerOverride),
               aiConfig?.provider == providerOverride,
               !(aiConfig?.apiURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
                operationConfig.apiURL = aiConfig?.apiURL ?? providerOverride.defaultAPIURL
            } else {
                operationConfig.apiURL = providerOverride.defaultAPIURL
            }
            client = try AIClientFactory.createClient(config: operationConfig)
        } else if defaultClient.config.mode == operationConfig.mode,
                  defaultClient.config.enableSmartRename == operationConfig.enableSmartRename {
            client = defaultClient
        } else {
            client = try AIClientFactory.createClient(config: operationConfig)
        }

        currentDirectory = directory

        let exclusionMatcher = exclusionRules?.matcherSnapshot()
        var files: [FileItem] = []
        
        if let specificFiles = specificFiles {
            // Processing specific files
            updateState(.scanning, stage: "Scanning \(specificFiles.count) new files...", progress: 0.1)
            try checkCancellation()
            
            // Enable deep scan for small batches
            let shouldDeepScan = (aiConfig?.enableDeepScan ?? false) && specificFiles.count <= 20
            
            // map file names to FileItems
            // We assume specificFiles are filenames or relative paths
            for filename in specificFiles {
                let fileURL = directory.appendingPathComponent(filename)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
                    continue
                }

                if isDirectory.boolValue {
                    if let nestedFiles = try? await scanner.scanDirectory(
                        at: fileURL,
                        relativeTo: directory,
                        deepScan: shouldDeepScan,
                        exclusionMatcher: exclusionMatcher
                    ) {
                        files.append(contentsOf: nestedFiles)
                    }
                } else if let item = try? await scanner.scanFile(
                    at: fileURL,
                    relativeTo: directory,
                    deepScan: shouldDeepScan,
                    exclusionMatcher: exclusionMatcher
                ) {
                    files.append(item)
                }
            }
            files = Array(Set(files))
            setScannedFiles(files)
        } else {
            // Fallback to scanning root
            updateState(.scanning, stage: "Scanning for new files...", progress: 0.1)
            try checkCancellation()
            
            let allFiles = try await scanner.scanDirectory(
                at: directory,
                exclusionMatcher: exclusionMatcher
            )
            
            // Filter: Only top-level files (no folders, no deep scan) for incremental drop.
            // The scanner already computed each path relative to the scan root,
            // so prefer it (pure string work) instead of a realpath syscall per
            // file on the main actor. The resolved-prefix comparison stays as
            // the fallback for scan roots whose enumeration spelling differs
            // (e.g. /var vs /private/var), where the scanner's own relative
            // path degrades to the last path component.
            let rawBasePath = directory.standardizedFileURL.path
            // One realpath for the root, not one per scanned file: the fallback
            // below only needs the resolved root prefix.
            let resolvedBasePath = directory.resolvingSymlinksInPath().standardizedFileURL.path
            files = allFiles.filter { file in
                let rawFilePath = URL(fileURLWithPath: file.path).standardizedFileURL.path
                if rawFilePath.hasPrefix(rawBasePath + "/") {
                    if let scannerRelativePath = file.relativePath, !scannerRelativePath.isEmpty {
                        return !scannerRelativePath.contains("/") // Only files in root
                    }
                    let relativePath = String(rawFilePath.dropFirst(rawBasePath.count + 1))
                    return !relativePath.contains("/") // Only files in root
                }

                let filePath = URL(fileURLWithPath: file.path)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                    .path
                guard filePath.hasPrefix(resolvedBasePath + "/") else { return false }
                let relativePath = String(filePath.dropFirst(resolvedBasePath.count + 1))
                return !relativePath.contains("/") // Only files in root
            }
            setScannedFiles(files)
        }

        if files.isEmpty {
            await MainActor.run {
                transition(to: .idle, force: true)
                organizationStage = "No new files to organize"
            }
            return
        }

        updateState(.organizing, stage: "Organizing \(files.count) new files...", progress: 0.3)
        await MainActor.run {
            isStreaming = true
        }

        startTimeoutTimer()

        do {
            try checkCancellation()

            let existingFolderContext = try await PromptBuilder.buildExistingFoldersContextOffMain(at: directory)
                ?? "No descendant folders currently exist."
            let contextPrompt: String
            switch mode {
            case .organize:
                contextPrompt = """
                \(existingFolderContext)

                RULES for Organization:
                1. You MUST prioritize placing files into these existing descendant paths if they are relevant, regardless of path depth.
                2. Do NOT create new folders unless the file is completely unrelated to any existing folder.
                3. If a file does not fit well into any existing folder, you may leave it in the root (do not move it).
                4. This is a "Smart Drop" operation: maintain the existing structure and keep every original filename.
                """
            case .organizeAndRename:
                contextPrompt = """
                \(existingFolderContext)

                RULES for Organization and Renaming:
                1. Prioritize placing files into these existing descendant paths when they are relevant, regardless of path depth.
                2. Do not create new folders unless a file is unrelated to the existing structure.
                3. Improve unclear filenames when the available evidence supports a better name.
                4. Preserve clear filenames and maintain the existing structure instead of reinventing it.
                """
            case .renameOnly:
                contextPrompt = """
                RULES for Renaming:
                1. Keep every file in its current folder.
                2. Improve unclear filenames only when the available evidence supports a better name.
                3. Preserve filenames that are already clear and useful.
                """
            }

            let prompt = PromptBuilder.wrapDirectUserInstructions(customPrompt ?? customInstructions) + "\n\n" + contextPrompt
            
            // Add Learnings context
            var finalPrompt = prompt
            if let learnedContext = learningsManager?.generatePromptContext(forFolder: directory.path),
               !learnedContext.isEmpty {
                finalPrompt += "\n\n" + learnedContext
            }

            if mode != .renameOnly,
               let modelDirContext = learningsManager?.generateModelDirectoryContext(for: files),
               !modelDirContext.isEmpty {
                finalPrompt += "\n\n" + modelDirContext
            }
            
            // Add Storage Locations context
            if mode != .renameOnly,
               let storageContext = await storageLocationsManager?.generatePromptContext(),
               !storageContext.isEmpty {
                finalPrompt += "\n\n" + storageContext
            }
            finalPrompt += exclusionInstructions(forRenameOnly: mode == .renameOnly)
            
            let personaPrompt = effectivePersonaPrompt()

            let plan = try await analyzeInBoundedBatches(
                files: files,
                client: client,
                imagePayload: [:],
                instructions: finalPrompt,
                personaPrompt: personaPrompt,
                temperature: temperature,
                modeOverride: mode
            )

            stopTimeoutTimer()

            try checkCancellation()

            await MainActor.run {
                isStreaming = false
                currentPlan = normalizeRenameSuggestions(
                    in: applyRenameRuleConfiguration(to: plan, config: operationConfig),
                    config: operationConfig
                )
            }

            // Validate plan before auto-apply (with a targeted retry for common validation failures)
            let allowedLocations = storageLocationsManager?.enabledLocations ?? []
            var planAfterValidation = normalizeStorageDestinations(in: plan, allowedLocations: allowedLocations, sourceDirectoryURL: directory)
            planAfterValidation = OrganizationModePlanEnforcer.enforce(
                planAfterValidation,
                mode: mode,
                baseURL: directory
            )
            do {
                try await validator.validateOffMain(
                    planAfterValidation,
                    at: directory,
                    allowedStorageLocations: allowedLocations,
                    mode: mode
                )
            } catch let validationError as ValidationError {
                if let retryPlan = await retryWithValidationEnhancement(
                    files: files,
                    client: client,
                    validationError: validationError,
                    directory: directory,
                    instructions: finalPrompt,
                    personaPrompt: personaPrompt,
                    temperature: temperature,
                    imagePayload: [:],
                    allowedStorageLocations: allowedLocations
                ) {
                    planAfterValidation = OrganizationModePlanEnforcer.enforce(
                        retryPlan,
                        mode: mode,
                        baseURL: directory
                    )
                } else {
                    throw validationError
                }
            }

            // Post-AI exclusion validation
            var validatedPlan = planAfterValidation
            if let exclusionRules = exclusionRules {
                let enforcer = ExclusionEnforcer(exclusionManager: exclusionRules)
                let validationResult = enforcer.validate(planAfterValidation)
                if validationResult.hasViolations {
                    OrganizerServices.log("Exclusion violations in incremental plan: \(validationResult.violationCount)", category: "FolderOrganizer")
                    validatedPlan = validationResult.cleanedPlan ?? planAfterValidation
                }
            }

            handleLearningToolCall(
                from: validatedPlan,
                source: historySource,
                folderPath: directory.path
            )

            await MainActor.run {
                currentPlan = normalizeRenameSuggestions(
                    in: applyRenameRuleConfiguration(to: validatedPlan, config: operationConfig),
                    config: operationConfig
                )
            }

            guard autoApply else {
                await MainActor.run {
                    preparedPlanModeOverride = mode
                    updateState(.ready, stage: "Ready for review", progress: 1.0)
                }
                return
            }

            // Auto-apply for incremental (same task so outer cancel keeps working)
            try await performApply(
                at: directory,
                dryRun: false,
                enableTagging: operationConfig.enableFileTagging,
                source: historySource,
                modeOverride: mode,
                runToken: runToken
            )

        } catch {
            // A superseded run must not stop the winner's timeout timer, record
            // a failure for the old directory, or consume the winner's
            // performApply failure flag.
            guard isCurrentOrganizeRun(runToken) else { throw error }
            stopTimeoutTimer()
            // performApply records its own failure entries; without this the
            // auto-apply failure would land in history twice.
            let recordedByApply = consumePerformApplyFailureRecording()
            handleOrganizationError(
                error,
                directory: directory,
                source: historySource,
                recordsHistory: !recordedByApply
            )
            throw error
        }
    }
}
