//
//  MenuBarLabsSections.swift
//  Sorty
//
//  Menu bar sections for Labs: Downloads Inbox and Expiring Files.
//

import AppKit
import SwiftUI

// MARK: - Downloads Inbox

/// New downloads with a suggested folder each. Return files the top one.
struct MenuBarDownloadsInboxSection: View {
    @SortyHotReload private var hotReload
    @ObservedObject private var inbox = DownloadsInboxManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let visibleItemCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads Inbox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !inbox.items.isEmpty {
                    Text("\(inbox.items.count)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .numericTextTransition(animationValue: inbox.items.count)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            if let move = inbox.lastMove {
                undoRow(move)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let error = inbox.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }

            if inbox.items.isEmpty {
                Text("New downloads will show up here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(inbox.items.prefix(Self.visibleItemCount).enumerated()), id: \.element.id) { index, item in
                    MenuBarInboxRow(item: item, isFirst: index == 0)
                        .transition(.opacity)
                }
                if inbox.items.count > Self.visibleItemCount {
                    Text("+ \(inbox.items.count - Self.visibleItemCount) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: inbox.items.map(\.id))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: inbox.lastMove)
        .task { inbox.scheduleRefresh(delay: .zero) }
    }

    private func undoRow(_ move: DownloadsInboxMove) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
            Text("Moved to \(move.movedURL.deletingLastPathComponent().lastPathComponent)")
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Button("Undo") {
                HapticFeedbackManager.shared.tap()
                Task { await inbox.undoLastMove() }
            }
            .buttonStyle(.link)
            .font(.caption.weight(.semibold))
            .keyboardShortcut("z", modifiers: .command)
            .accessibilityIdentifier("MenuBarInboxUndo")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

private struct MenuBarInboxRow: View {
    @SortyHotReload private var hotReload
    let item: DownloadsInboxItem
    let isFirst: Bool

    @ObservedObject private var inbox = DownloadsInboxManager.shared
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            AppKitImageView(image: NSWorkspace.shared.icon(forFile: item.url.path), size: CGSize(width: 18, height: 18))
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label(item.suggestion.displayName, systemImage: suggestionIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(suggestionHelp)
            }

            Spacer(minLength: 4)

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
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovered ? 1 : 0.4)
            .accessibilityLabel("More options for \(item.url.lastPathComponent)")

            acceptButton
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.1) : Color.clear)
        )
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MenuBarInboxRow")
    }

    @ViewBuilder
    private var acceptButton: some View {
        let button = Button {
            HapticFeedbackManager.shared.success()
            Task { await inbox.accept(item) }
        } label: {
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
        }
        .buttonStyle(.plain)
        .help(isFirst ? "Move to \(item.suggestion.displayName) (Return)" : "Move to \(item.suggestion.displayName)")
        .accessibilityLabel("Move \(item.url.lastPathComponent) to \(item.suggestion.displayName)")

        if isFirst {
            button.keyboardShortcut(.return, modifiers: [])
        } else {
            button
        }
    }

    private var suggestionIcon: String {
        switch item.suggestion.source {
        case .routingRule: "arrow.triangle.branch"
        case .remembered: "clock.arrow.circlepath"
        case .fileKind: "folder"
        }
    }

    private var suggestionHelp: String {
        switch item.suggestion.source {
        case .routingRule: "One of your routing rules matched this file."
        case .remembered: "You filed this kind of file here before."
        case .fileKind: "A folder for this kind of file inside Downloads."
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
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        HapticFeedbackManager.shared.success()
        Task { await inbox.accept(item, to: url) }
    }
}

// MARK: - Expiring Files

/// Old installers, archives and screenshots waiting for review before the Trash.
struct MenuBarExpiringFilesSection: View {
    @SortyHotReload private var hotReload
    @ObservedObject private var manager = ExpiringFilesManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isReviewing = false
    @State private var deselected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if manager.candidates.isEmpty {
                if let result = manager.lastResult {
                    Label(result, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                } else {
                    Text("Nothing has expired.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            } else {
                summaryButton
                if isReviewing {
                    reviewList
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: isReviewing)
        .task { await manager.refresh() }
    }

    private var selected: [ExpiringFileCandidate] {
        manager.candidates.filter { !deselected.contains($0.id) }
    }

    private var summaryButton: some View {
        Button {
            HapticFeedbackManager.shared.selection()
            isReviewing.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Clean Up \(manager.candidates.count) Old \(manager.candidates.count == 1 ? "File" : "Files")")
                        .font(.callout)
                    Text("\(ByteCountFormatter.string(fromByteCount: manager.totalSize, countStyle: .file)) · older than \(manager.ageInDays) days")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isReviewing ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MenuBarExpiringFilesSummary")
    }

    private var reviewList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(manager.candidates) { candidate in
                        candidateRow(candidate)
                    }
                }
            }
            .frame(maxHeight: 180)

            HStack {
                Button("Move \(selected.count) to Trash") {
                    HapticFeedbackManager.shared.success()
                    let chosen = selected
                    Task {
                        await manager.moveToTrash(chosen)
                        deselected = []
                        isReviewing = false
                    }
                }
                .buttonStyle(.sortyPrimary(size: .small))
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("MenuBarExpiringFilesTrash")

                Spacer()

                Text("Recoverable from the Trash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func candidateRow(_ candidate: ExpiringFileCandidate) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { !deselected.contains(candidate.id) },
                set: { isOn in
                    HapticFeedbackManager.shared.selection()
                    if isOn { deselected.remove(candidate.id) } else { deselected.insert(candidate.id) }
                }
            )) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(candidate.url.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(candidate.reason.rawValue) · \(candidate.dateAdded.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: 4)

            Button("Keep") {
                HapticFeedbackManager.shared.tap()
                manager.keep(candidate)
            }
            .buttonStyle(.link)
            .font(.caption2)
            .help("Never suggest this file again")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}
