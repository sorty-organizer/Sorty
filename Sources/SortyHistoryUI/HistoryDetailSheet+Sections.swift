import AppKit
import SwiftUI

// MARK: - Sections
extension HistoryDetailSheet {
    @ViewBuilder
    func rawAIResponseSection(_ raw: String) -> some View {
        let displayRaw = FeatureFlags.privacyModeEnabled ? PrivacyPathMasker.redactedText(raw) : raw
        let copyRaw = FeatureFlags.privacyModeEnabled ? displayRaw : raw
        let responseLines = displayRaw.components(separatedBy: .newlines)

        VStack(alignment: .leading, spacing: 8) {
            Button {
                toggleRawAIResponse()
                HapticFeedbackManager.shared.tap()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showRawAIResponse ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .symbolReplaceTransition(animationValue: showRawAIResponse)
                    Text("Raw AI Response")
                        .font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("RawAIResponseDisclosure")
            .accessibilityHint(showRawAIResponse ? "Tap to collapse" : "Tap to expand")

            if showRawAIResponse {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        CopyButtonWithAnimation(
                            content: copyRaw,
                            label: FeatureFlags.privacyModeEnabled ? "Copy Redacted JSON" : "Copy Raw JSON"
                        )
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("CopyRawJSONButton")
                    }

                    ScrollView([.horizontal, .vertical], showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(responseLines.enumerated()), id: \.offset) { _, line in
                                rawResponseLine(line)
                            }
                        }
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.topLeading)
                    .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 500, alignment: .leading)
                    .padding()
                    .background(Color.black.opacity(0.05))
                    .cornerRadius(8)
                    .accessibilityLabel(FeatureFlags.privacyModeEnabled ? "Raw AI response hidden in Privacy Mode" : "Raw AI response data")
                }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.985, anchor: .top))
                )
            }
        }
    }

    func toggleRawAIResponse() {
        if showRawAIResponse {
            withAnimation(rawAIResponseDisclosureAnimation) {
                showRawAIResponse = false
            }
            return
        }

        withAnimation(rawAIResponseDisclosureAnimation) {
            showRawAIResponse = true
        }
    }

    var rawAIResponseDisclosureAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.52, dampingFraction: 0.86)
    }

    func handleUndo() {
        HapticFeedbackManager.shared.tap()
        // Perform pre-flight validation before showing confirmation
        Task { @MainActor in
            let result = performPreflightValidation(for: .undo)
            preflightResult = result
            showUndoConfirmation = true
        }
    }

    func executeUndo() {
        HapticFeedbackManager.shared.tap()
        isProcessing = true
        Task {
            do {
                let result = try await organizer.undoHistoryEntry(currentEntry)
                if result.hasIssues {
                    HapticFeedbackManager.shared.tap()
                    // Show detailed partial result sheet
                    partialUndoResult = PartialUndoResult(
                        successCount: result.successfulOperations,
                        missingFiles: result.missingFiles,
                        failedOperationCount: result.retryableFailedOperationIDs.count,
                        directoryPath: currentEntry.directoryPath
                    )
                    isProcessing = false
                    showPartialResultSheet = true
                } else {
                    HapticFeedbackManager.shared.success()
                    onAction("All \(result.successfulOperations) operations reversed successfully.")
                    onDismiss()
                }
            } catch {
                HapticFeedbackManager.shared.error()
                onAction(friendlyErrorMessage(for: error, operation: "undo"))
            }
            isProcessing = false
        }
    }

    func handleRestore() {
        HapticFeedbackManager.shared.tap()
        showRestoreConfirmation = true
    }

    func showDifferentModelPicker() {
        HapticFeedbackManager.shared.tap()
        showRedoModelPicker = true
    }

    func executeRestore() {
        HapticFeedbackManager.shared.tap()
        isProcessing = true
        Task {
            do {
                let result = try await organizer.restoreToState(targetEntry: currentEntry)
                if result.hasIssues {
                    HapticFeedbackManager.shared.tap()
                    partialUndoResult = PartialUndoResult(
                        successCount: result.successfulOperations,
                        missingFiles: result.missingFiles,
                        failedOperationCount: result.retryableFailedOperationIDs.count,
                        directoryPath: currentEntry.directoryPath
                    )
                    isProcessing = false
                    showPartialResultSheet = true
                } else {
                    HapticFeedbackManager.shared.success()
                    onAction("Folder state restored successfully.")
                    onDismiss()
                }
            } catch {
                HapticFeedbackManager.shared.error()
                onAction(friendlyErrorMessage(for: error, operation: "restore"))
            }
            isProcessing = false
        }
    }

    func handleRedo() {
        HapticFeedbackManager.shared.tap()
        // Perform pre-flight validation before showing confirmation
        Task { @MainActor in
            let result = performPreflightValidation(for: .redo)
            preflightResult = result
            showRedoConfirmation = true
        }
    }

    func executeRedo() {
        HapticFeedbackManager.shared.tap()
        isProcessing = true
        Task {
            do {
                try await organizer.redoOrganization(from: currentEntry)
                HapticFeedbackManager.shared.success()
                onAction("Organization re-applied successfully.")
                onDismiss()
            } catch {
                HapticFeedbackManager.shared.error()
                onAction(friendlyErrorMessage(for: error, operation: "redo"))
            }
            isProcessing = false
        }
    }

    enum PreflightOperation {
        case undo
        case redo
    }

    func performPreflightValidation(for operation: PreflightOperation) -> PreflightValidationResult {
        var missingFiles: [String] = []
        var directoryIssues: [String] = []
        var availableCount = 0

        let fileManager = FileManager.default

        switch operation {
        case .undo:
            // Check if files at destination paths still exist (for undo, we move from destination back to source)
            guard let operations = currentEntry.operations else {
                return PreflightValidationResult(availableCount: 0, missingFiles: [], directoryIssues: [])
            }

            for op in operations where op.type == .moveFile || op.type == .renameFile {
                if let destPath = op.destinationPath {
                    if fileManager.fileExists(atPath: destPath) {
                        availableCount += 1
                        // Check if source directory still exists
                        let sourceDir = URL(fileURLWithPath: op.sourcePath).deletingLastPathComponent().path
                        if !fileManager.fileExists(atPath: sourceDir) && !directoryIssues.contains(sourceDir) {
                            directoryIssues.append(sourceDir)
                        }
                    } else {
                        let fileName = URL(fileURLWithPath: destPath).lastPathComponent
                        missingFiles.append(fileName)
                    }
                }
            }

        case .redo:
            // For redo, check if source files exist at their original locations
            guard let operations = currentEntry.operations else {
                return PreflightValidationResult(availableCount: 0, missingFiles: [], directoryIssues: [])
            }

            for op in operations where op.type == .moveFile || op.type == .renameFile {
                if fileManager.fileExists(atPath: op.sourcePath) {
                    availableCount += 1
                } else {
                    let fileName = URL(fileURLWithPath: op.sourcePath).lastPathComponent
                    missingFiles.append(fileName)
                }
            }
        }

        return PreflightValidationResult(
            availableCount: availableCount,
            missingFiles: missingFiles,
            directoryIssues: directoryIssues
        )
    }

    func friendlyErrorMessage(for error: Error, operation: String) -> String {
        let nsError = error as NSError

        // Handle common file system errors with actionable guidance
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError:
                return "Some files were moved or deleted since this organization. Try using 'Undo' on individual operations instead."
            case NSFileWriteNoPermissionError:
                return "Permission denied. Check that Sorty has access to this folder in System Settings > Privacy & Security > Files and Folders."
            case NSFileWriteOutOfSpaceError:
                return "Not enough disk space. Free up some space and try again."
            case NSFileWriteVolumeReadOnlyError:
                return "This volume is read-only. Check that the disk is not locked or in read-only mode."
            default:
                break
            }
        }

        // Default to the localized description with operation context
        return "Could not \(operation): \(error.localizedDescription)"
    }

    func handleRestoreDuplicates() {
        HapticFeedbackManager.shared.tap()
        isProcessing = true
        Task {
            guard let restorables = currentEntry.restorableItems else {
                isProcessing = false
                return
            }
            var restoredCount = 0
            var failedCount = 0
            var restorableItems: [RestorableDuplicate] = []
            for item in restorables {
                guard DuplicateRestorationManager.shared.canRestore(item: item) else {
                    failedCount += 1
                    restorableItems.append(item)
                    continue
                }
                do {
                    try DuplicateRestorationManager.shared.restore(item: item)
                    restoredCount += 1
                } catch {
                    failedCount += 1
                    restorableItems.append(item)
                }
            }
            if restoredCount > 0 {
                HapticFeedbackManager.shared.success()

                // Drop the restored entries so "Deleted Files" and the restore
                // button disappear. Keep an empty array rather than nil so the
                // entry still counts as detailed and the pruned list is written
                // back instead of a stale details file being re-read.
                var updatedEntry = currentEntry
                updatedEntry.restorableItems = restorableItems
                loadedEntry = updatedEntry
                organizer.history.updateEntry(updatedEntry)
            } else {
                HapticFeedbackManager.shared.error()
            }
            let failureSuffix = failedCount == 0 ? "" : " \(failedCount) could not be restored because they were removed from Trash or their destination is occupied."
            onAction("Restored \(restoredCount) files.\(failureSuffix)")
            isProcessing = false
            onDismiss()
        }
    }

    func handleUndoSingleOperation(_ operation: FileSystemManager.FileOperation) {
        HapticFeedbackManager.shared.tap()
        undoingOperationID = operation.id
        Task { @MainActor in
            do {
                let result = try await organizer.undoSingleOperation(from: currentEntry, operation: operation)
                if result.hasIssues {
                    HapticFeedbackManager.shared.error()
                    failedOperationIDs.insert(operation.id)
                } else {
                    HapticFeedbackManager.shared.success()
                    undoneOperationIDs.insert(operation.id)
                    // Per-file undo teaches Sorty: remember the reverted placement.
                    learningsManager.recordRejection(originalPath: operation.sourcePath)
                }
            } catch {
                HapticFeedbackManager.shared.error()
                failedOperationIDs.insert(operation.id)
            }
            undoingOperationID = nil
        }
    }

    static func files(from plan: OrganizationPlan?) -> [FileItem] {
        guard let plan else { return [] }
        var files = plan.unorganizedFiles
        func collect(_ suggestion: FolderSuggestion) {
            files.append(contentsOf: suggestion.files)
            suggestion.subfolders.forEach(collect)
        }
        plan.suggestions.forEach(collect)
        return files
    }

    func handleRedoWithModel(provider: AIProvider, model: String) {
        showRedoModelPicker = false
        HapticFeedbackManager.shared.tap()
        isProcessing = true
        Task {
            do {
                // Set up folder context from history entry
                let directoryURL = URL(fileURLWithPath: entry.directoryPath)
                organizer.currentDirectory = directoryURL

                // Generate new plan with specified provider/model
                try await organizer.regenerateWithModel(
                    provider: provider,
                    model: model,
                    files: Self.files(from: entry.plan)
                )
                HapticFeedbackManager.shared.success()
                onAction("New organization generated with \(provider.displayName) (\(model)).")
                onDismiss()
            } catch {
                HapticFeedbackManager.shared.error()
                onAction("Error: \(error.localizedDescription)")
            }
            isProcessing = false
        }
    }

    private func rawResponseLine(_ line: String) -> some View {
        Text(line.isEmpty ? " " : line)
            .scrollTransition(
                topLeading: .identity,
                bottomTrailing: reduceMotion
                    ? .identity
                    : .interactive(timingCurve: .easeInOut)
                        .threshold(.visible(0.18)),
                axis: .vertical
            ) { content, phase in
                content
                    .opacity(phase == .bottomTrailing ? 0 : 1)
                    .blur(radius: phase == .bottomTrailing ? 1.5 : 0)
                    .offset(y: phase == .bottomTrailing ? 6 : 0)
            }
    }
}
