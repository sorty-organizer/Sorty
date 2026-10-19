//
//  AdvancedSettingsView.swift
//  Sorty
//
//  Advanced settings section
//

import AppKit
import SwiftUI

struct AdvancedSettingsView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Timeouts", icon: "clock", color: .orange) {
                VStack(spacing: 16) {
                    TimeoutSliderRow(
                        title: "Request Timeout",
                        description: "Time to wait for initial response",
                        value: $viewModel.config.requestTimeout,
                        sliderMin: AIConfig.minRequestTimeout,
                        maxAllowed: AIConfig.maxRequestTimeout,
                        step: 10,
                        focusTarget: .advancedRequestTimeout
                    )

                    Divider()

                    TimeoutSliderRow(
                        title: "Resource Timeout",
                        description: "Maximum total request duration",
                        value: $viewModel.config.resourceTimeout,
                        sliderMin: AIConfig.minOrganizeResourceTimeout,
                        maxAllowed: AIConfig.maxOrganizeResourceTimeout,
                        step: 10,
                        focusTarget: .advancedResourceTimeout
                    )
                }
            }
            .settingsFocusable(.advancedTimeouts)

            SettingsCard(title: "Developer", icon: "hammer", color: .gray) {
                SettingsToggle(
                    isOn: $viewModel.config.showStatsForNerds,
                    title: "Stats for Nerds",
                    description: "Show live AI metrics — tokens, throughput, timing, and cost — in preview, results, and history",
                    focusTarget: .advancedStats
                )
            }
            .settingsFocusable(.advancedDeveloper)
        }
    }
}

// MARK: - Timeout Slider with Editable Maximum

private struct TimeoutSliderRow: View {
    @SortyHotReload private var hotReload
    let title: String
    let description: String
    @Binding var value: TimeInterval
    let sliderMin: Double
    /// Upper bound consumers actually honor. The editable maximum cannot
    /// exceed it, so the UI never advertises an unused timeout.
    let maxAllowed: Double
    let step: Double
    let focusTarget: SettingsFocusTarget

    @State private var editingMax = false
    @State private var maxText = ""
    @State private var customMax: Double?
    @FocusState private var maxFieldFocused: Bool
    
    private var effectiveMax: Double {
        min(max(customMax ?? maxAllowed, sliderMin), maxAllowed)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(LocalizedStringKey(title))
                    .font(.subheadline)
                Spacer()
                Text("\(Int(value))s")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
                    .numericTextTransition(animationValue: value)
            }
            
            HStack(spacing: 8) {
                NoTickSlider(value: $value, in: sliderMin...effectiveMax, step: step)
                
                if editingMax {
                    TextField("Max", text: $maxText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .font(.subheadline.monospacedDigit())
                        .focused($maxFieldFocused)
                        .onSubmit { commitMax() }
                        .onAppear {
                            maxText = "\(Int(effectiveMax))"
                            maxFieldFocused = true
                        }
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            editingMax = true
                        }
                    } label: {
                        Text("\(Int(effectiveMax))s")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .numericTextTransition(animationValue: effectiveMax)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Click to set custom maximum")
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                            HapticFeedbackManager.shared.selection()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
            }
            
            Text(LocalizedStringKey(description))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .settingsFocusableSetting(focusTarget)
    }
    
    private func commitMax() {
        // Double accepts strings such as "inf"; allowing those into the slider
        // range later traps when the displayed maximum is converted to Int.
        // Bound to the hard cap consumers honor so the UI never shows a value
        // that gets silently clamped downstream.
        if let parsed = Double(maxText),
           parsed.isFinite,
           parsed >= sliderMin,
           parsed <= maxAllowed {
            let rounded = (parsed / step).rounded() * step
            let bounded = min(rounded, maxAllowed)
            withAnimation(.easeInOut(duration: 0.15)) {
                customMax = bounded
                if value > bounded { value = bounded }
            }
            HapticFeedbackManager.shared.success()
        }
        withAnimation(.easeInOut(duration: 0.15)) {
            editingMax = false
        }
    }
}

#Preview {
    AdvancedSettingsView()
        .environmentObject(SettingsViewModel())
        .frame(width: 500, height: 500)
}
