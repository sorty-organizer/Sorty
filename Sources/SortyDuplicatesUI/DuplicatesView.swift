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

package struct DuplicatesView: View {
    @SortyHotReload var hotReload
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var detectionManager: DuplicateDetectionManager
    @EnvironmentObject var settingsManager: DuplicateSettingsManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State var showDeleteConfirmation = false
    @State var filesToDelete: [FileItem] = []
    @State var cleanupErrorMessage: String?
    @State var isCleaningUp = false
    @State var showSettings = false
    @State var handoffFilePaths: [String] = []
    @State var currentScanTask: Task<Void, Never>?
    @State var isExactSectionExpanded = true
    @State var isSimilarSectionExpanded = true
    @State var capturedDirectory: URL?
    @State var currentScanID = UUID()
    @State var semanticScanProgress: String?

    package init() {}

    // Derived directory: Use local if set, otherwise fallback to global
    var effectiveDirectory: URL? {
        appState.duplicateSelectedDirectory ?? appState.selectedDirectory
    }

    var isShowingEmptyContent: Bool {
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

    var isPreparingScan: Bool {
        detectionManager.state == .preparing
    }

    var duplicateScanProgress: Double {
        guard case .scanning(let progress) = detectionManager.state else { return 0 }
        return progress
    }

    package var body: some View {
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

    func consumePendingHandoffIfNeeded() {
        guard let handoff = appState.pendingDuplicatesHandoff else { return }
        apply(handoff: handoff)
    }

    func apply(handoff: AppState.DuplicatesHandoff) {
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
    func duplicatesBaseHeaderSection() -> some View {
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
    func duplicatesBaseEmptyState() -> some View {
        DuplicatesEmptyStateView(
            title: "Select a Directory",
            description: "Choose a folder to scan for identical files and recover disk space",
            icon: "doc.on.doc",
            actionTitle: "Choose Directory",
            actionAccessibilityIdentifier: "DuplicatesEmptyChooseDirectory",
            action: selectDirectory
        )
    }

    var noDuplicatesView: some View {
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

    var resultsView: some View {
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
                            .font(.headline)
                        Text(
                            "Review exact duplicates first. Similar files stay separate and need individual confirmation."
                        )
                        .font(.subheadline)
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

    var exactGroups: [UnifiedDuplicateGroup] {
        detectionManager.allGroups.filter { $0.isExact }
    }

    var similarGroups: [UnifiedDuplicateGroup] {
        detectionManager.allGroups.filter { $0.isSemantic }
    }


}







