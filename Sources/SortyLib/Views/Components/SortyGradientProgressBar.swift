//
//  SortyGradientProgressBar.swift
//  Sorty
//
//  Reusable progress indicators with gradient fills.
//

import SwiftUI

// MARK: - Private helpers

private struct SortyGradientRingSegment: View {
    @SortyHotReload private var hotReload
    let accent: Color
    let lineWidth: CGFloat
    let start: Double
    let end: Double

    var body: some View {
        Circle()
            .inset(by: lineWidth / 2)
            .trim(from: start, to: end)
            .stroke(
                SortyBeamPalette.arcGradient(accent: accent),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .shadow(color: accent.opacity(0.24), radius: lineWidth * 1.25)
    }
}

private enum SortyBeamPalette {
    static var trackFill: some ShapeStyle {
        Color.white.opacity(0.055)
    }

    static var trackStroke: some ShapeStyle {
        LinearGradient(
            colors: [.white.opacity(0.18), .white.opacity(0.045)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func barGradient(accent: Color) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: accent.opacity(0.82), location: 0.0),
                .init(color: accent.opacity(0.98), location: 0.48),
                .init(color: accent.opacity(0.86), location: 1.0),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    static func arcGradient(accent: Color) -> AngularGradient {
        AngularGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: accent.opacity(0.24), location: 0.48),
                .init(color: accent.opacity(0.70), location: 0.76),
                .init(color: accent.opacity(0.94), location: 0.92),
                .init(color: accent.opacity(0.98), location: 1.0),
            ],
            center: .center
        )
    }
}

// MARK: - SortyGradientProgressBar

struct SortyGradientProgressBar: View {
    @SortyHotReload private var hotReload
    let progress: Double
    var accent: Color = SortyDesignSystem.Colors.resolvedAccent
    var height: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(SortyBeamPalette.trackFill)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(SortyBeamPalette.trackStroke, lineWidth: 1)
                    )

                if clampedProgress > 0 {
                    let fillWidth = max(height, geo.size.width * clampedProgress)

                    Capsule(style: .continuous)
                        .fill(SortyBeamPalette.barGradient(accent: accent))
                        .overlay(
                            Capsule(style: .continuous)
                                .inset(by: max(1, height * 0.14))
                                .fill(.white.opacity(0.18))
                                .frame(height: max(1.5, height * 0.20)),
                            alignment: .top
                        )
                        .frame(width: fillWidth)
                        .shadow(color: accent.opacity(0.22), radius: height * 0.65, x: 0, y: 0)
                        .shadow(color: accent.opacity(0.16), radius: height * 1.05, x: 0, y: 0)
                }
            }
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.25), value: clampedProgress)
    }
}

// MARK: - SortyGradientLoadingBar

struct SortyGradientLoadingBar: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var accent: Color = SortyDesignSystem.Colors.resolvedAccent
    var width: CGFloat = 150
    var height: CGFloat = 10
    var segmentWidthRatio: CGFloat = 0.34

    @State private var travelPhase: CGFloat = 0

    private var clampedSegmentRatio: CGFloat {
        min(max(segmentWidthRatio, 0.15), 0.75)
    }

    var body: some View {
        GeometryReader { geo in
            let segmentWidth = geo.size.width * clampedSegmentRatio
            let travelDistance = geo.size.width + segmentWidth

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(SortyBeamPalette.trackFill)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(SortyBeamPalette.trackStroke, lineWidth: 1)
                    )

                Capsule(style: .continuous)
                    .fill(SortyBeamPalette.barGradient(accent: accent))
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(accent.opacity(0.16))
                    )
                    .frame(width: segmentWidth)
                    .offset(x: (travelPhase * travelDistance) - segmentWidth)
                    .shadow(color: accent.opacity(0.42), radius: 7, x: 0, y: 0)
            }
            .clipShape(Capsule(style: .continuous))
        }
        .frame(width: width, height: height)
        .onAppear {
            travelPhase = reduceMotion ? 0.5 : 0
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                travelPhase = 1
            }
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            if shouldReduceMotion {
                travelPhase = 0.5
            } else {
                travelPhase = 0
                withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                    travelPhase = 1
                }
            }
        }
    }
}

// MARK: - SortyGradientCircularProgress

struct SortyGradientCircularProgress: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let progress: Double
    var accent: Color = SortyDesignSystem.Colors.resolvedAccent
    var size: CGFloat = 80
    var lineWidth: CGFloat = 8
    var showsShimmer: Bool = false

    @State private var animatedProgress: Double = 0
    @State private var isWindowVisible = true

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(SortyBeamPalette.trackFill, lineWidth: lineWidth)

            if animatedProgress > 0 {
                SortyGradientRingSegment(
                    accent: accent,
                    lineWidth: lineWidth,
                    start: 0,
                    end: animatedProgress
                )
            }

            if showsShimmer {
                SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isWindowVisible || animatedProgress == 0)) { context in
                    let elapsed = context.date.timeIntervalSinceReferenceDate
                    let arcSpan = animatedProgress * 360
                    let phase = (elapsed * 120).truncatingRemainder(
                        dividingBy: arcSpan.isZero ? 360 : arcSpan)
                    let shimmerCenter = phase / max(arcSpan, 1)
                    let pulse = (sin(elapsed * 1.8) + 1) * 0.5
                    let peakOpacity = 0.35 + (pulse * 0.25)
                    let glowOpacity = 0.10 + (pulse * 0.10)
                    let highlightWidth: Double = 0.12

                    let trimStart = max(shimmerCenter - highlightWidth, 0) * animatedProgress
                    let trimEnd = min(shimmerCenter + highlightWidth, 1) * animatedProgress

                    Circle()
                        .inset(by: lineWidth / 2)
                        .trim(from: trimStart, to: trimEnd)
                        .stroke(
                            accent.opacity(peakOpacity),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .blur(radius: 2)
                        .blendMode(.plusLighter)

                    Circle()
                        .inset(by: lineWidth / 2)
                        .trim(from: 0, to: animatedProgress)
                        .stroke(
                            accent.opacity(glowOpacity),
                            style: StrokeStyle(lineWidth: lineWidth + 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .blur(radius: lineWidth * 0.8)
                        .blendMode(.plusLighter)
                }
                .drawingGroup(opaque: false)
            }
        }
        .frame(width: size, height: size)
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                animatedProgress = clampedProgress
            }
        }
        .onChange(of: clampedProgress) { _, newValue in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                animatedProgress = newValue
            }
        }
    }
}

// MARK: - SortyGradientCircularLoader

/// Compact spinning loader with a tail-to-tip gradient arc.
struct SortyGradientCircularLoader: View {
    @SortyHotReload private var hotReload
    var accent: Color = SortyDesignSystem.Colors.resolvedAccent
    var size: CGFloat = 18
    var lineWidth: CGFloat = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        SwiftUI.TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: reduceMotion || controlActiveState == .inactive
            )
        ) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let rotation = reduceMotion ? 0 : (time * 280).truncatingRemainder(dividingBy: 360)
            let pulse = (sin(time * 2.2) + 1) * 0.5
            let sweep = 0.24 + (0.34 * pulse)
            let trailEnd = 0.06 + ((1 - pulse) * 0.08)
            let leadEnd = min(trailEnd + sweep, 0.97)
            let arcLen = leadEnd - trailEnd

            let stops: [Gradient.Stop] = [
                .init(color: .clear, location: trailEnd),
                .init(color: accent.opacity(0.34), location: trailEnd + arcLen * 0.50),
                .init(color: accent.opacity(0.78), location: trailEnd + arcLen * 0.84),
                .init(color: accent.opacity(0.98), location: leadEnd),
            ]

            ZStack {
                Circle()
                    .inset(by: lineWidth / 2)
                    .stroke(SortyBeamPalette.trackFill, lineWidth: lineWidth)

                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: trailEnd, to: leadEnd)
                    .stroke(
                        AngularGradient(stops: stops, center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(rotation - 90))
                    .shadow(color: accent.opacity(0.48), radius: lineWidth * 1.2, x: 0, y: 0)
            }
        }
        .frame(width: size, height: size)
        .drawingGroup(opaque: false)
    }
}
