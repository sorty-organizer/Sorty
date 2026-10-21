import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Watched Folder Card

struct WatchedFolderCard: View {
    @SortyHotReload private var hotReload
    enum AccessRecoveryError: Identifiable {
        case incorrectFolder(selectedName: String)
        case bookmarkCreationFailed

        var id: String {
            switch self {
            case .incorrectFolder:
                return "incorrect-folder"
            case .bookmarkCreationFailed:
                return "bookmark-creation-failed"
            }
        }

        var title: String {
            switch self {
            case .incorrectFolder:
                return "Choose the Original Folder"
            case .bookmarkCreationFailed:
                return "Access Couldn’t Be Saved"
            }
        }

        func message(for expectedName: String) -> String {
            switch self {
            case .incorrectFolder(let selectedName):
                return "Sorty expected \"\(expectedName)\", but you selected \"\(selectedName)\". No folder was changed. Choose \"\(expectedName)\" to restore access."
            case .bookmarkCreationFailed:
                return "Sorty couldn’t save access to \"\(expectedName)\". No folder was changed. Please try again."
            }
        }
    }

    let folder: WatchedFolder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @EnvironmentObject var watchedFoldersManager: WatchedFoldersManager
    @EnvironmentObject var organizer: FolderOrganizer
    @EnvironmentObject var appState: AppState
    @State private var showingConfig = false
    @State private var pendingFullOrganization: WatchedFolder?
    @State private var isHovered = false
    @State private var highlightPulse = false
    @State private var isCardVisible = false
    @State private var isWindowVisible = true
    @State private var expiredSnoozeDeadline: Date?
    @State private var accessRecoveryError: AccessRecoveryError?
    @State private var isConfirmingReviewDiscard = false
    @State private var isConfirmingFolderRemoval = false

    private var isSnoozed: Bool {
        folder.isSnoozed && expiredSnoozeDeadline != folder.snoozedUntil
    }

    private var hasSavedReview: Bool {
        if case .awaitingReview = watchedFoldersManager.activityByFolder[folder.id] {
            return true
        }
        return false
    }

    private var isOrganizing: Bool {
        guard let currentDir = organizer.currentDirectory else { return false }
        // Only scanning/organizing/applying are active work. `.ready` is a plan
        // waiting for review, not a running operation.
        return currentDir.path == folder.path && organizer.state.isOperationInProgress
    }

    private var isHighlighted: Bool {
        appState.highlightedWatchedFolderID == folder.id
    }

    // Check if AI is available
    private var isAIConfigured: Bool {
        organizer.aiClient != nil
    }

    private var folderExists: Bool {
        watchedFoldersManager.folderExists(folder.id)
    }

    private var statusColor: Color {
        if !folderExists { return .red }
        if folder.accessStatus == .lost { return .orange }
        if !folder.isEnabled { return .secondary }
        if isOrganizing { return .blue }
        return .green
    }

    private var statusIcon: String {
        if !folderExists { return "exclamationmark.triangle.fill" }
        if folder.accessStatus == .lost { return "lock.slash.fill" }
        if !folder.isEnabled { return "pause.circle.fill" }
        if isOrganizing { return "arrow.triangle.2.circlepath" }
        return "eye.circle.fill"
    }

    private var cardBackgroundColor: Color {
        if isHighlighted {
            return SortyDesignSystem.Colors.resolvedAccent.opacity(highlightPulse ? 0.14 : 0.08)
        }
        return isHovered ? Color.primary.opacity(0.03) : Color.clear
    }

    private var cardBorderColor: Color {
        if isHighlighted {
            return SortyDesignSystem.Colors.resolvedAccent.opacity(highlightPulse ? 0.9 : 0.45)
        }
        return folderExists ? Color.white.opacity(0.1) : Color.red.opacity(0.3)
    }

    private var cardShadowColor: Color {
        if isHighlighted {
            return SortyDesignSystem.Colors.resolvedAccent.opacity(highlightPulse ? 0.35 : 0.16)
        }
        return .black.opacity(0.03)
    }

    private var cardShadowRadius: CGFloat {
        isHighlighted ? 10 : 3
    }

    private var folderIconView: some View {
        ZStack(alignment: .bottomTrailing) {
            FolderThumbnailView(
                url: URL(fileURLWithPath: folder.path), size: CGSize(width: 40, height: 40)
            )
            .opacity(folder.isEnabled ? 1.0 : 0.6)

            Image(systemName: statusIcon)
                .font(.system(size: 14))
                .foregroundStyle(statusColor)
                .symbolReplaceTransition(animationValue: statusIcon)
                .background(
                    Circle()
                        .fill(Color(NSColor.controlBackgroundColor))
                        .frame(width: 18, height: 18)
                )
                .offset(x: 4, y: 4)
        }
        .frame(width: 48, height: 48)
    }

    private var organizingBadge: some View {
        HStack(spacing: 4) {
            SortyGradientCircularLoader(size: 10, lineWidth: 2)
            Text("Running...")
                .font(.caption2)
        }
        .foregroundColor(.blue)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.blue.opacity(0.1))
        .clipShape(Capsule())
    }

    private var aiMissingBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
            Text("Provider Missing")
                .font(.caption2)
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.orange.opacity(0.1))
        .clipShape(Capsule())
        .help("Watching requires a provider configured in Settings")
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(folder.name)
                .font(.headline)
                .foregroundColor(folder.isEnabled ? .primary : .secondary)

            if isOrganizing {
                organizingBadge
            }

            if folder.isEnabled && !isAIConfigured {
                aiMissingBadge
            }
        }
    }

    private var lastTriggeredStat: some View {
        Group {
            if let lastTriggered = folder.lastTriggered {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .contentTransition(.symbolEffect(.replace))
                    Text(lastTriggered, style: .relative)
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private var modelOverrideStat: some View {
        Group {
            if let modelOverride = folder.modelOverride {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.caption2)
                        .contentTransition(.symbolEffect(.replace))
                    Text(modelOverride)
                        .font(.caption2)
                        .lineLimit(1)
                        .numericTextTransition(animationValue: modelOverride)
                }
                .foregroundStyle(.purple)
            }
        }
    }

    private var organizationModeStat: some View {
        HStack(spacing: 4) {
            Image(systemName: folder.effectiveOrganizationMode.iconName)
                .font(.caption2)
                .symbolReplaceTransition(
                    animationValue: folder.effectiveOrganizationMode
                )
            Text(folder.effectiveOrganizationMode.displayName)
                .font(.caption2)
                .numericTextTransition(
                    animationValue: folder.effectiveOrganizationMode
                )
        }
        .foregroundStyle(.blue)
    }

    private var missingFolderStatus: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .contentTransition(.symbolEffect(.replace))
            Text("Folder not found")
                .font(.caption2)
        }
        .foregroundStyle(.red)
    }

    private var grantAccessButton: some View {
        Button("Grant Access") {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "Re-select \"\(folder.name)\" to restore access"
            panel.prompt = "Grant Access"
            panel.directoryURL = folder.url

            if panel.runModal() == .OK, let url = panel.url {
                switch watchedFoldersManager.reauthorizeFolder(folder, with: url) {
                case .success:
                    HapticFeedbackManager.shared.success()
                case .incorrectFolder:
                    HapticFeedbackManager.shared.error()
                    accessRecoveryError = .incorrectFolder(selectedName: url.lastPathComponent)
                case .bookmarkCreationFailed:
                    HapticFeedbackManager.shared.error()
                    accessRecoveryError = .bookmarkCreationFailed
                }
            }
        }
        .font(.caption2)
        .buttonStyle(.sortyBordered)
        .controlSize(.mini)
        .alert(item: $accessRecoveryError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message(for: folder.name)),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var healthStatusView: some View {
        if !folderExists {
            missingFolderStatus
        } else if folder.accessStatus == .lost {
            grantAccessButton
        }
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            lastTriggeredStat
            organizationModeStat
            modelOverrideStat
            healthStatusView
        }
    }

    @ViewBuilder
    private var activityLine: some View {
        if isSnoozed, let until = folder.snoozedUntil {
            Label(snoozedActivityText(until: until), systemImage: "clock.badge.pause")
                .foregroundStyle(.orange)
        } else if let activity = watchedFoldersManager.activityByFolder[folder.id] {
            if case .awaitingReview(let count) = activity {
                awaitingReviewLine(fileCount: count)
            } else if case .parked(let count) = activity {
                parkedBatchLine(fileCount: count)
            } else {
                WatchedFolderActivityLabel(activity: activity)
            }
        }
    }

    private func parkedBatchLine(fileCount: Int) -> some View {
        HStack(spacing: 8) {
            Label(
                "\(fileCount) file\(fileCount == 1 ? "" : "s") couldn’t be organized",
                systemImage: "exclamationmark.circle.fill"
            )
            .foregroundStyle(.secondary)

            Button {
                postPendingBatchNotification(.retryWatchedFolderBatch)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.sortyProminent(intent: .primary, size: .mini))

            Button("Discard", role: .destructive) {
                postPendingBatchNotification(.discardWatchedFolderBatch)
            }
            .buttonStyle(.sortyBordered(intent: .destructive, size: .mini))
        }
    }

    private func awaitingReviewLine(fileCount: Int) -> some View {
        HStack(spacing: 8) {
            Label(
                "\(fileCount) file\(fileCount == 1 ? "" : "s") ready",
                systemImage: "eye.fill"
            )
            .foregroundStyle(.secondary)

            Button {
                HapticFeedbackManager.shared.tap()
                _ = MainWindowRouter.shared.post(
                    name: .showOrganizationPreview,
                    userInfo: [
                        "folderPath": folder.path,
                        "isWatchedReview": true
                    ]
                )
            } label: {
                Label("Review", systemImage: "arrow.right")
            }
            .buttonStyle(.sortyProminent(intent: .primary, size: .mini))

            Button("Discard", role: .destructive) {
                isConfirmingReviewDiscard = true
            }
            .buttonStyle(.sortyBordered(intent: .destructive, size: .mini))
        }
    }

    private var folderInfoView: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleRow

            PrivacySensitivePathText(path: folder.path)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            statsRow

            activityLine
                .font(.caption2)
                .lineLimit(1)
        }
    }

    private var quickActionsView: some View {
        HStack(spacing: 8) {
            snoozeMenu

            Button {
                HapticFeedbackManager.shared.tap()
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
            } label: {
                Image(systemName: "folder")
                    .font(.caption)
            }
            .buttonStyle(.sortyBordered)
            .controlSize(.small)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(folder.name) in Finder")

            Button {
                HapticFeedbackManager.shared.tap()
                showingConfig = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
            }
            .buttonStyle(.sortyBordered)
            .controlSize(.small)
            .help("Configure")
            .accessibilityLabel("Configure \(folder.name)")

            Button {
                requestFolderRemoval()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.sortyBordered)
            .controlSize(.small)
            .help("Remove")
            .accessibilityLabel("Remove \(folder.name)")
        }
    }

    private var snoozeMenu: some View {
        Menu {
            if isSnoozed {
                Button("Resume Now") {
                    watchedFoldersManager.snooze(folder, until: nil)
                    HapticFeedbackManager.shared.selection()
                }
                Divider()
            }
            Button("15 Minutes") { snooze(for: 15 * 60) }
            Button("1 Hour") { snooze(for: 60 * 60) }
            Button("Until Tomorrow") {
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
                watchedFoldersManager.snooze(
                    folder,
                    until: Calendar.current.startOfDay(for: tomorrow)
                )
                HapticFeedbackManager.shared.selection()
            }
        } label: {
            Image(systemName: isSnoozed ? "clock.badge.checkmark" : "clock.badge.pause")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isSnoozed ? "Change snooze" : "Snooze this watched folder")
        .accessibilityLabel(
            isSnoozed ? "Change snooze for \(folder.name)" : "Snooze \(folder.name)"
        )
    }

    private func snooze(for duration: TimeInterval) {
        watchedFoldersManager.snooze(folder, until: Date().addingTimeInterval(duration))
        HapticFeedbackManager.shared.selection()
    }

    private func snoozedActivityText(until: Date) -> String {
        let time = until.formatted(date: .omitted, time: .shortened)
        guard let activity = watchedFoldersManager.activityByFolder[folder.id] else {
            return "Snoozed until \(time)"
        }
        let count: Int
        switch activity {
        case .waitingForStability(let fileCount, _),
             .queued(let fileCount, _),
             .parked(let fileCount),
             .running(let fileCount),
             .awaitingReview(let fileCount):
            count = fileCount
        case .retrying(let fileCount, _, _):
            count = fileCount
        }
        return "Snoozed until \(time) · \(count) queued"
    }

    private func postPendingBatchNotification(_ notification: Notification.Name) {
        HapticFeedbackManager.shared.tap()
        NotificationCenter.default.post(name: notification, object: folder.id)
    }

    private var isEnabledBinding: Binding<Bool> {
        Binding(
            get: { folder.isEnabled },
            set: { _ in
                HapticFeedbackManager.shared.selection()
                watchedFoldersManager.toggleEnabled(for: folder)
            }
        )
    }

    private var watchToggle: some View {
        Toggle("Watch \(folder.name)", isOn: isEnabledBinding)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityHint(
                "When enabled, Sorty organizes new files into this folder's preferred structure.")
    }

    private var controlsView: some View {
        HStack(spacing: 12) {
            quickActionsView
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(reduceMotion || isHovered ? 1 : 0.96)
                .allowsHitTesting(isHovered)
                .accessibilityHidden(!isHovered)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.15),
                    value: isHovered
                )

            watchToggle
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: folder.isEnabled)
    }

    var body: some View {
        activeCard
        .onHover { hovering in
            guard hovering != isHovered else { return }
            isHovered = hovering
        }
        .onAppear {
            isCardVisible = true
            updateHighlightAnimation(isHighlighted)
        }
        .onDisappear {
            // Offscreen cards hold their highlight state statically: the
            // repeatForever pulse stops instead of animating inside the
            // lazy buffer.
            isCardVisible = false
            updateHighlightAnimation(isHighlighted)
        }
        .onChange(of: isHighlighted) { _, newValue in
            updateHighlightAnimation(newValue)
        }
        .onChange(of: controlActiveState) { _, _ in
            updateHighlightAnimation(isHighlighted)
        }
        .onChange(of: reduceMotion) { _, _ in
            updateHighlightAnimation(isHighlighted)
        }
        .onChange(of: isWindowVisible) { _, _ in
            updateHighlightAnimation(isHighlighted)
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
            }
            Button("Configure...") {
                showingConfig = true
            }
            Divider()
            Button("Remove", role: .destructive) {
                requestFolderRemoval()
            }
        }
        .sheet(isPresented: $showingConfig, onDismiss: openPendingFullOrganization) {
            WatchedFolderConfigView(
                folder: folder,
                onOpenFullOrganization: { updatedFolder in
                    pendingFullOrganization = updatedFolder
                }
            )
                .modalBounce()
        }
        .alert("Discard Saved Plan?", isPresented: $isConfirmingReviewDiscard) {
            Button("Keep Plan", role: .cancel) {}
            Button("Discard Plan", role: .destructive) {
                HapticFeedbackManager.shared.tap()
                NotificationCenter.default.post(
                    name: .discardWatchedFolderReview,
                    object: folder.id
                )
            }
        } message: {
            Text("Sorty will forget this plan without moving any files. New changes waiting for this watched folder can then be organized.")
        }
        .alert("Remove Watched Folder?", isPresented: $isConfirmingFolderRemoval) {
            Button("Keep Folder", role: .cancel) {}
            Button("Remove Folder and Discard Plan", role: .destructive) {
                removeFolder()
            }
        } message: {
            Text("Removing \"\(folder.name)\" will also discard its saved review plan. No files will be moved.")
        }

    }

    private func requestFolderRemoval() {
        if hasSavedReview {
            isConfirmingFolderRemoval = true
        } else {
            removeFolder()
        }
    }

    private func removeFolder() {
        HapticFeedbackManager.shared.tap()
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) {
            watchedFoldersManager.removeFolder(folder)
        }
    }

    private func updateHighlightAnimation(_ isActive: Bool) {
        if isActive, isCardVisible, isWindowVisible, controlActiveState != .inactive, !reduceMotion {
            highlightPulse = false
            withAnimation(.easeInOut(duration: 0.9).repeatCount(3, autoreverses: true)) {
                highlightPulse = true
            }
        } else {
            withAnimation(nil) {
                highlightPulse = isActive && isCardVisible
            }
        }
    }

    private func openPendingFullOrganization() {
        guard let updatedFolder = pendingFullOrganization else { return }
        pendingFullOrganization = nil

        organizer.reset()
        organizer.customInstructions = updatedFolder.customPrompt ?? ""
        appState.selectedDirectory = updatedFolder.url
        appState.openRelatedView(.organize)
    }

    private var cardContent: some View {
        HStack(spacing: 16) {
            folderIconView
            folderInfoView

            Spacer()

            controlsView
        }
    }

    private var activeCard: some View {
        cardContent
        .padding(16)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardBackgroundColor)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.15),
                    value: isHovered
                )
        }
        .systemLiquidGlassBackground(cornerRadius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(cardBorderColor, lineWidth: isHighlighted ? 1.6 : 1)
        )
        .shadow(color: cardShadowColor, radius: cardShadowRadius, x: 0, y: 1)
        .opacity(folderExists ? 1.0 : 0.8)
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .task(id: folder.snoozedUntil) {
            // Refresh snooze controls once at expiry instead of keeping every
            // card subscribed to the per-second countdown clock.
            guard let deadline = folder.snoozedUntil else { return }
            let delay = deadline.timeIntervalSinceNow
            guard delay.isFinite else { return }
            do {
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { return }
                expiredSnoozeDeadline = deadline
            } catch {
                // A changed snooze date or removed card cancels this deadline.
            }
        }
    }
}
