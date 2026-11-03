import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

// MARK: - Flat File Row View

struct FlatFileRowView: View {
    @SortyHotReload private var hotReload
    let file: FileItem
    let depth: Int
    let parentFolderID: UUID
    let renameMapping: FileRenameMapping?
    let fileTags: [String]
    let fileComment: String?
    let duplicateInfo: DuplicateInfo?
    let parentSuggestion: FolderSuggestion?
    let isHighlighted: Bool
    let store: PreviewStore
    @ObservedObject var dragDropManager: DragDropManager
    let onPlanChanged: () -> Void
    @EnvironmentObject var learningsManager: LearningsManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    /// Injected for tests (MockAIClient); defaults to the factory in production.
    var injectedAIClient: (any AIClientProtocol)? = nil
    
    @State private var isDragging = false
    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var isRegeneratingName = false
    @FocusState private var isFocused: Bool
    
    private var rowContent: FlatFileRowContent {
        FlatFileRowContent(
            file: file,
            renameMapping: renameMapping,
            renameHelpText: renameMapping.map(renameHelpText),
            fileTags: fileTags,
            fileComment: fileComment,
            duplicateInfo: duplicateInfo,
            parentSuggestion: parentSuggestion,
            learningsManager: learningsManager,
            isHighlighted: isHighlighted,
            isEditingName: $isEditingName,
            editedName: $editedName,
            isRegeneratingName: $isRegeneratingName,
            highlightedFileID: Binding(
                get: { store.highlightedFileID },
                set: { store.highlightedFileID = $0 }
            ),
            isFocused: $isFocused,
            onSave: saveRename,
            onCancel: cancelRename,
            onStartEditing: startEditing,
            onRegenerate: regenerateSuggestedName,
            onReject: rejectRename
        )
    }

    var body: some View {
        FlatFileRowSurface(
            content: rowContent,
            depth: depth,
            isHighlighted: isHighlighted,
            isEditingName: isEditingName,
            isDragging: $isDragging,
            hasRename: renameMapping?.hasRename == true,
            onOpen: openFile,
            onReveal: revealInFinder,
            onRename: { startEditing(initialValue: editableName) },
            onRegenerate: regenerateSuggestedName,
            onRejectRename: rejectRename,
            onRevertOrganization: revertOrganization,
            onBeginDrag: beginDrag,
            onDisappear: resetInteractionState
        )
        .onChange(of: isEditingName) { _, editing in
            store.setRenaming(editing, fileID: file.id)
        }
    }
    
    private var editableName: String {
        FlatFileRowContent.editableName(for: file, renameMapping: renameMapping)
    }

    private func startEditing(initialValue: String) {
        HapticFeedbackManager.shared.selection()
        editedName = initialValue
        isEditingName = true
        isFocused = true
    }

    private func openFile() {
        NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
    }

    private func revealInFinder() {
        NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
    }

    private func rejectRename() {
        store.rejectRename(fileID: file.id, folderID: parentFolderID)
        onPlanChanged()
    }

    private func revertOrganization() {
        store.moveFileToUnorganized(fileID: file.id)
        onPlanChanged()
    }

    private func beginDrag() -> NSItemProvider {
        isDragging = true
        dragDropManager.startDrag(file)
        return NSItemProvider(object: file.id.uuidString as NSString)
    }

    private func resetInteractionState() {
        isDragging = false
        isEditingName = false
        store.setRenaming(false, fileID: file.id)
    }
    
    private func saveRename() {
        if !editedName.isEmpty {
            store.updateRename(fileID: file.id, folderID: parentFolderID, newName: editedName, isUserEdited: true)
            onPlanChanged()
        }
        isEditingName = false
    }

    private func regenerateSuggestedName() {
        guard !isRegeneratingName else { return }
        let previousSuggestion = renameMapping?.suggestedName ?? ""
        withAnimation(.sortyFade) {
            isRegeneratingName = true
        }
        HapticFeedbackManager.shared.selection()

        Task {
            do {
                let replacementName = try await RenameRegenerator.regenerate(
                    file: file,
                    currentSuggestion: renameMapping?.suggestedName,
                    config: settingsViewModel.config,
                    client: injectedAIClient
                )
                await MainActor.run {
                    store.updateRename(fileID: file.id, folderID: parentFolderID, newName: replacementName)
                    onPlanChanged()
                    withAnimation(.sortyFade) {
                        isRegeneratingName = false
                    }
                    HapticFeedbackManager.shared.success()
                }
            } catch {
                await MainActor.run {
                    let fallbackName = RenameRegenerator.distinctName(
                        previousSuggestion.isEmpty ? file.displayName : previousSuggestion,
                        previousSuggestion: previousSuggestion
                    )
                    store.updateRename(fileID: file.id, folderID: parentFolderID, newName: fallbackName)
                    onPlanChanged()
                    withAnimation(.sortyFade) {
                        isRegeneratingName = false
                    }
                    HapticFeedbackManager.shared.error()
                }
            }
        }
    }

    private func cancelRename() {
        isEditingName = false
    }

    private func renameHelpText(_ mapping: FileRenameMapping) -> String {
        if mapping.isUserEdited == true { return "Renamed by you" }
        let reason = mapping.renameReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty ? "Sorty suggested rename" : reason
    }
}
