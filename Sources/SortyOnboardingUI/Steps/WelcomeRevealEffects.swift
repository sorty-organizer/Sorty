import AppKit
import AVFoundation
import Combine
import SwiftUI

// MARK: - Animated Gradient Background

struct AnimatedGradientBackground: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var isWindowVisible = true
    var revealed: Bool = true
    var motionEnabled: Bool = true
    var color1: Color = .purple
    var color2: Color = .blue
    var color3: Color = .teal

    private var motionPaused: Bool {
        !motionEnabled || reduceMotion || reduceTransparency || !isWindowVisible
            || controlActiveState == .inactive || scenePhase != .active
    }

    // How ambient blobs are drawn: one Canvas pass inside a single 30fps
    // timeline. Radial gradients already fade to clear, so no blur passes
    // are needed. A frozen timeline frame doubles as the reduced-motion pose.
    var body: some View {
        SwiftUI.TimelineView(
            .animation(minimumInterval: 1.0 / 30.0, paused: motionPaused)
        ) { timeline in
            Canvas { context, size in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let drift = reduceMotion || reduceTransparency ? 0 : seconds * .pi * 2 / 12
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                Self.blob(
                    context: &context,
                    center: CGPoint(
                        x: center.x + 50 * sin(drift),
                        y: center.y - 30 * cos(drift)
                    ),
                    radius: 200,
                    color: color1.opacity(revealed ? 0.3 : 0)
                )
                Self.blob(
                    context: &context,
                    center: CGPoint(
                        x: center.x - 40 * cos(drift * 0.8),
                        y: center.y + 40 * sin(drift * 0.8)
                    ),
                    radius: 250,
                    color: color2.opacity(revealed ? 0.2 : 0)
                )
                Self.blob(
                    context: &context,
                    center: CGPoint(
                        x: center.x + 30 * cos(drift * 1.2),
                        y: center.y + 50 * sin(drift * 1.2)
                    ),
                    radius: 180,
                    color: color3.opacity(revealed ? 0.15 : 0)
                )
            }
        }
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
    }

    private static func blob(
        context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        color: Color
    ) {
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [color, .clear]),
                center: center,
                startRadius: 0,
                endRadius: radius
            )
        )
    }
}

// MARK: - Reveal Gradient Blob

/// A vibrant gradient blob that expands from center to create the "reveal" moment
struct RevealGradientBlob: View {
    @SortyHotReload private var hotReload
    let scale: CGFloat
    let opacity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var isWindowVisible = true

    private var motionPaused: Bool {
        reduceMotion || reduceTransparency || !isWindowVisible || controlActiveState == .inactive || scenePhase != .active
    }

    // How the reveal blob is drawn: one Canvas pass inside a single 30fps
    // timeline. Radial gradients already fade to clear, so no blur passes
    // are needed. A frozen timeline frame doubles as the reduced-motion pose.
    var body: some View {
        SwiftUI.TimelineView(
            .animation(minimumInterval: 1.0 / 30.0, paused: motionPaused)
        ) { timeline in
            Canvas { context, size in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let sway = motionPaused ? 0 : seconds * .pi * 2 / 8
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                Self.blob(
                    context: &context,
                    center: center,
                    radiusX: 300,
                    radiusY: 250,
                    colors: [
                        Color.purple.opacity(0.7),
                        Color.indigo.opacity(0.5),
                        Color.blue.opacity(0.3),
                        Color.clear
                    ]
                )
                Self.blob(
                    context: &context,
                    center: CGPoint(
                        x: center.x + 30 * sin(sway),
                        y: center.y - 20 * cos(sway)
                    ),
                    radiusX: 225,
                    radiusY: 200,
                    colors: [
                        Color.blue.opacity(0.5),
                        Color.purple.opacity(0.3),
                        Color.clear
                    ]
                )
                Self.blob(
                    context: &context,
                    center: center,
                    radiusX: 120,
                    radiusY: 120,
                    colors: [
                        Color.white.opacity(0.15),
                        Color.purple.opacity(0.2),
                        Color.clear
                    ]
                )
            }
        }
        .frame(width: 600, height: 500)
        .scaleEffect(scale)
        .opacity(opacity)
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
    }

    private static func blob(
        context: inout GraphicsContext,
        center: CGPoint,
        radiusX: CGFloat,
        radiusY: CGFloat,
        colors: [Color]
    ) {
        let rect = CGRect(
            x: center.x - radiusX,
            y: center.y - radiusY,
            width: radiusX * 2,
            height: radiusY * 2
        )
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: colors),
                center: center,
                startRadius: 0,
                endRadius: max(radiusX, radiusY)
            )
        )
    }
}

// MARK: - Glow Ring

/// A pulsing glow ring behind the app icon during reveal
struct GlowRing: View {
    @SortyHotReload private var hotReload
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var pulseScale: CGFloat = 1.0
    @State private var isWindowVisible = true

    private var motionPaused: Bool {
        reduceMotion || reduceTransparency || !isWindowVisible || controlActiveState == .inactive || scenePhase != .active
    }

    // How the ring is drawn: a static stroked circle whenever motion or
    // transparency is reduced. The pulse runs only while fully active.

    var body: some View {
        Circle()
            .stroke(
                AngularGradient(
                    colors: [.purple, .blue, .indigo, .purple],
                    center: .center
                ),
                lineWidth: 3
            )
            .frame(width: 120, height: 120)
            .scaleEffect(isActive ? pulseScale : 0.5)
            .opacity(isActive ? 0.6 : 0)
            .blur(radius: reduceTransparency ? 0 : 4)
            .background(WindowVisibilityReader(isVisible: $isWindowVisible))
            .onAppear {
                guard !motionPaused else { return }
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                    pulseScale = 1.15
                }
            }
            .onChange(of: motionPaused) { _, paused in
                if paused {
                    withAnimation(nil) {
                        pulseScale = 1
                    }
                } else {
                    withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                        pulseScale = 1.15
                    }
                }
            }
    }
}

// MARK: - Floating Particle

struct FloatingParticle: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var yOffset: CGFloat = 0
    @State private var opacity: Double = 0
    @State private var isWindowVisible = true
    let delay: Double
    let size: CGFloat
    let xPosition: CGFloat

    private var motionPaused: Bool {
        reduceMotion || !isWindowVisible || controlActiveState == .inactive || scenePhase != .active
    }

    var body: some View {
        Circle()
            .fill(.white.opacity(0.3))
            .frame(width: size, height: size)
            .offset(x: xPosition, y: yOffset)
            .opacity(opacity)
            .background(WindowVisibilityReader(isVisible: $isWindowVisible))
            .onAppear {
                guard !motionPaused else { return }
                startDrift()
            }
            .onChange(of: motionPaused) { _, paused in
                if paused {
                    withAnimation(nil) {
                        yOffset = 0
                        opacity = 0
                    }
                } else {
                    startDrift()
                }
            }
    }

    // How particles resume: the same drift used on appear, so unpausing
    // (window visible again) restarts motion instead of leaving them parked.
    private func startDrift() {
        withAnimation(.easeInOut(duration: Double.random(in: 3...6)).repeatForever(autoreverses: false).delay(delay)) {
            yOffset = -300
            opacity = 0
        }
        withAnimation(.easeIn(duration: 1).delay(delay)) {
            opacity = 0.6
        }
    }
}
