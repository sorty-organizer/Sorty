import AppKit
import SwiftUI

struct HistoryDetailSheet: View {
    @SortyHotReload var hotReload
    let entry: OrganizationHistoryEntry
    @Binding var isProcessing: Bool
    let onAction: (String) -> Void
    let onDismiss: () -> Void

    @State var showRawAIResponse = false
    @State var showRedoModelPicker = false
    @State var undoneOperationIDs: Set<UUID> = []
    @State var failedOperationIDs: Set<UUID> = []
    @State var undoingOperationID: UUID?
    @State var highlightedFileID: UUID? = nil
    @State var feedbackGiven: LearningsManager.SessionOutcome?
    @State var showFeedbackConfirmation = false
    @State var detailModel: HistoryDetailModel?
    @State var loadedEntry: OrganizationHistoryEntry?

    // Pre-flight validation state
    @State var showUndoConfirmation = false
    @State var showRestoreConfirmation = false
    @State var showRedoConfirmation = false
    @State var preflightResult: PreflightValidationResult?
    @State var showPartialResultSheet = false
    @State var partialUndoResult: PartialUndoResult?

    @EnvironmentObject var organizer: FolderOrganizer
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var learningsManager: LearningsManager
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var currentEntry: OrganizationHistoryEntry {
        guard var loadedEntry else {
            return organizer.history.entries.first { $0.id == entry.id } ?? entry
        }
        if let summary = organizer.history.entries.first(where: { $0.id == entry.id }) {
            loadedEntry.status = summary.status
            loadedEntry.isUndone = summary.isUndone
            loadedEntry.undoRestoredCount = summary.undoRestoredCount
        }
        return loadedEntry
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                    HistoryDetailHeaderSection(
                        entry: currentEntry,
                        reasoningNotes: currentEntry.plan?.notes
                    )

                    Divider()

                    HistorySessionStatisticsSection(
                        entry: currentEntry,
                        showsDetailedStats: settingsViewModel.config.showStatsForNerds
                    )

                    HistoryPartialUndoSection(entry: currentEntry)

                    HistoryDetailErrorSection(entry: currentEntry)

                    HistoryDetailActionsSection(
                        entry: currentEntry,
                        onRestoreDuplicates: handleRestoreDuplicates,
                        onApplyOrRedo: handleRedo,
                        onRestore: handleRestore,
                        onUndo: handleUndo,
                        onTryDifferentModel: showDifferentModelPicker
                    )

                    if currentEntry.status == .completed,
                       !currentEntry.isUndone,
                       learningsManager.summary.state != .noConsent,
                       learningsManager.summary.state != .locked {
                        QuickFeedbackButtons(
                            feedbackGiven: $feedbackGiven,
                            showConfirmation: $showFeedbackConfirmation,
                            onFeedback: recordFeedback,
                            isPaused: learningsManager.summary.state == .paused
                        )
                    }

                    // Timeline Section
                    if currentEntry.success {
                        CompactTimelineView(
                            entries: organizer.history.entries,
                            directoryPath: currentEntry.directoryPath
                        )
                    }

                    // Learnings Applied
                    if let detailModel {
                        HistoryLiquidGlassLearningsCard(
                            fileContexts: detailModel.learningsFileContexts
                        )
                    }

                    // Duplicate Files
                    if let detailModel {
                        HistoryLiquidGlassDuplicateCard(
                            duplicateGroups: detailModel.duplicateGroups,
                            totalDuplicateCount: detailModel.totalDuplicateCount,
                            handoffDirectory: URL(fileURLWithPath: currentEntry.directoryPath),
                            highlightedFileID: $highlightedFileID
                        )
                    }

                    HistoryPlanDetailsSection(
                        entry: currentEntry,
                        highlightedFileID: $highlightedFileID
                    )

                    HistoryFileOperationsSection(
                        entry: currentEntry,
                        undoneOperationIDs: undoneOperationIDs,
                        failedOperationIDs: failedOperationIDs,
                        undoingOperationID: undoingOperationID,
                        onUndo: handleUndoSingleOperation
                    )

                    HistoryRestorableItemsSection(entry: currentEntry)

                    // Raw AI Response (Stats for Nerds)
                    if settingsViewModel.config.showStatsForNerds,
                       let raw = currentEntry.rawAIResponse,
                       !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        rawAIResponseSection(raw)
                    }
                    }
                    .padding(24)
                }
                .onChange(of: highlightedFileID) { _, highlightedFileID in
                    guard let highlightedFileID else { return }
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                        scrollProxy.scrollTo(highlightedFileID, anchor: .center)
                    }
                    DispatchQueue.main.async {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                            scrollProxy.scrollTo(highlightedFileID, anchor: .center)
                        }
                    }
                }
                .navigationTitle("Session Details")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            onDismiss()
                        }
                        .accessibilityLabel("Close details")
                        .accessibilityIdentifier("DismissDetailsButton")
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .task(id: entry.id) {
            let details = await organizer.history.details(for: entry)
            guard !Task.isCancelled else { return }
            loadedEntry = details
            detailModel = HistoryDetailModel(entryID: details.id, plan: details.plan)
        }
        .modelSelectionOverlay(
            isPresented: $showRedoModelPicker,
            currentProvider: settingsViewModel.config.provider,
            currentModel: settingsViewModel.config.model,
            reasoningEffortForModel: { provider, model in
                settingsViewModel.config.reasoningEffort(for: provider, model: model)
            },
            onSelectReasoningEffort: { provider, model, effort in
                settingsViewModel.config.setReasoningEffort(effort, for: provider, model: model)
            },
            onSelect: { provider, model, authMethod in
                if let authMethod {
                    settingsViewModel.config.setAuthMethod(authMethod, for: provider)
                }
                handleRedoWithModel(provider: provider, model: model)
            },
            isSubscriptionSelected: settingsViewModel.config.authMethod(for: settingsViewModel.config.provider) == .accountSignIn
        )
        .confirmationDialog(
            "Undo Organization?",
            isPresented: $showUndoConfirmation,
            titleVisibility: .visible
        ) {
            Button("Undo \(preflightResult?.availableCount ?? 0) Operations", role: .destructive) {
                executeUndo()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let result = preflightResult {
                Text(undoConfirmationMessage(result))
            }
        }
        .confirmationDialog(
            "Restore to This State?",
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                executeRestore()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will undo all organization sessions after this point for this folder. Some files may have been modified or moved since.")
        }
        .confirmationDialog(
            "Re-Apply Organization?",
            isPresented: $showRedoConfirmation,
            titleVisibility: .visible
        ) {
            Button("Re-Apply") {
                executeRedo()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let result = preflightResult {
                Text(redoConfirmationMessage(result))
            }
        }
        .sheet(isPresented: $showPartialResultSheet) {
            if let result = partialUndoResult {
                PartialUndoResultSheet(result: result) {
                    showPartialResultSheet = false
                    partialUndoResult = nil
                }
            }
        }
    }

    func undoConfirmationMessage(_ result: PreflightValidationResult) -> String {
        var message = "This will move \(result.availableCount) file(s) back to their original locations."
        if !result.missingFiles.isEmpty {
            message += "\n\n⚠️ \(result.missingFiles.count) file(s) cannot be restored because they were moved or deleted."
        }
        if !result.directoryIssues.isEmpty {
            message += "\n\n⚠️ \(result.directoryIssues.count) original folder(s) no longer exist and will be recreated."
        }
        return message
    }

    func recordFeedback(_ outcome: LearningsManager.SessionOutcome, reason: String? = nil) {
        learningsManager.recordSessionOutcomeFeedback(
            sessionId: entry.id.uuidString,
            outcome: outcome,
            folderPath: entry.directoryPath,
            reason: reason
        )
        DebugLogger.log("Session feedback recorded: \(outcome.rawValue) for session \(entry.id.uuidString)")
    }

    func redoConfirmationMessage(_ result: PreflightValidationResult) -> String {
        var message = "This will reorganize \(result.availableCount) file(s) according to the original plan."
        if !result.missingFiles.isEmpty {
            message += "\n\n⚠️ \(result.missingFiles.count) file(s) are no longer available."
        }
        return message
    }

}

#Preview {
    HistoryView()
        .environmentObject(AppState())
        .environmentObject(FolderOrganizer())
        .environmentObject(SettingsViewModel())
        .frame(width: 900, height: 700)
}
