import Foundation
import SwiftUI

struct RenameNameChangeView: View {
    @SortyHotReload private var hotReload
    let suggestedName: String
    let helpText: String
    var isRegenerating = false
    /// Only the highlighted row plays the reveal sweep. Every other row
    /// renders its final state directly: no GeometryReader sweep, no blur
    /// bounce, no delayed dispatch hops.
    var isHighlighted = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var suggestedNameReveal = true
    @State private var showRevealSweep = false

    var body: some View {
        Text(suggestedName)
            .fontWeight(.medium)
            .foregroundColor(SortyDesignSystem.Colors.success)
            .lineLimit(1)
            .truncationMode(.middle)
            .opacity(isRegenerating ? 0 : (suggestedNameReveal ? 1 : 0))
            .blur(radius: reduceMotion ? 0 : (isRegenerating ? 6 : (suggestedNameReveal ? 0 : 4)))
            .offset(x: reduceMotion ? 0 : (suggestedNameReveal ? 0 : -10))
            .overlay(alignment: .leading) {
                if showRevealSweep && suggestedNameReveal && !isRegenerating && !reduceMotion && isHighlighted {
                    RenameNameRevealSweep()
                        .allowsHitTesting(false)
                }
            }
            .animation(isHighlighted ? .sortyFade : nil, value: isRegenerating)
            .animation(isHighlighted ? .sortySmooth : nil, value: suggestedNameReveal)
            .help(helpText)
            .onChange(of: suggestedName) { _, _ in
                guard !reduceMotion, isHighlighted else {
                    suggestedNameReveal = true
                    return
                }
                suggestedNameReveal = false
                showRevealSweep = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    withAnimation(.sortySmooth) {
                        suggestedNameReveal = true
                        showRevealSweep = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        showRevealSweep = false
                    }
                }
            }
            .onChange(of: isRegenerating) { _, newValue in
                guard !reduceMotion, isHighlighted else { return }
                if newValue {
                    withAnimation(.sortyFade) {
                        suggestedNameReveal = false
                        showRevealSweep = false
                    }
                }
            }
    }
}

private struct RenameNameRevealSweep: View {
    @SortyHotReload private var hotReload
    @State private var progress: CGFloat = -0.35

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)

            LinearGradient(
                colors: [
                    .clear,
                    .white.opacity(0.24),
                    SortyDesignSystem.Colors.success.opacity(0.18),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: max(width * 0.26, 22), height: geometry.size.height * 1.8)
            .blur(radius: 2.2)
            .offset(x: width * progress)
            .blendMode(.plusLighter)
            .onAppear {
                progress = -0.35
                withAnimation(.easeOut(duration: 0.58)) {
                    progress = 1.12
                }
            }
        }
        .clipped()
    }
}

struct FlatFolderRowHeaderContent: View {
    @SortyHotReload private var hotReload
    let folderName: String
    let fileCount: Int
    let isExpanded: Bool
    let isDropTarget: Bool
    let reduceMotion: Bool

    private var displayName: String {
        folderName.hasPrefix("/")
            ? URL(fileURLWithPath: folderName).lastPathComponent
            : folderName
    }

    var body: some View {
        Group {
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 20)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(
                    reduceMotion ? nil : .sortySnappy,
                    value: isExpanded
                )
                .accessibilityHidden(true)

            CompactFolderThumbnail(
                url: nil,
                folderName: folderName,
                size: 16,
                fileCount: fileCount
            )
            .opacity(isDropTarget ? 0.7 : 1.0)

            Text(displayName)
                .fontWeight(.medium)

            Text("(\(fileCount) files)")
                .font(.caption)
                .foregroundColor(.secondary)
                .numericTextTransition(animationValue: fileCount)
        }
    }
}

struct FlatFolderRowContextMenu: View {
    @SortyHotReload private var hotReload
    let isStorageDestination: Bool
    let onRevert: () -> Void
    let onChangeStorage: () -> Void
    let onReveal: () -> Void

    var body: some View {
        Button(role: .destructive, action: onRevert) {
            Label("Revert Organization", systemImage: "arrow.uturn.backward")
        }

        if isStorageDestination {
            Divider()
            Button("Change Storage Location…", action: onChangeStorage)
            Button("Show in Finder", action: onReveal)
        }
    }
}

struct FlatFileRowContent: View {
    @SortyHotReload private var hotReload
    private enum Column {
        static let sizeWidth: CGFloat = 60
        static let dragHandleWidth: CGFloat = 12
    }

    let file: FileItem
    let renameMapping: FileRenameMapping?
    let renameHelpText: String?
    let fileTags: [String]
    let fileComment: String?
    let duplicateInfo: DuplicateInfo?
    let parentSuggestion: FolderSuggestion?
    let learningsManager: LearningsManager
    let isHighlighted: Bool
    @Binding var isEditingName: Bool
    @Binding var editedName: String
    @Binding var isRegeneratingName: Bool
    @Binding var highlightedFileID: UUID?
    let isFocused: FocusState<Bool>.Binding
    let onSave: () -> Void
    let onCancel: () -> Void
    let onStartEditing: (String) -> Void
    let onRegenerate: () -> Void
    let onReject: () -> Void

    /// Name the rename field starts with: the pending suggestion, else the current name.
    static func editableName(for file: FileItem, renameMapping: FileRenameMapping?) -> String {
        if let renameMapping, renameMapping.hasRename, let suggested = renameMapping.suggestedName {
            return suggested
        }
        return file.displayName
    }

    private var editableName: String {
        Self.editableName(for: file, renameMapping: renameMapping)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                FileThumbnailView(
                    url: URL(fileURLWithPath: file.path),
                    size: CGSize(width: 20, height: 20)
                )

                if isEditingName {
                    TextField("New name", text: $editedName)
                        .textFieldStyle(.plain)
                        .focused(isFocused)
                        .onSubmit(onSave)
                        .onExitCommand(perform: onCancel)
                        .font(.body)
                } else {
                    Text(file.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(renameMapping?.hasRename == true ? .secondary : .primary)
                        .strikethrough(
                            renameMapping?.hasRename == true,
                            color: SortyDesignSystem.Colors.error.opacity(0.72)
                        )
                        // Double-clicking the name renames; the rest of the row still opens the file.
                        .onTapGesture(count: 2) { onStartEditing(editableName) }
                }

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    if !fileTags.isEmpty {
                        TagDotsView(tags: fileTags)
                    }

                    if let parentSuggestion {
                        LiquidGlassLearningsButton(
                            file: file,
                            suggestion: parentSuggestion,
                            learningsManager: learningsManager
                        )
                    }

                    if let fileComment, !fileComment.isEmpty {
                        CommentBubbleButton(comment: fileComment)
                    }

                    if let duplicateInfo {
                        LiquidGlassDuplicateButton(
                            duplicateInfo: duplicateInfo,
                            highlightedFileID: $highlightedFileID
                        )
                    }

                    Text(file.formattedSize)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: Column.sizeWidth, alignment: .leading)

                    Image(systemName: "line.3.horizontal")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.6))
                        .frame(width: Column.dragHandleWidth)
                        .accessibilityHidden(true)
                }
            }

            if let renameMapping, renameMapping.hasRename, !isEditingName {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    RenameNameChangeView(
                        suggestedName: renameMapping.suggestedName ?? "",
                        helpText: renameHelpText ?? "",
                        isRegenerating: isRegeneratingName,
                        isHighlighted: isHighlighted
                    )
                    .onTapGesture(count: 2) { onStartEditing(editableName) }

                    Spacer(minLength: 12)

                    if renameMapping.isUserEdited == true {
                        Image(systemName: "person.crop.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Renamed by you")
                            .accessibilityLabel("Renamed by you")
                    } else {
                        Image(systemName: "wand.and.stars")
                            .font(.caption)
                            .foregroundColor(SortyDesignSystem.Colors.resolvedAccent)
                            .help(renameMapping.renameReason ?? "Sorty suggested rename")
                    }

                    RenameActionGlassCluster(
                        isRegenerating: isRegeneratingName,
                        onEdit: { onStartEditing(renameMapping.suggestedName ?? "") },
                        onRegenerate: onRegenerate,
                        onReject: onReject
                    )
                }
                .padding(.leading, 28)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct FlatFileRowContextMenu: View {
    @SortyHotReload private var hotReload
    let hasRename: Bool
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onRename: () -> Void
    let onRegenerate: () -> Void
    let onRejectRename: () -> Void
    let onRevertOrganization: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Label("Open", systemImage: "arrow.up.right.square")
        }
        Button(action: onReveal) {
            Label("Reveal in Finder", systemImage: "folder")
        }
        Divider()
        Button(action: onRename) {
            Label("Rename…", systemImage: "pencil")
        }
        if hasRename {
            Button(action: onRegenerate) {
                Label("Regenerate Name", systemImage: "arrow.triangle.2.circlepath")
            }
            Button(role: .destructive, action: onRejectRename) {
                Label("Revert Name", systemImage: "arrow.uturn.backward")
            }
        }
        Button(role: .destructive, action: onRevertOrganization) {
            Label("Revert Organization", systemImage: "questionmark.folder")
        }
    }
}

struct FlatFileRowSurface: View {
    @SortyHotReload private var hotReload
    let content: FlatFileRowContent
    let depth: Int
    let isHighlighted: Bool
    let isEditingName: Bool
    @Binding var isDragging: Bool
    let hasRename: Bool
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onRename: () -> Void
    let onRegenerate: () -> Void
    let onRejectRename: () -> Void
    let onRevertOrganization: () -> Void
    let onBeginDrag: () -> NSItemProvider
    let onDisappear: () -> Void

    private var fillColor: Color {
        if isHighlighted {
            return SortyDesignSystem.Colors.resolvedAccent.opacity(0.12)
        }
        return isDragging
            ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.1)
            : .clear
    }

    private var strokeColor: Color {
        isHighlighted || isEditingName
            ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.3)
            : .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content
        }
        .padding(.leading, CGFloat(depth * 16))
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.sm, style: .continuous).fill(fillColor))
        .overlay(RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.sm, style: .continuous).stroke(strokeColor, lineWidth: 1))
        .contentShape(Rectangle())
        .contextMenu {
            FlatFileRowContextMenu(
                hasRename: hasRename,
                onOpen: onOpen,
                onReveal: onReveal,
                onRename: onRename,
                onRegenerate: onRegenerate,
                onRejectRename: onRejectRename,
                onRevertOrganization: onRevertOrganization
            )
        }
        .onTapGesture(count: 2, perform: onOpen)
        .accessibilityAction(named: "Open file", onOpen)
        .accessibilityAction(named: "Reveal file in Finder", onReveal)
        .accessibilityAction(named: "Rename file", onRename)
        .opacity(isDragging ? 0.5 : 1.0)
        .onDrag(onBeginDrag)
        .onDrop(of: [.text], isTargeted: nil) { _ in
            isDragging = false
            return false
        }
        .onDisappear(perform: onDisappear)
    }
}

struct RenameActionGlassCluster: View {
    @SortyHotReload private var hotReload
    let isRegenerating: Bool
    let onEdit: () -> Void
    let onRegenerate: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            RenameGlassIconButton(systemImage: "pencil", help: "Edit suggested name", action: onEdit)
            Button(action: onRegenerate) {
                if isRegenerating {
                    SortyGradientCircularLoader(size: 12, lineWidth: 2.2)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
            }
            .buttonStyle(.plain)
            .disabled(isRegenerating)
            .help("Regenerate name with the selected AI model")
            .accessibilityLabel("Regenerate suggested name")

            RenameGlassIconButton(systemImage: "xmark.circle", help: "Keep original name", action: onReject)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .systemLiquidGlassBackground(cornerRadius: SortyDesignSystem.Radius.lg, interactive: false)
    }
}

private struct RenameGlassIconButton: View {
    @SortyHotReload private var hotReload
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}
