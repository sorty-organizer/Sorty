import Foundation
import SwiftUI
import Combine
import SortyLearnings
import SortyFileSystem
import SortyModels
import SortyAI
import SortyFS

// MARK: - Regenerate Preview
extension FolderOrganizer {
    public func regeneratePreview() async throws {
        OrganizerServices.captureWorkflow(
            workflow: "regenerate",
            stage: "started",
            outcome: "started",
            properties: ["variant": "same_configuration"]
        )
        guard let basePlan = currentPlan else {
            throw OrganizationError.noCurrentPlan
        }

        guard !isOperationInProgress() else {
            return
        }
        guard let runToken = claimOrganizeRun() else {
            ModelLog.debug("Regenerate preview blocked: another run is already in progress")
            return
        }
        defer { releaseOrganizeRun(runToken) }

        // Get original files from the current plan
        var allFiles: [FileItem] = []
        func collectFiles(_ suggestion: FolderSuggestion) {
            allFiles.append(contentsOf: suggestion.files)
            for subfolder in suggestion.subfolders {
                collectFiles(subfolder)
            }
        }
        for suggestion in basePlan.suggestions {
            collectFiles(suggestion)
        }
        allFiles.append(contentsOf: basePlan.unorganizedFiles)

        if let exclusionRules = exclusionRules {
            allFiles = exclusionRules.filterFiles(allFiles)
        }

        // Run inside the tracked task so cancel() aborts the AI request
        // instead of letting it keep generating a response nobody will use.
        cancelInternal(preservingToken: runToken)
        isCancellationRequested = false
        currentTask = Task {
            try await performRegeneratePreview(allFiles: allFiles, basePlan: basePlan)
        }
        defer {
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
            if suppressCancellationReset {
                suppressCancellationReset = false
                throw CancellationError()
            }
            resetToIdle()
            throw CancellationError()
        }
    }

    private func performRegeneratePreview(allFiles: [FileItem], basePlan: OrganizationPlan) async throws {
        let currentPlan = basePlan
        let requestContext = (aiClient?.config ?? aiConfig).map {
            AIRequestDiagnosticContext(config: $0, fileCount: allFiles.count)
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

        let isRenameOnly = aiConfig?.mode == .renameOnly
        updateState(
            .organizing,
            stage: isRenameOnly ? "Generating new filename suggestions..." : "Generating a new organization plan...",
            progress: 0.3
        )
        await MainActor.run {
            isStreaming = true
        }

        startTimeoutTimer()

        do {
            guard let client = aiClient else {
                throw OrganizationError.clientNotConfigured
            }

            try checkCancellation()

            // Log the previous attempt as skipped/superseded
            if let directory = currentDirectory, !currentRunLearningExcluded {
                let skippedEntry = OrganizationHistoryEntry(
                    directoryPath: directory.path,
                    filesOrganized: 0,
                    foldersCreated: 0,
                    plan: currentPlan,
                    success: false,
                    status: .skipped,
                    errorMessage: isRenameOnly ? "User requested different filename suggestions" : "User requested different organization",
                    rawAIResponse: streamingContent.isEmpty ? nil : streamingContent
                )
                history.addEntry(skippedEntry)
            }

            // Generate new plan
            let personaPrompt = effectivePersonaPrompt()
            
            var instructions = PromptBuilder.wrapDirectUserInstructions(customInstructions)
            if let learnedContext = learningsManager?.generatePromptContext(forFolder: currentDirectory?.path), !learnedContext.isEmpty {
                instructions += "\n\n" + learnedContext
            }

            if !isRenameOnly,
               let modelDirContext = learningsManager?.generateModelDirectoryContext(for: allFiles),
               !modelDirContext.isEmpty {
                instructions += "\n\n" + modelDirContext
            }
            
            // Add Storage Locations context
            if !isRenameOnly, let storageContext = await storageLocationsManager?.generatePromptContext(), !storageContext.isEmpty {
                instructions += "\n\n" + storageContext
            }
            instructions += exclusionInstructions(forRenameOnly: isRenameOnly)
            
            var newPlan = try await analyzeInBoundedBatches(
                files: allFiles,
                client: client,
                imagePayload: [:],
                instructions: instructions,
                personaPrompt: personaPrompt,
                temperature: nil
            )
            newPlan.version = (currentPlan.version) + 1
            
            if let exclusionRules = exclusionRules {
                let enforcer = ExclusionEnforcer(exclusionManager: exclusionRules)
                let validationResult = enforcer.validate(newPlan)
                if validationResult.hasViolations {
                    OrganizerServices.log("Exclusion violations in regenerated preview: \(validationResult.violationCount)", category: "FolderOrganizer")
                    newPlan = validationResult.cleanedPlan ?? newPlan
                }
            }

            handleLearningToolCall(
                from: newPlan,
                source: .manual,
                folderPath: currentDirectory?.path ?? ""
            )

            if let directory = currentDirectory, !currentRunLearningExcluded {
                let summary = currentPlan.suggestions
                    .map { "\($0.folderName) (\($0.files.count) files)" }
                    .joined(separator: ", ")
                learningsManager?.recordRegeneratedOrganization(
                    folderPath: directory.path,
                    previousPlanSummary: summary,
                    guidingInstruction: customInstructions,
                    regenerationCount: currentPlan.version
                )
                learningsManager?.recordGuidingInstruction(
                    customInstructions,
                    for: directory.path,
                    fileCount: allFiles.count
                )
            }

            stopTimeoutTimer()

            try checkCancellation()

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
                properties: ["variant": "same_configuration"]
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

            // Record failed attempt
            if let directory = currentDirectory {
                let failedEntry = OrganizationHistoryEntry(
                    directoryPath: directory.path,
                    filesOrganized: 0,
                    foldersCreated: 0,
                    plan: nil,
                    success: false,
                    status: .failed,
                    errorMessage: error.userFacingMessage,
                    rawAIResponse: streamingContent.isEmpty ? nil : streamingContent
                )
                history.addEntry(failedEntry)
            }

            OrganizerServices.captureWorkflow(
                workflow: "regenerate",
                stage: "plan_generation",
                outcome: "failed",
                properties: ["variant": "same_configuration"]
            )
            OrganizerServices.capture(
                error: error,
                feature: "organize",
                operation: "regenerate_preview",
                requestContext: requestContext
            )
            throw error
        }
    }

    // MARK: - Multi-State Undo/Redo

    private func normalizedRevertPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func retainedOperations(
        from operations: [FileSystemManager.FileOperation]?,
        retryableFailedOperationIDs: [UUID]
    ) -> [FileSystemManager.FileOperation]? {
        guard let operations, !operations.isEmpty else {
            return nil
        }

        let failedIDs = Set(retryableFailedOperationIDs)
        guard !failedIDs.isEmpty else {
            return nil
        }

        let remaining = operations.filter { failedIDs.contains($0.id) }
        return remaining.isEmpty ? nil : remaining
    }

    private func withRevertGuard<T>(
        entryIDs: [UUID],
        path: String,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        let normalizedPath = normalizedRevertPath(path)
        let didAcquire = await revertOperationTracker.begin(entryIDs: entryIDs, path: normalizedPath)
        guard didAcquire else {
            throw OrganizationError.revertAlreadyInProgress(normalizedPath)
        }

        #if DEBUG
        if let revertOperationTestHook {
            await revertOperationTestHook()
        }
        #endif

        do {
            let result = try await operation()
            await revertOperationTracker.end(entryIDs: entryIDs, path: normalizedPath)
            return result
        } catch {
            await revertOperationTracker.end(entryIDs: entryIDs, path: normalizedPath)
            throw error
        }
    }

    @discardableResult
    private func performUndoHistoryEntry(
        _ entry: OrganizationHistoryEntry,
        shouldPostNotification: Bool
    ) async throws -> FileSystemManager.RestoreResult {
        guard !entry.isUndone else {
            return FileSystemManager.RestoreResult(successfulOperations: 0, missingFiles: [])
        }
        guard let operations = entry.operations, !operations.isEmpty else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        // A revert is a new operation: clear any stale cancellation flag left
        // by reset()/cancel() and claim .applying (forced) so a concurrent
        // organize() observes real work in flight instead of racing the moves.
        // From .idle the plain transition is invalid, so this must be forced.
        isCancellationRequested = false
        updateState(.applying, stage: "Verifying files before undo...", progress: 0.1, force: true)

        let moveOps = operations.filter { $0.type == .moveFile || $0.type == .renameFile }
        var preCheckMissing: [String] = []
        for op in moveOps {
            if let dest = op.destinationPath, !FileManager.default.fileExists(atPath: dest) {
                let filename = URL(fileURLWithPath: dest).lastPathComponent
                preCheckMissing.append(filename)
                ModelLog.debug("Pre-check: file missing at \(dest)")
            }
        }

        if !preCheckMissing.isEmpty {
            let totalMoves = moveOps.count
            ModelLog.debug("Pre-check: \(preCheckMissing.count)/\(totalMoves) files missing before undo")
        }

        updateProgress(0.3, stage: "Undoing changes...")

        do {
            let result = try await fileSystemManager.reverseOperations(operations)

            var updatedEntry = entry
            let remainingOperations = retainedOperations(
                from: updatedEntry.operations,
                retryableFailedOperationIDs: result.retryableFailedOperationIDs
            )

            updatedEntry.operations = remainingOperations
            updatedEntry.isUndone = !result.hasIssues && remainingOperations == nil
            updatedEntry.undoRestoredCount = (entry.undoRestoredCount ?? 0) + result.successfulOperations
            updatedEntry.undoFailedFiles = result.hasIssues ? result.missingFiles : nil
            updatedEntry.status = remainingOperations == nil && !result.hasIssues ? .undo : .partiallyUndone

            history.updateEntry(updatedEntry)

            await MainActor.run {
                if result.hasIssues, !result.missingFiles.isEmpty {
                    organizationStage = "Undo complete: \(result.successfulOperations) restored, \(result.missingFiles.count) couldn't be found"
                } else if result.hasIssues {
                    organizationStage = "Undo complete: \(result.successfulOperations) restored"
                } else {
                    organizationStage = "Undo complete"
                }
                progress = 1.0
                transition(to: .idle, force: true)
            }

            if shouldPostNotification {
                NotificationCenter.default.post(
                    name: .organizationDidRevert,
                    object: nil,
                    userInfo: [
                        "url": URL(fileURLWithPath: entry.directoryPath),
                        "entry": updatedEntry,
                        "restoreResult": result
                    ]
                )
            }

            return result

        } catch {
            await MainActor.run {
                transition(to: .error(error), force: true)
                errorMessage = error.userFacingMessage
            }
            throw error
        }
    }

    /// Undoes a specific historical session
    /// Pre-checks file existence, recovers from per-file errors, and tracks partial success
    @discardableResult
    public func undoHistoryEntry(_ entry: OrganizationHistoryEntry) async throws -> FileSystemManager.RestoreResult {
        let entry = await history.details(for: entry)
        let reliabilitySpan = OrganizerServices.startSpan(
            name: "undo_organization",
            operation: "workflow.undo",
            feature: "history"
        )
        defer { reliabilitySpan?.finish() }
        OrganizerServices.captureWorkflow(
            workflow: "undo",
            stage: "started",
            outcome: "started"
        )
        do {
            let result = try await withRevertGuard(entryIDs: [entry.id], path: entry.directoryPath) {
                try await self.performUndoHistoryEntry(entry, shouldPostNotification: true)
            }
            OrganizerServices.captureWorkflow(
                workflow: "undo",
                stage: "completed",
                outcome: result.hasIssues ? "partially_completed" : "success",
                properties: [
                    "count_bucket": OrganizerServices.countBucket(result.successfulOperations),
                ]
            )
            return result
        } catch {
            OrganizerServices.captureWorkflow(
                workflow: "undo",
                stage: "restore",
                outcome: "failed"
            )
            OrganizerServices.capture(
                error: error,
                feature: "history",
                operation: "undo_organization"
            )
            throw error
        }
    }

    /// Restores to a previous state by undoing all intermediate sessions
    /// Returns a combined RestoreResult with totals from all undone entries
    @discardableResult
    public func restoreToState(targetEntry: OrganizationHistoryEntry) async throws -> FileSystemManager.RestoreResult {
        // Find all sessions on the same path that are after this one and not undone
        let path = targetEntry.directoryPath
        let entriesToUndo = history.entries.filter {
            $0.directoryPath == path &&
            $0.timestamp > targetEntry.timestamp &&
            !$0.isUndone &&
            ($0.status == .completed || $0.status == .partiallyUndone) &&
            $0.storedOperationCount > 0
        }.sorted { $0.timestamp > $1.timestamp } // Undo most recent first

        return try await withRevertGuard(
            entryIDs: entriesToUndo.map(\.id),
            path: path
        ) {
            self.isCancellationRequested = false
            self.updateState(.applying, stage: "Rolling back states...", progress: 0.1, force: true)

            let total = Double(max(entriesToUndo.count, 1))
            var combinedSuccessCount = 0
            var combinedMissingFiles: [String] = []
            var combinedRetryableFailures: [UUID] = []

            for (index, entry) in entriesToUndo.enumerated() {
                let entry = await self.history.details(for: entry)
                self.updateProgress(Double(index) / total, stage: "Undoing session from \(entry.timestamp.formatted())...")

                let result = try await self.performUndoHistoryEntry(entry, shouldPostNotification: true)
                combinedSuccessCount += result.successfulOperations
                combinedMissingFiles.append(contentsOf: result.missingFiles)
                combinedRetryableFailures.append(contentsOf: result.retryableFailedOperationIDs)
            }

            let combinedResult = FileSystemManager.RestoreResult(
                successfulOperations: combinedSuccessCount,
                missingFiles: combinedMissingFiles,
                retryableFailedOperationIDs: combinedRetryableFailures
            )

            await MainActor.run { [self] in
                self.organizationStage = combinedResult.hasIssues ? "Restoration complete (some files skipped)" : "Restoration complete"
                self.progress = 1.0
                self.transition(to: .idle, force: true)
            }

            return combinedResult
        }
    }

    /// Undoes a single file operation within a history entry
    @discardableResult
    public func undoSingleOperation(from entry: OrganizationHistoryEntry, operation: FileSystemManager.FileOperation) async throws -> FileSystemManager.RestoreResult {
        let detailedEntry = await history.details(for: entry)
        let currentOperation = detailedEntry.operations?.first { $0.id == operation.id } ?? operation
        return try await withRevertGuard(entryIDs: [detailedEntry.id], path: detailedEntry.directoryPath) {
            // Single-file revert is still file work: track it like the batch
            // paths so organize() cannot start mid-restore. Forced because the
            // plain idle->applying transition is invalid.
            self.isCancellationRequested = false
            self.updateState(.applying, stage: "Undoing change...", progress: 0.3, force: true)

            do {
                let siblingOperations = (detailedEntry.operations ?? []).filter { $0.id != currentOperation.id }
                let result = try await self.fileSystemManager.restoreSingleOperation(
                    currentOperation,
                    protectedSiblingOperations: siblingOperations
                )

                await MainActor.run {
                    var updatedEntry = detailedEntry
                    let shouldRetainOperation = result.retryableFailedOperationIDs.contains(currentOperation.id)
                    if !shouldRetainOperation {
                        updatedEntry.operations?.removeAll { $0.id == currentOperation.id }
                        if updatedEntry.operations?.isEmpty == true {
                            updatedEntry.operations = nil
                        }
                    }

                    let fullyUndone = updatedEntry.operations == nil && !result.hasIssues
                    updatedEntry.isUndone = fullyUndone
                    updatedEntry.status = fullyUndone ? .undo : .partiallyUndone
                    updatedEntry.undoRestoredCount = (detailedEntry.undoRestoredCount ?? 0) + result.successfulOperations
                    updatedEntry.undoFailedFiles = result.hasIssues ? result.missingFiles : nil

                    self.history.updateEntry(updatedEntry)
                }
                self.updateState(.idle, stage: "Undo complete", progress: 1.0, force: true)

                return result
            } catch {
                // A failed single-file revert must not leave the organizer
                // stuck in .applying; mirror the batch undo error transition.
                await MainActor.run {
                    self.transition(to: .error(error), force: true)
                    self.errorMessage = error.userFacingMessage
                }
                throw error
            }
        }
    }
}
