import AppKit
import Foundation
import SwiftUI
import Beam
import SortyFileSystem

// MARK: - Actions
extension DuplicatesView {
    func startScan() {
        guard let directory = effectiveDirectory else { return }
        let handoffPaths = handoffFilePaths
        handoffFilePaths = []
        let settings = settingsManager.settings
        HapticFeedbackManager.shared.tap()

        // Cancel any in-flight scan and invalidate any work already returned by it.
        currentScanTask?.cancel()
        if detectionManager.isScanning || isPreparingScan {
            detectionManager.cancelCurrentScan()
        }
        let scanID = UUID()
        currentScanID = scanID

        // Capture current directory
        capturedDirectory = directory
        detectionManager.state = .preparing

        currentScanTask = Task {
            let scanner = DirectoryScanner()
            do {
                let scanSource = try await resolveFilesForScan(
                    scanner: scanner,
                    directory: directory,
                    handoffPaths: handoffPaths,
                    settings: settings,
                    scanID: scanID
                )

                // Only the active scan for the still-selected directory may publish results.
                if currentScanID == scanID,
                   capturedDirectory == directory,
                   directory == effectiveDirectory,
                   !Task.isCancelled {
                    switch scanSource {
                    case .inventory(let inventory):
                        await detectionManager.scanForDuplicates(
                            inventory: inventory,
                            settings: settings
                        )
                    case .files(let files):
                        await detectionManager.scanForDuplicates(
                            files: files,
                            settings: settings
                        )
                    }

                    if currentScanID == scanID, !Task.isCancelled {
                        // Auto-select first group
                        if let first = detectionManager.allGroups.first {
                            appState.duplicateSelectedGroup = first
                        }
                        HapticFeedbackManager.shared.success()
                    }
                }
            } catch {
                if currentScanID == scanID, !Task.isCancelled {
                    detectionManager.state = .failed(error.userFacingMessage)
                    HapticFeedbackManager.shared.error()
                    DebugLogger.log("Duplicate scan failed: \(error)")
                    AnalyticsManager.shared.captureWorkflow(
                        workflow: "duplicate_scan",
                        stage: "preparing",
                        outcome: "failed"
                    )
                    ReliabilityManager.shared.capture(
                        error: error,
                        feature: "duplicates",
                        operation: "scan_directory"
                    )
                }
            }
        }
    }

    func resolveFilesForScan(
        scanner: DirectoryScanner,
        directory: URL,
        handoffPaths: [String],
        settings: DuplicateSettings,
        scanID: UUID
    ) async throws -> ResolvedDuplicateScan {
        guard !handoffPaths.isEmpty else {
            guard currentScanID == scanID, !Task.isCancelled else {
                throw CancellationError()
            }
            let inventory = try await scanner.scanDirectoryForDuplicates(
                at: directory,
                settings: settings
            ) { scanned, stage in
                guard self.currentScanID == scanID, !Task.isCancelled else { return }
                self.detectionManager.scanStage = "\(stage) \(scanned.formatted()) scanned"
            }
            return .inventory(inventory)
        }

        var targetedFiles: [FileItem] = []
        for path in handoffPaths {
            if Task.isCancelled || currentScanID != scanID { break }

            let fileURL = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            if let scannedFile = try? await scanner.scanFile(
                at: fileURL,
                deepScan: false,
                computeHashes: false
            ), !scannedFile.isDirectory
            {
                targetedFiles.append(scannedFile)
            }
        }

        if targetedFiles.count >= 2 {
            return .files(targetedFiles)
        }

        // Fallback when history paths no longer exist or are insufficient.
        guard currentScanID == scanID, !Task.isCancelled else {
            throw CancellationError()
        }
        let inventory = try await scanner.scanDirectoryForDuplicates(
            at: directory,
            settings: settings
        ) { scanned, stage in
            guard self.currentScanID == scanID, !Task.isCancelled else { return }
            self.detectionManager.scanStage = "\(stage) \(scanned.formatted()) scanned"
        }
        return .inventory(inventory)
    }

    enum ResolvedDuplicateScan {
        case inventory(DuplicateScanInventory)
        case files([FileItem])
    }

    func cancelScan() {
        AnalyticsManager.shared.captureImportantButton(
            "cancel_duplicate_scan",
            screen: "duplicates",
            feature: "duplicate_scan"
        )
        currentScanID = UUID()
        currentScanTask?.cancel()
        currentScanTask = nil
        detectionManager.cancelCurrentScan()
        HapticFeedbackManager.shared.tap()
    }

    /// Trashes the pending files off the main actor, records the cleanup in
    /// History, then refreshes the scan. Stale or partial failures surface an
    /// alert instead of silently reporting success.
    func deleteFiles(_ files: [FileItem]) async {
        // Bulk trashing is not re-entrant: a second cleanup would validate and
        // move files the first batch is already working on.
        guard !isCleaningUp else { return }
        isCleaningUp = true
        defer { isCleaningUp = false }

        var totalDeleted = 0
        var totalSizeRecovered: Int64 = 0
        var trashedPaths = Set<String>()

        do {
            let potentialRestorables = try await DuplicateRestorationManager.shared.moveToTrashAsync(
                files: files)
            totalDeleted = potentialRestorables.count
            totalSizeRecovered = files.reduce(0) { $0 + $1.size }
            trashedPaths.formUnion(potentialRestorables.map(\.originalPath))

            let entry = OrganizationHistoryEntry(
                directoryPath: effectiveDirectory?.path ?? "",
                filesOrganized: 0,
                foldersCreated: 0,
                success: true,
                status: .duplicatesCleanup,
                duplicatesDeleted: totalDeleted,
                recoveredSpace: totalSizeRecovered,
                restorableItems: potentialRestorables,
                duplicateCleanupMode: .trash
            )
            appState.organizer?.history.addEntry(entry)

            HapticFeedbackManager.shared.success()
            AnalyticsManager.shared.captureFeature(
                feature: "duplicates",
                subfeature: "cleanup",
                action: "move_to_trash",
                outcome: "success",
                properties: [
                    "count_bucket": AnalyticsManager.countBucket(totalDeleted),
                ]
            )
        } catch {
            // Files that already reached the Trash are kept restorable; the
            // `.duplicatesCleanup` status keeps History's restore action visible
            // even though the overall cleanup failed.
            if let partialFailure = error as? PartialTrashFailure {
                let movedItems = partialFailure.movedItems
                let deletedCount = movedItems.count
                let movedPaths = Set(movedItems.map(\.originalPath))
                trashedPaths.formUnion(movedPaths)
                let recoveredSpace = files
                    .filter { movedPaths.contains($0.path) }
                    .reduce(0) { $0 + $1.size }
                let errorMessage = error.userFacingMessage
                let entry = OrganizationHistoryEntry(
                    directoryPath: effectiveDirectory?.path ?? "",
                    filesOrganized: 0,
                    foldersCreated: 0,
                    success: false,
                    status: .duplicatesCleanup,
                    errorMessage: errorMessage,
                    duplicatesDeleted: deletedCount,
                    recoveredSpace: recoveredSpace,
                    restorableItems: movedItems,
                    duplicateCleanupMode: .trash
                )
                appState.organizer?.history.addEntry(entry)
            }

            cleanupErrorMessage = error.userFacingMessage
            HapticFeedbackManager.shared.error()
            DebugLogger.log("Delete failed: \(error)")
            AnalyticsManager.shared.captureFeature(
                feature: "duplicates",
                subfeature: "cleanup",
                action: "move_to_trash",
                outcome: "failed",
                properties: [
                    "count_bucket": AnalyticsManager.countBucket(files.count),
                ]
            )
            ReliabilityManager.shared.capture(
                error: error,
                feature: "duplicates",
                operation: "move_to_trash"
            )
        }

        // Drop the trashed files from the published groups before rescanning:
        // a cancelled rescan keeps the previous groups, and those must not
        // list files that already reached the Trash.
        pruneCleanedUpResults(trashedPaths)

        // Refresh the scan
        startScan()
    }

    /// Removes trashed paths from the published results and drops a selection
    /// that no longer exists, so a cancelled post-cleanup rescan cannot keep
    /// displaying deleted files.
    func pruneCleanedUpResults(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        detectionManager.pruneResults(removingPaths: paths)

        if let selected = appState.duplicateSelectedGroup,
           !detectionManager.allGroups.contains(where: { $0.id == selected.id }) {
            appState.duplicateSelectedGroup = detectionManager.allGroups.first
        }
    }

    func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            appState.duplicateSelectedDirectory = url
            detectionManager.clearResults()
            appState.duplicateSelectedGroup = nil
        }
    }

    /// Describes the pending set exactly: which group kinds are affected, how
    /// many files are removed, and which copies actually survive. The previous
    /// copy claimed similar files were never included, which is false for the
    /// per-file delete path.
    var bulkCleanupConfirmationMessage: String {
        let pendingIDs = Set(filesToDelete.map(\.id))
        let affectedGroups = detectionManager.allGroups.filter { group in
            group.files.contains { pendingIDs.contains($0.id) }
        }
        let fileLabel = filesToDelete.count == 1 ? "file" : "files"

        guard !affectedGroups.isEmpty else {
            return "Sorty will move \(filesToDelete.count) \(fileLabel) to Trash. History can restore these files until Trash is emptied."
        }

        let exactGroups = affectedGroups.filter(\.isExact)
        let similarGroups = affectedGroups.filter(\.isSemantic)
        var groupSummary: [String] = []
        if !exactGroups.isEmpty {
            groupSummary.append(
                "\(exactGroups.count) exact-match group\(exactGroups.count == 1 ? "" : "s")"
            )
        }
        if !similarGroups.isEmpty {
            groupSummary.append(
                "\(similarGroups.count) similar-file group\(similarGroups.count == 1 ? "" : "s")"
            )
        }

        var message =
            "Sorty will move \(filesToDelete.count) \(fileLabel) to Trash across \(groupSummary.joined(separator: " and "))."
        message += " \(keeperSummary(for: affectedGroups, pendingIDs: pendingIDs))"
        message += " History can restore these files until Trash is emptied."
        return message
    }

    /// Names the survivors using the actual pending set, so the confirmation
    /// never credits the keep strategy when the user chose a different keeper.
    func keeperSummary(
        for groups: [UnifiedDuplicateGroup],
        pendingIDs: Set<UUID>
    ) -> String {
        let survivingCount = groups.reduce(0) { total, group in
            total + group.files.filter { !pendingIDs.contains($0.id) }.count
        }

        guard survivingCount == groups.count else {
            return "\(survivingCount) file\(survivingCount == 1 ? "" : "s") in these groups stay."
        }

        let followsKeepStrategy = groups.allSatisfy { $0.isExact } && groups.allSatisfy { group in
            let keeperID = group.files.first { !pendingIDs.contains($0.id) }?.id
            return keeperID != nil && keeperID == CleanupPreferenceResolver.preferredFileID(
                in: group.files,
                strategy: settingsManager.settings.defaultKeepStrategy
            )
        }

        if followsKeepStrategy {
            return "One copy stays in each group (\(settingsManager.settings.defaultKeepStrategy.displayName))."
        }
        return "One file stays in each group."
    }

    func prepareBulkDelete() {
        guard !isCleaningUp else { return }

        var filesToDelete: [FileItem] = []

        // Bulk cleanup is intentionally limited to byte-identical files.
        for group in detectionManager.allGroups where group.isExact {
            guard let keepFileID = CleanupPreferenceResolver.preferredFileID(
                in: group.files,
                strategy: settingsManager.settings.defaultKeepStrategy
            ), group.files.contains(where: { $0.id == keepFileID }) else {
                continue
            }

            filesToDelete.append(contentsOf: group.files.filter { $0.id != keepFileID })
        }
        if !filesToDelete.isEmpty {
            self.filesToDelete = filesToDelete
            self.showDeleteConfirmation = true
        }
    }
}
