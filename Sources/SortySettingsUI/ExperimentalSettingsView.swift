//
//  ExperimentalSettingsView.swift
//  Sorty
//
//  Sorty Labs switches and remotely tested features
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

            if analytics.isLoadingExperimentalFeatures || !otherExperimentalFeatures.isEmpty {
                remoteFeaturesCard
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? .sortyQuick : .sortySmooth, value: analytics.isLoadingExperimentalFeatures)
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

    /// Features rolled out remotely. While the list loads, the card keeps its
    /// shape with placeholder rows so nothing jumps when results arrive.
    private var remoteFeaturesCard: some View {
        SettingsCard(title: "In Testing", icon: "testtube.2", color: .teal) {
            if analytics.isLoadingExperimentalFeatures {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Checking for experimental features")
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if analytics.isLoadingExperimentalFeatures && otherExperimentalFeatures.isEmpty {
                    ForEach(0..<2, id: \.self) { index in
                        remoteFeatureRow(
                            title: "Experimental feature",
                            description: "A short description of what this feature changes in Sorty.",
                            systemImage: "flask",
                            variant: nil
                        )
                        .redacted(reason: .placeholder)
                        .accessibilityHidden(true)
                        if index == 0 { Divider() }
                    }
                } else {
                    Text("Features Sorty is trying out with some users. They turn on for you automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(otherExperimentalFeatures) { feature in
                        Divider()
                        remoteFeatureRow(
                            title: feature.title,
                            description: feature.description,
                            systemImage: feature.systemImage,
                            variant: feature.variant
                        )
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 8)
        .animation(reduceMotion ? .sortyQuick : .sortySmooth, value: hasAppeared)
    }

    private func remoteFeatureRow(title: String, description: String, systemImage: String, variant: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            LabsIconTile(systemImage: systemImage, tint: .teal)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    if let variant {
                        Text(variant)
                            .sortyBadge()
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

/// Tinted rounded square that leads each Labs row.
private struct LabsIconTile: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.sm, style: .continuous)
                    .fill(tint.opacity(0.14))
            )
            .accessibilityHidden(true)
    }
}

/// Local opt-in switches for experimental features. Unlike the PostHog list
/// below it, these work offline and never depend on analytics consent.
private struct SortyLabsCard: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SortyLabsFeature.routingRules.defaultsKey) private var routingRules = false
    @AppStorage(SortyLabsFeature.expiringFiles.defaultsKey) private var expiringFiles = false
    @AppStorage(ExpiringFilesManager.ageInDaysKey) private var expiringAgeInDays = ExpiringFilesManager.defaultAgeInDays
    @AppStorage(ExpiringFilesManager.finishedDownloadsKey) private var finishedDownloads = false
    @EnvironmentObject private var appState: AppState

    /// Ages offered in the menu; a value set with `defaults write` is added so it still shows.
    private var agePresets: [Int] {
        let presets = [1, 3, 7, 14, 30, 60, 90]
        return presets.contains(expiringAgeInDays) ? presets : (presets + [expiringAgeInDays]).sorted()
    }

    var body: some View {
        SettingsCard(title: "Sorty Labs", icon: "flask", color: .indigo) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Early features you can switch on yourself. They work offline and may change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(SortyLabsFeature.allCases) { feature in
                    Divider()
                    featureSection(feature)
                }
            }
            .animation(reduceMotion ? .sortyFade : .sortySmooth, value: expiringFiles)
            .animation(reduceMotion ? .sortyFade : .sortySmooth, value: routingRules)
        }
        .onChange(of: expiringFiles) { _, _ in
            Task { await ExpiringFilesManager.shared.refresh() }
        }
        .onChange(of: finishedDownloads) { _, _ in
            HapticFeedbackManager.shared.selection()
            Task { await ExpiringFilesManager.shared.refresh() }
        }
        .onChange(of: expiringAgeInDays) { _, _ in
            HapticFeedbackManager.shared.selection()
            Task { await ExpiringFilesManager.shared.refresh() }
        }
    }

    @ViewBuilder
    private func featureSection(_ feature: SortyLabsFeature) -> some View {
        let isOn = binding(for: feature)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                LabsIconTile(systemImage: feature.systemImage, tint: .indigo)

                VStack(alignment: .leading, spacing: 4) {
                    Text(feature.title)
                        .font(.subheadline.weight(.medium))
                    Text(feature.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                    if isOn.wrappedValue {
                        openLink(for: feature)
                            .padding(.top, 2)
                            .transition(.opacity)
                    }
                }

                Spacer(minLength: 12)

                Toggle(feature.title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .fixedSize()
                    .accessibilityIdentifier("LabsToggle-\(feature.rawValue)")
            }
            .padding(.vertical, 4)

            if feature == .expiringFiles, expiringFiles {
                SettingsSubsettingRow(
                    title: "Offer Files After",
                    description: "How long a file sits untouched before it's offered."
                ) {
                    Picker("Offer Files After", selection: $expiringAgeInDays) {
                        ForEach(agePresets, id: \.self) { days in
                            Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityIdentifier("LabsExpiringAgePicker")
                }

                SettingsSubsettingRow(
                    title: "Spot Finished Downloads",
                    description: "Offer an installer once its app is in Applications, and an archive once it's been extracted, without waiting."
                ) {
                    Toggle("Spot Finished Downloads", isOn: $finishedDownloads)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .fixedSize()
                        .accessibilityIdentifier("LabsExpiringFinishedToggle")
                }
            }
        }
    }

    /// Points each enabled feature at the screen where it lives in the main window.
    private func openLink(for feature: SortyLabsFeature) -> some View {
        let (title, destination): (String, AppState.AppView) = switch feature {
        case .routingRules: ("Add rules in Exclusions", .exclusions)
        case .expiringFiles: ("Open Clean Up in Watched Folders", .watchedFolders)
        }
        return Button {
            HapticFeedbackManager.shared.tap()
            appState.openRelatedView(destination)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
        .pointerStyle(.link)
        .accessibilityIdentifier("LabsOpen-\(feature.rawValue)")
    }

    private func binding(for feature: SortyLabsFeature) -> Binding<Bool> {
        let binding: Binding<Bool> = switch feature {
        case .routingRules: $routingRules
        case .expiringFiles: $expiringFiles
        }
        return Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                HapticFeedbackManager.shared.selection()
                binding.wrappedValue = newValue
                AnalyticsManager.shared.captureSettingChanged(feature.title, isEnabled: newValue)
            }
        )
    }
}

#Preview {
    ExperimentalSettingsView()
        .frame(width: 500, height: 320)
        .padding(24)
}
