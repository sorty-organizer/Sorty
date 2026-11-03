import SwiftUI

// One follow-up question for uncertain placements. Dismissible, max once
// per session (enforced by the observer's consume path).
struct InlineLearningMomentCard: View {
    @SortyHotReload private var hotReload
    @ObservedObject var observer: ContinuousLearningObserver
    @EnvironmentObject var learningsManager: LearningsManager

    @State private var moment: InlineLearningMoment?

    var body: some View {
        Group {
            if let moment {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.bubble.fill")
                            .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                        Text("Quick question")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button {
                            HapticFeedbackManager.shared.tap()
                            observer.dismissPendingLearningMoment()
                            self.moment = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("InlineMomentDismissButton")
                        .accessibilityLabel("Dismiss question")
                    }
                    Text(moment.prompt)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                        ForEach(moment.options, id: \.self) { option in
                            Button {
                                answer(option, for: moment)
                            } label: {
                                Text(option)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.sortyChip())
                            .accessibilityIdentifier("InlineMomentOption-\(option)")
                        }
                    }
                }
                .sortyCard(padding: 14)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("InlineMomentCard")
                .accessibilityLabel("Follow-up question: \(moment.prompt)")
            }
        }
        .onAppear { presentIfAvailable() }
        .onReceive(observer.$pendingLearningMoment) { _ in presentIfAvailable() }
    }

    private func presentIfAvailable() {
        guard moment == nil else { return }
        guard observer.pendingLearningMoment != nil else { return }
        moment = observer.consumePendingLearningMoment()
        if moment != nil {
            HapticFeedbackManager.shared.selection()
        }
    }

    private func answer(_ option: String, for moment: InlineLearningMoment) {
        let answer = InlineLearningMomentAnswer(
            momentId: moment.id,
            sessionId: moment.sessionId,
            selectedOption: option
        )
        Task { await learningsManager.recordInlineLearningMomentAnswer(answer) }
        HapticFeedbackManager.shared.success()
        withAnimation(.sortyFade) {
            self.moment = nil
        }
    }
}

/// One quiet line under the completion subtitle, e.g. "About 37 minutes of manual work saved".
struct TimeSavedHighlight: View {
    @SortyHotReload private var hotReload
    let value: String
    let animationValue: TimeInterval

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(SortyDesignSystem.Colors.success)
                .accessibilityHidden(true)
            Text("About \(Text(value).monospacedDigit().foregroundStyle(.primary)) of manual work saved")
                .numericTextTransition(animationValue: animationValue)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Estimated manual time saved: \(value)")
    }
}

struct CompletionBadgeGlow: View {
    @SortyHotReload private var hotReload
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            color.opacity(0.34),
                            color.opacity(0.16),
                            color.opacity(0)
                        ],
                        center: .center,
                        startRadius: 22,
                        endRadius: 56
                    )
                )
                .frame(width: 112, height: 112)
                .scaleEffect(isBreathing ? 1.08 : 0.96)
                .opacity(isBreathing ? 0.9 : 0.68)

            Circle()
                .stroke(color.opacity(0.32), lineWidth: 9)
                .frame(width: 68, height: 68)
                .blur(radius: 10)
                .scaleEffect(isBreathing ? 1.04 : 0.98)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.16),
                            color.opacity(0.08),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.34, y: 0.3),
                        startRadius: 0,
                        endRadius: 46
                    )
                )
                .frame(width: 88, height: 88)
                .blur(radius: 8)
        }
        .frame(width: 112, height: 112)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }

            withAnimation(.easeInOut(duration: 1.4).repeatCount(2, autoreverses: true)) {
                isBreathing = true
            }
        }
    }
}

struct ConfettiParticlesView: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Particle: Identifiable {
        let id = UUID()
        let angle: Double
        let distance: CGFloat
        let color: Color
        let size: CGFloat
        let delay: Double
    }
    
    @State private var burstedParticles: Set<UUID> = []
    
    private let particles: [Particle] = {
        let colors: [Color] = [.green, .blue, .purple, .orange, .yellow, .mint]
        return (0..<12).map { i in
            Particle(
                angle: Double(i) * 30 + Double.random(in: -10...10),
                distance: CGFloat.random(in: 50...80),
                color: colors[i % colors.count],
                size: CGFloat.random(in: 4...7),
                delay: Double.random(in: 0...0.25)
            )
        }
    }()
    
    var body: some View {
        ZStack {
            ForEach(particles) { particle in
                let isBursted = burstedParticles.contains(particle.id)
                Circle()
                    .fill(particle.color)
                    .frame(width: particle.size, height: particle.size)
                    .offset(
                        x: isBursted ? cos(particle.angle * .pi / 180) * particle.distance : 0,
                        y: isBursted ? sin(particle.angle * .pi / 180) * particle.distance : 0
                    )
                    .opacity(isBursted ? 0 : 0.8)
                    .scaleEffect(isBursted ? 0.3 : 1)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            for particle in particles {
                _ = withAnimation(.easeOut(duration: Double.random(in: 0.5...0.9)).delay(particle.delay)) {
                    burstedParticles.insert(particle.id)
                }
            }
        }
    }
}

/// Slim, dismissible tip row at the bottom of the completion screen.
struct CompletionFeatureSuggestionCard: View {
    @SortyHotReload private var hotReload
    let icon: String
    let title: String
    let description: String
    let actionTitle: String
    let onDismiss: () -> Void
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(SortyDesignSystem.Colors.info)
                .accessibilityHidden(true)

            Text(LocalizedStringKey(title))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Button(action: action) {
                Text(actionTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Open storage location settings")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss suggestion")
            .accessibilityLabel("Dismiss storage location suggestion")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .sortyInsetSurface(cornerRadius: SortyDesignSystem.Radius.lg)
        .help(description)
        .accessibilityElement(children: .contain)
    }
}
