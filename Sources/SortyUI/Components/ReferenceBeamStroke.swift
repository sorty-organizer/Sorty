import Foundation
import SwiftUI

/// Shared drawing for reference beam borders. Callers own timing, motion
/// preferences, visibility, and opacity; this view only renders a phase.
package struct ReferenceBeamStroke: View {
    let cornerRadius: CGFloat
    let phase: TimeInterval
    let lineWidth: CGFloat

    package init(cornerRadius: CGFloat, phase: TimeInterval, lineWidth: CGFloat = 1) {
        self.cornerRadius = cornerRadius
        self.phase = phase
        self.lineWidth = lineWidth
    }

    package var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: .clear, location: 0.08),
                        .init(
                            color: Color(red: 0.08, green: 0.80, blue: 1.0).opacity(0.36),
                            location: 0.16),
                        .init(
                            color: Color(red: 0.92, green: 0.16, blue: 0.58).opacity(0.62),
                            location: 0.25),
                        .init(color: .white.opacity(0.88), location: 0.32),
                        .init(
                            color: Color(red: 1.0, green: 0.34, blue: 0.18).opacity(0.54),
                            location: 0.39),
                        .init(
                            color: Color(red: 0.40, green: 0.20, blue: 1.0).opacity(0.36),
                            location: 0.48),
                        .init(color: .clear, location: 0.58),
                        .init(color: .clear, location: 1.00),
                    ],
                    center: .center,
                    angle: .degrees((phase.truncatingRemainder(dividingBy: 1)) * 360)
                ),
                lineWidth: lineWidth
            )
    }
}
