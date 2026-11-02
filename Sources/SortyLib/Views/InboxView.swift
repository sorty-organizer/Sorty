//
//  InboxView.swift
//  Sorty
//
//  Main-window page for the Labs Downloads Inbox and Expiring Files.
//

import AppKit
import SwiftUI

/// Shows whichever of Downloads Inbox and Expiring Files is on. The sidebar
/// lists this page only while at least one of them is enabled. With both on,
/// a segmented control switches between them.
struct InboxView: View {
    enum Tab: String {
        case downloads
        case expiring
    }

    @SortyHotReload private var hotReload
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var inbox = DownloadsInboxManager.shared
    @ObservedObject private var expiring = ExpiringFilesManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SortyLabsFeature.downloadsInbox.defaultsKey) private var isDownloadsInboxEnabled = false
    @AppStorage(SortyLabsFeature.expiringFiles.defaultsKey) private var isExpiringFilesEnabled = false
    @AppStorage("inbox.selectedTab") private var storedTab: Tab = .downloads
    @State private var deselected: Set<String> = []

    /// The tab actually shown, falling back when the stored one is turned off.
    private var tab: Tab {
        switch (isDownloadsInboxEnabled, isExpiringFilesEnabled) {
        case (true, false): .downloads
        case (false, true): .expiring
        default: storedTab
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .animatedAppearance(delay: 0.03)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .downloads: downloadsContent
                    case .expiring: expiringContent
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animatedAppearance(delay: 0.05)
            }
        }
        .task {
            inbox.scheduleRefresh(delay: .zero)
            await expiring.refresh()
        }
        .animation(reduceMotion ? nil : .sortySnappy, value: inbox.items.map(\.id))
        .animation(reduceMotion ? nil : .sortySnappy, value: expiring.candidates.map(\.id))
        .animation(reduceMotion ? nil : .sortyFade, value: inbox.lastMoves)
        .animation(reduceMotion ? nil : .sortyFade, value: tab)
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
            if isDownloadsInboxEnabled && isExpiringFilesEnabled {
                Picker("Section", selection: Binding(get: { tab }, set: { newValue in
                    HapticFeedbackManager.shared.selection()
                    storedTab = newValue
                })) {
                    Text("Downloads \(inbox.items.count)").tag(Tab.downloads)
                    Text("Expiring \(expiring.candidates.count)").tag(Tab.expiring)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("InboxTabPicker")
            }
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
        switch tab {
        case .downloads:
            let count = inbox.items.count
            guard count > 0 else { return "New downloads appear here with a suggested folder" }
            let folders = downloadGroups.count
            return "\(count) new \(count == 1 ? "download" : "downloads") for \(folders) \(folders == 1 ? "folder" : "folders")"
        case .expiring:
            let count = expiring.candidates.count
            guard count > 0 else { return "Old installers, archives and screenshots appear here" }
            return "\(count) old \(count == 1 ? "file" : "files") · \(ByteCountFormatter.string(fromByteCount: expiring.totalSize, countStyle: .file))"
        }
    }

    // MARK: Downloads Inbox

    @ViewBuilder
    private var downloadsContent: some View {
        if let move = inbox.lastMove {
            InboxBanner(
                systemImage: "checkmark.circle.fill",
                tint: SortyDesignSystem.Colors.success,
                text: movedText(for: move)
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
            InboxEmptyCard(
                title: "You're all caught up",
                systemImage: "tray",
                message: "Files you download from now on show up here with a suggested folder."
            )
        } else {
            ForEach(downloadGroups, id: \.destination) { group in
                InboxDestinationCard(
                    suggestion: group.items[0].suggestion,
                    items: group.items,
                    firstItemID: inbox.items.first?.id
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }

    private func movedText(for move: DownloadsInboxMove) -> String {
        let folder = move.movedURL.deletingLastPathComponent().lastPathComponent
        let count = inbox.lastMoves.count
        return count == 1
            ? "Moved \(move.movedURL.lastPathComponent) to \(folder)"
            : "Moved \(count) files to \(folder)"
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

/// One destination folder with the downloads headed there and a Move All action.
private struct InboxDestinationCard: View {
    let suggestion: DownloadsInboxSuggestion
    let items: [DownloadsInboxItem]
    let firstItemID: String?
    @ObservedObject private var inbox = DownloadsInboxManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                InboxIconTile(systemImage: "folder.fill", tint: .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(suggestion.displayName)
                            .font(.headline)
                        Text("\(items.count)")
                            .sortyBadge()
                    }
                    Label(reason, systemImage: reasonIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(suggestion.destination.path)
                }
                Spacer()
                if items.count > 1 {
                    Button {
                        HapticFeedbackManager.shared.success()
                        let batch = items
                        Task { await inbox.acceptAll(batch) }
                    } label: {
                        Label("Move All", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(.sortyBordered(size: .small))
                    .help("Move all \(items.count) files to \(suggestion.displayName)")
                    .accessibilityIdentifier("InboxMoveAllButton")
                }
            }
            .padding(16)

            Divider().padding(.horizontal, 16)

            VStack(spacing: 2) {
                ForEach(items) { item in
                    InboxDownloadRow(item: item, isFirst: item.id == firstItemID)
                        .transition(.opacity)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .systemLiquidGlassBackground(cornerRadius: SortyDesignSystem.Radius.lg, interactive: false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("InboxDestinationCard")
    }

    private var reason: String {
        switch suggestion.source {
        case .routingRule: "Matches a routing rule"
        case .remembered: "Where you filed these before"
        case .fileKind: "Sorted by file kind"
        }
    }

    private var reasonIcon: String {
        switch suggestion.source {
        case .routingRule: "arrow.triangle.branch"
        case .remembered: "clock.arrow.circlepath"
        case .fileKind: "doc.on.doc"
        }
    }
}

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

/// A one-line notice above the cards, with an optional trailing action.
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.md, style: .continuous)
                .fill(tint.opacity(0.1))
        )
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
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More options")
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
            Text("Move")
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
