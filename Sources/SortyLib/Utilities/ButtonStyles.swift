//
//  ButtonStyles.swift
//  Sorty
//
//  Centralized button styles for the application
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

/// Standard app button style for regular controls, with semantic tint variants.
public struct SortyStandardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var intent: SortyButtonIntent
    var isProminent: Bool
    var size: ControlSize

    public init(
        intent: SortyButtonIntent = .secondary,
        isProminent: Bool = false,
        size: ControlSize = .regular
    ) {
        self.intent = intent
        self.isProminent = isProminent
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let resolvedIntent = resolvedIntent(for: configuration)
        let accent = resolvedIntent.accent
        let radius = size == .small ? 7.0 : 8.0

        configuration.label
            .font(.system(size: fontSize, weight: isProminent ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foregroundStyle(intent: resolvedIntent, accent: accent))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(backgroundStyle(accent: accent, isPressed: pressed))
            }
            .systemLiquidGlassBackground(cornerRadius: radius)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(borderStyle(intent: resolvedIntent, accent: accent), lineWidth: isProminent ? 1.15 : 1)
            }
            .scaleEffect(pressed ? 0.975 : 1)
            .opacity(isEnabled ? 1 : 0.52)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
            .onChange(of: pressed) { _, newValue in
                if newValue {
                    if resolvedIntent == .destructive {
                        HapticFeedbackManager.shared.error()
                    } else {
                        HapticFeedbackManager.shared.tap()
                    }
                }
            }
    }

    private var fontSize: CGFloat {
        switch size {
        case .mini: return 11
        case .small: return 12
        case .large, .extraLarge: return 15
        default: return 14
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .mini: return 10
        case .small: return 12
        case .large, .extraLarge: return 20
        default: return 16
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .mini: return 4
        case .small: return 6
        case .large, .extraLarge: return 11
        default: return 9
        }
    }

    private func resolvedIntent(for configuration: Configuration) -> SortyButtonIntent {
        configuration.role == .destructive ? .destructive : intent
    }

    private func foregroundStyle(intent: SortyButtonIntent, accent: Color) -> some ShapeStyle {
        isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(intent == .secondary ? Color.primary : accent)
    }

    private func backgroundStyle(accent: Color, isPressed: Bool) -> some ShapeStyle {
        if isProminent {
            return AnyShapeStyle(accent.opacity(isPressed ? 0.78 : 0.9))
        }

        return AnyShapeStyle(Color.clear)
    }

    private func borderStyle(intent: SortyButtonIntent, accent: Color) -> some ShapeStyle {
        if isProminent {
            return AnyShapeStyle(Color.white.opacity(0.24))
        }

        return AnyShapeStyle(accent.opacity(intent == .secondary ? 0.24 : 0.38))
    }
}

/// Primary pill-shaped button style used for main actions
public struct SortyPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isSecondary: Bool = false
    var size: ControlSize = .regular
    var isGlassInteractive: Bool = true
    
    public init(
        isSecondary: Bool = false,
        size: ControlSize = .regular,
        isGlassInteractive: Bool = true
    ) {
        self.isSecondary = isSecondary
        self.size = size
        self.isGlassInteractive = isGlassInteractive
    }
    
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size == .small ? 13 : size == .large ? 18 : 15, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(isSecondary ? Color.primary : Color.white)
            .padding(.horizontal, size == .small ? 16 : size == .large ? 32 : 22)
            .padding(.vertical, size == .small ? 8 : size == .large ? 16 : 10)
            .background(
                ZStack {
                    if isSecondary {
                        Capsule()
                            .fill(Color.secondary.opacity(0.3))
                    } else {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: Color.accentColor.opacity(0.85), location: 0),
                                        .init(color: Color.accentColor, location: 0.3),
                                        .init(color: Color.accentColor.opacity(0.95), location: 0.5),
                                        .init(color: Color.accentColor, location: 0.7),
                                        .init(color: Color.accentColor.opacity(0.85), location: 1)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        Capsule()
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: Color.black.opacity(0.15), location: 0),
                                        .init(color: Color.clear, location: 0.3),
                                        .init(color: Color.clear, location: 0.7),
                                        .init(color: Color.black.opacity(0.15), location: 1)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )

                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.25),
                                        Color.white.opacity(0.1),
                                        Color.black.opacity(0.1),
                                        Color.black.opacity(0.2)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    }
                }
            )
            .systemLiquidGlassBackground(cornerRadius: 999, interactive: isGlassInteractive)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7),
                value: configuration.isPressed
            )
            .shadow(color: Color.black.opacity(isSecondary ? 0 : 0.15), radius: 8, x: 0, y: 4)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed {
                    HapticFeedbackManager.shared.tap()
                }
            }
    }
}

/// Pill button style with a caller-provided fill color for semantic actions.
public struct TintedPillButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var fillColor: Color
    var foregroundColor: Color = .white
    var size: ControlSize = .regular

    public init(fillColor: Color, foregroundColor: Color = .white, size: ControlSize = .regular) {
        self.fillColor = fillColor
        self.foregroundColor = foregroundColor
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size == .small ? 13 : 15, weight: .semibold))
            .lineLimit(1)
            .foregroundColor(foregroundColor)
            .padding(.horizontal, size == .small ? 16 : 22)
            .padding(.vertical, size == .small ? 8 : 10)
            .background(
                ZStack {
                    Capsule()
                        .fill(fillColor.opacity(configuration.isPressed ? 0.88 : 1.0))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.14),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    Capsule()
                        .strokeBorder(
                            fillColor.opacity(0.35),
                            lineWidth: 1
                        )
                }
            )
            .systemLiquidGlassBackground(cornerRadius: 999)
            .shadow(color: fillColor.opacity(0.24), radius: 8, x: 0, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, newValue in
                if newValue {
                    HapticFeedbackManager.shared.tap()
                }
            }
    }
}

/// Standard secondary button style with border and haptic feedback
public struct SortySecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: ControlSize = .regular
    var color: Color = .secondary
    
    public init(size: ControlSize = .regular, color: Color = .secondary) {
        self.size = size
        self.color = color
    }
    
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size == .small ? 12 : 14, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, size == .small ? 12 : 16)
            .padding(.vertical, size == .small ? 6 : 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
            )
            .systemLiquidGlassBackground(cornerRadius: 8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(color.opacity(0.3), lineWidth: 1)
            )
            .foregroundColor(color == .secondary ? .primary : color)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(reduceMotion ? nil : .subtleBounce, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { oldValue, newValue in
                if newValue {
                    HapticFeedbackManager.shared.tap()
                }
            }
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
            .lineLimit(1)
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

struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isVisible: $isVisible)
    }

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.observe(window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        context.coordinator.isVisible = $isVisible
        context.coordinator.observe(nsView.window)
    }

    static func dismantleNSView(_ nsView: WindowProbeView, coordinator: Coordinator) {
        coordinator.observe(nil)
        nsView.onWindowChange = nil
    }

    final class Coordinator {
        var isVisible: Binding<Bool>
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []

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
                    self?.refresh()
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
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
        }
    }

    final class WindowProbeView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
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

extension ButtonStyle where Self == TintedPillButtonStyle {
    public static func tintedPill(
        _ fillColor: Color,
        foreground foregroundColor: Color = .white,
        size: ControlSize = .regular
    ) -> TintedPillButtonStyle {
        TintedPillButtonStyle(fillColor: fillColor, foregroundColor: foregroundColor, size: size)
    }
}

extension ButtonStyle where Self == SortyStandardButtonStyle {
    public static var sortyBordered: SortyStandardButtonStyle {
        SortyStandardButtonStyle()
    }

    public static var sortyProminent: SortyStandardButtonStyle {
        SortyStandardButtonStyle(intent: .primary, isProminent: true)
    }

    public static func sortyBordered(
        intent: SortyButtonIntent = .secondary,
        size: ControlSize = .regular
    ) -> SortyStandardButtonStyle {
        SortyStandardButtonStyle(intent: intent, size: size)
    }

    public static func sortyProminent(
        intent: SortyButtonIntent = .primary,
        size: ControlSize = .regular
    ) -> SortyStandardButtonStyle {
        SortyStandardButtonStyle(intent: intent, isProminent: true, size: size)
    }
}

extension ButtonStyle where Self == SortyPrimaryButtonStyle {
    public static var sortyPrimary: SortyPrimaryButtonStyle { SortyPrimaryButtonStyle() }
    public static func sortyPrimary(
        isSecondary: Bool = false,
        size: ControlSize = .regular,
        isGlassInteractive: Bool = true
    ) -> SortyPrimaryButtonStyle {
        SortyPrimaryButtonStyle(
            isSecondary: isSecondary,
            size: size,
            isGlassInteractive: isGlassInteractive
        )
    }
}

extension ButtonStyle where Self == SortySecondaryButtonStyle {
    public static var sortySecondary: SortySecondaryButtonStyle { SortySecondaryButtonStyle() }
    public static func sortySecondary(size: ControlSize = .regular, color: Color = .secondary) -> SortySecondaryButtonStyle {
        SortySecondaryButtonStyle(size: size, color: color)
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
