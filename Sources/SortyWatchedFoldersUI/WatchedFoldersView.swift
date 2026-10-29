//
//  WatchedFoldersView.swift
//  Sorty
//
//  Modern watched folders management with rich folder cards and status indicators
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// One shared clock for visible countdown labels. Lists and cards do not
/// observe it, and it stops when no countdown is visible.
@MainActor
final class WatchedFoldersTicker: ObservableObject {
    static let shared = WatchedFoldersTicker()

    @Published private(set) var now = Date()
    private var tickTask: Task<Void, Never>?
    /// Number of consumers currently demanding ticks. Windows come and go
    /// independently, so `stop()` from one window must not freeze the
    /// countdowns of another: the shared task stops only at zero demand.
    private var demandCount = 0

    private init() {}

    /// Registers one consumer. Every call must be paired with exactly one
    /// `stop()`; each countdown label guards that pairing with its own demand
    /// flag so an unbalanced call cannot freeze other windows.
    func start() {
        demandCount += 1
        guard tickTask == nil else { return }
        now = Date()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.now = Date()
            }
        }
    }

    func stop() {
        demandCount = max(demandCount - 1, 0)
        guard demandCount == 0 else { return }
        tickTask?.cancel()
        tickTask = nil
    }
}

package struct WatchedFoldersView: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var watchedFoldersManager: WatchedFoldersManager
    @EnvironmentObject var appState: AppState
    @State private var showingFolderPicker = false
    @State private var isDropTargeted = false

    package init() {}

    package var body: some View {
        VStack(spacing: 0) {
            if watchedFoldersManager.folders.isEmpty {
                ZStack(alignment: .topLeading) {
                    EmptyWatchedFoldersView(onAddFolder: {
                        HapticFeedbackManager.shared.tap()
                        showingFolderPicker = true
                    }, onAddSuggestedFolder: { url in
                        addWatchedFolder(from: url)
                    })
                    .transition(TransitionStyles.scaleAndFade)
                    .animatedAppearance(delay: 0.08)

                    emptyHeaderView
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .animatedAppearance(delay: 0.03)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Header
                headerView
                    .animatedAppearance(delay: 0.03)

                Divider()

                // Folder Grid/List
                ZStack {
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(
                                    Array(watchedFoldersManager.folders.enumerated()),
                                    id: \.element.id
                                ) { index, folder in
                                    WatchedFolderCard(folder: folder)
                                    .id(folder.id)
                                    .animatedAppearance(
                                        delay: 0.05 + min(Double(index), 8) * 0.04
                                    )
                                }
                            }
                            .padding(20)
                        }
                        .onChange(of: appState.highlightedWatchedFolderID) { _, highlightedID in
                            guard let highlightedID else { return }
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                scrollProxy.scrollTo(highlightedID, anchor: .center)
                            }
                        }
                    }
                    .transition(TransitionStyles.slideFromRight)
                }
                .animation(.pageTransition, value: watchedFoldersManager.folders.isEmpty)
            }
        }
        .emptyStateWorkflowGradient(isVisible: watchedFoldersManager.folders.isEmpty)
        .animation(.pageTransition, value: watchedFoldersManager.folders.isEmpty)
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    addWatchedFolder(from: url)
                }
            case .failure(let error):
                HapticFeedbackManager.shared.error()
                DebugLogger.log("Failed to select folder: \(error)")
            }
        }
        .siriDropZone(isTargeted: $isDropTargeted) { providers in
            handleFolderDrop(providers: providers)
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .task {
            watchedFoldersManager.refreshFolderExistence()
        }
        .navigationTitle("Watched Folders")
    }

    private func addWatchedFolder(from url: URL) {
        HapticFeedbackManager.shared.success()

        // Start accessing the security-scoped resource before creating the bookmark.
        // fileImporter URLs are security-scoped but the resource must be explicitly
        // started to ensure bookmark creation captures the scope.
        let didStart = url.startAccessingSecurityScopedResource()

        let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        if didStart {
            url.stopAccessingSecurityScopedResource()
        }

        if bookmarkData == nil {
            DebugLogger.log("Failed to create security-scoped bookmark for \(url.path)")
        }

        let folder = WatchedFolder(
            path: url.path,
            bookmarkData: bookmarkData
        )
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            watchedFoldersManager.addFolder(folder)
        }
    }

    private func handleFolderDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
            if let data = item as? Data,
                let url = URL(dataRepresentation: data, relativeTo: nil),
                url.hasDirectoryPath
            {
                Task { @MainActor in
                    HapticFeedbackManager.shared.success()
                    let bookmarkData = try? url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    let folder = WatchedFolder(
                        path: url.path,
                        bookmarkData: bookmarkData
                    )
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        watchedFoldersManager.addFolder(folder)
                    }
                }
            }
        }
        return true
    }

    private var headerView: some View {
        HStack {
            HStack(spacing: 12) {
                if appState.navigatedFromSettings {
                    GlassyBackButton {
                        HapticFeedbackManager.shared.tap()
                        appState.navigatedFromSettings = false
                        appState.openSettingsWindow(section: .rules)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Watched Folders")
                        .font(.title2)
                        .fontWeight(.semibold)

                    HStack(spacing: 8) {
                        let activeCount = watchedFoldersManager.activeFolderCount

                        Text("\(activeCount) active")
                            .foregroundStyle(activeCount > 0 ? .green : .secondary)
                            .numericTextTransition(animationValue: activeCount)
                    }
                    .font(.caption)
                }
            }
            .animatedAppearance(delay: 0.05)

            Spacer()

            Button {
                HapticFeedbackManager.shared.tap()
                showingFolderPicker = true
            } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.sortyPrimary)
            .onboardingBeamBorder(variant: .success)
            .accessibilityIdentifier("AddWatchedFolderButton")
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var emptyHeaderView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Watched Folders")
                    .font(.largeTitle.bold())

                Text("Monitor folders and automatically organize new files as they arrive")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

// MARK: - Empty State View

struct EmptyWatchedFoldersView: View {
    @SortyHotReload private var hotReload
    let onAddFolder: () -> Void
    let onAddSuggestedFolder: (URL) -> Void
    @State private var hasAppeared = false
    @State private var beamHasAppeared = false

    var body: some View {
        VStack(spacing: 24) {
            EmptyStateHeroIcon(systemName: "folder.badge.plus")
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.8)
                .animation(
                    .spring(response: 0.5, dampingFraction: 0.7).delay(0.1), value: hasAppeared)

            VStack(spacing: 8) {
                Text("No Watched Folders")
                    .font(.title3)
                    .fontWeight(.semibold)

                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Add folders like")

                        FolderSuggestionPill(
                            name: "Downloads",
                            url: FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent("Downloads"),
                            action: onAddSuggestedFolder
                        )

                        Text("or")

                        FolderSuggestionPill(
                            name: "Desktop",
                            url: FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent("Desktop"),
                            action: onAddSuggestedFolder
                        )
                    }

                    Text("to automatically organize new files as they arrive")
                }
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: hasAppeared)

            Button {
                onAddFolder()
            } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.sortyPrimary)
            .onboardingBeamBorder(variant: .featured, active: beamHasAppeared)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 15)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: hasAppeared)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                hasAppeared = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                beamHasAppeared = true
            }
        }
    }
}

struct FolderSuggestionPill: View {
    @SortyHotReload private var hotReload
    let name: String
    let url: URL
    let action: (URL) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            action(url)
        } label: {
            HStack(spacing: 4) {
                FolderThumbnailView(
                    url: url,
                    size: CGSize(width: 16, height: 16)
                )

                Text(name)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(isHovered ? 0.14 : 0.07))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovered ? .primary : .secondary)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel("Add \(name) to watched folders")
    }
}



// MARK: - Config Section

#Preview {
    WatchedFoldersView()
        .environmentObject(WatchedFoldersManager())
        .environmentObject(FolderOrganizer())
        .frame(width: 600, height: 500)
}
