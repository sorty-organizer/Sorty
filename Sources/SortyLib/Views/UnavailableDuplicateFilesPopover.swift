import AppKit
import Foundation
import SwiftUI
import Beam

struct UnavailableDuplicateFilesPopover: View {
    @SortyHotReload private var hotReload
    let files: [UnavailableDuplicateFile]
    let onScanAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Unavailable Files")
                    .font(.headline)
                Text("Reconnect external drives or download cloud files, then scan again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(files) { file in
                        unavailableFileRow(file)
                        if file.id != files.last?.id {
                            Divider()
                                .padding(.leading, 44)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)

            Divider()

            HStack {
                Spacer()
                Button("Scan Again", action: onScanAgain)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.sortyPrimary(size: .small))
            }
            .padding(12)
        }
        .frame(width: 390)
    }

    private func unavailableFileRow(_ file: UnavailableDuplicateFile) -> some View {
        HStack(spacing: 10) {
            UnavailableFileIcon(fileURL: file.url)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(file.reason.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Menu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                    HapticFeedbackManager.shared.success()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Options for \(file.url.lastPathComponent)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }
}

struct UnavailableFileIcon: View {
    let fileURL: URL
    @State private var icon: NSImage

    init(fileURL: URL) {
        self.fileURL = fileURL
        _icon = State(
            initialValue: AnalysisIconProvider.icon(
                forFileExtension: fileURL.pathExtension
            )
        )
    }

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .scaledToFit()
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
            .task(id: fileURL.path) {
                let resolvedIcon = await FileThumbnailProvider.shared.thumbnail(
                    for: fileURL,
                    size: CGSize(width: 24, height: 24)
                )
                guard !Task.isCancelled else { return }
                icon = resolvedIcon
            }
    }
}

struct DuplicatesNerdStatsStrip: View {
    @SortyHotReload private var hotReload
    @ObservedObject var manager: DuplicateDetectionManager

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                stat("Scanned", value: "\(manager.scannedFileCount)")
                stat("Candidates", value: "\(manager.hashCandidateCount)")
            }
            HStack(spacing: 8) {
                stat("Sampled", value: "\(manager.sampledFileCount)")
                stat("Full hashes", value: "\(manager.hashedFileCount)")
            }
            HStack(spacing: 8) {
                stat("Cache hits", value: "\(manager.hashCacheHitCount)")
                stat("Similar analyzed", value: "\(manager.semanticAnalyzedFileCount)")
            }
            if manager.unreadableFileCount > 0 {
                HStack(spacing: 8) {
                    stat("Unreadable", value: "\(manager.unreadableFileCount)")
                    stat("Duration", value: formattedDuration)
                }
            } else {
                stat("Duration", value: formattedDuration)
            }
        }
        .padding(10)
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Duplicate scan stats. \(manager.scannedFileCount) files scanned. \(manager.hashCandidateCount) hash candidates. \(manager.sampledFileCount) files sampled. \(manager.hashedFileCount) files fully hashed. \(manager.hashCacheHitCount) cache hits. \(manager.semanticAnalyzedFileCount) files analyzed for similarity. \(manager.semanticSkippedFileCount) files skipped for similarity. \(manager.unreadableFileCount) unreadable files. Duration \(formattedDuration)."
        )
    }

    private func stat(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .numericTextTransition(animationValue: value)
        }
        .font(.caption2)
    }

    private var formattedDuration: String {
        guard manager.scanDuration > 0 else { return "—" }
        return String(format: "%.2fs", manager.scanDuration)
    }
}
