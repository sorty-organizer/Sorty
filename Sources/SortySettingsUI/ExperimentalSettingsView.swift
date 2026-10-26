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
        .padding(20)
        .frame(maxWidth: .infinity)
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Checking for experimental features.")
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(otherExperimentalFeatures) { feature in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: feature.systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.indigo)
                        .frame(width: 28, height: 28)
                        .background(.indigo.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(feature.title)
                                .font(.subheadline.weight(.semibold))
                            if let variant = feature.variant {
                                Text(variant)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.secondary.opacity(0.1), in: Capsule())
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 8)
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.45, dampingFraction: 0.82),
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
    @AppStorage(SortyLabsFeature.projectDetection.defaultsKey) private var projectDetection = false
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
        case .projectDetection: $projectDetection
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
