import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

// MARK: - Flattened Row View

struct FlattenedRowView: View, @MainActor Equatable {
    @SortyHotReload private var hotReload
    let presentation: PreviewRowPresentation
    let store: PreviewStore
    @ObservedObject var dragDropManager: DragDropManager
    let onPlanChanged: () -> Void

    static func == (lhs: FlattenedRowView, rhs: FlattenedRowView) -> Bool {
        lhs.presentation == rhs.presentation
    }
    
    var body: some View {
        switch presentation {
        case .folder(let row, let tags, let comment, let fileCount):
            if case .folder(let suggestion) = row.type {
                FlatFolderRowView(
                    suggestion: suggestion,
                    depth: row.depth,
                    isExpanded: row.isExpanded,
                    rowID: row.id,
                    folderTags: tags,
                    folderComment: comment,
                    fileCount: fileCount,
                    store: store,
                    dragDropManager: dragDropManager,
                    onPlanChanged: onPlanChanged
                )
            }
        case .file(
            let row,
            let renameMapping,
            let tags,
            let comment,
            let duplicateInfo,
            let parentSuggestion,
            let isHighlighted
        ):
            if case .file(let file, let parentFolderID) = row.type {
                FlatFileRowView(
                    file: file,
                    depth: row.depth,
                    parentFolderID: parentFolderID,
                    renameMapping: renameMapping,
                    fileTags: tags,
                    fileComment: comment,
                    duplicateInfo: duplicateInfo,
                    parentSuggestion: parentSuggestion,
                    isHighlighted: isHighlighted,
                    store: store,
                    dragDropManager: dragDropManager,
                    onPlanChanged: onPlanChanged
                )
            }
        case .unorganizedHeader(let row, let fileCount):
            FlatUnorganizedHeaderView(
                fileCount: fileCount,
                isExpanded: row.isExpanded,
                store: store,
                dragDropManager: dragDropManager,
                onPlanChanged: onPlanChanged
            )
        case .unorganizedFile(let row, let duplicateInfo, let isHighlighted, let moveDestinations):
            if case .unorganizedFile(let file) = row.type {
                FlatUnorganizedFileRowView(
                    file: file,
                    dragDropManager: dragDropManager,
                    store: store,
                    duplicateInfo: duplicateInfo,
                    isHighlighted: isHighlighted,
                    moveDestinations: moveDestinations,
                    onPlanChanged: onPlanChanged
                )
            }
        case .remaining(let row, let count):
            HStack(spacing: 8) {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                Text("\(count.formatted()) more files hidden to keep the preview responsive. Apply still includes them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, CGFloat(row.depth) * 20 + 12)
            .padding(.vertical, 7)
        }
    }
}
