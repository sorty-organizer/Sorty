import Foundation
import SwiftUI
import Combine
import SortyLearnings
import SortyFileSystem
import SortyModels
import SortyAI
import SortyFS

// MARK: - Apply Organization
extension FolderOrganizer {
    public func apply(
        at baseURL: URL,
        dryRun: Bool = false,
        enableTagging: Bool = true,
        source: OrganizationEntrySource = .manual,
        modeOverride: OrganizationMode? = nil
    ) async throws {
        // Double-apply guard: a second apply while file moves are in flight is a
        // no-op with user feedback, preserving a single history entry. Checked
        // before cancelInternal so the second call cannot cancel the first run.
        if state == .applying {
            organizationStage = "Already applying changes..."
            OrganizerServices.log(
                "Ignoring re-entrant apply() while already applying",
                level: .warning,
                category: "FolderOrganizer"
            )
            return
        }
        guard currentPlan != nil else {
            throw OrganizationError.noCurrentPlan
        }
        if let planBaseURL = currentPlanBaseURL,
           planBaseURL.resolvingSymlinksInPath().standardizedFileURL
                != baseURL.resolvingSymlinksInPath().standardizedFileURL {
            throw OrganizationError.planDirectoryMismatch(
                expected: planBaseURL.path,
                actual: baseURL.path
            )
        }
        // A live run owns the task slot; applying now would cancel it and let
        // it clobber this apply when it resumes. Claiming synchronously also
        // blocks a second apply before the .applying transition below.
        guard let runToken = claimOrganizeRun() else {
            organizationStage = "Another operation is still running..."
            OrganizerServices.log(
                "Ignoring apply() while another run is active",
                level: .warning,
                category: "FolderOrganizer"
            )
            return
        }
        defer { releaseOrganizeRun(runToken) }
        // Claim .applying synchronously (before the first await) so a second
        // apply() observes .applying and no-ops instead of cancelling this run
        // via cancelInternal and starting a concurrent file-move pass.
        // performApply validates off-main afterwards; a validation failure
        // still surfaces as .error from here.
        withBatchUpdates {
            transition(to: .applying, force: true)
            organizationStage = "Applying changes to your files..."
            progress = 0.0
        }
        // Run the apply inside the tracked task so cancel() aborts the
        // file moves (FileSystemManager polls Task cancellation per file).
        cancelInternal(preservingToken: runToken)
        isCancellationRequested = false
        currentTask = Task {
            try await performApply(
                at: baseURL,
                dryRun: dryRun,
                enableTagging: enableTagging,
                source: source,
                modeOverride: modeOverride,
                runToken: runToken
            )
        }
        defer { clearTask(ifOwnedBy: runToken) }
        do {
            try await currentTask?.value
        } catch where Self.isCancellationError(error) {
            try checkCancellationRunOwnership(runToken)
            if suppressCancellationReset {
                suppressCancellationReset = false
                throw CancellationError()
            }
            resetToIdle(source: source)
            throw CancellationError()
        }
    }

    func performApply(
        at baseURL: URL,
        dryRun: Bool = false,
        enableTagging: Bool = true,
        source: OrganizationEntrySource = .manual,
        modeOverride: OrganizationMode? = nil,
        runToken: UInt64
    ) async throws {
        guard let currentPlan else {
            throw OrganizationError.noCurrentPlan
        }
        // This layer owns apply-failure history; clear any flag left over from
        // an earlier run before recording fresh failures. A superseded run must
        // not clear a flag the winner is about to consume.
        if isCurrentOrganizeRun(runToken) {
            performApplyRecordedFailure = false
        }
        let reliabilitySpan = OrganizerServices.startSpan(
            name: "apply_plan",
            operation: "workflow.apply",
            feature: "organize"
        )
        defer { reliabilitySpan?.finish() }
        let analyticsStartedAt = Date()
        OrganizerServices.captureWorkflow(
            workflow: "organize",
            stage: "apply_started",
            outcome: "started",
            properties: [
                "count_bucket": OrganizerServices.countBucket(currentPlan.totalFiles),
                "entry_source": source.rawValue,
                "mode": (modeOverride ?? preparedPlanModeOverride ?? aiConfig?.mode ?? .organize).rawValue,
            ]
        )

        // Note: the public apply() wrapper resets the cancellation flag for
        // standalone applies. Don't reset it here so a cancel requested while
        // an incremental/selected-files run is in flight stays visible.
        try checkCancellation()

        // Re-validate at apply time to protect all entry points, including regenerated previews.
        var operationConfig = aiConfig ?? aiClient?.config
        let requestedMode = modeOverride ?? preparedPlanModeOverride
        if let requestedMode {
            operationConfig?.mode = requestedMode
            operationConfig?.enableSmartRename = requestedMode != .organize
        }

        let operationMode = requestedMode ?? operationConfig?.mode ?? .organize

        let allowedLocations = storageLocationsManager?.enabledLocations ?? []
        let normalizedPlan = normalizeStorageDestinations(in: currentPlan, allowedLocations: allowedLocations, sourceDirectoryURL: baseURL)
        let normalizedRenamePlan = normalizeRenameSuggestions(
            in: applyRenameRuleConfiguration(to: normalizedPlan, config: operationConfig),
            config: operationConfig
        )
        let planToApply = OrganizationModePlanEnforcer.enforce(
            normalizedRenamePlan,
            mode: operationMode,
            baseURL: baseURL
        )
        // Validate before publishing: a failing plan must not replace the
        // user-reviewed preview, and must surface as .error (not a silent stay
        // in .ready/.completed with a swapped plan).
        do {
            try await validator.validateOffMain(
                planToApply,
                at: baseURL,
                allowedStorageLocations: allowedLocations,
                mode: operationMode
            )
        } catch {
            // A superseded run must not replace the winner's state with its own
            // validation failure.
            guard isCurrentOrganizeRun(runToken) else { throw error }
            let displayMessage = userFacingErrorMessage(for: error)
            transition(to: .error(error), force: true)
            errorMessage = displayMessage
            OrganizerServices.showError(
                message: displayMessage,
                folderPath: baseURL.path,
                isCritical: true
            )
            throw error
        }
        self.currentPlan = planToApply
        currentPlanBaseURL = baseURL.standardizedFileURL

        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "Applying organization to: \(baseURL.lastPathComponent)"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        updateState(.applying, stage: "Applying changes to your files...", progress: 0.0)
        // A restart mid-apply must not resurrect a stale ready preview; the
        // interrupted marker restores the folder without auto-reapplying.
        persistManualSession(directory: baseURL, plan: nil, stateHint: .interrupted, instructions: currentRunInstructions)
        
        // Start learning session for rule tracking
        if let learningsObserver = learningsObserver {
            learningsObserver.startSession(
                folderPath: baseURL.path,
                historyEntryId: nil,
                learningExcluded: currentRunLearningExcluded
            )
        }

        var completedOperationsBeforeHistory: [FileSystemManager.FileOperation] = []

        do {
            let applyProgressThrottle = ApplyProgressThrottle()
            let operations = try await fileSystemManager.applyOrganization(
                planToApply,
                at: baseURL, 
                dryRun: dryRun, 
                enableTagging: enableTagging,
                strictExclusions: aiConfig?.strictExclusions ?? true,
                exclusionManager: exclusionRules,
                skipPreValidation: true,
                progress: { [weak self] percent, message in
                    guard applyProgressThrottle.shouldReport(percent: percent) else { return }
                    Task { @MainActor [weak self] in
                        guard let self, !Task.isCancelled, !self.isCancellationRequested else { return }
                        self.progress = min(percent, 1.0)
                        self.organizationStage = message
                    }
                }
            )
            completedOperationsBeforeHistory = operations

            #if DEBUG
            // Lets tests cancel deterministically after moves complete but
            // before the post-move cancellation check.
            if let postMoveTestHook {
                await postMoveTestHook()
            }
            #endif

            try checkCancellation()
            
            // Track rule applications for learning feedback
            if let learningsObserver = learningsObserver, !dryRun, !currentRunLearningExcluded {
                // Warm the profile off-main before synchronous feedback hooks
                // read it, so a cold Keychain lookup cannot freeze the UI.
                await learningsManager?.loadProfileIfNeededForCollectionAsync()
                try checkCancellation()
                // Pre-start the session so rule applications can be recorded
                learningsObserver.startSession(folderPath: baseURL.path, historyEntryId: nil, operations: operations)
                recordRuleApplications(for: planToApply, operations: operations, observer: learningsObserver)
            }

            if !dryRun, !currentRunLearningExcluded, !planHistory.isEmpty {
                let rejectedPlans = planHistory
                let evidence = await Task.detached(priority: .utility) {
                    PlanPreferenceDiffer.compare(
                        rejectedPlans: rejectedPlans,
                        acceptedPlan: planToApply,
                        folderPath: baseURL.path
                    )
                }.value
                if let evidence {
                    learningsManager?.recordRegenerationPreferenceEvidence(evidence)
                }
            }

            let historyEntry = OrganizationHistoryEntry(
                directoryPath: baseURL.path,
                filesOrganized: planToApply.totalFiles,
                foldersCreated: planToApply.totalFolders,
                plan: planToApply,
                success: true,
                status: .completed,
                rawAIResponse: streamingContent.isEmpty ? nil : streamingContent,
                operations: operations,
                source: source
            )

            await MainActor.run {
                history.addEntry(historyEntry)
                organizationStage = "Complete!"
                progress = 1.0
                transition(to: .completed)
                // The enforced mode is now applied; consume the one-shot
                // watched-review override so it cannot leak into a later plan.
                preparedPlanModeOverride = nil
                persistManualSession(directory: baseURL, plan: planToApply, stateHint: .completed, instructions: currentRunInstructions)
            }

            NotificationCenter.default.post(
                name: .organizationDidFinish,
                object: nil,
                userInfo: [
                    "url": baseURL,
                    "entry": historyEntry,
                    "operations": operations,
                    "learningExcluded": currentRunLearningExcluded,
                ]
            )
            
            // End learning session
            if let learningsObserver = learningsObserver {
                learningsObserver.endSession()
            }

            // Auto-reveal in Finder is opt-in.
            let shouldAutoRevealInFinder = automationManager?.autoSelectOrganizedFolders ?? false

            if let automationManager = automationManager, automationManager.isAutomationGranted {
                automationManager.refreshFinder(at: baseURL)

                if shouldAutoRevealInFinder {
                    let folderURLs = planToApply.suggestions.map { resolvePlanFolderURL(folderName: $0.folderName, baseURL: baseURL) }
                    automationManager.selectOrganizedFolders(folderURLs: folderURLs)
                }
            } else if shouldAutoRevealInFinder {
                let folderURLs = planToApply.suggestions.compactMap { suggestion -> URL? in
                    let url = resolvePlanFolderURL(folderName: suggestion.folderName, baseURL: baseURL)
                    return FileManager.default.fileExists(atPath: url.path) ? url : nil
                }
                if !folderURLs.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(folderURLs)
                }
            }

            OrganizerServices.captureWorkflow(
                workflow: "organize",
                stage: "applied",
                outcome: "success",
                properties: OrganizerServices.durationProperties(
                    Date().timeIntervalSince(analyticsStartedAt)
                ).merging([
                    "count_bucket": OrganizerServices.countBucket(operations.count),
                    "entry_source": source.rawValue,
                    "mode": operationMode.rawValue,
                ]) { current, _ in current }
            )

        } catch where Self.isCancellationError(error) {
            // Persist whatever was already moved before the cancellation
            // surfaced. resetToIdle() only records for .organizing/.ready and
            // the state here is .applying, so without this entry the moved
            // files would have no undo path.
            let partialOperations: [FileSystemManager.FileOperation]
            if case FileSystemError.partialApplyFailure(let operations, _) = error,
               !operations.isEmpty {
                partialOperations = operations
            } else {
                partialOperations = completedOperationsBeforeHistory
            }
            if !partialOperations.isEmpty {
                let cancelledEntry = OrganizationHistoryEntry(
                    directoryPath: baseURL.path,
                    filesOrganized: partialOperations.filter { $0.type == .moveFile || $0.type == .renameFile }.count,
                    foldersCreated: partialOperations.filter { $0.type == .createFolder }.count,
                    plan: planToApply,
                    success: false,
                    status: .partiallyUndone,
                    errorMessage: "User cancelled the operation",
                    rawAIResponse: streamingContent.isEmpty ? nil : streamingContent,
                    operations: partialOperations,
                    source: source
                )
                // Kept even when superseded: this entry is the only undo path
                // for the files that already moved before the cancellation.
                await MainActor.run {
                    history.addEntry(cancelledEntry)
                }
                if isCurrentOrganizeRun(runToken) {
                    performApplyRecordedFailure = true
                }
            }
            OrganizerServices.captureWorkflow(
                workflow: "organize",
                stage: "apply",
                outcome: "cancelled",
                properties: OrganizerServices.durationProperties(
                    Date().timeIntervalSince(analyticsStartedAt)
                ).merging([
                    "count_bucket": OrganizerServices.countBucket(completedOperationsBeforeHistory.count),
                    "entry_source": source.rawValue,
                    "mode": operationMode.rawValue,
                ]) { current, _ in current }
            )
            if isCurrentOrganizeRun(runToken) {
                resetToIdleUnlessCancellationResetIsSuppressed(source: source)
            }
            throw CancellationError()
        } catch {
            let partialOperations: [FileSystemManager.FileOperation]?
            let wasCancelled: Bool
            if case FileSystemError.partialApplyFailure(let operations, let description) = error {
                partialOperations = operations.isEmpty ? nil : operations
                wasCancelled = Self.isCancellationError(error)
                    || isCancellationRequested
                    || description.localizedCaseInsensitiveContains("cancel")
            } else if !completedOperationsBeforeHistory.isEmpty {
                partialOperations = completedOperationsBeforeHistory
                wasCancelled = Self.isCancellationError(error) || isCancellationRequested
            } else {
                partialOperations = nil
                wasCancelled = Self.isCancellationError(error) || isCancellationRequested
            }

            let failedEntry = OrganizationHistoryEntry(
                directoryPath: baseURL.path,
                filesOrganized: partialOperations?.filter { $0.type == .moveFile || $0.type == .renameFile }.count ?? 0,
                foldersCreated: partialOperations?.filter { $0.type == .createFolder }.count ?? 0,
                plan: planToApply,
                success: false,
                status: wasCancelled && partialOperations == nil
                    ? .cancelled
                    : (partialOperations == nil ? .failed : .partiallyUndone),
                errorMessage: wasCancelled ? "User cancelled the operation" : error.userFacingMessage,
                rawAIResponse: streamingContent.isEmpty ? nil : streamingContent,
                operations: partialOperations,
                source: source
            )

            // A superseded run must not record a failure for the old directory
            // or overwrite the winner's state; the entry it built is dropped.
            if isCurrentOrganizeRun(runToken) {
                await MainActor.run {
                    history.addEntry(failedEntry)
                    if wasCancelled {
                        resetToIdleUnlessCancellationResetIsSuppressed(source: source)
                    } else {
                        transition(to: .error(error), force: true)
                        errorMessage = userFacingErrorMessage(for: error)
                        organizationStage = errorMessage ?? "Apply failed"
                    }
                }
                // performApply owns this failure's history row; enclosing catches
                // must not add a duplicate via handleOrganizationError.
                performApplyRecordedFailure = true
            }

            OrganizerServices.captureWorkflow(
                workflow: "organize",
                stage: "apply",
                outcome: wasCancelled
                    ? (partialOperations == nil ? "cancelled" : "cancelled_partially_completed")
                    : (partialOperations == nil ? "failed" : "partially_completed"),
                properties: OrganizerServices.durationProperties(
                    Date().timeIntervalSince(analyticsStartedAt)
                ).merging([
                    "count_bucket": OrganizerServices.countBucket(partialOperations?.count ?? 0),
                    "entry_source": source.rawValue,
                    "mode": operationMode.rawValue,
                ]) { current, _ in current }
            )
            OrganizerServices.capture(
                error: error,
                feature: "organize",
                operation: "apply_plan",
                recoverable: partialOperations == nil
            )
            throw error
        }
    }

    @MainActor
    public func redoOrganization(from entry: OrganizationHistoryEntry) async throws {
        let entry = await history.details(for: entry)
        guard let plan = entry.plan else {
            throw OrganizationError.noCurrentPlan
        }
        let baseURL = URL(fileURLWithPath: entry.directoryPath).standardizedFileURL
        currentDirectory = baseURL
        currentPlan = plan
        currentPlanBaseURL = baseURL
        // A redo is a manual apply of a historical plan; it must not inherit a
        // watched-review mode override (even when the plan id is unchanged).
        preparedPlanModeOverride = nil

        // Do not pre-transition to .applying here: apply() owns the
        // idle/ready/completed -> applying transition and treats a second apply
        // while .applying as a no-op, so pre-setting .applying would make this
        // redo a no-op. performApply sets the applying stage.
        do {
            try await apply(at: baseURL, dryRun: false, enableTagging: aiConfig?.enableFileTagging ?? true)
            
            if entry.isUndone {
                var updatedEntry = entry
                updatedEntry.isUndone = false
                updatedEntry.status = .completed
                history.updateEntry(updatedEntry)
            }
            
            await MainActor.run {
                organizationStage = "Redo complete"
                progress = 1.0
                transition(to: .completed)
            }
        } catch {
            await MainActor.run {
                transition(to: .error(error), force: true)
                errorMessage = error.userFacingMessage
            }
            throw error
        }
    }

    /// Generate organization plan with a specific provider
    /// Returns a plan without updating the organizer's state
    private func generatePlanWithProvider(
        files: [FileItem],
        provider: AIProvider,
        model: String? = nil,
        customInstructions: String? = nil
    ) async throws -> OrganizationPlan {
        var tempConfig = aiConfig ?? AIConfig.default
        tempConfig.provider = provider
        tempConfig.model = model ?? provider.defaultModel
        
        let isSameProvider = aiConfig?.provider == provider
        let hasCustomURL = !(aiConfig?.apiURL ?? "").isEmpty
        
        if !isSameProvider || !hasCustomURL {
            tempConfig.apiURL = provider.defaultAPIURL
        }
        
        let tempClient = try AIClientFactory.createClient(config: tempConfig)
        
        let personaPrompt = effectivePersonaPrompt()
        
        let isRenameOnly = tempConfig.mode == .renameOnly
        var instructions = PromptBuilder.wrapDirectUserInstructions(customInstructions ?? self.customInstructions)
        if let learnedContext = learningsManager?.generatePromptContext(forFolder: currentDirectory?.path), !learnedContext.isEmpty {
            instructions += "\n\n" + learnedContext
        }
        if !isRenameOnly,
           let modelDirContext = learningsManager?.generateModelDirectoryContext(for: files),
           !modelDirContext.isEmpty {
            instructions += "\n\n" + modelDirContext
        }
        if !isRenameOnly, let storageContext = await storageLocationsManager?.generatePromptContext(), !storageContext.isEmpty {
            instructions += "\n\n" + storageContext
        }
        instructions += exclusionInstructions(forRenameOnly: isRenameOnly)
        
        let plan = try await analyzeInBoundedBatches(
            files: files,
            client: tempClient,
            imagePayload: [:],
            instructions: instructions,
            personaPrompt: personaPrompt,
            temperature: nil,
            modeOverride: tempConfig.mode
        )
        
        return plan
    }

    /// Get files from current plan for regeneration
    public func getFilesFromCurrentPlan() -> [FileItem] {
        guard let currentPlan = currentPlan else { return [] }
        
        var allFiles: [FileItem] = []
        func collectFiles(_ suggestion: FolderSuggestion) {
            allFiles.append(contentsOf: suggestion.files)
            for subfolder in suggestion.subfolders {
                collectFiles(subfolder)
            }
        }
        for suggestion in currentPlan.suggestions {
            collectFiles(suggestion)
        }
        allFiles.append(contentsOf: currentPlan.unorganizedFiles)
        
        return allFiles
    }
    
    /// Record which files were moved by which inferred rules (for learning feedback)
    private func recordRuleApplications(for plan: OrganizationPlan, operations: [FileSystemManager.FileOperation], observer: ContinuousLearningObserver) {
        learningsManager?.loadProfileIfNeededForCollection()
        let activeRules = learningsManager?.getActiveRules() ?? []
        guard !activeRules.isEmpty else { return }
        let compiledRules = activeRules.compactMap { rule -> (id: String, regex: NSRegularExpression)? in
            guard let regex = try? NSRegularExpression(
                pattern: rule.pattern,
                options: .caseInsensitive
            ) else {
                return nil
            }
            return (rule.id, regex)
        }
        
        // Build a map of filename to ruleId from the plan suggestions
        var fileToRuleMap: [String: String] = [:]
        
        func traverseSuggestions(_ suggestions: [FolderSuggestion]) {
            for suggestion in suggestions {
                for file in suggestion.files {
                    if let ruleId = suggestion.ruleId {
                        fileToRuleMap[file.displayName] = ruleId
                    }
                }
                traverseSuggestions(suggestion.subfolders)
            }
        }
        
        traverseSuggestions(plan.suggestions)
        
        for operation in operations {
            guard operation.type == .moveFile || operation.type == .renameFile else { continue }
            guard let destPath = operation.destinationPath else { continue }
            
            let fileName = URL(fileURLWithPath: operation.sourcePath).lastPathComponent
            
            // Priority 1: Use specific rule mapping from the AI plan if available
            if let ruleId = fileToRuleMap[fileName] {
                observer.recordRuleApplication(destinationPath: destPath, ruleId: ruleId)
                continue
            }
            
            // Priority 2: Try to match the rule's regex pattern against the filename (heuristic backup)
            let range = NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)
            for rule in compiledRules {
                if rule.regex.firstMatch(in: fileName, options: [], range: range) != nil {
                    observer.recordRuleApplication(destinationPath: destPath, ruleId: rule.id)
                    break
                }
            }
        }
    }
    
    /// Regenerate preview with a specific provider and model
    public func regenerateWithModel(provider: AIProvider, model: String) async throws {
        try await regenerateWithModel(provider: provider, model: model, files: nil)
    }

    package func regenerateWithModel(provider: AIProvider, model: String, files suppliedFiles: [FileItem]?) async throws {
        OrganizerServices.captureWorkflow(
            workflow: "regenerate",
            stage: "started",
            outcome: "started",
            properties: ["variant": "model"]
        )
        if suppliedFiles != nil && (state == .scanning || state == .organizing) {
            await cancelCurrentOperationForRestart()
        }
        if suppliedFiles == nil && (state == .scanning || state == .organizing) {
            guard let directory = currentDirectory else {
                throw OrganizationError.noCurrentPlan
            }

            await cancelCurrentOperationForRestart()

            withBatchUpdates {
                clearStreamingDisplayState()
                isStreaming = false
                showTimeoutMessage = false
                currentInsight = ""
                insightHistory = []
                insightsCache = nil
                errorMessage = nil
                elapsedTime = 0
                let noun = aiConfig?.mode == .renameOnly ? "rename analysis" : "analysis"
                organizationStage = "Restarting \(noun) with \(provider.displayName) (\(model))..."
                progress = 0.08
            }

            // The cancelled run's token was cleared, but another run can
            // legitimately claim it while the old task unwinds. Use a
            // non-stealing claim so that run keeps ownership instead of being
            // orphaned, and skip the restart if it won the slot.
            guard let restartToken = claimOrganizeRun() else {
                ModelLog.debug("Restart blocked: another run claimed the organize slot while unwinding")
                return
            }
            defer { releaseOrganizeRun(restartToken) }
            try await runOrganizationTask(directory: directory, customPrompt: nil, temperature: nil, runToken: restartToken)
            return
        }

        var files = suppliedFiles ?? getFilesFromCurrentPlan()

        if suppliedFiles == nil, files.isEmpty, let directory = currentDirectory {
            files = try await scanPhase(directory: directory)
        }

        guard !files.isEmpty else {
            throw OrganizationError.noCurrentPlan
        }

        guard !isOperationInProgress() else {
            return
        }
        guard let runToken = claimOrganizeRun() else {
            ModelLog.debug("Regenerate blocked: another run is already in progress")
            return
        }
        defer { releaseOrganizeRun(runToken) }

        // Run inside the tracked task so cancel() aborts the AI request
        // instead of letting it keep generating a response nobody will use.
        cancelInternal(preservingToken: runToken)
        isCancellationRequested = false
        currentTask = Task {
            try await performRegenerateWithModel(provider: provider, model: model, files: files)
        }
        defer { clearTask(ifOwnedBy: runToken) }
        do {
            try await currentTask?.value
        } catch where Self.isCancellationError(error) {
            try checkCancellationRunOwnership(runToken)
            if suppressCancellationReset {
                suppressCancellationReset = false
                throw CancellationError()
            }
            resetToIdle()
            throw CancellationError()
        }
    }

    private func performRegenerateWithModel(provider: AIProvider, model: String, files: [FileItem]) async throws {
        var files = files
        if let exclusionRules = exclusionRules {
            files = exclusionRules.filterFiles(files)
        }

        // Reset streaming state
        await MainActor.run {
            clearStreamingDisplayState()
            isStreaming = false
            showTimeoutMessage = false
            currentInsight = ""
            insightHistory = []
            insightsCache = nil
        }

        let modelStage = aiConfig?.mode == .renameOnly
            ? "Getting new names from \(provider.displayName) (\(model))..."
            : "Getting a new plan from \(provider.displayName) (\(model))..."
        updateState(.organizing, stage: modelStage, progress: 0.3)
        await MainActor.run {
            isStreaming = true
        }

        startTimeoutTimer()

        do {
            var newPlan = try await generatePlanWithProvider(files: files, provider: provider, model: model)
            newPlan.version = (currentPlan?.version ?? 0) + 1
            
            if let exclusionRules = exclusionRules {
                let enforcer = ExclusionEnforcer(exclusionManager: exclusionRules)
                let validationResult = enforcer.validate(newPlan)
                if validationResult.hasViolations {
                    OrganizerServices.log("Exclusion violations in regenerated preview: \(validationResult.violationCount)", category: "FolderOrganizer")
                    newPlan = validationResult.cleanedPlan ?? newPlan
                }
            }
            
            try checkCancellation()
            
            stopTimeoutTimer()
            
            await MainActor.run {
                guard !isCancellationRequested else { return }
                isStreaming = false
                organizationStage = "Ready!"
                progress = 1.0
                if let existingPlan = self.currentPlan {
                    self.recordPreviewVersion(existingPlan)
                }
                self.currentPlan = normalizeRenameSuggestions(in: applyRenameRuleConfiguration(to: newPlan))
                transition(to: .ready)
            }
            OrganizerServices.captureWorkflow(
                workflow: "regenerate",
                stage: "plan_ready",
                outcome: "success",
                properties: ["variant": "model"]
            )
        } catch where Self.isCancellationError(error) {
            stopTimeoutTimer()
            await MainActor.run {
                isStreaming = false
                if !suppressCancellationReset {
                    resetToIdle()
                }
            }
            throw CancellationError()
        } catch {
            stopTimeoutTimer()
            await MainActor.run {
                transition(to: .error(error), force: true)
                errorMessage = error.userFacingMessage
            }
            OrganizerServices.captureWorkflow(
                workflow: "regenerate",
                stage: "plan_generation",
                outcome: "failed",
                properties: ["variant": "model"]
            )
            OrganizerServices.capture(
                error: error,
                feature: "organize",
                operation: "regenerate_with_model"
            )
            throw error
        }
    }
}
