import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

// MARK: - Flat Folder Row View

struct FlatFolderRowView: View {
    @SortyHotReload private var hotReload

    /// Memoizes storage-location matches across rows and body evaluations.
    /// All access runs under the lock, so sharing one instance is safe.
    private final class StorageMatchCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: StorageLocation?] = [:]

        func match(for key: String, compute: () -> StorageLocation?) -> StorageLocation? {
            lock.withLock {
                if let boxed = storage[key] {
                    return boxed
                }
                let result = compute()
                if storage.count > 64 {
                    storage.removeAll()
                }
                storage[key] = result
                return result
            }
        }
    }

    private static let storageMatchCache = StorageMatchCache()

    let suggestion: FolderSuggestion
    let depth: Int
    let isExpanded: Bool
    let rowID: String
    let folderTags: [String]
    let folderComment: String?
    let fileCount: Int
    let store: PreviewStore
    @ObservedObject var dragDropManager: DragDropManager
    let onPlanChanged: () -> Void
    @EnvironmentObject var learningsManager: LearningsManager
    @EnvironmentObject var storageLocationsManager: StorageLocationsManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isDropTarget = false
    @State private var showStorageLocationPicker = false
    @State private var showStoragePopover = false
    @State private var storageLocationPickerErrorMessage: String?

    private var isStorageDestination: Bool {
        suggestion.folderName.hasPrefix("/")
    }

    private var matchedStorageLocation: StorageLocation? {
        guard isStorageDestination else { return nil }
        // Memoized per folder + locations signature. The resolver walks every
        // location per row per body evaluation; the signature rebuild is one
        // string join, and hits skip the resolver entirely.
        let key = suggestion.folderName + "#" + storageLocationsManager.locations.map(\.path).joined(separator: "|")
        return Self.storageMatchCache.match(for: key) {
            storageLocationsManager.locations.lazy
                .filter { StorageLocationPathResolver.isPath(suggestion.folderName, within: $0.path) }
                .max { $0.path.count < $1.path.count }
        }
    }

    private var usedStorageURL: URL? {
        if let matchedStorageLocation {
            return URL(fileURLWithPath: matchedStorageLocation.path, isDirectory: true)
        }
        return StorageLocationPathResolver.absoluteURL(from: suggestion.folderName)
    }

    private var usedStorageDisplayName: String {
        if let matchedStorageLocation {
            return matchedStorageLocation.name
        }
        return usedStorageURL?.lastPathComponent ?? "Storage"
    }

    private var usedStoragePath: String {
        if let matchedStorageLocation {
            return matchedStorageLocation.path
        }
        return usedStorageURL?.path ?? suggestion.folderName
    }

    private var storageLocationPickerErrorIsPresented: Binding<Bool> {
        Binding(
            get: { storageLocationPickerErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    storageLocationPickerErrorMessage = nil
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            folderHeader
            .padding(.leading, CGFloat(depth * 16))
            .padding(.vertical, 4)
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
                named: isExpanded ? "Collapse \(suggestion.folderName)" : "Expand \(suggestion.folderName)",
                toggleExpanded
            )
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isDropTarget ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.1) : Color.clear)
                    .strokeBorder(isDropTarget ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.55) : Color.clear, lineWidth: 1.5)
            )
            .contextMenu {
                FlatFolderRowContextMenu(
                    isStorageDestination: isStorageDestination,
                    onRevert: revertOrganization,
                    onChangeStorage: showStoragePicker,
                    onReveal: revealStorageLocationInFinder
                )
            }
            .onDrop(of: [.text], delegate: OptimizedFileDropDelegate(
                targetFolderID: suggestion.id,
                store: store,
                draggedFile: $dragDropManager.draggedFile,
                isTargeted: $isDropTarget,
                onPlanChanged: onPlanChanged
            ))
            .fileImporter(
                isPresented: $showStorageLocationPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleStorageLocationImport(result)
            }
            .alert(
                "Couldn't Change Storage Location",
                isPresented: storageLocationPickerErrorIsPresented
            ) {
                Button("OK", role: .cancel) {
                    storageLocationPickerErrorMessage = nil
                }
            } message: {
                Text(storageLocationPickerErrorMessage ?? "Please try selecting the folder again.")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
    }

    private var storageLocationDropdown: some View {
        Button {
            showStoragePopover.toggle()
        } label: {
            Image(systemName: "externaldrive")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(showStoragePopover ? .primary : .secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("StorageLocationMenuButton")
        .help("Storage location options")
        .popover(isPresented: $showStoragePopover, arrowEdge: .bottom) {
            StorageLocationPopoverContent(
                displayName: usedStorageDisplayName,
                path: usedStoragePath,
                onChangeLocation: {
                    showStoragePopover = false
                    showStorageLocationPicker = true
                },
                onShowInFinder: {
                    showStoragePopover = false
                    revealStorageLocationInFinder()
                },
                onCopyPath: {
                    showStoragePopover = false
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(usedStoragePath, forType: .string)
                }
            )
            .systemLiquidGlassPopover(cornerRadius: 12)
        }
    }

    private func finderIcon(for path: String) -> some View {
        AppKitImageView(
            image: NSWorkspace.shared.icon(forFile: path),
            size: CGSize(width: 12, height: 12),
            cornerRadius: 2
        )
        .frame(width: 12, height: 12)
    }

    private func revealStorageLocationInFinder() {
        guard let usedStorageURL else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: usedStorageURL.path)
    }

    private func toggleExpanded() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
            store.toggleFolder(id: rowID)
        }
    }

    private func revertOrganization() {
        store.revertFolderOrganization(folderID: suggestion.id)
        onPlanChanged()
    }

    private func showStoragePicker() {
        showStorageLocationPicker = true
    }

    private func handleStorageLocationImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let selectedURL = urls.first else { return }
            do {
                try storageLocationsManager.addLocation(url: selectedURL, customName: nil)
            } catch {
                DebugLogger.log("Could not add selected storage location during preview destination change: \(error)")
            }
            store.updateFolderDestination(
                folderID: suggestion.id,
                newDestinationPath: selectedURL.path
            )
            onPlanChanged()
        case .failure(let error):
            storageLocationPickerErrorMessage = error.localizedDescription
        }
    }

    private var folderHeader: some View {
        HStack {
            FlatFolderRowHeaderContent(
                folderName: suggestion.folderName,
                fileCount: fileCount,
                isExpanded: isExpanded,
                isDropTarget: isDropTarget,
                reduceMotion: reduceMotion
            )

            if isStorageDestination {
                storageLocationDropdown
            }

            if !folderTags.isEmpty {
                TagDotsView(tags: folderTags)
            }

            if let comment = folderComment, !comment.isEmpty {
                CommentBubbleButton(comment: comment)
            }

            Spacer()

            LiquidGlassReasoningButton(
                suggestion: suggestion,
                learningsManager: learningsManager
            )
        }
    }
}
