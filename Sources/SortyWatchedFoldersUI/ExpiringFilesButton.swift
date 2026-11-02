//
//  ExpiringFilesButton.swift
//  Sorty
//
//  Watched Folders Clean Up popover for Labs Expiring Files.
//

import AppKit
import SwiftUI

/// Header button in Watched Folders while the Labs flag is on. Opens a popover
/// for clearing old installers, archives and screenshots by simple rules, no AI.
struct ExpiringFilesButton: View {
    @ObservedObject private var expiring = ExpiringFilesManager.shared
    @State private var isPresented = false

    var body: some View {
        Button {
            HapticFeedbackManager.shared.tap()
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: SortyLabsFeature.expiringFiles.systemImage)
                Text("Clean Up")
                if !expiring.candidates.isEmpty {
                    Text("\(expiring.candidates.count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.orange))
                        .contentTransition(.numericText())
                }
            }
        }
        .buttonStyle(.sortyBordered)
        .help("Clear old installers, archives and screenshots, found by file type and age")
        .accessibilityLabel(expiring.candidates.isEmpty ? "Clean Up" : "Clean Up, \(expiring.candidates.count) files")
        .accessibilityIdentifier("ExpiringFilesButton")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ExpiringFilesPanel()
                .systemLiquidGlassPopover(cornerRadius: 12)
        }
        .task {
            await expiring.refresh()
        }
    }
}

/// Popover contents: rule-based review list with a single Trash action.
private struct ExpiringFilesPanel: View {
    @ObservedObject private var expiring = ExpiringFilesManager.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deselected: Set<String> = []

    private var selectedCandidates: [ExpiringFileCandidate] {
        expiring.candidates.filter { !deselected.contains($0.id) }
    }

    private var selectedSize: Int64 {
        selectedCandidates.reduce(0) { $0 + $1.size }
    }

    private var ageDescription: String {
        expiring.ageInDays == 1 ? "1 day" : "\(expiring.ageInDays) days"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean Up")
                        .font(.headline)
                    Text("Installers, archives and screenshots older than \(ageDescription). Your AI provider isn't used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    HapticFeedbackManager.shared.tap()
                    appState.openSettingsWindow(section: .experimental)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Clean Up settings")
                .accessibilityLabel("Clean Up settings")
                .accessibilityIdentifier("ExpiringFilesSettingsButton")
            }
            .padding(16)

            Divider()

            if expiring.candidates.isEmpty {
                Label(expiring.lastResult ?? "Nothing to clear right now.", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ScrollView {
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
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)

                Divider()

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
                .padding(12)
            }
        }
        .frame(width: 420)
        .animation(reduceMotion ? nil : .sortySnappy, value: expiring.candidates.map(\.id))
        .accessibilityIdentifier("ExpiringFilesPanel")
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
