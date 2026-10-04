//
//  DuplicateSettingsView.swift
//  Sorty
//
//  UI for configuring duplicate detection settings
//

import SwiftUI

struct DuplicateSettingsView: View {
    @SortyHotReload private var hotReload
    @ObservedObject var settingsManager: DuplicateSettingsManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SortyDesignSystem.Spacing.lg) {
                VStack(alignment: .leading, spacing: SortyDesignSystem.Spacing.xxs) {
                    Text("Duplicate Preferences")
                        .sortyTypography(.title3, weight: .medium)
                    Text("Control what scans include and how bulk cleanup keeps a copy.")
                        .sortyTypography()
                        .foregroundStyle(SortyDesignSystem.Colors.textSecondary)
                }

                Spacer()

                HStack(spacing: SortyDesignSystem.Spacing.md) {
                    Button("Restore Defaults", systemImage: "arrow.counterclockwise") {
                        HapticFeedbackManager.shared.tap()
                        settingsManager.reset()
                    }
                    .labelStyle(.iconOnly)
                    .systemLiquidGlassButton()
                    .help("Restore Defaults")

                    Button("Done", action: saveAndDismiss)
                        .buttonStyle(.sortyPrimary(size: .small))
                        .systemLiquidGlassBackground(cornerRadius: 999)
                        .keyboardShortcut(.return)
                }
            }
            .padding(.horizontal, SortyDesignSystem.Spacing.xl)
            .padding(.vertical, SortyDesignSystem.Spacing.lg)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: SortyDesignSystem.Spacing.sectionMedium) {
                    SettingsCard(
                        title: "Scan Results",
                        icon: "magnifyingglass",
                        color: SortyDesignSystem.Colors.primary
                    ) {
                        VStack(alignment: .leading, spacing: SortyDesignSystem.Spacing.lg) {
                            Toggle(
                                "Find similar files",
                                isOn: $settingsManager.settings.includeSemanticDuplicates
                            )

                            Text("Similar files may be versions or variants. Sorty keeps them out of bulk cleanup so you can review them individually.")
                                .sortyTypography()
                                .foregroundStyle(SortyDesignSystem.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            if settingsManager.settings.includeSemanticDuplicates {
                                SettingsSubsettingRow(
                                    title: "Match range",
                                    description: "Choose how closely files need to match."
                                ) {
                                    Picker(
                                        "Match range",
                                        selection: $settingsManager.settings.semanticSimilarityThreshold
                                    ) {
                                        ForEach(SimilarFileMatchRange.allCases, id: \.self) { range in
                                            Text(range.displayName).tag(range.threshold)
                                        }
                                        if !presetThresholds.contains(
                                            settingsManager.settings.semanticSimilarityThreshold
                                        ) {
                                            Text("Custom").tag(
                                                settingsManager.settings.semanticSimilarityThreshold
                                            )
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .accessibilityIdentifier("SemanticSimilarityThresholdPicker")
                                }
                            }
                        }
                        .animation(
                            reduceMotion
                                ? .easeInOut(duration: 0.14)
                                : .spring(response: 0.34, dampingFraction: 0.78),
                            value: settingsManager.settings.includeSemanticDuplicates
                        )
                    }

                    SettingsCard(
                        title: "Bulk Cleanup",
                        icon: "checkmark.shield",
                        color: SortyDesignSystem.Colors.primary
                    ) {
                        VStack(alignment: .leading, spacing: SortyDesignSystem.Spacing.md) {
                            Picker(
                                "Copy to keep",
                                selection: $settingsManager.settings.defaultKeepStrategy
                            ) {
                                ForEach(KeepStrategy.usefulCleanupCases, id: \.self) { strategy in
                                    Text(strategy.displayName).tag(strategy)
                                }
                            }
                            .pickerStyle(.menu)

                            Text(settingsManager.settings.defaultKeepStrategy.description)
                                .sortyTypography()
                                .foregroundStyle(SortyDesignSystem.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(SortyDesignSystem.Spacing.xl)
            }
        }
        .frame(width: 560, height: 460)
        .background(SortyDesignSystem.Colors.backgroundPrimary)
        .onDisappear(perform: settingsManager.save)
    }

    private var presetThresholds: [Double] {
        SimilarFileMatchRange.allCases.map(\.threshold)
    }
    
    private func saveAndDismiss() {
        HapticFeedbackManager.shared.light()
        settingsManager.save()
        dismiss()
    }
}

#Preview {
    DuplicateSettingsView(settingsManager: DuplicateSettingsManager())
}
