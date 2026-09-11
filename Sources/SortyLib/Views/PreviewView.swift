//
//  PreviewView.swift
//  Sorty
//
//  Lightweight container view for preview interface
//  Components split into Preview/ directory
//

import SwiftUI

struct PreviewView: View {
    @SortyHotReload private var hotReload
    let plan: OrganizationPlan
    let baseURL: URL
    let onReturnToStart: (() -> Void)?
    let onApplyStarted: (() -> Void)?
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var organizer: FolderOrganizer
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var learningsManager: LearningsManager
    @StateObject private var dragDropManager = DragDropManager()
    @StateObject private var previewStore: PreviewStore
    @State private var showApplyConfirmation = false
    @State private var isApplying = false
    @State private var editablePlan: OrganizationPlan
    @State private var hasEdits = false
    @State private var showRedoModelPicker = false
    @State private var isRedoingWithModel = false
    @State private var viewingHistoryIndex: Int? = nil
    @State private var activeNotificationApplyRequestID: UUID?
    @State private var activeNotificationRedoRequestID: UUID?
    @FocusState private var instructionsFocused: Bool

    private var displayedPlan: OrganizationPlan {
        Self.planForApply(
            editablePlan: editablePlan,
            history: organizer.planHistory,
            viewingHistoryIndex: viewingHistoryIndex
        )
    }

    static func planForApply(
        editablePlan: OrganizationPlan,
        history: [OrganizationPlan],
        viewingHistoryIndex: Int?
    ) -> OrganizationPlan {
        guard let viewingHistoryIndex, history.indices.contains(viewingHistoryIndex) else {
            return editablePlan
        }
        return history[viewingHistoryIndex]
    }

    private var isViewingHistory: Bool {
        viewingHistoryIndex != nil
    }

    private var totalVersions: Int {
        organizer.planHistory.count + 1
    }

    private var displayedVersionIndex: Int {
        viewingHistoryIndex ?? organizer.planHistory.count
    }

    private var currentDiffSource: OrganizationPlanDiff.Source? {
        if viewingHistoryIndex == nil, hasEdits {
            return OrganizationPlanDiff.Source(
                oldPlan: plan,
                newPlan: editablePlan,
                fromLabel: "Preview \(plan.version)",
                toLabel: "Edited"
            )
        }
        if displayedVersionIndex > 0 {
            return diff(from: displayedVersionIndex - 1, to: displayedVersionIndex)
        }
        return diff(from: displayedVersionIndex, to: displayedVersionIndex + 1)
    }

    private var previousDiffSource: OrganizationPlanDiff.Source? {
        guard displayedVersionIndex > 0 else { return nil }
        return diff(from: displayedVersionIndex - 1, to: displayedVersionIndex)
    }

    private var nextDiffSource: OrganizationPlanDiff.Source? {
        diff(from: displayedVersionIndex, to: displayedVersionIndex + 1)
    }
    
    private var renameCount: Int {
        displayedPlan.suggestions.reduce(0) { $0 + $1.renameCount }
    }
    private var shouldDisableButtons: Bool { isApplying || organizer.state == .scanning || organizer.state == .organizing }
    private var isOrganizing: Bool { isApplying || organizer.state == .applying }
    private var mode: OrganizationMode { settingsViewModel.config.mode }
    private var emptyStateType: PreviewListView.EmptyStateType {
        if displayedPlan.totalFiles == 0 { return .emptyDirectory }
        if displayedPlan.suggestions.isEmpty && !displayedPlan.unorganizedFiles.isEmpty { return .allUnorganized(displayedPlan.unorganizedFiles.count) }
        return .none
    }
    
    init(
        plan: OrganizationPlan,
        baseURL: URL,
        onReturnToStart: (() -> Void)? = nil,
        onApplyStarted: (() -> Void)? = nil
    ) {
        self.plan = plan; self.baseURL = baseURL
        self.onReturnToStart = onReturnToStart
        self.onApplyStarted = onApplyStarted
        _previewStore = StateObject(wrappedValue: PreviewStore(plan: plan))
        _editablePlan = State(initialValue: plan)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            PreviewHeaderView(
                version: displayedPlan.version,
                hasEdits: isViewingHistory ? false : hasEdits,
                notes: displayedPlan.notes,
                totalFiles: displayedPlan.totalFiles,
                totalFolders: displayedPlan.totalFolders,
                renameCount: isViewingHistory ? 0 : renameCount,
                totalVersions: totalVersions,
                isViewingHistory: isViewingHistory,
                currentDiffSource: currentDiffSource,
                previousDiffSource: previousDiffSource,
                nextDiffSource: nextDiffSource,
                onPreviousVersion: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        if let idx = viewingHistoryIndex {
                            if idx > 0 {
                                viewingHistoryIndex = idx - 1
                            }
                        } else if !organizer.planHistory.isEmpty {
                            viewingHistoryIndex = organizer.planHistory.count - 1
                        }
                    }
                },
                onNextVersion: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        if let idx = viewingHistoryIndex {
                            if idx >= organizer.planHistory.count - 1 {
                                viewingHistoryIndex = nil
                            } else {
                                viewingHistoryIndex = idx + 1
                            }
                        }
                    }
                }
            )
            if settingsViewModel.config.showStatsForNerds {
                PreviewStatsView(stats: displayedPlan.generationStats, showStatsForNerds: true, estimatedTimeRemaining: nil, currentFile: Int(organizer.progress * Double(displayedPlan.totalFiles)), totalFiles: displayedPlan.totalFiles, stage: organizer.organizationStage)
            }
            Divider()
            PreviewListView(
                store: previewStore,
                dragDropManager: dragDropManager,
                onPlanChanged: {
                    hasEdits = true
                    editablePlan = previewStore.plan
                },
                emptyStateType: emptyStateType,
                onFocusInstructions: { instructionsFocused = true },
                onRegenerate: regeneratePreview,
                onChooseFolder: {
                    HapticFeedbackManager.shared.selection()
                    appState.showDirectoryPicker = true
                },
                onExitPreview: exitPreview
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomToolbar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .numericTextTransition(animationValue: plan)
        .accessibilityIdentifier("OrganizationPreviewScreen")
        .alert("Apply \(mode.actionVerb)?", isPresented: $showApplyConfirmation) {
            Button("Cancel", role: .cancel) {
                if let requestID = activeNotificationApplyRequestID {
                    NotificationManager.shared.recordActionLifecycle("apply", stage: "cancelled", detail: "preview confirmation")
                    activeNotificationApplyRequestID = nil
                    appState.clearNotificationActionRequest(id: requestID)
                }
            }
            Button("Apply") {
                if activeNotificationApplyRequestID != nil {
                    NotificationManager.shared.recordActionLifecycle("apply", stage: "confirmed", detail: "preview confirmation")
                }
                applyOrganization()
            }
        } message: { Text(applyConfirmationMessage) }
        .onChange(of: organizer.state) { _, newState in
            if case .completed = newState {
                isApplying = false
                if activeNotificationApplyRequestID != nil {
                    NotificationManager.shared.recordActionLifecycle("apply", stage: "completed", detail: baseURL.path)
                    activeNotificationApplyRequestID = nil
                }
            } else if case .error(let error) = newState {
                isApplying = false
                if activeNotificationApplyRequestID != nil {
                    NotificationManager.shared.recordActionLifecycle("apply", stage: "failed", failed: true, detail: error.localizedDescription)
                    activeNotificationApplyRequestID = nil
                }
            }
        }
        .onAppear {
            previewStore.dragDropManager = dragDropManager
            previewStore.learningsManager = learningsManager
            learningsManager.loadProfileIfNeededForCollection()
            consumePendingNotificationActionIfNeeded()
        }
        .onChange(of: plan) { _, newPlan in editablePlan = newPlan; previewStore.updatePlan(newPlan); previewStore.resetEditsCaptured(); hasEdits = false }
        .onChange(of: viewingHistoryIndex) { _, newIndex in
            if let idx = newIndex, idx < organizer.planHistory.count {
                previewStore.updatePlan(organizer.planHistory[idx])
            } else {
                previewStore.updatePlan(editablePlan)
            }
        }
        .onChange(of: appState.pendingNotificationActionRequest?.id) { _, _ in
            consumePendingNotificationActionIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .redoOrganizationWithModel)) { notification in
            guard notification.targetsWindowSession(appState.windowSessionID) else { return }
            guard organizer.state == .ready else { return }
            showRedoModelPicker = true
        }
        .onChange(of: showRedoModelPicker) { oldValue, newValue in
            guard oldValue, !newValue, activeNotificationRedoRequestID != nil else { return }
            NotificationManager.shared.recordActionLifecycle("redo_with_model", stage: "cancelled", detail: "preview picker")
            activeNotificationRedoRequestID = nil
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
                redoWithProviderAndModel(provider, model)
            },
            isSubscriptionSelected: settingsViewModel.config.authMethod(for: settingsViewModel.config.provider) == .accountSignIn
        )
        .environmentObject(dragDropManager)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func diff(from oldIndex: Int, to newIndex: Int) -> OrganizationPlanDiff.Source? {
        let versions = organizer.planHistory + [editablePlan]
        guard versions.indices.contains(oldIndex), versions.indices.contains(newIndex) else { return nil }
        return OrganizationPlanDiff.Source(
            oldPlan: versions[oldIndex],
            newPlan: versions[newIndex],
            fromLabel: "Preview \(versions[oldIndex].version)",
            toLabel: "Preview \(versions[newIndex].version)"
        )
    }
    
    @ViewBuilder
    private var bottomToolbar: some View {
        VStack(spacing: 0) {
            if !isOrganizing {
                PreviewInstructionsRow(instructions: $organizer.customInstructions, isFocused: _instructionsFocused, onInstructionsChanged: handleInstructionsChanged)
                Divider()
            }
            if isOrganizing {
                PreviewProgressView(progress: organizer.progress, stage: organizer.organizationStage, estimatedTimeRemaining: calculateTimeRemaining(), onCancel: cancelToStart)
            } else {
                PreviewActionsView(
                    isApplying: isApplying,
                    hasEdits: hasEdits,
                    hasCustomInstructions: !organizer.customInstructions.isEmpty,
                    isRedoingWithModel: isRedoingWithModel,
                    shouldDisableButtons: shouldDisableButtons,
                    editsCapturedCount: previewStore.editsCapturedCount,
                    editsCapturedPulse: previewStore.editCapturedPulse,
                    mode: mode,
                    onCancel: { recordCancelledOrganization(); cancelToStart() },
                    onReset: { HapticFeedbackManager.shared.tap(); editablePlan = plan; previewStore.updatePlan(plan); previewStore.resetEditsCaptured(); hasEdits = false },
                    onRegenerate: regeneratePreview,
                    onChooseModel: { showRedoModelPicker = true },
                    onApply: { HapticFeedbackManager.shared.tap(); showApplyConfirmation = true }
                )
            }
        }
    }
    
    private func handleInstructionsChanged(_ newValue: String) {
        if !newValue.isEmpty && learningsManager.consentManager.canCollectData { NotificationCenter.default.post(name: .steeringPromptProvided, object: nil, userInfo: ["prompt": newValue, "folderPath": baseURL.path]) }
    }

    private var applyConfirmationMessage: String {
        switch mode {
        case .renameOnly:
            return "\(renameCount) suggested name changes will be applied in place. \(displayedPlan.unorganizedFiles.count) files will be left unchanged."
        case .organizeAndRename:
            return "\(displayedPlan.totalFiles) files will be organized, with \(renameCount) name changes. \(displayedPlan.unorganizedFiles.count) files will remain in place."
        case .organize:
            return "\(displayedPlan.totalFiles) files will be organized. \(displayedPlan.unorganizedFiles.count) files will remain in place."
        }
    }
    
    private func regeneratePreview() {
        if !organizer.customInstructions.isEmpty,
           !LearningsManager.instructionsExcludeCurrentRun(organizer.customInstructions),
           learningsManager.consentManager.canCollectData {
            learningsManager.recordGuidingInstruction(organizer.customInstructions)
        }
        Task {
            do {
                try await organizer.regeneratePreview()
            } catch is CancellationError {
                return
            } catch {
                organizer.state = .error(error)
            }
        }
    }
    
    private func redoWithProviderAndModel(_ provider: AIProvider, _ model: String) {
        showRedoModelPicker = false; isRedoingWithModel = true; HapticFeedbackManager.shared.tap()
        if activeNotificationRedoRequestID != nil {
            NotificationManager.shared.recordActionLifecycle("redo_with_model", stage: "confirmed", detail: "\(provider.displayName):\(model)")
            NotificationManager.shared.recordActionLifecycle("redo_with_model", stage: "executing", detail: baseURL.path)
        }
        Task {
            do {
                try await organizer.regenerateWithModel(provider: provider, model: model)
                await MainActor.run {
                    HapticFeedbackManager.shared.success()
                    isRedoingWithModel = false
                    if activeNotificationRedoRequestID != nil {
                        NotificationManager.shared.recordActionLifecycle("redo_with_model", stage: "completed", detail: "\(provider.displayName):\(model)")
                        activeNotificationRedoRequestID = nil
                    }
                }
            }
            catch is CancellationError {
                isRedoingWithModel = false
            } catch {
                await MainActor.run {
                    HapticFeedbackManager.shared.error()
                    isRedoingWithModel = false
                    if activeNotificationRedoRequestID != nil {
                        NotificationManager.shared.recordActionLifecycle("redo_with_model", stage: "failed", failed: true, detail: error.localizedDescription)
                        activeNotificationRedoRequestID = nil
                    }
                    organizer.state = .error(error)
                }
            }
        }
    }
    
    private func applyOrganization() {
        let planToApply = displayedPlan
        isApplying = true
        organizer.currentPlan = planToApply
        onApplyStarted?()
        if activeNotificationApplyRequestID != nil {
            NotificationManager.shared.recordActionLifecycle("apply", stage: "executing", detail: baseURL.path)
        }
        let resolvedURL = appState.resolveSelectedDirectoryWithAccess() ?? baseURL
        Task { @MainActor in
            do {
                try await organizer.apply(at: resolvedURL, dryRun: false, enableTagging: settingsViewModel.config.enableFileTagging)
                if case .completed = organizer.state {
                    // Record accepted placements only after the apply actually completed,
                    // so failed or cancelled applies don't write false positive examples.
                    recordAcceptedPlacements(from: planToApply)
                    isApplying = false
                }
            } catch is CancellationError {
                isApplying = false
            } catch {
                organizer.state = .error(error)
                isApplying = false
            }
        }
    }

    private func consumePendingNotificationActionIfNeeded() {
        guard let request = appState.pendingNotificationActionRequest else { return }
        guard request.folderPath == nil || URL(fileURLWithPath: request.folderPath!).standardizedFileURL == baseURL.standardizedFileURL else {
            return
        }
        guard organizer.state == .ready else { return }

        switch request.kind {
        case .applyConfirmation:
            activeNotificationApplyRequestID = request.id
            NotificationManager.shared.recordActionLifecycle("apply", stage: "confirmation_shown", detail: baseURL.path)
            showApplyConfirmation = true
        case .redoWithModelConfirmation:
            guard request.notificationType == "previewReady" else { return }
            activeNotificationRedoRequestID = request.id
            NotificationManager.shared.recordActionLifecycle("redo_with_model", stage: "confirmation_shown", detail: baseURL.path)
            showRedoModelPicker = true
        }

        appState.clearNotificationActionRequest(id: request.id)
    }
    
    /// Record accepted file placements and rename decisions after a successful apply
    private func recordAcceptedPlacements(from appliedPlan: OrganizationPlan) {
        guard learningsManager.consentManager.canCollectData else { return }
        var remainingLearningExamples = 2_000
        
        func processFolder(_ folder: FolderSuggestion, parentPath: String) {
            guard remainingLearningExamples > 0 else { return }
            let folderPath = parentPath.isEmpty ? folder.folderName : "\(parentPath)/\(folder.folderName)"
            for file in folder.files {
                guard remainingLearningExamples > 0 else { break }
                remainingLearningExamples -= 1
                let destPath = "\(folderPath)/\(file.displayName)"
                learningsManager.addPositiveExample(srcPath: file.path, dstPath: destPath)
                
                // Record accepted renames
                if let mapping = previewStore.renameMappings[file.id], mapping.hasRename {
                    learningsManager.recordRenameFeedback(
                        originalName: file.displayName,
                        suggestedName: mapping.suggestedName,
                        finalName: mapping.suggestedName,
                        folderPath: folderPath,
                        action: .accept,
                        confidence: mapping.renameConfidence
                    )
                }
            }
            for subfolder in folder.subfolders {
                guard remainingLearningExamples > 0 else { break }
                processFolder(subfolder, parentPath: folderPath)
            }
        }
        
        for suggestion in appliedPlan.suggestions {
            guard remainingLearningExamples > 0 else { break }
            processFolder(suggestion, parentPath: "")
        }
    }
    
    private func calculateTimeRemaining() -> TimeInterval? {
        let remaining = editablePlan.totalFiles - Int(organizer.progress * Double(editablePlan.totalFiles))
        guard remaining > 0, organizer.progress > 0 else { return nil }
        return Double(remaining) * 0.3
    }
    
    private func recordCancelledOrganization() {
        let folderNames = editablePlan.suggestions.map { $0.folderName }
        let allFiles = editablePlan.suggestions.flatMap { $0.files }
        let extensionCounts = Dictionary(grouping: allFiles, by: { (file: FileItem) in
            file.extension.lowercased()
        }).mapValues { (files: [FileItem]) in
            files.count
        }
        learningsManager.recordCancelledOrganization(
            folderPath: baseURL.path,
            fileCount: editablePlan.totalFiles,
            proposedFolderCount: editablePlan.totalFolders,
            instructions: organizer.customInstructions.isEmpty ? nil : organizer.customInstructions,
            stage: "preview",
            proposedFolderNames: folderNames.isEmpty ? nil : folderNames,
            fileExtensionCounts: extensionCounts.isEmpty ? nil : extensionCounts,
            aiModel: settingsViewModel.config.model
        )
    }

    private func cancelToStart() {
        if let onReturnToStart {
            onReturnToStart()
        } else {
            withAnimation(.smooth(duration: 0.34)) {
                organizer.cancel()
            }
        }
    }

    private func exitPreview() {
        HapticFeedbackManager.shared.tap()
        if let onReturnToStart {
            onReturnToStart()
        } else {
            withAnimation(.smooth(duration: 0.34)) {
                organizer.reset()
            }
        }
    }
}
