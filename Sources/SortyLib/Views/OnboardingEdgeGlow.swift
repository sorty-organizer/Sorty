import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import os

struct OnboardingScreenEdgeGlow: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var strength = 0.55
    var body: some View {
        ZStack {
            edgeGradient(startPoint: .top, endPoint: .bottom)
            edgeGradient(startPoint: .bottom, endPoint: .top)
            edgeGradient(startPoint: .leading, endPoint: .trailing)
            edgeGradient(startPoint: .trailing, endPoint: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .compositingGroup()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: strength)
        .blur(radius: 12)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func edgeGradient(
        startPoint: UnitPoint,
        endPoint: UnitPoint
    ) -> some View {
        return LinearGradient(
            stops: [
                .init(
                    color: SortyDesignSystem.Colors.resolvedAccent.opacity(strength),
                    location: 0
                ),
                .init(
                    color: SortyDesignSystem.Colors.resolvedAccent.opacity(strength * 0.34),
                    location: 0.035
                ),
                .init(color: .clear, location: 0.13)
            ],
            startPoint: startPoint,
            endPoint: endPoint
        )
    }
}
