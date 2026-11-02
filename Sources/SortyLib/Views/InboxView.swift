//
//  InboxView.swift
//  Sorty
//
//  Main-window page for Labs Expiring Files.
//

import AppKit
import SwiftUI

/// Reviews expiring files while the feature is enabled.
struct InboxView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var expiring = ExpiringFilesManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deselected: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
                .animatedAppearance(delay: 0.03)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    expiringContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .animatedAppearance(delay: 0.05)
            }
        }
        .task {
            await expiring.refresh()
        }
        .animation(reduceMotion ? nil : .sortySnappy, value: expiring.candidates.map(\.id))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Inbox")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Button {
                HapticFeedbackManager.shared.tap()
                appState.openSettingsWindow(section: .experimental)
            } label: {
                Label("Labs Settings", systemImage: "flask")
            }
            .buttonStyle(.sortyBordered(size: .small))
            .accessibilityIdentifier("InboxLabsSettingsButton")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var headerSubtitle: String {
        let count = expiring.candidates.count
        guard count > 0 else { return "Old installers, archives and screenshots appear here" }
        return "\(count) old \(count == 1 ? "file" : "files") · \(ByteCountFormatter.string(fromByteCount: expiring.totalSize, countStyle: .file))"
    }

    // MARK: Expiring Files

    private var selectedCandidates: [ExpiringFileCandidate] {
        expiring.candidates.filter { !deselected.contains($0.id) }
    }

    private var selectedSize: Int64 {
        selectedCandidates.reduce(0) { $0 + $1.size }
    }

    @ViewBuilder
    private var expiringContent: some View {
        if expiring.candidates.isEmpty {
            InboxEmptyCard(
                title: expiring.lastResult ?? "Nothing has expired",
                systemImage: "checkmark.circle",
                message: "Installers, archives and screenshots older than \(expiring.ageInDays) days show up here for review."
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    InboxIconTile(systemImage: SortyLabsFeature.expiringFiles.systemImage, tint: .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Older than \(expiring.ageInDays) days")
                            .font(.headline)
                        Text("Uncheck anything you want to keep for now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Select All", isOn: Binding(
                        get: { deselected.isEmpty },
                        set: { isOn in
                            HapticFeedbackManager.shared.selection()
                            deselected = isOn ? [] : Set(expiring.candidates.map(\.id))
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .accessibilityIdentifier("InboxExpiringSelectAll")
                }
                .padding(16)

                Divider().padding(.horizontal, 16)

                VStack(spacing: 2) {
                    ForEach(expiring.candidates) { candidate in
                        InboxExpiringRow(
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

                Divider().padding(.horizontal, 16)

                HStack {
                    Label("Files go to the Trash, so you can still recover them.", systemImage: "arrow.uturn.backward.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        HapticFeedbackManager.shared.success()
                        let chosen = selectedCandidates
                        Task {
                            await expiring.moveToTrash(chosen)
                            deselected = []
                        }
                    } label: {
                        Text("Trash \(selectedCandidates.count) · \(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))")
                            .contentTransition(.numericText())
                    }
                    .buttonStyle(.sortyProminent(size: .small))
                    .disabled(selectedCandidates.isEmpty)
                    .accessibilityIdentifier("InboxExpiringTrashButton")
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .systemLiquidGlassBackground(cornerRadius: SortyDesignSystem.Radius.lg, interactive: false)
            .accessibilityIdentifier("InboxExpiringCard")
        }
    }
}

// MARK: - Cards

private struct InboxEmptyCard: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        SortyEmptyState(
            LocalizedStringKey(title),
            systemImage: systemImage,
            message: LocalizedStringKey(message),
            size: .inline
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .systemLiquidGlassBackground(cornerRadius: SortyDesignSystem.Radius.lg, interactive: false)
    }
}

/// A tinted rounded square holding a symbol, used to lead card headers.
private struct InboxIconTile: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.sm, style: .continuous)
                    .fill(tint.opacity(0.14))
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Rows

/// Loads a QuickLook thumbnail, showing the Finder icon until it arrives.
private struct InboxThumbnail: View {
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
private struct InboxFileRow<Leading: View, Trailing: View>: View {
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
            InboxThumbnail(url: url)
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

private struct InboxExpiringRow: View {
    let candidate: ExpiringFileCandidate
    @Binding var isSelected: Bool

    var body: some View {
        InboxFileRow(
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
        .accessibilityIdentifier("InboxExpiringRow")
    }
}
