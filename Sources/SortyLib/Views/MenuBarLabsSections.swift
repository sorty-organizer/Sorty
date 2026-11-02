//
//  MenuBarLabsSections.swift
//  Sorty
//
//  Menu bar section for Labs Expiring Files.
//

import AppKit
import SwiftUI

// MARK: - Expiring Files

/// "Clean Up" in the menu bar: one row summarizing old installers, archives and
/// screenshots, expanding into a checklist. Draws nothing, divider included,
/// while there is nothing to review or report.
struct MenuBarExpiringFilesSection: View {
    @SortyHotReload private var hotReload
    @ObservedObject private var manager = ExpiringFilesManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isReviewing = false
    @State private var isSummaryHovered = false
    @State private var deselected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !manager.candidates.isEmpty {
                Divider()
                summaryButton
                if isReviewing {
                    reviewList
                        .transition(.opacity)
                }
            } else if let result = manager.lastResult {
                Divider()
                Label(result, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .animation(reduceMotion ? nil : .sortySnappy, value: isReviewing)
        .animation(reduceMotion ? nil : .sortySnappy, value: manager.candidates.map(\.id))
        .task { await manager.refresh() }
        .onChange(of: manager.candidates.isEmpty) { _, isEmpty in
            if isEmpty { isReviewing = false }
        }
    }

    private var selected: [ExpiringFileCandidate] {
        manager.candidates.filter { !deselected.contains($0.id) }
    }

    private var selectedSize: Int64 {
        selected.reduce(0) { $0 + $1.size }
    }

    private var summaryButton: some View {
        Button {
            HapticFeedbackManager.shared.selection()
            isReviewing.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: SortyLabsFeature.expiringFiles.systemImage)
                    .foregroundStyle(.orange)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Clean Up")
                        .font(.callout)
                    Text("\(manager.candidates.count) old \(manager.candidates.count == 1 ? "file" : "files") · \(ByteCountFormatter.string(fromByteCount: manager.totalSize, countStyle: .file))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isReviewing ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.sm, style: .continuous)
                    .fill(isSummaryHovered ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.1) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.sm, style: .continuous))
            .animation(.sortyQuick, value: isSummaryHovered)
        }
        .buttonStyle(.plain)
        .onHover { isSummaryHovered = $0 }
        .accessibilityLabel("Clean Up, \(manager.candidates.count) old files")
        .accessibilityHint(isReviewing ? "Hide the list" : "Review files before moving them to the Trash")
        .accessibilityIdentifier("MenuBarExpiringFilesSummary")
    }

    /// Files grouped by kind, so a long list reads as a few rows.
    private var groups: [MenuBarExpiringGroup] {
        let grouped = Dictionary(grouping: manager.candidates, by: MenuBarExpiringGroup.Kind.init)
        return MenuBarExpiringGroup.Kind.allCases.compactMap { kind in
            grouped[kind].map { MenuBarExpiringGroup(kind: kind, files: $0) }
        }
    }

    private func selection(for candidate: ExpiringFileCandidate) -> Binding<Bool> {
        Binding(
            get: { !deselected.contains(candidate.id) },
            set: { isOn in
                if isOn { deselected.remove(candidate.id) } else { deselected.insert(candidate.id) }
            }
        )
    }

    private var reviewList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        MenuBarExpiringGroupRow(
                            group: group,
                            selection: selection(for:),
                            onKeep: { candidate in
                                HapticFeedbackManager.shared.tap()
                                manager.keep(candidate)
                            }
                        )
                        .transition(.opacity)
                    }
                }
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                HapticFeedbackManager.shared.success()
                let chosen = selected
                Task {
                    await manager.moveToTrash(chosen)
                    deselected = []
                }
            } label: {
                Text("Move \(selected.count) to Trash · \(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))")
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.sortyProminent(size: .small))
            .disabled(selected.isEmpty)
            .help("Files go to the Trash, so you can still recover them.")
            .accessibilityIdentifier("MenuBarExpiringFilesTrash")
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
    }
}

/// Candidates of one kind, shown as a single row in the menu bar.
private struct MenuBarExpiringGroup: Identifiable {
    enum Kind: CaseIterable {
        case screenshots, installers, archives, marked

        init(_ candidate: ExpiringFileCandidate) {
            switch candidate.reason {
            case .screenshot: self = .screenshots
            case .installer, .installed: self = .installers
            case .archive, .extracted: self = .archives
            case .markedByYou: self = .marked
            }
        }

        var title: String {
            switch self {
            case .screenshots: "Screenshots"
            case .installers: "Installers"
            case .archives: "Archives"
            case .marked: "Marked to Expire"
            }
        }
    }

    let kind: Kind
    let files: [ExpiringFileCandidate]
    var id: Kind { kind }
    var size: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// A kind of file with a stacked preview, a checkbox for the whole group, and a
/// disclosure for picking individual files.
private struct MenuBarExpiringGroupRow: View {
    let group: MenuBarExpiringGroup
    let selection: (ExpiringFileCandidate) -> Binding<Bool>
    let onKeep: (ExpiringFileCandidate) -> Void
    @State private var isExpanded = false
    @State private var isHovered = false

    private var detail: String {
        let size = ByteCountFormatter.string(fromByteCount: group.size, countStyle: .file)
        if group.files.count == 1, let file = group.files.first {
            return "\(file.url.lastPathComponent) · \(size)"
        }
        return "\(group.files.count) files · \(size)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Toggle(sources: group.files.map(selection), isOn: \.self) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("Trash all \(group.kind.title)")

                MenuBarThumbnailStack(urls: group.files.prefix(3).map(\.url))

                VStack(alignment: .leading, spacing: 1) {
                    Text(group.kind.title)
                        .font(.callout)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.sm, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                HapticFeedbackManager.shared.selection()
                isExpanded.toggle()
            }
            .onHover { isHovered = $0 }
            .animation(.sortyQuick, value: isHovered)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isExpanded ? "Hide files" : "Show files")

            if isExpanded {
                ForEach(group.files) { candidate in
                    MenuBarExpiringRow(candidate: candidate, isSelected: selection(candidate)) {
                        onKeep(candidate)
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(.sortySnappy, value: isExpanded)
        .accessibilityIdentifier("MenuBarExpiringGroup")
    }
}

/// Up to three thumbnails fanned out, like a small pile of the files.
private struct MenuBarThumbnailStack: View {
    let urls: [URL]

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(urls.enumerated().reversed()), id: \.element) { index, url in
                MenuBarThumbnail(url: url, side: 24)
                    .offset(x: CGFloat(index) * 5)
            }
        }
        .frame(width: 34, height: 26, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// QuickLook thumbnail with the Finder icon as a placeholder.
private struct MenuBarThumbnail: View {
    let url: URL
    let side: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.08)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .task(id: url) {
            image = await FileThumbnailProvider.shared.thumbnail(for: url, size: CGSize(width: side * 2, height: side * 2))
        }
    }
}

/// One file inside an expanded group. Clicking the row toggles it; Keep
/// appears on hover so idle rows stay quiet.
private struct MenuBarExpiringRow: View {
    let candidate: ExpiringFileCandidate
    @Binding var isSelected: Bool
    let onKeep: () -> Void
    @State private var isHovered = false

    private var detail: String {
        let age = candidate.dateAdded.formatted(.relative(presentation: .named))
        let size = ByteCountFormatter.string(fromByteCount: candidate.size, countStyle: .file)
        return candidate.isFinished
            ? "\(candidate.reason.rawValue) · \(size)"
            : "\(age) · \(size)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { newValue in
                    HapticFeedbackManager.shared.selection()
                    isSelected = newValue
                }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel("Trash \(candidate.url.lastPathComponent)")

            MenuBarThumbnail(url: candidate.url, side: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(candidate.url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isHovered {
                Button("Keep", action: onKeep)
                    .buttonStyle(.sortyBordered(size: .small))
                    .help("Stop suggesting this file")
                    .transition(.opacity)
            }
        }
        .padding(.leading, 32)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.sm, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .opacity(isSelected ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture {
            HapticFeedbackManager.shared.selection()
            isSelected.toggle()
        }
        .animation(.sortyQuick, value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([candidate.url])
            }
            Button("Keep", action: onKeep)
        }
        .accessibilityIdentifier("MenuBarExpiringFilesRow")
    }
}
