//
//  OrganizationRulesSettingsView.swift
//  Sorty
//
//  Organization Rules settings section
//

import SwiftUI

struct OrganizationRulesSettingsView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var viewModel: SettingsViewModel
    
    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Content Rules", icon: "checklist", color: .orange) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsToggle(
                        isOn: $viewModel.config.enableFileTagging,
                        title: "Enable File Tagging",
                        description: "Allow Sorty to suggest and apply Finder tags to files",
                        focusTarget: .rulesFileTagging
                    )
                }
            }
            .settingsFocusable(.rulesContentRules)
            .animatedAppearance(delay: 0.05)

            // Organization Style
            SettingsCard(title: "Organization Style", icon: "paintpalette", color: .purple) {
                PersonaPickerView()
            }
            .settingsFocusable(.rulesOrganizationStyle)
            .animatedAppearance(delay: 0.1)
        }
    }
}

#Preview {
    OrganizationRulesSettingsView()
        .environmentObject(AppState())
        .environmentObject(SettingsViewModel())
        .frame(width: 500, height: 400)
}
