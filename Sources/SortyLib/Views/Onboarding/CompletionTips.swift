import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI

struct CompletionContrastBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @SortyHotReload private var hotReload
    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).opacity(0.38)

            LinearGradient(
                colors: [
                    Color.black.opacity(colorScheme == .dark ? 0.22 : 0),
                    Color.clear,
                    Color.black.opacity(colorScheme == .dark ? 0.10 : 0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    CompletionPalette.softRose.opacity(0.18),
                    CompletionPalette.accent.opacity(0.08),
                    Color.clear
                ],
                center: UnitPoint(x: 0.50, y: 0.42),
                startRadius: 20,
                endRadius: 520
            )
        }
        .mask(alignment: .top) {
            VStack(spacing: 0) {
                LinearGradient(
                    stops: [
                        .init(color: Color.clear, location: 0.00),
                        .init(color: Color.clear, location: 0.16),
                        .init(color: Color.black.opacity(0.18), location: 0.46),
                        .init(color: Color.black.opacity(0.62), location: 0.76),
                        .init(color: Color.black, location: 1.00)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 300)

                Color.black
            }
        }
        .ignoresSafeArea()
    }
}

struct QuickTipRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @SortyHotReload private var hotReload
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(CompletionPalette.accent.opacity(0.14))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                CompletionPalette.softRose.opacity(0.24),
                                lineWidth: 0.5
                            )
                    )

                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? CompletionPalette.softRose : CompletionPalette.deepRose)
            }

            Text(text)
                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 4)
    }
}
