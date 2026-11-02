//
//  InboxView.swift
//  Sorty
//
//  Main-window page for the Labs Downloads Inbox and Expiring Files.
//

import SwiftUI

/// Shows whichever of Downloads Inbox and Expiring Files is on. The sidebar
/// lists this page only while at least one of them is enabled.
struct InboxView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var inbox = DownloadsInboxManager.shared
    @ObservedObject private var expiring = ExpiringFilesManager.shared
    @AppStorage(SortyLabsFeature.downloadsInbox.defaultsKey) private var isDownloadsInboxEnabled = false
    @AppStorage(SortyLabsFeature.expiringFiles.defaultsKey) private var isExpiringFilesEnabled = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .animatedAppearance(delay: 0.03)

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    if isDownloadsInboxEnabled {
                        SettingsCard(
                            title: SortyLabsFeature.downloadsInbox.title,
                            icon: SortyLabsFeature.downloadsInbox.systemImage,
                            color: .blue,
                            count: inbox.items.isEmpty ? nil : inbox.items.count
                        ) {
                            MenuBarDownloadsInboxSection(showsHeader: false, visibleItemCount: DownloadsInboxManager.maximumItems)
                        }
                        .accessibilityIdentifier("InboxDownloadsCard")
                        .animatedAppearance(delay: 0.05)
                    }

                    if isExpiringFilesEnabled {
                        SettingsCard(
                            title: SortyLabsFeature.expiringFiles.title,
                            icon: SortyLabsFeature.expiringFiles.systemImage,
                            color: .orange,
                            count: expiring.candidates.isEmpty ? nil : expiring.candidates.count
                        ) {
                            MenuBarExpiringFilesSection(startsExpanded: true)
                        }
                        .accessibilityIdentifier("InboxExpiringCard")
                        .animatedAppearance(delay: 0.08)
                    }
                }
                .padding(24)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Inbox")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Also in the menu bar. Turn these off in Settings › Experimental.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                HapticFeedbackManager.shared.tap()
                appState.openSettingsWindow(section: .experimental)
            } label: {
                Label("Labs Settings", systemImage: "flask")
            }
            .buttonStyle(.sortyBordered(intent: .info, size: .small))
            .accessibilityIdentifier("InboxLabsSettingsButton")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}
