import AppKit
import SwiftUI
import SortyCore

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
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var isWindowVisible = true

    private let bandWidthRatio: CGFloat = 0.42
    private let shimmerAngle = Angle(degrees: 18)
    private let shimmerSpeed: Double = 1.15

    private var shimmerPaused: Bool {
        !isLoading || reduceMotion || !isWindowVisible || controlActiveState == .inactive
            || scenePhase != .active
    }

    func body(content: Content) -> some View {
        if isLoading, !reduceMotion {
            content
                .overlay {
                    GeometryReader { geometry in
                        let width = max(geometry.size.width, 1)
                        let height = max(geometry.size.height, 1)
                        let bandWidth = width * bandWidthRatio
                        let travelDistance = width + (bandWidth * 2)

                        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: shimmerPaused)) { context in
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
                .background(WindowVisibilityReader(isVisible: $isWindowVisible))
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
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var isWindowVisible = true

    private let bandWidthRatio: CGFloat = 0.62
    private let shimmerAngle = Angle(degrees: 8)
    private let shimmerSpeed: Double = 0.42

    private var clampedIntensity: Double {
        min(max(intensity, 0.5), 1.7)
    }

    private var textShimmerPaused: Bool {
        !isLoading || reduceMotion || !isWindowVisible || controlActiveState == .inactive
            || scenePhase != .active
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
                            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: textShimmerPaused)) { context in
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
                .background(WindowVisibilityReader(isVisible: $isWindowVisible))
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

/// Animated loading dots view.
/// How it stays cheap: a single 12fps timeline shared by all dots, paused
/// offscreen or while the window is inactive. Dots are pure opacity/offset
/// with no blur passes.
public struct LoadingDotsView: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
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
            SwiftUI.TimelineView(
                .animation(
                    minimumInterval: 1.0 / 12.0,
                    paused: !isWindowVisible || controlActiveState == .inactive
                )
            ) { timeline in
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

/// Spinning loading indicator with bounce.
/// How it stays cheap: a single 12fps timeline (matching LoadingDotsView),
/// paused offscreen or while the window is inactive.
public struct BouncingSpinner: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
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
            SwiftUI.TimelineView(
                .animation(
                    minimumInterval: 1.0 / 12.0,
                    paused: !isWindowVisible || controlActiveState == .inactive
                )
            ) { timeline in
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
