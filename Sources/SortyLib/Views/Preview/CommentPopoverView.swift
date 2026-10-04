//
//  CommentPopoverView.swift
//  Sorty
//

import SwiftUI

struct CommentBubbleButton: View {
    @SortyHotReload private var hotReload
    let comment: String
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "text.bubble")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            CommentPopoverView(comment: comment)
                .systemLiquidGlassPopover(cornerRadius: 12)
        }
        .help("View comment")
    }
}

struct CommentPopoverView: View {
    @SortyHotReload private var hotReload
    let comment: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Finder Comment")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            Text(comment)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(minWidth: 200, maxWidth: 300)
    }
}
