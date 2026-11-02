//
//  ExperimentalSettingsView.swift
//  Sorty
//
//  PostHog-backed experimental features
//

import SwiftUI

struct ExperimentalSettingsView: View {
    @SortyHotReload private var hotReload
    @ObservedObject private var analytics = AnalyticsManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 12) {
            SortyLabsCard()

            Group {
                if analytics.isLoadingExperimentalFeatures {
                    loadingState
                } else if !otherExperimentalFeatures.isEmpty {
                    featureList
                }
            }
        }
        // Keep the section focus target stable while experimental features load.
        .settingsFocusable(.experimentalEmptyState)
        .task {
            analytics.reloadExperimentalFeatures()
            guard !hasAppeared else { return }
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            hasAppeared = true
        }
    }

    private var otherExperimentalFeatures: [ExperimentalFeature] {
        analytics.experimentalFeatures.filter { $0.id != FeatureFlags.codexSkillInstallerKey }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Checking the lab…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .sortyCard(padding: 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Checking for experimental features.")
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(otherExperimentalFeatures) { feature in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: feature.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                        .frame(width: 28, height: 28)
                        .background(SortyDesignSystem.Colors.resolvedAccent.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(feature.title)
                                .font(.subheadline.weight(.semibold))
                            if let variant = feature.variant {
                                Text(variant)
                                    .sortyBadge()
                            }
                        }
                        Text(feature.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)

                if feature.id != otherExperimentalFeatures.last?.id {
                    Divider()
                }
            }
        }
        .sortyCard(padding: 16)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 8)
        .animation(
            reduceMotion ? .sortyQuick : .sortySmooth,
            value: hasAppeared
        )
    }
}

/// Local opt-in switches for experimental features. Unlike the PostHog list
/// below it, these work offline and never depend on analytics consent.
private struct SortyLabsCard: View {
    @SortyHotReload private var hotReload
    @AppStorage(SortyLabsFeature.routingRules.defaultsKey) private var routingRules = false
    @AppStorage(SortyLabsFeature.downloadsInbox.defaultsKey) private var downloadsInbox = false
    @AppStorage(SortyLabsFeature.expiringFiles.defaultsKey) private var expiringFiles = false
    @AppStorage(ExpiringFilesManager.ageInDaysKey) private var expiringAgeInDays = ExpiringFilesManager.defaultAgeInDays

    var body: some View {
        SettingsCard(title: "Sorty Labs", icon: "flask", color: .indigo) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(SortyLabsFeature.allCases) { feature in
                    SettingsToggle(
                        isOn: binding(for: feature),
                        title: feature.title,
                        description: feature.summary
                    )
                    .accessibilityIdentifier("LabsToggle-\(feature.rawValue)")

                    if feature == .expiringFiles, expiringFiles {
                        Stepper(value: $expiringAgeInDays, in: 1...365) {
                            Text("Offer files older than \(expiringAgeInDays) days")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .numericTextTransition(animationValue: expiringAgeInDays)
                        }
                        .padding(.leading, 4)
                        .accessibilityIdentifier("LabsExpiringAgeStepper")
                    }

                    if feature != SortyLabsFeature.allCases.last {
                        Divider()
                    }
                }
            }
        }
        .onChange(of: downloadsInbox) { _, _ in
            DownloadsInboxManager.shared.refreshEnabledState()
        }
        .onChange(of: expiringFiles) { _, _ in
            Task { await ExpiringFilesManager.shared.refresh() }
        }
    }

    private func binding(for feature: SortyLabsFeature) -> Binding<Bool> {
        let binding: Binding<Bool> = switch feature {
        case .routingRules: $routingRules
        case .downloadsInbox: $downloadsInbox
        case .expiringFiles: $expiringFiles
        }
        return Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                HapticFeedbackManager.shared.selection()
                binding.wrappedValue = newValue
            }
        )
    }
}

#Preview {
    ExperimentalSettingsView()
        .frame(width: 500, height: 320)
        .padding(24)
}
