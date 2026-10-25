import Foundation
import SwiftUI
import Combine
import SortyLearnings
import SortyFileSystem
import SortyModels
import SortyAI
import SortyFS

// MARK: - Main Organization Methods
extension FolderOrganizer {
    /// Start organization - MUST be explicitly called by user action
    public func organize(directory: URL, customPrompt: String? = nil, temperature: Double? = nil) async throws {
        // Claim the run synchronously before the first await: the state guard
        // is still false while this call loads persisted state, so without a
        // claim a second start would cancel this run and then clobber its
        // task/state on exit.
        guard let runToken = claimOrganizeRun() else {
            ModelLog.debug("Organization blocked: Already starting or in progress")
            return
        }
        defer { releaseOrganizeRun(runToken) }
        // Guard against auto-start
        guard !isOperationInProgress() else {
            ModelLog.debug("Organization blocked: Already in progress")
            return
        }
        preparedPlanModeOverride = nil
        // Never organize with empty/unhydrated exclusion rules.
        await exclusionRules?.loadPersistedState()
        await personaManager?.loadPersistedState()
        await customPersonaStore?.loadPersistedState()
        let reliabilitySpan = OrganizerServices.startSpan(
            name: "organize",
            operation: "workflow.organize",
            feature: "organize"
        )
        defer { reliabilitySpan?.finish() }

        OrganizerServices.captureWorkflow(
            workflow: "organize",
            stage: "started",
            outcome: "started",
            properties: [
                "has_custom_instructions": !(customPrompt?.isEmpty ?? true),
                "mode": aiConfig?.mode.rawValue ?? "organize",
            ]
        )

        // Cancel any existing task first, keeping this run's freshly claimed
        // token alive.
        cancelInternal(preservingToken: runToken)
        // Snapshot the intent before analysis starts so a restart forced by
        // macOS (e.g. enabling Full Disk Access) can offer the folder again.
        persistManualSession(directory: directory, plan: nil, stateHint: .interrupted, instructions: customPrompt ?? customInstructions)
        try await runOrganizationTask(directory: directory, customPrompt: customPrompt, temperature: temperature, runToken: runToken)
    }

    func runOrganizationTask(
        directory: URL,
        customPrompt: String?,
        temperature: Double?,
        runToken: UInt64
    ) async throws {
        currentRunInstructions = customPrompt ?? customInstructions
        modelExcludedCurrentRun = false
        withBatchUpdates {
            // This run generates a fresh plan; a watched-review mode override
            // from an earlier plan must not leak into it.
            preparedPlanModeOverride = nil
            pinsCompletionView = false
            clearStreamingDisplayState()
            streamFileIDTable = [:]
            isStreaming = false
            showTimeoutMessage = false
            currentInsight = ""
            insightHistory = []
            insightsCache = nil
            isCancellationRequested = false
            userInitiatedAction = true
            visionAnalysisSummary = nil
        }

        let task = Task {
            try await performOrganization(
                directory: directory,
                customPrompt: customPrompt,
                temperature: temperature,
                runToken: runToken
            )
        }
        currentTask = task
        defer {
            // Only the run that still owns the token may clear the task; a
            // superseded run must not clobber the winner.
            if isCurrentOrganizeRun(runToken) {
                currentTask = nil
            }
        }

        do {
            try await task.value
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
                return
            }
            resetToIdle()
        } catch {
            throw error
        }
    }

    private func performOrganization(directory: URL, customPrompt: String?, temperature: Double?, runToken: UInt64) async throws {
        let analyticsStartedAt = Date()
        let diagnosticConfig = aiClient?.config ?? aiConfig
        var diagnosticFileCount: Int?
        guard aiClient != nil else {
            let error = OrganizationError.clientNotConfigured
            OrganizerServices.capture(
                error: error,
                feature: "organize",
                operation: "generate_plan",
                requestContext: diagnosticConfig.map { AIRequestDiagnosticContext(config: $0) }
            )
            throw error
        }

        // No process-wide power assertion here: the network-bound AI wait in
        // aiAnalysisPhase holds its own narrowly scoped assertion, while
        // scanning and local validation run without keeping the machine awake.
        // (ProcessInfo has no .utilityAllowingIdleSystemSleep option, so
        // narrowing scope is the available lever.)

        do {
            currentDirectory = directory

            let files = try await scanPhase(directory: directory)
            diagnosticFileCount = files.count

            if files.isEmpty {
                stopTimeoutTimer()

                await MainActor.run {
                    currentPlan = OrganizationPlan(
                        notes: "This folder is empty. Add files and try again."
                    )
                    updateState(.ready, stage: "No files found to organize", progress: 1.0)
                }

                OrganizerServices.previewReady(
                        folderName: directory.lastPathComponent,
                        folderPath: directory.path,
                        planID: currentPlan?.id,
                        originSessionID: windowSessionID
                    )
                OrganizerServices.captureWorkflow(
                    workflow: "organize",
                    stage: "plan_ready",
                    outcome: "empty",
                    properties: OrganizerServices.durationProperties(
                        Date().timeIntervalSince(analyticsStartedAt)
                    ).merging([
                        "count_bucket": OrganizerServices.countBucket(0),
                        "result_kind": "empty_directory",
                    ]) { current, _ in current }
                )

                return
            }

            let (filesWithHashes, duplicateContext) = try await duplicateDetectionPhase(files: files)
            let (plan, instructions, personaPrompt, imagePayload) = try await aiAnalysisPhase(
                files: filesWithHashes,
                directory: directory,
                customPrompt: customPrompt,
                temperature: temperature,
                duplicateContext: duplicateContext
            )
            let validatedPlan = try await validationPhase(
                plan: plan,
                files: filesWithHashes,
                directory: directory,
                instructions: instructions,
                personaPrompt: personaPrompt,
                temperature: temperature,
                imagePayload: imagePayload
            )
            handleLearningToolCall(
                from: validatedPlan,
                source: .manual,
                folderPath: directory.path
            )

            try checkCancellation()

            await MainActor.run {
                guard !isCancellationRequested else { return }
                currentPlan = validatedPlan
                resumeCheckpoint = nil
                updateState(.ready, stage: "Ready!", progress: 1.0)
                persistManualSession(directory: directory, plan: validatedPlan, stateHint: .ready, instructions: currentRunInstructions)
            }

            try checkCancellation()

            OrganizerServices.previewReady(
                    folderName: directory.lastPathComponent,
                    folderPath: directory.path,
                    planID: validatedPlan.id,
                    originSessionID: windowSessionID
                )

            if let learningsObserver = learningsObserver {
                learningsObserver.startSession(
                    folderPath: directory.path,
                    historyEntryId: nil,
                    learningExcluded: currentRunLearningExcluded
                )
                if !currentRunLearningExcluded {
                    recordPlanRules(plan, observer: learningsObserver)
                }
            }

            OrganizerServices.captureWorkflow(
                workflow: "organize",
                stage: "plan_ready",
                outcome: "success",
                properties: OrganizerServices.durationProperties(
                    Date().timeIntervalSince(analyticsStartedAt)
                ).merging([
                    "count_bucket": OrganizerServices.countBucket(files.count),
                    "result_kind": "organization_plan",
                ]) { current, _ in current }.merging(
                    OrganizerServices.generationDurationProperties(validatedPlan.generationStats)
                ) { current, _ in current }
            )

        } catch where Self.isCancellationError(error) {
            // A superseded run must not stop the winner's timeout timer or
            // reset its state; the outer wrapper consumes the suppression flag.
            if isCurrentOrganizeRun(runToken) {
                stopTimeoutTimer()
                resetToIdleUnlessCancellationResetIsSuppressed()
            }
            OrganizerServices.captureWorkflow(
                workflow: "organize",
                stage: "plan_generation",
                outcome: "cancelled",
                properties: OrganizerServices.durationProperties(
                    Date().timeIntervalSince(analyticsStartedAt)
                )
            )
            throw CancellationError()
        } catch {
            // A superseded run must not record a failure for the old directory
            // or overwrite the winner's error state.
            guard isCurrentOrganizeRun(runToken) else { throw error }
            stopTimeoutTimer()
            handleOrganizationError(error, directory: directory)
            OrganizerServices.captureWorkflow(
                workflow: "organize",
                stage: "plan_generation",
                outcome: "failed",
                properties: OrganizerServices.durationProperties(
                    Date().timeIntervalSince(analyticsStartedAt)
                )
            )
            OrganizerServices.capture(
                error: error,
                feature: "organize",
                operation: "generate_plan",
                requestContext: diagnosticConfig.map { AIRequestDiagnosticContext(config: $0, fileCount: diagnosticFileCount) }
            )
            throw error
        }
    }

    // MARK: - Organization Phases

    func scanPhase(directory: URL) async throws -> [FileItem] {
        let usesDeepScan = (aiConfig?.enableDeepScan ?? false)
            && (aiConfig?.provider.supportsDeepScan ?? true)
        let scanStagePrefix = usesDeepScan
            ? "Scanning and analyzing file content"
            : "Fast Mode: scanning file names and folder context"
        updateState(.scanning, stage: "\(scanStagePrefix)...", progress: 0.05)

        try checkCancellation()

        // Set up deep scan progress reporting
        await scanner.setDeepScanProgressCallback { [weak self] current, _ in
            guard current == 1 || current.isMultiple(of: 25) else { return }
            Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled, !self.isCancellationRequested else { return }
                self.deepScanProgress = (current: current, total: 0)
                self.organizationStage = "Analyzing file content: \(current) files..."
            }
        }
        await scanner.setScanProgressCallback { [weak self] current in
            // Throttle per-file callbacks to avoid spawning a Task per file.
            guard current == 1 || current.isMultiple(of: 25) else { return }
            Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled, !self.isCancellationRequested else { return }
                self.scannedFileCount = current
                self.organizationStage =
                    "\(scanStagePrefix): \(GenerationStats.formatCount(current)) files found..."
            }
        }

        if let keywords = aiConfig?.customOCRKeywords {
            await scanner.setCustomOCRKeywords(keywords)
        }
        await scanner.setOCRLanguages(aiConfig?.ocrLanguages ?? ["en-US"])

        let exclusionMatcher = exclusionRules?.matcherSnapshot()
        blockingExclusionRule = exclusionRules?.blockingRule(forDirectoryAt: directory)
        let filesFound: [FileItem]
        do {
            filesFound = try await scanner.scanDirectory(
                at: directory,
                deepScan: usesDeepScan,
                deepScanFileLimit: Self.deepScanFileLimit,
                exclusionMatcher: exclusionMatcher
            )
        } catch {
            await scanner.setScanProgressCallback(nil)
            await scanner.setDeepScanProgressCallback(nil)
            throw error
        }
        await scanner.setScanProgressCallback(nil)
        await scanner.setDeepScanProgressCallback(nil)
        scannedFileCount = filesFound.count
        setScannedFiles(filesFound)

        deepScanProgress = nil

        // Check if scan was degraded due to memory pressure
        if await scanner.lastScanWasDegraded, let reason = await scanner.degradationReason {
            updateProgress(0.12, stage: "⚠️ \(reason)")
            try? await Task.sleep(for: .seconds(1.5))
        }

        let scanResult = exclusionMatcher?.isEmpty == false
            ? "Found \(filesFound.count) files after exclusions"
            : "Found \(filesFound.count) files"
        let scanResultStage = usesDeepScan
            ? "\(scanResult); content is ready for analysis"
            : "Fast Mode: \(scanResult.lowercased())"
        updateProgress(0.20, stage: scanResultStage)

        try checkCancellation()

        return filesFound
    }

    private func duplicateDetectionPhase(files: [FileItem]) async throws -> ([FileItem], String) {
        guard aiConfig?.detectDuplicates ?? false else {
            detectedDuplicates = []
            return (files, "")
        }

        updateProgress(0.21, stage: "Checking for duplicates...")

        let detector = DuplicateDetector()
        let result = await detector.findExactDuplicates(in: files) { [weak self] completed, total in
            guard let self, total > 0 else { return }
            self.updateProgress(
                0.21,
                stage: "Checking \(completed.formatted()) of \(total.formatted()) duplicate candidates..."
            )
        }
        try checkCancellation()
        let duplicates = result.groups
        await MainActor.run {
            self.detectedDuplicates = duplicates
        }

        return (files, PromptContextHelper.duplicateContext(from: duplicates))
    }

    private func aiAnalysisPhase(
        files: [FileItem],
        directory: URL,
        customPrompt: String?,
        temperature: Double?,
        duplicateContext: String
    ) async throws -> (OrganizationPlan, String, String?, [String: Data]) {
        updateState(.organizing, stage: "Connecting to AI provider...", progress: 0.22)
        await MainActor.run {
            isStreaming = false
            measuredWorkProgress = nil
            aiAnalysisActivity = .requesting
        }

        // Power assertion covers the network-bound AI wait only.
        let analysisActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Requesting organization plan"
        )
        defer { ProcessInfo.processInfo.endActivity(analysisActivity) }

        startTimeoutTimer()

        try checkCancellation()

        let personaPrompt = effectivePersonaPrompt()

        let directInstructions = customPrompt ?? customInstructions
        var instructions = PromptBuilder.wrapDirectUserInstructions(directInstructions)
        if let referenceContext = try await fileReferenceContext(from: directInstructions, files: files) {
            instructions += "\n\n" + referenceContext
        }
        if !duplicateContext.isEmpty {
            instructions += duplicateContext
        }

        let isRenameOnly = aiConfig?.mode == .renameOnly
        instructions += exclusionInstructions(forRenameOnly: isRenameOnly)

        if let learnedContext = learningsManager?.generatePromptContext(forFolder: directory.path), !learnedContext.isEmpty {
            instructions += "\n\n" + learnedContext
            ModelLog.debug("Injected Learnings context into prompt")
        }

        if !isRenameOnly,
           let modelDirContext = learningsManager?.generateModelDirectoryContext(for: files),
           !modelDirContext.isEmpty {
            instructions += "\n\n" + modelDirContext
            ModelLog.debug("Injected Model Directory reference context into prompt")
        }

        if !isRenameOnly,
           let directoryManifest = try await PromptBuilder.buildDirectoryManifestContextOffMain(
               baseDirectoryURL: directory,
               files: files
           ) {
            instructions += "\n\n" + directoryManifest
            ModelLog.debug("Injected source folder context into prompt")
        }

        if !isRenameOnly, let storageContext = await storageLocationsManager?.generatePromptContext(), !storageContext.isEmpty {
            let sourceDir = StorageLocationPathResolver.canonicalPath(directory.path)
            let enabledLocations = storageLocationsManager?.enabledLocations ?? []

            var sourceDirClause = """
            11. The source directory you are organizing is: "\(sourceDir)".
                CRITICAL: The source directory and storage locations are completely separate filesystem locations.
                To route a file to storage, copy the EXACT path from VALID_STORAGE_PATHS or KNOWN_STORAGE_SUBFOLDERS.
                Do NOT build storage paths by appending folder names to the source directory.
                Non-storage destinations must use short relative names (no leading /).
            """

            if let firstLocation = enabledLocations.first {
                let storagePath = StorageLocationPathResolver.canonicalPath(firstLocation.path)
                let storageName = URL(fileURLWithPath: storagePath).lastPathComponent
                sourceDirClause += """

                ✗ WRONG: "\(sourceDir)/\(storageName)" — this is inside the source, NOT a storage location.
                ✓ RIGHT: "\(storagePath)" — copy the exact path from VALID_STORAGE_PATHS.
                """
            }

            instructions += "\n\n" + storageContext + "\n" + sourceDirClause
            ModelLog.debug("Injected Storage Locations context into prompt")
        }

        if !isRenameOnly,
           let existingFoldersContext = try await PromptBuilder.buildExistingFoldersContextOffMain(at: directory) {
            instructions += "\n\n" + existingFoldersContext
            ModelLog.debug("Injected Existing Folders context into prompt")
        }

        let imagePayload: [String: Data] = [:]

        let visionEnabled = aiConfig?.enableVision ?? false
        let currentModel = aiConfig?.model ?? ""
        let currentProvider = aiConfig?.provider ?? .openAICompatible
        let modelSupportsVision = OrganizerServices.visionSupportChecker(currentModel, currentProvider)
        let shouldLimitVisionImages = aiConfig?.limitVisionImages ?? true
        let configuredBatchSize = max(1, aiConfig?.visionBatchSize ?? 12)
        let visionSelectionLimit: Int
        if shouldLimitVisionImages {
            visionSelectionLimit = configuredBatchSize
        } else if files.count > 10_000 {
            visionSelectionLimit = 100
        } else {
            visionSelectionLimit = files.count
        }
        let visionSelection = visionEnabled
            ? boundedVisionSelection(
                from: files,
                batchSize: visionSelectionLimit,
                strategy: aiConfig?.visionBatchStrategy ?? .noText,
                fileBatchSize: shouldLimitVisionImages
                    ? (isRenameOnly ? Self.renameAnalysisBatchSize : Self.organizeAnalysisBatchSize)
                    : nil
            )
            : (selected: [], total: 0)

        if visionSelection.total > 0 && modelSupportsVision {
            let selectedBatch = visionSelection.selected
            let totalImageCount = visionSelection.total
            preparedVisionAttachmentNames.removeAll(keepingCapacity: true)
            visionPreparationFailureCount = 0
            visionPreparationByteLimitSkipCount = 0
            visionAnalysisSummary = VisionAnalysisSummary(
                analyzedCount: 0,
                totalImageCount: totalImageCount,
                skippedCount: max(0, totalImageCount - selectedBatch.count),
                failedCount: 0,
                warningMessage: nil
            )
        } else if visionSelection.total > 0 && !modelSupportsVision {
            let warning = "Vision is enabled but \(currentProvider.displayName) (\(currentModel)) doesn't support multimodal analysis. Results will use text-only analysis."
            visionAnalysisSummary = VisionAnalysisSummary(
                analyzedCount: 0,
                totalImageCount: visionSelection.total,
                skippedCount: visionSelection.total,
                failedCount: 0,
                warningMessage: warning
            )
            ModelLog.debug(warning)
        } else {
            visionAnalysisSummary = nil
        }

        guard let client = aiClient else {
            throw OrganizationError.clientNotConfigured
        }

        let plan = try await analyzeInBoundedBatches(
            files: files,
            client: client,
            imagePayload: imagePayload,
            visionFiles: modelSupportsVision ? visionSelection.selected : [],
            instructions: instructions,
            personaPrompt: personaPrompt,
            temperature: temperature,
            directory: directory
        )

        try checkCancellation()

        stopTimeoutTimer()

        return (plan, instructions, personaPrompt, imagePayload)
    }

    func analyzeInBoundedBatches(
        files: [FileItem],
        client: AIClientProtocol,
        imagePayload: [String: Data],
        visionFiles: [FileItem] = [],
        instructions: String,
        personaPrompt: String?,
        temperature: Double?,
        modeOverride: OrganizationMode? = nil,
        directory: URL? = nil,
        resuming checkpoint: OrganizationResumeCheckpoint? = nil
    ) async throws -> OrganizationPlan {
        let mode = checkpoint?.mode ?? modeOverride ?? aiConfig?.mode ?? client.config.mode
        let resolvedDirectory = checkpoint?.directory ?? directory ?? currentDirectory
        var completeInstructions = checkpoint?.instructions ?? instructions
        if mode != .renameOnly,
           !completeInstructions.contains("## SOURCE FOLDER CONTEXT"),
           let resolvedDirectory,
           let manifest = try await PromptBuilder.buildDirectoryManifestContextOffMain(
               baseDirectoryURL: resolvedDirectory,
               files: files
           ) {
            completeInstructions += "\n\n" + manifest
        }
        if mode == .renameOnly,
           !completeInstructions.contains("## FINDER-TAGGED FOLDERS IN SCOPE"),
           let resolvedDirectory,
           let finderTagContext = PromptBuilder.buildFinderTaggedFolderContext(
               baseDirectoryURL: resolvedDirectory,
               files: files
           ) {
            completeInstructions += "\n\n" + finderTagContext
        }
        let batchSize = mode == .organize
            ? Self.organizeAnalysisBatchSize
            : Self.renameAnalysisBatchSize
        let batchCount = max(1, (files.count + batchSize - 1) / batchSize)

        aiAnalysisActivity = .requesting

        let analysisStart = Date()
        let accumulator = LargeFolderPlanAccumulator()
        var taxonomy: [String] = []
        var retainedNotes: [String] = []
        var totalResponseTokens = 0
        var totalPromptTokens = 0
        var hasPromptTokenCount = false
        var firstTTFT: TimeInterval?
        var estimatedCost = Decimal.zero
        var hasEstimatedCost = false
        var completedAnalysisBatchCount = 0
        var completedPlans = checkpoint?.completedPlans ?? []

        for completedPlan in completedPlans {
            taxonomy = await accumulator.merge(completedPlan)
            if let stats = completedPlan.generationStats {
                totalResponseTokens += stats.totalTokens
                if let promptTokens = stats.promptTokens {
                    totalPromptTokens += promptTokens
                    hasPromptTokenCount = true
                }
                if firstTTFT == nil {
                    firstTTFT = stats.ttft
                }
                if let cost = stats.estimatedCost {
                    estimatedCost += cost
                    hasEstimatedCost = true
                }
            }
            completedAnalysisBatchCount += 1
        }

        if let resolvedDirectory {
            resumeCheckpoint = OrganizationResumeCheckpoint(
                files: files,
                directory: resolvedDirectory,
                instructions: completeInstructions,
                personaPrompt: personaPrompt,
                imagePayload: imagePayload,
                visionFiles: visionFiles,
                temperature: temperature,
                mode: mode,
                completedPlans: completedPlans,
                nextBatchIndex: checkpoint?.nextBatchIndex ?? 0
            )
        }

        // Bounded concurrency: up to analysisBatchConcurrency batches in
        // flight. Requests execute concurrently off the main actor while
        // merges stay ordered through the accumulator, so the merged plan,
        // taxonomy, progress, and resume checkpoint match serial order.
        // Merged batches accumulate in completedPlans as they land; when a
        // batch ultimately fails, the group aborts but those good batches
        // stay cached in the resume checkpoint, and the halve-and-retry
        // inside requestBatchPlans retries only the failed batch.
        let startBatchIndex = checkpoint?.nextBatchIndex ?? 0
        startTimeoutTimer()
        defer {
            batchStreamChannels.removeAll()
            visibleBatchStreamIndex = nil
            isStreaming = false
            if batchCount == 1 {
                var baseClient = client
                baseClient.streamingDelegate = self
            }
        }
        // Throwing-group scope exit cancels stragglers on failure; merged
        // batches are already cached in the resume checkpoint above.
        try await withThrowingTaskGroup(of: (Int, [OrganizationPlan]).self) { group in
            var nextDispatch = startBatchIndex
            var nextMerge = startBatchIndex
            var bufferedPlans: [Int: [OrganizationPlan]] = [:]

            while nextMerge < batchCount {
                try checkCancellation()
                while nextDispatch < batchCount,
                      nextDispatch - nextMerge < Self.analysisBatchConcurrency {
                    let batchIndex = nextDispatch
                    let start = batchIndex * batchSize
                    let end = min(start + batchSize, files.count)
                    let job = try await makeBatchAnalysisJob(
                        batchIndex: batchIndex,
                        batch: Array(files[start..<end]),
                        batchCount: batchCount,
                        baseClient: client,
                        mode: mode,
                        completeInstructions: completeInstructions,
                        taxonomySnapshot: taxonomy,
                        imagePayload: imagePayload,
                        visionFiles: visionFiles,
                        visionBaseDirectory: resolvedDirectory,
                        personaPrompt: personaPrompt,
                        temperature: temperature
                    )
                    nextDispatch += 1
                    let phaseProgress = 0.30 + (Double(batchIndex) / Double(batchCount)) * 0.52
                    let suggestionAction = mode == .renameOnly ? "Finding better names" : "Finding the best folders"
                    updateMeasuredProgress(
                        completed: batchIndex,
                        total: batchCount,
                        estimatedOverallProgress: phaseProgress,
                        stage: batchCount > 1
                            ? "\(suggestionAction) for \(GenerationStats.formatCount(end)) of \(GenerationStats.formatCount(files.count)) files..."
                            : "\(suggestionAction) for \(GenerationStats.formatCount(files.count)) files..."
                    )
                    group.addTask {
                        let plans = try await Self.requestBatchPlans(job: job)
                        return (job.batchIndex, plans)
                    }
                }

                guard let (completedIndex, plans) = try await group.next() else { break }
                try checkCancellation()
                bufferedPlans[completedIndex] = plans
                while let ready = bufferedPlans.removeValue(forKey: nextMerge) {
                    try checkCancellation()
                    completedAnalysisBatchCount += ready.count
                    for batchPlan in ready {
                        if let stats = batchPlan.generationStats {
                            totalResponseTokens += stats.totalTokens
                            if let promptTokens = stats.promptTokens {
                                totalPromptTokens += promptTokens
                                hasPromptTokenCount = true
                            }
                            if firstTTFT == nil {
                                firstTTFT = stats.ttft
                            }
                            if let cost = stats.estimatedCost {
                                estimatedCost += cost
                                hasEstimatedCost = true
                            }
                        }
                        let note = batchPlan.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !note.isEmpty, retainedNotes.count < 3, !retainedNotes.contains(note) {
                            retainedNotes.append(note)
                        }
                        taxonomy = await accumulator.merge(batchPlan)
                    }
                    completedPlans.append(contentsOf: ready)
                    resumeCheckpoint?.completedPlans = completedPlans
                    resumeCheckpoint?.nextBatchIndex = nextMerge + 1

                    let completed = nextMerge + 1
                    let completedEnd = min(completed * batchSize, files.count)
                    let completedProgress = 0.30 + (Double(completed) / Double(batchCount)) * 0.52
                    updateMeasuredProgress(
                        completed: completed,
                        total: batchCount,
                        estimatedOverallProgress: completedProgress,
                        stage: "Found suggestions for \(GenerationStats.formatCount(completedEnd)) of \(GenerationStats.formatCount(files.count)) files"
                    )
                    nextMerge += 1
                    batchStreamChannels.removeValue(forKey: nextMerge - 1)
                    if visibleBatchStreamIndex == nextMerge - 1 {
                        visibleBatchStreamIndex = batchStreamChannels[nextMerge] == nil ? nil : nextMerge
                        batchStreamChannels[nextMerge]?.present()
                    }
                }
            }
        }
        var mergedPlan = await accumulator.result()
        let duration = Date().timeIntervalSince(analysisStart)
        let totalFileSize = await Task.detached(priority: .utility) {
            files.reduce(Int64.zero) { partial, file in
                let (sum, overflow) = partial.addingReportingOverflow(file.size)
                return overflow ? Int64.max : sum
            }
        }.value
        let model = client.config.model
        let provider = client.config.provider.displayName
        let summary = batchCount > 1
            ? "Analyzed \(GenerationStats.formatCount(files.count)) files across \(completedAnalysisBatchCount) AI requests."
            : "Analyzed \(GenerationStats.formatCount(files.count)) files."
        mergedPlan.notes = ([summary] + retainedNotes).joined(separator: " ")
        mergedPlan.generationStats = GenerationStats(
            duration: duration,
            tps: duration > 0 ? Double(totalResponseTokens) / duration : 0,
            ttft: firstTTFT ?? 0,
            totalTokens: totalResponseTokens,
            model: model,
            filesScanned: files.count,
            totalFileSize: totalFileSize,
            promptTokens: hasPromptTokenCount ? totalPromptTokens : nil,
            provider: provider,
            estimatedCost: hasEstimatedCost ? estimatedCost : nil
        )
        clearMeasuredProgress(
            estimatedOverallProgress: 0.84,
            stage: mode == .renameOnly ? "Checking name suggestions..." : "Checking organization plan..."
        )
        return mergedPlan
    }

    public func resumeOrganization() async throws {
        guard let checkpoint = resumeCheckpoint,
              let client = aiClient else {
            throw OrganizationError.noCurrentPlan
        }
        guard let runToken = claimOrganizeRun() else {
            ModelLog.debug("Resume blocked: another run is already in progress")
            return
        }
        defer { releaseOrganizeRun(runToken) }

        cancelInternal(preservingToken: runToken)
        isCancellationRequested = false
        clearStreamingDisplayState()
        updateState(
            .organizing,
            stage: "Continuing \(checkpoint.mode.displayName)...",
            progress: 0.30
        )

        currentTask = Task {
            let plan = try await analyzeInBoundedBatches(
                files: checkpoint.files,
                client: client,
                imagePayload: checkpoint.imagePayload,
                visionFiles: checkpoint.visionFiles,
                instructions: checkpoint.instructions,
                personaPrompt: checkpoint.personaPrompt,
                temperature: checkpoint.temperature,
                modeOverride: checkpoint.mode,
                directory: checkpoint.directory,
                resuming: checkpoint
            )
            let validatedPlan = try await validationPhase(
                plan: plan,
                files: checkpoint.files,
                directory: checkpoint.directory,
                instructions: checkpoint.instructions,
                personaPrompt: checkpoint.personaPrompt,
                temperature: checkpoint.temperature,
                imagePayload: checkpoint.imagePayload
            )
            handleLearningToolCall(
                from: validatedPlan,
                source: .manual,
                folderPath: checkpoint.directory.path
            )
            currentPlan = validatedPlan
            resumeCheckpoint = nil
            updateState(.ready, stage: "Ready!", progress: 1.0)
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
            stopTimeoutTimer()
            resetToIdleUnlessCancellationResetIsSuppressed()
            throw CancellationError()
        } catch {
            guard isCurrentOrganizeRun(runToken) else { throw error }
            stopTimeoutTimer()
            handleOrganizationError(error, directory: checkpoint.directory)
            throw error
        }
    }

    nonisolated static func isTimeoutFailure(_ error: Error) -> Bool {
        if let clientError = error as? AIClientError,
           case .networkError(let underlyingError) = clientError {
            let underlyingNSError = underlyingError as NSError
            if underlyingNSError.domain == NSURLErrorDomain,
               underlyingNSError.code == NSURLErrorTimedOut {
                return true
            }
        }
        let description = error.localizedDescription.lowercased()
        if description.contains("timeout") || description.contains("timed out") {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }
}
