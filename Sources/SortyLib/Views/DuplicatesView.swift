//
//  DuplicatesView.swift
//  Sorty
//
//  UI for displaying and managing duplicate files
//  Enhanced with haptic feedback, "Liquid Glass" aesthetic, and Split View layout
//

import AppKit
import Foundation
import SwiftUI
import Beam

struct DuplicatesView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var detectionManager: DuplicateDetectionManager
    @EnvironmentObject var settingsManager: DuplicateSettingsManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State private var showDeleteConfirmation = false
    @State private var filesToDelete: [FileItem] = []
    @State private var cleanupErrorMessage: String?
    @State private var isCleaningUp = false
    @State private var showSettings = false
    @State private var handoffFilePaths: [String] = []
    @State private var currentScanTask: Task<Void, Never>?
    @State private var isExactSectionExpanded = true
    @State private var isSimilarSectionExpanded = true
    @State private var capturedDirectory: URL?
    @State private var currentScanID = UUID()
    @State private var semanticScanProgress: String?

    // Derived directory: Use local if set, otherwise fallback to global
    private var effectiveDirectory: URL? {
        appState.duplicateSelectedDirectory ?? appState.selectedDirectory
    }

    private var isShowingEmptyContent: Bool {
        guard effectiveDirectory != nil else { return true }

        switch detectionManager.state {
        case .preparing, .scanning:
            return false
        case .idle:
            return detectionManager.allGroups.isEmpty
        case .completed, .failed:
            return detectionManager.allGroups.isEmpty
        }
    }

    private var isPreparingScan: Bool {
        detectionManager.state == .preparing
    }

    private var duplicateScanProgress: Double {
        guard case .scanning(let progress) = detectionManager.state else { return 0 }
        return progress
    }

    var body: some View {
        VStack(spacing: 0) {
            if effectiveDirectory == nil {
                // Base page: Workspace-Health-style layout
                ZStack(alignment: .topLeading) {
                    duplicatesBaseEmptyState()
                        .padding(32)
                        .animatedAppearance(delay: 0.08)

                    duplicatesBaseHeaderSection()
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .animatedAppearance(delay: 0.03)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Header
                DuplicatesHeaderNew(
                    manager: detectionManager,
                    currentDirectory: effectiveDirectory,
                    isCleaningUp: isCleaningUp,
                    onSelectDirectory: selectDirectory,
                    onScan: startScan,
                    onCancel: cancelScan,
                    onBulkDelete: prepareBulkDelete,
                    onSettings: { showSettings = true }
                )
                .animatedAppearance(delay: 0.03)

                ZStack {
                    switch detectionManager.state {
                    case .preparing, .scanning:
                        ScanProgressViewNew(
                            progress: duplicateScanProgress,
                            isPreparing: isPreparingScan,
                            stage: detectionManager.scanStage
                        )
                            .transition(.opacity)

                    case .idle:
                        if !detectionManager.allGroups.isEmpty {
                            // A cancelled rescan keeps the previous groups, so
                            // show the retained results instead of claiming the
                            // folder is duplicate-free.
                            resultsView
                            .transition(.opacity)
                        } else if detectionManager.lastScanDate == nil {
                            DuplicatesEmptyStateView(
                                title: "Ready to Scan",
                                description:
                                    "Identical files in \(effectiveDirectory?.lastPathComponent ?? "this folder") will be identified.",
                                icon: "waveform.path.ecg",
                                iconColor: SortyDesignSystem.Colors.resolvedAccent,
                                actionTitle: "Start Scan",
                                animatesIcon: true,
                                isDefaultAction: true,
                                action: startScan
                            )
                            .transition(.opacity)
                        } else {
                            noDuplicatesView
                                .transition(.opacity)
                        }

                    case .completed, .failed:
                        if detectionManager.allGroups.isEmpty {
                            noDuplicatesView
                            .transition(.opacity)
                        } else {
                            resultsView
                            .transition(.opacity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.sortySpringStandard, value: detectionManager.state)
                .animation(.sortySpringStandard, value: effectiveDirectory)
            }
        }
        .emptyStateWorkflowGradient(isVisible: isShowingEmptyContent)
        .navigationTitle("Duplicate Files")
        .alert("Move Duplicate Files to Trash?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                HapticFeedbackManager.shared.tap()
            }
            Button("Move to Trash", role: .destructive) {
                HapticFeedbackManager.shared.error()
                AnalyticsManager.shared.captureImportantButton(
                    "confirm_duplicate_cleanup",
                    screen: "duplicates",
                    feature: "duplicate_cleanup"
                )
                Task { await deleteFiles(filesToDelete) }
            }
        } message: {
            Text(bulkCleanupConfirmationMessage)
        }
        .alert(
            "Cleanup Stopped",
            isPresented: Binding(
                get: { cleanupErrorMessage != nil },
                set: { if !$0 { cleanupErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cleanupErrorMessage ?? "")
        }
        .onAppear {
            consumePendingHandoffIfNeeded()
        }
        .onChange(of: effectiveDirectory) { _, _ in
            // Cancel in-flight scan if directory changes
            currentScanID = UUID()
            currentScanTask?.cancel()
            // Clear results when switching directories to prevent showing stale data
            detectionManager.clearResults()
            appState.duplicateSelectedGroup = nil
        }
        .onChange(of: appState.pendingDuplicatesHandoff) { _, handoff in
            guard let handoff else { return }
            apply(handoff: handoff)
        }
        .onDisappear {
            currentScanID = UUID()
            currentScanTask?.cancel()
            currentScanTask = nil
            if detectionManager.isScanning || isPreparingScan {
                detectionManager.cancelCurrentScan()
            }
        }
        .sheet(isPresented: $showSettings) {
            DuplicateSettingsView(settingsManager: settingsManager)
        }
    }

    private func consumePendingHandoffIfNeeded() {
        guard let handoff = appState.pendingDuplicatesHandoff else { return }
        apply(handoff: handoff)
    }

    private func apply(handoff: AppState.DuplicatesHandoff) {
        currentScanID = UUID()
        currentScanTask?.cancel()
        currentScanTask = nil
        detectionManager.cancelCurrentScan()

        if let directory = handoff.directory {
            appState.duplicateSelectedDirectory = directory
            appState.selectedDirectory = directory
        }
        handoffFilePaths = handoff.filePaths

        detectionManager.clearResults()
        appState.duplicateSelectedGroup = nil
        appState.pendingDuplicatesHandoff = nil

        if handoff.autoStart, effectiveDirectory != nil {
            startScan()
        }
    }

    // MARK: - Base Page (No Directory Selected)

    @ViewBuilder
    private func duplicatesBaseHeaderSection() -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Duplicate Files")
                    .font(.largeTitle.bold())

                Text("Find identical files, recover disk space, and keep your workspace tidy")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func duplicatesBaseEmptyState() -> some View {
        DuplicatesEmptyStateView(
            title: "Select a Directory",
            description: "Choose a folder to scan for identical files and recover disk space",
            icon: "doc.on.doc",
            actionTitle: "Choose Directory",
            actionAccessibilityIdentifier: "DuplicatesEmptyChooseDirectory",
            action: selectDirectory
        )
    }

    private var noDuplicatesView: some View {
        DuplicatesEmptyStateView(
            title: detectionManager.unreadableFileCount > 0
                ? "Scan Incomplete"
                : "No Duplicates Found",
            description: detectionManager.unreadableFileCount > 0
                ? "Sorty couldn't read \(detectionManager.unreadableFileCount) file\(detectionManager.unreadableFileCount == 1 ? "" : "s"). Make cloud files available offline or reconnect the drive, then scan again."
                : "All readable files in this folder are unique.",
            icon: detectionManager.unreadableFileCount > 0
                ? "exclamationmark.triangle.fill"
                : "checkmark.circle.fill",
            heroTint: detectionManager.unreadableFileCount > 0 ? .orange : .green,
            actionTitle: "Scan Another Folder",
            celebratesAppearance: detectionManager.unreadableFileCount == 0,
            action: selectDirectory
        )
    }

    private var resultsView: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    DuplicatesResultsSidebarHeader(
                        manager: detectionManager,
                        showsStats: settingsViewModel.config.showStatsForNerds,
                        onScanAgain: startScan
                    )

                    Divider()

                    List(selection: $appState.duplicateSelectedGroup) {
                        if !exactGroups.isEmpty {
                            Section(isExpanded: $isExactSectionExpanded) {
                                ForEach(exactGroups) { group in
                                    UnifiedDuplicateGroupRow(group: group)
                                        .tag(group)
                                }
                            } header: {
                                DuplicateSectionHeader(
                                    title: "Exact duplicates",
                                    isExpanded: $isExactSectionExpanded,
                                    guidance: "Exact matches have identical content. Keep one copy, then remove the rest when you are confident about the location you want to preserve.",
                                    infoKey: "exactDuplicateGuidance"
                                )
                            }
                        }

                        if !similarGroups.isEmpty {
                            Section(isExpanded: $isSimilarSectionExpanded) {
                                ForEach(similarGroups) { group in
                                    UnifiedDuplicateGroupRow(group: group)
                                        .tag(group)
                                }
                            } header: {
                                DuplicateSectionHeader(
                                    title: "Similar files",
                                    isExpanded: $isSimilarSectionExpanded,
                                    guidance: "Similar files may be versions or variants. Review thumbnails, dates, and resolution before applying the recommendation.\n\nExcluded from Cleanup All. Review before applying a recommendation.",
                                    infoKey: "similarFileGuidance"
                                )
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
                .frame(width: 340, height: geometry.size.height, alignment: .topLeading)

                Divider()

                if let group = appState.duplicateSelectedGroup {
                    UnifiedDuplicateGroupDetailView(
                        group: group,
                        settings: settingsManager.settings,
                        onDelete: { files in
                            guard !isCleaningUp else { return }
                            filesToDelete = files
                            showDeleteConfirmation = true
                        }
                    )
                    .disabled(isCleaningUp)
                    .frame(
                        minWidth: 0,
                        maxWidth: .infinity,
                        minHeight: 0,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Choose a group")
                            .sortyTypography(.headline, weight: .medium)
                        Text(
                            "Review exact duplicates first. Similar files stay separate and need individual confirmation."
                        )
                        .sortyTypography(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .topLeading
            )
        }
    }

    private var exactGroups: [UnifiedDuplicateGroup] {
        detectionManager.allGroups.filter { $0.isExact }
    }

    private var similarGroups: [UnifiedDuplicateGroup] {
        detectionManager.allGroups.filter { $0.isSemantic }
    }

    private func startScan() {
        guard let directory = effectiveDirectory else { return }
        let handoffPaths = handoffFilePaths
        handoffFilePaths = []
        let settings = settingsManager.settings
        HapticFeedbackManager.shared.tap()

        // Cancel any in-flight scan and invalidate any work already returned by it.
        currentScanTask?.cancel()
        if detectionManager.isScanning || isPreparingScan {
            detectionManager.cancelCurrentScan()
        }
        let scanID = UUID()
        currentScanID = scanID

        // Capture current directory
        capturedDirectory = directory
        detectionManager.state = .preparing

        currentScanTask = Task {
            let scanner = DirectoryScanner()
            do {
                let scanSource = try await resolveFilesForScan(
                    scanner: scanner,
                    directory: directory,
                    handoffPaths: handoffPaths,
                    settings: settings,
                    scanID: scanID
                )

                // Only the active scan for the still-selected directory may publish results.
                if currentScanID == scanID,
                   capturedDirectory == directory,
                   directory == effectiveDirectory,
                   !Task.isCancelled {
                    switch scanSource {
                    case .inventory(let inventory):
                        await detectionManager.scanForDuplicates(
                            inventory: inventory,
                            settings: settings
                        )
                    case .files(let files):
                        await detectionManager.scanForDuplicates(
                            files: files,
                            settings: settings
                        )
                    }

                    if currentScanID == scanID, !Task.isCancelled {
                        // Auto-select first group
                        if let first = detectionManager.allGroups.first {
                            appState.duplicateSelectedGroup = first
                        }
                        HapticFeedbackManager.shared.success()
                    }
                }
            } catch {
                if currentScanID == scanID, !Task.isCancelled {
                    detectionManager.state = .failed(error.localizedDescription)
                    HapticFeedbackManager.shared.error()
                    DebugLogger.log("Duplicate scan failed: \(error)")
                    AnalyticsManager.shared.captureWorkflow(
                        workflow: "duplicate_scan",
                        stage: "preparing",
                        outcome: "failed"
                    )
                    ReliabilityManager.shared.capture(
                        error: error,
                        feature: "duplicates",
                        operation: "scan_directory"
                    )
                }
            }
        }
    }

    private func resolveFilesForScan(
        scanner: DirectoryScanner,
        directory: URL,
        handoffPaths: [String],
        settings: DuplicateSettings,
        scanID: UUID
    ) async throws -> ResolvedDuplicateScan {
        guard !handoffPaths.isEmpty else {
            guard currentScanID == scanID, !Task.isCancelled else {
                throw CancellationError()
            }
            let inventory = try await scanner.scanDirectoryForDuplicates(
                at: directory,
                settings: settings
            ) { scanned, stage in
                guard self.currentScanID == scanID, !Task.isCancelled else { return }
                self.detectionManager.scanStage = "\(stage) \(scanned.formatted()) scanned"
            }
            return .inventory(inventory)
        }

        var targetedFiles: [FileItem] = []
        for path in handoffPaths {
            if Task.isCancelled || currentScanID != scanID { break }

            let fileURL = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            if let scannedFile = try? await scanner.scanFile(
                at: fileURL,
                deepScan: false,
                computeHashes: false
            ), !scannedFile.isDirectory
            {
                targetedFiles.append(scannedFile)
            }
        }

        if targetedFiles.count >= 2 {
            return .files(targetedFiles)
        }

        // Fallback when history paths no longer exist or are insufficient.
        guard currentScanID == scanID, !Task.isCancelled else {
            throw CancellationError()
        }
        let inventory = try await scanner.scanDirectoryForDuplicates(
            at: directory,
            settings: settings
        ) { scanned, stage in
            guard self.currentScanID == scanID, !Task.isCancelled else { return }
            self.detectionManager.scanStage = "\(stage) \(scanned.formatted()) scanned"
        }
        return .inventory(inventory)
    }

    private enum ResolvedDuplicateScan {
        case inventory(DuplicateScanInventory)
        case files([FileItem])
    }

    private func cancelScan() {
        AnalyticsManager.shared.captureImportantButton(
            "cancel_duplicate_scan",
            screen: "duplicates",
            feature: "duplicate_scan"
        )
        currentScanID = UUID()
        currentScanTask?.cancel()
        currentScanTask = nil
        detectionManager.cancelCurrentScan()
        HapticFeedbackManager.shared.tap()
    }

    /// Trashes the pending files off the main actor, records the cleanup in
    /// History, then refreshes the scan. Stale or partial failures surface an
    /// alert instead of silently reporting success.
    private func deleteFiles(_ files: [FileItem]) async {
        // Bulk trashing is not re-entrant: a second cleanup would validate and
        // move files the first batch is already working on.
        guard !isCleaningUp else { return }
        isCleaningUp = true
        defer { isCleaningUp = false }

        var totalDeleted = 0
        var totalSizeRecovered: Int64 = 0
        var trashedPaths = Set<String>()

        do {
            let potentialRestorables = try await DuplicateRestorationManager.shared.moveToTrashAsync(
                files: files)
            totalDeleted = potentialRestorables.count
            totalSizeRecovered = files.reduce(0) { $0 + $1.size }
            trashedPaths.formUnion(potentialRestorables.map(\.originalPath))

            let entry = OrganizationHistoryEntry(
                directoryPath: effectiveDirectory?.path ?? "",
                filesOrganized: 0,
                foldersCreated: 0,
                success: true,
                status: .duplicatesCleanup,
                duplicatesDeleted: totalDeleted,
                recoveredSpace: totalSizeRecovered,
                restorableItems: potentialRestorables,
                duplicateCleanupMode: .trash
            )
            appState.organizer?.history.addEntry(entry)

            HapticFeedbackManager.shared.success()
            AnalyticsManager.shared.captureFeature(
                feature: "duplicates",
                subfeature: "cleanup",
                action: "move_to_trash",
                outcome: "success",
                properties: [
                    "count_bucket": AnalyticsManager.countBucket(totalDeleted),
                ]
            )
        } catch {
            // Files that already reached the Trash are kept restorable; the
            // `.duplicatesCleanup` status keeps History's restore action visible
            // even though the overall cleanup failed.
            if let partialFailure = error as? PartialTrashFailure {
                let movedItems = partialFailure.movedItems
                let deletedCount = movedItems.count
                let movedPaths = Set(movedItems.map(\.originalPath))
                trashedPaths.formUnion(movedPaths)
                let recoveredSpace = files
                    .filter { movedPaths.contains($0.path) }
                    .reduce(0) { $0 + $1.size }
                let errorMessage = error.localizedDescription
                let entry = OrganizationHistoryEntry(
                    directoryPath: effectiveDirectory?.path ?? "",
                    filesOrganized: 0,
                    foldersCreated: 0,
                    success: false,
                    status: .duplicatesCleanup,
                    errorMessage: errorMessage,
                    duplicatesDeleted: deletedCount,
                    recoveredSpace: recoveredSpace,
                    restorableItems: movedItems,
                    duplicateCleanupMode: .trash
                )
                appState.organizer?.history.addEntry(entry)
            }

            cleanupErrorMessage = error.localizedDescription
            HapticFeedbackManager.shared.error()
            DebugLogger.log("Delete failed: \(error)")
            AnalyticsManager.shared.captureFeature(
                feature: "duplicates",
                subfeature: "cleanup",
                action: "move_to_trash",
                outcome: "failed",
                properties: [
                    "count_bucket": AnalyticsManager.countBucket(files.count),
                ]
            )
            ReliabilityManager.shared.capture(
                error: error,
                feature: "duplicates",
                operation: "move_to_trash"
            )
        }

        // Drop the trashed files from the published groups before rescanning:
        // a cancelled rescan keeps the previous groups, and those must not
        // list files that already reached the Trash.
        pruneCleanedUpResults(trashedPaths)

        // Refresh the scan
        startScan()
    }

    /// Removes trashed paths from the published results and drops a selection
    /// that no longer exists, so a cancelled post-cleanup rescan cannot keep
    /// displaying deleted files.
    private func pruneCleanedUpResults(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        detectionManager.pruneResults(removingPaths: paths)

        if let selected = appState.duplicateSelectedGroup,
           !detectionManager.allGroups.contains(where: { $0.id == selected.id }) {
            appState.duplicateSelectedGroup = detectionManager.allGroups.first
        }
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            appState.duplicateSelectedDirectory = url
            detectionManager.clearResults()
            appState.duplicateSelectedGroup = nil
        }
    }

    /// Describes the pending set exactly: which group kinds are affected, how
    /// many files are removed, and which copies actually survive. The previous
    /// copy claimed similar files were never included, which is false for the
    /// per-file delete path.
    private var bulkCleanupConfirmationMessage: String {
        let pendingIDs = Set(filesToDelete.map(\.id))
        let affectedGroups = detectionManager.allGroups.filter { group in
            group.files.contains { pendingIDs.contains($0.id) }
        }
        let fileLabel = filesToDelete.count == 1 ? "file" : "files"

        guard !affectedGroups.isEmpty else {
            return "Sorty will move \(filesToDelete.count) \(fileLabel) to Trash. History can restore these files until Trash is emptied."
        }

        let exactGroups = affectedGroups.filter(\.isExact)
        let similarGroups = affectedGroups.filter(\.isSemantic)
        var groupSummary: [String] = []
        if !exactGroups.isEmpty {
            groupSummary.append(
                "\(exactGroups.count) exact-match group\(exactGroups.count == 1 ? "" : "s")"
            )
        }
        if !similarGroups.isEmpty {
            groupSummary.append(
                "\(similarGroups.count) similar-file group\(similarGroups.count == 1 ? "" : "s")"
            )
        }

        var message =
            "Sorty will move \(filesToDelete.count) \(fileLabel) to Trash across \(groupSummary.joined(separator: " and "))."
        message += " \(keeperSummary(for: affectedGroups, pendingIDs: pendingIDs))"
        message += " History can restore these files until Trash is emptied."
        return message
    }

    /// Names the survivors using the actual pending set, so the confirmation
    /// never credits the keep strategy when the user chose a different keeper.
    private func keeperSummary(
        for groups: [UnifiedDuplicateGroup],
        pendingIDs: Set<UUID>
    ) -> String {
        let survivingCount = groups.reduce(0) { total, group in
            total + group.files.filter { !pendingIDs.contains($0.id) }.count
        }

        guard survivingCount == groups.count else {
            return "\(survivingCount) file\(survivingCount == 1 ? "" : "s") in these groups stay."
        }

        let followsKeepStrategy = groups.allSatisfy { $0.isExact } && groups.allSatisfy { group in
            let keeperID = group.files.first { !pendingIDs.contains($0.id) }?.id
            return keeperID != nil && keeperID == CleanupPreferenceResolver.preferredFileID(
                in: group.files,
                strategy: settingsManager.settings.defaultKeepStrategy
            )
        }

        if followsKeepStrategy {
            return "One copy stays in each group (\(settingsManager.settings.defaultKeepStrategy.displayName))."
        }
        return "One file stays in each group."
    }

    private func prepareBulkDelete() {
        guard !isCleaningUp else { return }

        var filesToDelete: [FileItem] = []

        // Bulk cleanup is intentionally limited to byte-identical files.
        for group in detectionManager.allGroups where group.isExact {
            guard let keepFileID = CleanupPreferenceResolver.preferredFileID(
                in: group.files,
                strategy: settingsManager.settings.defaultKeepStrategy
            ), group.files.contains(where: { $0.id == keepFileID }) else {
                continue
            }

            filesToDelete.append(contentsOf: group.files.filter { $0.id != keepFileID })
        }
        if !filesToDelete.isEmpty {
            self.filesToDelete = filesToDelete
            self.showDeleteConfirmation = true
        }
    }
}

// MARK: - Redesigned Header

struct DuplicatesHeaderNew: View {
    @SortyHotReload private var hotReload
    @ObservedObject var manager: DuplicateDetectionManager
    let currentDirectory: URL?
    let isCleaningUp: Bool
    let onSelectDirectory: () -> Void
    let onScan: () -> Void
    let onCancel: () -> Void
    let onBulkDelete: () -> Void
    let onSettings: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            headerLayout(spacing: 20, showsFullControls: true)
                .frame(minWidth: 760)
            headerLayout(spacing: 12, showsFullControls: false)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var isScanInProgress: Bool {
        manager.isScanning || manager.state == .preparing
    }

    private func headerLayout(spacing: CGFloat, showsFullControls: Bool) -> some View {
        HStack(spacing: spacing) {
            // Left Side: Title & Target Folder
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.1))
                        .frame(width: 44, height: 44)

                    Image(systemName: "doc.on.doc.fill")
                        .foregroundStyle(.blue)
                        .sortyTypography(.title3, weight: .medium)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicate Files")
                        .sortyTypography(.headline, weight: .medium)
                        .lineLimit(1)

                    if let dir = currentDirectory {
                        Button(action: onSelectDirectory) {
                            HStack(spacing: 4) {
                                AppKitImageView(
                                    image: NSWorkspace.shared.icon(forFile: dir.path),
                                    size: CGSize(width: 16, height: 16)
                                )
                                .frame(width: 16, height: 16)
                                Text(dir.lastPathComponent)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .sortyTypography(.body)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                        .buttonStyle(.plain)
                        .help(PrivacyPathMasker.redactedPath(dir.path))
                    } else {
                        Text("No folder selected")
                            .sortyTypography(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 260, alignment: .leading)
            }
            .layoutPriority(1)

            Spacer()

            // Right Side: Controls
            HStack(spacing: showsFullControls ? 12 : 8) {
                HStack(spacing: 8) {
                    Button(action: onSettings) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .systemLiquidGlassButton()
                    .help("Detection Settings")
                    .accessibilityLabel("Duplicate detection settings")
                    .disabled(isScanInProgress)

                    if manager.exactGroupCount > 0 && !isScanInProgress {
                        Button {
                            onBulkDelete()
                        } label: {
                            Label(
                                showsFullControls ? "Clean Up Exact Copies" : "Clean Up",
                                systemImage: "trash"
                            )
                        }
                        .buttonStyle(.sortyPrimary(size: .small))
                        .tint(.red)
                        .disabled(isCleaningUp)
                        .help("Keep one preferred copy from every exact-match group and move the rest to Trash")
                    }

                    if isScanInProgress {
                        Button(action: onCancel) {
                            Label("Cancel", systemImage: "xmark")
                        }
                        .buttonStyle(.sortyPrimary(isSecondary: true, size: .small))
                        .tint(.red)
                    } else if manager.lastScanDate == nil {
                        Button(action: onScan) {
                            Label(
                                showsFullControls ? "Start Scan" : "Scan", systemImage: "play.fill")
                        }
                        .buttonStyle(.sortyPrimary(size: .small))
                        .disabled(currentDirectory == nil)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
    }
}

// MARK: - Components

private struct DuplicatesResultsSidebarHeader: View {
    @SortyHotReload private var hotReload
    @ObservedObject var manager: DuplicateDetectionManager
    let showsStats: Bool
    let onScanAgain: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsUnavailableFiles = false
    @AppStorage("duplicates.semanticCleanupNoticeDismissed")
    private var hasDismissedSemanticCleanupNotice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review groups")
                    .sortyTypography(.headline, weight: .medium)

                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .numericTextTransition(animationValue: summaryText)
            }

            if showsStats {
                DuplicatesNerdStatsStrip(manager: manager)
            }

            if manager.unreadableFileCount > 0 {
                Button {
                    HapticFeedbackManager.shared.selection()
                    showsUnavailableFiles.toggle()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .accessibilityHidden(true)
                        Text(
                            "\(manager.unreadableFileCount) file\(manager.unreadableFileCount == 1 ? " was" : "s were") unavailable and excluded from these results."
                        )
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .numericTextTransition(animationValue: manager.unreadableFileCount)
                .accessibilityHint("Shows the unavailable files and recovery options")
                .popover(isPresented: $showsUnavailableFiles, arrowEdge: .trailing) {
                    UnavailableDuplicateFilesPopover(
                        files: manager.unavailableFiles,
                        onScanAgain: {
                            showsUnavailableFiles = false
                            onScanAgain()
                        }
                    )
                }
            }

            if manager.semanticSkippedFileCount > 0 {
                Label(
                    "Exact duplicate results are complete. Similarity matching was skipped for this large folder to keep resource use stable.",
                    systemImage: "leaf"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if manager.semanticGroupCount > 0 && !hasDismissedSemanticCleanupNotice {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("Cleanup All only removes exact duplicates.", systemImage: "checkmark.shield")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 4)

                    Button("OK") {
                        HapticFeedbackManager.shared.tap()
                        withAnimation(noticeDismissAnimation) {
                            hasDismissedSemanticCleanupNotice = true
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                }
                .font(.caption)
                .transition(noticeDismissTransition)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var noticeDismissAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.24)
    }

    private var noticeDismissTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    private var summaryText: String {
        let exact = "\(manager.exactGroupCount) exact group\(manager.exactGroupCount == 1 ? "" : "s")"
        let similar = "\(manager.semanticGroupCount) similar file\(manager.semanticGroupCount == 1 ? "" : "s")"
        let recoverable = "\(manager.formattedSavings) safely recoverable"
        return [exact, similar, recoverable].joined(separator: " • ")
    }
}

private struct UnavailableDuplicateFilesPopover: View {
    @SortyHotReload private var hotReload
    let files: [UnavailableDuplicateFile]
    let onScanAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Unavailable Files")
                    .sortyTypography(.headline, weight: .medium)
                Text("Reconnect external drives or download cloud files, then scan again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(files) { file in
                        unavailableFileRow(file)
                        if file.id != files.last?.id {
                            Divider()
                                .padding(.leading, 44)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)

            Divider()

            HStack {
                Spacer()
                Button("Scan Again", action: onScanAgain)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.sortyPrimary(size: .small))
            }
            .padding(12)
        }
        .frame(width: 390)
    }

    private func unavailableFileRow(_ file: UnavailableDuplicateFile) -> some View {
        HStack(spacing: 10) {
            UnavailableFileIcon(fileURL: file.url)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(file.reason.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Menu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                    HapticFeedbackManager.shared.success()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Options for \(file.url.lastPathComponent)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }
}

private struct UnavailableFileIcon: View {
    let fileURL: URL
    @State private var icon: NSImage

    init(fileURL: URL) {
        self.fileURL = fileURL
        _icon = State(
            initialValue: AnalysisIconProvider.icon(
                forFileExtension: fileURL.pathExtension
            )
        )
    }

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .scaledToFit()
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
            .task(id: fileURL.path) {
                let resolvedIcon = await FileThumbnailProvider.shared.thumbnail(
                    for: fileURL,
                    size: CGSize(width: 24, height: 24)
                )
                guard !Task.isCancelled else { return }
                icon = resolvedIcon
            }
    }
}

private struct DuplicatesNerdStatsStrip: View {
    @SortyHotReload private var hotReload
    @ObservedObject var manager: DuplicateDetectionManager

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                stat("Scanned", value: "\(manager.scannedFileCount)")
                stat("Candidates", value: "\(manager.hashCandidateCount)")
            }
            HStack(spacing: 8) {
                stat("Sampled", value: "\(manager.sampledFileCount)")
                stat("Full hashes", value: "\(manager.hashedFileCount)")
            }
            HStack(spacing: 8) {
                stat("Cache hits", value: "\(manager.hashCacheHitCount)")
                stat("Similar analyzed", value: "\(manager.semanticAnalyzedFileCount)")
            }
            if manager.unreadableFileCount > 0 {
                HStack(spacing: 8) {
                    stat("Unreadable", value: "\(manager.unreadableFileCount)")
                    stat("Duration", value: formattedDuration)
                }
            } else {
                stat("Duration", value: formattedDuration)
            }
        }
        .padding(10)
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Duplicate scan stats. \(manager.scannedFileCount) files scanned. \(manager.hashCandidateCount) hash candidates. \(manager.sampledFileCount) files sampled. \(manager.hashedFileCount) files fully hashed. \(manager.hashCacheHitCount) cache hits. \(manager.semanticAnalyzedFileCount) files analyzed for similarity. \(manager.semanticSkippedFileCount) files skipped for similarity. \(manager.unreadableFileCount) unreadable files. Duration \(formattedDuration)."
        )
    }

    private func stat(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .numericTextTransition(animationValue: value)
        }
        .font(.caption2)
    }

    private var formattedDuration: String {
        guard manager.scanDuration > 0 else { return "—" }
        return String(format: "%.2fs", manager.scanDuration)
    }
}

struct UnifiedDuplicateGroupRow: View {
    @SortyHotReload private var hotReload
    let group: UnifiedDuplicateGroup

    /// Memoizes the folder summary across rows and body evaluations. The
    /// summary parses every file URL; the cache key is the full path list so
    /// a changed group can never serve a stale label.
    private final class FolderSummaryCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]

        func summary(for key: String, compute: () -> String) -> String {
            lock.withLock {
                if let cached = storage[key] {
                    return cached
                }
                let built = compute()
                if storage.count > 128 {
                    storage.removeAll()
                }
                storage[key] = built
                return built
            }
        }
    }

    private static let folderSummaryCache = FolderSummaryCache()

    private var firstFileURL: URL? {
        guard let path = group.files.first?.path else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var folderSummary: String {
        let key = "\(group.id)#\(group.files.map(\.path).joined(separator: "|"))"
        return Self.folderSummaryCache.summary(for: key) {
            let folders = Set(
                group.files.map {
                    URL(fileURLWithPath: $0.path).deletingLastPathComponent().lastPathComponent
                })
            if folders.count == 1, let folder = folders.first, !folder.isEmpty {
                return folder
            }
            return "Across \(folders.count) folders"
        }
    }

    private var badgeColor: Color {
        group.isExact ? .orange : .blue
    }

    var body: some View {
        HStack(spacing: 12) {
            if let url = firstFileURL {
                FileThumbnailView(url: url, size: CGSize(width: 40, height: 40))
                    .frame(width: 40, height: 40)
            } else {
                RoundedRectangle(cornerRadius: 9)
                    .fill(badgeColor.opacity(0.12))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: group.isExact ? "doc.on.doc.fill" : "waveform.path")
                            .foregroundStyle(badgeColor)
                            .symbolReplaceTransition(animationValue: group.isExact)
                    }
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(group.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(group.displayName)

                HStack(spacing: 5) {
                    Label(folderSummary, systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("•")
                    Text("\(group.files.count) \(group.isExact ? "copies" : "matches")")
                        .numericTextTransition(animationValue: group.files.count)
                    Text("•")
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: group.potentialSavings, countStyle: .file)
                    )
                    .foregroundStyle(.green)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .layoutPriority(1)

        }
        .padding(.vertical, 7)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct DuplicateSectionHeader: View {
    @SortyHotReload private var hotReload
    let title: String
    @Binding var isExpanded: Bool
    let guidance: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage private var isDismissed: Bool
    @State private var isInfoPresented = false
    @State private var shouldDismissInfo = false

    init(
        title: String,
        isExpanded: Binding<Bool>,
        guidance: String,
        infoKey: String
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.guidance = guidance
        self._isDismissed = AppStorage(wrappedValue: false, infoKey)
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.24),
                            value: isExpanded
                        )
                        .accessibilityHidden(true)

                    Text(title)
                }
                .frame(minHeight: 32, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(
                "Double-click to " + (isExpanded ? "collapse" : "expand") + " this section"
            )

            if !isDismissed {
                Button {
                    shouldDismissInfo = false
                    isInfoPresented = true
                } label: {
                    Image(systemName: "info.circle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("About " + title)
                .popover(isPresented: $isInfoPresented) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("About " + title)
                            .sortyTypography(.headline, weight: .medium)

                        Text(guidance)
                            .sortyTypography(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Toggle("Don't show again", isOn: $shouldDismissInfo)
                            .sortyTypography(.body)

                        HStack {
                            Spacer()
                            Button("OK") {
                                if shouldDismissInfo {
                                    isDismissed = true
                                }
                                isInfoPresented = false
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(16)
                    .frame(width: 360, alignment: .leading)
                }
            }
        }
        .onAppear {
            shouldDismissInfo = isDismissed
        }
    }
}

struct UnifiedDuplicateGroupDetailView: View {
    @SortyHotReload private var hotReload
    let group: UnifiedDuplicateGroup
    let settings: DuplicateSettings
    let onDelete: ([FileItem]) -> Void
    @State private var selectedKeepFileId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupOverview

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(sortedFiles, id: \.id) { file in
                        UnifiedFileDetailRow(
                            file: file,
                            isRecommended: file.id == effectiveKeepFileId,
                            recommendation: recommendationLabel(for: file),
                            onKeep: {
                                HapticFeedbackManager.shared.selection()
                                selectedKeepFileId = file.id
                            },
                            onDelete: {
                                onDelete([file])
                            }
                        )
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            selectedKeepFileId = preferredKeepFileId()
        }
        .onChange(of: group.id) { _, _ in
            selectedKeepFileId = preferredKeepFileId()
        }
        .onChange(of: settings.defaultKeepStrategy) { _, _ in
            selectedKeepFileId = preferredKeepFileId()
        }
    }

    private var groupOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                overviewTitle
                Spacer(minLength: 8)
            }

            HStack {
                primaryActionButton
                Spacer(minLength: 0)
            }

            metricsGrid

            if let recommendation = group.recommendation, recommendation == .manualReview {
                Text("This group needs manual review before Sorty will choose files to remove.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 104), spacing: 8)
            ],
            alignment: .leading,
            spacing: 8
        ) {
            DuplicateMetricTile(
                value: "\(group.files.count)", label: group.isExact ? "copies" : "versions",
                color: .primary)
            DuplicateMetricTile(
                value: ByteCountFormatter.string(
                    fromByteCount: group.potentialSavings, countStyle: .file), label: "recoverable",
                color: .green)
            DuplicateMetricTile(
                value: group.isExact ? "100%" : (group.similarityPercentage ?? "Review"),
                label: group.isExact ? "match" : "similarity",
                color: group.isExact ? .orange : .blue)
        }
    }

    private var overviewTitle: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !group.isExact || group.confidenceLevel == .low {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        overviewBadges
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        overviewBadges
                    }
                }
            }

            Text(group.displayName)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .layoutPriority(1)
    }

    @ViewBuilder
    private var overviewBadges: some View {
        if !group.isExact {
            Text(group.groupTypeLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1), in: Capsule())
        }

        if group.confidenceLevel == .low {
            confidenceBadge
        }
    }

    private var confidenceBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.orange)
                .frame(width: 6, height: 6)
            Text(group.confidenceLevel.rawValue)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if let recommendation = group.recommendation {
            Button {
                removeFilesExceptSelectedKeepFile()
            } label: {
                Text(compactButtonTitle(for: recommendation))
            }
            .buttonStyle(.sortyPrimary)
            .tint(.blue)
            .controlSize(.regular)
            .help(recommendation.description)
        } else {
            Button {
                removeFilesExceptSelectedKeepFile()
            } label: {
                Text("Clean Up Selected")
            }
            .buttonStyle(.sortyPrimary)
            .tint(.red)
            .controlSize(.regular)
            .help("Keep the first file and clean up the rest.")
        }
    }

    private var sortedFiles: [FileItem] {
        // Put recommended file first, then sort by date
        let recommendedId = effectiveKeepFileId
        return group.files.sorted { f1, f2 in
            if f1.id == recommendedId { return true }
            if f2.id == recommendedId { return false }
            let d1 = f1.creationDate ?? Date.distantPast
            let d2 = f2.creationDate ?? Date.distantPast
            return d1 < d2
        }
    }

    private func recommendationLabel(for file: FileItem) -> String? {
        guard file.id == effectiveKeepFileId else { return nil }

        if selectedKeepFileId == file.id {
            return "Selected"
        }

        switch group.recommendation {
        case .keepHighestResolution:
            return "Highest Res"
        case .keepNewest:
            return "Newest"
        case .keepOldest:
            return "Original"
        case .keepLargest:
            return "Largest"
        case .archiveOlderVersions:
            return "Latest Draft"
        case .manualReview, .none:
            return "Recommended"
        }
    }

    private func compactButtonTitle(
        for recommendation: SemanticDuplicateGroup.DuplicateRecommendation
    ) -> String {
        switch recommendation {
        case .keepHighestResolution:
            return "Clean Up Selected"
        case .keepNewest:
            return "Clean Up Selected"
        case .keepOldest:
            return "Clean Up Selected"
        case .keepLargest:
            return "Clean Up Selected"
        case .archiveOlderVersions:
            return "Archive Older"
        case .manualReview:
            return "Clean Up Selected"
        }
    }

    private var effectiveKeepFileId: UUID? {
        if let selectedKeepFileId,
           group.files.contains(where: { $0.id == selectedKeepFileId }) {
            return selectedKeepFileId
        }
        return preferredKeepFileId()
    }

    private func removeFilesExceptSelectedKeepFile() {
        guard let keepId = effectiveKeepFileId,
              group.files.contains(where: { $0.id == keepId }) else { return }
        let filesToRemove = group.files.filter { $0.id != keepId }
        guard !filesToRemove.isEmpty else { return }
        onDelete(filesToRemove)
    }

    private func preferredKeepFileId() -> UUID? {
        if group.isExact {
            return keepFile(using: settings.defaultKeepStrategy)?.id
        }
        if let recommended = group.recommendedFileId,
           group.files.contains(where: { $0.id == recommended }) {
            return recommended
        }

        return keepFile(using: settings.defaultKeepStrategy)?.id
    }

    private func keepFile(using strategy: KeepStrategy) -> FileItem? {
        switch strategy {
        case .newest:
            return group.files.max { comparableDate(for: $0) < comparableDate(for: $1) }
        case .oldest:
            return group.files.min { comparableDate(for: $0) < comparableDate(for: $1) }
        case .largest:
            return group.files.max { $0.size < $1.size }
        case .smallest:
            return group.files.min { $0.size < $1.size }
        case .shortestPath:
            return group.files.min { $0.path.count < $1.path.count }
        }
    }

    private func comparableDate(for file: FileItem) -> Date {
        file.modificationDate ?? file.creationDate ?? .distantPast
    }
}

private struct DuplicateMetricTile: View {
    @SortyHotReload private var hotReload
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .numericTextTransition(animationValue: value)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .systemLiquidGlassBackground(cornerRadius: 10, interactive: false)
        .frame(minHeight: 50)
        .accessibilityElement(children: .combine)
    }
}

struct UnifiedFileDetailRow: View {
    @SortyHotReload private var hotReload
    let file: FileItem
    let isRecommended: Bool
    let recommendation: String?
    let onKeep: () -> Void
    let onDelete: () -> Void

    private var fileURL: URL {
        URL(fileURLWithPath: file.path)
    }

    private var parentFolderName: String {
        fileURL.deletingLastPathComponent().lastPathComponent
    }

    var body: some View {
        verticalLayout
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .systemLiquidGlassBackground(cornerRadius: 12)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isRecommended ? Color.green.opacity(0.24) : Color.primary.opacity(0.07),
                    lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            UnifiedFileDetailContextMenu(
                isRecommended: isRecommended,
                onOpen: openFile,
                onReveal: revealInFinder,
                onKeep: onKeep,
                onDelete: onDelete
            )
        }
        .onTapGesture(count: 2, perform: openFile)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(file.displayName)
        .accessibilityAction(named: "Open file", openFile)
        .accessibilityAction(named: "Reveal file in Finder", revealInFinder)
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                thumbnail
                fileSummary
            }

            HStack {
                if isRecommended {
                    keepBadge
                } else {
                    keepButton
                    deleteButton
                }
                Spacer()
            }
        }
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            FileThumbnailView(url: fileURL, size: CGSize(width: 44, height: 44))

            if isRecommended {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption2)
                    .padding(2)
                    .background(Circle().fill(.white))
                    .offset(x: 4, y: 4)
                    .help("Recommended to Keep")
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 44, height: 44)
    }

    private var fileSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(file.displayName)
                .sortyTypography(.headline, weight: .medium)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)

            if let label = recommendation {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.blue))
            }

            revealButton

            fileMetadata
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var revealButton: some View {
        Button {
            NSWorkspace.shared.selectFile(
                file.path,
                inFileViewerRootedAtPath: fileURL.deletingLastPathComponent().path)
        } label: {
            Label {
                Text(parentFolderName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                AppKitImageView(
                    image: NSWorkspace.shared.icon(
                        forFile: fileURL.deletingLastPathComponent().path),
                    size: CGSize(width: 12, height: 12)
                )
                .frame(width: 12, height: 12)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1), in: Capsule())
            .foregroundStyle(.secondary)
        }
        .contentShape(Capsule())
        .buttonStyle(.plain)
        .help("Reveal in Finder: \(PrivacyPathMasker.redactedPath(fileURL.deletingLastPathComponent().path))")
    }

    private var fileMetadata: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                if let date = file.creationDate {
                    Text("•")
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                if let pixels = file.totalPixels, pixels > 0 {
                    Text("•")
                    Text("\(formatPixels(pixels))")
                        .foregroundStyle(.blue)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                if let date = file.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                if let pixels = file.totalPixels, pixels > 0 {
                    Text("\(formatPixels(pixels))")
                        .foregroundStyle(.blue)
                }
            }
        }
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Label("Remove", systemImage: "trash")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.sortyBordered)
        .controlSize(.small)
        .foregroundStyle(.red)
        .help("Delete this duplicate")
        .accessibilityLabel("Delete \(file.displayName)")
    }

    private var keepButton: some View {
        Button(action: onKeep) {
            Label("Keep This", systemImage: "checkmark.circle")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.sortyBordered)
        .controlSize(.small)
        .help("Keep this file and mark the others for cleanup")
    }

    private var keepBadge: some View {
        Label("Keep", systemImage: "checkmark.circle.fill")
            .font(.caption.bold())
            .foregroundStyle(.green)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.green.opacity(0.1), in: Capsule())
    }

    private func formatPixels(_ pixels: Int) -> String {
        let mp = Double(pixels) / 1_000_000.0
        return String(format: "%.1f MP", mp)
    }

    private func openFile() {
        _ = NSWorkspace.shared.open(fileURL)
    }

    private func revealInFinder() {
        NSWorkspace.shared.selectFile(
            file.path,
            inFileViewerRootedAtPath: fileURL.deletingLastPathComponent().path)
    }
}

private struct UnifiedFileDetailContextMenu: View {
    @SortyHotReload private var hotReload
    let isRecommended: Bool
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onKeep: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Label("Open", systemImage: "arrow.up.right.square")
        }

        Button(action: onReveal) {
            Label("Reveal in Finder", systemImage: "folder")
        }

        Divider()

        if isRecommended {
            Label("Keep This", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else {
            Button(action: onKeep) {
                Label("Keep This", systemImage: "checkmark.circle")
            }

            Button(role: .destructive, action: onDelete) {
                Label("Remove", systemImage: "trash")
            }
        }
    }
}

// Reused components
struct DuplicatesEmptyStateView: View {
    @SortyHotReload private var hotReload
    let title: String
    let description: String
    let icon: String
    var iconColor: Color = .secondary
    var heroTint: Color?
    let actionTitle: String
    var actionAccessibilityIdentifier: String?
    var animatesIcon = false
    var celebratesAppearance = false
    var isDefaultAction = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @State private var beamHasAppeared = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                if celebratesAppearance {
                    Circle()
                        .stroke(heroTint ?? .green, lineWidth: 2)
                        .frame(width: 100, height: 100)
                        .scaleEffect(reduceMotion ? 1 : (hasAppeared ? 1.28 : 0.78))
                        .opacity(hasAppeared ? 0 : 0.42)
                }

                if animatesIcon {
                    ScanningPulseIcon(systemName: icon, color: iconColor)
                } else {
                    EmptyStateHeroIcon(
                        systemName: icon,
                        tint: heroTint,
                        symbolBounceTrigger: celebratesAppearance && hasAppeared && !reduceMotion
                    )
                }
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.82)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.18)
                    : .spring(response: 0.48, dampingFraction: 0.64).delay(0.06),
                value: hasAppeared
            )
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(LocalizedStringKey(title))
                    .font(.title2.bold())

                Text(LocalizedStringKey(description))
                    .sortyTypography(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 350)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title). \(description)")
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: reduceMotion || hasAppeared ? 0 : 10)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.18).delay(0.04)
                    : .spring(response: 0.5, dampingFraction: 0.82).delay(0.16),
                value: hasAppeared
            )

            Button(action: action) {
                Text(actionTitle)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.sortyPrimary)
            .onboardingBeamBorder(variant: .featured, active: beamHasAppeared)
            .controlSize(.large)
            .modifier(DefaultActionShortcut(isEnabled: isDefaultAction))
            .accessibilityLabel(actionTitle)
            .accessibilityHint(
                isDefaultAction
                    ? "Press Enter to \(actionTitle.lowercased())"
                    : "Activate to \(actionTitle.lowercased())"
            )
            .accessibilityIdentifier(
                actionAccessibilityIdentifier
                    ?? "\(title.replacingOccurrences(of: " ", with: ""))Action"
            )
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: reduceMotion || hasAppeared ? 0 : 14)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.18).delay(0.08)
                    : .spring(response: 0.52, dampingFraction: 0.82).delay(0.24),
                value: hasAppeared
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            hasAppeared = true

            try? await Task.sleep(for: .milliseconds(reduceMotion ? 80 : 420))
            guard !Task.isCancelled else { return }
            beamHasAppeared = true
        }
    }
}

private struct DefaultActionShortcut: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}

private struct ScanningPulseIcon: View {
    @SortyHotReload private var hotReload
    let systemName: String
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var isWindowVisible = true

    private var isPaused: Bool {
        reduceMotion || reduceTransparency || !isWindowVisible
            || controlActiveState == .inactive || scenePhase != .active
    }

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: isPaused)) {
            timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let pulse = isPaused ? 0.5 : (sin(elapsed * 3.2) + 1) / 2
            let beamPhase = isPaused ? 0.5 : elapsed.truncatingRemainder(dividingBy: 1.8) / 1.8

            Image(systemName: systemName)
                .font(.system(size: 48))
                .foregroundStyle(color.opacity(0.55 + pulse * 0.2))
                .overlay {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [
                                .clear, .white, SortyDesignSystem.Colors.resolvedAccent, .clear,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.65)
                        .offset(
                            x: (proxy.size.width * 1.65 * beamPhase) - (proxy.size.width * 0.65))
                    }
                    .mask {
                        Image(systemName: systemName)
                            .font(.system(size: 48))
                    }
                    .opacity(isPaused ? 0.35 : 0.95)
                }
                .shadow(
                    color: SortyDesignSystem.Colors.resolvedAccent.opacity(0.27),
                    radius: 4
                )
        }
        .frame(width: 72, height: 56)
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .accessibilityHidden(true)
    }
}

struct ScanProgressViewNew: View {
    @SortyHotReload private var hotReload
    let progress: Double
    var isPreparing: Bool = false
    var stage: String = ""

    @Environment(\.controlActiveState) private var controlActiveState

    private var isAnimationActive: Bool {
        controlActiveState != .inactive
    }

    private var clampedProgress: Double {
        max(0, min(1, progress))
    }

    private var percent: Int {
        Int((clampedProgress * 100).rounded())
    }

    private var title: String {
        if isPreparing {
            return "Preparing Scan..."
        }
        return stage.localizedCaseInsensitiveContains("semantic")
            ? "Finding Similar Files"
            : "Finding Exact Duplicates"
    }

    private var scanIcon: String {
        isPreparing ? "folder.badge.gearshape" : "doc.text.magnifyingglass"
    }

    private var subtitle: String {
        if !stage.isEmpty {
            return stage
        }
        return isPreparing
            ? "Reading directory structure..." : "Comparing file content to find exact matches..."
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                progressCard
            }
            .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            isPreparing
                ? "Preparing scan" : "Scanning for duplicate files, \(percent) percent complete")
    }

    private var progressCard: some View {
        ZStack {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: scanIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .symbolReplaceTransition(animationValue: scanIcon)
                    .frame(width: 30)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(LocalizedStringKey(title))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                            .numericTextTransition(animationValue: title)

                        if !isPreparing {
                            Text("\(percent)%")
                                .monospacedDigit()
                                .fixedSize(horizontal: true, vertical: false)
                                .numericTextTransition(
                                    animationValue: percent,
                                    animation: .easeInOut(duration: 0.3)
                                )
                        }
                    }
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)

                    Text(LocalizedStringKey(subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .numericTextTransition(animationValue: subtitle)
                }

                Spacer(minLength: 0)

                MinsangGlassLoader(
                    textChangeTrigger: title,
                    size: 54,
                    isActive: isAnimationActive
                )
                .frame(width: 54)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 420, height: 94)
        .background {
            beamSurface
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isPreparing
                ? "Preparing to scan for duplicates"
                : "Computing file hashes to find exact duplicate matches"
        )
        .accessibilityValue(isPreparing ? subtitle : "\(percent) percent complete, \(subtitle)")
    }

    private var beamSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.clear)
                .systemLiquidGlassBackground(cornerRadius: 16, interactive: false)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
        .beam(
            .medium,
            palette: .colorful,
            theme: .dark,
            active: isAnimationActive,
            cornerRadius: 16,
            strength: 1.0
        )
        .scanProgressReferenceBeamFallback(
            cornerRadius: 16, active: true
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    fileprivate func scanProgressReferenceBeamFallback(
        cornerRadius: CGFloat,
        active: Bool
    ) -> some View {
        overlay {
            ScanProgressReferenceBeamFallback(
                cornerRadius: cornerRadius,
                active: active
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct ScanProgressReferenceBeamFallback: View {
    @SortyHotReload private var hotReload
    let cornerRadius: CGFloat
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var isWindowVisible = true

    private var shouldAnimate: Bool {
        active && !reduceMotion && !reduceTransparency && isWindowVisible
            && controlActiveState != .inactive && scenePhase == .active
    }

    var body: some View {
        SwiftUI.TimelineView(
            .animation(minimumInterval: 1.0 / 12.0, paused: !shouldAnimate)
        ) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = shouldAnimate ? time / 1.96 : 0
            // Stroke-only fallback: Beam supplies interior light; the glow's
            // blurs were the dominant fallback cost.
            beamStroke(phase: phase)
                .opacity(active ? 0.82 : 0)
                .animation(.easeOut(duration: 0.6), value: active)
        }
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
    }

    private func beamStroke(phase: TimeInterval) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: .clear, location: 0.08),
                        .init(
                            color: Color(red: 0.08, green: 0.80, blue: 1.0).opacity(0.36),
                            location: 0.16),
                        .init(
                            color: Color(red: 0.92, green: 0.16, blue: 0.58).opacity(0.62),
                            location: 0.25),
                        .init(color: .white.opacity(0.88), location: 0.32),
                        .init(
                            color: Color(red: 1.0, green: 0.34, blue: 0.18).opacity(0.54),
                            location: 0.39),
                        .init(
                            color: Color(red: 0.40, green: 0.20, blue: 1.0).opacity(0.36),
                            location: 0.48),
                        .init(color: .clear, location: 0.58),
                        .init(color: .clear, location: 1.00),
                    ],
                    center: .center,
                    angle: .degrees((phase.truncatingRemainder(dividingBy: 1)) * 360)
                ),
                lineWidth: 1
            )
    }
}
