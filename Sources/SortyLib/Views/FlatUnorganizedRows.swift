import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

// MARK: - Flat Unorganized Header View

struct FlatUnorganizedHeaderView: View {
    @SortyHotReload private var hotReload
    let fileCount: Int
    let isExpanded: Bool
    let store: PreviewStore
    @ObservedObject var dragDropManager: DragDropManager
    let onPlanChanged: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTarget = false
    
    var body: some View {
        HStack {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
            Image(systemName: "questionmark.folder")
                .foregroundColor(.orange)
            Text("Unorganized Files")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text("\(fileCount) files")
                .font(.caption)
                .foregroundColor(.secondary)
                .numericTextTransition(animationValue: fileCount)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleExpanded)
        .focusable()
        .onKeyPress(.space) {
            toggleExpanded()
            return .handled
        }
        .onKeyPress(.return) {
            toggleExpanded()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(
            named: isExpanded ? "Collapse unorganized files" : "Expand unorganized files",
            toggleExpanded
        )
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTarget ? Color.orange.opacity(0.1) : Color.clear)
                .strokeBorder(isDropTarget ? Color.orange : Color.clear, lineWidth: 2)
        )
        .onDrop(of: [.text], delegate: OptimizedUnorganizedDropDelegate(
            store: store,
            draggedFile: $dragDropManager.draggedFile,
            isTargeted: $isDropTarget,
            onPlanChanged: onPlanChanged
        ))
    }

    private func toggleExpanded() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
            store.toggleFolder(id: PreviewStore.unorganizedSectionID)
        }
    }
}

// MARK: - Flat Unorganized File Row View

struct FlatUnorganizedFileRowView: View {
    @SortyHotReload private var hotReload
    let file: FileItem
    @ObservedObject var dragDropManager: DragDropManager
    let store: PreviewStore
    let duplicateInfo: DuplicateInfo?
    let isHighlighted: Bool
    let moveDestinations: [PreviewMoveDestination]
    let onPlanChanged: () -> Void
    @State private var isDragging = false

    var body: some View {
        rowContent
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isHighlighted ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            
            Button {
                NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            if !moveDestinations.isEmpty {
                Menu("Move to Folder") {
                    ForEach(moveDestinations) { destination in
                        Button(destination.name) {
                            store.moveFile(fileID: file.id, toFolderID: destination.id)
                            onPlanChanged()
                        }
                    }
                }
            }
        }
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
        }
        .focusable()
        .onKeyPress(.return) {
            NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
            return .handled
        }
        .accessibilityAction(named: "Open \(file.displayName)") {
            NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
        }
        .accessibilityAction(named: "Reveal \(file.displayName) in Finder") {
            NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
        }
        .accessibilityActions {
            ForEach(moveDestinations) { destination in
                Button("Move to \(destination.name)") {
                    store.moveFile(fileID: file.id, toFolderID: destination.id)
                    onPlanChanged()
                }
            }
        }
        .opacity(isDragging ? 0.5 : 1.0)
        .onDrag {
            isDragging = true
            dragDropManager.startDrag(file)
            return NSItemProvider(object: file.id.uuidString as NSString)
        }
    }

    private var rowContent: some View {
        HStack {
            FileThumbnailView(url: URL(fileURLWithPath: file.path), size: CGSize(width: 20, height: 20))
            Text(file.displayName)
            Spacer()

            if let dupInfo = duplicateInfo {
                LiquidGlassDuplicateButton(
                    duplicateInfo: dupInfo,
                    highlightedFileID: Binding(
                        get: { store.highlightedFileID },
                        set: { store.highlightedFileID = $0 }
                    )
                )
            }

            Text(file.formattedSize)
                .foregroundColor(.secondary)

            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary.opacity(0.6))
        }
    }

    private var backgroundColor: Color {
        isHighlighted ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.12) : (isDragging ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.1) : Color.clear)
    }

}
