//
//  OrganizationRulesSettingsView.swift
//  Sorty
//
//  Organization Rules settings section
//

import SwiftUI

/// Shapes what organized folders look like: persona style, Finder tags, and
/// the exclusions every plan respects.
struct OrganizationRulesSettingsView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var viewModel: SettingsViewModel
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Organization Style", icon: "paintpalette", color: .purple) {
                PersonaPickerView()
            }
            .settingsFocusable(.rulesOrganizationStyle)

            SettingsCard(title: "Finder Tags", icon: "tag", color: .orange) {
                SettingsToggle(
                    isOn: $viewModel.config.enableFileTagging,
                    title: "Enable File Tagging",
                    description: "Allow Sorty to suggest and apply Finder tags to files",
                    focusTarget: .rulesFileTagging
                )
            }
            .settingsFocusable(.rulesContentRules)

            SettingsCard(title: "Exclusions", icon: "minus.circle", color: .red) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        ExclusionRuleCountLabel()
                        Text("Files and folders that match are left out of every organization plan.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        HapticFeedbackManager.shared.tap()
                        appState.openRelatedView(.exclusions)
                    } label: {
                        Label("Manage", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.sortyBordered(intent: .info, size: .small))
                    .accessibilityIdentifier("SettingsManageExclusionsButton")
                }
                .settingsFocusableSetting(.rulesExclusions)
            }
        }
    }
}

/// Observes the exclusion store on its own so rule usage updates only redraw this label.
private struct ExclusionRuleCountLabel: View {
    @EnvironmentObject private var exclusionRules: ExclusionRulesManager

    var body: some View {
        Text(summary)
            .font(.subheadline.weight(.medium))
            .numericTextTransition(animationValue: summary)
    }

    private var summary: String {
        guard exclusionRules.hasLoadedPersistedState else { return "Exclusion rules" }
        let count = exclusionRules.rules.filter(\.isEnabled).count
        switch count {
        case 0: return "No active exclusion rules"
        case 1: return "1 active exclusion rule"
        default: return "\(count) active exclusion rules"
        }
    }
}

#Preview {
    OrganizationRulesSettingsView()
        .environmentObject(AppState())
        .environmentObject(SettingsViewModel())
        .environmentObject(ExclusionRulesManager())
        .frame(width: 500, height: 400)
}
