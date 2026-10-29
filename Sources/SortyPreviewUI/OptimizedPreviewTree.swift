//
//  OptimizedPreviewTree.swift
//  Sorty
//
//  Optimized flat-list rendering for large organization previews.
//  Uses a flattened data structure to avoid recursive view creation
//  and improve scrolling performance.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit


// MARK: - Optimized Preview Tree View

struct OptimizedPreviewTree: View {
    @SortyHotReload private var hotReload
    @ObservedObject var store: PreviewStore
    @ObservedObject var dragDropManager: DragDropManager
    let onPlanChanged: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.flattenedRows, id: \.id) { row in
                        FlattenedRowView(
                            presentation: store.presentation(for: row),
                            store: store,
                            dragDropManager: dragDropManager,
                            onPlanChanged: onPlanChanged
                        )
                        .equatable()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: store.highlightedFileID) { _, highlightedFileID in
                guard let highlightedFileID else { return }
                guard let rowID = store.revealFileAndResolveRowID(highlightedFileID) else { return }
                if reduceMotion {
                    scrollProxy.scrollTo(rowID, anchor: .center)
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        scrollProxy.scrollTo(rowID, anchor: .center)
                    }
                }
            }
        }
    }

}
