import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import os

// MARK: - Progress Bar

struct OnboardingIconSliver: View {
    @SortyHotReload private var hotReload
    let systemName: String
    let color: Color
    let fontSize: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweepProgress: CGFloat = 0
    private let sliverDuration: TimeInterval = 1.25

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: fontSize))
            .foregroundStyle(color)
            .modifier(
                OnboardingIconSweep(
                    progress: reduceMotion ? 0.5 : sweepProgress,
                    reduceMotion: reduceMotion,
                    tint: color
                )
            )
            .onAppear {
                guard !reduceMotion else { return }
                sweepProgress = 0
                HapticSequenceManager.shared.playShimmerWave(duration: sliverDuration)
                withAnimation(.easeInOut(duration: sliverDuration)) {
                    sweepProgress = 1
                }
            }
            .accessibilityHidden(false)
    }
}

struct OnboardingIconSweep: ViewModifier, Animatable {
    var progress: CGFloat
    let reduceMotion: Bool
    let tint: Color

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let sweep = min(max(progress, 0), 1)
        let envelope = sin(sweep * .pi)
        let glow = reduceMotion ? 0 : envelope * envelope
        let overlayOpacity = Double(glow)

        return content
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: tint.opacity(0.25), location: 0),
                        .init(color: tint, location: max(0, sweep - 0.16)),
                        .init(color: .white, location: sweep),
                        .init(color: tint, location: min(1, sweep + 0.16)),
                        .init(color: tint.opacity(0.25), location: 1)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .mask { content }
                .opacity(overlayOpacity)
                .shadow(color: tint.opacity(glow * 0.8), radius: glow * 13)
            }
            .shadow(color: tint.opacity(glow * 0.52), radius: glow * 11)
    }
}

struct OnboardingProgressBar: View {
    @SortyHotReload private var hotReload
    let currentStep: OnboardingStep

    @MainActor
    private var activeSteps: [OnboardingStep] {
        OnboardingStep.allCases
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<activeSteps.count, id: \.self) { index in
                let step = activeSteps[index]

                if index > 0 {
                    Capsule(style: .continuous)
                        .fill(
                            step.rawValue <= currentStep.rawValue
                                ? SortyDesignSystem.Colors.resolvedAccent : Color.secondary.opacity(0.2)
                        )
                        .frame(width: 56, height: 2)
                        .padding(.top, 11)
                }

                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(
                                step.rawValue <= currentStep.rawValue
                                    ? SortyDesignSystem.Colors.resolvedAccent : Color.secondary.opacity(0.2)
                            )
                            .frame(width: 24, height: 24)

                        let isComplete = step.rawValue < currentStep.rawValue

                        if isComplete {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(
                                    step.rawValue <= currentStep.rawValue ? .white : .secondary)
                        }
                    }

                    Text(LocalizedStringKey(step.title))
                        .font(.caption2)
                        .foregroundStyle(step == currentStep ? .primary : .secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 20)
                }
                .frame(width: 82)
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }
}
