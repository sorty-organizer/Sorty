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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    @State private var iconAppeared = false
    @State private var titleAppeared = false
    @State private var timeSavedAppeared = false
    @State private var summaryAppeared = false
    @State private var buttonsAppeared = false
    @State private var historyLinkAppeared = false
    @State private var isHoveringHistoryLink = false
    @State private var showParticles = false
    @State private var glowPulseID = 0
    @State private var undoState: UndoPresentationState = .idle
    @State private var undoRestoredCount = 0
    @State private var undoSkippedCount = 0
    @State private var lastUndoneEntry: OrganizationHistoryEntry?
    @State private var isStorageSuggestionDismissed = false
    
    @State private var shouldShowFinalCounts = false

    private enum UndoPresentationState: Equatable {
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
    
    private var shouldShowStorageSuggestion: Bool {
        !isStorageSuggestionDismissed
            && mode != .renameOnly
            && totalFiles >= 50
            && storageLocationsManager.enabledLocations.isEmpty
    }

    private var primaryStatLabel: String {
        if undoState == .completed {
            return undoRestoredCount == 1 ? "File Restored" : "Files Restored"
        }

        switch mode {
        case .renameOnly: return renameCount == 1 ? "Name Changed" : "Names Changed"
        case .organize, .organizeAndRename: return totalFiles == 1 ? "File Moved" : "Files Moved"
        }
    }

    private var primaryStatValue: String {
        if undoState == .completed {
            return "\(undoRestoredCount)"
        }

        return "\(shouldShowFinalCounts ? primaryStatTarget : 0)"
    }

    private var secondaryStatValue: String {
        if undoState == .completed {
            // "0 Items Skipped" is noise; when nothing was skipped, show the
            // folders the undo cleaned up instead.
            if undoSkippedCount > 0 { return "\(undoSkippedCount)" }
            return mode == .renameOnly ? "\(renameCount)" : "\(totalFolders)"
        }

        return "\(shouldShowFinalCounts ? secondaryStatTarget : 0)"
    }

    private var secondaryStatLabel: String {
        if undoState == .completed {
            if undoSkippedCount > 0 {
                return undoSkippedCount == 1 ? "Item Skipped" : "Items Skipped"
            }
            if mode == .renameOnly {
                return renameCount == 1 ? "Name Reverted" : "Names Reverted"
            }
            return totalFolders == 1 ? "Folder Removed" : "Folders Removed"
        }

        switch mode {
        case .renameOnly: return max(totalFiles - renameCount, 0) == 1 ? "File Unchanged" : "Files Unchanged"
        case .organize, .organizeAndRename: return totalFolders == 1 ? "Folder Created" : "Folders Created"
        }
    }

    private var primaryStatTarget: Int {
        mode == .renameOnly ? renameCount : totalFiles
    }

    private var secondaryStatTarget: Int {
        mode == .renameOnly ? max(totalFiles - renameCount, 0) : totalFolders
    }

    private var combinedModeHighlight: (value: String, label: String, icon: String, color: Color)? {
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
                    VStack(spacing: usesCompactVerticalLayout ? 10 : 16) {
                        ZStack {
                            CompletionBadgeGlow(color: statusColor)
                                .phaseAnimator([false, true, false], trigger: glowPulseID) { content, isIntensified in
                                    content
                                        .scaleEffect(!reduceMotion && isIntensified ? 1.12 : 1)
                                        .brightness(isIntensified ? 0.08 : 0)
                                        .shadow(
                                            color: statusColor.opacity(isIntensified ? 0.65 : 0),
                                            radius: isIntensified ? 20 : 0
                                        )
                                } animation: { isIntensified in
                                    reduceMotion
                                        ? .linear(duration: 0.01)
                                        : isIntensified
                                            ? .spring(response: 0.2, dampingFraction: 0.68)
                                            : .easeOut(duration: 0.48)
                                }
                                .scaleEffect(iconAppeared ? 1 : 0.7)
                                .opacity(iconAppeared ? 1 : 0)

                            if showParticles {
                                ConfettiParticlesView()
                            }

                            ZStack {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 58, height: 58)

                                Image(systemName: statusIcon)
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundStyle(.white)
                                    .symbolReplaceTransition(animationValue: statusIcon)
                            }
                            .scaleEffect(iconAppeared ? 1 : 0.3)
                            .shadow(color: statusColor.opacity(0.42), radius: 12)
                        }
                        .scaleEffect(usesCompactVerticalLayout ? 0.84 : 1)
                        .frame(height: usesCompactVerticalLayout ? 92 : 112)
                        .contentShape(Circle())
                        .onTapGesture {
                            glowPulseID += 1
                            HapticFeedbackManager.shared.light()
                        }
                        .help("Click to intensify the glow")
                        .accessibilityHidden(true)
                        
                        VStack(spacing: usesCompactVerticalLayout ? 5 : 8) {
                            Text(statusTitle)
                                .font(.title.bold())
                                .opacity(titleAppeared ? 1 : 0)
                                .offset(y: titleAppeared ? 0 : 10)
                                .numericTextTransition(animationValue: statusTitle)

                            Text(statusMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .opacity(titleAppeared ? 1 : 0)
                                .offset(y: titleAppeared ? 0 : 10)
                                .numericTextTransition(animationValue: statusMessage)

                            let effectiveTimeSaved: TimeInterval = {
                                if let stats = stats, stats.estimatedTimeSaved > 0 {
                                    return stats.estimatedTimeSaved
                                }
                                return GenerationStats.estimatedTimeSaved(forFileCount: totalFiles)
                            }()
                            
                            if effectiveTimeSaved > 0 && undoState == .idle {
                                TimeSavedHighlight(
                                    value: timeSavedString(effectiveTimeSaved),
                                    animationValue: effectiveTimeSaved,
                                    usesCompactVerticalLayout: usesCompactVerticalLayout
                                )
                                .padding(.top, usesCompactVerticalLayout ? 2 : 8)
                                .opacity(timeSavedAppeared ? 1 : 0)
                                .offset(y: timeSavedAppeared ? 0 : 10)
                            }
                        }
                    }
                    
                    VStack(spacing: usesCompactVerticalLayout ? 12 : 18) {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(statusColor)

                            Text(undoState == .completed ? "Undo summary" : "Run summary")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)

                            Spacer()
                        }

                        HStack(spacing: 0) {
                            IconStatItem(
                                style: .completion,
                                icon: mode == .renameOnly ? "pencil.line" : "doc.on.doc.fill",
                                value: primaryStatValue,
                                label: primaryStatLabel,
                                color: .blue
                            )

                            IconStatDivider(height: 54)

                            IconStatItem(
                                style: .completion,
                                icon: mode == .renameOnly ? "doc.text" : "folder.fill.badge.plus",
                                value: secondaryStatValue,
                                label: secondaryStatLabel,
                                color: .purple
                            )

                            if mode == .organizeAndRename,
                               undoState != .completed,
                               let combinedModeHighlight {
                                IconStatDivider(height: 54)

                                IconStatItem(
                                    style: .completion,
                                    icon: combinedModeHighlight.icon,
                                    value: combinedModeHighlight.value,
                                    label: combinedModeHighlight.label,
                                    color: combinedModeHighlight.color
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, usesCompactVerticalLayout ? 13 : 18)
                    .frame(maxWidth: 560)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                    .opacity(summaryAppeared ? 1 : 0)
                    .offset(y: summaryAppeared ? 0 : 30)
                    
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
                    
                    VStack(spacing: usesCompactVerticalLayout ? 8 : 12) {
                        Button {
                            HapticFeedbackManager.shared.tap()
                            returnToStart()
                        } label: {
                            Label("Organise Another", systemImage: "folder.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.sortyPrimary(size: .large))
                        .onHover { hovering in
                            if hovering {
                                HapticFeedbackManager.shared.selection()
                            }
                        }
                        .help("Return to the folder picker to organise another folder")
                        .accessibilityHint("Returns to the folder picker to organise another folder")
                        .disabled(undoState.isBusy)

                        HStack(spacing: 12) {
                            if undoState == .completed || undoState.isRedoing {
                                Button {
                                    HapticFeedbackManager.shared.tap()
                                    redoLastOrganization()
                                } label: {
                                    if undoState.isRedoing {
                                        Label("Redoing...", systemImage: "arrow.triangle.2.circlepath")
                                            .frame(maxWidth: .infinity)
                                    } else {
                                        Label("Redo", systemImage: "arrow.uturn.forward")
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                                .buttonStyle(.sortyBordered(intent: .primary, size: .regular))
                                .onHover { hovering in
                                    if hovering {
                                        HapticFeedbackManager.shared.selection()
                                    }
                                }
                                .help("Reapply the organization you just undid")
                                .accessibilityHint("Reapplies the most recent organization plan")
                                .disabled(undoState.isRedoing || lastUndoneEntry == nil)
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                            } else {
                                Button {
                                    HapticFeedbackManager.shared.tap()
                                    undoLastOrganization()
                                } label: {
                                    if undoState.isUndoing {
                                        Label("Undoing...", systemImage: "arrow.triangle.2.circlepath")
                                            .frame(maxWidth: .infinity)
                                    } else {
                                        Label("Undo", systemImage: "arrow.uturn.backward")
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                                .buttonStyle(.sortyBordered(size: .regular))
                                .onHover { hovering in
                                    if hovering {
                                        HapticFeedbackManager.shared.selection()
                                    }
                                }
                                .help("Undo the latest organization for this folder")
                                .accessibilityHint("Restores files from the most recent successful run")
                                .disabled(undoState != .idle)
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                            }

                            Button {
                                HapticFeedbackManager.shared.tap()
                                NSWorkspace.shared.open(directoryURL)
                            } label: {
                                Label(mode == .renameOnly ? "Show Renamed Files" : "View in Finder", systemImage: "folder.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.sortyBordered(size: .regular))
                            .onHover { hovering in
                                if hovering {
                                    HapticFeedbackManager.shared.selection()
                                }
                            }
                            .help(mode == .renameOnly ? "Open the folder containing renamed files" : "Open the organized folder in Finder")
                            .accessibilityHint(mode == .renameOnly ? "Shows your renamed files in Finder" : "Shows your organized files in Finder")
                            .disabled(undoState.isBusy)
                        }
                    }
                    .frame(maxWidth: 560)
                    .opacity(buttonsAppeared ? 1 : 0)
                    .offset(y: buttonsAppeared ? 0 : 20)
                    
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
        .onAppear {
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

    private var statusIcon: String {
        switch undoState {
        case .idle:
            return "checkmark"
        case .undoing:
            return "arrow.uturn.backward"
        case .completed:
            return "checkmark"
        case .redoing:
            return "arrow.uturn.forward"
        case .failed:
            return "exclamationmark"
        }
    }

    private var statusColor: Color {
        switch undoState {
        case .idle:
            return .green
        case .undoing:
            return .blue
        case .completed:
            return .green
        case .redoing:
            return .blue
        case .failed:
            return .red
        }
    }

    private var statusTitle: String {
        switch undoState {
        case .idle:
            return mode.completionTitle
        case .undoing:
            return "Undoing Changes"
        case .completed:
            return "Undo Complete"
        case .redoing:
            return "Redoing Changes"
        case .failed:
            return "Undo Failed"
        }
    }

    private var statusMessage: String {
        switch undoState {
        case .idle:
            return mode.completionMessage
        case .undoing:
            return "Restoring files to their previous locations..."
        case .completed:
            return undoSkippedCount > 0
                ? "Restored what could be safely reverted. Review history for skipped items."
                : "Restored your files to their previous locations."
        case .redoing:
            return "Reapplying the organization plan..."
        case .failed:
            return "Sorty could not complete that action. Please review history for details."
        }
    }
    
    private func undoLastOrganization() {
        guard undoState == .idle else { return }
        guard let lastEntry = organizer.history.entries.first(where: { $0.directoryPath == directoryURL.path && $0.success && !$0.isUndone }) else { return }
        lastUndoneEntry = lastEntry
        organizer.pinsCompletionView = true

        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            undoState = .undoing
            showParticles = false
        }
        
        Task {
            do {
                let result = try await organizer.undoHistoryEntry(lastEntry)
                await MainActor.run {
                    undoRestoredCount = restoredDisplayCount(for: lastEntry, result: result)
                    undoSkippedCount = result.missingFiles.count
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                        undoState = .completed
                    }
                    HapticFeedbackManager.shared.success()
                    showUndoCompleteHUD()
                }
            } catch {
                await MainActor.run {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                        undoState = .failed
                    }
                    HapticFeedbackManager.shared.error()
                }
                print("Failed to undo organization: \(error)")

                try? await Task.sleep(for: .seconds(2))

                await MainActor.run {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                        undoState = .idle
                    }
                    lastUndoneEntry = nil
                }
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
        guard result.successfulOperations == 0, result.missingFiles.isEmpty else {
            return result.successfulOperations
        }

        let fileOperationCount = entry.operations?.filter { operation in
            operation.type == .moveFile || operation.type == .renameFile || operation.type == .copyFile
        }.count ?? 0

        return max(fileOperationCount, entry.filesOrganized)
    }

    private func redoLastOrganization() {
        guard undoState == .completed else { return }
        guard let entry = lastUndoneEntry else { return }
        organizer.pinsCompletionView = true

        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            undoState = .redoing
        }

        Task {
            do {
                try await organizer.redoOrganization(from: entry)
                await MainActor.run {
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
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                        undoState = .failed
                    }
                    HapticFeedbackManager.shared.error()
                }
                print("Failed to redo organization: \(error)")

                try? await Task.sleep(for: .seconds(2))

                await MainActor.run {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                        undoState = .completed
                    }
                }
            }
        }
    }

    private func returnToStart() {
        organizer.pinsCompletionView = false
        if let onReturnToStart {
            onReturnToStart()
        } else {
            withAnimation(.smooth(duration: 0.34)) {
                organizer.reset()
            }
        }
    }
    
    private func timeSavedString(_ seconds: TimeInterval) -> String {
        if seconds >= 3600 {
            let hours = seconds / 3600
            return String(format: "%.1f hours", hours)
        } else if seconds >= 60 {
            let minutes = seconds / 60
            return String(format: "%.0f minutes", minutes)
        } else {
            return String(format: "%.0f seconds", seconds)
        }
    }
}

private struct TimeSavedHighlight: View {
    @SortyHotReload private var hotReload
    let value: String
    let animationValue: TimeInterval
    let usesCompactVerticalLayout: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.secondary.opacity(0.1), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Estimated time saved")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .numericTextTransition(animationValue: animationValue)
            }

            Spacer(minLength: 12)

            Text("Manual work")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, usesCompactVerticalLayout ? 7 : 10)
        .frame(maxWidth: 340)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Estimated manual time saved: \(value)")
    }
}

private struct CompletionBadgeGlow: View {
    @SortyHotReload private var hotReload
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            color.opacity(0.34),
                            color.opacity(0.16),
                            color.opacity(0)
                        ],
                        center: .center,
                        startRadius: 22,
                        endRadius: 56
                    )
                )
                .frame(width: 112, height: 112)
                .scaleEffect(isBreathing ? 1.08 : 0.96)
                .opacity(isBreathing ? 0.9 : 0.68)

            Circle()
                .stroke(color.opacity(0.32), lineWidth: 9)
                .frame(width: 68, height: 68)
                .blur(radius: 10)
                .scaleEffect(isBreathing ? 1.04 : 0.98)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.16),
                            color.opacity(0.08),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.34, y: 0.3),
                        startRadius: 0,
                        endRadius: 46
                    )
                )
                .frame(width: 88, height: 88)
                .blur(radius: 8)
        }
        .frame(width: 112, height: 112)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }

            withAnimation(.easeInOut(duration: 1.4).repeatCount(2, autoreverses: true)) {
                isBreathing = true
            }
        }
    }
}

private struct ConfettiParticlesView: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Particle: Identifiable {
        let id = UUID()
        let angle: Double
        let distance: CGFloat
        let color: Color
        let size: CGFloat
        let delay: Double
    }
    
    @State private var burstedParticles: Set<UUID> = []
    
    private let particles: [Particle] = {
        let colors: [Color] = [.green, .blue, .purple, .orange, .yellow, .mint]
        return (0..<12).map { i in
            Particle(
                angle: Double(i) * 30 + Double.random(in: -10...10),
                distance: CGFloat.random(in: 50...80),
                color: colors[i % colors.count],
                size: CGFloat.random(in: 4...7),
                delay: Double.random(in: 0...0.25)
            )
        }
    }()
    
    var body: some View {
        ZStack {
            ForEach(particles) { particle in
                let isBursted = burstedParticles.contains(particle.id)
                Circle()
                    .fill(particle.color)
                    .frame(width: particle.size, height: particle.size)
                    .offset(
                        x: isBursted ? cos(particle.angle * .pi / 180) * particle.distance : 0,
                        y: isBursted ? sin(particle.angle * .pi / 180) * particle.distance : 0
                    )
                    .opacity(isBursted ? 0 : 0.8)
                    .scaleEffect(isBursted ? 0.3 : 1)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            for particle in particles {
                _ = withAnimation(.easeOut(duration: Double.random(in: 0.5...0.9)).delay(particle.delay)) {
                    burstedParticles.insert(particle.id)
                }
            }
        }
    }
}

private struct CompletionFeatureSuggestionCard: View {
    @SortyHotReload private var hotReload
    let icon: String
    let title: String
    let description: String
    let actionTitle: String
    let usesCompactVerticalLayout: Bool
    let onDismiss: () -> Void
    let action: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(LocalizedStringKey(description))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(description)
            }
            
            Spacer()
            
            Button(action: action) {
                Text(actionTitle)
                    .lineLimit(1)
                    .font(.subheadline.weight(.semibold))
            }
                .buttonStyle(.sortyBordered(intent: .primary, size: .small))
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
                .help("Open storage location settings")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss suggestion")
            .accessibilityLabel("Dismiss storage location suggestion")
        }
        .padding(usesCompactVerticalLayout ? 12 : 16)
        .systemLiquidGlassBackground(cornerRadius: 16)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), Color.white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 5)
        .help(description)
        .accessibilityElement(children: .contain)
    }
}
