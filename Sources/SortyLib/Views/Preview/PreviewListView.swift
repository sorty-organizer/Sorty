//
//  PreviewListView.swift
//  Sorty
//
//  List container for the preview file/folder tree
//

import AppKit
import SwiftUI

struct PreviewListView: View {
    @SortyHotReload private var hotReload
    @ObservedObject var store: PreviewStore
    @ObservedObject var dragDropManager: DragDropManager
    let onPlanChanged: () -> Void
    let emptyStateType: EmptyStateType
    var onFocusInstructions: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    var onChooseFolder: (() -> Void)? = nil
    var onExitPreview: (() -> Void)? = nil
    
    enum EmptyStateType {
        case allUnorganized(Int)  // Int is the file count
        case emptyDirectory
        case none
        
        var isEmpty: Bool {
            switch self {
            case .none: return false
            default: return true
            }
        }
    }
    
    var body: some View {
        ZStack {
            if emptyStateType.isEmpty {
                emptyStateView
            } else {
                OptimizedPreviewTree(
                    store: store,
                    dragDropManager: dragDropManager,
                    onPlanChanged: onPlanChanged
                )
            }
        }
    }
    
    @ViewBuilder
    private var emptyStateView: some View {
        switch emptyStateType {
        case .emptyDirectory:
            EmptyPreviewState(
                icon: "folder.badge.questionmark",
                iconColor: .orange,
                title: "Empty Directory",
                message: "This folder doesn't contain any files to organize.",
                actions: [
                    EmptyAction(
                        title: "Choose Folder",
                        icon: "folder.badge.plus",
                        accessibilityID: "PreviewEmptyStateChooseFolder",
                        action: { onChooseFolder?() }
                    ),
                    EmptyAction(
                        title: "Back",
                        icon: "chevron.left",
                        accessibilityID: "PreviewEmptyStateBack",
                        action: { onExitPreview?() }
                    )
                ]
            )
            
        case .allUnorganized(let count):
            EmptyPreviewState(
                icon: "questionmark.folder",
                iconColor: .orange,
                title: "All Files Unorganized",
                message: "\(count) files couldn't be automatically organized. Try providing specific instructions to help Sorty categorize them better.",
                actions: [
                    EmptyAction(
                        title: "Add Instructions",
                        icon: "text.bubble",
                        accessibilityID: "PreviewEmptyStateAddInstructions",
                        action: { onFocusInstructions?() }
                    ),
                    EmptyAction(
                        title: "Regenerate",
                        icon: "arrow.triangle.2.circlepath",
                        accessibilityID: "PreviewEmptyStateRegenerate",
                        action: { onRegenerate?() }
                    )
                ]
            )
            
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Empty Preview State

struct EmptyPreviewState: View {
    @SortyHotReload private var hotReload
    let icon: String
    let iconColor: Color
    let title: String
    let message: String
    var actions: [EmptyAction] = []
    
    @State private var isHovered = false
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            emptyStateArtwork
            
            VStack(spacing: 8) {
                Text(LocalizedStringKey(title))
                    .font(.title3)
                    .fontWeight(.semibold)
                
                Text(message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            if !actions.isEmpty {
                HStack(spacing: 12) {
                    ForEach(actions) { action in
                        Button {
                            HapticFeedbackManager.shared.tap()
                            action.action()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: action.icon)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(action.title)
                                    .font(.caption.bold())
                            }
                        }
                        .buttonStyle(.sortyPrimary(size: .small))
                        .accessibilityIdentifier(action.accessibilityID ?? "")
                    }
                }
                .padding(.top, 8)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .opacity(isHovered ? 0.95 : 1.0)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title): \(message)")
    }

    @ViewBuilder
    private var emptyStateArtwork: some View {
        fallbackArtwork
    }

    private var fallbackArtwork: some View {
        ZStack {
            Circle()
                .fill(iconColor.opacity(0.1))
                .frame(width: 100, height: 100)

            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(iconColor)
        }
        .accessibilityHidden(true)
    }
}

struct EmptyAction: Identifiable {
    let title: String
    let icon: String
    var accessibilityID: String? = nil
    let action: () -> Void

    var id: String {
        accessibilityID ?? "\(title)|\(icon)"
    }
}

#if DEBUG
// MARK: - Previews

#Preview("Preview List - Normal") {
    PreviewListView(
        store: PreviewStore(plan: PreviewMocks.makeOrganizationPlan()),
        dragDropManager: DragDropManager(),
        onPlanChanged: {},
        emptyStateType: .none
    )
    .frame(width: 800, height: 400)
}

#Preview("Empty State - All Unorganized") {
    PreviewListView(
        store: PreviewStore(plan: OrganizationPlan()),
        dragDropManager: DragDropManager(),
        onPlanChanged: {},
        emptyStateType: .allUnorganized(12)
    )
    .frame(width: 800, height: 400)
}

#Preview("Empty State - Empty Directory") {
    PreviewListView(
        store: PreviewStore(plan: OrganizationPlan()),
        dragDropManager: DragDropManager(),
        onPlanChanged: {},
        emptyStateType: .emptyDirectory
    )
    .frame(width: 800, height: 400)
}

#endif
