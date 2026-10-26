import Foundation
import SwiftUI
import Combine
import SortyLearnings
import SortyFileSystem
import SortyModels
import SortyAI
import SortyFS

// MARK: - Cancellation
extension FolderOrganizer {
    /// Cancel any ongoing operation - RELIABLE cancellation
    public func cancel(source: OrganizationEntrySource = .manual) {
        ModelLog.debug("Cancel requested by user")
        OrganizerServices.captureWorkflow(
            workflow: "organize",
            stage: "cancel_requested",
            outcome: "cancelled",
            properties: ["entry_source": source.rawValue]
        )
        AISessionManager.shared.clearErrors()
        cancelInternal()
        resetToIdle(source: source)
    }

    /// Stop live work immediately while a caller owns the visual return-to-start transition.
    /// The caller should finish the cancellation with `cancel()` after the outgoing view has faded.
    public func prepareForReturnToStartTransition() {
        guard state == .scanning || state == .organizing || state == .applying else { return }
        ModelLog.debug("Preparing return-to-start cancellation")
        AISessionManager.shared.clearErrors()
        suppressCancellationReset = true
        cancelInternal()
        isStreaming = false
    }

    /// Stops the tracked task. The active run token is invalidated unless the
    /// caller just claimed it, so a superseded run's deferred cleanup cannot
    /// clear a newer run's task.
    func cancelInternal(preservingToken: UInt64? = nil) {
        isCancellationRequested = true
        currentTask?.cancel()
        currentTask = nil
        if activeOrganizeRunToken != preservingToken {
            activeOrganizeRunToken = nil
        }
        displayUpdateTask?.cancel()
        displayUpdateTask = nil
        insightExtractionTask?.cancel()
        insightExtractionTask = nil
        stopTimeoutTimer()
    }

    func cancelCurrentOperationForRestart() async {
        suppressCancellationReset = true
        let taskToCancel = currentTask
        cancelInternal()
        _ = await taskToCancel?.result
        suppressCancellationReset = false
    }

    func checkCancellation() throws {
        if isCancellationRequested || Task.isCancelled {
            throw CancellationError()
        }
    }

    func isOperationInProgress() -> Bool {
        switch state {
        case .scanning, .organizing, .applying:
            return true
        default:
            return false
        }
    }

    func resetToIdle(source: OrganizationEntrySource = .manual) {
        // Record cancellation in history if we were in a meaningful state
        if state == .organizing || state == .ready {
            if let directory = currentDirectory {
                let cancelledEntry = OrganizationHistoryEntry(
                    directoryPath: directory.path,
                    filesOrganized: 0,
                    foldersCreated: 0,
                    plan: currentPlan,
                    success: false,
                    status: .cancelled,
                    errorMessage: "User cancelled the operation",
                    rawAIResponse: streamingContent.isEmpty ? nil : streamingContent,
                    source: source
                )
                history.addEntry(cancelledEntry)

                // Record to learnings with available context (avoiding expensive directory re-scans)
                let fileCount = max(scannedFileCount, currentPlan?.totalFiles ?? 0)
                let proposedFolders = currentPlan?.suggestions.count ?? 0
                let folderNames = currentPlan?.suggestions.map { $0.folderName }
                
                if !currentRunLearningExcluded {
                    learningsManager?.recordCancelledOrganization(
                        folderPath: directory.path,
                        fileCount: fileCount,
                        proposedFolderCount: proposedFolders,
                        instructions: customInstructions.isEmpty ? nil : customInstructions,
                        stage: organizationStage.isEmpty ? "analysis" : organizationStage,
                        proposedFolderNames: folderNames,
                        proposedStructureSummary: nil,
                        fileExtensionCounts: nil,
                        regenerationCount: currentPlan?.version ?? 0,
                        regenerationInstructions: nil,
                        aiModel: aiConfig?.model
                    )
                }
            }
        }

        clearStreamingDisplayState()
        currentInsight = ""
        insightHistory = []
        insightsCache = nil
        transition(to: .idle, force: true)
        organizationStage = "" // Clear instead of "Organization cancelled" to avoid "doing too much"
        isStreaming = false
        measuredWorkProgress = nil
        // A cancelled run must not resurrect after a restart.
        clearPersistedManualSession()
    }

    func resetToIdleUnlessCancellationResetIsSuppressed(source: OrganizationEntrySource = .manual) {
        guard !suppressCancellationReset else { return }
        resetToIdle(source: source)
    }

    @MainActor
    func handleOrganizationError(
        _ error: Error,
        directory: URL,
        source: OrganizationEntrySource = .manual,
        recordsHistory: Bool = true
    ) {
        // Don't record history or show UI for cancellation errors
        if Self.isCancellationError(error) {
            resetToIdleUnlessCancellationResetIsSuppressed(source: source)
            return
        }

        let displayMessage = userFacingErrorMessage(for: error)
        if recordsHistory {
            let failedEntry = OrganizationHistoryEntry(
                directoryPath: directory.path,
                filesOrganized: 0,
                foldersCreated: 0,
                plan: nil,
                success: false,
                status: .failed,
                errorMessage: displayMessage,
                rawAIResponse: streamingContent.isEmpty ? nil : streamingContent,
                source: source
            )
            history.addEntry(failedEntry)
        }

        transition(to: .error(error), force: true)
        errorMessage = displayMessage
        measuredWorkProgress = nil
        
        // Show error notification
        OrganizerServices.showError(
            message: displayMessage,
            folderPath: currentDirectory?.path,
            isCritical: true
        )
    }

    @MainActor
    func userFacingErrorMessage(for error: Error) -> String {
        if let clientError = error as? AIClientError {
            // Quota errors surface the raw provider body (including long
            // upgrade URLs) via failureReason; keep the toast and history entry
            // to the actionable summary instead.
            if clientError.isQuotaExhausted {
                return "Free-tier allowance used up for this model. Add paid credits or switch models."
            }
            return clientError.failureReason ?? clientError.errorDescription ?? clientError.localizedDescription
        }
        if let localized = error as? LocalizedError {
            if let reason = localized.failureReason, !reason.isEmpty {
                return reason
            }
            if let description = localized.errorDescription, !description.isEmpty {
                return description
            }
        }
        return error.userFacingMessage
    }

    /// Bounded exponential backoff with jitter before a plan retry.
    /// Validation, quality, and exclusion retries resend the full prompt
    /// (request bodies live in the AI client layer), so at minimum each retry
    /// waits its turn: 1s, 2s, 4s capped, plus up to 250 ms of jitter.
    @MainActor
    private func waitForPlanRetryBackoff() async {
        retryAttemptCount += 1
        let cappedShift = min(retryAttemptCount, 2)
        let base = 0.5 * Double(1 << cappedShift)
        let delay = min(4.0, base) + Double.random(in: 0...0.25)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    // MARK: - Exclusion Retry
    
    /// Retry AI call with enhanced exclusion prompt after violations
    func retryWithExclusionEnhancement(
        files: [FileItem],
        client: AIClientProtocol,
        violations: [ExclusionViolation],
        instructions: String,
        personaPrompt: String?,
        temperature: Double?,
        imagePayload: [String: Data]
    ) async -> OrganizationPlan? {
        guard let enforcer = exclusionEnforcer else { return nil }
        
        OrganizerServices.log("Retrying with enhanced exclusion prompt", category: "FolderOrganizer")
        restartPlanGenerationForRetry()
        await waitForPlanRetryBackoff()
        guard (try? checkCancellation()) != nil else { return nil }
        
        // Generate enhanced prompt with violation details
        let enhancedPrompt = instructions + enforcer.generateRetryPromptEnhancement(for: violations)
        
        do {
            defer { stopTimeoutTimer() }
            let retryPlan = try await analyzeInBoundedBatches(
                files: files,
                client: client,
                imagePayload: imagePayload,
                instructions: enhancedPrompt,
                personaPrompt: personaPrompt,
                temperature: temperature
            )
            return retryPlan
        } catch {
            OrganizerServices.log("Exclusion retry failed: \(error.localizedDescription)", category: "FolderOrganizer")
            return nil
        }
    }
    
    func retryWithValidationEnhancement(
        files: [FileItem],
        client: AIClientProtocol,
        validationError: ValidationError,
        directory: URL,
        instructions: String,
        personaPrompt: String?,
        temperature: Double?,
        imagePayload: [String: Data],
        allowedStorageLocations: [StorageLocation]
    ) async -> OrganizationPlan? {
        let enhancement: String
        switch validationError {
        case .pathExists(let path):
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            OrganizerServices.log("Retrying: path exists conflict (\(fileName))", category: "FolderOrganizer")
            enhancement = """
            
            CRITICAL CORRECTION REQUIRED:
            You suggested a folder named "\(fileName)", but a FILE with that exact name already exists in the directory.
            You MUST NOT use "\(fileName)" as a folder name.
            Choose a different folder name that does not conflict with existing files. For example, add a suffix like "\(fileName) Files" or use a different category name.
            """
        case .invalidStorageLocation(let path):
            OrganizerServices.log("Retrying: invalid storage location (\(path))", category: "FolderOrganizer")
            let allowedList: String
            if allowedStorageLocations.isEmpty {
                allowedList = "- No storage locations are currently enabled. Use only relative folder names."
            } else {
                allowedList = allowedStorageLocations
                    .map { "  - \($0.path) (\($0.name))" }
                    .joined(separator: "\n")
            }

            enhancement = """
            
            CRITICAL CORRECTION REQUIRED:
            You used an invalid storage location path: "\(path)".
            If you choose a storage destination, the folder name MUST be an absolute path within one of these approved storage roots:
            \(allowedList)
            You may use a root path itself or a subfolder inside that root (for example: /Archive/Excel Sheets).
            Never use relative placeholders like "storage" or "storage/anything".
            If none of the approved roots fit, organize files with relative folders under the source directory instead.
            """
        default:
            return nil
        }

        restartPlanGenerationForRetry()
        
        let enhancedPrompt = instructions + enhancement
        await waitForPlanRetryBackoff()
        guard (try? checkCancellation()) != nil else { return nil }
        
        do {
            defer { stopTimeoutTimer() }
            let retryPlan = try await analyzeInBoundedBatches(
                files: files,
                client: client,
                imagePayload: imagePayload,
                instructions: enhancedPrompt,
                personaPrompt: personaPrompt,
                temperature: temperature
            )
            
            let normalizedRetryPlan = normalizeStorageDestinations(in: retryPlan, allowedLocations: allowedStorageLocations, sourceDirectoryURL: directory)

            // Validate the retry plan
            try await validator.validateOffMain(
                normalizedRetryPlan,
                at: directory,
                allowedStorageLocations: allowedStorageLocations,
                mode: aiConfig?.mode ?? .organize
            )
            OrganizerServices.log("Validation retry succeeded", category: "FolderOrganizer")
            return normalizedRetryPlan
        } catch {
            OrganizerServices.log("Validation retry failed: \(error.localizedDescription)", category: "FolderOrganizer")
            return nil
        }
    }

    // MARK: - State Updates with Progress

    @MainActor
    func updateState(_ newState: OrganizationState, stage: String, progress: Double, force: Bool = false) {
        guard !isCancellationRequested else { return }
        
        // Validate state transition
        let didTransition = transition(to: newState, force: force)
        guard didTransition else { return }
        
        // Update other properties
        organizationStage = stage
        self.progress = progress
    }

    @MainActor
    func updateProgress(_ progress: Double, stage: String? = nil) {
        guard !isCancellationRequested else { return }
        if let stage = stage {
            // Batch when updating both progress and stage
            withBatchUpdates {
                self.progress = progress
                self.organizationStage = stage
            }
        } else {
            self.progress = progress
        }
    }

    @MainActor
    func updateMeasuredProgress(
        completed: Int,
        total: Int,
        estimatedOverallProgress: Double,
        stage: String
    ) {
        guard !isCancellationRequested else { return }
        withBatchUpdates {
            progress = estimatedOverallProgress
            organizationStage = stage
            measuredWorkProgress = MeasuredWorkProgress(completed: completed, total: total)
        }
    }

    @MainActor
    func clearMeasuredProgress(estimatedOverallProgress: Double, stage: String) {
        guard !isCancellationRequested else { return }
        withBatchUpdates {
            progress = estimatedOverallProgress
            organizationStage = stage
            measuredWorkProgress = nil
        }
    }
}
