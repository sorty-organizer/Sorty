import AppKit
import Foundation
import SwiftUI
import Beam

struct ScanningPulseIcon: View {
    @SortyHotReload private var hotReload
    let systemName: String
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var isWindowVisible = true

    private var isPaused: Bool {
        reduceMotion || reduceTransparency || !isWindowVisible
            || controlActiveState == .inactive || scenePhase != .active
    }

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: isPaused)) {
            timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let pulse = isPaused ? 0.5 : (sin(elapsed * 3.2) + 1) / 2
            let beamPhase = isPaused ? 0.5 : elapsed.truncatingRemainder(dividingBy: 1.8) / 1.8

            Image(systemName: systemName)
                .font(.system(size: 48))
                .foregroundStyle(color.opacity(0.55 + pulse * 0.2))
                .overlay {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [
                                .clear, .white, SortyDesignSystem.Colors.resolvedAccent, .clear,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.65)
                        .offset(
                            x: (proxy.size.width * 1.65 * beamPhase) - (proxy.size.width * 0.65))
                    }
                    .mask {
                        Image(systemName: systemName)
                            .font(.system(size: 48))
                    }
                    .opacity(isPaused ? 0.35 : 0.95)
                }
                .shadow(
                    color: SortyDesignSystem.Colors.resolvedAccent.opacity(0.27),
                    radius: 4
                )
        }
        .frame(width: 72, height: 56)
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .accessibilityHidden(true)
    }
}

struct ScanProgressViewNew: View {
    @SortyHotReload private var hotReload
    let progress: Double
    var isPreparing: Bool = false
    var stage: String = ""

    @Environment(\.controlActiveState) private var controlActiveState

    private var isAnimationActive: Bool {
        controlActiveState != .inactive
    }

    private var clampedProgress: Double {
        max(0, min(1, progress))
    }

    private var percent: Int {
        Int((clampedProgress * 100).rounded())
    }

    private var title: String {
        if isPreparing {
            return "Preparing Scan..."
        }
        return stage.localizedCaseInsensitiveContains("semantic")
            ? "Finding Similar Files"
            : "Finding Exact Duplicates"
    }

    private var scanIcon: String {
        isPreparing ? "folder.badge.gearshape" : "doc.text.magnifyingglass"
    }

    private var subtitle: String {
        if !stage.isEmpty {
            return stage
        }
        return isPreparing
            ? "Reading directory structure..." : "Comparing file content to find exact matches..."
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                progressCard
            }
            .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            isPreparing
                ? "Preparing scan" : "Scanning for duplicate files, \(percent) percent complete")
    }

    private var progressCard: some View {
        ZStack {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: scanIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .symbolReplaceTransition(animationValue: scanIcon)
                    .frame(width: 30)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(LocalizedStringKey(title))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                            .numericTextTransition(animationValue: title)

                        if !isPreparing {
                            Text("\(percent)%")
                                .monospacedDigit()
                                .fixedSize(horizontal: true, vertical: false)
                                .numericTextTransition(
                                    animationValue: percent,
                                    animation: .easeInOut(duration: 0.3)
                                )
                        }
                    }
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)

                    Text(LocalizedStringKey(subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .numericTextTransition(animationValue: subtitle)
                }

                Spacer(minLength: 0)

                MinsangGlassLoader(
                    textChangeTrigger: title,
                    size: 54,
                    isActive: isAnimationActive
                )
                .frame(width: 54)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 420, height: 94)
        .background {
            beamSurface
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isPreparing
                ? "Preparing to scan for duplicates"
                : "Computing file hashes to find exact duplicate matches"
        )
        .accessibilityValue(isPreparing ? subtitle : "\(percent) percent complete, \(subtitle)")
    }

    private var beamSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.clear)
                .systemLiquidGlassBackground(cornerRadius: 16, interactive: false)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
        .beam(
            .medium,
            palette: .colorful,
            theme: .dark,
            active: isAnimationActive,
            cornerRadius: 16,
            strength: 1.0
        )
        .scanProgressReferenceBeamFallback(
            cornerRadius: 16, active: true
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    fileprivate func scanProgressReferenceBeamFallback(
        cornerRadius: CGFloat,
        active: Bool
    ) -> some View {
        overlay {
            ScanProgressReferenceBeamFallback(
                cornerRadius: cornerRadius,
                active: active
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

struct ScanProgressReferenceBeamFallback: View {
    @SortyHotReload private var hotReload
    let cornerRadius: CGFloat
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var isWindowVisible = true

    private var shouldAnimate: Bool {
        active && !reduceMotion && !reduceTransparency && isWindowVisible
            && controlActiveState != .inactive && scenePhase == .active
    }

    var body: some View {
        SwiftUI.TimelineView(
            .animation(minimumInterval: 1.0 / 12.0, paused: !shouldAnimate)
        ) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = shouldAnimate ? time / 1.96 : 0
            // Stroke-only fallback: Beam supplies interior light; the glow's
            // blurs were the dominant fallback cost.
            ReferenceBeamStroke(cornerRadius: cornerRadius, phase: phase)
                .opacity(active ? 0.82 : 0)
                .animation(.easeOut(duration: 0.6), value: active)
        }
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
    }


}
