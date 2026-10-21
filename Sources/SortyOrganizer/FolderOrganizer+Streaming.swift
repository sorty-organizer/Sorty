import Foundation
import SwiftUI
import Combine
import SortyLearnings
import SortyFileSystem
import SortyModels
import SortyAI
import SortyFS

// MARK: - StreamingDelegate
extension FolderOrganizer {
    struct StreamPresentationPayload: Sendable {
        let fullContent: String
        let truncatedContent: String
    }

    nonisolated private static func makeStreamPresentationPayload(from content: String) -> StreamPresentationPayload {
        // Walk only the displayed suffix, rather than counting the entire response
        // before walking it again. String indices preserve composed characters.
        let fullStart = content.index(
            content.endIndex,
            offsetBy: -streamUIPresentationCharacterLimit,
            limitedBy: content.startIndex
        ) ?? content.startIndex
        let fullContent = String(content[fullStart...])
        let previewStart = content.index(
            content.endIndex,
            offsetBy: -streamPreviewCharacterLimit,
            limitedBy: content.startIndex
        ) ?? content.startIndex
        let truncatedContent = (previewStart == content.startIndex ? "" : "...")
            + String(content[previewStart...])
        return StreamPresentationPayload(
            fullContent: fullContent,
            truncatedContent: truncatedContent
        )
    }

    @MainActor
    private func appendRetainedStreamChunk(_ chunk: String) {
        streamingContent += chunk
        retainedStreamingByteCount += chunk.utf8.count
        streamingContentRevision &+= 1
        let trimThreshold = Self.streamRetentionByteLimit + Self.streamRetentionTrimByteSlack
        if retainedStreamingByteCount > trimThreshold {
            streamingContent = Self.retainingUTF8Suffix(
                of: streamingContent,
                maximumByteCount: Self.streamRetentionByteLimit
            )
            retainedStreamingByteCount = streamingContent.utf8.count
        }
    }

    nonisolated static func retainingUTF8Suffix(
        of content: String,
        maximumByteCount: Int
    ) -> String {
        guard content.utf8.count > maximumByteCount else { return content }
        var suffix = content.utf8.suffix(maximumByteCount)
        while let first = suffix.first, first & 0b1100_0000 == 0b1000_0000 {
            suffix = suffix.dropFirst()
        }
        return String(decoding: suffix, as: UTF8.self)
    }

    nonisolated static func retainedStreamCompletion(_ content: String) -> String {
        retainingUTF8Suffix(of: content, maximumByteCount: streamRetentionByteLimit)
    }

    @MainActor
    func scheduleDisplayUpdate(for contentSnapshot: String, force: Bool = false) {
        guard liveInsightsEnabled else { return }

        let now = Date()
        if !force && now.timeIntervalSince(lastDisplayUpdate) < displayUpdateInterval {
            return
        }
        lastDisplayUpdate = now

        let estimatedTotal = estimatedStreamingCharacterTarget()
        // Progress is capped at 80%; characters beyond the target cannot change it.
        let contentLength = progress < 0.80 ? contentSnapshot.prefix(estimatedTotal).count : estimatedTotal
        let expectedRevision = streamingContentRevision

        displayUpdateTask?.cancel()
        displayUpdateTask = Task { @MainActor [weak self] in
            let payload = Self.makeStreamPresentationPayload(from: contentSnapshot)
            guard let self, !Task.isCancelled, !self.isCancellationRequested else { return }
            guard self.streamingContentRevision >= expectedRevision else { return }

            self.withBatchUpdates {
                self.displayStreamingContent = payload.fullContent
                self.truncatedDisplayStreamingContent = payload.truncatedContent
                self.updateProgressFromStreamLength(contentLength, estimatedTotal: estimatedTotal)
            }
        }
    }

    @MainActor
    private func updateProgressFromStreamLength(_ contentLength: Int, estimatedTotal: Int? = nil) {
        let target = estimatedTotal ?? estimatedStreamingCharacterTarget()
        let contentProgress = min(0.80, 0.30 + (Double(contentLength) / Double(target)) * 0.50)
        if progress < contentProgress {
            progress = contentProgress
        }
    }

    @MainActor
    private func syncDisplayContentImmediately() {
        let payload = Self.makeStreamPresentationPayload(from: streamingContent)
        displayStreamingContent = payload.fullContent
        truncatedDisplayStreamingContent = payload.truncatedContent
    }

    @MainActor
    func clearStreamingDisplayState() {
        displayUpdateTask?.cancel()
        displayUpdateTask = nil
        insightExtractionTask?.cancel()
        insightExtractionTask = nil
        streamingContent = ""
        retainedStreamingByteCount = 0
        streamingContentRevision &+= 1
        displayStreamingContent = ""
        truncatedDisplayStreamingContent = ""
        lastDisplayUpdate = .distantPast
        lastInsightExtraction = .distantPast
        insightsCache = nil
        progressLineBuffer = ""
        discardsCurrentProgressLine = false
        receivedProgressLines = false
        jsonStartedInStream = false
        progressLineCount = 0
    }

    private var analysisStageDescription: String {
        switch aiConfig?.mode {
        case .renameOnly:
            return "Sorty is preparing rename suggestions..."
        case .organizeAndRename:
            return "Sorty is organizing and renaming your files..."
        case .organize, nil:
            return "Sorty is organizing your files..."
        }
    }

    @MainActor
    func restartPlanGenerationForRetry() {
        clearStreamingDisplayState()
        withBatchUpdates {
            isStreaming = false
            progress = 0.30
            organizationStage = analysisStageDescription
        }
        startTimeoutTimer()
    }

    public func didReceiveChunk(_ chunk: String) {
        guard !isCancellationRequested else { return }

        // If a prior stream already completed, treat this as a brand-new stream session.
        if !isStreaming, !streamingContent.isEmpty {
            clearStreamingDisplayState()
        }
            
        let isFirstChunk = streamingContent.isEmpty
        appendRetainedStreamChunk(chunk)

        if isFirstChunk {
            // Batch all initial state updates together
            withBatchUpdates {
                isStreaming = true
                organizationStage = analysisStageDescription
                progress = 0.30
                if liveInsightsEnabled {
                    syncDisplayContentImmediately()
                }
            }
        }

        if liveInsightsEnabled {
            // Try to extract progress lines from the stream before JSON starts
            if !jsonStartedInStream {
                processProgressLines(from: chunk)
            }

            // Throttle UI-impacting updates to prevent layout thrashing and main actor congestion
            scheduleDisplayUpdate(for: streamingContent)

            // Fall back to regex extractor only if no progress lines were received
            if !receivedProgressLines {
                extractInsightsIfNeeded()
            }
        } else {
            let now = Date()
            if now.timeIntervalSince(lastDisplayUpdate) >= displayUpdateInterval {
                lastDisplayUpdate = now
                if progress < 0.80 {
                    let target = estimatedStreamingCharacterTarget()
                    updateProgressFromStreamLength(streamingContent.prefix(target).count, estimatedTotal: target)
                }
            }
        }
    }
    
    // MARK: - Progress Line Parsing
    
    /// Parse progress lines (>> category: text) from streaming chunks
    @MainActor
    private func processProgressLines(from chunk: String) {
        for fragment in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            if fragment.contains("{") {
                progressLineBuffer = ""
                discardsCurrentProgressLine = true
                jsonStartedInStream = true
                return
            }

            appendProgressLineFragment(fragment)
            guard fragment.endIndex != chunk.endIndex else { continue }
            finishProgressLine()
        }
    }

    @MainActor
    private func appendProgressLineFragment(_ fragment: Substring) {
        guard !discardsCurrentProgressLine else { return }

        var remainder = fragment
        if progressLineBuffer.isEmpty {
            remainder = remainder.drop(while: { $0.isWhitespace })
        }

        if progressLineBuffer.count < 3 {
            let prefixRemainder = remainder.prefix(3 - progressLineBuffer.count)
            progressLineBuffer.append(contentsOf: prefixRemainder)
            remainder = remainder.dropFirst(prefixRemainder.count)
            guard ">> ".hasPrefix(progressLineBuffer) else {
                progressLineBuffer = ""
                discardsCurrentProgressLine = true
                return
            }
        }

        let maximumProgressLineLength = 16 * 1024
        guard progressLineBuffer.count + remainder.count <= maximumProgressLineLength else {
            progressLineBuffer = ""
            discardsCurrentProgressLine = true
            return
        }
        progressLineBuffer.append(contentsOf: remainder)
    }

    @MainActor
    private func finishProgressLine() {
        defer {
            progressLineBuffer = ""
            discardsCurrentProgressLine = false
        }
        guard !discardsCurrentProgressLine else { return }

        let line = progressLineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix(">> "), progressLineCount < progressLineLimit else { return }

        let content = String(line.dropFirst(3))
        guard let insight = parseProgressLine(content) else { return }

        progressLineCount += 1
        receivedProgressLines = true

        withBatchUpdates {
            currentInsight = insight.text
            if let existingIndex = insightHistory.firstIndex(where: { $0.id == insight.id }) {
                insightHistory.remove(at: existingIndex)
            }
            if insightHistory.count >= progressLineLimit {
                insightHistory.removeFirst()
            }
            insightHistory.append(insight)
        }
        insightsCache = nil
    }

    /// Rebuild insight timeline from the already-buffered stream text.
    /// Used when users re-enable Live Insights during an active generation.
    @MainActor
    private func rebuildInsightsFromStreamingSnapshot() {
        let snapshot = streamingContent
        guard !snapshot.isEmpty else {
            withBatchUpdates {
                currentInsight = ""
                insightHistory = []
            }
            progressLineBuffer = ""
            discardsCurrentProgressLine = false
            receivedProgressLines = false
            jsonStartedInStream = false
            progressLineCount = 0
            return
        }

        let rawLines = snapshot.components(separatedBy: .newlines)
        var rebuiltInsights: [AIInsight] = []
        var sawJSON = false
        var trailingPartialBuffer = ""

        for (index, rawLine) in rawLines.enumerated() {
            let isLastLine = index == rawLines.count - 1
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedLine.contains("{") {
                sawJSON = true
                trailingPartialBuffer = ""
                break
            }

            if isLastLine, !snapshot.hasSuffix("\n") {
                trailingPartialBuffer = rawLine
            }

            guard !trimmedLine.isEmpty else { continue }
            guard trimmedLine.hasPrefix(">> "), rebuiltInsights.count < progressLineLimit else { continue }

            let lineContent = String(trimmedLine.dropFirst(3))
            guard let insight = parseProgressLine(lineContent) else { continue }

            if let existingIndex = rebuiltInsights.firstIndex(where: { $0.id == insight.id }) {
                rebuiltInsights.remove(at: existingIndex)
            }
            rebuiltInsights.append(insight)
        }

        progressLineBuffer = ""
        discardsCurrentProgressLine = false
        if !sawJSON {
            appendProgressLineFragment(trailingPartialBuffer[...])
        }
        receivedProgressLines = !rebuiltInsights.isEmpty
        jsonStartedInStream = sawJSON
        progressLineCount = rebuiltInsights.count

        withBatchUpdates {
            currentInsight = rebuiltInsights.last?.text ?? ""
            insightHistory = rebuiltInsights
        }
    }
    
    /// Parse a progress line like "file: Assigning invoice.pdf to Finances" into an AIInsight
    private func parseProgressLine(_ content: String) -> AIInsight? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5 else { return nil }
        
        var category: AIInsight.Category = .general
        var text = trimmed
        
        // Try to extract "category: text" format
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let prefix = String(trimmed[trimmed.startIndex..<colonIndex])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let remainder = String(trimmed[trimmed.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)
            
            switch prefix {
            case "file", "folder", "pattern", "decision", "constraint", "general":
                switch prefix {
                case "file": category = .file
                case "folder": category = .folder
                case "pattern": category = .pattern
                case "decision": category = .decision
                case "constraint": category = .constraint
                default: category = .general
                }
                guard !remainder.isEmpty else { return nil }
                text = remainder
            default:
                category = .general
            }
        }

        if let destination = Self.extractAssignmentDestination(from: text),
           !Self.isLikelyLiveFolderName(destination) {
            return nil
        }
        if category == .file && Self.isLowSignalFileProgressInsight(text) {
            return nil
        }
        let clipped = String(text.prefix(120))
        let resolvedFilePath = (category == .file) ? resolveScannedFilePathForMention(in: text) : nil
        return AIInsight(text: clipped, category: category, filePath: resolvedFilePath, stableSeed: text)
    }

    private func resolveScannedFilePathForMention(in text: String) -> String? {
        guard let fileName = Self.extractMentionedFileName(from: text) else { return nil }
        return Self.resolveScannedFilePath(
            for: fileName,
            scannedFilePathLookup: scannedFilePathLookup,
            currentDirectoryPath: currentDirectory?.path
        )
    }

    nonisolated private static func extractMentionedFileName(from text: String) -> String? {
        if let quotedRegex = quotedFileMentionRegex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = quotedRegex.matches(in: text, options: [], range: range)
            for match in matches.reversed() {
                guard let fileRange = Range(match.range(at: 1), in: text) else { continue }
                let fileName = normalizeCandidateFileName(String(text[fileRange]))
                if isLikelyFileName(fileName) {
                    return URL(fileURLWithPath: fileName).lastPathComponent
                }
            }
        }

        if let bareRegex = bareFileMentionRegex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = bareRegex.matches(in: text, options: [], range: range)
            for match in matches.reversed() {
                guard let fileRange = Range(match.range(at: 1), in: text) else { continue }
                let fileName = normalizeCandidateFileName(String(text[fileRange]))
                if isLikelyFileName(fileName) {
                    return URL(fileURLWithPath: fileName).lastPathComponent
                }
            }
        }

        return nil
    }

    nonisolated private static func resolveScannedFilePath(
        for fileName: String,
        scannedFilePathLookup: [String: [String]],
        currentDirectoryPath: String?
    ) -> String? {
        let key = fileName.lowercased()
        guard let matches = scannedFilePathLookup[key], !matches.isEmpty else { return nil }

        if matches.count == 1 {
            return matches[0]
        }

        if let currentDirectoryPath {
            let preferred = matches.filter { $0.hasPrefix(currentDirectoryPath + "/") }
            if preferred.count == 1 { return preferred[0] }
        }
        return nil
    }

    nonisolated private static func normalizeFolderName(_ input: String) -> String {
        input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?"))
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    nonisolated private static func isLikelyLiveFolderName(_ input: String) -> Bool {
        let candidate = normalizeFolderName(input)
        guard candidate.count >= 2, candidate.count <= 80 else { return false }
        guard !candidate.contains("{"), !candidate.contains("}"), !candidate.contains("\"") else { return false }
        guard !candidate.contains("/"), !candidate.contains("\\") else { return false }
        guard URL(fileURLWithPath: candidate).pathExtension.isEmpty else { return false }

        let lower = candidate.lowercased()
        guard !blockedLiveFolderNames.contains(lower) else { return false }
        guard !lower.contains("top-level"),
              !lower.contains("top level"),
              !lower.contains("preferred"),
              !lower.contains("constraint"),
              !lower.contains("response format"),
              !lower.contains("system prompt") else {
            return false
        }
        return true
    }

    nonisolated private static func normalizeCandidateFileName(_ input: String) -> String {
        input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}"))
    }

    nonisolated private static func isLikelyFileName(_ input: String) -> Bool {
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.count <= 220 else { return false }
        let ext = URL(fileURLWithPath: candidate).pathExtension
        return !ext.isEmpty
    }

    nonisolated private static func isLowSignalFileProgressInsight(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return true }

        if lowered.contains("response format") || lowered.contains("json schema") || lowered.contains("system prompt") {
            return true
        }

        if let destination = extractAssignmentDestination(from: text),
           !isLikelyLiveFolderName(destination) {
            return true
        }

        return false
    }

    nonisolated private static func extractAssignmentDestination(from text: String) -> String? {
        guard let regex = assignmentDestinationRegex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let destinationRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let destination = normalizeFolderName(String(text[destinationRange]))
        return destination.isEmpty ? nil : destination
    }

    /// Extract meaningful insights from the streaming AI response
    /// This is throttled and uses caching to avoid performance impact
    func extractInsightsIfNeeded(force: Bool = false) {
        guard liveInsightsEnabled else { return }

        let now = Date()
        if !force {
            guard now.timeIntervalSince(lastInsightExtraction) >= insightExtractionInterval else { return }
        }
        lastInsightExtraction = now
        
        // Get the last portion of content for analysis
        let content = streamingContent
        guard content.index(content.startIndex, offsetBy: 21, limitedBy: content.endIndex) != nil else { return }
        
        // Check cache first
        let contentRevision = streamingContentRevision
        let contentByteCount = retainedStreamingByteCount
        if let cache = insightsCache,
           cache.streamingContentRevision == contentRevision,
           cache.retainedStreamingByteCount == contentByteCount,
           cache.isValid {
            // Use cached insights
            withBatchUpdates {
                self.currentInsight = cache.currentInsight
                self.insightHistory = cache.insights
            }
            return
        }

        let fileLookup = scannedFilePathLookup
        let currentDirectoryPath = currentDirectory?.path

        insightExtractionTask?.cancel()
        insightExtractionTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let insight = await self.insightExtractor.extractInsight(
                from: content,
                scannedFilePathLookup: fileLookup,
                currentDirectoryPath: currentDirectoryPath
            )

            guard !Task.isCancelled,
                  self.liveInsightsEnabled,
                  let insight,
                  insight.text != self.currentInsight else { return }

            self.withBatchUpdates {
                self.currentInsight = insight.text
                if let existingIndex = self.insightHistory.firstIndex(where: { $0.id == insight.id }) {
                    self.insightHistory.remove(at: existingIndex)
                }
                if self.insightHistory.count >= self.progressLineLimit {
                    self.insightHistory.removeFirst()
                }
                self.insightHistory.append(insight)
            }

            self.insightsCache = InsightsCache(
                streamingContentRevision: contentRevision,
                retainedStreamingByteCount: contentByteCount,
                insights: self.insightHistory,
                currentInsight: insight.text,
                timestamp: Date()
            )
        }
    }
    
    @MainActor
    public func setLiveInsightsEnabled(_ enabled: Bool) {
        guard liveInsightsEnabled != enabled else { return }
        liveInsightsEnabled = enabled

        if enabled {
            if !streamingContent.isEmpty {
                rebuildInsightsFromStreamingSnapshot()
                syncDisplayContentImmediately()
                scheduleDisplayUpdate(for: streamingContent, force: true)
                if !receivedProgressLines {
                    extractInsightsIfNeeded(force: true)
                }
            }
            return
        }

        displayUpdateTask?.cancel()
        displayUpdateTask = nil
        displayStreamingContent = ""
        truncatedDisplayStreamingContent = ""

        insightExtractionTask?.cancel()
        insightExtractionTask = nil
        lastInsightExtraction = .distantPast
        insightsCache = nil
    }
    
    private func estimatedStreamingCharacterTarget() -> Int {
        let fileCount = max(1, scannedFileCount)
        let provider = aiConfig?.provider

        let base = 1200
        let perFile = min(220, max(70, 80 + Int(log2(Double(fileCount) + 1.0) * 14)))
        let complexityBoost = min(2500, fileCount * 18)

        let providerMultiplier: Double
        switch provider {
        case .anthropic:
            providerMultiplier = 1.15
        case .ollama, .openAICompatible:
            providerMultiplier = 1.05
        default:
            providerMultiplier = 1.0
        }

        let estimated = Int(Double(base + (fileCount * perFile) + complexityBoost) * providerMultiplier)
        return min(24_000, max(2_000, estimated))
    }
    
    func setScannedFiles(_ files: [FileItem]) {
        // Publish only a bounded slice for UI, but keep the full list and
        // lookup for insights, thumbnails, and streaming resolution
        // (deep scan up to 2000).
        allScannedFiles = files
        scannedFiles = Array(files.prefix(scannedFilesUIPublishLimit))
        scannedFilePathLookup = Dictionary(grouping: files, by: { $0.displayName.lowercased() })
            .mapValues { $0.map { $0.path } }
    }
    
    public func didComplete(content: String) {
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The provider returns the parsed plan separately. Keep only a bounded
            // diagnostic tail so streaming, UI, and history do not duplicate an
            // arbitrarily large response.
            streamingContent = Self.retainedStreamCompletion(content)
            retainedStreamingByteCount = streamingContent.utf8.count
            streamingContentRevision &+= 1
            if liveInsightsEnabled {
                syncDisplayContentImmediately()
            }
        }
        isStreaming = false
        organizationStage = aiConfig?.mode == .renameOnly ? "Building rename preview..." : "Building organization plan..."
        stopTimeoutTimer()
    }

    public func didFail(error: Error) {
        isStreaming = false
        errorMessage = userFacingErrorMessage(for: error)
        stopTimeoutTimer()

        // Request user attention for streaming failure
        OrganizerServices.attentionRequester()
    }

    // MARK: - Timeout Timer

    func startTimeoutTimer() {
        startTime = Date()
        elapsedTime = 0
        showTimeoutMessage = false

        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            while let self = self, !Task.isCancelled, !self.isCancellationRequested {
                // 10 s granularity: elapsed-time display and the 30 s
                // timeout banner do not need a 2 s main-actor wakeup.
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled || self.isCancellationRequested { break }

                if let start = self.startTime {
                    self.elapsedTime = Date().timeIntervalSince(start)

                    if self.elapsedTime >= 30 && !self.showTimeoutMessage {
                        self.showTimeoutMessage = true
                    }
                }
            }
        }
    }

    func stopTimeoutTimer() {
        timeoutTask?.cancel()
        timeoutTask = nil
        startTime = nil
    }
}
