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
                            .foregroundStyle(.teal)
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
                                HapticFeedbackManager.shared.selection()
                                answer(option, for: moment)
                            } label: {
                                Text(option)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity)
                                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("InlineMomentOption-\(option)")
                        }
                    }
                }
                .padding(14)
                .systemLiquidGlassBackground(cornerRadius: 14)
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
        withAnimation(.easeOut(duration: 0.2)) {
            self.moment = nil
        }
    }
}

struct TimeSavedHighlight: View {
    @SortyHotReload private var hotReload
    let value: String
    let animationValue: TimeInterval
    let usesCompactVerticalLayout: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.secondary.opacity(0.1), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Estimated time saved")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .numericTextTransition(animationValue: animationValue)
            }

            Spacer(minLength: 12)

            Text("Manual work")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, usesCompactVerticalLayout ? 7 : 10)
        .frame(maxWidth: 340)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
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

struct CompletionFeatureSuggestionCard: View {
    @SortyHotReload private var hotReload
    let icon: String
    let title: String
    let description: String
    let actionTitle: String
    let usesCompactVerticalLayout: Bool
    let onDismiss: () -> Void
    let action: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(LocalizedStringKey(description))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(description)
            }
            
            Spacer()
            
            Button(action: action) {
                Text(actionTitle)
                    .lineLimit(1)
                    .font(.subheadline.weight(.semibold))
            }
                .buttonStyle(.sortyBordered(intent: .primary, size: .small))
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
                .help("Open storage location settings")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss suggestion")
            .accessibilityLabel("Dismiss storage location suggestion")
        }
        .padding(usesCompactVerticalLayout ? 12 : 16)
        .systemLiquidGlassBackground(cornerRadius: 16)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), Color.white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 5)
        .help(description)
        .accessibilityElement(children: .contain)
    }
}
