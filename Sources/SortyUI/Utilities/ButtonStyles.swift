//
//  ButtonStyles.swift
//  Sorty
//
//  Sorty's button styles: SortyButtonStyle for every action, metal-fx for the Organize hero
//

import AppKit
import SwiftUI

import Beam

public enum SortyButtonIntent: Equatable {
    case primary
    case secondary
    case success
    case warning
    case info
    case destructive

    var accent: Color {
        switch self {
        case .primary:
            return .accentColor
        case .secondary:
            return .secondary
        case .success:
            return SortyDesignSystem.Colors.success
        case .warning:
            return SortyDesignSystem.Colors.warning
        case .info:
            return SortyDesignSystem.Colors.info
        case .destructive:
            return SortyDesignSystem.Colors.error
        }
    }
}

/// Sorty's one button style: a capsule in two weights.
///
/// Use `.sortyProminent` for the single main action in a group (filled with the
/// intent color) and `.sortyBordered` for every other action (glass with a
/// hairline border). Pick an `intent` for meaning, never an arbitrary color.
/// Size comes from `size` when given, otherwise from the environment's
/// `.controlSize`, so `.controlSize(.small)` works as it does on native buttons.
/// The Organize hero button is the only exception and uses `.metalFxPrimary`.
public struct SortyButtonStyle: ButtonStyle {
    var intent: SortyButtonIntent
    var isProminent: Bool
    var size: ControlSize?

    public init(
        intent: SortyButtonIntent = .secondary,
        isProminent: Bool = false,
        size: ControlSize? = nil
    ) {
        self.intent = intent
        self.isProminent = isProminent
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        SortyButtonBody(
            configuration: configuration,
            intent: configuration.role == .destructive ? .destructive : intent,
            isProminent: isProminent,
            size: size
        )
    }
}

private struct SortyButtonBody: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var environmentSize
    @State private var isHovering = false

    let configuration: ButtonStyleConfiguration
    let intent: SortyButtonIntent
    let isProminent: Bool
    let size: ControlSize?

    var body: some View {
        let pressed = configuration.isPressed
        let accent = intent.accent

        configuration.label
            .font(.system(size: metrics.font, weight: isProminent ? .semibold : .medium))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .foregroundStyle(foreground(accent: accent))
            .padding(.horizontal, metrics.horizontal)
            .padding(.vertical, metrics.vertical)
            .background { surface(accent: accent, isPressed: pressed) }
            .overlay {
                Capsule()
                    .strokeBorder(border(accent: accent), lineWidth: 1)
            }
            .contentShape(Capsule())
            .shadow(
                color: accent.opacity(isProminent && isEnabled ? (isHovering ? 0.28 : 0.18) : 0),
                radius: pressed ? 2 : 6,
                y: pressed ? 1 : 2
            )
            .scaleEffect(pressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.52)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
            .onHover { isHovering = $0 && isEnabled }
            .onChange(of: pressed) { _, isPressed in
                guard isPressed else { return }
                if intent == .destructive {
                    HapticFeedbackManager.shared.error()
                } else {
                    HapticFeedbackManager.shared.tap()
                }
            }
    }

    @ViewBuilder
    private func surface(accent: Color, isPressed: Bool) -> some View {
        if isProminent {
            Capsule()
                .fill(accent.opacity(isPressed ? 0.82 : 1))
                .overlay {
                    Capsule().fill(Color.white.opacity(isHovering && !isPressed ? 0.1 : 0))
                }
        } else {
            Capsule()
                .fill(Color.primary.opacity(isPressed ? 0.10 : (isHovering ? 0.06 : 0)))
                .systemLiquidGlassBackground(cornerRadius: SortyDesignSystem.Radius.capsule)
        }
    }

    private var metrics: (font: CGFloat, horizontal: CGFloat, vertical: CGFloat) {
        switch size ?? environmentSize {
        case .mini: return (11, 10, 4)
        case .small: return (12, 14, 6)
        case .large: return (16, 24, 12)
        case .extraLarge: return (19, 34, 15)
        default: return (14, 18, 9)
        }
    }

    private func foreground(accent: Color) -> AnyShapeStyle {
        if isProminent { return AnyShapeStyle(.white) }
        return AnyShapeStyle(intent == .secondary ? Color.primary : accent)
    }

    private func border(accent: Color) -> AnyShapeStyle {
        if isProminent { return AnyShapeStyle(Color.white.opacity(0.22)) }
        return AnyShapeStyle(accent.opacity(intent == .secondary ? 0.24 : 0.4))
    }
}

/// SwiftUI port of metal-fx's chromatic liquid-metal button treatment.
public struct MetalFxPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var isPaused: Bool
    var usesSubtleIdleBeam: Bool
    @State private var isHovering = false

    public init(isPaused: Bool = false, usesSubtleIdleBeam: Bool = false) {
        self.isPaused = isPaused
        self.usesSubtleIdleBeam = usesSubtleIdleBeam
    }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed

        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background {
                MetalFxPillSurface(
                    isPressed: pressed,
                    isHovering: isHovering,
                    isEnabled: isEnabled,
                    isPaused: isPaused,
                    usesSubtleIdleBeam: usesSubtleIdleBeam,
                    colorScheme: colorScheme,
                    reduceMotion: reduceMotion
                )
            }
            .contentShape(Capsule())
            .shadow(
                color: Color(red: 0.65, green: 0.91, blue: 1).opacity(isEnabled ? (isHovering ? 0.24 : 0.14) : 0.03),
                radius: pressed ? 4 : (isHovering ? 12 : 8),
                y: pressed ? 1 : (isHovering ? 5 : 3)
            )
            .scaleEffect(pressed ? 0.975 : 1)
            .opacity(isEnabled ? 1 : 0.56)
            .animation(.easeOut(duration: 0.14), value: pressed)
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    HapticFeedbackManager.shared.selection()
                }
            }
            .onChange(of: pressed) { _, newValue in
                if newValue {
                    HapticFeedbackManager.shared.tap()
                }
            }
    }
}

private struct MetalFxPillSurface: View {
    @SortyHotReload private var hotReload
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var isWindowVisible = true
    @State private var accumulatedAnimationTime: TimeInterval = 0
    @State private var animationStartedAt: TimeInterval?
    let isPressed: Bool
    let isHovering: Bool
    let isEnabled: Bool
    let isPaused: Bool
    let usesSubtleIdleBeam: Bool
    let colorScheme: ColorScheme
    let reduceMotion: Bool

    private var isIntensified: Bool {
        isHovering || isPressed
    }

    private var idleBeamOpacity: Double {
        usesSubtleIdleBeam && !isIntensified ? 0.42 : 1.0
    }

    private var shouldAnimateSurface: Bool {
        !isPaused && isEnabled && !reduceMotion && isWindowVisible
            && controlActiveState != .inactive && scenePhase == .active
    }

    private var animationFrameInterval: TimeInterval {
        isIntensified ? 1.0 / 30.0 : 1.0 / 10.0
    }

    var body: some View {
        ZStack {
            Capsule()
                .fill(baseFill)

            animatedLighting

            stationaryLighting
        }
        .clipShape(Capsule())
        .compositingGroup()
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .onAppear {
            if animationStartedAt == nil, accumulatedAnimationTime == 0 {
                accumulatedAnimationTime = Date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 12)
            }
            updateAnimationClock(isRunning: shouldAnimateSurface)
        }
        .onChange(of: shouldAnimateSurface) { _, isRunning in
            updateAnimationClock(isRunning: isRunning)
        }
    }

    @ViewBuilder
    private var animatedLighting: some View {
        if shouldAnimateSurface {
            SwiftUI.TimelineView(.animation(minimumInterval: animationFrameInterval)) { timeline in
                lighting(phase: phase(at: timeline.date.timeIntervalSinceReferenceDate))
            }
        } else {
            lighting(
                phase: !isWindowVisible && !reduceMotion
                    ? phase(at: Date.timeIntervalSinceReferenceDate)
                    : 0
            )
        }
    }

    private func lighting(phase: Double) -> some View {
        ZStack {
            ring(phase: phase)
            stationaryBorder
            movingCatchlight(phase: phase)
                .opacity(usesSubtleIdleBeam && !isIntensified ? 0.38 : 1.0)
        }
    }

    private func phase(at time: TimeInterval) -> Double {
        // Keep phase values small. Feeding an ever-growing uptime value into
        // AngularGradient eventually loses precision and can render a dark seam.
        let elapsed = animationStartedAt.map { max(0, time - $0) } ?? 0
        return (accumulatedAnimationTime + elapsed).truncatingRemainder(dividingBy: 12) / 12
    }

    private func updateAnimationClock(isRunning: Bool) {
        let now = Date.timeIntervalSinceReferenceDate
        if isRunning {
            if animationStartedAt == nil {
                animationStartedAt = now
            }
        } else if let animationStartedAt {
            accumulatedAnimationTime = (
                accumulatedAnimationTime + max(0, now - animationStartedAt)
            ).truncatingRemainder(dividingBy: 12)
            self.animationStartedAt = nil
        }
    }

    private func ring(phase: Double) -> some View {
        Capsule()
            .strokeBorder(
                AngularGradient(
                    colors: ringColors,
                    center: .center,
                    angle: .degrees(phase * 360)
                ),
                lineWidth: isIntensified ? 3.2 : 1.6
            )
            .blur(radius: 0.35)
            .opacity(idleBeamOpacity)
    }

    private var stationaryBorder: some View {
        Capsule()
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.30 : 0.38),
                        Color.white.opacity(0.08),
                        Color.black.opacity(colorScheme == .dark ? 0.28 : 0.10)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
    }

    private var stationaryLighting: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(isPressed ? 0.08 : (isHovering ? 0.16 : (usesSubtleIdleBeam ? 0.08 : 0.11))),
                        Color.clear,
                        Color.black.opacity(isPressed ? 0.22 : 0.13)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .padding(3)
    }

    private var baseFill: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.31, blue: 0.45),
                Color(red: 0.94, green: 0.20, blue: 0.36),
                Color(red: 0.72, green: 0.15, blue: 0.36)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var ringColors: [Color] {
        if colorScheme == .dark {
            return [
                .black.opacity(0.72),
                Color(red: 0.67, green: 0.91, blue: 1.00),
                Color(red: 0.77, green: 1.00, blue: 0.62),
                Color(red: 0.97, green: 0.53, blue: 0.55),
                .black.opacity(0.82),
                Color(red: 1.00, green: 0.99, blue: 0.76),
                .black.opacity(0.72)
            ]
        }

        return [
            Color(red: 1.00, green: 0.95, blue: 0.95),
            Color(red: 1.00, green: 0.98, blue: 0.82),
            Color(red: 0.69, green: 0.91, blue: 0.74),
            Color(red: 0.62, green: 0.63, blue: 0.65),
            Color(red: 0.88, green: 0.93, blue: 1.00),
            .white,
            Color(red: 1.00, green: 0.95, blue: 0.95)
        ]
    }

    private func movingCatchlight(phase: Double) -> some View {
        let travel = (sin(phase * 2 * .pi) + 1) / 2

        return Capsule()
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: max(0, travel - 0.22)),
                        .init(color: Color.white.opacity(isHovering ? 0.72 : 0.52), location: travel),
                        .init(color: Color(red: 0.67, green: 0.91, blue: 1).opacity(0.28), location: min(1, travel + 0.18)),
                        .init(color: .clear, location: min(1, travel + 0.30))
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: isHovering ? 6 : 5
            )
            .blur(radius: 5)
            .opacity(isPressed ? 0.35 : 0.72)
    }
}

package struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    package init(isVisible: Binding<Bool>) {
        self._isVisible = isVisible
    }

    package func makeCoordinator() -> Coordinator {
        Coordinator(isVisible: $isVisible)
    }

    package func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.observe(window)
        }
        return view
    }

    package func updateNSView(_ nsView: WindowProbeView, context: Context) {
        context.coordinator.isVisible = $isVisible
        context.coordinator.observe(nsView.window)
    }

    package static func dismantleNSView(_ nsView: WindowProbeView, coordinator: Coordinator) {
        coordinator.observe(nil)
        nsView.onWindowChange = nil
    }

    @MainActor
    package final class Coordinator: NSObject {
        var isVisible: Binding<Bool>
        private weak var observedWindow: NSWindow?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        init(isVisible: Binding<Bool>) {
            self.isVisible = isVisible
        }

        func observe(_ window: NSWindow?) {
            guard observedWindow !== window else { return }
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
            observedWindow = window
            guard let window else {
                isVisible.wrappedValue = false
                return
            }
            for name in [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.refresh()
                    }
                })
            }
            refresh()
        }

        private func refresh() {
            guard let window = observedWindow else {
                isVisible.wrappedValue = false
                return
            }
            isVisible.wrappedValue = window.isVisible
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        }

        deinit {
            // Deinit is nonisolated and can run off the main thread.
            // NotificationCenter removal is thread-safe, so observers are
            // removed directly instead of assuming main-actor isolation.
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
        }
    }

    package final class WindowProbeView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        package override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}

public enum OnboardingBeamBorderVariant: Equatable {
    case standard
    case featured
    case info
    case success
    case warning
    case destructive

    fileprivate var palette: BeamPalette {
        switch self {
        case .standard:
            return .colorful
        case .featured, .warning, .destructive:
            return .sunset
        case .info, .success:
            return .ocean
        }
    }

    fileprivate var strength: Double {
        switch self {
        case .standard:
            return 0.86
        case .featured, .destructive:
            return 1
        case .info:
            return 0.9
        case .success:
            return 0.92
        case .warning:
            return 0.96
        }
    }
}

public extension View {
    /// Applies Beam's button-sized capsule treatment to prominent pill controls.
    func onboardingBeamBorder(
        variant: OnboardingBeamBorderVariant = .standard,
        active: Bool = true,
        isIntensified: Bool = false,
        includesInteriorGlow: Bool = false
    ) -> some View {
        overlay {
            OnboardingBeamBorder(
                variant: variant,
                active: active,
                isIntensified: isIntensified,
                includesInteriorGlow: includesInteriorGlow
            )
        }
    }
}

private struct OnboardingBeamBorder: View {
    @SortyHotReload private var hotReload
    let variant: OnboardingBeamBorderVariant
    let active: Bool
    let isIntensified: Bool
    let includesInteriorGlow: Bool

    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Capsule()
            .fill(.clear)
            .beam(
                .small,
                palette: variant.palette,
                theme: .dark,
                active: active && controlActiveState != .inactive,
                shape: .capsule,
                strength: min(1, variant.strength * (isIntensified ? 1.12 : 1)),
                lensStrength: includesInteriorGlow ? (isIntensified ? 3 : 2) : 0
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension ButtonStyle where Self == SortyButtonStyle {
    /// Secondary actions: glass capsule with a hairline border.
    public static var sortyBordered: SortyButtonStyle {
        SortyButtonStyle()
    }

    /// The main action in a group: filled capsule.
    public static var sortyProminent: SortyButtonStyle {
        SortyButtonStyle(intent: .primary, isProminent: true)
    }

    public static func sortyBordered(
        intent: SortyButtonIntent = .secondary,
        size: ControlSize? = nil
    ) -> SortyButtonStyle {
        SortyButtonStyle(intent: intent, size: size)
    }

    public static func sortyProminent(
        intent: SortyButtonIntent = .primary,
        size: ControlSize? = nil
    ) -> SortyButtonStyle {
        SortyButtonStyle(intent: intent, isProminent: true, size: size)
    }
}

extension ButtonStyle where Self == MetalFxPrimaryButtonStyle {
    public static func metalFxPrimary(
        isPaused: Bool = false,
        usesSubtleIdleBeam: Bool = false
    ) -> MetalFxPrimaryButtonStyle {
        MetalFxPrimaryButtonStyle(isPaused: isPaused, usesSubtleIdleBeam: usesSubtleIdleBeam)
    }
}
