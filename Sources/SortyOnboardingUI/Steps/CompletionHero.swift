import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI

struct CompletionHero: View {
    @SortyHotReload private var hotReload
    let hasAppeared: Bool
    let showGlowRing: Bool
    let celebrationPhase: CompletionCelebrationPhase
    let exitTriggered: Bool
    let contentDismissed: Bool
    let isButtonHovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        ZStack {
            CompletionRippleField(
                hasAppeared: hasAppeared,
                showGlowRing: showGlowRing,
                exitTriggered: exitTriggered
            )
            CompletionCheckmarkIcon(
                hasAppeared: hasAppeared,
                isButtonHovered: isButtonHovered
            )
        }
        .background {
            RetainedCompletionCelebrationBlob(
                phase: celebrationPhase,
                exitTriggered: exitTriggered,
                reduceMotion: reduceMotion,
                isActive: controlActiveState != .inactive
            )
            .frame(width: 520, height: 440)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(reduceMotion || hasAppeared ? 1 : 0.9)
        .animation(
            reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.9),
            value: hasAppeared
        )
        .scaleEffect(contentDismissed ? 0.8 : 1.0)
        .opacity(contentDismissed ? 0 : 1)
    }
}

struct CompletionRippleField: View {
    @SortyHotReload private var hotReload
    let hasAppeared: Bool
    let showGlowRing: Bool
    let exitTriggered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        RetainedCompletionHeroEffects(
            isVisible: !exitTriggered && showGlowRing && hasAppeared,
            reduceMotion: reduceMotion,
            isActive: controlActiveState != .inactive
        )
        .frame(width: 240, height: 240)
        .transition(.opacity)
    }
}

struct CompletionGlowRingGraphic: View {
    @SortyHotReload private var hotReload
    var body: some View {
        Circle()
            .stroke(
                AngularGradient(
                    colors: [
                        CompletionPalette.softRose.opacity(0.86),
                        CompletionPalette.accent.opacity(0.78),
                        CompletionPalette.deepRose.opacity(0.46),
                        CompletionPalette.softRose.opacity(0.86)
                    ],
                    center: .center
                ),
                lineWidth: 3
            )
            .frame(width: 140, height: 140)
            .blur(radius: 8)
            .frame(width: 180, height: 180)
            .accessibilityHidden(true)
    }
}

struct RetainedCompletionHeroEffects: NSViewRepresentable {
    @SortyHotReload private var hotReload
    let isVisible: Bool
    let reduceMotion: Bool
    let isActive: Bool

    func makeNSView(context: Context) -> RetainedCompletionHeroEffectsView {
        RetainedCompletionHeroEffectsView()
    }

    func updateNSView(_ nsView: RetainedCompletionHeroEffectsView, context: Context) {
        nsView.update(
            isVisible: isVisible,
            reduceMotion: reduceMotion,
            isActive: isActive
        )
    }
}

@MainActor
final class RetainedCompletionHeroEffectsView: NSView {
    private let glowHost = NSHostingView(rootView: CompletionGlowRingGraphic())
    private let rippleLayers = (0..<3).map { _ in CAShapeLayer() }
    private var isVisible = false
    private var isAnimating = false
    private var animationClock = OnboardingLayerClock()
    private var lastReduceMotion: Bool?
    private var lastIsActive: Bool?
    private var lastLayoutBounds: CGRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)

        glowHost.wantsLayer = true
        glowHost.layer?.shouldRasterize = true
        updateGlowRasterizationScale()
        glowHost.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        addSubview(glowHost)

        for (index, rippleLayer) in rippleLayers.enumerated() {
            rippleLayer.fillColor = NSColor.clear.cgColor
            rippleLayer.strokeColor = NSColor(
                CompletionPalette.softRose.opacity(0.18 - Double(index) * 0.04)
            ).cgColor
            rippleLayer.lineWidth = 2
            layer?.insertSublayer(rippleLayer, below: glowHost.layer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard lastLayoutBounds != bounds else { return }
        lastLayoutBounds = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowHost.frame = CGRect(
            x: bounds.midX - 90,
            y: bounds.midY - 90,
            width: 180,
            height: 180
        )
        glowHost.layer?.position = CGPoint(x: bounds.midX, y: bounds.midY)

        for (index, rippleLayer) in rippleLayers.enumerated() {
            let diameter = CGFloat(140 + index * 30)
            let frame = CGRect(
                x: bounds.midX - diameter / 2,
                y: bounds.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            rippleLayer.frame = frame
            rippleLayer.path = CGPath(ellipseIn: rippleLayer.bounds, transform: nil)
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGlowRasterizationScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGlowRasterizationScale()
    }

    /// Cache the static angular gradient and blur at the pulse's largest size
    /// so scale animation stays sharp on Retina displays without reblurring.
    private func updateGlowRasterizationScale() {
        glowHost.layer?.rasterizationScale = (window?.backingScaleFactor ?? 2) * 1.15
    }

    func update(isVisible: Bool, reduceMotion: Bool, isActive: Bool) {
        let visibilityChanged = self.isVisible != isVisible
        let motionChanged = lastReduceMotion != reduceMotion
        let activityChanged = lastIsActive != isActive
        self.isVisible = isVisible
        lastReduceMotion = reduceMotion
        lastIsActive = isActive
        guard visibilityChanged || motionChanged || activityChanged else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowHost.layer?.opacity = isVisible ? 0.6 : 0
        rippleLayers.forEach { $0.opacity = isVisible && reduceMotion ? 0.10 : 0 }
        CATransaction.commit()

        guard isVisible else {
            stopAnimating()
            return
        }
        guard !reduceMotion else {
            stopAnimating()
            return
        }

        startAnimatingIfNeeded()
        if isActive {
            animationClock.resume(layer)
        } else if isAnimating {
            animationClock.pause(layer)
        }
    }

    private func startAnimatingIfNeeded() {
        guard !isAnimating else { return }
        isAnimating = true

        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1
        pulse.toValue = 1.15
        pulse.duration = 2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowHost.layer?.add(pulse, forKey: "completionGlowPulse")

        for (index, rippleLayer) in rippleLayers.enumerated() {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.8
            scale.toValue = 1.2

            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 1
            opacity.toValue = 0

            let group = CAAnimationGroup()
            group.animations = [scale, opacity]
            group.duration = 1.5
            group.beginTime = CACurrentMediaTime() + Double(index) * 0.3
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            rippleLayer.add(group, forKey: "completionRipple")
        }
    }

    private func stopAnimating() {
        guard isAnimating || animationClock.isPaused else { return }
        animationClock.resume(layer)
        isAnimating = false
        glowHost.layer?.removeAnimation(forKey: "completionGlowPulse")
        rippleLayers.forEach { $0.removeAllAnimations() }
    }
}

struct CompletionCheckmarkIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    @SortyHotReload private var hotReload
    let hasAppeared: Bool
    let isButtonHovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(colorScheme == .dark
                    ? CompletionPalette.shadowRose.opacity(0.30)
                    : CompletionPalette.accent.opacity(0.10))
                .frame(width: 118, height: 118)

            Circle()
                .fill(CompletionPalette.accent)
                .frame(width: 72, height: 72)
                .opacity(isButtonHovered ? 0 : 1)

            ZStack {
                Image(systemName: "checkmark")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .opacity(isButtonHovered ? 0 : 1)
                    .scaleEffect(isButtonHovered ? 0.72 : 1)
                    .symbolEffect(.bounce, value: reduceMotion ? false : hasAppeared)

                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 88, height: 88)
                    .opacity(isButtonHovered ? 1 : 0)
                    .scaleEffect(isButtonHovered ? 1 : 0.72)
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82),
                value: isButtonHovered
            )
        }
    }
}
