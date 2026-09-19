//
//  GlassyBackButton.swift
//  Sorty
//
//  Reusable glassy back button component
//

import SwiftUI

struct GlassyBackButton: View {
    @SortyHotReload private var hotReload
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .systemLiquidGlassCircularButtonLabel()
                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
        .accessibilityIdentifier("GlassyBackButton")
    }
}
