import SwiftUI
import SortyFileSystem

extension OrganizationCompleteView {
    func submitCompletionFeedback() {
        guard let outcome = feedbackDraft.outcome, feedbackDraft.canSubmit else { return }
        learningsManager.recordSessionOutcomeFeedback(
            sessionId: feedbackHistoryEntryID ?? directoryURL.path,
            outcome: outcome,
            folderPath: directoryURL.path,
            reason: feedbackDraft.resolvedReason
        )
        HapticFeedbackManager.shared.success()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            feedbackSubmitted = true
        }
    }
    
    /// Restores the failed undo/redo card when this view is mounted again while
    /// the organizer still carries the failure (for example after visiting
    /// History), instead of briefly showing the success presentation.
    func restoreFailureCardIfNeeded() {
        guard undoState == .idle,
              case .error = organizer.state,
              let action = organizer.completionFailureAction else { return }
        failureMessage = organizer.errorMessage
        failedAction = action == .undo ? FailedAction.undo : FailedAction.redo
        if action == .redo {
            // Redo retries the exact entry that failed; without it a remounted
            // card would show a disabled Redo button.
            lastUndoneEntry = organizer.completionFailureEntry
        }
        keepsFailureCardPinned = true
        undoState = .failed
    }

    func undoLastOrganization() {
        guard canUndo else {
            // A failed redo is retried through the redo button; route there
            // instead of leaving the caller with a silent no-op.
            if undoState == .failed && failedAction == .redo {
                redoLastOrganization()
            }
            return
        }
        let isRetry = undoState == .failed && failedAction == .undo
        guard let lastEntry = organizer.history.entries.first(where: { $0.directoryPath == directoryURL.path && $0.success && !$0.isUndone }) else { return }
        lastUndoneEntry = lastEntry
        keepsFailureCardPinned = false
        organizer.pinsCompletionView = true
        if isRetry {
            failureMessage = nil
            failedAction = nil
            organizer.errorMessage = nil
            organizer.completionFailureAction = nil
            organizer.completionFailureEntry = nil
        }

        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            undoState = .undoing
            showParticles = false
        }
        
        Task {
            do {
                // Load details first so the restored count can be limited to
                // file operations instead of every reversed operation.
                let detailedEntry = await organizer.history.details(for: lastEntry)
                let result = try await organizer.undoHistoryEntry(lastEntry)
                await MainActor.run {
                    undoRestoredCount = restoredDisplayCount(for: detailedEntry, result: result)
                    undoSkippedCount = result.missingFiles.count
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                        undoState = .completed
                    }
                    if undoRestoredCount > 0 || undoSkippedCount > 0 {
                        HapticFeedbackManager.shared.success()
                        showUndoCompleteHUD()
                    } else {
                        HapticFeedbackManager.shared.tap()
                    }
                }
            } catch {
                await MainActor.run {
                    let message = "Couldn't restore your files: \(error.userFacingMessage)"
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                        undoState = .failed
                    }
                    failureMessage = message
                    failedAction = .undo
                    organizer.errorMessage = message
                    organizer.completionFailureAction = .undo
                    organizer.completionFailureEntry = lastEntry
                    keepsFailureCardPinned = true
                    organizer.pinsCompletionView = true
                    HapticFeedbackManager.shared.error()
                }
                DebugLogger.log("Failed to undo organization: \(error.localizedDescription)")
            }
        }
    }

    private func showUndoCompleteHUD() {
        let message = undoRestoredSummaryText
        NotificationManager.shared.showHUDInfo(
            title: "Files restored",
            message: message,
            icon: "checkmark.seal.fill",
            iconColor: .mint,
            actions: [
                HUDNotificationAction(title: "Redo", systemImage: "arrow.uturn.forward") {
                    NotificationManager.shared.dismissHUD()
                    redoLastOrganization()
                }
            ]
        )
    }

    private var undoRestoredSummaryText: String {
        if undoSkippedCount > 0 {
            return "\(undoRestoredCount) restored, \(undoSkippedCount) skipped"
        }
        return "\(undoRestoredCount) restored"
    }

    private func restoredDisplayCount(
        for entry: OrganizationHistoryEntry,
        result: FileSystemManager.RestoreResult
    ) -> Int {
        // Only move/rename/copy operations touch files; `successfulOperations`
        // also counts tag restores and folder cleanups. A missing operation list,
        // or a pass with nothing restored and nothing missing, means there is
        // nothing to report as restored.
        let fileOperations = (entry.operations ?? []).filter { operation in
            operation.type == .moveFile || operation.type == .renameFile || operation.type == .copyFile
        }
        guard !fileOperations.isEmpty,
              result.successfulOperations > 0 || !result.missingFiles.isEmpty else {
            return 0
        }

        let failedOperationIDs = Set(result.retryableFailedOperationIDs)
        return fileOperations.filter { !failedOperationIDs.contains($0.id) }.count
    }

    func redoLastOrganization() {
        guard canRedo else { return }
        let isRetry = undoState == .failed && failedAction == .redo
        guard let entry = lastUndoneEntry else { return }
        keepsFailureCardPinned = false
        organizer.pinsCompletionView = true
        if isRetry {
            failureMessage = nil
            failedAction = nil
            organizer.errorMessage = nil
            organizer.completionFailureAction = nil
            organizer.completionFailureEntry = nil
        }

        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            undoState = .redoing
        }

        Task {
            do {
                try await organizer.redoOrganization(from: entry)
                await MainActor.run {
                    failedAction = nil
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                        undoState = .idle
                    }
                    lastUndoneEntry = nil
                    undoRestoredCount = 0
                    undoSkippedCount = 0
                    HapticFeedbackManager.shared.success()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showParticles = true
                    }
                }
            } catch {
                await MainActor.run {
                    let message = "Couldn't reapply the organization: \(error.userFacingMessage)"
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                        undoState = .failed
                    }
                    failureMessage = message
                    failedAction = .redo
                    organizer.errorMessage = message
                    organizer.completionFailureAction = .redo
                    organizer.completionFailureEntry = entry
                    keepsFailureCardPinned = true
                    organizer.pinsCompletionView = true
                    HapticFeedbackManager.shared.error()
                }
                DebugLogger.log("Failed to redo organization: \(error.localizedDescription)")
            }
        }
    }

    func returnToStart() {
        keepsFailureCardPinned = false
        organizer.completionFailureAction = nil
        organizer.completionFailureEntry = nil
        organizer.pinsCompletionView = false
        if let onReturnToStart {
            onReturnToStart()
        } else {
            withAnimation(.smooth(duration: 0.34)) {
                organizer.reset()
            }
        }
    }
    
}
