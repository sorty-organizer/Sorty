import AppKit
import Foundation
import SwiftUI
import Beam

struct UnifiedFileDetailRow: View {
    @SortyHotReload private var hotReload
    let file: FileItem
    let isRecommended: Bool
    let recommendation: String?
    let onKeep: () -> Void
    let onDelete: () -> Void

    private var fileURL: URL {
        URL(fileURLWithPath: file.path)
    }

    private var parentFolderName: String {
        fileURL.deletingLastPathComponent().lastPathComponent
    }

    var body: some View {
        verticalLayout
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .systemLiquidGlassBackground(cornerRadius: 12)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isRecommended ? Color.green.opacity(0.24) : Color.primary.opacity(0.07),
                    lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            UnifiedFileDetailContextMenu(
                isRecommended: isRecommended,
                onOpen: openFile,
                onReveal: revealInFinder,
                onKeep: onKeep,
                onDelete: onDelete
            )
        }
        .onTapGesture(count: 2, perform: openFile)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(file.displayName)
        .accessibilityAction(named: "Open file", openFile)
        .accessibilityAction(named: "Reveal file in Finder", revealInFinder)
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                thumbnail
                fileSummary
            }

            HStack {
                if isRecommended {
                    keepBadge
                } else {
                    keepButton
                    deleteButton
                }
                Spacer()
            }
        }
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            FileThumbnailView(url: fileURL, size: CGSize(width: 44, height: 44))

            if isRecommended {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption2)
                    .padding(2)
                    .background(Circle().fill(.white))
                    .offset(x: 4, y: 4)
                    .help("Recommended to Keep")
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 44, height: 44)
    }

    private var fileSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(file.displayName)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)

            if let label = recommendation {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.blue))
            }

            revealButton

            fileMetadata
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var revealButton: some View {
        Button {
            NSWorkspace.shared.selectFile(
                file.path,
                inFileViewerRootedAtPath: fileURL.deletingLastPathComponent().path)
        } label: {
            Label {
                Text(parentFolderName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                AppKitImageView(
                    image: NSWorkspace.shared.icon(
                        forFile: fileURL.deletingLastPathComponent().path),
                    size: CGSize(width: 12, height: 12)
                )
                .frame(width: 12, height: 12)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1), in: Capsule())
            .foregroundStyle(.secondary)
        }
        .contentShape(Capsule())
        .buttonStyle(.plain)
        .help("Reveal in Finder: \(PrivacyPathMasker.redactedPath(fileURL.deletingLastPathComponent().path))")
    }

    private var fileMetadata: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                if let date = file.creationDate {
                    Text("•")
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                if let pixels = file.totalPixels, pixels > 0 {
                    Text("•")
                    Text("\(formatPixels(pixels))")
                        .foregroundStyle(.blue)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                if let date = file.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                if let pixels = file.totalPixels, pixels > 0 {
                    Text("\(formatPixels(pixels))")
                        .foregroundStyle(.blue)
                }
            }
        }
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Label("Remove", systemImage: "trash")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.sortyBordered)
        .controlSize(.small)
        .foregroundStyle(.red)
        .help("Delete this duplicate")
        .accessibilityLabel("Delete \(file.displayName)")
    }

    private var keepButton: some View {
        Button(action: onKeep) {
            Label("Keep This", systemImage: "checkmark.circle")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.sortyBordered)
        .controlSize(.small)
        .help("Keep this file and mark the others for cleanup")
    }

    private var keepBadge: some View {
        Label("Keep", systemImage: "checkmark.circle.fill")
            .font(.caption.bold())
            .foregroundStyle(.green)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.green.opacity(0.1), in: Capsule())
    }

    private func formatPixels(_ pixels: Int) -> String {
        let mp = Double(pixels) / 1_000_000.0
        return String(format: "%.1f MP", mp)
    }

    private func openFile() {
        NSWorkspace.shared.open(fileURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    private func revealInFinder() {
        NSWorkspace.shared.selectFile(
            file.path,
            inFileViewerRootedAtPath: fileURL.deletingLastPathComponent().path)
    }
}

struct UnifiedFileDetailContextMenu: View {
    @SortyHotReload private var hotReload
    let isRecommended: Bool
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onKeep: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Label("Open", systemImage: "arrow.up.right.square")
        }

        Button(action: onReveal) {
            Label("Reveal in Finder", systemImage: "folder")
        }

        Divider()

        if isRecommended {
            Label("Keep This", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else {
            Button(action: onKeep) {
                Label("Keep This", systemImage: "checkmark.circle")
            }

            Button(role: .destructive, action: onDelete) {
                Label("Remove", systemImage: "trash")
            }
        }
    }
}
