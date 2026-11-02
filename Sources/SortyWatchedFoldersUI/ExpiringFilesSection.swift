//
//  ExpiringFilesSection.swift
//  Sorty
//
//  Watched Folders card for Labs Expiring Files.
//

import AppKit
import SwiftUI

/// One collapsed row at the top of Watched Folders while the Labs flag is on and
/// files are waiting. Review expands the checklist inline; nothing shows when empty.
struct ExpiringFilesSection: View {
    @ObservedObject private var expiring = ExpiringFilesManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isReviewing = false
    @State private var deselected: Set<String> = []

    var body: some View {
        content
            .task {
                await expiring.refresh()
            }
            .animation(reduceMotion ? nil : .sortySnappy, value: expiring.candidates.map(\.id))
            .animation(reduceMotion ? nil : .sortySnappy, value: isReviewing)
    }

    private var selectedCandidates: [ExpiringFileCandidate] {
        expiring.candidates.filter { !deselected.contains($0.id) }
    }

    private var selectedSize: Int64 {
        selectedCandidates.reduce(0) { $0 + $1.size }
    }

    private var summary: String {
        let count = expiring.candidates.count
        let size = ByteCountFormatter.string(fromByteCount: expiring.totalSize, countStyle: .file)
        return "\(count) old \(count == 1 ? "file" : "files") to clear · \(size)"
    }

    @ViewBuilder
    private var content: some View {
        if !expiring.candidates.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: SortyLabsFeature.expiringFiles.systemImage)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(summary)
                        .font(.callout.weight(.medium))
                        .contentTransition(.numericText())
                    Spacer()
                    Button(isReviewing ? "Done" : "Review") {
                        HapticFeedbackManager.shared.tap()
                        isReviewing.toggle()
                    }
                    .buttonStyle(.sortyBordered(size: .small))
                    .accessibilityIdentifier("ExpiringFilesReviewButton")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if isReviewing {
                    Divider().padding(.horizontal, 16)

                    VStack(spacing: 2) {
                        ForEach(expiring.candidates) { candidate in
                            ExpiringCandidateRow(
                                candidate: candidate,
                                isSelected: Binding(
                                    get: { !deselected.contains(candidate.id) },
                                    set: { isOn in
                                        HapticFeedbackManager.shared.selection()
                                        if isOn { deselected.remove(candidate.id) } else { deselected.insert(candidate.id) }
                                    }
                                )
                            )
                            .transition(.opacity)
                        }
                    }
                    .padding(8)

                    HStack {
                        Spacer()
                        Button {
                            HapticFeedbackManager.shared.success()
                            let chosen = selectedCandidates
                            Task {
                                await expiring.moveToTrash(chosen)
                                deselected = []
                            }
                        } label: {
                            Text("Move \(selectedCandidates.count) to Trash · \(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))")
                                .contentTransition(.numericText())
                        }
                        .buttonStyle(.sortyProminent(size: .small))
                        .disabled(selectedCandidates.isEmpty)
                        .help("Files go to the Trash, so you can still recover them.")
                        .accessibilityIdentifier("ExpiringFilesTrashButton")
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .systemLiquidGlassBackground(cornerRadius: SortyDesignSystem.Radius.lg, interactive: false)
            .accessibilityIdentifier("ExpiringFilesCard")
        }
    }
}

// MARK: - Rows

/// Loads a QuickLook thumbnail, showing the Finder icon until it arrives.
private struct ExpiringThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                AppKitImageView(image: NSWorkspace.shared.icon(forFile: url.path), size: CGSize(width: 32, height: 32))
            }
        }
        .frame(width: 36, height: 36)
        .task(id: url) {
            image = await FileThumbnailProvider.shared.thumbnail(for: url, size: CGSize(width: 72, height: 72))
        }
        .accessibilityHidden(true)
    }
}

/// Shared row chrome: thumbnail, two lines of text, hover highlight. Trailing
/// actions are inserted on hover rather than faded, so idle rows stay clean.
private struct ExpiringFileRow<Leading: View, Trailing: View>: View {
    let url: URL
    let detail: Text
    /// Keeps actions visible without hover, for the row that owns a keyboard shortcut.
    var alwaysShowsTrailing = false
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            leading
            ExpiringThumbnail(url: url)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isHovered || alwaysShowsTrailing {
                HStack(spacing: 6) { trailing }
                    .transition(.opacity)
            }
        }
        .frame(minHeight: 36)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.sm, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .animation(.sortyQuick, value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

private struct ExpiringCandidateRow: View {
    let candidate: ExpiringFileCandidate
    @Binding var isSelected: Bool

    var body: some View {
        ExpiringFileRow(
            url: candidate.url,
            detail: Text("\(candidate.reason.rawValue) · added \(candidate.dateAdded.formatted(.relative(presentation: .named))) · \(ByteCountFormatter.string(fromByteCount: candidate.size, countStyle: .file))")
        ) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Trash \(candidate.url.lastPathComponent)")
        } trailing: {
            Button("Keep") {
                HapticFeedbackManager.shared.tap()
                ExpiringFilesManager.shared.keep(candidate)
            }
            .buttonStyle(.sortyBordered(size: .small))
            .help("Never suggest this file again")
        }
        .opacity(isSelected ? 1 : 0.6)
        .accessibilityIdentifier("ExpiringCandidateRow")
    }
}
