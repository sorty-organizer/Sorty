//
//  Constants.swift
//  Sorty
//
//  App-wide constants
//

import Foundation

enum Constants {
    static let appGroupIdentifier = "group.com.sorty.app"
    static let maxPreviewVersions = 5
}

extension Notification.Name {
    public static let organizationDidStart = Notification.Name("OrganizationDidStart")
    public static let organizationDidFinish = Notification.Name("OrganizationDidFinish")
    public static let organizationDidRevert = Notification.Name("OrganizationDidRevert")
    public static let forceQuitSorty = Notification.Name("ForceQuitSorty")
    
    /// Triggered when the user requests to delete all usage data
    public static let clearAllUsageData = Notification.Name("clearAllUsageData")
}




import SwiftUI
import AppKit

// MARK: - Haptic Feedback Manager

/// Manages haptic feedback for user interactions on macOS
@MainActor
public class HapticFeedbackManager {
    @MainActor
    public static let shared = HapticFeedbackManager()

    private init() {}

    /// Performs haptic feedback for button taps and general interactions
    public func tap() {
        performEmphasizedPulse()
    }

    /// Performs haptic feedback for successful actions
    public func success() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Performs haptic feedback for alignment or snapping
    public func alignment() {
        performLightAlignmentHaptic()
    }

    /// Performs haptic feedback for errors or warnings
    public func error() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Performs haptic feedback for selection changes
    public func selection() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    /// Performs a subtle light haptic for hover transitions and gentle state changes.
    public func light() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    /// Emits a short two-step pulse that is more perceptible than a single generic tap.
    private func performEmphasizedPulse() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    private func performLightAlignmentHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }
}

// MARK: - Haptic Sequence Manager

/// Plays timed haptic sequences that follow visual animations (e.g., shimmer left-to-right).
@MainActor
public final class HapticSequenceManager {
    public static let shared = HapticSequenceManager()
    private var activeTask: Task<Void, Never>?
    private var lastWaveStartAt: Date = .distantPast
    
    private init() {}
    
    /// Plays a left-to-right haptic wave whose cadence mirrors an ease-in-out shimmer.
    public func playShimmerWave(
        tapCount: Int = 5,
        duration: TimeInterval = 0.65,
        minimumInterval: TimeInterval = 0.2
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastWaveStartAt) >= minimumInterval else { return }
        lastWaveStartAt = now

        activeTask?.cancel()
        activeTask = Task { @MainActor in
            let clampedTapCount = max(tapCount, 2)
            var previousTimelinePhase = 0.0

            for i in 0..<clampedTapCount {
                guard !Task.isCancelled else { return }

                if i > 0 {
                    let spatialPhase = Double(i) / Double(clampedTapCount - 1)
                    let timelinePhase = easeInOutTimelinePhase(for: spatialPhase)
                    let delay = max(0, duration * (timelinePhase - previousTimelinePhase))
                    previousTimelinePhase = timelinePhase

                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }

                guard !Task.isCancelled else { return }

                let feedback: NSHapticFeedbackManager.FeedbackPattern =
                    i == clampedTapCount - 1 ? .levelChange : .alignment
                NSHapticFeedbackManager.defaultPerformer.perform(feedback, performanceTime: .now)
            }
        }
    }

    /// Inverts a smooth ease-in-out curve so evenly spaced haptic positions
    /// arrive slowly at each edge and more quickly through the center.
    private func easeInOutTimelinePhase(for spatialPhase: Double) -> Double {
        let clampedPhase = min(max(spatialPhase, 0), 1)
        return 0.5 - sin(asin(1 - 2 * clampedPhase) / 3)
    }
    
    /// Plays a single emphasis haptic for a notable UI event (new insight, popup appearing).
    public func playEventPulse() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
    
    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }
}

// MARK: - Custom Animations

extension Animation {
    /// Smooth spring animation for page transitions - subtle
    public static var pageTransition: Animation {
        .easeOut(duration: 0.2)
    }

    /// Restrained spring animation for modal content settling into place.
    public static var modalBounce: Animation {
        .spring(response: 0.38, dampingFraction: 0.84)
    }

    /// Subtle bounce for interactive elements
    public static var subtleBounce: Animation {
        .spring(response: 0.24, dampingFraction: 0.78)
    }
}
/// Gives custom modal content a restrained scale-and-rise entrance.
struct ModalBounceModifier: ViewModifier {
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion || appeared ? 1.0 : 0.985)
            .offset(y: reduceMotion || appeared ? 0 : 8)
            .opacity(reduceMotion || appeared ? 1.0 : 0)
            .onAppear {
                guard !reduceMotion else {
                    appeared = true
                    return
                }

                withAnimation(.modalBounce) {
                    appeared = true
                }
            }
    }
}

/// Shimmer loading effect modifier with smooth continuous animation
struct ShimmerModifier: ViewModifier {
    let isLoading: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let bandWidthRatio: CGFloat = 0.42
    private let shimmerAngle = Angle(degrees: 18)
    private let shimmerSpeed: Double = 1.15

    func body(content: Content) -> some View {
        if isLoading, !reduceMotion {
            content
                .overlay {
                    GeometryReader { geometry in
                        let width = max(geometry.size.width, 1)
                        let height = max(geometry.size.height, 1)
                        let bandWidth = width * bandWidthRatio
                        let travelDistance = width + (bandWidth * 2)

                        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isLoading)) { context in
                            let elapsed = context.date.timeIntervalSinceReferenceDate * shimmerSpeed
                            let progress = elapsed - floor(elapsed)
                            let offsetX = (progress * travelDistance) - bandWidth

                            LinearGradient(
                                colors: [
                                    .clear,
                                    .white.opacity(0.6),
                                    .white.opacity(0.28),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: bandWidth, height: height * 2.2)
                            .rotationEffect(shimmerAngle)
                            .offset(x: offsetX)
                        }
                    }
                }
                .blendMode(.screen)
                .mask(content)
                .drawingGroup(opaque: false)
        } else {
            content
        }
    }
}

/// Text-specific shimmer that preserves base legibility and adds a subtle moving highlight.
struct TextShimmerModifier: ViewModifier {
    let isLoading: Bool
    let phaseOffset: Double
    let intensity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private let bandWidthRatio: CGFloat = 0.62
    private let shimmerAngle = Angle(degrees: 8)
    private let shimmerSpeed: Double = 0.42

    private var clampedIntensity: Double {
        min(max(intensity, 0.5), 1.7)
    }

    func body(content: Content) -> some View {
        if isLoading {
            content
                .overlay {
                    GeometryReader { geometry in
                        let width = max(geometry.size.width, 1)
                        let height = max(geometry.size.height, 1)
                        let bandWidth = width * bandWidthRatio
                        let travelDistance = width + (bandWidth * 2.5)

                        if reduceMotion {
                            LinearGradient(
                                colors: [
                                    .clear,
                                    SortyDesignSystem.Colors.resolvedAccent.opacity((colorScheme == .dark ? 0.2 : 0.14) * clampedIntensity),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: bandWidth * 1.2, height: height * 1.8)
                            .rotationEffect(shimmerAngle)
                            .offset(x: (width - bandWidth) * 0.18)
                        } else {
                            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isLoading)) { context in
                                let elapsed = (context.date.timeIntervalSinceReferenceDate + phaseOffset) * shimmerSpeed
                                let progress = elapsed - floor(elapsed)
                                let easedProgress = progress * progress * (3 - (2 * progress))
                                let offsetX = (easedProgress * travelDistance) - (bandWidth * 1.2)

                                let accentGlow = (colorScheme == .dark ? 0.38 : 0.28) * clampedIntensity
                                let whiteGlow = (colorScheme == .dark ? 0.72 : 0.52) * clampedIntensity

                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: SortyDesignSystem.Colors.resolvedAccent.opacity(accentGlow * 0.55), location: 0.2),
                                        .init(color: .white.opacity(whiteGlow * 0.64), location: 0.39),
                                        .init(color: .white.opacity(whiteGlow), location: 0.5),
                                        .init(color: .white.opacity(whiteGlow * 0.64), location: 0.61),
                                        .init(color: SortyDesignSystem.Colors.resolvedAccent.opacity(accentGlow * 0.55), location: 0.8),
                                        .init(color: .clear, location: 1)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: bandWidth, height: height * 2.2)
                                .rotationEffect(shimmerAngle)
                                .offset(x: offsetX)
                                .blendMode(.plusLighter)
                            }
                        }
                    }
                }
                .mask(content)
                .drawingGroup(opaque: false)
        } else {
            content
        }
    }
}

/// Animated appearance modifier for list items - subtle version
struct AnimatedAppearanceModifier: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .offset(y: reduceMotion || appeared ? 0 : 8)
            .opacity(reduceMotion || appeared ? 1 : 0.4)
            .onAppear {
                guard !reduceMotion else {
                    appeared = true
                    return
                }
                withAnimation(.easeOut(duration: 0.2).delay(delay)) {
                    appeared = true
                }
            }
            .onChange(of: reduceMotion) { _, isEnabled in
                if isEnabled {
                    appeared = true
                }
            }
    }
}

// MARK: - View Extensions

extension View {
    /// Applies modal bounce animation on appear
    public func modalBounce() -> some View {
        modifier(ModalBounceModifier())
    }

    /// Applies shimmer loading effect
    public func shimmer(isLoading: Bool) -> some View {
        modifier(ShimmerModifier(isLoading: isLoading))
    }

    /// Applies a subtle shimmer optimized for text legibility.
    public func textShimmer(isLoading: Bool, phaseOffset: Double = 0, intensity: Double = 1.0) -> some View {
        modifier(TextShimmerModifier(isLoading: isLoading, phaseOffset: phaseOffset, intensity: intensity))
    }

    /// Applies animated appearance with stagger delay
    public func animatedAppearance(delay: Double = 0) -> some View {
        modifier(AnimatedAppearanceModifier(delay: delay))
    }
}

// MARK: - Transition Helpers

/// Namespace for commonly used transitions - subtle versions
@MainActor
public enum TransitionStyles {
    @MainActor
    public static let slideFromRight = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .offset(x: 20)),
        removal: .opacity.combined(with: .offset(x: -20))
    )

    public static let scaleAndFade = AnyTransition.asymmetric(
        insertion: .scale(scale: 0.97).combined(with: .opacity),
        removal: .scale(scale: 0.97).combined(with: .opacity)
    )
}

// MARK: - Loading Indicator Views

/// Animated loading dots view
public struct LoadingDotsView: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isWindowVisible = true

    let dotCount: Int
    let dotSize: CGFloat
    let color: Color
    let speed: Double

    public init(dotCount: Int = 3, dotSize: CGFloat = 8, color: Color = .accentColor, speed: Double = 2.4) {
        self.dotCount = dotCount
        self.dotSize = dotSize
        self.color = color
        self.speed = speed
    }

    public var body: some View {
        if reduceMotion {
            dots(at: 0)
        } else {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !isWindowVisible)) { timeline in
                dots(at: timeline.date.timeIntervalSinceReferenceDate)
            }
            .drawingGroup(opaque: false)
            .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        }
    }

    private func dots(at time: TimeInterval) -> some View {
        HStack(spacing: dotSize * 0.8) {
            ForEach(0..<dotCount, id: \.self) { index in
                let phase = reduceMotion ? Double(index) * 0.85 : time * speed + (Double(index) * 0.85)
                let wave = (sin(phase) + 1) / 2
                Circle()
                    .fill(color)
                    .frame(width: dotSize, height: dotSize)
                    .opacity(0.35 + (0.5 * wave))
                    .offset(y: reduceMotion ? 0 : -dotSize * 0.3 * wave)
            }
        }
        .frame(height: dotSize * 1.6, alignment: .center)
        .accessibilityHidden(true)
    }
}

/// Spinning loading indicator with bounce
public struct BouncingSpinner: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isWindowVisible = true

    let size: CGFloat
    let color: Color

    public init(size: CGFloat = 24, color: Color = .accentColor) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        if reduceMotion {
            spinner(rotation: 0, scale: 1)
        } else {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isWindowVisible)) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let rotation = elapsed.truncatingRemainder(dividingBy: 0.8) / 0.8 * 360
                let scale = CGFloat(0.95 + (sin(elapsed * .pi * 2 / 0.8) + 1) * 0.025)
                spinner(rotation: rotation, scale: scale)
            }
            .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        }
    }

    private func spinner(rotation: Double, scale: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotation))
            .scaleEffect(scale)
            .accessibilityHidden(true)
    }
}
