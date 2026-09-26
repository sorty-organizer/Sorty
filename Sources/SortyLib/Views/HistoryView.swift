//
//  HistoryView.swift
//  Sorty
//
//  Advanced History view with 6 stats, card-based layout matching DuplicatesView style
//  Enhanced with haptic feedback, micro-animations, and full ARIA accessibility
//

import AppKit
import SwiftUI

struct HistoryImpactSummary: Equatable {
    var filesOrganized = 0
    var foldersCreated = 0
    var totalSessions = 0
    var completedSessions = 0
    var totalTimeSaved: TimeInterval = 0

    init(entries: [OrganizationHistoryEntry] = []) {
        totalSessions = entries.count

        for entry in entries where entry.status == .completed {
            filesOrganized += entry.filesOrganized
            foldersCreated += entry.foldersCreated
            completedSessions += 1
            totalTimeSaved += entry.storedEstimatedTimeSaved ?? 0
        }
    }

    var successRate: Double {
        guard totalSessions > 0 else { return 0 }
        return Double(completedSessions) / Double(totalSessions)
    }
}

struct HistorySessionRow: Identifiable, Equatable {
    let id: UUID
    let directoryPath: String
    let folderName: String
    let timestamp: Date
    let status: OrganizationStatus
    let filesOrganized: Int
    let foldersCreated: Int
    let duplicatesDeleted: Int?
    let recoveredSpace: Int64?
    let generationMetadata: String?
    let thumbnailLoadDelay: Duration

    init(entry: OrganizationHistoryEntry, thumbnailLoadIndex: Int) {
        id = entry.id
        directoryPath = entry.directoryPath
        folderName = entry.displayName
        timestamp = entry.timestamp
        status = entry.status
        filesOrganized = entry.filesOrganized
        foldersCreated = entry.foldersCreated
        duplicatesDeleted = entry.duplicatesDeleted
        recoveredSpace = entry.recoveredSpace
        thumbnailLoadDelay = .milliseconds(250 + min(thumbnailLoadIndex, 12) * 35)

        if let modelName = entry.storedGenerationModelName {
            generationMetadata = entry.storedHasBillableCost
                ? "\(modelName) · \(GenerationStats.formatCost(entry.storedEstimatedCost ?? 0))"
                : modelName
        } else {
            generationMetadata = nil
        }
    }
}

private struct HistorySessionRecord: Equatable {
    let row: HistorySessionRow
    let directoryPath: String
    let source: OrganizationEntrySource
    let isUndone: Bool
    let hasOperations: Bool

    init(entry: OrganizationHistoryEntry, thumbnailLoadIndex: Int) {
        row = HistorySessionRow(entry: entry, thumbnailLoadIndex: thumbnailLoadIndex)
        directoryPath = entry.directoryPath
        source = entry.source
        isUndone = entry.isUndone
        hasOperations = entry.storedOperationCount > 0
    }
}

/// Caches the derived history snapshot across HistoryView rebuilds so tab
/// switches reuse the last computed records instead of remapping every entry.
/// Entries publish on willSet while `revision` bumps on didSet, so a stored
/// snapshot is only served when no mutation happened since it was computed.
@MainActor
private enum HistorySnapshotCache {
    private static var historyID: ObjectIdentifier?
    private static var revision: UInt64?
    private static var records: [HistorySessionRecord] = []
    private static var summary = HistoryImpactSummary()

    static func snapshot(
        for history: OrganizationHistory
    ) -> (records: [HistorySessionRecord], summary: HistoryImpactSummary)? {
        guard historyID == ObjectIdentifier(history), revision == history.revision else {
            return nil
        }
        return (records, summary)
    }

    static func store(
        records: [HistorySessionRecord],
        summary: HistoryImpactSummary,
        for history: OrganizationHistory
    ) {
        historyID = ObjectIdentifier(history)
        revision = history.revision
        self.records = records
        self.summary = summary
    }
}

struct HistoryView: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var organizer: FolderOrganizer
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var appState: AppState
    @State private var selectedEntry: OrganizationHistoryEntry?
    @State private var isProcessing = false
    @State private var alertMessage: String?
    @State private var showAlert = false
    @State private var selectedFilter: HistoryFilter = .all
    @State private var searchText: String = ""
    @State private var showingDetail = false
    @State private var showRedoModelPicker = false
    @State private var redoModelEntry: OrganizationHistoryEntry?
    @State private var activeNotificationRedoRequestID: UUID?
    @State private var cachedEntries: [OrganizationHistoryEntry] = []
    @State private var cachedSessionRecords: [HistorySessionRecord] = []
    @State private var filteredChronologicalEntries: [HistorySessionRow] = []
    @State private var filteredManualEntries: [HistorySessionRow] = []
    @State private var filteredWatchedEntries: [HistorySessionRow] = []
    @State private var collapsedSections: Set<HistorySectionKind> = []
    @State private var impactSummary = HistoryImpactSummary()
    @State private var displayedEntryCount = 50
    private let pageSize = 50

    private var hasFilteredEntries: Bool {
        !filteredChronologicalEntries.isEmpty
    }

    private var matchingSessionCount: Int {
        filteredChronologicalEntries.count
    }

    private var chronologicalEntries: ArraySlice<HistorySessionRow> {
        filteredChronologicalEntries.prefix(displayedEntryCount)
    }

    private var manualEntries: ArraySlice<HistorySessionRow> {
        filteredManualEntries.prefix(displayedEntryCount)
    }

    private var watchedEntries: ArraySlice<HistorySessionRow> {
        filteredWatchedEntries.prefix(displayedEntryCount)
    }

    private var hasMoreEntries: Bool {
        if selectedFilter == .all {
            return chronologicalEntries.count < filteredChronologicalEntries.count
        }
        return manualEntries.count < filteredManualEntries.count ||
            watchedEntries.count < filteredWatchedEntries.count
    }

    private enum HistorySectionKind: Hashable {
        case manual
        case watched

        var title: String {
            switch self {
            case .manual: "Sessions You Started"
            case .watched: "Watched Folder Automations"
            }
        }

        var systemImage: String {
            switch self {
            case .manual: "person.fill"
            case .watched: "bolt.horizontal.circle"
            }
        }
    }

    private var primarySectionKind: HistorySectionKind {
        selectedFilter == .watched || manualEntries.isEmpty ? .watched : .manual
    }

    private var showsSecondaryWatchedSection: Bool {
        primarySectionKind == .manual && !watchedEntries.isEmpty
    }

    private var historyCardTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .top)),
            removal: .opacity
        )
        .animation(.easeInOut(duration: 0.18))
    }

    private var filterSelection: Binding<HistoryFilter> {
        Binding(
            get: { selectedFilter },
            set: { newSelection in
                guard newSelection != selectedFilter else { return }
                selectedFilter = newSelection
                displayedEntryCount = pageSize
                refreshFilteredEntries(in: cachedSessionRecords, using: newSelection)
            }
        )
    }

    enum HistoryFilter: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case undoable = "Undoable"
        case failed = "Failed"
        case skipped = "Skipped"
        case cancelled = "Cancelled"
        case manual = "Manual"
        case watched = "Watched"

        var id: String { rawValue }

        var detailedLabel: String {
            switch self {
            case .manual: "Sessions You Started"
            default: rawValue
            }
        }

        var systemImage: String {
            switch self {
            case .all: "tray.full"
            case .undoable: "arrow.uturn.backward.circle"
            case .failed: "exclamationmark.triangle"
            case .skipped: "forward"
            case .cancelled: "xmark.circle"
            case .manual: "hand.tap"
            case .watched: "eye"
            }
        }

        func includes(
            status: OrganizationStatus,
            source: OrganizationEntrySource,
            isUndone: Bool = false,
            hasOperations: Bool = false
        ) -> Bool {
            switch self {
            case .all: true
            case .undoable:
                !isUndone &&
                    hasOperations &&
                    (status == .completed || status == .partiallyUndone)
            case .failed: status == .failed
            case .skipped: status == .skipped
            case .cancelled: status == .cancelled
            case .manual: source == .manual
            case .watched: source == .watchedFolder
            }
        }
    }

    var body: some View {
        Group {
            if cachedEntries.count > 1 {
                content
                    .searchable(text: $searchText, prompt: "Search folders")
            } else {
                content
            }
        }
        .onReceive(organizer.history.$entries) { entries in
            refreshHistorySnapshot(entries)
            consumePendingHistoryEntryIfNeeded()
            if entries.count <= 1 {
                searchText = ""
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if cachedEntries.isEmpty {
                ZStack(alignment: .topLeading) {
                    HistoryEmptyStateView()
                        .transition(TransitionStyles.scaleAndFade)
                        .animatedAppearance(delay: 0.08)

                    HistoryHeader(
                        totalSessions: impactSummary.totalSessions,
                        selectedFilter: filterSelection,
                        showsControls: false,
                        onClearHistory: {
                            appState.clearHistoryWithConfirmation()
                        }
                    )
                    .animatedAppearance(delay: 0.03)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Header - matches DuplicatesView style
                HistoryHeader(
                    totalSessions: matchingSessionCount,
                    selectedFilter: filterSelection,
                    showsControls: true,
                    onClearHistory: {
                        appState.clearHistoryWithConfirmation()
                    }
                )
                .animatedAppearance(delay: 0.03)

                Divider()

                ZStack {
                    if !searchText.isEmpty && !hasFilteredEntries {
                        HistorySearchEmptyStateView(searchText: searchText, onClear: { searchText = "" })
                            .transition(TransitionStyles.scaleAndFade)
                    } else {
                        historyEntriesScroll
                            .background(Color(NSColor.windowBackgroundColor))
                            .transition(TransitionStyles.slideFromRight)
                            .animatedAppearance(delay: 0.08)
                    }
                }
            }
        }
        .emptyStateWorkflowGradient(isVisible: cachedEntries.isEmpty)
        .animation(.pageTransition, value: cachedEntries.isEmpty)
        .navigationTitle("History")
        .disabled(isProcessing)
        .overlay {
            if isProcessing {
                ProcessingOverlay(stage: organizer.organizationStage)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isProcessing)
        .alert("History Action", isPresented: $showAlert) {
            Button("OK", role: .cancel) {
                HapticFeedbackManager.shared.tap()
            }
        } message: {
            if let msg = alertMessage {
                Text(msg)
            }
        }
        .sheet(isPresented: $showingDetail) {
            if let entry = selectedEntry {
                HistoryDetailSheet(
                    entry: entry,
                    isProcessing: $isProcessing,
                    onAction: { msg in
                        alertMessage = msg
                        showAlert = true
                    },
                    onDismiss: {
                        showingDetail = false
                        selectedEntry = nil
                    }
                )
                .environmentObject(organizer)
            }
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
                guard let entry = redoModelEntry else { return }
                if let authMethod {
                    settingsViewModel.config.setAuthMethod(authMethod, for: provider)
                }
                showRedoModelPicker = false
                handleRedoWithModel(entry, provider: provider, model: model)
            },
            isSubscriptionSelected: settingsViewModel.config.authMethod(for: settingsViewModel.config.provider) == .accountSignIn
        )
        .onAppear {
            consumePendingHistoryEntryIfNeeded()
            consumePendingNotificationActionIfNeeded()
        }
        .onChange(of: appState.pendingHistoryEntryID) { _, _ in
            consumePendingHistoryEntryIfNeeded()
        }
        .onChange(of: searchText) { _, _ in
            displayedEntryCount = pageSize
            refreshFilteredEntries()
        }
        .onChange(of: appState.pendingNotificationActionRequest?.id) { _, _ in
            consumePendingNotificationActionIfNeeded()
        }
        .onChange(of: showRedoModelPicker) { oldValue, newValue in
            guard oldValue, !newValue, activeNotificationRedoRequestID != nil else { return }
            NotificationManager.shared.recordActionLifecycle("redo_with_model", stage: "cancelled", detail: "history picker")
            activeNotificationRedoRequestID = nil
        }
    }

    private var historyEntriesScroll: some View {
        List {
            HistorySummaryCard(summary: impactSummary)
                .padding(.top, 10)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("History Summary")
                .listRowInsets(EdgeInsets(top: 6, leading: 28, bottom: 12, trailing: 28))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if selectedFilter == .all {
                historySessionRows(chronologicalEntries)
            } else {
                historySessionsSection(primarySectionKind)

                if showsSecondaryWatchedSection {
                    historySessionsSection(.watched)
                }
            }

            if hasMoreEntries {
                LoadMoreHistoryRow {
                    displayedEntryCount += pageSize
                }
                .task(id: displayedEntryCount) {
                    await Task.yield()
                    guard hasMoreEntries else { return }
                    displayedEntryCount += pageSize
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 28, bottom: 16, trailing: 28))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private func historySessionsSection(_ kind: HistorySectionKind) -> some View {
        let entries = kind == .manual ? manualEntries : watchedEntries
        let totalCount = kind == .manual ? filteredManualEntries.count : filteredWatchedEntries.count
        let isCollapsed = collapsedSections.contains(kind)

        if !entries.isEmpty {
            Button {
                HapticFeedbackManager.shared.selection()
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    if isCollapsed {
                        collapsedSections.remove(kind)
                    } else {
                        collapsedSections.insert(kind)
                    }
                }
            } label: {
                HStack {
                    Label {
                        Text(kind.title)
                            .numericTextTransition(animationValue: kind.title)
                    } icon: {
                        Image(systemName: kind.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .accessibilityHidden(true)
                    }
                        .font(.headline)
                    Spacer()
                    Text("\(totalCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .numericTextTransition(animationValue: totalCount)
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                        .symbolReplaceTransition(animationValue: isCollapsed)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            .accessibilityHint(isCollapsed ? "Expands this category" : "Collapses this category")
            .listRowInsets(EdgeInsets(top: 2, leading: 28, bottom: 0, trailing: 28))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if !isCollapsed {
                historySessionRows(entries)
            }
        }
    }

    private func historySessionRows(_ entries: ArraySlice<HistorySessionRow>) -> some View {
        // Snapshot main-actor view state for the Sendable scroll-transition closure below.
        let reduceMotionSnapshot = reduceMotion
        return ForEach(entries) { entry in
            HistorySessionCard(
                entry: entry,
                isSelected: selectedEntry?.id == entry.id,
                onSelect: {
                    HapticFeedbackManager.shared.selection()
                    selectEntry(id: entry.id)
                }
            )
            .transition(historyCardTransition)
            .scrollTransition(
                topLeading: .identity,
                bottomTrailing: reduceMotion
                    ? .identity
                    : .interactive(timingCurve: .easeOut)
                        .threshold(.visible(0.12)),
                axis: .vertical
            ) { content, phase in
                content
                    .opacity(!reduceMotionSnapshot && phase == .bottomTrailing ? 0.86 : 1)
                    .scaleEffect(
                        !reduceMotionSnapshot && phase == .bottomTrailing ? 0.988 : 1,
                        anchor: .top
                    )
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 28, bottom: 8, trailing: 28))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    private func refreshHistorySnapshot(_ entries: [OrganizationHistoryEntry]) {
        let history = organizer.history
        let records: [HistorySessionRecord]
        let summary: HistoryImpactSummary

        if let cached = HistorySnapshotCache.snapshot(for: history) {
            (records, summary) = cached
        } else {
            records = entries.enumerated().map { index, entry in
                HistorySessionRecord(entry: entry, thumbnailLoadIndex: index)
            }
            summary = HistoryImpactSummary(entries: entries)
            HistorySnapshotCache.store(records: records, summary: summary, for: history)
        }

        cachedEntries = entries
        cachedSessionRecords = records
        impactSummary = summary
        refreshFilteredEntries(in: records)
    }

    private func refreshFilteredEntries() {
        refreshFilteredEntries(in: cachedSessionRecords)
    }

    private func refreshFilteredEntries(
        in records: [HistorySessionRecord],
        using filter: HistoryFilter? = nil
    ) {
        let activeFilter = filter ?? selectedFilter
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var manual: [HistorySessionRow] = []
        var watched: [HistorySessionRow] = []
        var chronological: [HistorySessionRow] = []
        chronological.reserveCapacity(records.count)
        manual.reserveCapacity(records.count)
        watched.reserveCapacity(records.count / 4)

        for record in records {
            guard activeFilter.includes(
                status: record.row.status,
                source: record.source,
                isUndone: record.isUndone,
                hasOperations: record.hasOperations
            ) else {
                continue
            }
            guard query.isEmpty || record.directoryPath.localizedCaseInsensitiveContains(query) else {
                continue
            }

            chronological.append(record.row)
            switch record.source {
            case .manual:
                manual.append(record.row)
            case .watchedFolder:
                watched.append(record.row)
            }
        }

        filteredChronologicalEntries = chronological.sorted { $0.timestamp > $1.timestamp }
        filteredManualEntries = manual
        filteredWatchedEntries = watched
    }

    private func selectEntry(id: UUID) {
        guard let entry = cachedEntries.first(where: { $0.id == id }) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            selectedEntry = entry
            showingDetail = true
        }
    }

    private func consumePendingHistoryEntryIfNeeded() {
        guard let entryID = appState.pendingHistoryEntryID,
              cachedEntries.contains(where: { $0.id == entryID }) else { return }
        appState.pendingHistoryEntryID = nil
        selectEntry(id: entryID)
    }

    private func handleRedoWithModel(_ entry: OrganizationHistoryEntry, provider: AIProvider, model: String) {
        isProcessing = true
        if activeNotificationRedoRequestID != nil {
            NotificationManager.shared.recordActionLifecycle("redo_with_model", stage: "confirmed", detail: "\(provider.displayName):\(model)")
            NotificationManager.shared.recordActionLifecycle("redo_with_model", stage: "executing", detail: entry.directoryPath)
        }
        Task { @MainActor in
            do {
                // First set up the folder context from history entry
                let directoryURL = URL(fileURLWithPath: entry.directoryPath)
                organizer.currentDirectory = directoryURL

                // Generate new plan with specified provider/model
                try await organizer.regenerateWithModel(provider: provider, model: model)
                HapticFeedbackManager.shared.success()
                alertMessage = "New organization generated with \(provider.displayName) (\(model))."
                showAlert = true
                if activeNotificationRedoRequestID != nil {
                    NotificationManager.shared.recordActionLifecycle("redo_with_model", stage: "completed", detail: entry.directoryPath)
                    activeNotificationRedoRequestID = nil
                }
            } catch {
                HapticFeedbackManager.shared.error()
                alertMessage = "Error: \(error.localizedDescription)"
                showAlert = true
                if activeNotificationRedoRequestID != nil {
                    NotificationManager.shared.recordActionLifecycle("redo_with_model", stage: "failed", failed: true, detail: error.localizedDescription)
                    activeNotificationRedoRequestID = nil
                }
            }
            isProcessing = false
        }
    }

    private func consumePendingNotificationActionIfNeeded() {
        guard let request = appState.pendingNotificationActionRequest else { return }
        guard request.kind == .redoWithModelConfirmation else { return }
        guard request.notificationType != "previewReady" else { return }
        guard let targetEntry = notificationRedoTargetEntry(for: request.folderPath) else { return }

        redoModelEntry = targetEntry
        activeNotificationRedoRequestID = request.id
        NotificationManager.shared.recordActionLifecycle("redo_with_model", stage: "confirmation_shown", detail: targetEntry.directoryPath)
        showRedoModelPicker = true
        appState.clearNotificationActionRequest(id: request.id)
    }

    private func notificationRedoTargetEntry(for folderPath: String?) -> OrganizationHistoryEntry? {
        if let folderPath {
            let normalizedPath = URL(fileURLWithPath: folderPath).standardizedFileURL.path
            if let matchingEntry = organizer.history.entries.first(where: {
                URL(fileURLWithPath: $0.directoryPath).standardizedFileURL.path == normalizedPath
            }) {
                return matchingEntry
            }
        }

        return organizer.history.entries.first
    }
}

// MARK: - History Header

struct HistorySearchEmptyStateView: View {
    @SortyHotReload private var hotReload
    let searchText: String
    let onClear: () -> Void

    @State private var hasAppeared = false
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 80, height: 80)

                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.8)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: hasAppeared)

            VStack(spacing: 8) {
                Text("No Results Found")
                    .font(.title3.bold())

                Text("No history entries match \"\(searchText)\"")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 10)
            .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.1), value: hasAppeared)

            Button {
                HapticFeedbackManager.shared.tap()
                onClear()
            } label: {
                Label("Clear Search", systemImage: "xmark.circle")
            }
            .buttonStyle(.sortyBordered)
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.spring(response: 0.2), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    HapticFeedbackManager.shared.selection()
                }
            }
            .opacity(hasAppeared ? 1 : 0)
            .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.2), value: hasAppeared)
            .accessibilityIdentifier("ClearSearchButton")

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            hasAppeared = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("No search results for \(searchText)")
    }
}

// MARK: - History Empty State

struct HistoryEmptyStateView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Hero section
            VStack(spacing: 16) {
                EmptyStateHeroIcon(systemName: "clock.arrow.circlepath")
                    .opacity(hasAppeared ? 1 : 0)
                    .scaleEffect(hasAppeared ? 1 : 0.8)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.1), value: hasAppeared)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("No History Yet")
                        .font(.title2.bold())

                    Text("Organize a folder to start tracking sessions, results, and actions you can revisit later.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 10)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: hasAppeared)
            }

            // CTA button
            Button {
                HapticFeedbackManager.shared.tap()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    appState.currentView = .organize
                }
            } label: {
                Text("Start Organizing")
            }
            .buttonStyle(.sortyPrimary)
            .onboardingBeamBorder(
                variant: .featured,
                active: hasAppeared,
                isIntensified: isHovered,
                includesInteriorGlow: isHovered
            )
            .controlSize(.large)
            .contentShape(Capsule())
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.84), value: isHovered)
            .onHover { hovering in
                if hovering && !isHovered {
                    HapticFeedbackManager.shared.selection()
                }
                isHovered = hovering
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 15)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: hasAppeared)
            .accessibilityLabel("Start organizing a folder")
            .accessibilityHint("Navigate to the organize view to begin")
            .accessibilityIdentifier("HistoryEmptyStateCTA")

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("No history yet. Organize a folder to start tracking your sessions.")
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                hasAppeared = true
            }
        }
    }
}

// MARK: - History Detail Sheet
