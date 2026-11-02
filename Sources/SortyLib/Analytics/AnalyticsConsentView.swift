//
//  AnalyticsConsentView.swift
//  Sorty
//
//  One-time, explicit analytics choice shown after onboarding.
//

import SwiftUI

public struct AnalyticsConsentView: View {
    @SortyHotReload private var hotReload
    @ObservedObject private var analytics = AnalyticsManager.shared
    @Environment(\.openURL) private var openURL

    public init() {}

    public var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                Label("Help Improve Sorty", systemImage: "chart.bar.xaxis")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)

                Text("Allow anonymous product and reliability analytics?")
                    .font(.headline)

                Text("If you allow it, Sorty records which screens and features are used, broad outcome and timing buckets, and sanitized errors or crashes. It never sends folder names, file names, paths, file contents, prompts, AI responses, API keys, or your identity.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("You can change this at any time in Advanced Settings. “Don’t Allow” sends nothing and Sorty won’t ask again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Read the Privacy Policy") {
                    guard let url = URL(string: "https://sorty-organizer.github.io/Sorty/privacy-policy/") else {
                        return
                    }
                    openURL(url)
                }
                .buttonStyle(.link)
                .controlSize(.small)

                HStack(spacing: 10) {
                    Button("Don’t Allow") {
                        HapticFeedbackManager.shared.tap()
                        analytics.setConsent(.denied)
                    }
                    .buttonStyle(.sortyBordered)
                    .accessibilityIdentifier("AnalyticsConsentDenyButton")

                    Button("Allow Anonymous Analytics") {
                        HapticFeedbackManager.shared.success()
                        analytics.setConsent(.granted)
                    }
                    .buttonStyle(.sortyProminent)
                    .accessibilityIdentifier("AnalyticsConsentAllowButton")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(24)
            .frame(width: 510)
            .systemLiquidGlassBackground(cornerRadius: SortyDesignSystem.Radius.xl, interactive: false)
            .shadow(color: .black.opacity(0.16), radius: 28, y: 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Anonymous analytics permission")
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}
