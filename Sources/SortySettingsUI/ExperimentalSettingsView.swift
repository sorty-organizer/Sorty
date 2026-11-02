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
    @State private var hasReportedRemoteExperiments = false

    var body: some View {
        VStack(spacing: 12) {
            SortyLabsCard()

            if analytics.isLoadingExperimentalFeatures || !otherExperimentalFeatures.isEmpty {
                remoteFeaturesCard
                    .transition(.opacity)
            }
        }
        .onChange(of: analytics.isLoadingExperimentalFeatures) { _, isLoading in
            if !isLoading { reportRemoteExperimentsOnce() }
        }
        .animation(reduceMotion ? .sortyQuick : .sortySmooth, value: analytics.isLoadingExperimentalFeatures)
        // Keep the section focus target stable while experimental features load.
        .settingsFocusable(.experimentalEmptyState)
        .task {
            analytics.reloadExperimentalFeatures()
            // A throttled reload answers from cache without a loading phase.
            if !analytics.isLoadingExperimentalFeatures { reportRemoteExperimentsOnce() }
            guard !hasAppeared else { return }
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            hasAppeared = true
        }
    }

    /// Reported once per visit, after loading settles, so reloads don't double count.
    private func reportRemoteExperimentsOnce() {
        guard !hasReportedRemoteExperiments else { return }
        hasReportedRemoteExperiments = true
        LabsTelemetry.remoteExperimentsShown(count: otherExperimentalFeatures.count)
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

    static let agePresetValues = [1, 3, 7, 14, 30, 60, 90]

    /// Ages offered in the menu; a value set with `defaults write` is added so it still shows.
    private var agePresets: [Int] {
        let presets = Self.agePresetValues
        return presets.contains(expiringAgeInDays) ? presets : (presets + [expiringAgeInDays]).sorted()
    }

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

                    if binding(for: feature).wrappedValue {
                        openLink(for: feature)
                            .transition(.opacity)
                    }

                    if feature == .expiringFiles, expiringFiles {
                        expiringOptions
                            .transition(.opacity)
                    }

                    if feature != SortyLabsFeature.allCases.last {
                        Divider()
                    }
                }
            }
            .animation(reduceMotion ? .sortyFade : .sortySmooth, value: expiringFiles)
            .animation(reduceMotion ? .sortyFade : .sortySmooth, value: routingRules)
        }
        .onChange(of: expiringFiles) { _, _ in
            Task { await ExpiringFilesManager.shared.refresh() }
        }
        .onChange(of: finishedDownloads) { _, isOn in
            HapticFeedbackManager.shared.selection()
            AnalyticsManager.shared.captureSettingChanged("Spot Finished Downloads", isEnabled: isOn, section: "experimental")
            Task { await ExpiringFilesManager.shared.refresh() }
        }
        .onChange(of: expiringAgeInDays) { _, days in
            HapticFeedbackManager.shared.selection()
            LabsTelemetry.expiringAgeChanged(to: days, presets: Self.agePresetValues)
            Task { await ExpiringFilesManager.shared.refresh() }
        }
    }

    /// Expiring Files options in one inset box under the feature, so they read
    /// as belonging to it rather than as features of their own.
    private var expiringOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Offer files after")
                    .font(.callout)
                Spacer(minLength: 12)
                Picker("Offer files after", selection: $expiringAgeInDays) {
                    ForEach(agePresets, id: \.self) { days in
                        Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("LabsExpiringAgePicker")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
                .padding(.leading, 12)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spot finished downloads")
                        .font(.callout)
                    Text("Offer installers once their app is installed, and archives once extracted, without waiting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("Spot finished downloads", isOn: $finishedDownloads)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityIdentifier("LabsExpiringFinishedToggle")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.md, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.md, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    /// Points each enabled feature at the screen where it lives in the main window.
    private func openLink(for feature: SortyLabsFeature) -> some View {
        let (title, destination): (String, AppState.AppView) = switch feature {
        case .routingRules: ("Add Routing Rules in Exclusions", .exclusions)
        case .expiringFiles: ("Review in Watched Folders", .watchedFolders)
        }
        return Button {
            HapticFeedbackManager.shared.tap()
            LabsTelemetry.openedFromSettings(feature)
            appState.openRelatedView(destination)
        } label: {
            Label(title, systemImage: "arrow.up.right")
        }
        .buttonStyle(.sortyBordered(intent: .info, size: .small))
        .accessibilityIdentifier("LabsOpen-\(feature.rawValue)")
    }

    /// SettingsToggle already plays the haptic and records the change.
    private func binding(for feature: SortyLabsFeature) -> Binding<Bool> {
        switch feature {
        case .routingRules: $routingRules
        case .expiringFiles: $expiringFiles
        }
    }
}

#Preview {
    ExperimentalSettingsView()
        .frame(width: 500, height: 320)
        .padding(24)
}
