//
//  LiquidGlassDuplicateButton.swift
//  Sorty
//
//  Liquid glass style button for displaying duplicate file information.
//  Shows other duplicate files in a dropdown and provides quick actions via context menu.
//

import SwiftUI

/// Information about a file's duplicate status
public struct DuplicateInfo: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let file: FileItem
    private let groupFiles: [FileItem]
    public let isExactMatch: Bool
    public let similarity: Double

    public init(file: FileItem, duplicates: [FileItem], isExactMatch: Bool = true, similarity: Double = 1.0) {
        self.id = file.id
        self.file = file
        self.groupFiles = [file] + duplicates
        self.isExactMatch = isExactMatch
        self.similarity = similarity
    }

    package init(file: FileItem, sharedGroup: [FileItem], isExactMatch: Bool = true, similarity: Double = 1.0) {
        self.id = file.id
        self.file = file
        self.groupFiles = sharedGroup
        self.isExactMatch = isExactMatch
        self.similarity = similarity
    }

    public var duplicates: [FileItem] {
        groupFiles.filter { $0.id != file.id }
    }

    public var duplicateCount: Int {
        max(0, groupFiles.count - 1)
    }

    public var formattedSimilarity: String {
        if isExactMatch { return "Exact Match" }
        return "\(Int(similarity * 100))% Similar"
    }
}

package struct LiquidGlassDuplicateButton: View {
    @SortyHotReload private var hotReload
    let duplicateInfo: DuplicateInfo
    var onFileSelected: ((FileItem) -> Void)? = nil

    @State private var showPopover = false
    @State private var hoveredFileID: UUID? = nil

    init(duplicateInfo: DuplicateInfo, onFileSelected: ((FileItem) -> Void)? = nil) {
        self.duplicateInfo = duplicateInfo
        self.onFileSelected = onFileSelected
    }

    package init(duplicateInfo: DuplicateInfo, highlightedFileID: Binding<UUID?>) {
        self.duplicateInfo = duplicateInfo
        self.onFileSelected = { selectedFile in
            highlightedFileID.wrappedValue = selectedFile.id
        }
    }

    private var accentColor: Color {
        duplicateInfo.isExactMatch ? .red : .orange
    }

    package var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            ZStack {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(showPopover ? accentColor : Color.secondary)
            }
            .frame(width: 22, height: 22)
            .systemLiquidGlassBackground(cornerRadius: 11)
            .overlay(
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(showPopover ? 0.5 : 0.3),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
            .shadow(color: Color.black.opacity(0.08), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .help("\(duplicateInfo.duplicateCount) duplicate\(duplicateInfo.duplicateCount == 1 ? "" : "s") found")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            duplicatePopoverContent
                .systemLiquidGlassPopover(cornerRadius: 12)
        }
        .contextMenu {
            contextMenuItems
        }
    }

    // MARK: - Popover Content

    private var duplicatePopoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.12))
                        .frame(width: 28, height: 28)

                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accentColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Duplicates")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)

                    Text(duplicateInfo.formattedSimilarity)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Text("\(duplicateInfo.duplicateCount)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .numericTextTransition(animationValue: duplicateInfo.duplicateCount)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(accentColor))
            }
            .padding(.bottom, 10)

            Divider()
                .opacity(0.4)
                .padding(.bottom, 10)

            // Current file
            VStack(alignment: .leading, spacing: 6) {
                Text("This File")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)

                duplicateFileRow(file: duplicateInfo.file, isCurrent: true)
            }
            .padding(.bottom, 12)

            // Other duplicates
            VStack(alignment: .leading, spacing: 6) {
                Text("Other Copies")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)

                ForEach(duplicateInfo.duplicates) { duplicate in
                    duplicateFileRow(file: duplicate, isCurrent: false)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 280, maxWidth: 360)
    }

    @ViewBuilder
    private func duplicateFileRow(file: FileItem, isCurrent: Bool) -> some View {
        Button {
            if !isCurrent {
                onFileSelected?(file)
            }
            showPopover = false
        } label: {
            HStack(spacing: 10) {
                FileThumbnailView(url: URL(fileURLWithPath: file.path), size: CGSize(width: 24, height: 24))

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.displayName)
                        .font(.callout)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                        .lineLimit(1)

                    Text(file.formattedSize)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if isCurrent {
                    Text("Current")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(SortyDesignSystem.Colors.resolvedAccent))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hoveredFileID == file.id ? Color.secondary.opacity(0.1) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredFileID = isHovering ? file.id : nil
        }
        .contextMenu {
            fileContextMenu(for: file)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            NSWorkspace.shared.selectFile(duplicateInfo.file.path, inFileViewerRootedAtPath: "")
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }

        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: duplicateInfo.file.path))
        } label: {
            Label("Quick Look", systemImage: "eye")
        }

        Divider()

        Button {
            showPopover = true
        } label: {
            Label("View All Duplicates", systemImage: "doc.on.doc")
        }
    }

    @ViewBuilder
    private func fileContextMenu(for file: FileItem) -> some View {
        Button {
            NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }

        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
        } label: {
            Label("Quick Look", systemImage: "eye")
        }

        Divider()

        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(file.path, forType: .string)
        } label: {
            Label("Copy Path", systemImage: "doc.on.clipboard")
        }
    }
}

// MARK: - Previews

#Preview("Liquid Glass Duplicate Button") {
    let file1 = FileItem(path: "/test/document.pdf", name: "document", extension: "pdf", size: 1024000)
    let file2 = FileItem(path: "/test/copy/document.pdf", name: "document", extension: "pdf", size: 1024000)
    let file3 = FileItem(path: "/backup/document.pdf", name: "document", extension: "pdf", size: 1024000)

    let info = DuplicateInfo(file: file1, duplicates: [file2, file3])

    LiquidGlassDuplicateButton(duplicateInfo: info)
        .padding()
}

#Preview("Liquid Glass Duplicate - Semantic") {
    let file1 = FileItem(path: "/test/photo_001.jpg", name: "photo_001", extension: "jpg", size: 2048000)
    let file2 = FileItem(path: "/test/photo_001_copy.jpg", name: "photo_001_copy", extension: "jpg", size: 1900000)

    let info = DuplicateInfo(file: file1, duplicates: [file2], isExactMatch: false, similarity: 0.95)

    LiquidGlassDuplicateButton(duplicateInfo: info)
        .padding()
}
