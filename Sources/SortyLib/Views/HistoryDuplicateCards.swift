import AppKit
import SwiftUI

// MARK: - Liquid Glass Duplicate Summary Card (History)

struct HistoryLiquidGlassDuplicateCard: View {
    @SortyHotReload private var hotReload
    let duplicateGroups: [DuplicateInfo]
    let totalDuplicateCount: Int
    var handoffDirectory: URL? = nil
    @Binding var highlightedFileID: UUID?
    @State private var showPopover = false
    @EnvironmentObject var appState: AppState

    var body: some View {
        if !duplicateGroups.isEmpty {
            GlassPillButton(
                icon: "doc.on.doc",
                title: "Duplicates",
                tint: .red,
                count: totalDuplicateCount
            ) {
                showPopover.toggle()
            }
            .accessibilityLabel("Duplicates found: \(totalDuplicateCount)")
            .accessibilityHint("Tap to view duplicate file groups")
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                historyDuplicatePopover
                    .systemLiquidGlassPopover(cornerRadius: 12)
            }
        }
    }

    private var historyDuplicatePopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassPopoverHeader(
                icon: "doc.on.doc",
                title: "Duplicate Files",
                tint: .red,
                subtitle: "\(duplicateGroups.count) group\(duplicateGroups.count == 1 ? "" : "s"), \(totalDuplicateCount) duplicate\(totalDuplicateCount == 1 ? "" : "s")",
                subtitleAnimationValue: "\(duplicateGroups.count)-\(totalDuplicateCount)"
            )

            Divider()
                .opacity(0.4)
                .padding(.bottom, 10)

            Button {
                handoffToDuplicates()
            } label: {
                Label("Handle in Duplicates", systemImage: "arrowshape.turn.up.right.circle.fill")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(SortyDesignSystem.Colors.resolvedAccent.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(duplicateGroups) { group in
                        HistoryDuplicateGroupRow(
                            group: group,
                            handoffDirectory: handoffDirectory,
                            highlightedFileID: $highlightedFileID
                        )
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding(14)
        .frame(minWidth: 300, maxWidth: 400)
    }

    private func handoffToDuplicates() {
        let filePaths = duplicateGroups.flatMap { group in
            [group.file.path] + group.duplicates.map(\.path)
        }
        appState.handoffToDuplicates(
            forFilePaths: filePaths,
            preferredDirectory: handoffDirectory,
            autoStart: true
        )
        showPopover = false
        HapticFeedbackManager.shared.selection()
    }
}

// MARK: - History Helper Views

struct HistoryDuplicateGroupRow: View {
    @SortyHotReload private var hotReload
    let group: DuplicateInfo
    var handoffDirectory: URL? = nil
    @Binding var highlightedFileID: UUID?
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    highlightedFileID = group.file.id
                }
            } label: {
                primaryFileLabel
            }
            .buttonStyle(.plain)
            .contextMenu {
                contextMenu(for: group.file.path)
            }

            ForEach(group.duplicates) { dup in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        highlightedFileID = dup.id
                    }
                } label: {
                    HistoryDuplicateFileLabel(file: dup, isHighlighted: highlightedFileID == dup.id)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                .contextMenu {
                    contextMenu(for: dup.path)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func contextMenu(for path: String) -> some View {
        let groupPaths = [group.file.path] + group.duplicates.map(\.path)

        Button {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        Button {
            appState.handoffToDuplicates(
                forFilePaths: groupPaths,
                preferredDirectory: handoffDirectory,
                autoStart: true
            )
        } label: {
            Label("Handle in Duplicates", systemImage: "arrowshape.turn.up.right.circle")
        }
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } label: {
            Label("Quick Look", systemImage: "eye")
        }
        Button {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                NotificationManager.shared.show(.info(title: "Success", message: "Moved duplicate to Trash"))
            } catch {
                NotificationManager.shared.showError(message: "Could not move to Trash: \(error.localizedDescription)")
            }
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
    }

    private var primaryFileLabel: some View {
        HStack(spacing: 6) {
            FileThumbnailView(url: URL(fileURLWithPath: group.file.path), size: CGSize(width: 20, height: 20))
            Text(group.file.displayName)
                .font(.callout)
                .fontWeight(highlightedFileID == group.file.id ? .semibold : .medium)
                .foregroundStyle(highlightedFileID == group.file.id ? .primary : .primary)
                .lineLimit(1)
            Spacer()
            Text("\(group.duplicateCount + 1) copies")
                .font(.caption2)
                .foregroundStyle(.white)
                .numericTextTransition(animationValue: group.duplicateCount)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.red))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(highlightedFileID == group.file.id ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.12) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Pre-flight Validation Models

/// Result of pre-flight validation before undo/redo operations
struct HistoryDuplicateFileLabel: View {
    let file: FileItem
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(file.displayName)
                .font(.caption)
                .fontWeight(isHighlighted ? .semibold : .regular)
                .foregroundStyle(isHighlighted ? .primary : .secondary)
                .lineLimit(1)
            Spacer()
            Text(file.formattedSize)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHighlighted ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.12) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 4))
    }
}
