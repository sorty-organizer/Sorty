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
                iconColor: SortyDesignSystem.Colors.warning,
                title: "Empty directory",
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
                iconColor: SortyDesignSystem.Colors.warning,
                title: "All files unorganized",
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

    var body: some View {
        SortyEmptyState(
            LocalizedStringKey(title),
            systemImage: icon,
            message: LocalizedStringKey(message),
            tint: iconColor
        ) {
            if !actions.isEmpty {
                HStack(spacing: 12) {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        if index == 0 {
                            actionButton(action)
                                .buttonStyle(.sortyProminent(size: .small))
                        } else {
                            actionButton(action)
                                .buttonStyle(.sortyBordered(size: .small))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title): \(message)")
    }

    private func actionButton(_ action: EmptyAction) -> some View {
        Button {
            HapticFeedbackManager.shared.tap()
            action.action()
        } label: {
            Label(action.title, systemImage: action.icon)
        }
        .accessibilityIdentifier(action.accessibilityID ?? "")
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
