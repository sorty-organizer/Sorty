import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RenameGenerationEventList: View {
    let events: [RenameStreamEvent]
    @Binding var shouldFollowLatest: Bool

    var indexedEvents: [(offset: Int, element: RenameStreamEvent)] {
        Array(events.enumerated())
    }

    var activeEventID: String? { events.last?.id }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                eventRows
            }
            .onHover { hovering in
                shouldFollowLatest = !hovering
            }
            .onChange(of: activeEventID) { _, id in
                guard shouldFollowLatest, let id else { return }
                withAnimation(.smooth(duration: 0.24)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private var eventRows: some View {
        VStack(spacing: 8) {
            ForEach(indexedEvents, id: \.element.id) { index, event in
                RenameGenerationRow(
                    originalName: event.originalName,
                    suggestedName: event.suggestedName,
                    filePath: event.filePath,
                    isDirectory: event.isDirectory,
                    isActive: activeEventID == event.id,
                    isRevealed: event.isRevealed,
                    isMostRecent: index == events.indices.last
                )
                .id(event.id)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .padding(.vertical, 1)
    }
}
