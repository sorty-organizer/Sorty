//
//  ThanksForUsingSortyView.swift
//  Sorty
//
//  Appreciation window with usage stats and liquid glass styling.
//

import AppKit
import SwiftUI

struct ThanksForUsingSortyView: View {
    @SortyHotReload private var hotReload
    static let preferredWindowWidth: CGFloat = 480
    static let preferredWindowHeight: CGFloat = 520

    private let sponsorsURL = URL(string: "https://github.com/sponsors/shirishpothi")!

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hoveredStatID: String?
    @State private var stats = UserStatsSnapshot.load()
    @State private var supportHovered = false

    var body: some View {
        VStack(spacing: 16) {
            header
            if FeatureFlags.supportDeveloperEnabled {
                supportButton
            }
            statsTable
        }
        .padding(24)
        .frame(width: Self.preferredWindowWidth, height: Self.preferredWindowHeight)
        .modifier(WindowGlassBackground())
        .windowLinkHoverPillHost()
        .accessibilityIdentifier("ThanksForUsingSortyView")
        .onAppear {
            stats = UserStatsSnapshot.load()
            HapticFeedbackManager.shared.selection()
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            MascotHeartParticleMorphView(color: SortyDesignSystem.Colors.resolvedAccent)
                .frame(width: 170, height: 170)
                .accessibilityHidden(true)
                .accessibilityIdentifier("thanksWindowHeart")

            Text("Thanks for using Sorty")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
        }
    }

    private var supportButton: some View {
        Button {
            HapticFeedbackManager.shared.tap()
            NSWorkspace.shared.open(sponsorsURL)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                Text("Support the Developer")
                    .foregroundStyle(.white)
            }
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .buttonStyle(.sortyProminent)
        .controlSize(.large)
        .trackHoveredURL(sponsorsURL)
        .scaleEffect(supportHovered ? 1.04 : 1.0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: supportHovered)
        .onHover { hovering in
            supportHovered = hovering
            if hovering {
                HapticFeedbackManager.shared.selection()
            }
        }
        .accessibilityIdentifier("thanksSupportDeveloperButton")
    }

    private var statsTable: some View {
        VStack(alignment: .center, spacing: 10) {
            Text("Your Key Stats")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(spacing: 0) {
                statsRow(left: statItems[0], right: statItems[1])
                Divider()
                statsRow(left: statItems[2], right: statItems[3])
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .modifier(LiquidSurface(cornerRadius: 18))
            .onHover { hovering in
                if !hovering {
                    hoveredStatID = nil
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func statsRow(left: StatItem, right: StatItem) -> some View {
        HStack(spacing: 0) {
            statsCell(item: left)
            Divider()
            statsCell(item: right)
        }
        .frame(height: 72)
    }

    private func statsCell(item: StatItem) -> some View {
        let isHighlighted = hoveredStatID == item.id

        return VStack(alignment: .leading, spacing: 4) {
            Text(item.value)
                .font(.title2.bold())
            Text(LocalizedStringKey(item.title))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(isHighlighted ? Color.white.opacity(0.09) : Color.clear)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isHighlighted)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredStatID = item.id
                HapticFeedbackManager.shared.light()
            } else if hoveredStatID == item.id {
                hoveredStatID = nil
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.value)")
        .accessibilityIdentifier("thanksStat_\(item.id)")
    }

    private var statItems: [StatItem] {
        [
            StatItem(id: "sessions", title: "Sessions", value: stats.sessions.formatted()),
            StatItem(id: "filesOrganized", title: "Files Organized", value: stats.filesOrganized.formatted()),
            StatItem(id: "foldersCreated", title: "Folders Created", value: stats.foldersCreated.formatted()),
            StatItem(id: "successRate", title: "Success Rate", value: "\(stats.successRatePercent)%")
        ]
    }
}

private struct StatItem: Identifiable {
    let id: String
    let title: String
    let value: String
}

private struct LiquidSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .systemLiquidGlassBackground(cornerRadius: cornerRadius, interactive: true)
    }
}

struct UserStatsSnapshot {
    let sessions: Int
    let filesOrganized: Int
    let foldersCreated: Int
    let successRate: Double
    let activeDays: Int

    var successRatePercent: Int {
        Int((successRate * 100).rounded())
    }

    static func load(userDefaults: UserDefaults = .standard, storageDirectory: URL? = nil) -> UserStatsSnapshot {
        let entries = OrganizationHistory.loadPersistedEntries(
            userDefaults: userDefaults,
            storageDirectory: storageDirectory
        )

        guard !entries.isEmpty else {
            return UserStatsSnapshot(sessions: 0, filesOrganized: 0, foldersCreated: 0, successRate: 0, activeDays: 0)
        }

        let completedEntries = entries.filter { $0.status == .completed }
        let sessions = entries.count
        let filesOrganized = completedEntries.reduce(0) { $0 + $1.filesOrganized }
        let foldersCreated = completedEntries.reduce(0) { $0 + $1.foldersCreated }
        let successfulCount = completedEntries.count
        let successRate = sessions > 0 ? Double(successfulCount) / Double(sessions) : 0
        let calendar = Calendar.current
        let activeDays = Set(entries.map { calendar.startOfDay(for: $0.timestamp) }).count

        return UserStatsSnapshot(
            sessions: sessions,
            filesOrganized: filesOrganized,
            foldersCreated: foldersCreated,
            successRate: successRate,
            activeDays: activeDays
        )
    }
}

#Preview {
    ThanksForUsingSortyView()
}
