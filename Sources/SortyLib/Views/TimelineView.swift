//
//  TimelineView.swift
//  Sorty
//
//  "Time Machine" style timeline slider for undo/redo history
//

import SwiftUI

struct TimelineView: View {
    @SortyHotReload private var hotReload
    let entries: [OrganizationHistoryEntry]
    let directoryPath: String
    let onRestore: (OrganizationHistoryEntry) -> Void
    
    @State private var selectedIndex: Int = 0
    @State private var isHovering = false
    @State private var hoverIndex: Int?
    
    private var filteredEntries: [OrganizationHistoryEntry] {
        entries.filter { $0.directoryPath == directoryPath && $0.success }
            .sorted { $0.timestamp > $1.timestamp }
    }
    
    var body: some View {
        let timelineEntries = filteredEntries

        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2)
                    .foregroundColor(.blue)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Organization Timeline")
                        .font(.headline)
                    Text("Restore to any previous organization state")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Text("\(timelineEntries.count) snapshots")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .numericTextTransition(animationValue: timelineEntries.count)
            }
            
            if timelineEntries.isEmpty {
                EmptyTimelineView()
            } else {
                // Timeline slider
                VStack(spacing: 12) {
                    // Visual timeline
                    TimelineSliderTrack(
                        entries: timelineEntries,
                        selectedIndex: $selectedIndex,
                        hoverIndex: $hoverIndex
                    )
                    
                    // Selected entry details
                    if selectedIndex < timelineEntries.count {
                        SelectedEntryCard(
                            entry: timelineEntries[selectedIndex],
                            allEntries: timelineEntries,
                            onRestore: onRestore
                        )
                    }
                }
            }
        }
        .padding()
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
}

// MARK: - Timeline Slider Track

struct TimelineSliderTrack: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let entries: [OrganizationHistoryEntry]
    @Binding var selectedIndex: Int
    @Binding var hoverIndex: Int?
    
    var body: some View {
        let maxFiles = entries.lazy.map(\.filesOrganized).max() ?? 1

        GeometryReader { geo in
            let width = geo.size.width
            let nodeSpacing = entries.count > 1 ? width / CGFloat(entries.count - 1) : width / 2
            
            ZStack(alignment: .leading) {
                // Track line
                Rectangle()
                    .fill(.primary.opacity(0.1))
                    .frame(height: 4)
                    .cornerRadius(2)
                
                // Filled portion up to selected
                if selectedIndex > 0 && entries.count > 1 {
                    Rectangle()
                        .fill(.primary.opacity(0.4))
                        .frame(width: nodeSpacing * CGFloat(selectedIndex), height: 4)
                        .cornerRadius(2)
                }
                
                // Timeline nodes
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    let xPosition = entries.count > 1 ? nodeSpacing * CGFloat(index) : width / 2
                    let magnitude = Double(entry.filesOrganized) / Double(max(1, maxFiles))
                    
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3)) {
                            selectedIndex = index
                        }
                    } label: {
                        TimelineNode(
                            entry: entry,
                            isSelected: index == selectedIndex,
                            isHovered: hoverIndex == index,
                            magnitude: magnitude
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        hoverIndex = hovering ? index : nil
                    }
                    .accessibilityLabel(entry.timestamp.formatted(date: .long, time: .shortened))
                    .accessibilityValue(index == selectedIndex ? "Selected" : "Not selected")
                    .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                    .position(x: xPosition, y: geo.size.height / 2)
                }
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 22)
    }
}

// MARK: - Timeline Node

struct TimelineNode: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let entry: OrganizationHistoryEntry
    let isSelected: Bool
    let isHovered: Bool
    let magnitude: Double // 0.0 to 1.0
    
    var body: some View {
        ZStack {
            // Subtle halo for selection
            if isSelected {
                Circle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 32, height: 32)
            }
            
            // Core node
            Circle()
                .fill(entry.isUndone ? Color.orange : (entry.success ? Color.blue : Color.red))
                .frame(width: nodeSize, height: nodeSize)
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
            
            // Selection ring
            if isSelected {
                Circle()
                    .stroke(Color.white, lineWidth: 2)
                    .frame(width: nodeSize, height: nodeSize)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .scaleEffect(isHovered ? 1.2 : 1.0)
        .animation(reduceMotion ? nil : .spring(response: 0.3), value: isHovered)
        .animation(reduceMotion ? nil : .spring(response: 0.3), value: isSelected)
    }
    
    private var nodeSize: CGFloat {
        // Base size 8, max additional 12 based on magnitude
        let base: CGFloat = 8
        let additional = 12.0 * magnitude
        return isSelected ? (base + additional + 4) : (base + additional)
    }
}

// MARK: - Selected Entry Card

struct SelectedEntryCard: View {
    @SortyHotReload private var hotReload
    let entry: OrganizationHistoryEntry
    let allEntries: [OrganizationHistoryEntry] // All filtered entries to determine current state
    let onRestore: (OrganizationHistoryEntry) -> Void
    
    @State private var showRestoreConfirmation = false
    
    var body: some View {
        HStack(spacing: 20) {
            // Icon status
            ZStack {
                Circle()
                    .fill(entry.isUndone ? Color.orange.opacity(0.1) : Color.blue.opacity(0.1))
                    .frame(width: 40, height: 40)
                Image(systemName: entry.isUndone ? "arrow.uturn.backward" : "folder.badge.gear")
                    .font(.title3)
                    .foregroundColor(entry.isUndone ? .orange : .blue)
                    .symbolReplaceTransition(animationValue: entry.isUndone)
            }
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.isUndone ? "Reverted State" : "Organization Snapshot")
                    .font(.headline)
                    .numericTextTransition(animationValue: entry.isUndone)
                
                Text(entry.timestamp.formatted(date: .long, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .numericTextTransition(animationValue: entry.timestamp)
                
                HStack(spacing: 12) {
                    Label("\(entry.filesOrganized) files moved", systemImage: "arrow.right.doc.on.clipboard")
                        .numericTextTransition(animationValue: entry.filesOrganized)
                    Label("\(entry.foldersCreated) folders", systemImage: "folder.badge.plus")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 2)
            }
            
            Spacer()
            
            // Action
            if isCurrentState {
                Label("Current", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(20)
            } else {
                Button {
                    showRestoreConfirmation = true
                } label: {
                    Text("Restore this State")
                        .fontWeight(.medium)
                }
                .buttonStyle(.sortyProminent)
                .tint(.blue)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
        .alert("Restore to this state?", isPresented: $showRestoreConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Restore") {
                onRestore(entry)
            }
        } message: {
            Text("This will undo all organizations performed after this snapshot. Files will be moved back to their original locations found in this snapshot.")
        }
    }
    
    private var isCurrentState: Bool {
        // This entry is "current" if it's the most recent non-undone entry
        guard !entry.isUndone else { return false }
        
        // Find the most recent non-undone entry
        let mostRecentActive = allEntries
            .filter { !$0.isUndone }
            .sorted { $0.timestamp > $1.timestamp }
            .first
        
        return mostRecentActive?.id == entry.id
    }
}

// MARK: - Empty Timeline View

struct EmptyTimelineView: View {
    @SortyHotReload private var hotReload
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.largeTitle)
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("No timeline available")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text("Organize this folder to create timeline snapshots")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - Compact Timeline for HistoryView

struct CompactTimelineView: View {
    @SortyHotReload private var hotReload
    let entries: [OrganizationHistoryEntry]
    let directoryPath: String
    
    @EnvironmentObject var organizer: FolderOrganizer
    @State private var isProcessing = false
    @State private var showAlert = false
    @State private var alertMessage: String?
    @State private var showMissingFilesConfirmation = false
    @State private var missingFilesForConfirmation: [String] = []
    @State private var pendingRestoreEntry: OrganizationHistoryEntry?
    
    private var filteredEntries: [OrganizationHistoryEntry] {
        entries.filter { $0.directoryPath == directoryPath && $0.success }
            .sorted { $0.timestamp > $1.timestamp }
    }
    
    var body: some View {
        if filteredEntries.count > 1 {
            TimelineView(
                entries: entries,
                directoryPath: directoryPath,
                onRestore: handleRestore
            )
            .disabled(isProcessing)
            .overlay {
                if isProcessing {
                    SortyGradientLoadingBar(width: 160, height: 10)
                        .padding(20)
                        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
                }
            }
            .alert("Timeline", isPresented: $showAlert) {
                Button("OK") { }
            } message: {
                if let msg = alertMessage {
                    Text(msg)
                }
            }
            .alert("Missing Files", isPresented: $showMissingFilesConfirmation) {
                Button("Cancel", role: .cancel) {
                    pendingRestoreEntry = nil
                    missingFilesForConfirmation = []
                }
                Button("Continue Anyway") {
                    if let entry = pendingRestoreEntry {
                        performRestore(entry)
                    }
                }
            } message: {
                Text("\(missingFilesForConfirmation.count) file(s) no longer exist and cannot be restored:\n\n\(missingFilesForConfirmation.prefix(5).joined(separator: "\n"))\(missingFilesForConfirmation.count > 5 ? "\n...and \(missingFilesForConfirmation.count - 5) more" : "")\n\nContinue with partial restore?")
            }
        }
    }
    
    private func handleRestore(_ entry: OrganizationHistoryEntry) {
        // Find all entries that would be undone
        let entriesToUndo = filteredEntries.filter {
            $0.timestamp > entry.timestamp &&
            $0.status == .completed &&
            !$0.isUndone
        }
        
        // Collect all operations that would be reversed
        var allOperations: [FileSystemManager.FileOperation] = []
        for e in entriesToUndo {
            if let ops = e.operations {
                allOperations.append(contentsOf: ops)
            }
        }
        
        // Perform preflight check asynchronously
        Task {
            let fileSystemManager = FileSystemManager()
            let missingFiles = await fileSystemManager.preflightRestore(allOperations)
            
            await MainActor.run {
                if !missingFiles.isEmpty {
                    // Show confirmation dialog
                    missingFilesForConfirmation = missingFiles
                    pendingRestoreEntry = entry
                    showMissingFilesConfirmation = true
                } else {
                    // No missing files, proceed directly
                    performRestore(entry)
                }
            }
        }
    }
    
    private func performRestore(_ entry: OrganizationHistoryEntry) {
        isProcessing = true
        pendingRestoreEntry = nil
        missingFilesForConfirmation = []
        
        Task {
            do {
                let result = try await organizer.restoreToState(targetEntry: entry)
                if result.hasIssues {
                    alertMessage = "Restored to \(entry.timestamp.formatted())\n\n\(result.summaryMessage)"
                } else {
                    alertMessage = "Successfully restored to \(entry.timestamp.formatted())"
                }
            } catch {
                alertMessage = "Restore failed: \(error.localizedDescription)"
            }
            isProcessing = false
            showAlert = true
        }
    }
}

#Preview {
    let entries = [
        OrganizationHistoryEntry(
            directoryPath: "/Users/test/Downloads",
            filesOrganized: 25,
            foldersCreated: 5
        ),
        OrganizationHistoryEntry(
            directoryPath: "/Users/test/Downloads",
            filesOrganized: 18,
            foldersCreated: 4,
            isUndone: true
        ),
        OrganizationHistoryEntry(
            directoryPath: "/Users/test/Downloads",
            filesOrganized: 30,
            foldersCreated: 6
        )
    ]
    
    TimelineView(
        entries: entries,
        directoryPath: "/Users/test/Downloads",
        onRestore: { _ in }
    )
    .padding()
    .frame(width: 600)
}
