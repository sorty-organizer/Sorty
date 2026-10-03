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
    // Memoized rename/diff derivations. The body observes the organizer, so
    // without this every organizer publish would rebuild the planHistory
    // arrays and reduce the rename mappings, even for unrelated state.
    @State private var memoizedRenameCount: Int
    @State private var memoizedCurrentDiff: OrganizationPlanDiff.Source?
    @State private var memoizedPreviousDiff: OrganizationPlanDiff.Source?
    @State private var memoizedNextDiff: OrganizationPlanDiff.Source?
    // Quality/confidence derivations for the displayed plan. Refreshed in
    // refreshDerivedPlanStats alongside the rename count.
    @State private var memoizedLowConfidenceCount: Int
    @State private var memoizedHiddenFileCount: Int
    @State private var memoizedCollisionGroups: [FilenameCollisionGroup]
    @State private var memoizedStorageDestinationCount: Int

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
        memoizedCurrentDiff
    }

    private var previousDiffSource: OrganizationPlanDiff.Source? {
        memoizedPreviousDiff
    }

    private var nextDiffSource: OrganizationPlanDiff.Source? {
        memoizedNextDiff
    }

    private var renameCount: Int {
        memoizedRenameCount
    }
    private var shouldDisableButtons: Bool { isApplying || organizer.state == .scanning || organizer.state == .organizing }
    private var isOrganizing: Bool { isApplying || organizer.state == .applying }
    private var mode: OrganizationMode { settingsViewModel.config.mode }
    private var emptyStateType: PreviewListView.EmptyStateType {
        if displayedPlan.totalFiles == 0 { return .emptyDirectory }
        if displayedPlan.suggestions.isEmpty && !displayedPlan.unorganizedFiles.isEmpty {
            return .allUnorganized(count: displayedPlan.unorganizedFiles.count, reasons: displayedPlan.unorganizedDetails)
        }
        return .none
    }

    /// True when the apply button and confirmation should warn: quality
    /// below passing, flagged renames, collisions, an incomplete parse, or a
    /// stale history version being applied.
    private var applyWarningActive: Bool {
        isViewingHistory
            || displayedPlan.isPartial
            || displayedPlan.needsReview
            || (displayedPlan.qualityAssessment.map { !$0.passes } ?? false)
            || memoizedLowConfidenceCount > 0
            || !memoizedCollisionGroups.isEmpty
    }

    /// Unresolved 3+-way name conflicts block Apply until each file has a
    /// unique name. Two-way conflicts auto-rename safely and never block.
    private var applyBlockedReason: String? {
        guard !isViewingHistory else { return nil }
        guard let blocking = memoizedCollisionGroups.first(where: \.isBlocking) else { return nil }
        return "\"\(blocking.collidingName)\" is claimed by \(blocking.files.count) files in "
            + "\(blocking.folderPath) — accept an inline suggestion for each file before applying."
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
        _memoizedRenameCount = State(initialValue: plan.suggestions.reduce(0) { $0 + $1.renameCount })
        _memoizedLowConfidenceCount = State(initialValue: PreviewPlanInsights.flaggableRenames(in: plan).count)
        _memoizedHiddenFileCount = State(initialValue: PreviewPlanInsights.hiddenFileCount(in: plan))
        _memoizedCollisionGroups = State(initialValue: PreviewPlanInsights.collisionGroups(in: plan))
        _memoizedStorageDestinationCount = State(initialValue: PreviewPlanInsights.storageDestinationCount(in: plan))
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
                },
                qualityAssessment: displayedPlan.qualityAssessment,
                lowConfidenceRenameCount: memoizedLowConfidenceCount
            )
            if settingsViewModel.config.showStatsForNerds {
                PreviewStatsView(stats: displayedPlan.generationStats, showStatsForNerds: true, estimatedTimeRemaining: nil, currentFile: currentFileProgress(for: displayedPlan.totalFiles), totalFiles: displayedPlan.totalFiles, stage: organizer.organizationStage)
            }
            Divider()
            previewNotices
            PreviewListView(
                store: previewStore,
                dragDropManager: dragDropManager,
                onPlanChanged: {
                    hasEdits = true
                    editablePlan = previewStore.plan
                    refreshDerivedPlanStats()
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
            previewStore.learningsManager = learningsManager
            refreshDerivedPlanStats()
            consumePendingNotificationActionIfNeeded()
        }
        .task {
            await learningsManager.loadProfileIfNeededForCollectionAsync()
            await loadExistingFolderPathsForRescore()
        }
        .onChange(of: previewStore.plan.qualityAssessment) { _, _ in
            // Debounced off-main re-score landed: sync the edited plan so the
            // Quality badge updates. User edits already sync via onPlanChanged,
            // so this only fires for quality-only refreshes.
            guard viewingHistoryIndex == nil else { return }
            editablePlan = previewStore.plan
            refreshDerivedPlanStats()
        }
        .onChange(of: plan) { _, newPlan in
            viewingHistoryIndex = nil
            editablePlan = newPlan
            previewStore.updatePlan(newPlan)
            previewStore.resetEditsCaptured()
            hasEdits = false
            refreshDerivedPlanStats()
        }
        .onChange(of: viewingHistoryIndex) { _, newIndex in
            if let idx = newIndex, idx < organizer.planHistory.count {
                previewStore.updatePlan(organizer.planHistory[idx])
            } else {
                previewStore.updatePlan(editablePlan)
            }
            refreshDerivedPlanStats()
        }
        .onChange(of: organizer.planHistory) { _, history in
            if let viewingHistoryIndex, !history.indices.contains(viewingHistoryIndex) {
                self.viewingHistoryIndex = nil
                previewStore.updatePlan(editablePlan)
            }
            refreshDerivedPlanStats()
        }
        .onChange(of: hasEdits) { _, _ in
            refreshDerivedPlanStats()
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

    // How derived plan stats stay fresh: recomputed only when the plan, its
    // history, the viewed version, or the edit flag changes — never on
    // unrelated organizer publishes (progress ticks, stage strings).
    private func refreshDerivedPlanStats() {
        let shown = displayedPlan
        memoizedRenameCount = shown.suggestions.reduce(0) { $0 + $1.renameCount }
        memoizedLowConfidenceCount = PreviewPlanInsights.flaggableRenames(in: shown).count
        memoizedHiddenFileCount = PreviewPlanInsights.hiddenFileCount(in: shown)
        memoizedCollisionGroups = PreviewPlanInsights.collisionGroups(in: shown)
        memoizedStorageDestinationCount = PreviewPlanInsights.storageDestinationCount(in: shown)
        if viewingHistoryIndex == nil, hasEdits {
            memoizedCurrentDiff = OrganizationPlanDiff.Source(
                oldPlan: plan,
                newPlan: editablePlan,
                fromLabel: "Preview \(plan.version)",
                toLabel: "Edited"
            )
        } else if displayedVersionIndex > 0 {
            memoizedCurrentDiff = diff(from: displayedVersionIndex - 1, to: displayedVersionIndex)
        } else {
            memoizedCurrentDiff = diff(from: displayedVersionIndex, to: displayedVersionIndex + 1)
        }
        memoizedPreviousDiff = displayedVersionIndex > 0
            ? diff(from: displayedVersionIndex - 1, to: displayedVersionIndex)
            : nil
        memoizedNextDiff = diff(from: displayedVersionIndex, to: displayedVersionIndex + 1)
    }
    
    /// Inline warnings above the file tree: an incomplete parse, a stale
    /// history version, or a truncated preview must never look complete.
    @ViewBuilder
    private var previewNotices: some View {
        if displayedPlan.isPartial || displayedPlan.needsReview || isViewingHistory || memoizedHiddenFileCount > 0 || !memoizedCollisionGroups.isEmpty {
            VStack(spacing: 8) {
                if displayedPlan.isPartial || displayedPlan.needsReview {
                    noticeRow(
                        icon: "exclamationmark.triangle.fill",
                        color: .orange,
                        title: "Review incomplete plan",
                        text: partialNoticeText,
                        accessibilityID: "PartialPlanNotice",
                        actionTitle: "Regenerate",
                        actionID: "PartialPlanRegenerateButton",
                        action: regeneratePreview
                    )
                }
                if isViewingHistory {
                    noticeRow(
                        icon: "clock.arrow.circlepath",
                        color: .blue,
                        title: "Earlier preview",
                        text: "Viewing older preview v\(displayedPlan.version) of \(totalVersions) — Apply uses this version and discards current edits.",
                        accessibilityID: "StaleHistoryNotice",
                        actionTitle: "Return to latest",
                        actionID: "ReturnToLatestButton",
                        action: {
                            HapticFeedbackManager.shared.selection()
                            viewingHistoryIndex = nil
                        }
                    )
                }
                if !memoizedCollisionGroups.isEmpty {
                    noticeRow(
                        icon: "exclamationmark.triangle.fill",
                        color: .orange,
                        title: "Duplicate filenames",
                        text: collisionNoticeText,
                        accessibilityID: "FilenameCollisionNotice",
                        actionTitle: "Resolve all",
                        actionID: "FixAllCollisionsButton",
                        action: fixAllCollisions
                    )
                }
                if memoizedHiddenFileCount > 0 {
                    noticeRow(
                        icon: "eye.slash.fill",
                        color: .secondary,
                        title: "Showing a limited preview",
                        text: "Preview hides \(memoizedHiddenFileCount) files for performance — Apply includes all \(displayedPlan.totalFiles) files.",
                        accessibilityID: "TruncatedPreviewNotice",
                        actionTitle: nil,
                        actionID: nil,
                        action: nil
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var partialNoticeText: String {
        let count = displayedPlan.parseWarnings.count
        if count > 0 {
            return "\(count) parse warning\(count == 1 ? "" : "s"). Regenerate the plan or review the files before applying."
        }
        return "Some files may be missing from this plan. Regenerate or review the files before applying."
    }

    /// Collision notice: blocking 3+-way conflicts name the file and pause
    /// Apply; two-way conflicts auto-rename with inline suggestions.
    private var collisionNoticeText: String {
        let blocking = memoizedCollisionGroups.filter(\.isBlocking)
        if let first = blocking.first {
            return "\"\(first.collidingName)\" is claimed by \(first.files.count) files in "
                + "\(first.folderPath). Give each file a unique name to enable Apply."
        }
        let files = memoizedCollisionGroups.reduce(0) { $0 + $1.files.count }
        return "\(files) files share destination names. Choose the suggested names below or resolve them all. Apply will otherwise rename them automatically."
    }

    /// Applies every pending uniquified suggestion, then re-syncs the plan.
    private func fixAllCollisions() {
        HapticFeedbackManager.shared.success()
        previewStore.acceptAllCollisionSuggestions()
        hasEdits = true
        editablePlan = previewStore.plan
        refreshDerivedPlanStats()
    }

    private func noticeRow(
        icon: String,
        color: Color,
        title: String,
        text: String,
        accessibilityID: String,
        actionTitle: String?,
        actionID: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle) { action() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityIdentifier(actionID ?? "")
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityIdentifier(accessibilityID)
    }

    @ViewBuilder
    private var bottomToolbar: some View {
        VStack(spacing: 0) {
            if !isOrganizing {
                PreviewInstructionsRow(instructions: $organizer.customInstructions, isFocused: _instructionsFocused, onInstructionsChanged: handleInstructionsChanged)
                Divider()
            }
            if isOrganizing {
                PreviewProgressView(
                    progress: organizer.progress,
                    stage: organizer.organizationStage,
                    estimatedTimeRemaining: calculateTimeRemaining(),
                    onCancel: cancelToStart,
                    // TODO(perf/rendering): source from FolderOrganizer as an
                    // explicit isAIWaiting Bool (read-only hook). The organizer
                    // is intentionally not edited here.
                    isAIWaiting: false
                )
            } else {
                PreviewActionsView(
                    isApplying: isApplying,
                    hasEdits: hasEdits,
                    hasCustomInstructions: !organizer.customInstructions.isEmpty,
                    isRedoingWithModel: isRedoingWithModel,
                    shouldDisableButtons: shouldDisableButtons,
                    editsCapturedCount: previewStore.editsCapturedCount,
                    mode: mode,
                    showsApplyWarning: applyWarningActive,
                    applyBlockedReason: applyBlockedReason,
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

    /// Caches on-disk folders for edit re-scores (convention-match context).
    /// Runs once off-main; until it lands, re-scores fall back to no context.
    private func loadExistingFolderPathsForRescore() async {
        do {
            let paths = try await PlanQualityEvaluator.existingFolderPathsOffMain(at: baseURL)
            previewStore.setExistingFolderPaths(paths)
        } catch {
            // Re-scores fall back to no convention context.
            return
        }
    }

    private var applyConfirmationMessage: String {
        let planToApply = displayedPlan
        let base: String
        switch mode {
        case .renameOnly:
            base = "\(renameCount) suggested name changes will be applied in place. \(planToApply.unorganizedFiles.count) files will be left unchanged."
        case .organizeAndRename:
            base = "\(planToApply.totalFiles) files will be organized, with \(renameCount) name changes. \(planToApply.unorganizedFiles.count) files will remain in place."
        case .organize:
            base = "\(planToApply.totalFiles) files will be organized. \(planToApply.unorganizedFiles.count) files will remain in place."
        }

        var extras: [String] = []
        if isViewingHistory {
            extras.append("You are viewing older preview v\(planToApply.version) of \(totalVersions) — applying it discards your current edits.")
        }
        if planToApply.isPartial || planToApply.needsReview {
            let warningCount = planToApply.parseWarnings.count
            extras.append(warningCount > 0
                ? "This plan is incomplete (\(warningCount) parse warnings) — review it before applying."
                : "This plan is incomplete — review it before applying.")
        }
        if let quality = planToApply.qualityAssessment, !quality.passes {
            extras.append("Quality score is \(quality.score)/100 (below passing \(PlanQualityAssessment.passingScore)) with \(quality.issues.count) issues — see the Quality badge.")
        }
        if mode != .renameOnly {
            let split = folderCreationSplit(for: planToApply)
            if split.new > 0 || split.existing > 0 {
                extras.append("\(split.new) new top-level folders will be created (\(split.existing) already exist).")
            }
            if memoizedStorageDestinationCount > 0 {
                extras.append("\(memoizedStorageDestinationCount) folders target external storage locations.")
            }
        }
        extras.append(contentsOf: PreviewPlanInsights.collisionConfirmationLines(groups: memoizedCollisionGroups))
        if memoizedLowConfidenceCount > 0 {
            extras.append("\(memoizedLowConfidenceCount) renames have medium or low confidence and are flagged inline.")
        }
        if memoizedHiddenFileCount > 0 {
            extras.append("The preview hides \(memoizedHiddenFileCount) files for performance; apply includes all \(planToApply.totalFiles) files.")
        }
        return ([base] + extras).joined(separator: " ")
    }

    /// New-vs-existing split for top-level relative folders, checked against
    /// the live filesystem at confirmation time. Cheap: a handful of stat
    /// calls, only when the confirmation message is built.
    private func folderCreationSplit(for planToApply: OrganizationPlan) -> (new: Int, existing: Int) {
        let fileManager = FileManager.default
        var new = 0
        var existing = 0
        for suggestion in planToApply.suggestions where !suggestion.folderName.hasPrefix("/") {
            let url = baseURL.appendingPathComponent(suggestion.folderName, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                existing += 1
            } else {
                new += 1
            }
        }
        return (new, existing)
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
    
    private func currentFileProgress(for totalFiles: Int) -> Int {
        guard totalFiles > 0, organizer.progress.isFinite else { return 0 }
        let progress = min(max(organizer.progress, 0), 1)
        guard progress < 1 else { return totalFiles }
        return Int(progress * Double(totalFiles))
    }

    private func calculateTimeRemaining() -> TimeInterval? {
        let progress = organizer.progress
        guard progress.isFinite, progress > 0, editablePlan.totalFiles > 0 else { return nil }
        let completed = currentFileProgress(for: editablePlan.totalFiles)
        let remaining = editablePlan.totalFiles - completed
        guard remaining > 0 else { return nil }
        // Whole seconds: fractional churn would relabel the eta every tick.
        return (Double(remaining) * 0.3).rounded()
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
