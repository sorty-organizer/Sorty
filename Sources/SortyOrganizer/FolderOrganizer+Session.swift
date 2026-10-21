import Foundation
import SwiftUI
import Combine
import SortyLearnings
import SortyFileSystem
import SortyModels
import SortyAI
import SortyFS

// MARK: - Reset
extension FolderOrganizer {
    public func reset() {
        cancelInternal()
        preparedPlanModeOverride = nil
        
        // Clear transient AI session errors on manual reset
        AISessionManager.shared.clearErrors()

        // Batch all reset operations into a single UI update cycle
        withBatchUpdates {
            pinsCompletionView = false
            transition(to: .idle, force: true)
            progress = 0.0
            currentPlan = nil
            planHistory = []
            errorMessage = nil
            clearStreamingDisplayState()
            organizationStage = ""
            isStreaming = false
            showTimeoutMessage = false
            elapsedTime = 0
            currentDirectory = nil
            blockingExclusionRule = nil
            scannedFileCount = 0
            scannedFiles = []
            allScannedFiles = []
            detectedDuplicates = []
            measuredWorkProgress = nil
            visionAnalysisSummary = nil
            resumeCheckpoint = nil
            // Keep isCancellationRequested=true so late chunks/callbacks from the
            // cancelled run keep dropping. The next operation resets it to false.
            userInitiatedAction = false
            
            // Clear AI insights and cache
            insightExtractionTask?.cancel()
            insightExtractionTask = nil
            currentInsight = ""
            insightHistory = []
            lastInsightExtraction = .distantPast
            insightsCache = nil
        }
        clearPersistedManualSession()
    }

    // MARK: - Manual session restore (Full Disk Access restart)

    /// Why a manual session was snapshotted. Selected/interrupted runs
    /// restore the folder without a plan; ready/completed runs restore the plan.
    public enum ManualSessionStateHint: String, Codable, Sendable {
        case selected
        case interrupted
        case ready
        case completed
    }

    struct PersistedManualSession: Codable, Sendable {
        var directoryPath: String
        var directoryBookmark: Data?
        var customInstructions: String
        var instructionsFormatVersion: Int?
        var plan: OrganizationPlan?
        var stateHint: ManualSessionStateHint
        var savedAt: Date
    }

    struct ManualSessionRestoreResult: Sendable {
        let snapshot: PersistedManualSession
        let directory: URL
        let scopedBookmarkURL: URL?
    }

    /// Older ready snapshots saved the assembled request. Recover the direct
    /// user block, including snapshots wrapped again by a later run.
    nonisolated private static func recoverLegacyUserInstructions(_ stored: String) -> String {
        var text = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = "<user_instructions>"
        let closing = "</user_instructions>"
        while text.hasPrefix(opening) {
            text = String(text.dropFirst(opening.count))
            if let end = text.range(of: closing) {
                text = String(text[..<end.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let generatedSections = [
            "IMPORTANT: The following patterns are STRICTLY EXCLUDED and must NOT be moved, renamed, or modified:",
            "NATURAL LANGUAGE EXCEPTIONS (must be respected):",
            "## SOURCE FOLDER CONTEXT",
            "## REFERENCE MODEL DIRECTORIES",
            "LEARNINGS CONTEXT",
            "DUPLICATE FILES DETECTED:",
            "## ORGANIZATION LOCATIONS"
        ]
        if let boundary = generatedSections.compactMap({ text.range(of: $0)?.lowerBound }).min() {
            text = String(text[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    static func defaultManualSessionURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sorty", isDirectory: true)
            .appendingPathComponent("ManualSession.json")
    }

    private func resolvedManualSessionURL(_ explicit: URL? = nil) -> URL? {
        explicit ?? manualSessionURLForTesting ?? Self.defaultManualSessionURL()
    }

    /// Snapshots the manual session for restart recovery. Writes stay on the
    /// main actor per the startup contract; each call replaces the previous
    /// snapshot so the file always reflects the latest user-visible state.
    public func persistManualSession(
        directory: URL,
        plan: OrganizationPlan?,
        stateHint: ManualSessionStateHint,
        instructions: String,
        url: URL? = nil
    ) {
        guard isManualSessionPersistenceEnabled else { return }
        let targetURL = resolvedManualSessionURL(url)
        guard let targetURL else { return }
        let directoryPath = directory.standardizedFileURL.path
        let bookmark: Data?
        if cachedManualSessionDirectoryPath == directoryPath {
            bookmark = cachedManualSessionBookmark
        } else {
            bookmark = try? directory.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            cachedManualSessionDirectoryPath = directoryPath
            cachedManualSessionBookmark = bookmark
        }
        let snapshot = PersistedManualSession(
            directoryPath: directoryPath,
            directoryBookmark: bookmark,
            customInstructions: instructions,
            instructionsFormatVersion: 1,
            plan: plan,
            stateHint: stateHint,
            savedAt: Date()
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var fingerprintSnapshot = snapshot
            fingerprintSnapshot.savedAt = .distantPast
            let fingerprint = try encoder.encode(fingerprintSnapshot)
            if lastManualSessionFingerprintByURL[targetURL] == fingerprint,
               FileManager.default.fileExists(atPath: targetURL.path) {
                return
            }
            manualSessionGeneration &+= 1
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(snapshot)
            try data.write(to: targetURL, options: .atomic)
            lastManualSessionFingerprintByURL[targetURL] = fingerprint
        } catch {
            ModelLog.debug("FolderOrganizer: Failed to persist manual session: \(error)")
        }
    }

    /// Records a folder selection before analysis starts. Skips when a richer
    /// snapshot (in-progress run or ready plan) is already active so restoring
    /// cannot clobber it back to a bare selection.
    public func persistSelectedDirectoryForRestart(_ url: URL, sessionURL: URL? = nil) {
        guard isManualSessionPersistenceEnabled,
              state == .idle,
              currentPlan == nil else { return }
        persistManualSession(directory: url, plan: nil, stateHint: .selected, instructions: customInstructions, url: sessionURL)
    }

    public func clearPersistedManualSession(url: URL? = nil) {
        guard isManualSessionPersistenceEnabled else { return }
        let targetURL = resolvedManualSessionURL(url)
        guard let targetURL else { return }
        manualSessionGeneration &+= 1
        restoredManualSessionScopedURL?.stopAccessingSecurityScopedResource()
        restoredManualSessionScopedURL = nil
        try? FileManager.default.removeItem(at: targetURL)
        lastManualSessionFingerprintByURL.removeValue(forKey: targetURL)
    }

    /// Restores the snapshotted folder (and ready/completed plan when present).
    /// Reads and decodes off the main actor; published state mutates on it.
    /// Returns the restored directory so the caller can reselect it.
    @discardableResult
    public func restorePersistedManualSession(sessionURL: URL? = nil) async -> URL? {
        guard isManualSessionPersistenceEnabled else { return nil }
        guard state == .idle, currentDirectory == nil, currentPlan == nil else { return nil }
        let targetURL = resolvedManualSessionURL(sessionURL)
        guard let targetURL else { return nil }
        let generation = manualSessionGeneration
        let result: ManualSessionRestoreResult? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: targetURL) else { return nil }
            guard let snapshot = try? JSONDecoder().decode(PersistedManualSession.self, from: data) else {
                return nil
            }
            var resolved: URL?
            var scopedBookmarkURL: URL?
            if let bookmark = snapshot.directoryBookmark {
                var isStale = false
                if let bookmarkURL = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    if bookmarkURL.startAccessingSecurityScopedResource() {
                        scopedBookmarkURL = bookmarkURL
                    }
                    resolved = bookmarkURL.standardizedFileURL
                }
            }
            let directory = resolved
                ?? URL(fileURLWithPath: snapshot.directoryPath).standardizedFileURL
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                scopedBookmarkURL?.stopAccessingSecurityScopedResource()
                try? FileManager.default.removeItem(at: targetURL)
                return nil
            }
            return ManualSessionRestoreResult(
                snapshot: snapshot,
                directory: directory,
                scopedBookmarkURL: scopedBookmarkURL
            )
        }.value
        guard let result else { return nil }
        guard generation == manualSessionGeneration,
              state == .idle,
              currentDirectory == nil,
              currentPlan == nil,
              resolvedManualSessionURL(sessionURL) == targetURL else {
            result.scopedBookmarkURL?.stopAccessingSecurityScopedResource()
            return nil
        }
        let snapshot = result.snapshot
        let directory = result.directory
        restoredManualSessionScopedURL?.stopAccessingSecurityScopedResource()
        restoredManualSessionScopedURL = result.scopedBookmarkURL
        customInstructions = snapshot.instructionsFormatVersion == nil
            ? Self.recoverLegacyUserInstructions(snapshot.customInstructions)
            : snapshot.customInstructions
        currentDirectory = directory
        switch snapshot.stateHint {
        case .ready:
            guard let plan = snapshot.plan else { return directory }
            currentPlan = plan
            progress = 1.0
            transition(to: .ready, force: true)
            organizationStage = "Ready!"
        case .completed:
            guard let plan = snapshot.plan else { return directory }
            currentPlan = plan
            progress = 1.0
            transition(to: .completed, force: true)
            organizationStage = "Complete!"
        case .selected, .interrupted:
            break
        }
        return directory
    }

    public func loadPreparedIncrementalPlan(
        _ plan: OrganizationPlan,
        directory: URL,
        mode: OrganizationMode
    ) {
        cancelInternal()
        isCancellationRequested = false
        currentDirectory = directory
        currentPlan = plan
        preparedPlanModeOverride = mode
        transition(to: .ready, force: true)
        organizationStage = "Ready for review"
        progress = 1
    }
    func recordPlanRules(_ plan: OrganizationPlan, observer: ContinuousLearningObserver) {
        // Recursively record rules
        let rootPath = currentDirectory?.path ?? ""
        
        func processSuggestion(_ suggestion: FolderSuggestion, currentPath: String) {
            let folderPath = (currentPath as NSString).appendingPathComponent(suggestion.folderName)
            
            // Record rules for files in this folder
            for _ in suggestion.files {
                let destinationPath = folderPath // Approximate destination path for the file
                
                // If the suggestion has a rule ID (from Learnings analysis), record it
                if let ruleId = suggestion.semanticTags.first(where: { $0.hasPrefix("rule:") })?.replacingOccurrences(of: "rule:", with: "") {
                    observer.recordRuleApplication(destinationPath: destinationPath, ruleId: ruleId)
                }
            }
            
            // Recurse
            for subfolder in suggestion.subfolders {
                processSuggestion(subfolder, currentPath: folderPath)
            }
        }
        
        for suggestion in plan.suggestions {
            processSuggestion(suggestion, currentPath: rootPath)
        }
    }
}
