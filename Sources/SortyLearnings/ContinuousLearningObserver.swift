//
//  ContinuousLearningObserver.swift
//  Sorty
//
//  Watches for user actions that contradict or refine AI decisions:
//  1. Manual Moves (Correction)
//  2. Deletions/Re-organization (Rejection)
//  3. History Reverts
//  4. User Instructions (Additional and Guiding)
//  5. Steering Prompts (Post-organization instructions)
//  6. Session Linking (Correlate all behaviors to AI sessions)
//
//  Enhanced with consent checking - no data collected without opt-in
//

import Foundation
import Combine
import SortyFileSystem
import SortyModels

@MainActor
public class ContinuousLearningObserver: ObservableObject {
    private var learningsManager: LearningsManager
    private let history: OrganizationHistory

    private var cancellables = Set<AnyCancellable>()
    private var recentlyMovedFiles: [String: Date] = [:] // Path -> Time
    private var learningExcludedRunPaths: Set<String> = []

    /// Revert notifications parked while the learnings profile was unavailable
    /// (file or Keychain outage). Replayed once it loads so session-based
    /// attribution is not lost.
    private var pendingReverts: [(entry: OrganizationHistoryEntry, reason: String?)] = []

    /// Known groups of related project files that should stay together
    static let relatedFileGroups: [[String]] = [
        ["package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb"],
        ["Gemfile", "Gemfile.lock"],
        ["Cargo.toml", "Cargo.lock"],
        ["go.mod", "go.sum"],
        ["Pipfile", "Pipfile.lock"],
        [".gitignore", ".gitattributes"],
        ["Podfile", "Podfile.lock"],
        ["composer.json", "composer.lock"],
        ["pubspec.yaml", "pubspec.lock"],
        ["CMakeLists.txt", "CMakeCache.txt"],
        ["Makefile", "Makefile.am"],
        ["tsconfig.json", "tsconfig.build.json"],
        [".eslintrc", ".eslintrc.json", ".eslintrc.js"],
        [".prettierrc", ".prettierrc.json", ".prettierrc.js"],
    ]
    
    /// Current active session (started when organization is applied)
    @Published public private(set) var currentSession: OrganizationSession?
    
    /// Published pending learning moment for the UI to pick up
    @Published public var pendingLearningMoment: InlineLearningMoment?
    
    /// Recent sessions for correlation (last 24 hours)
    private var recentSessions: [OrganizationSession] = []

    /// Sessions ended by `endSession()` whose `.organizationDidFinish`
    /// notification has not been consumed yet. Notifications are delivered on
    /// the main queue in the same order runs end, so the oldest unclaimed
    /// session for a folder is the run that just reported.
    private var unclaimedFinishedSessionIDs: [String] = []
    
    /// Observation window for correlating user changes with AI sessions (default 30 minutes)
    public var correlationWindowMinutes: Double = 30
    
    /// Quick access to consent status
    private var canCollect: Bool {
        learningsManager.consentManager.canCollectData && !learningsManager.sessionLearningPaused
    }
    
    public init(learningsManager: LearningsManager, history: OrganizationHistory) {
        self.learningsManager = learningsManager
        self.history = history
    }

    public func startObserving() {
        NotificationCenter.default.publisher(for: .organizationDidRevert)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleRevertNotification(notification)
            }
            .store(in: &cancellables)
            
        NotificationCenter.default.publisher(for: .organizationDidFinish)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleFinishNotification(notification)
            }
            .store(in: &cancellables)
        
        // Listen for steering prompts
        NotificationCenter.default.publisher(for: .steeringPromptProvided)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleSteeringPrompt(notification)
            }
            .store(in: &cancellables)

        // Retry reverts parked while the learnings profile was unavailable as
        // soon as it loads, so persisted sessions can be resolved.
        learningsManager.$currentProfile
            .receive(on: DispatchQueue.main)
            .sink { [weak self] profile in
                guard profile != nil else { return }
                self?.replayPendingReverts()
            }
            .store(in: &cancellables)
        
        // Clean up old sessions periodically
        cleanupOldSessions()
    }
    
    /// Start a new organization session (called when organization is applied)
    public func startSession(
        folderPath: String,
        historyEntryId: String?,
        operations: [FileOperation]? = nil,
        learningExcluded: Bool = false
    ) {
        guard canCollect else { return }

        let normalizedFolderPath = standardizedPath(folderPath)
        if learningExcluded {
            excludeCurrentRun(folderPath: folderPath)
            return
        }
        learningExcludedRunPaths.remove(normalizedFolderPath)

        if var session = currentSession,
           URL(fileURLWithPath: session.folderPath).standardizedFileURL.path == URL(fileURLWithPath: folderPath).standardizedFileURL.path,
           session.reaction == .inProgress,
           session.completedAt == nil,
           historyEntryId == nil || session.historyEntryId == nil || session.historyEntryId == historyEntryId {
            if let historyEntryId {
                session.historyEntryId = historyEntryId
            }
            if let operations {
                applyOperations(operations, to: &session)
            }
            persistSessionUpdate(session)
            return
        }

        var session = OrganizationSession(
            folderPath: folderPath,
            historyEntryId: historyEntryId,
            events: [
                OrganizationSessionEvent(
                    kind: .started,
                    summary: "Started organization run for \(URL(fileURLWithPath: folderPath).lastPathComponent)"
                )
            ]
        )

        if let operations {
            applyOperations(operations, to: &session)
        }

        persistSessionUpdate(session, appendIfNeeded: true)
        ModelLog.log("Started learning session \(session.id)", level: .debug, category: "LearningObserver")
    }
    
    /// Record that a specific rule was applied to a file
    public nonisolated func recordRuleApplication(destinationPath: String, ruleId: String) {
        Task { @MainActor in
            guard canCollect, var session = currentSession else { return }
            
            session.appliedRules[destinationPath] = ruleId
            session.usedRuleIds.insert(ruleId)
            if let fileIndex = session.filesMoved.firstIndex(where: { $0.destinationPath == destinationPath }) {
                session.filesMoved[fileIndex].ruleId = ruleId
            }
            self.persistSessionUpdate(session)
        }
    }
    
    /// End the current session and leave it open for the correlation window.
    public func endSession() {
        // A claim whose run never reported (or reported long ago) must not
        // linger and swallow a later run's finish notification.
        pruneUnclaimedFinishedSessions()
        if var session = currentSession {
            session.completedAt = Date()
            session.events.append(
                OrganizationSessionEvent(
                    timestamp: session.completedAt ?? Date(),
                    kind: .completionPending,
                    summary: "Waiting for post-organization feedback"
                )
            )
            persistSessionUpdate(session)
            // The run's finish notification is delivered after this call; the
            // session stays unclaimed until that notification links it to its
            // history entry.
            if !unclaimedFinishedSessionIDs.contains(session.id) {
                unclaimedFinishedSessionIDs.append(session.id)
            }
            ModelLog.log("Ended learning session \(session.id)", level: .debug, category: "LearningObserver")
        }
    }
    
    // MARK: - Steering Prompts
    
    /// Track a steering prompt (post-organization instruction)
    public func trackSteeringPrompt(_ prompt: String, forFolder folderPath: String? = nil) {
        guard canCollect, !prompt.isEmpty else { return }
        if let folderPath, isRunExcluded(folderPath) { return }
        
        // Add to current session if active
        if var session = currentSession {
            session.steeringPrompts.append(prompt)
            session.events.append(
                OrganizationSessionEvent(
                    kind: .steeringPrompt,
                    summary: prompt
                )
            )
            persistSessionUpdate(session)
        }
        
        // Record as guiding instruction for future use
        learningsManager.recordGuidingInstruction(prompt)
        learningsManager.recordSteeringPrompt(prompt, folderPath: folderPath ?? currentSession?.folderPath, sessionId: currentSession?.id)
        
        ModelLog.log("Recorded steering prompt", level: .debug, category: "LearningObserver")
    }
    
    private func handleSteeringPrompt(_ notification: Notification) {
        guard let prompt = notification.userInfo?["prompt"] as? String else { return }
        let folderPath = notification.userInfo?["folderPath"] as? String

        if LearningsManager.instructionsExcludeCurrentRun(prompt) {
            if let folderPath {
                excludeCurrentRun(folderPath: folderPath)
            }
            ModelLog.log(
                "Excluded current run from learning",
                level: .info,
                category: "LearningObserver"
            )
            return
        }

        trackSteeringPrompt(prompt, forFolder: folderPath)
        
        if let exclusionPattern = parseExclusionFromPrompt(prompt) {
            Task {
                await learningsManager.addLearningExclusion(exclusionPattern)
                ModelLog.log("Added learning exclusion from steering prompt", level: .info, category: "LearningObserver")
            }
        }
    }
    
    public func parseExclusionFromPrompt(_ prompt: String) -> String? {
        let lowered = prompt.lowercased()
        let exclusionPhrases = [
            "don't learn from",
            "dont learn from",
            "skip learning for",
            "exclude from learning",
            "ignore for learning",
            "no learning for",
            "stop learning from"
        ]
        
        for phrase in exclusionPhrases {
            if lowered.contains(phrase) {
                if let range = lowered.range(of: phrase) {
                    let remainder = String(prompt[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let cleaned = remainder
                        .replacingOccurrences(of: "moves in ", with: "")
                        .replacingOccurrences(of: "my ", with: "")
                        .replacingOccurrences(of: " folder", with: "")
                        .replacingOccurrences(of: " directory", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    
                    if !cleaned.isEmpty {
                        return cleaned
                    }
                }
            }
        }
        return nil
    }
    
    private func cleanupOldSessions() {
        let cutoff = Date().addingTimeInterval(-86400) // 24 hours
        recentSessions = recentSessions.filter { $0.timestamp > cutoff }
        // Drop claims for sessions that fell out of the correlation window so
        // the queue cannot grow or claim an unrelated later run.
        let liveSessionIDs = Set(recentSessions.map(\.id))
        unclaimedFinishedSessionIDs.removeAll { !liveSessionIDs.contains($0) }
        pruneUnclaimedFinishedSessions()
    }

    /// Drops claims whose session disappeared, already linked to a history
    /// entry, or outlived the correlation window.
    private func pruneUnclaimedFinishedSessions(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-correlationWindowMinutes * 60)
        unclaimedFinishedSessionIDs.removeAll { id in
            guard let session = recentSessions.first(where: { $0.id == id }) else { return true }
            guard session.historyEntryId == nil else { return true }
            return (session.completedAt ?? session.timestamp) < cutoff
        }
    }

    public func excludeCurrentRun(folderPath: String) {
        let normalizedFolderPath = standardizedPath(folderPath)
        learningExcludedRunPaths.insert(normalizedFolderPath)

        guard let session = currentSession,
              standardizedPath(session.folderPath) == normalizedFolderPath else { return }

        currentSession = nil
        recentSessions.removeAll { $0.id == session.id }
        unclaimedFinishedSessionIDs.removeAll { $0 == session.id }
        learningsManager.discardOrganizationSession(id: session.id)
    }

    private func isRunExcluded(_ folderPath: String) -> Bool {
        learningExcludedRunPaths.contains(standardizedPath(folderPath))
    }

    private func isPathInExcludedRun(_ path: String) -> Bool {
        learningExcludedRunPaths.contains { excludedFolderPath in
            StorageLocationPathResolver.isPath(path, within: excludedFolderPath)
        }
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func persistSessionUpdate(_ session: OrganizationSession, appendIfNeeded: Bool = false) {
        currentSession = session
        if let index = recentSessions.firstIndex(where: { $0.id == session.id }) {
            recentSessions[index] = session
        } else if appendIfNeeded {
            // Multiple distinct organization runs can target the same folder.
            // Preserve each ID for history correlation and revert matching.
            recentSessions.append(session)
        }
        learningsManager.upsertOrganizationSession(session)
    }

    private func applyOperations(_ operations: [FileOperation], to session: inout OrganizationSession) {
        var movedFiles = session.filesMoved
        var updatedCount = 0
        for operation in operations {
            guard let destinationPath = operation.destinationPath else { continue }
            recentlyMovedFiles[destinationPath] = Date()
            let existingIndex = movedFiles.firstIndex { $0.destinationPath == destinationPath }
            let previousRuleID = existingIndex.map { movedFiles[$0].ruleId } ?? nil
            let movedFile = OrganizationSessionMovedFile(
                sourcePath: operation.sourcePath,
                destinationPath: destinationPath,
                ruleId: previousRuleID
            )
            if let existingIndex {
                movedFiles[existingIndex] = movedFile
            } else {
                movedFiles.append(movedFile)
            }
            updatedCount += 1
        }

        guard updatedCount > 0 else { return }
        session.filesMoved = movedFiles
        session.folderPatterns = extractFolderPatterns(from: movedFiles, rootFolderPath: session.folderPath)
        session.planSummary = summarizePlan(from: session.folderPatterns, fileCount: movedFiles.count)
        session.events.append(
            OrganizationSessionEvent(
                kind: .applied,
                summary: "Applied organization to \(updatedCount) files"
            )
        )
    }

    private func extractFolderPatterns(
        from files: [OrganizationSessionMovedFile],
        rootFolderPath: String
    ) -> [OrganizationSessionFolderPattern] {
        let rootURL = URL(fileURLWithPath: rootFolderPath)
        let grouped = Dictionary(grouping: files) { file in
            let folderURL = URL(fileURLWithPath: file.destinationFolderPath)
            let relative = folderURL.path.replacingOccurrences(of: rootURL.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? folderURL.lastPathComponent : relative
        }

        return grouped.map { relativePath, items in
            let folderName = relativePath.components(separatedBy: "/").last ?? rootURL.lastPathComponent
            let extensions = items.map { URL(fileURLWithPath: $0.sourcePath).pathExtension.lowercased() }.filter { !$0.isEmpty }
            let extensionCounts = Dictionary(grouping: extensions, by: { $0 }).mapValues(\.count)
            let topExtensions = extensionCounts.sorted { $0.value > $1.value }.prefix(3).map(\.key)
            let sampleNames = items.prefix(3).map(\.fileName)
            return OrganizationSessionFolderPattern(
                relativePath: relativePath.isEmpty ? folderName : relativePath,
                folderName: folderName,
                fileCount: items.count,
                fileExtensions: topExtensions,
                sampleFileNames: sampleNames
            )
        }
        .sorted { $0.fileCount > $1.fileCount }
    }

    private func summarizePlan(from patterns: [OrganizationSessionFolderPattern], fileCount: Int) -> String {
        let folderList = patterns.prefix(3).map(\.relativePath).joined(separator: ", ")
        guard !folderList.isEmpty else {
            return "\(fileCount) files organized"
        }
        return "\(fileCount) files organized into \(folderList)"
    }
    
    /// Find the most relevant session for a given path
    private func findRelevantSession(for path: String) -> OrganizationSession? {
        let cutoff = Date().addingTimeInterval(-correlationWindowMinutes * 60)
        
        // Find sessions that:
        // 1. Are within the correlation window
        // 2. Have a matching folder path (the file is within the session's folder)
        return recentSessions
            .filter { $0.timestamp > cutoff }
            .filter { StorageLocationPathResolver.isPath(path, within: $0.folderPath) }
            .sorted { $0.timestamp > $1.timestamp }
            .first
    }
    
    // MARK: - File Move Tracking
    
    /// Called by FolderWatcher delegate or FileSystemManager when a move occurs
    public func handleFileMove(from src: String, to dst: String) {
        Task { await handleFileMoveAsync(from: src, to: dst) }
    }

    private func handleFileMoveAsync(from src: String, to dst: String) async {
        guard canCollect else { return }
        guard !isPathInExcludedRun(src), !isPathInExcludedRun(dst) else { return }
        
        if learningsManager.isPathExcludedFromLearning(src) || learningsManager.isPathExcludedFromLearning(dst) {
            ModelLog.log("Skipped learning for an excluded path", level: .debug, category: "LearningObserver")
            return
        }
        
        // 1. Check if this file was recently organized by AI
        // Look back 24 hours (or configurable window)
        let recentEntries = history.entries.prefix(50) // Check last 50 sessions
        
        var foundMatch = false
        var matchedSession: OrganizationSession?
        
        // First try to find a relevant session
        matchedSession = findRelevantSession(for: src) ?? findRelevantSession(for: dst)
        
        for summary in recentEntries where summary.storedOperationCount > 0 {
            let entry = await history.details(for: summary)
            guard let operations = entry.operations else { continue }
            
            // Check if this file (src) was the DESTINATION of an AI move
            // i.e. AI moved X -> src.
            // Now User moves src -> dst.
            // This implies Correction: X -> dst is the better rule.
            
            if let aiOp = operations.first(where: { $0.destinationPath == src }) {
                // Found the AI action that put the file here
                ModelLog.log("Recorded a user correction to an AI placement", category: "LearningObserver")
                
                let change = DirectoryChange(
                    originalPath: src, 
                    newPath: dst, 
                    wasAIOrganized: true,
                    aiSessionId: matchedSession?.id ?? entry.id.uuidString
                )
                
                learningsManager.recordDirectoryChange(
                    from: src, 
                    to: dst, 
                    wasAIOrganized: true,
                    sessionId: change.aiSessionId
                )
                learningsManager.recordCorrection(originalPath: aiOp.sourcePath, newPath: dst)
                
                // Track correction in the session
                if var session = matchedSession {
                    session.userCorrections.append(change)
                    session.reaction = .corrected
                    session.timeToReaction = change.timestamp.timeIntervalSince(session.timestamp)
                    if let failedRuleId = session.appliedRules[src] {
                        let wasNewFailure = session.failedRuleIds.insert(failedRuleId).inserted
                        if wasNewFailure {
                            learningsManager.recordRuleFailure(ruleId: failedRuleId)
                        }
                    }
                    session.events.append(
                        OrganizationSessionEvent(
                            timestamp: change.timestamp,
                            kind: .correction,
                            summary: "User corrected an AI placement",
                            sourcePath: src,
                            destinationPath: dst,
                            ruleId: session.appliedRules[src]
                        )
                    )
                    persistSessionUpdate(session)
                }
                
                foundMatch = true
                break
            }
        }
        
        if !foundMatch {
            // General learning (even if not correcting specific AI action)
            // Just assume user likes files of this type in this destination
            learningsManager.addPositiveExample(srcPath: src, dstPath: dst)
            learningsManager.recordDirectoryChange(
                from: src, 
                to: dst, 
                wasAIOrganized: false,
                sessionId: matchedSession?.id
            )
            
            // Still track in session if within correlation window
            if var session = matchedSession {
                let change = DirectoryChange(
                    originalPath: src, 
                    newPath: dst, 
                    wasAIOrganized: false,
                    aiSessionId: session.id
                )
                session.userCorrections.append(change)
                session.reaction = .corrected
                session.timeToReaction = change.timestamp.timeIntervalSince(session.timestamp)
                session.events.append(
                    OrganizationSessionEvent(
                        timestamp: change.timestamp,
                        kind: .correction,
                        summary: "User manually moved a file after organization",
                        sourcePath: src,
                        destinationPath: dst
                    )
                )
                persistSessionUpdate(session)
            }
        }
    }

    /// Called when a file is removed from the monitored scope (moved outside or deleted)
    public func handleFileRemoval(at path: String) {
        Task { await handleFileRemovalAsync(at: path) }
    }

    private func handleFileRemovalAsync(at path: String) async {
        guard canCollect else { return }
        guard !isPathInExcludedRun(path) else { return }
        
        if learningsManager.isPathExcludedFromLearning(path) {
            ModelLog.log("Skipped learning for an excluded path", level: .debug, category: "LearningObserver")
            return
        }
        
        let recentEntries = history.entries.prefix(50)
        
        let matchedSession = findRelevantSession(for: path)
        var foundMatch = false
        
        for summary in recentEntries where summary.storedOperationCount > 0 {
            let entry = await history.details(for: summary)
            guard let operations = entry.operations else { continue }
            
            if let aiOp = operations.first(where: { $0.destinationPath == path }) {
                ModelLog.log("Recorded a removal after an AI placement", category: "LearningObserver")
                learningsManager.recordRejection(originalPath: aiOp.sourcePath)
                
                // Track in session if within correlation window
                if var session = matchedSession {
                    let change = DirectoryChange(
                        originalPath: path,
                        newPath: "",
                        wasAIOrganized: true,
                        aiSessionId: session.id
                    )
                    session.userCorrections.append(change)
                    session.reaction = .corrected
                    session.timeToReaction = change.timestamp.timeIntervalSince(session.timestamp)
                    if let failedRuleId = session.appliedRules[path] {
                        let wasNewFailure = session.failedRuleIds.insert(failedRuleId).inserted
                        if wasNewFailure {
                            learningsManager.recordRuleFailure(ruleId: failedRuleId)
                        }
                    }
                    session.events.append(
                        OrganizationSessionEvent(
                            timestamp: change.timestamp,
                            kind: .rejection,
                            summary: "User removed a file after organization",
                            sourcePath: path,
                            ruleId: session.appliedRules[path]
                        )
                    )
                    persistSessionUpdate(session)
                }
                
                foundMatch = true
                break
            }
        }
        
        if !foundMatch {
            learningsManager.recordRejection(originalPath: path)
        }
    }
    
    // MARK: - User Instructions Tracking
    
    /// Track when user provides additional instructions for organization
    public func trackAdditionalInstruction(_ instruction: String, forFolder folderPath: String) {
        guard canCollect else { return }
        if LearningsManager.instructionsExcludeCurrentRun(instruction) {
            excludeCurrentRun(folderPath: folderPath)
            return
        }
        guard !isRunExcluded(folderPath) else { return }
        
        learningsManager.recordAdditionalInstruction(instruction, for: folderPath)
        ModelLog.log("Recorded an additional instruction", level: .debug, category: "LearningObserver")
    }
    
    /// Track when user provides guiding instructions for next attempt
    public func trackGuidingInstruction(_ instruction: String) {
        guard canCollect else { return }
        if LearningsManager.instructionsExcludeCurrentRun(instruction) {
            if let folderPath = currentSession?.folderPath {
                excludeCurrentRun(folderPath: folderPath)
            }
            return
        }
        
        learningsManager.recordGuidingInstruction(instruction)
        ModelLog.log("Recorded guiding instruction", level: .debug, category: "LearningObserver")
    }
    
    // MARK: - History Revert Tracking
    
    private func handleRevertNotification(_ notification: Notification) {
        guard canCollect,
              let entry = notification.userInfo?["entry"] as? OrganizationHistoryEntry else { return }
        processRevert(entry: entry, reason: notification.userInfo?["reason"] as? String)
    }

    /// Records and attributes one revert. `isRetry` replays a notification that
    /// was parked while the profile was unavailable, where the revert event may
    /// already have been flushed from the manager's pending-write queue.
    private func processRevert(entry: OrganizationHistoryEntry, reason: String?, isRetry: Bool = false) {
        guard canCollect else { return }
        guard !isRunExcluded(entry.directoryPath) else { return }

        let entryID = entry.id.uuidString
        if !isRetry {
            // Repeated notifications for the same history item must not count
            // the revert as repeated negative evidence.
            let alreadyProcessed = learningsManager.hasRecordedOrPendingHistoryRevert(entryId: entryID)
                || recentSessions.contains { $0.historyEntryId == entryID && $0.wasReverted }
                || learningsManager.currentProfile?.sessions.contains { $0.historyEntryId == entryID && $0.wasReverted } == true
            guard !alreadyProcessed else { return }
        }

        ModelLog.log("Learning from a reverted session", category: "LearningObserver")

        // Record the revert event before any session lookup. The event is
        // evidence on its own: a backing-off profile must not drop it, and a
        // missing session must not keep it from being recorded.
        learningsManager.recordHistoryRevert(
            entryId: entryID,
            operationCount: entry.undoRestoredCount ?? entry.filesOrganized,
            folderPath: entry.directoryPath,
            revertReason: reason
        )

        // Attribution needs sessions and rules from the persisted profile. Park
        // the notification (the manager queues the event) and retry once the
        // profile loads, instead of recording a partial undo as a no-op.
        guard learningsManager.currentProfile != nil else {
            parkRevert(entry: entry, reason: reason)
            return
        }

        // Find and update the relevant session.
        let sessionIndex = recentSessions.firstIndex(where: { $0.historyEntryId == entryID })
        // In-memory sessions are gone after a relaunch; fall back to the
        // persisted session linked to this history entry so reverts of older
        // runs still produce rejections and rule failures.
        let persistedSession = sessionIndex == nil
            ? learningsManager.currentProfile?.sessions.first(where: { $0.historyEntryId == entryID })
            : nil

        // A clean undo clears the entry's stored operations; a partial undo
        // keeps only the operations that FAILED to restore. Those retained
        // move/rename operations are the not-reverted set, so the files the
        // user actually reverted are the session's recorded moves minus them.
        let failedMoveSourcePaths = Set(
            (entry.operations ?? [])
                .filter { $0.type == .moveFile || $0.type == .renameFile }
                .map(\.sourcePath)
        )
        let recordedSession = sessionIndex.map { recentSessions[$0] } ?? persistedSession
        let revertedMovedFiles = (recordedSession?.filesMoved ?? []).filter {
            !failedMoveSourcePaths.contains($0.sourcePath)
        }
        let rejectionSourcePaths = revertedMovedFiles.map(\.sourcePath)

        // Only rules that were applied to reverted files failed. Per-file rule
        // attribution exists on modern sessions; legacy sessions fall back to
        // their used rules, and only when files really were reverted.
        var newlyFailedRuleIDs: Set<String> = []
        if let session = recordedSession {
            let attributedRuleIDs = Set(revertedMovedFiles.compactMap { movedFile in
                movedFile.ruleId ?? session.appliedRules[movedFile.destinationPath]
            })
            if attributedRuleIDs.isEmpty {
                newlyFailedRuleIDs = session.filesMoved.isEmpty || !revertedMovedFiles.isEmpty
                    ? session.usedRuleIds
                    : []
            } else {
                newlyFailedRuleIDs = attributedRuleIDs
            }
            newlyFailedRuleIDs.subtract(session.failedRuleIds)
        }
        
        if let sessionIndex {
            var session = recentSessions[sessionIndex]
            session.wasReverted = true
            session.reaction = .reverted
            session.completedAt = Date()
            session.timeToReaction = Date().timeIntervalSince(session.timestamp)
            session.failedRuleIds.formUnion(newlyFailedRuleIDs)
            session.events.append(
                OrganizationSessionEvent(
                    kind: .reverted,
                    summary: reason ?? "Organization was reverted"
                )
            )
            recentSessions[sessionIndex] = session
            if currentSession?.id == session.id {
                currentSession = session
            }
            learningsManager.upsertOrganizationSession(session)
        } else if var session = persistedSession {
            session.wasReverted = true
            session.reaction = .reverted
            session.completedAt = max(session.completedAt ?? .distantPast, Date())
            session.timeToReaction = Date().timeIntervalSince(session.timestamp)
            session.failedRuleIds.formUnion(newlyFailedRuleIDs)
            session.events.append(
                OrganizationSessionEvent(
                    kind: .reverted,
                    summary: reason ?? "Organization was reverted"
                )
            )
            learningsManager.upsertOrganizationSession(session)
        }
        
        for sourcePath in rejectionSourcePaths {
            // AI moved A -> B.
            // User reverted (B -> A).
            // Learn: A -> B is BAD. (Rejection)
            learningsManager.recordRejection(originalPath: sourcePath)
        }

        for ruleId in newlyFailedRuleIDs {
            learningsManager.recordRuleFailure(ruleId: ruleId)
        }
    }

    /// Parks a revert whose attribution needs the profile, keyed by history
    /// entry so duplicate notifications replay once.
    private func parkRevert(entry: OrganizationHistoryEntry, reason: String?) {
        guard !pendingReverts.contains(where: { $0.entry.id == entry.id }) else { return }
        pendingReverts.append((entry: entry, reason: reason))
    }

    /// Replays reverts parked while the profile was unavailable. Runs when the
    /// profile loads, so session resolution sees persisted sessions.
    private func replayPendingReverts() {
        guard learningsManager.currentProfile != nil, !pendingReverts.isEmpty else { return }
        let pending = pendingReverts
        pendingReverts.removeAll()
        for item in pending {
            processRevert(entry: item.entry, reason: item.reason, isRetry: true)
        }
    }
    
    private func handleFinishNotification(_ notification: Notification) {
        // Track "pending" moves to correlate later
        // This helps us know "AI just put file X at Y" without querying history immediately
        guard let entry = notification.userInfo?["entry"] as? OrganizationHistoryEntry,
              let operations = entry.operations else { return }
        let learningExcluded = notification.userInfo?["learningExcluded"] as? Bool ?? false
        if learningExcluded || isRunExcluded(entry.directoryPath) {
            excludeCurrentRun(folderPath: entry.directoryPath)
            return
        }

        let entryID = entry.id.uuidString
        let normalizedFolder = standardizedPath(entry.directoryPath)
        let movedSourcePaths = Set(operations.filter { $0.destinationPath != nil }.map(\.sourcePath))

        // Resolve the session that belongs to this run. `FolderOrganizer` calls
        // `endSession()` before this notification's main-queue delivery, so
        // completion state must not decide the match: the history entry ID is
        // the run token, and a session already linked to another entry is a
        // different run and must never be merged into.
        var resolvedSession: OrganizationSession?
        if let index = recentSessions.firstIndex(where: { $0.historyEntryId == entryID }) {
            // Duplicate delivery for an already-linked run.
            resolvedSession = recentSessions[index]
        } else if let index = unclaimedFinishedSessionIndex(
            matchingFolder: normalizedFolder,
            movedSourcePaths: movedSourcePaths
        ) {
            resolvedSession = recentSessions[index]
        } else if let session = currentSession,
                  standardizedPath(session.folderPath) == normalizedFolder,
                  session.historyEntryId == nil || session.historyEntryId == entryID {
            resolvedSession = session
        }

        var usedRuleIDs: Set<String> = []
        if var session = resolvedSession {
            unclaimedFinishedSessionIDs.removeAll { $0 == session.id }
            session.historyEntryId = entryID
            if session.completedAt == nil {
                session.completedAt = Date()
            }
            applyOperations(operations, to: &session)
            usedRuleIDs = session.usedRuleIds
            persistSessionUpdate(session)
        } else if canCollect {
            // No tracked run survived (e.g. the observer restarted mid-run).
            // Keep the entry linked to a single session and inherit the rule
            // usage recorded for this run so rule successes are not lost.
            var session = OrganizationSession(
                completedAt: Date(),
                folderPath: entry.directoryPath,
                historyEntryId: entryID,
                events: [
                    OrganizationSessionEvent(
                        kind: .started,
                        summary: "Recovered organization run for \(URL(fileURLWithPath: entry.directoryPath).lastPathComponent)"
                    )
                ]
            )
            if let run = currentSession,
               standardizedPath(run.folderPath) == normalizedFolder,
               run.historyEntryId == nil || run.historyEntryId == entryID {
                session.usedRuleIds = run.usedRuleIds
                session.failedRuleIds = run.failedRuleIds
                session.appliedRules = run.appliedRules
            }
            applyOperations(operations, to: &session)
            usedRuleIDs = session.usedRuleIds
            persistSessionUpdate(session, appendIfNeeded: true)
        }

        for op in operations {
            if let destPath = op.destinationPath {
                recentlyMovedFiles[destPath] = Date()
            }
        }
        
        // Clean up old entries (older than 24 hours)
        let cutoff = Date().addingTimeInterval(-86400)
        recentlyMovedFiles = recentlyMovedFiles.filter { $0.value > cutoff }
        
        // Record run in metrics
        learningsManager.recordSuccessfulRun(folderPath: entry.directoryPath, fileCount: operations.count, ruleIdsUsed: usedRuleIDs)

        // Check for related files that were separated
        checkRelatedFilesSeparation(operations: operations, folderPath: entry.directoryPath)
    }

    /// Index of the oldest ended-but-unclaimed session for this folder whose
    /// recorded moves match the finishing run. Falls back to the oldest
    /// unclaimed session because finish order mirrors `endSession()` order.
    /// Candidates older than the correlation window are never claimed.
    private func unclaimedFinishedSessionIndex(
        matchingFolder normalizedFolder: String,
        movedSourcePaths: Set<String>
    ) -> Int? {
        pruneUnclaimedFinishedSessions()
        let cutoff = Date().addingTimeInterval(-correlationWindowMinutes * 60)
        let candidates = unclaimedFinishedSessionIDs.compactMap { id in
            recentSessions.firstIndex { $0.id == id }
        }.filter { index in
            let session = recentSessions[index]
            return standardizedPath(session.folderPath) == normalizedFolder
                && session.historyEntryId == nil
                && (session.completedAt ?? session.timestamp) >= cutoff
        }

        guard !candidates.isEmpty else { return nil }
        if !movedSourcePaths.isEmpty,
           let matching = candidates.first(where: {
               Set(recentSessions[$0].filesMoved.map(\.sourcePath)) == movedSourcePaths
           }) {
            return matching
        }
        return candidates.first
    }

    public func handleMonitoringWindowExpired(for directoryPath: String) {
        guard canCollect else { return }
        guard !isRunExcluded(directoryPath) else { return }
        guard let index = recentSessions
            .enumerated()
            .filter({ $0.element.folderPath == directoryPath })
            .sorted(by: { ($0.element.completedAt ?? $0.element.timestamp) > ($1.element.completedAt ?? $1.element.timestamp) })
            .map(\.offset)
            .first else { return }

        var session = recentSessions[index]
        guard session.completedAt != nil else { return }

        if session.wasReverted {
            currentSession = currentSession?.id == session.id ? nil : currentSession
            return
        }

        if session.userCorrections.isEmpty {
            session.reaction = .accepted
            session.timeToReaction = Date().timeIntervalSince(session.timestamp)
            session.events.append(
                OrganizationSessionEvent(
                    kind: .accepted,
                    summary: "No post-organization corrections were detected during the correlation window"
                )
            )

            for movedFile in session.filesMoved {
                learningsManager.addPositiveExample(srcPath: movedFile.sourcePath, dstPath: movedFile.destinationPath)
            }

            for ruleId in session.usedRuleIds.subtracting(session.failedRuleIds) {
                learningsManager.recordRuleSuccess(ruleId: ruleId)
            }
        }

        persistSessionUpdate(session)
        
        // Generate an inline learning moment for accepted sessions
        if session.reaction == .accepted {
            let proposedFolders = session.folderPatterns.map(\.folderName)
            if let moment = learningsManager.generateInlineLearningMoment(from: session, proposedFolders: proposedFolders) {
                pendingLearningMoment = moment
            }
        }
        
        if currentSession?.id == session.id {
            currentSession = nil
        }
    }

    // MARK: - Related Files Detection

    /// After organization, check if related project files (e.g., package.json + pnpm-lock.yaml)
    /// were moved to different locations or if some were moved while others weren't.
    private func checkRelatedFilesSeparation(
        operations: [FileOperation],
        folderPath: String
    ) {
        guard canCollect else { return }

        let movedFileNames = Set(operations.compactMap { op -> String? in
            guard op.destinationPath != nil else { return nil }
            return URL(fileURLWithPath: op.sourcePath).lastPathComponent
        })

        // Only names that actually exist in the organized folder (plus the files
        // this run moved) can be "left behind" or "separated". Group members
        // that were never on disk must not trigger a suggestion. The scan looks
        // into subfolders too: a nested lockfile that stayed behind is still
        // part of the project and must not read as absent.
        let presentFileNames = movedFileNames.union(
            presentRelatedFiles(
                in: folderPath,
                candidates: Set(Self.relatedFileGroups.flatMap { $0 })
            )
        )

        // Build a map of filename -> destination folder
        var fileDestinations: [String: String] = [:]
        for op in operations {
            guard let dest = op.destinationPath else { continue }
            let fileName = URL(fileURLWithPath: op.sourcePath).lastPathComponent
            let destFolder = URL(fileURLWithPath: dest).deletingLastPathComponent().path
            fileDestinations[fileName] = destFolder
        }

        for group in Self.relatedFileGroups {
            let movedFromGroup = group.filter { movedFileNames.contains($0) }
            guard !movedFromGroup.isEmpty else { continue }

            // Check if files in the group were moved to different destinations
            let destinations = Set(movedFromGroup.compactMap { fileDestinations[$0] })
            let presentGroupMembers = group.filter { presentFileNames.contains($0) }
            let notMoved = presentGroupMembers.filter { !movedFileNames.contains($0) }

            let shouldSuggest: Bool
            if destinations.count > 1 {
                // Files moved to different folders
                shouldSuggest = true
            } else if !notMoved.isEmpty {
                // Some files moved, others are still in the folder
                shouldSuggest = true
            } else {
                shouldSuggest = false
            }

            if shouldSuggest {
                let groupName = group.first ?? "project files"
                let fileList = presentGroupMembers.joined(separator: ", ")
                let message = "\(fileList) are related project files and should stay together. Consider adding them to exceptions."
                let suggestion = LearningsManager.ExceptionSuggestion(
                    message: message,
                    fileNames: Array(presentGroupMembers),
                    groupName: groupName
                )
                // Only add if not already suggested for this group
                if !learningsManager.pendingExceptionSuggestions.contains(where: { $0.groupName == groupName }) {
                    learningsManager.pendingExceptionSuggestions.append(suggestion)
                }
            }
        }
    }

    /// Related-file candidates that exist at the folder root or in a shallow
    /// subfolder. The old root-only listing treated a nested lockfile as
    /// absent, so a separated project file could go unnoticed. The scan is
    /// depth- and entry-bounded so large folders stay cheap.
    private func presentRelatedFiles(in folderPath: String, candidates: Set<String>) -> Set<String> {
        var remaining = candidates
        guard !remaining.isEmpty else { return [] }

        let rootContents = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: folderPath)) ?? []
        )
        var present = candidates.intersection(rootContents)
        remaining.subtract(present)
        guard !remaining.isEmpty else { return present }

        let maximumDepth = 3
        let maximumVisitedEntries = 2_000
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: folderPath, isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]
        ) else {
            return present
        }

        var visitedEntries = 0
        for case let url as URL in enumerator {
            if enumerator.level > maximumDepth {
                enumerator.skipDescendants()
                continue
            }
            visitedEntries += 1
            guard visitedEntries <= maximumVisitedEntries else { break }

            let name = url.lastPathComponent
            if remaining.remove(name) != nil {
                present.insert(name)
                if remaining.isEmpty { break }
            }
        }
        return present
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    static let steeringPromptProvided = Notification.Name("steeringPromptProvided")
    
    // Learnings menu actions
    static let showLearningsStats = Notification.Name("showLearningsStats")
    static let pauseLearning = Notification.Name("pauseLearning")
    static let exportLearningsProfile = Notification.Name("exportLearningsProfile")
    static let importLearningsProfile = Notification.Name("importLearningsProfile")
    static let clearLearningsData = Notification.Name("clearLearningsData")
}
