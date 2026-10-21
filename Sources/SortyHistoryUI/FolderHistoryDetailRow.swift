import AppKit
import SwiftUI

// MARK: - Folder History Detail Row

struct FolderHistoryDetailRow: View {
    @SortyHotReload private var hotReload
    let suggestion: FolderSuggestion
    let rootDirectory: URL?
    @Binding var highlightedFileID: UUID?
    @EnvironmentObject var learningsManager: LearningsManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var showStoragePopover = false
    @State private var visibleFileCount: Int = 60
    private let filePageSize: Int = 60
    private let filesByHash: [String: [FileItem]]

    init(
        suggestion: FolderSuggestion,
        rootDirectory: URL? = nil,
        highlightedFileID: Binding<UUID?>
    ) {
        self.suggestion = suggestion
        self.rootDirectory = rootDirectory
        _highlightedFileID = highlightedFileID

        var filesByHash: [String: [FileItem]] = [:]
        filesByHash.reserveCapacity(suggestion.files.count)
        for file in suggestion.files {
            guard let hash = file.sha256Hash, !hash.isEmpty else { continue }
            filesByHash[hash, default: []].append(file)
        }
        self.filesByHash = filesByHash
    }

    private func fileTags(for file: FileItem) -> [String]? {
        let tags = suggestion.tags(for: file)
        return tags.isEmpty ? nil : tags
    }

    private func fileComment(for file: FileItem) -> String? {
        suggestion.comment(for: file)
    }

    private var isStorageDestination: Bool {
        suggestion.folderName.hasPrefix("/")
    }

    private var storageLocationURL: URL? {
        StorageLocationPathResolver.absoluteURL(from: suggestion.folderName)
    }

    private var storageLocationPath: String {
        storageLocationURL?.path ?? suggestion.folderName
    }

    private var storageLocationDisplayName: String {
        storageLocationURL?.lastPathComponent ?? "Storage"
    }

    private func fileDuplicateInfo(for file: FileItem) -> DuplicateInfo? {
        guard let hash = file.sha256Hash,
              let sharedGroup = filesByHash[hash],
              sharedGroup.count > 1 else {
            return nil
        }
        return DuplicateInfo(
            file: file,
            sharedGroup: sharedGroup,
            isExactMatch: true,
            similarity: 1.0
        )
    }

    private func subtreeContainsFile(_ fileID: UUID, in folder: FolderSuggestion) -> Bool {
        if folder.files.contains(where: { $0.id == fileID }) {
            return true
        }
        for subfolder in folder.subfolders {
            if subtreeContainsFile(fileID, in: subfolder) {
                return true
            }
        }
        return false
    }

    private func expandForHighlightedFileIfNeeded(_ fileID: UUID?) {
        guard let fileID, !isExpanded else { return }
        guard subtreeContainsFile(fileID, in: suggestion) else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) {
            isExpanded = true
        }
    }

    private func toggleExpanded() {
        HapticFeedbackManager.shared.tap()
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) {
            isExpanded.toggle()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .symbolReplaceTransition(animationValue: isExpanded)
                            .accessibilityHidden(true)

                        CompactFolderThumbnail(
                            url: nil,
                            folderName: suggestion.folderName,
                            size: 18
                        )
                        .scaleEffect(isHovered ? 1.1 : 1.0)
                        .animation(reduceMotion ? nil : .subtleBounce, value: isHovered)
                        .accessibilityHidden(true)

                        PrivacySensitivePathText(path: suggestion.folderName)
                            .fontWeight(.semibold)

                        Text("(\(suggestion.totalFileCount) files)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onHover { hovering in
                    isHovered = hovering
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(suggestion.folderName), \(suggestion.totalFileCount) files")
                .accessibilityHint(isExpanded ? "Collapses the folder" : "Expands the folder")

                if isStorageDestination {
                    storageLocationDropdown
                }

                if !suggestion.tags.isEmpty {
                    TagDotsView(tags: suggestion.tags)
                }

                if let comment = suggestion.comment, !comment.isEmpty {
                    CommentBubbleButton(comment: comment)
                }

                LiquidGlassReasoningButton(suggestion: suggestion)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    let shouldAnimate = suggestion.files.count <= 40
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(suggestion.files.prefix(visibleFileCount).enumerated()), id: \.element.id) { index, fileItem in
                            FolderHistoryFileRow(
                                file: fileItem,
                                suggestion: suggestion,
                                tags: fileTags(for: fileItem),
                                comment: fileComment(for: fileItem),
                                duplicateInfo: fileDuplicateInfo(for: fileItem),
                                rootDirectory: rootDirectory,
                                learningsManager: learningsManager,
                                highlightedFileID: $highlightedFileID,
                                isExpanded: isExpanded,
                                animationDelay: shouldAnimate && !reduceMotion
                                    ? Double(index) * 0.02
                                    : nil
                            )
                        }

                        if suggestion.files.count > visibleFileCount {
                            Button {
                                HapticFeedbackManager.shared.tap()
                                visibleFileCount = min(visibleFileCount + filePageSize, suggestion.files.count)
                            } label: {
                                Label("Show more files", systemImage: "chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 12)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    ForEach(suggestion.subfolders) { subfolder in
                        FolderHistoryDetailRow(
                            suggestion: subfolder,
                            rootDirectory: rootDirectory,
                            highlightedFileID: $highlightedFileID
                        )
                        .padding(.leading, 12)
                    }
                }
                .padding(.leading, 12)
                .padding(.vertical, 4)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        )
                )
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(8)
        .onAppear {
            expandForHighlightedFileIfNeeded(highlightedFileID)
        }
        .onChange(of: highlightedFileID) { _, newValue in
            expandForHighlightedFileIfNeeded(newValue)
        }
    }

    @ViewBuilder
    private var storageLocationDropdown: some View {
        Button {
            showStoragePopover.toggle()
        } label: {
            Image(systemName: "externaldrive")
                .font(.caption)
                .foregroundStyle(showStoragePopover ? .primary : .secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help("Storage location options")
        .accessibilityIdentifier("HistoryStorageLocationMenuButton-\(suggestion.id.uuidString)")
        .popover(isPresented: $showStoragePopover, arrowEdge: .bottom) {
            StorageLocationPopoverContent(
                displayName: storageLocationDisplayName,
                path: storageLocationPath,
                onShowInFinder: {
                    showStoragePopover = false
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: storageLocationPath)
                },
                onCopyPath: {
                    showStoragePopover = false
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(storageLocationPath, forType: .string)
                }
            )
            .systemLiquidGlassPopover(cornerRadius: 12)
        }
    }
}

struct FolderHistoryFileRow: View {
    @SortyHotReload private var hotReload
    let file: FileItem
    let suggestion: FolderSuggestion
    let tags: [String]?
    let comment: String?
    let duplicateInfo: DuplicateInfo?
    let rootDirectory: URL?
    let learningsManager: LearningsManager
    @Binding var highlightedFileID: UUID?
    let isExpanded: Bool
    let animationDelay: Double?

    var body: some View {
        HStack(spacing: 8) {
            FileThumbnailView(
                url: URL(fileURLWithPath: file.path),
                size: CGSize(width: 20, height: 20)
            )
            Text(file.displayName)

            if let tags, !tags.isEmpty {
                TagDotsView(tags: tags)
            }

            if let comment, !comment.isEmpty {
                CommentBubbleButton(comment: comment)
            }

            LiquidGlassLearningsButton(
                file: file,
                suggestion: suggestion,
                learningsManager: learningsManager
            )

            if let duplicateInfo {
                LiquidGlassDuplicateButton(
                    duplicateInfo: duplicateInfo,
                    highlightedFileID: $highlightedFileID
                )
            }

            Spacer()
            Text(file.formattedSize)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.leading, 12)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    highlightedFileID == file.id
                        ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.12)
                        : Color.clear
                )
        )
        .opacity(isExpanded ? 1 : 0)
        .offset(y: isExpanded ? 0 : -5)
        .animation(
            animationDelay.map {
                Animation.spring(response: 0.3, dampingFraction: 0.7).delay($0)
            },
            value: isExpanded
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(file.displayName), \(file.formattedSize)")
    }
}
