//
//  InboxView.swift
//  Sorty
//
//  Main-window page for the Labs Downloads Inbox and Expiring Files.
//

import AppKit
import SwiftUI

/// Shows whichever of Downloads Inbox and Expiring Files is on. The sidebar
/// lists this page only while at least one of them is enabled.
struct InboxView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var inbox = DownloadsInboxManager.shared
    @ObservedObject private var expiring = ExpiringFilesManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SortyLabsFeature.downloadsInbox.defaultsKey) private var isDownloadsInboxEnabled = false
    @AppStorage(SortyLabsFeature.expiringFiles.defaultsKey) private var isExpiringFilesEnabled = false
    @State private var deselected: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
                .animatedAppearance(delay: 0.03)

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    if isDownloadsInboxEnabled {
                        downloadsCard
                            .animatedAppearance(delay: 0.05)
                    }
                    if isExpiringFilesEnabled {
                        expiringCard
                            .animatedAppearance(delay: 0.08)
                    }
                }
                .padding(24)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            inbox.scheduleRefresh(delay: .zero)
            await expiring.refresh()
        }
        .animation(reduceMotion ? nil : .sortySnappy, value: inbox.items.map(\.id))
        .animation(reduceMotion ? nil : .sortySnappy, value: expiring.candidates.map(\.id))
        .animation(reduceMotion ? nil : .sortyFade, value: inbox.lastMove)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
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
        var parts: [String] = []
        if isDownloadsInboxEnabled {
            parts.append("\(inbox.items.count) new \(inbox.items.count == 1 ? "download" : "downloads")")
        }
        if isExpiringFilesEnabled {
            parts.append("\(expiring.candidates.count) old \(expiring.candidates.count == 1 ? "file" : "files")")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Downloads Inbox

    private var downloadsCard: some View {
        SettingsCard(
            title: SortyLabsFeature.downloadsInbox.title,
            icon: SortyLabsFeature.downloadsInbox.systemImage,
            color: .blue,
            count: inbox.items.isEmpty ? nil : inbox.items.count
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if let move = inbox.lastMove {
                    InboxBanner(
                        systemImage: "checkmark.circle.fill",
                        tint: SortyDesignSystem.Colors.success,
                        text: "Moved \(move.movedURL.lastPathComponent) to \(move.movedURL.deletingLastPathComponent().lastPathComponent)"
                    ) {
                        Button("Undo") {
                            HapticFeedbackManager.shared.tap()
                            Task { await inbox.undoLastMove() }
                        }
                        .buttonStyle(.sortyBordered(size: .small))
                        .keyboardShortcut("z", modifiers: .command)
                        .accessibilityIdentifier("InboxUndoButton")
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let error = inbox.lastError {
                    InboxBanner(
                        systemImage: "exclamationmark.triangle.fill",
                        tint: SortyDesignSystem.Colors.error,
                        text: error
                    ) { EmptyView() }
                }

                if inbox.items.isEmpty {
                    SortyEmptyState(
                        "No new downloads",
                        systemImage: "tray",
                        message: "Files you download from now on show up here with a suggested folder.",
                        size: .inline
                    )
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(downloadGroups, id: \.destination) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                InboxGroupHeader(suggestion: group.items[0].suggestion, count: group.items.count)
                                ForEach(group.items) { item in
                                    InboxDownloadRow(item: item, isFirst: item.id == inbox.items.first?.id)
                                        .transition(.opacity)
                                }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("InboxDownloadsCard")
    }

    /// Groups downloads by suggested folder, keeping the order each folder first appears in.
    private var downloadGroups: [(destination: URL, items: [DownloadsInboxItem])] {
        var order: [URL] = []
        var byDestination: [URL: [DownloadsInboxItem]] = [:]
        for item in inbox.items {
            let key = item.suggestion.destination
            if byDestination[key] == nil { order.append(key) }
            byDestination[key, default: []].append(item)
        }
        return order.map { ($0, byDestination[$0] ?? []) }
    }

    // MARK: Expiring Files

    private var selectedCandidates: [ExpiringFileCandidate] {
        expiring.candidates.filter { !deselected.contains($0.id) }
    }

    private var expiringCard: some View {
        SettingsCard(
            title: SortyLabsFeature.expiringFiles.title,
            icon: SortyLabsFeature.expiringFiles.systemImage,
            color: .orange,
            count: expiring.candidates.isEmpty ? nil : expiring.candidates.count
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if expiring.candidates.isEmpty {
                    SortyEmptyState(
                        expiring.lastResult.map { LocalizedStringKey($0) } ?? "Nothing has expired",
                        systemImage: "checkmark.circle",
                        message: "Installers, archives and screenshots older than \(expiring.ageInDays) days show up here for review.",
                        size: .inline
                    )
                } else {
                    Text("\(ByteCountFormatter.string(fromByteCount: expiring.totalSize, countStyle: .file)) in files older than \(expiring.ageInDays) days. Uncheck anything you want to keep for now.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

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

                    HStack {
                        Text("Files go to the Trash, so you can still recover them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Move \(selectedCandidates.count) to Trash") {
                            HapticFeedbackManager.shared.success()
                            let chosen = selectedCandidates
                            Task {
                                await expiring.moveToTrash(chosen)
                                deselected = []
                            }
                        }
                        .buttonStyle(.sortyProminent(size: .small))
                        .disabled(selectedCandidates.isEmpty)
                        .accessibilityIdentifier("InboxExpiringTrashButton")
                    }
                    .padding(.top, 4)
                }
            }
        }
        .accessibilityIdentifier("InboxExpiringCard")
    }
}

// MARK: - Rows

/// A one-line notice above a list, with an optional trailing action.
private struct InboxBanner<Action: View>: View {
    let systemImage: String
    let tint: Color
    let text: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.sm, style: .continuous)
                .fill(tint.opacity(0.1))
        )
    }
}

/// Shared row chrome: file icon, two lines of text, hover highlight.
private struct InboxFileRow<Leading: View, Trailing: View>: View {
    let url: URL
    let detail: Text
    /// Keeps actions visible without hover, for the row that owns a keyboard shortcut.
    var alwaysShowsTrailing = false
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            leading
            AppKitImageView(image: NSWorkspace.shared.icon(forFile: url.path), size: CGSize(width: 24, height: 24))
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { trailing }
                .opacity(isHovered || alwaysShowsTrailing ? 1 : 0)
                .allowsHitTesting(isHovered || alwaysShowsTrailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.sm, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .animation(.sortyQuick, value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

private struct InboxDownloadRow: View {
    let item: DownloadsInboxItem
    let isFirst: Bool
    @ObservedObject private var inbox = DownloadsInboxManager.shared

    var body: some View {
        InboxFileRow(
            url: item.url,
            detail: Text("\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) · \(item.dateAdded.formatted(.relative(presentation: .named)))"),
            alwaysShowsTrailing: isFirst
        ) {
            EmptyView()
        } trailing: {
            Menu {
                Button("Choose Folder…") { chooseFolder() }
                Button("Trash in 7 Days") {
                    ExpiringFilesManager.shared.markToExpire(item.url, afterDays: 7)
                    inbox.dismiss(item)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                Divider()
                Button("Leave in Downloads") { inbox.dismiss(item) }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More options for \(item.url.lastPathComponent)")

            moveButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("InboxDownloadRow")
    }

    @ViewBuilder
    private var moveButton: some View {
        let button = Button {
            HapticFeedbackManager.shared.success()
            Task { await inbox.accept(item) }
        } label: {
            Text("Move to \(item.suggestion.displayName)")
        }
        .buttonStyle(.sortyBordered(size: .small))
        .help(isFirst ? "Move to \(item.suggestion.displayName) (Return)" : "Move to \(item.suggestion.displayName)")
        .accessibilityLabel("Move \(item.url.lastPathComponent) to \(item.suggestion.displayName)")

        if isFirst {
            button.keyboardShortcut(.return, modifiers: [])
        } else {
            button
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Sorty will remember this folder for .\(item.url.pathExtension) files."
        panel.directoryURL = item.suggestion.destination.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        HapticFeedbackManager.shared.success()
        Task { await inbox.accept(item, to: url) }
    }
}

/// Names the folder a group of downloads will move to, and why Sorty picked it.
private struct InboxGroupHeader: View {
    let suggestion: DownloadsInboxSuggestion
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(suggestion.displayName)
                .fontWeight(.semibold)
            Text("\(count)")
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .help(help)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch suggestion.source {
        case .routingRule: "arrow.triangle.branch"
        case .remembered: "clock.arrow.circlepath"
        case .fileKind: "folder"
        }
    }

    private var help: String {
        switch suggestion.source {
        case .routingRule: "One of your routing rules matched these files."
        case .remembered: "You filed this kind of file here before."
        case .fileKind: "A folder for this kind of file inside Downloads."
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
        .accessibilityIdentifier("InboxExpiringRow")
    }
}
