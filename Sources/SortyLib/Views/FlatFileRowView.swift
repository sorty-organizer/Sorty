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
            onRegenerate: regenerateSuggestedName,
            onRejectRename: rejectRename,
            onRevertOrganization: revertOrganization,
            onBeginDrag: beginDrag,
            onDisappear: resetInteractionState
        )
    }
    
    private func startEditing(initialValue: String) {
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
    }
    
    private func saveRename() {
        if !editedName.isEmpty {
            store.updateRename(fileID: file.id, folderID: parentFolderID, newName: editedName)
            onPlanChanged()
        }
        isEditingName = false
    }

    private func regenerateSuggestedName() {
        guard !isRegeneratingName else { return }
        let previousSuggestion = renameMapping?.suggestedName ?? ""
        withAnimation(.easeInOut(duration: 0.2)) {
            isRegeneratingName = true
        }
        HapticFeedbackManager.shared.selection()

        Task {
            do {
                let client: any AIClientProtocol
                if let injected = injectedAIClient {
                    client = injected
                } else {
                    client = try AIClientFactory.createClient(config: settingsViewModel.config)
                }
                let plan = try await client.analyze(
                    files: [file],
                    customInstructions: renameRegenerationPrompt(),
                    personaPrompt: nil,
                    temperature: 0.8
                )
                let suggestedName = plan.suggestions
                    .lazy
                    .flatMap(\.allFileRenameMappings)
                    .first { $0.originalFile.id == file.id || $0.originalFile.displayName == file.displayName }?
                    .suggestedName
                guard let suggestedName, !suggestedName.isEmpty else {
                    throw AIClientError.invalidResponseFormat
                }
                let normalized = FilenameNormalizer.normalize(
                    suggestedName,
                    originalFilename: file.displayName,
                    options: settingsViewModel.config.renameNamingOptions
                ) ?? suggestedName
                let replacementName = distinctRegeneratedName(normalized, previousSuggestion: previousSuggestion)

                await MainActor.run {
                    store.updateRename(fileID: file.id, folderID: parentFolderID, newName: replacementName)
                    onPlanChanged()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isRegeneratingName = false
                    }
                    HapticFeedbackManager.shared.success()
                }
            } catch {
                await MainActor.run {
                    let fallbackName = distinctRegeneratedName(
                        previousSuggestion.isEmpty ? file.displayName : previousSuggestion,
                        previousSuggestion: previousSuggestion
                    )
                    store.updateRename(fileID: file.id, folderID: parentFolderID, newName: fallbackName)
                    onPlanChanged()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isRegeneratingName = false
                    }
                    HapticFeedbackManager.shared.error()
                }
            }
        }
    }

    private func renameRegenerationPrompt() -> String {
        let currentSuggestion = renameMapping?.suggestedName ?? "None"
        let metadata = file.contentMetadata
        let title = metadata?.documentTitle ?? ""
        let keywords = metadata?.detectedKeywords?.prefix(8).joined(separator: ", ") ?? ""
        let contentPreview = String(
            metadata?.allTextContent?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(900) ?? ""
        )

        return """
        Rename only this one file. Keep it in the current folder.

        Original filename: \(file.displayName)
        Current suggested filename: \(currentSuggestion)
        File extension to preserve: \(file.extension)
        Document title: \(title)
        Keywords: \(keywords)
        Content preview:
        \(contentPreview)

        Requirements:
        - Return Sorty's normal JSON organization response.
        - Use a single folder named ".".
        - Preserve the original file extension.
        - Make the name specific, useful, and concise.
        - Spaces are valid if they improve readability.
        - Do not return the current suggested filename. Generate a meaningfully different name.
        - Include suggested_name, rename_reason, and rename_confidence for this file.
        """
    }

    private func distinctRegeneratedName(_ candidate: String, previousSuggestion: String) -> String {
        guard candidate.caseInsensitiveCompare(previousSuggestion) == .orderedSame else {
            return candidate
        }

        let nsName = candidate as NSString
        let ext = nsName.pathExtension
        let base = nsName.deletingPathExtension
        let revised = "\(base) Revised"
        return ext.isEmpty ? revised : "\(revised).\(ext)"
    }
    
    private func cancelRename() {
        isEditingName = false
    }

    private func renameHelpText(_ mapping: FileRenameMapping) -> String {
        let reason = mapping.renameReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty ? "Sorty suggested rename" : reason
    }
}
