//
//  WatchedFoldersView.swift
//  Sorty
//
//  Modern watched folders management with rich folder cards and status indicators
//

import SwiftUI
import UniformTypeIdentifiers

struct WatchedFoldersView: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var watchedFoldersManager: WatchedFoldersManager
    @EnvironmentObject var appState: AppState
    @State private var showingFolderPicker = false
    @State private var selectedFolderForEdit: WatchedFolder?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if watchedFoldersManager.folders.isEmpty {
                ZStack(alignment: .topLeading) {
                    EmptyWatchedFoldersView(onAddFolder: {
                        HapticFeedbackManager.shared.tap()
                        showingFolderPicker = true
                    }, onAddSuggestedFolder: { url in
                        addWatchedFolder(from: url)
                    })
                    .transition(TransitionStyles.scaleAndFade)
                    .animatedAppearance(delay: 0.08)

                    emptyHeaderView
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .animatedAppearance(delay: 0.03)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Header
                headerView
                    .animatedAppearance(delay: 0.03)

                Divider()

                // Folder Grid/List
                ZStack {
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(
                                    Array(watchedFoldersManager.folders.enumerated()),
                                    id: \.element.id
                                ) { index, folder in
                                    WatchedFolderCard(folder: folder)
                                    .id(folder.id)
                                    .animatedAppearance(
                                        delay: 0.05 + min(Double(index), 8) * 0.04
                                    )
                                }
                            }
                            .padding(20)
                        }
                        .onChange(of: appState.highlightedWatchedFolderID) { _, highlightedID in
                            guard let highlightedID else { return }
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                scrollProxy.scrollTo(highlightedID, anchor: .center)
                            }
                        }
                    }
                    .transition(TransitionStyles.slideFromRight)
                }
                .animation(.pageTransition, value: watchedFoldersManager.folders.isEmpty)
            }
        }
        .emptyStateWorkflowGradient(isVisible: watchedFoldersManager.folders.isEmpty)
        .animation(.pageTransition, value: watchedFoldersManager.folders.isEmpty)
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    addWatchedFolder(from: url)
                }
            case .failure(let error):
                HapticFeedbackManager.shared.error()
                DebugLogger.log("Failed to select folder: \(error)")
            }
        }
        .siriDropZone(isTargeted: $isDropTargeted) { providers in
            handleFolderDrop(providers: providers)
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .onAppear {
            watchedFoldersManager.refreshFolderExistence()
        }
        .navigationTitle("Watched Folders")
    }

    private func addWatchedFolder(from url: URL) {
        HapticFeedbackManager.shared.success()

        // Start accessing the security-scoped resource before creating the bookmark.
        // fileImporter URLs are security-scoped but the resource must be explicitly
        // started to ensure bookmark creation captures the scope.
        let didStart = url.startAccessingSecurityScopedResource()

        let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        if didStart {
            url.stopAccessingSecurityScopedResource()
        }

        if bookmarkData == nil {
            DebugLogger.log("Failed to create security-scoped bookmark for \(url.path)")
        }

        let folder = WatchedFolder(
            path: url.path,
            bookmarkData: bookmarkData
        )
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            watchedFoldersManager.addFolder(folder)
        }
    }

    private func handleFolderDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
            if let data = item as? Data,
                let url = URL(dataRepresentation: data, relativeTo: nil),
                url.hasDirectoryPath
            {
                Task { @MainActor in
                    HapticFeedbackManager.shared.success()
                    let bookmarkData = try? url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    let folder = WatchedFolder(
                        path: url.path,
                        bookmarkData: bookmarkData
                    )
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        watchedFoldersManager.addFolder(folder)
                    }
                }
            }
        }
        return true
    }

    private var headerView: some View {
        HStack {
            HStack(spacing: 12) {
                if appState.navigatedFromSettings {
                    GlassyBackButton {
                        HapticFeedbackManager.shared.tap()
                        appState.navigatedFromSettings = false
                        appState.openSettingsWindow(section: .rules)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Watched Folders")
                        .font(.title2)
                        .fontWeight(.semibold)

                    HStack(spacing: 8) {
                        let activeCount = watchedFoldersManager.activeFolderCount

                        Text("\(activeCount) active")
                            .foregroundStyle(activeCount > 0 ? .green : .secondary)
                            .numericTextTransition(animationValue: activeCount)
                    }
                    .font(.caption)
                }
            }
            .animatedAppearance(delay: 0.05)

            Spacer()

            Button {
                HapticFeedbackManager.shared.tap()
                showingFolderPicker = true
            } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.sortyPrimary)
            .onboardingBeamBorder(variant: .success)
            .accessibilityIdentifier("AddWatchedFolderButton")
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var emptyHeaderView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Watched Folders")
                    .font(.largeTitle.bold())

                Text("Monitor folders and automatically organize new files as they arrive")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

// MARK: - Empty State View

struct EmptyWatchedFoldersView: View {
    @SortyHotReload private var hotReload
    let onAddFolder: () -> Void
    let onAddSuggestedFolder: (URL) -> Void
    @State private var hasAppeared = false
    @State private var beamHasAppeared = false

    var body: some View {
        VStack(spacing: 24) {
            EmptyStateHeroIcon(systemName: "folder.badge.plus")
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.8)
                .animation(
                    .spring(response: 0.5, dampingFraction: 0.7).delay(0.1), value: hasAppeared)

            VStack(spacing: 8) {
                Text("No Watched Folders")
                    .font(.title3)
                    .fontWeight(.semibold)

                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Add folders like")

                        FolderSuggestionPill(
                            name: "Downloads",
                            url: FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent("Downloads"),
                            action: onAddSuggestedFolder
                        )

                        Text("or")

                        FolderSuggestionPill(
                            name: "Desktop",
                            url: FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent("Desktop"),
                            action: onAddSuggestedFolder
                        )
                    }

                    Text("to automatically organize new files as they arrive")
                }
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: hasAppeared)

            Button {
                onAddFolder()
            } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.sortyPrimary)
            .onboardingBeamBorder(variant: .featured, active: beamHasAppeared)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 15)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: hasAppeared)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                hasAppeared = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                beamHasAppeared = true
            }
        }
    }
}

struct FolderSuggestionPill: View {
    @SortyHotReload private var hotReload
    let name: String
    let url: URL
    let action: (URL) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            action(url)
        } label: {
            HStack(spacing: 4) {
                FolderThumbnailView(
                    url: url,
                    size: CGSize(width: 16, height: 16)
                )

                Text(name)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(isHovered ? 0.14 : 0.07))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovered ? .primary : .secondary)
        .scaleEffect(isHovered ? 1.02 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
        .onHover { hovering in
            if hovering && !isHovered {
                HapticFeedbackManager.shared.selection()
            }
            isHovered = hovering
        }
        .accessibilityLabel("Add \(name) to watched folders")
    }
}

// MARK: - Watched Folder Card

struct WatchedFolderCard: View {
    @SortyHotReload private var hotReload
    private enum AccessRecoveryError: Identifiable {
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
    @State private var accessRecoveryError: AccessRecoveryError?
    @State private var isConfirmingReviewDiscard = false
    @State private var isConfirmingFolderRemoval = false

    private var hasSavedReview: Bool {
        if case .awaitingReview = watchedFoldersManager.activityByFolder[folder.id] {
            return true
        }
        return false
    }

    private var isOrganizing: Bool {
        guard let currentDir = organizer.currentDirectory else { return false }
        return currentDir.path == folder.path && organizer.state != .idle
            && organizer.state != .completed && !isErrorState
    }

    private var isErrorState: Bool {
        if case .error = organizer.state { return true }
        return false
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
        if folder.isSnoozed, let until = folder.snoozedUntil {
            Label(snoozedActivityText(until: until), systemImage: "clock.badge.pause")
                .foregroundStyle(.orange)
        } else if let activity = watchedFoldersManager.activityByFolder[folder.id] {
            if case .awaitingReview(let count) = activity {
                awaitingReviewLine(fileCount: count)
            } else if case .parked(let count) = activity {
                parkedBatchLine(fileCount: count)
            } else if activityHasCountdown(activity) {
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                    activityStatusLabel(activity, now: context.date)
                }
            } else {
                activityStatusLabel(activity, now: .now)
            }
        }
    }

    private func activityHasCountdown(_ activity: WatchedFolderActivity) -> Bool {
        switch activity {
        case .waitingForStability, .queued, .retrying:
            true
        case .parked, .running, .awaitingReview:
            false
        }
    }

    private func activityStatusLabel(_ activity: WatchedFolderActivity, now: Date) -> some View {
        Label {
            let status = activityText(activity, now: now)
            Text(status)
                .numericTextTransition(animationValue: status)
        } icon: {
            Image(systemName: activityIcon(activity))
        }
        .foregroundStyle(activityColor(activity))
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
            if folder.isSnoozed {
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
            Image(systemName: folder.isSnoozed ? "clock.badge.checkmark" : "clock.badge.pause")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(folder.isSnoozed ? "Change snooze" : "Snooze this watched folder")
        .accessibilityLabel(
            folder.isSnoozed ? "Change snooze for \(folder.name)" : "Snooze \(folder.name)"
        )
    }

    private func snooze(for duration: TimeInterval) {
        watchedFoldersManager.snooze(folder, until: Date().addingTimeInterval(duration))
        HapticFeedbackManager.shared.selection()
    }

    private func activityText(_ activity: WatchedFolderActivity, now: Date) -> String {
        switch activity {
        case .waitingForStability(let count, let date):
            return "\(count) waiting for stability · \(countdown(to: date, from: now))"
        case .queued(let count, let date):
            return "\(count) queued · \(countdown(to: date, from: now))"
        case .retrying(let count, let attempt, let date):
            return "\(count) retrying (attempt \(attempt)) · \(countdown(to: date, from: now))"
        case .parked(let count):
            return "\(count) file\(count == 1 ? "" : "s") couldn’t be organized"
        case .running(let count):
            return "Organizing \(count) file\(count == 1 ? "" : "s")"
        case .awaitingReview(let count):
            return "\(count) file\(count == 1 ? "" : "s") ready to review"
        }
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

    private func countdown(to date: Date, from now: Date) -> String {
        let seconds = max(Int(date.timeIntervalSince(now).rounded(.up)), 0)
        return seconds == 0 ? "starting now" : "in \(seconds)s"
    }

    private func activityIcon(_ activity: WatchedFolderActivity) -> String {
        switch activity {
        case .waitingForStability: "hourglass"
        case .queued: "tray.full"
        case .retrying: "arrow.clockwise"
        case .parked: "exclamationmark.circle"
        case .running: "arrow.triangle.2.circlepath"
        case .awaitingReview: "eye"
        }
    }

    private func activityColor(_ activity: WatchedFolderActivity) -> Color {
        switch activity {
        case .parked: .red
        case .retrying: .orange
        case .running, .awaitingReview: .blue
        case .waitingForStability, .queued: .secondary
        }
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
        HStack(spacing: 16) {
            folderIconView
            folderInfoView

            Spacer()

            controlsView
        }
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
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(cardBorderColor, lineWidth: isHighlighted ? 1.6 : 1)
        )
        .shadow(color: cardShadowColor, radius: cardShadowRadius, x: 0, y: 1)
        .opacity(folderExists ? 1.0 : 0.8)
        .scaleEffect(isHighlighted && highlightPulse ? 1.008 : 1.0)
        .onHover { hovering in
            guard hovering != isHovered else { return }
            isHovered = hovering
        }
        .onAppear {
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
        if isActive, controlActiveState != .inactive, !reduceMotion {
            highlightPulse = false
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                highlightPulse = true
            }
        } else {
            withAnimation(nil) {
                highlightPulse = isActive
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
}

private struct WatchedFolderNerdStats: View {
    @SortyHotReload private var hotReload
    let folder: WatchedFolder
    let activity: WatchedFolderActivity?
    @EnvironmentObject private var history: OrganizationHistory

    private var recentRuns: [OrganizationHistoryEntry] {
        let folderPath = URL(fileURLWithPath: folder.path).standardizedFileURL.path
        return history.entries.filter {
            $0.source == .watchedFolder
                && URL(fileURLWithPath: $0.directoryPath).standardizedFileURL.path == folderPath
        }
    }

    private var completedRuns: [OrganizationHistoryEntry] {
        recentRuns.filter { $0.status == .completed }
    }

    private var filesOrganized: Int {
        completedRuns.reduce(0) { $0 + $1.filesOrganized }
    }

    private var successRate: String {
        guard !recentRuns.isEmpty else { return "No runs" }
        let rate = Double(completedRuns.count) / Double(recentRuns.count) * 100
        return rate.formatted(.number.precision(.fractionLength(0))) + "%"
    }

    private var averageFilesPerRun: String {
        guard !completedRuns.isEmpty else { return "0" }
        let average = Double(filesOrganized) / Double(completedRuns.count)
        return average.formatted(.number.precision(.fractionLength(0...1)))
    }

    private var totalAITime: String {
        let duration = recentRuns.compactMap { $0.plan?.generationStats?.duration }.reduce(0, +)
        return GenerationStats.formatDuration(duration)
    }

    private var estimatedCost: String {
        let cost = recentRuns
            .compactMap { $0.plan?.generationStats?.computedCost }
            .reduce(Decimal.zero, +)
        return GenerationStats.formatCost(cost)
    }

    private var lastRun: String {
        guard let timestamp = recentRuns.first?.timestamp else { return "Never" }
        return timestamp.formatted(.relative(presentation: .named))
    }

    private var queuedFileCount: Int {
        guard let activity else { return 0 }
        switch activity {
        case .waitingForStability(let count, _),
             .queued(let count, _),
             .retrying(let count, _, _),
             .parked(let count),
             .running(let count),
             .awaitingReview(let count):
            return count
        }
    }

    private var activityLabel: String {
        guard let activity else { return "Idle" }
        switch activity {
        case .waitingForStability: return "Stabilizing"
        case .queued: return "Queued"
        case .retrying: return "Retrying"
        case .parked: return "Parked"
        case .running: return "Running"
        case .awaitingReview: return "Review"
        }
    }

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 10, maximum: .infinity)),
                GridItem(.flexible(minimum: 10, maximum: .infinity)),
                GridItem(.flexible(minimum: 10, maximum: .infinity))
            ],
            spacing: 8
        ) {
            NerdStatPillExpanded(
                icon: "tray.full",
                color: .indigo,
                title: "Queued files",
                value: GenerationStats.formatCount(queuedFileCount),
                unit: nil
            )
            NerdStatPillExpanded(
                icon: "waveform.path.ecg",
                color: .blue,
                title: "Activity",
                value: activityLabel,
                unit: nil
            )
            NerdStatPillExpanded(
                icon: "play.circle",
                color: .orange,
                title: "Runs",
                value: GenerationStats.formatCount(recentRuns.count),
                unit: nil
            )
            NerdStatPillExpanded(
                icon: "checkmark.circle",
                color: .green,
                title: "Success rate",
                value: successRate,
                unit: nil
            )
            NerdStatPillExpanded(
                icon: "doc.on.doc",
                color: .teal,
                title: "Files organized",
                value: GenerationStats.formatCount(filesOrganized),
                unit: nil
            )
            NerdStatPillExpanded(
                icon: "chart.bar",
                color: .purple,
                title: "Avg files per run",
                value: averageFilesPerRun,
                unit: nil
            )
            NerdStatPillExpanded(
                icon: "clock",
                color: .blue,
                title: "Total AI time",
                value: totalAITime,
                unit: nil
            )
            NerdStatPillExpanded(
                icon: "dollarsign.circle",
                color: .green,
                title: "Estimated cost",
                value: estimatedCost,
                unit: nil
            )
            NerdStatPillExpanded(
                icon: "calendar",
                color: .secondary,
                title: "Last run",
                value: lastRun,
                unit: nil
            )
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Watched Folder Config View

struct WatchedFolderConfigView: View {
    @SortyHotReload private var hotReload
    let folder: WatchedFolder
    let onOpenFullOrganization: (WatchedFolder) -> Void
    @EnvironmentObject var watchedFoldersManager: WatchedFoldersManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var customPersonaStore: CustomPersonaStore
    @EnvironmentObject var organizer: FolderOrganizer
    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var steeringManager = SteeringPromptManager.shared

    @State private var customPrompt: String
    @State private var useCustomModel: Bool
    @State private var selectedProvider: AIProvider
    @State private var selectedModel: String
    @State private var selectedMode: OrganizationMode
    @State private var selectedApplyPolicy: WatchedFolderApplyPolicy
    @State private var showModelPicker = false
    @State private var showFolderModelInfo = false
    @State private var showSavedPromptsSheet = false
    @State private var showSavePromptDialog = false
    @State private var savePromptName = ""
    @State private var isImprovingPrompt = false
    @State private var showImprovePromptRequest = false
    @State private var improvePromptRequestMessage = ""
    @State private var isPromptFocused = false
    @State private var instructionSuggestionIndex = 0
    @State private var instructionSelection = NSRange(location: 0, length: 0)
    @State private var showNerdStats = false

    init(
        folder: WatchedFolder,
        onOpenFullOrganization: @escaping (WatchedFolder) -> Void
    ) {
        self.folder = folder
        self.onOpenFullOrganization = onOpenFullOrganization
        _customPrompt = State(initialValue: folder.customPrompt ?? "")
        _useCustomModel = State(initialValue: folder.modelOverride != nil)
        _selectedProvider = State(initialValue: folder.providerOverride ?? .openAI)
        _selectedModel = State(initialValue: folder.modelOverride ?? AIProvider.openAI.defaultModel)
        _selectedMode = State(initialValue: folder.effectiveOrganizationMode)
        _selectedApplyPolicy = State(initialValue: folder.effectiveApplyPolicy)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 12) {
                    FolderThumbnailView(
                        url: URL(fileURLWithPath: folder.path),
                        size: CGSize(width: 32, height: 32)
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.name)
                            .font(.headline)
                        PrivacySensitivePathText(path: folder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if settingsViewModel.config.showStatsForNerds {
                    Button {
                        HapticFeedbackManager.shared.light()
                        showNerdStats.toggle()
                    } label: {
                        Label("Stats for Nerds", systemImage: "chart.bar.doc.horizontal")
                    }
                    .buttonStyle(.sortyBordered)
                    .controlSize(.small)
                    .help("Show watched-folder diagnostics")
                    .popover(isPresented: $showNerdStats, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Stats for Nerds")
                                .font(.headline)

                            Text("Live diagnostics for this watched folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            WatchedFolderNerdStats(
                                folder: folder,
                                activity: watchedFoldersManager.activityByFolder[folder.id]
                            )
                        }
                        .padding(16)
                        .frame(width: 420)
                        .systemLiquidGlassPopover(cornerRadius: 12)
                    }
                }

                Button("Done") {
                    HapticFeedbackManager.shared.success()
                    save()
                }
                .buttonStyle(.sortyProminent)
            }
            .padding()
            .background(.ultraThinMaterial)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    SettingsCard(title: "Action", icon: "slider.horizontal.3", color: .blue) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 4) {
                                ForEach(OrganizationMode.allCases, id: \.self) { mode in
                                    OrganizationModeSegment(
                                        mode: mode,
                                        isSelected: selectedMode == mode
                                    ) {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                            selectedMode = mode
                                        }
                                        HapticFeedbackManager.shared.selection()
                                    }
                                }
                            }
                            .padding(4)
                            .systemLiquidGlassBackground(cornerRadius: 999)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Watched folder action")

                            Text(LocalizedStringKey(selectedMode.description))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .numericTextTransition(animationValue: selectedMode)
                        }
                    }

                    SettingsCard(title: "When a Plan Is Ready", icon: "checkmark.shield", color: .green) {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Apply policy", selection: $selectedApplyPolicy) {
                                ForEach(WatchedFolderApplyPolicy.allCases, id: \.self) { policy in
                                    Text(policy.displayName).tag(policy)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityHint("Choose whether Sorty applies watched-folder plans or waits for your review")

                            Text(selectedApplyPolicy == .autoApply
                                ? "Sorty applies the plan as soon as it is ready."
                                : "Sorty saves the plan and notifies you to review it. It stays ready until you apply or discard it, even if you close Sorty.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // Actions Section
                    SettingsCard(title: "Actions", icon: "play", color: .blue) {
                        Button(action: openFullOrganization) {
                            HStack {
                                Image(systemName: selectedMode.iconName)
                                    .foregroundStyle(.blue)
                                    .symbolReplaceTransition(animationValue: selectedMode)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LocalizedStringKey(selectedModeManualAction.title))
                                        .foregroundStyle(.primary)
                                        .numericTextTransition(animationValue: selectedMode)
                                    Text(LocalizedStringKey(selectedModeManualAction.description))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .numericTextTransition(animationValue: selectedMode)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Custom Instructions Section
                    SettingsCard(title: "Custom Instructions", icon: "text.bubble", color: .purple)
                    {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .topLeading) {
                                SubmittableTextEditor(
                                    text: $customPrompt,
                                    isFocused: $isPromptFocused,
                                    selectedRange: $instructionSelection,
                                    onAcceptSuggestion: acceptCurrentInstructionSuggestion,
                                    onSubmit: {}
                                )
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)

                                if customPrompt.isEmpty {
                                    HStack(alignment: .top, spacing: 10) {
                                        Text(currentInstructionSuggestion)
                                            .font(.body)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(2)
                                            .numericTextTransition(
                                                animationValue: instructionSuggestionIndex
                                            )

                                        Spacer(minLength: 0)

                                        Text("Tab")
                                            .font(
                                                .system(
                                                    size: 10,
                                                    weight: .semibold,
                                                    design: .rounded
                                                )
                                            )
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(
                                                Color.secondary.opacity(0.10),
                                                in: RoundedRectangle(cornerRadius: 5)
                                            )
                                            .accessibilityHidden(true)
                                    }
                                    .padding(.leading, 18)
                                    .padding(.trailing, 10)
                                    .padding(.vertical, 9)
                                    .allowsHitTesting(false)
                                    .task(id: instructionSuggestions) {
                                        instructionSuggestionIndex = 0

                                        while !Task.isCancelled {
                                            try? await Task.sleep(for: .seconds(3.5))
                                            guard !Task.isCancelled else { return }
                                            instructionSuggestionIndex =
                                                (instructionSuggestionIndex + 1)
                                                % instructionSuggestions.count
                                        }
                                    }
                                }
                            }
                            .frame(height: 80)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(NSColor.textBackgroundColor))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)

                                FocusedInstructionBeamBorder(active: isPromptFocused)
                            }
                            .accessibilityIdentifier("WatchedFolderCustomInstructionsTextField")
                            .accessibilityLabel("Custom instructions for this watched folder")
                            .accessibilityHint(
                                customPrompt.isEmpty
                                    ? "Press Tab to use the suggested instruction"
                                    : "Enter adds a new line"
                            )

                            instructionActions
                        }
                    }

                    // AI Model Section
                    SettingsCard(title: "AI Model", icon: "cpu", color: .purple) {
                        VStack(spacing: 12) {
                            Toggle(isOn: $useCustomModel) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Use Custom Model")
                                        .font(.subheadline)
                                    Text("Override the global automation model for this folder")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if useCustomModel {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text("Folder Model")
                                                .font(.subheadline)

                                            Button {
                                                HapticFeedbackManager.shared.tap()
                                                showFolderModelInfo.toggle()
                                            } label: {
                                                Image(systemName: "info.circle")
                                                    .font(.caption)
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(.secondary)
                                            .help("About using a separate watched folder model")
                                            .accessibilityLabel(
                                                "Separate watched folder model information"
                                            )
                                            .onHover { hovering in
                                                if hovering {
                                                    HapticFeedbackManager.shared.selection()
                                                }
                                                showFolderModelInfo = hovering
                                            }
                                            .popover(
                                                isPresented: $showFolderModelInfo,
                                                arrowEdge: .trailing
                                            ) {
                                                VStack(alignment: .leading, spacing: 8) {
                                                    Text("Separate Watched Folder Model")
                                                        .font(.headline)

                                                    Text(
                                                        "The main Organize page keeps using the model selected under AI Provider. For faster, more responsive automation, try a smaller model such as GPT-5.6 Luna."
                                                    )
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .fixedSize(
                                                        horizontal: false,
                                                        vertical: true
                                                    )
                                                }
                                                .padding(14)
                                                .frame(width: 300, alignment: .leading)
                                                .systemLiquidGlassPopover(cornerRadius: 12)
                                            }
                                        }

                                        Text("Used only for this watched folder")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    ModelSelectorCompactButton(
                                        provider: selectedProvider,
                                        label: selectedModel.isEmpty
                                            ? selectedProvider.defaultModel
                                            : selectedModel,
                                        onTap: { showModelPicker = true }
                                    )
                                    .modelSelectorTriggerBounds()
                                }
                                .transition(
                                    reduceMotion
                                        ? .opacity
                                        : AnyTransition(.blurReplace)
                                )
                            }
                        }
                        .animation(
                            reduceMotion
                                ? .easeOut(duration: 0.15)
                                : .easeInOut(duration: 0.25),
                            value: useCustomModel
                        )
                    }

                    SettingsCard(title: "Recent AI Actions", icon: "sparkles", color: .purple) {
                        WatchedFolderRecentActions(
                            folder: folder,
                            history: organizer.history
                        )
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 680)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            primeModelSelectionFromGlobalDefaultsIfNeeded()
        }
        .onChange(of: useCustomModel) { _, useOverride in
            if useOverride && selectedModel.isEmpty {
                let defaults = globalAutomationSelection
                selectedProvider = defaults.provider
                selectedModel = defaults.model
            }
        }
        .modelSelectionOverlay(
            isPresented: $showModelPicker,
            currentProvider: selectedProvider,
            currentModel: selectedModel,
            contextMessage: "Choose the provider and model used only for this watched folder.",
            onSelect: { provider, model, authMethod in
                if let authMethod {
                    settingsViewModel.config.setAuthMethod(authMethod, for: provider)
                }
                selectedProvider = provider
                selectedModel = model
            },
            isSubscriptionSelected: settingsViewModel.config.authMethod(for: selectedProvider) == .accountSignIn
        )
        .sheet(isPresented: $showSavedPromptsSheet) {
            SavedPromptsSheet(
                steeringManager: steeringManager,
                settingsConfig: settingsViewModel.config,
                onApplyPrompt: { prompt in
                    customPrompt = prompt
                    showSavedPromptsSheet = false
                    HapticFeedbackManager.shared.tap()
                }
            )
        }
    }

    private var instructionActions: some View {
        HStack(alignment: .center, spacing: 0) {
            if !trimmedCustomPrompt.isEmpty {
                Button {
                    Task { await improvePromptWithAI() }
                } label: {
                    Label("Improve", systemImage: "wand.and.stars")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.teal)
                .disabled(isImprovingPrompt)
                .help("Improve instructions with Sorty")
                .accessibilityHint("Rewrites this watched folder's prompt to be clearer and more specific")
                .alert("Sorty needs more detail", isPresented: $showImprovePromptRequest) {
                    Button("Edit Instructions") {
                        isPromptFocused = true
                    }
                } message: {
                    Text("\(improvePromptRequestMessage)\n\nEdit the instructions above, then click Improve again.")
                }

                Button {
                    savePromptName = ""
                    showSavePromptDialog.toggle()
                } label: {
                    Label("Save", systemImage: "bookmark")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .help("Save current instructions for reuse")
                .accessibilityHint("Stores this prompt in your saved prompts list")
                .popover(isPresented: $showSavePromptDialog) {
                    savePromptPopover
                }
            }

            Button {
                showSavedPromptsSheet.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                        .frame(width: 18)
                        .accessibilityHidden(true)

                    Text(
                        steeringManager.prompts.isEmpty
                            ? "Saved Prompts"
                            : "Saved Prompts (\(steeringManager.prompts.count))"
                    )
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .systemLiquidGlassBackground(cornerRadius: 12)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            SortyDesignSystem.Colors.resolvedAccent.opacity(0.18),
                            lineWidth: 1
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Open your saved instruction prompts")
            .accessibilityHint("View, edit, and apply saved prompts")

            Spacer()

            CompactPersonaPicker()
        }
        .font(.caption2)
        .foregroundStyle(.quaternary)
    }

    private var savePromptPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Prompt")
                .font(.headline)

            TextField("Prompt name", text: $savePromptName)
                .textFieldStyle(.roundedBorder)

            if steeringManager.hasPrompt(named: savePromptName) {
                Text("A prompt with this name already exists.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    showSavePromptDialog = false
                }
                .buttonStyle(.sortyBordered)

                Spacer()

                Button("Save") {
                    steeringManager.addPrompt(
                        SavedSteeringPrompt(name: savePromptName, prompt: customPrompt)
                    )
                    showSavePromptDialog = false
                    HapticFeedbackManager.shared.success()
                }
                .buttonStyle(.sortyProminent)
                .disabled(
                    savePromptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || steeringManager.hasPrompt(named: savePromptName)
                )
            }
        }
        .padding(16)
        .frame(width: 280)
        .foregroundStyle(.primary)
        .systemLiquidGlassPopover(cornerRadius: 12)
    }

    private var trimmedCustomPrompt: String {
        customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var instructionSuggestions: [String] {
        InstructionSuggestionCatalog.suggestions(
            for: selectedMode,
            personaManager: personaManager,
            customPersonaStore: customPersonaStore
        )
    }

    private var currentInstructionSuggestion: String {
        instructionSuggestions[instructionSuggestionIndex % instructionSuggestions.count]
    }

    private var selectedModeManualAction: (title: String, description: String) {
        switch selectedMode {
        case .organize:
            return (
                "Run Organization",
                "Organize the files already in this folder without changing their names."
            )
        case .organizeAndRename:
            return (
                "Run Organization & Rename",
                "Organize the files already in this folder and improve their names."
            )
        case .renameOnly:
            return (
                "Run Rename",
                "Improve the names of files already in this folder without moving them."
            )
        }
    }

    private func acceptCurrentInstructionSuggestion() -> Bool {
        guard customPrompt.isEmpty else { return false }

        customPrompt = currentInstructionSuggestion
        instructionSelection = NSRange(
            location: (currentInstructionSuggestion as NSString).length,
            length: 0
        )
        HapticFeedbackManager.shared.selection()
        return true
    }

    private func improvePromptWithAI() async {
        guard !trimmedCustomPrompt.isEmpty else { return }
        isImprovingPrompt = true
        defer { isImprovingPrompt = false }

        do {
            let client = try AIClientFactory.createClient(config: settingsViewModel.config)
            let outcome = try await ImproveInstructionsTool.run(
                client: client,
                originalInstructions: trimmedCustomPrompt,
                workflow: selectedMode.gerund
            )

            switch outcome {
            case .replacement(let improved):
                customPrompt = improved
                showImprovePromptRequest = false
                HapticFeedbackManager.shared.success()
            case .needsUserInput(let message):
                improvePromptRequestMessage = message
                showImprovePromptRequest = true
                HapticFeedbackManager.shared.selection()
            }
        } catch {
            HapticFeedbackManager.shared.error()
        }
    }

    private var globalAutomationSelection: (provider: AIProvider, model: String) {
        let provider =
            settingsViewModel.config.automationProvider ?? settingsViewModel.config.provider
        let configuredModel =
            settingsViewModel.config.automationProvider == nil
            ? settingsViewModel.config.model
            : (settingsViewModel.config.automationModel ?? "")
        let model = configuredModel.isEmpty ? provider.defaultModel : configuredModel
        return (provider, model)
    }

    private func primeModelSelectionFromGlobalDefaultsIfNeeded() {
        guard folder.modelOverride == nil || folder.providerOverride == nil else {
            return
        }

        let defaults = globalAutomationSelection
        selectedProvider = defaults.provider
        selectedModel = defaults.model
    }

    private var currentFolderConfiguration: WatchedFolder {
        var updated = folder
        updated.organizationMode = selectedMode
        updated.applyPolicy = selectedApplyPolicy
        updated.customPrompt =
            customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : customPrompt

        if useCustomModel {
            updated.providerOverride = selectedProvider
            updated.modelOverride = selectedModel
        } else {
            updated.providerOverride = nil
            updated.modelOverride = nil
        }

        return updated
    }

    private func openFullOrganization() {
        HapticFeedbackManager.shared.tap()

        let updatedFolder = currentFolderConfiguration
        watchedFoldersManager.updateFolder(updatedFolder)

        var config = settingsViewModel.config
        config.enableSmartRename = true
        config.mode = updatedFolder.effectiveOrganizationMode
        settingsViewModel.config = config

        onOpenFullOrganization(updatedFolder)
        dismiss()
    }

    private func save() {
        withAnimation {
            watchedFoldersManager.updateFolder(currentFolderConfiguration)
        }
        dismiss()
    }
}

private struct WatchedFolderRecentActions: View {
    @SortyHotReload private var hotReload
    private static let visibleActionCount = 3

    private struct ActionAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    let folder: WatchedFolder
    @ObservedObject var history: OrganizationHistory
    @EnvironmentObject private var organizer: FolderOrganizer
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @EnvironmentObject private var learningsManager: LearningsManager
    @State private var undoingEntryID: UUID?
    @State private var selectedEntry: OrganizationHistoryEntry?
    @State private var isProcessing = false
    @State private var actionAlert: ActionAlert?
    @ScaledMetric(relativeTo: .body) private var actionRowHeight = 48

    private var recentEntries: [OrganizationHistoryEntry] {
        let folderPath = normalizedPath(folder.path)
        return history.entries.filter { entry in
            entry.source == .watchedFolder && normalizedPath(entry.directoryPath) == folderPath
        }
    }

    private var actionListHeight: CGFloat {
        let visibleRowCount = min(recentEntries.count, Self.visibleActionCount)
        guard visibleRowCount > 0 else { return 0 }

        let dividerCount = max(visibleRowCount - 1, 0)
        return CGFloat(visibleRowCount) * actionRowHeight + CGFloat(dividerCount)
    }

    var body: some View {
        Group {
            if recentEntries.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.questionmark")
                        .foregroundStyle(.secondary)
                    Text("No AI actions for this folder yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(recentEntries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                Divider()
                                    .padding(.leading, 28)
                            }

                            actionRow(entry)
                                .padding(.vertical, 7)
                        }
                    }
                }
                .frame(height: actionListHeight)
            }
        }
        .sheet(item: $selectedEntry) { entry in
            HistoryDetailSheet(
                entry: entry,
                isProcessing: $isProcessing,
                onAction: { message in
                    actionAlert = ActionAlert(title: "History Action", message: message)
                },
                onDismiss: {
                    selectedEntry = nil
                }
            )
            .environmentObject(organizer)
            .environmentObject(settingsViewModel)
            .environmentObject(learningsManager)
        }
        .alert(item: $actionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func actionRow(_ entry: OrganizationHistoryEntry) -> some View {
        HStack(spacing: 10) {
            Button {
                openDetails(for: entry)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: iconName(for: entry))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color(for: entry))
                        .frame(width: 18)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary(for: entry))
                            .font(.subheadline)
                            .lineLimit(1)
                            .numericTextTransition(animationValue: summary(for: entry))

                        Text(entry.timestamp, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(summary(for: entry)), \(entry.timestamp.formatted(date: .abbreviated, time: .shortened))"
            )
            .accessibilityHint("Open session details")
            .accessibilityIdentifier("WatchedFolderRecentAction-\(entry.id.uuidString)")

            if canUndo(entry) {
                Button {
                    undo(entry)
                } label: {
                    if undoingEntryID == entry.id {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 36)
                    } else {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                }
                .buttonStyle(.sortyBordered)
                .controlSize(.small)
                .disabled(undoingEntryID != nil)
                .accessibilityHint("Restores the files changed by this AI action")
            }
        }
    }

    private func openDetails(for entry: OrganizationHistoryEntry) {
        HapticFeedbackManager.shared.selection()
        selectedEntry = entry
    }

    private func undo(_ entry: OrganizationHistoryEntry) {
        guard undoingEntryID == nil else { return }
        undoingEntryID = entry.id
        Task { @MainActor in
            defer { undoingEntryID = nil }
            do {
                _ = try await organizer.undoHistoryEntry(entry)
                HapticFeedbackManager.shared.success()
            } catch {
                HapticFeedbackManager.shared.error()
                actionAlert = ActionAlert(
                    title: "Couldn’t Undo Action",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func canUndo(_ entry: OrganizationHistoryEntry) -> Bool {
        !entry.isUndone
            && entry.storedOperationCount > 0
            && (entry.status == .completed || entry.status == .partiallyUndone)
    }

    private func summary(for entry: OrganizationHistoryEntry) -> String {
        switch entry.status {
        case .completed:
            let count = entry.filesOrganized
            return "Organized \(count) file\(count == 1 ? "" : "s")"
        case .partiallyUndone:
            return "Partially undid this action"
        case .undo:
            return "Undid this action"
        case .failed:
            return "AI organization failed"
        case .cancelled:
            return "AI organization was cancelled"
        case .skipped:
            return "AI organization was skipped"
        case .duplicatesCleanup:
            return "Cleaned up duplicates"
        }
    }

    private func iconName(for entry: OrganizationHistoryEntry) -> String {
        switch entry.status {
        case .completed: "checkmark.circle.fill"
        case .partiallyUndone: "arrow.uturn.backward.circle"
        case .undo: "arrow.uturn.backward.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        case .skipped: "forward.circle.fill"
        case .duplicatesCleanup: "doc.on.doc.fill"
        }
    }

    private func color(for entry: OrganizationHistoryEntry) -> Color {
        switch entry.status {
        case .completed: .green
        case .partiallyUndone, .skipped: .orange
        case .undo: .blue
        case .failed: .red
        case .cancelled: .secondary
        case .duplicatesCleanup: .purple
        }
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

// MARK: - Config Section

#Preview {
    WatchedFoldersView()
        .environmentObject(WatchedFoldersManager())
        .environmentObject(FolderOrganizer())
        .frame(width: 600, height: 500)
}
