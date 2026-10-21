//
//  AccreditationsView.swift
//  Sorty
//
//  Dedicated open-source accreditations window.
//

import SwiftUI

struct AccreditationsView: View {
    @SortyHotReload private var hotReload
    @State private var iconHovered = false
    @StateObject private var contributorsFetcher = GitHubContributorsFetcher()
    @AppStorage("fetchGitHubContributorsEnabled") private var fetchGitHubContributorsEnabled = true
    @AppStorage(NetworkPrivacyPolicy.internetPrivacyModeKey) private var internetPrivacyModeEnabled = false
    let showBackButton: Bool
    let onBack: (() -> Void)?

    init(showBackButton: Bool = false, onBack: (() -> Void)? = nil) {
        self.showBackButton = showBackButton
        self.onBack = onBack
    }

    private var shouldFetchContributors: Bool {
        fetchGitHubContributorsEnabled && !internetPrivacyModeEnabled
    }

    private var allCredits: [CreditItem] {
        if shouldFetchContributors {
            return OpenSourceCredits.all + contributorsFetcher.contributors
        }
        return OpenSourceCredits.all
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "c.circle.fill")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(.secondary)
                // Glow carries hover, never scale: scaling re-rasterizes the
                // rolling-credits surface below on every hover frame.
                .shadow(
                    color: .secondary.opacity(iconHovered ? 0.35 : 0),
                    radius: iconHovered ? 10 : 0
                )
                .accessibilityIdentifier("AccreditationsIcon")
                .debouncedHover($iconHovered)

            Text("Accreditations")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Text("These open-source projects and contributors help keep Sorty alive.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 6)

            RollingCreditsView(
                title: "Open Source Projects & Contributors",
                items: allCredits,
                viewportHeight: 220
            )
            .accessibilityIdentifier("AccreditationsRollingCredits")

            if shouldFetchContributors && contributorsFetcher.isLoading && contributorsFetcher.contributors.isEmpty {
                Text("Loading GitHub contributors...")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.7))
                    .transition(.opacity)
            }

            Text("Tap a project to open its repository or license details.")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.82))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Thank you to every maintainer and contributor.")
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 380, height: 500)
        .overlay(alignment: .topLeading) {
            if showBackButton, let onBack {
                GlassyBackButton(action: onBack)
                    .accessibilityIdentifier("AccreditationsBackButton")
                    .padding(.top, 10)
                    .padding(.leading, 8)
            }
        }
        .modifier(WindowGlassBackground())
        .windowLinkHoverPillHost()
        .accessibilityIdentifier("AccreditationsView")
        .onAppear {
            contributorsFetcher.fetchIfNeeded(enabled: shouldFetchContributors)
        }
        .onChange(of: fetchGitHubContributorsEnabled) { _, newValue in
            contributorsFetcher.fetchIfNeeded(enabled: newValue && !internetPrivacyModeEnabled, forceRefresh: true)
        }
        .onChange(of: internetPrivacyModeEnabled) { _, newValue in
            contributorsFetcher.fetchIfNeeded(enabled: fetchGitHubContributorsEnabled && !newValue, forceRefresh: true)
        }
    }
}

#Preview {
    AccreditationsView()
}
