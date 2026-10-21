//
//  OrganizationCompleteView.swift
//  Sorty
//
//  A dedicated completion view component for the organization workflow
//

import SwiftUI

struct OrganizationCompleteView: View {
    @SortyHotReload private var hotReload
    let stats: GenerationStats?
    let totalFiles: Int
    let totalFolders: Int
    let renameCount: Int
    let mode: OrganizationMode
    let directoryURL: URL
    let onReturnToStart: (() -> Void)?
    
    @EnvironmentObject var organizer: FolderOrganizer
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var storageLocationsManager: StorageLocationsManager
    @EnvironmentObject var learningsManager: LearningsManager
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    
    @State var iconAppeared = false
    @State var titleAppeared = false
    @State var timeSavedAppeared = false
    @State var summaryAppeared = false
    @State var buttonsAppeared = false
    @State private var historyLinkAppeared = false
    @State private var isHoveringHistoryLink = false
    @State var showParticles = false
    @State var glowPulseID = 0
    @State var undoState: UndoPresentationState = .idle
    @State var undoRestoredCount = 0
    @State var undoSkippedCount = 0
    @State var lastUndoneEntry: OrganizationHistoryEntry?
    @State var failureMessage: String?
    @State var failedAction: FailedAction?
    @State private var isStorageSuggestionDismissed = false
    /// True while an undo/redo failure from this view owns the completion
    /// screen. The organizer's `.error` transition clears the completion pin,
    /// which would swap this view's failure card for the generic ErrorView, so
    /// the pin is restored until the user leaves the failure.
    @State var keepsFailureCardPinned = false
    
    @State private var shouldShowFinalCounts = false
    @State var feedbackDraft = SessionFeedbackDraft()
    @State var feedbackSubmitted = false

    enum UndoPresentationState: Equatable {
        case idle
        case undoing
        case completed
        case redoing
        case failed

        var isUndoing: Bool {
            if case .undoing = self {
                return true
            }
            return false
        }

        var isRedoing: Bool {
            if case .redoing = self {
                return true
            }
            return false
        }

        var isBusy: Bool {
            isUndoing || isRedoing
        }
    }

    /// The action that produced the current `.failed` state, so the view can
    /// title the error and offer the matching retry button.
    enum FailedAction: Equatable {
        case undo
        case redo
    }
    
    private var shouldShowStorageSuggestion: Bool {
        !isStorageSuggestionDismissed
            && mode != .renameOnly
            && totalFiles >= 50
            && storageLocationsManager.enabledLocations.isEmpty
    }

    /// Folder count straight from the applied plan, which includes nested
    /// subfolders; the `totalFolders` input only counts top-level suggestions.
    private var resolvedTotalFolders: Int {
        organizer.currentPlan?.totalFolders ?? totalFolders
    }

    var primaryStatLabel: String {
        if undoState == .completed {
            return undoRestoredCount == 1 ? "File Restored" : "Files Restored"
        }

        switch mode {
        case .renameOnly: return renameCount == 1 ? "Name Changed" : "Names Changed"
        case .organize, .organizeAndRename: return totalFiles == 1 ? "File Moved" : "Files Moved"
        }
    }

    var primaryStatValue: String {
        if undoState == .completed {
            return "\(undoRestoredCount)"
        }

        return "\(shouldShowFinalCounts ? primaryStatTarget : 0)"
    }

    var secondaryStatValue: String {
        if undoState == .completed {
            // Nothing was reversed, so don't claim folder cleanup either.
            if undoRestoredCount == 0 && undoSkippedCount == 0 { return "0" }
            // "0 Items Skipped" is noise; when nothing was skipped, show the
            // folders the undo cleaned up instead.
            if undoSkippedCount > 0 { return "\(undoSkippedCount)" }
            return mode == .renameOnly ? "\(renameCount)" : "\(resolvedTotalFolders)"
        }

        return "\(shouldShowFinalCounts ? secondaryStatTarget : 0)"
    }

    var secondaryStatLabel: String {
        if undoState == .completed {
            if undoSkippedCount > 0 {
                return undoSkippedCount == 1 ? "Item Skipped" : "Items Skipped"
            }
            if mode == .renameOnly {
                return renameCount == 1 ? "Name Reverted" : "Names Reverted"
            }
            return resolvedTotalFolders == 1 ? "Folder Removed" : "Folders Removed"
        }

        switch mode {
        case .renameOnly: return max(totalFiles - renameCount, 0) == 1 ? "File Unchanged" : "Files Unchanged"
        case .organize, .organizeAndRename: return resolvedTotalFolders == 1 ? "Folder Created" : "Folders Created"
        }
    }

    private var primaryStatTarget: Int {
        mode == .renameOnly ? renameCount : totalFiles
    }

    private var secondaryStatTarget: Int {
        mode == .renameOnly ? max(totalFiles - renameCount, 0) : resolvedTotalFolders
    }

    /// Undo is actionable when there is no action in flight; a failed undo
    /// offers its retry, while a failed redo does not (the redo button owns
    /// that retry) so the undo button can never silently no-op.
    var canUndo: Bool {
        undoState == .idle || (undoState == .failed && failedAction == .undo)
    }

    /// Redo is actionable after a completed undo or as the retry of a failed
    /// redo.
    var canRedo: Bool {
        undoState == .completed || (undoState == .failed && failedAction == .redo)
    }

    var combinedModeHighlight: (value: String, label: String, icon: String, color: Color)? {
        if renameCount > 0 {
            return (
                "\(shouldShowFinalCounts ? renameCount : 0)",
                renameCount == 1 ? "Name Improved" : "Names Improved",
                "pencil.line",
                SortyDesignSystem.Colors.accent
            )
        }

        guard let totalFileSize = stats?.totalFileSize, totalFileSize > 0 else {
            return nil
        }

        return (
            shouldShowFinalCounts
                ? ByteCountFormatter.string(fromByteCount: totalFileSize, countStyle: .file)
                : "0 KB",
            "Data Organised",
            "internaldrive.fill",
            .green
        )
    }
    
    var body: some View {
        GeometryReader { proxy in
            let usesCompactVerticalLayout = proxy.size.height < 720

            ScrollView(showsIndicators: false) {
                VStack(spacing: usesCompactVerticalLayout ? 18 : 28) {
                    completionHero(usesCompactVerticalLayout: usesCompactVerticalLayout)

                    completionSummary(usesCompactVerticalLayout: usesCompactVerticalLayout)

                    completionFeedbackCard
                        .frame(maxWidth: 560)
                        .opacity(summaryAppeared ? 1 : 0)
                        .offset(y: summaryAppeared ? 0 : 20)

                    if let observer = organizer.learningsObserver {
                        InlineLearningMomentCard(observer: observer)
                            .frame(maxWidth: 560)
                    }

                    if shouldShowStorageSuggestion {
                        CompletionFeatureSuggestionCard(
                            icon: "externaldrive.fill",
                            title: "Route large runs to preferred destinations",
                            description: "Add storage locations to send future results directly into archive or project folders.",
                            actionTitle: "Set Up Locations",
                            usesCompactVerticalLayout: usesCompactVerticalLayout,
                            onDismiss: {
                                HapticFeedbackManager.shared.tap()
                                withAnimation(.easeOut(duration: 0.2)) {
                                    isStorageSuggestionDismissed = true
                                }
                            }
                        ) {
                            HapticFeedbackManager.shared.tap()
                            withAnimation(.pageTransition) {
                                appState.currentView = .organize
                            }
                        }
                        .frame(maxWidth: 560)
                        .opacity(summaryAppeared ? 1 : 0)
                        .offset(y: summaryAppeared ? 0 : 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    
                    completionActions(usesCompactVerticalLayout: usesCompactVerticalLayout)

                    Button {
                        HapticFeedbackManager.shared.tap()
                        appState.openRelatedView(.history)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "clock.arrow.circlepath")

                            Text("View History")

                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 10)
                                .opacity(isHoveringHistoryLink ? 1 : 0)
                                .offset(
                                    x: reduceMotion || isHoveringHistoryLink ? 0 : -3,
                                    y: reduceMotion || isHoveringHistoryLink ? 0 : 3
                                )
                                .scaleEffect(
                                    reduceMotion || isHoveringHistoryLink ? 1 : 0.75
                                )
                                .accessibilityHidden(true)
                        }
                        .font(.subheadline)
                        .foregroundStyle(
                            isHoveringHistoryLink
                                ? SortyDesignSystem.Colors.accent
                                : SortyDesignSystem.Colors.textSecondary
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82),
                        value: isHoveringHistoryLink
                    )
                    .onHover { hovering in
                        isHoveringHistoryLink = hovering
                        if hovering {
                            HapticFeedbackManager.shared.selection()
                        }
                    }
                    .help("Review this run and previous organization sessions")
                    .accessibilityHint("Opens organization history")
                    .padding(.top, -4)
                    .opacity(historyLinkAppeared ? 1 : 0)
                    .offset(y: historyLinkAppeared ? 0 : 10)
                    
                    if let stats = stats, settingsViewModel.config.showStatsForNerds, undoState == .idle {
                        OrganizationResultView(stats: stats)
                            .padding(.horizontal, 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: 640)
                .frame(minHeight: proxy.size.height - 40)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, usesCompactVerticalLayout ? 12 : 20)
            }
        }
        .background(WorkflowGradientBackground())
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: undoState)
        .onChange(of: undoState) { _, newState in
            if newState != .failed {
                keepsFailureCardPinned = false
            }
        }
        .onChange(of: organizer.state) { _, newState in
            // Once the organizer leaves .error (retry, regenerate, or a new
            // run) this view must stop restoring the failure pin so the new
            // plan/state can be presented.
            if case .error = newState { return }
            keepsFailureCardPinned = false
        }
        .onChange(of: organizer.pinsCompletionView) { _, isPinned in
            // The organizer unpins on `.error`, which would hide this view's
            // retry card behind the generic ErrorView. Restore the pin only
            // while the failure came from this view's own undo/redo task and
            // the organizer is still in `.error`; when it has moved on (e.g.
            // Regenerate reached `.ready`) the pin must stay cleared.
            guard keepsFailureCardPinned, !isPinned else { return }
            guard case .error = organizer.state else {
                keepsFailureCardPinned = false
                return
            }
            organizer.pinsCompletionView = true
        }
        .onAppear {
            restoreFailureCardIfNeeded()
            organizer.pinsCompletionView = true
            HapticFeedbackManager.shared.success()
            
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6).delay(0.1)) {
                iconAppeared = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if !reduceMotion {
                    showParticles = true
                }
            }
            
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8).delay(0.2)) {
                titleAppeared = true
            }
            
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8).delay(0.35)) {
                timeSavedAppeared = true
            }
            
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8).delay(0.5)) {
                summaryAppeared = true
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                withAnimation(reduceMotion ? nil : .spring(response: 0.58, dampingFraction: 0.86)) {
                    shouldShowFinalCounts = true
                }
                HapticFeedbackManager.shared.alignment()
            }
            
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8).delay(0.65)) {
                buttonsAppeared = true
            }
            
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8).delay(0.8)) {
                historyLinkAppeared = true
            }
        }
    }

}
