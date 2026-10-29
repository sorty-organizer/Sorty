import Foundation
import SwiftUI
import Combine
import SortyLearnings
import SortyFileSystem
import SortyModels
import SortyAI
import SortyFS

extension FolderOrganizer {
    /// Each concurrent request owns its stream and 1-based file IDs. Only the
    /// earliest pending batch publishes into the organizer's visible stream.
    @MainActor
    final class BatchStreamChannel: StreamingDelegate {
        private weak var organizer: FolderOrganizer?
        private let batchIndex: Int
        private var files: [FileItem] = []
        private var content = ""
        private var hasStarted = false
        private var isComplete = false

        init(organizer: FolderOrganizer, batchIndex: Int) {
            self.organizer = organizer
            self.batchIndex = batchIndex
        }

        func beginRequest(files: [FileItem]) {
            if hasStarted {
                content = ""
                isComplete = false
                if organizer?.visibleBatchStreamIndex == batchIndex {
                    organizer?.clearStreamingDisplayState()
                }
            }
            hasStarted = true
            self.files = files
            if organizer?.visibleBatchStreamIndex == batchIndex {
                publishFileIDs()
            }
        }

        func didReceiveChunk(_ chunk: String) {
            content = FolderOrganizer.retainingUTF8Suffix(
                of: content + chunk,
                maximumByteCount: FolderOrganizer.streamRetentionByteLimit
            )
            if organizer?.visibleBatchStreamIndex == batchIndex {
                organizer?.didReceiveChunk(chunk)
            }
        }

        func didComplete(content: String) {
            self.content = FolderOrganizer.retainedStreamCompletion(content)
            isComplete = true
            if organizer?.visibleBatchStreamIndex == batchIndex {
                present()
            }
        }

        func didFail(error: Error) {
            // The batch task decides whether to retry or surface this error.
        }

        func present() {
            guard let organizer else { return }
            organizer.clearStreamingDisplayState()
            publishFileIDs()
            if !content.isEmpty {
                organizer.didReceiveChunk(content)
            }
            if isComplete {
                organizer.isStreaming = false
            }
        }

        private func publishFileIDs() {
            organizer?.streamFileIDTable = Dictionary(
                uniqueKeysWithValues: files.enumerated().map { ($0.offset + 1, $0.element) }
            )
        }
    }

    /// Sendable unit of AI batch work. Built on the main actor (prompt
    /// slicing, taxonomy snapshot, vision prep) and executed concurrently off
    /// it, so TaskGroup children never capture the organizer.
    struct BatchAnalysisJob: Sendable {
        let batchIndex: Int
        let client: AIClientProtocol
        let streamChannel: BatchStreamChannel
        var files: [FileItem]
        var batchImages: [String: Data]
        var requestInstructions: String
        let personaPrompt: String?
        let temperature: Double?
        /// Main-actor cancellation flag sampled at dispatch; Task.isCancelled
        /// covers task-tree cancellation.
        let cancellationRequested: Bool
        /// Vision-capable files for the whole run plus the base directory, so
        /// an adaptive split half that ends up without attachments can still
        /// prepare its own images.
        let visionFiles: [FileItem]
        let reprepareImages: (@Sendable ([FileItem]) async throws -> [String: Data])?
    }

    /// Builds one batch job: stream ID table, batch-scoped instructions with
    /// a taxonomy snapshot, and vision payload. Runs on the main actor at
    /// dispatch time; the returned job is self-contained for concurrent
    /// execution. The taxonomy snapshot may lag already-dispatched batches by
    /// up to (concurrency - 1); the merge stays strictly ordered.
    func makeBatchAnalysisJob(
        batchIndex: Int,
        batch: [FileItem],
        batchCount: Int,
        baseClient: AIClientProtocol,
        mode: OrganizationMode,
        completeInstructions: String,
        taxonomySnapshot: [String],
        imagePayload: [String: Data],
        visionFiles: [FileItem],
        visionBaseDirectory: URL?,
        personaPrompt: String?,
        temperature: Double?
    ) async throws -> BatchAnalysisJob {
        try checkCancellation()

        var batchClient: AIClientProtocol
        if batchCount == 1 {
            batchClient = baseClient
        } else {
            #if DEBUG
            if let batchClientFactoryForTesting {
                batchClient = try await batchClientFactoryForTesting(baseClient.config, batchIndex)
            } else {
                batchClient = try await AIClientFactory.createClientDetached(config: baseClient.config)
            }
            #else
            batchClient = try await AIClientFactory.createClientDetached(config: baseClient.config)
            #endif
        }
        let streamChannel = BatchStreamChannel(organizer: self, batchIndex: batchIndex)
        batchClient.streamingDelegate = streamChannel
        batchStreamChannels[batchIndex] = streamChannel
        if visibleBatchStreamIndex == nil {
            visibleBatchStreamIndex = batchIndex
        }

        var batchInstructions = completeInstructions
        if batchCount > 1 {
            // Avoid repeating the full 400-entry manifest on every 350-file
            // batch: replace it with a small batch-scoped manifest.
            if let visionBaseDirectory,
               batchInstructions.contains("## SOURCE FOLDER CONTEXT") {
                batchInstructions = PromptBuilder.strippingSourceFolderContext(from: batchInstructions)
                // Build the 60-entry batch manifest off-main because it reads
                // directory resource values.
                if let batchManifest = try await PromptBuilder.buildDirectoryManifestContextOffMain(
                    baseDirectoryURL: visionBaseDirectory,
                    files: batch,
                    maxEntries: 60
                ) {
                    batchInstructions += "\n\n" + batchManifest
                }
            }
            batchInstructions += Self.largeFolderBatchContext(
                batchIndex: batchIndex,
                batchCount: batchCount,
                taxonomy: taxonomySnapshot,
                mode: mode
            )
        }

        let fileNames = Set(batch.map { Self.visionAttachmentName(for: $0) })
        var batchImages = Self.visionImages(in: imagePayload, keyedBy: batch)
        if batchImages.isEmpty, let visionBaseDirectory {
            let selectedFiles = visionFiles.filter {
                fileNames.contains(Self.visionAttachmentName(for: $0))
            }
            batchImages = try await prepareVisionPayload(
                for: selectedFiles,
                baseDirectory: visionBaseDirectory
            )
        }
        let requestInstructions = Self.requestInstructions(
            base: batchInstructions,
            visionImages: batchImages
        )

        let reprepareImages: (@Sendable ([FileItem]) async throws -> [String: Data])? =
            visionBaseDirectory.map { baseDirectory in
                { @Sendable [weak self] files in
                    guard let self else { return [:] }
                    return try await self.prepareVisionPayload(for: files, baseDirectory: baseDirectory)
                }
            }

        return BatchAnalysisJob(
            batchIndex: batchIndex,
            client: batchClient,
            streamChannel: streamChannel,
            files: batch,
            batchImages: batchImages,
            requestInstructions: requestInstructions,
            personaPrompt: personaPrompt,
            temperature: temperature,
            cancellationRequested: isCancellationRequested,
            visionFiles: visionFiles,
            reprepareImages: reprepareImages
        )
    }

    /// Executes one batch job against the AI client, halve-and-retrying only
    /// that batch on splittable failures. Runs off the main actor; UI state
    /// is never touched here (the merge loop owns progress and taxonomy).
    nonisolated static func requestBatchPlans(
        job: BatchAnalysisJob,
        adaptiveDepth: Int = 0
    ) async throws -> [OrganizationPlan] {
        // Cap halve-and-retry recursion so a persistently failing batch cannot
        // recurse without bound; depth 9 lets a 350-file batch reach one file.
        let maxAdaptiveDepth = 9
        if job.cancellationRequested || Task.isCancelled {
            throw CancellationError()
        }

        let requestID = UUID()
        let context = AIRequestDiagnosticContext(
            config: job.client.config, fileCount: job.files.count, attachmentCount: job.batchImages.count
        )
        let startedAt = ProcessInfo.processInfo.systemUptime
        await OrganizerServices.recordRequest(
            id: requestID, context: context, outcome: .started,
            batch: job.batchIndex, adaptiveDepth: adaptiveDepth, elapsed: 0
        )

        do {
            await job.streamChannel.beginRequest(files: job.files)
            if job.batchImages.isEmpty {
                let plan = try await job.client.analyze(
                    files: job.files,
                    customInstructions: job.requestInstructions,
                    personaPrompt: job.personaPrompt,
                    temperature: job.temperature
                )
                await OrganizerServices.recordRequest(
                    id: requestID, context: context, outcome: .succeeded, batch: job.batchIndex,
                    adaptiveDepth: adaptiveDepth, elapsed: ProcessInfo.processInfo.systemUptime - startedAt
                )
                return [plan]
            }
            let plan = try await job.client.analyzeWithImages(
                files: job.files,
                imageData: job.batchImages,
                customInstructions: job.requestInstructions,
                personaPrompt: job.personaPrompt,
                temperature: job.temperature
            )
            await OrganizerServices.recordRequest(
                id: requestID, context: context, outcome: .succeeded, batch: job.batchIndex,
                adaptiveDepth: adaptiveDepth, elapsed: ProcessInfo.processInfo.systemUptime - startedAt
            )
            return [plan]
        } catch {
            if job.cancellationRequested || Task.isCancelled {
                throw CancellationError()
            }
            if Self.isCancellationError(error) { throw error }
            let willSplit = adaptiveDepth < maxAdaptiveDepth &&
                Self.shouldSplitAnalysisBatch(after: error, fileCount: job.files.count)
            await OrganizerServices.recordRequest(
                id: requestID, context: context, outcome: willSplit ? .splitRetry : .failed,
                batch: job.batchIndex, adaptiveDepth: adaptiveDepth,
                elapsed: ProcessInfo.processInfo.systemUptime - startedAt, error: error
            )
            guard willSplit else {
                throw error
            }

            let splitIndex = job.files.count / 2
            let retryMessage = "Retrying a failed \(job.files.count)-file AI request as separate requests for \(splitIndex) and \(job.files.count - splitIndex) files."
            Task { @MainActor in
                OrganizerServices.log(retryMessage, level: .warning, category: "FolderOrganizer")
            }
            // The parent request's vision context claims the parent batch's
            // attachments; strip it and rebuild per half so each prompt lists
            // exactly the images that request sends.
            let recoveryInstructions = Self.strippingVisionContext(from: job.requestInstructions) + """

            ADAPTIVE RETRY
            - The previous larger request could not produce a complete valid plan.
            - Return a complete plan for only the files in this smaller request.
            """
            var firstJob = job
            firstJob.files = Array(job.files[..<splitIndex])
            // Each half must only re-upload the parent batch's images that
            // belong to its own files, not the entire parent payload. PDF
            // page attachments decorate the base name with " [Page N]".
            firstJob.batchImages = Self.visionImages(in: job.batchImages, keyedBy: firstJob.files)
            if firstJob.batchImages.isEmpty, let reprepareImages = job.reprepareImages {
                firstJob.batchImages = try await reprepareImages(
                    Self.visionFiles(in: job.visionFiles, matching: firstJob.files)
                )
            }
            firstJob.requestInstructions = Self.requestInstructions(
                base: recoveryInstructions,
                visionImages: firstJob.batchImages
            )
            var secondJob = job
            secondJob.files = Array(job.files[splitIndex...])
            secondJob.batchImages = Self.visionImages(in: job.batchImages, keyedBy: secondJob.files)
            if secondJob.batchImages.isEmpty, let reprepareImages = job.reprepareImages {
                secondJob.batchImages = try await reprepareImages(
                    Self.visionFiles(in: job.visionFiles, matching: secondJob.files)
                )
            }
            secondJob.requestInstructions = Self.requestInstructions(
                base: recoveryInstructions,
                visionImages: secondJob.batchImages
            )
            // Halves stay sequential so their plans concatenate in order.
            let firstPlans = try await requestBatchPlans(job: firstJob, adaptiveDepth: adaptiveDepth + 1)
            let secondPlans = try await requestBatchPlans(job: secondJob, adaptiveDepth: adaptiveDepth + 1)
            return firstPlans + secondPlans
        }
    }

    nonisolated private static func shouldSplitAnalysisBatch(
        after error: Error,
        fileCount: Int
    ) -> Bool {
        guard fileCount > 1 else { return false }

        if let clientError = error as? AIClientError {
            switch clientError {
            case .invalidResponseFormat, .jsonDecodingError:
                return fileCount > minimumAdaptiveAnalysisBatchSize
            case .apiError(let statusCode, let message):
                if statusCode == 413 {
                    return true
                }
                let description = message.lowercased()
                return description.contains("output limit") ||
                    description.contains("context length") ||
                    description.contains("maximum context") ||
                    description.contains("max_tokens") ||
                    description.contains("too many tokens")
            default:
                break
            }
        }

        let description = error.localizedDescription.lowercased()
        return description.contains("output limit") ||
            description.contains("context length") ||
            description.contains("maximum context") ||
            description.contains("too many tokens")
    }

    nonisolated private static func largeFolderBatchContext(
        batchIndex: Int,
        batchCount: Int,
        taxonomy: [String],
        mode: OrganizationMode
    ) -> String {
        let taxonomyContext: String
        if mode == .renameOnly || taxonomy.isEmpty {
            taxonomyContext = ""
        } else {
            taxonomyContext = """

            Reuse these destination paths from earlier batches whenever they fit:
            \(taxonomy.map { "- \($0)" }.joined(separator: "\n"))
            """
        }

        return """

        LARGE FOLDER BATCH \(batchIndex + 1) OF \(batchCount)
        - This request contains a complete, disjoint batch from one larger folder.
        - File IDs are local to this batch. Include every file in this batch exactly once.
        - Keep decisions consistent across batches and do not invent wrapper folders just because this is a batch.
        - Reuse the same nested folder structure across batches; never alternate between "Parent/Child" and a Parent folder containing Child.
        \(taxonomyContext)
        """
    }

    nonisolated static func mergeLargeFolderBatch(
        _ incomingPlan: OrganizationPlan,
        into accumulatedPlan: inout OrganizationPlan
    ) {
        let incoming = normalizingDestinationHierarchy(
            in: removingDuplicateAssignments(from: incomingPlan)
        )
        mergeSuggestions(incoming.suggestions, into: &accumulatedPlan.suggestions)
        accumulatedPlan.unorganizedFiles.append(contentsOf: incoming.unorganizedFiles)
        accumulatedPlan.unorganizedDetails.append(contentsOf: incoming.unorganizedDetails)
        if accumulatedPlan.learningToolCall == nil {
            accumulatedPlan.learningToolCall = incoming.learningToolCall
        }
    }

    nonisolated static func normalizingDestinationHierarchy(
        in plan: OrganizationPlan
    ) -> OrganizationPlan {
        var normalized = plan
        normalized.suggestions = []
        mergeSuggestions(plan.suggestions, into: &normalized.suggestions)
        return normalized
    }

    nonisolated private static func removingDuplicateAssignments(
        from plan: OrganizationPlan
    ) -> OrganizationPlan {
        var updated = plan
        var claimedFileIDs: Set<UUID> = []

        func prune(_ folder: FolderSuggestion) -> FolderSuggestion {
            var result = folder
            result.files = folder.files.filter { claimedFileIDs.insert($0.id).inserted }
            let retainedIDs = Set(result.files.map(\.id))
            result.fileRenameMappings = folder.fileRenameMappings.filter {
                retainedIDs.contains($0.originalFile.id)
            }
            result.fileTagMappings = folder.fileTagMappings.filter {
                retainedIDs.contains($0.originalFile.id)
            }
            result.subfolders = folder.subfolders.map(prune)
            return result
        }

        updated.suggestions = plan.suggestions.map(prune)
        updated.unorganizedFiles = plan.unorganizedFiles.filter {
            claimedFileIDs.insert($0.id).inserted
        }
        let unorganizedNames = Set(updated.unorganizedFiles.map(\.displayName))
        updated.unorganizedDetails = plan.unorganizedDetails.filter {
            unorganizedNames.contains($0.filename)
        }
        return updated
    }

    nonisolated static func mergeSuggestions(
        _ incoming: [FolderSuggestion],
        into existing: inout [FolderSuggestion]
    ) {
        var existingIndexByKey = Dictionary(
            existing.enumerated().map {
                (normalizedDestinationKey($0.element.folderName), $0.offset)
            },
            uniquingKeysWith: { first, _ in first }
        )

        for rawSuggestion in incoming {
            let suggestion = hierarchizedSuggestion(rawSuggestion)
            let key = normalizedDestinationKey(suggestion.folderName)
            if let index = existingIndexByKey[key] {
                existing[index] = mergeFolderSuggestion(suggestion, into: existing[index])
            } else {
                existingIndexByKey[key] = existing.count
                existing.append(suggestion)
            }
        }
    }

    nonisolated private static func hierarchizedSuggestion(
        _ suggestion: FolderSuggestion
    ) -> FolderSuggestion {
        var recursivelyNormalized = suggestion
        recursivelyNormalized.subfolders = []
        mergeSuggestions(suggestion.subfolders, into: &recursivelyNormalized.subfolders)
        guard !suggestion.folderName.hasPrefix("/") else {
            return recursivelyNormalized
        }

        let components = suggestion.folderName
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        guard components.count > 1, let leafName = components.last else {
            return recursivelyNormalized
        }

        var nested = recursivelyNormalized
        nested.folderName = leafName
        for component in components.dropLast().reversed() {
            nested = FolderSuggestion(
                folderName: component,
                subfolders: [nested]
            )
        }
        return nested
    }

    nonisolated private static func mergeFolderSuggestion(
        _ incoming: FolderSuggestion,
        into existing: FolderSuggestion
    ) -> FolderSuggestion {
        var merged = existing
        var fileIDs = Set(existing.files.map(\.id))
        merged.files.append(contentsOf: incoming.files.filter { fileIDs.insert($0.id).inserted })
        merged.fileRenameMappings = Dictionary(
            (existing.fileRenameMappings + incoming.fileRenameMappings).map { ($0.originalFile.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.originalFile.id.uuidString < $1.originalFile.id.uuidString }
        merged.fileTagMappings = Dictionary(
            (existing.fileTagMappings + incoming.fileTagMappings).map { ($0.originalFile.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.originalFile.id.uuidString < $1.originalFile.id.uuidString }
        merged.tags = Array(Set(existing.tags).union(incoming.tags)).sorted()
        merged.semanticTags = Array(Set(existing.semanticTags).union(incoming.semanticTags)).sorted()
        if merged.description.isEmpty {
            merged.description = incoming.description
        }
        if merged.reasoning.isEmpty {
            merged.reasoning = incoming.reasoning
        }
        if merged.comment == nil {
            merged.comment = incoming.comment
        }
        if merged.confidenceScore == nil {
            merged.confidenceScore = incoming.confidenceScore
        }
        if merged.ruleId == nil {
            merged.ruleId = incoming.ruleId
        }
        mergeSuggestions(incoming.subfolders, into: &merged.subfolders)
        return merged
    }

    nonisolated private static func normalizedDestinationKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    nonisolated static func destinationTaxonomy(
        in plan: OrganizationPlan,
        limit: Int
    ) -> [String] {
        var result: [String] = []

        func collect(_ folders: [FolderSuggestion], parent: String?) {
            for folder in folders where result.count < limit {
                let path: String
                if folder.folderName.hasPrefix("/") || parent == nil || parent?.isEmpty == true {
                    path = folder.folderName
                } else {
                    path = "\(parent!)/\(folder.folderName)"
                }
                result.append(String(path.prefix(180)))
                collect(folder.subfolders, parent: path)
            }
        }

        collect(plan.suggestions, parent: nil)
        return result
    }
}
