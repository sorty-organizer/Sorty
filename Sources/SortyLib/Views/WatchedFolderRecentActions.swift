import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct WatchedFolderRecentActions: View {
    @SortyHotReload private var hotReload
    private static let visibleActionCount = 3

    struct ActionAlert: Identifiable {
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
