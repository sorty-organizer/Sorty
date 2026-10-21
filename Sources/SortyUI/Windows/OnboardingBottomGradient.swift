import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import os

package struct OnboardingBottomGradient: NSViewRepresentable {
    @SortyHotReload private var hotReload
    /// 0 = gradient hugs the bottom edge, 1 = gradient reaches near the top.
    var progress: Double = 0
    var showsBaseColor = true

    package init(progress: Double = 0, showsBaseColor: Bool = true) {
        self.progress = progress
        self.showsBaseColor = showsBaseColor
    }

    package func makeNSView(context: Context) -> RetainedOnboardingBottomGradientView {
        RetainedOnboardingBottomGradientView()
    }

    package func updateNSView(_ nsView: RetainedOnboardingBottomGradientView, context: Context) {
        nsView.update(
            progress: progress,
            showsBaseColor: showsBaseColor,
            isDark: context.environment.colorScheme == .dark,
            reduceMotion: context.environment.accessibilityReduceMotion
        )
    }
}

/// Retains the full-window color field as three gradient layers. Step changes
/// animate only layer colors and geometry instead of asking a SwiftUI Canvas to
/// redraw the entire window throughout every transition.
package final class RetainedOnboardingBottomGradientView: NSView {
    private static let transitionDuration: CFTimeInterval = 0.65

    private let accentGradient = CAGradientLayer()
    private let topShadeGradient = CAGradientLayer()
    private let radialGlowGradient = CAGradientLayer()
    private var currentProgress: Double?
    private var currentShowsBaseColor: Bool?
    private var currentIsDark: Bool?
    private var reduceMotion = false
    private var lastLayoutBounds = CGRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(accentGradient)
        layer?.addSublayer(topShadeGradient)
        layer?.addSublayer(radialGlowGradient)

        accentGradient.startPoint = CGPoint(x: 0.5, y: 1)
        accentGradient.locations = [0, 0.42, 1]
        topShadeGradient.startPoint = CGPoint(x: 0.5, y: 0)
        topShadeGradient.endPoint = CGPoint(x: 0.5, y: 1)
        topShadeGradient.locations = [0, 0.32, 0.64]
        radialGlowGradient.type = .radial
        radialGlowGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        radialGlowGradient.endPoint = CGPoint(x: 1, y: 0.5)
        radialGlowGradient.locations = [0, 0.42, 1]
        radialGlowGradient.compositingFilter = CIFilter(name: "CIAdditionCompositing")
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    package override func layout() {
        super.layout()
        guard bounds != lastLayoutBounds else { return }
        lastLayoutBounds = bounds
        applyPresentation(animated: false)
    }

    func update(
        progress: Double,
        showsBaseColor: Bool,
        isDark: Bool,
        reduceMotion: Bool
    ) {
        let clampedProgress = max(0, min(1, progress))
        let progressChanged = currentProgress != clampedProgress
        let appearanceChanged = currentIsDark != isDark
        let baseChanged = currentShowsBaseColor != showsBaseColor
        let motionChanged = self.reduceMotion != reduceMotion
        guard progressChanged || appearanceChanged || baseChanged || motionChanged else { return }

        let hasPresentedBefore = currentProgress != nil
        currentProgress = clampedProgress
        currentShowsBaseColor = showsBaseColor
        currentIsDark = isDark
        self.reduceMotion = reduceMotion
        applyPresentation(animated: hasPresentedBefore && progressChanged && !reduceMotion)
    }

    private func applyPresentation(animated: Bool) {
        guard let progress = currentProgress,
              let showsBaseColor = currentShowsBaseColor,
              let isDark = currentIsDark,
              !bounds.isEmpty else { return }

        let completion = progress * progress
        let intensity = 0.98 + completion * 0.28
        let bottomOpacity = isDark ? 0.42 : 0.20
        let midOpacity = isDark ? 0.22 : 0.10
        let glowOpacity = isDark ? 0.28 : 0.12
        let accent = NSColor(SortyDesignSystem.Colors.resolvedAccent)

        layer?.backgroundColor = showsBaseColor
            ? NSColor.windowBackgroundColor.cgColor
            : NSColor.clear.cgColor

        let accentColors = [
            accent.withAlphaComponent(bottomOpacity * intensity).cgColor,
            accent.withAlphaComponent(midOpacity * intensity).cgColor,
            accent.withAlphaComponent(0).cgColor
        ]
        let accentEndPoint = CGPoint(x: 0.5, y: 0.68 - progress * 0.56)
        let shadeColors = [
            NSColor.black.withAlphaComponent(isDark ? 0.18 : 0).cgColor,
            NSColor.black.withAlphaComponent(isDark ? 0.04 : 0).cgColor,
            NSColor.clear.cgColor
        ]
        let radialColors = [
            accent.withAlphaComponent(glowOpacity * intensity).cgColor,
            accent.withAlphaComponent((isDark ? 0.16 : 0.06) * intensity).cgColor,
            accent.withAlphaComponent(0).cgColor
        ]
        let radialRadius = 680 + completion * 560
        let radialCenter = CGPoint(
            x: bounds.midX,
            y: bounds.height * (1.02 - progress * 0.18)
        )
        let radialFrame = CGRect(
            x: radialCenter.x - radialRadius,
            y: radialCenter.y - radialRadius,
            width: radialRadius * 2,
            height: radialRadius * 2
        )

        let duration = animated ? Self.transitionDuration : 0
        update(
            accentGradient,
            frame: bounds,
            colors: accentColors,
            endPoint: accentEndPoint,
            duration: duration
        )
        update(
            topShadeGradient,
            frame: bounds,
            colors: shadeColors,
            endPoint: CGPoint(x: 0.5, y: 1),
            duration: 0
        )
        update(
            radialGlowGradient,
            frame: radialFrame,
            colors: radialColors,
            endPoint: CGPoint(x: 1, y: 0.5),
            duration: duration
        )
    }

    private func update(
        _ gradient: CAGradientLayer,
        frame: CGRect,
        colors: [CGColor],
        endPoint: CGPoint,
        duration: CFTimeInterval
    ) {
        if duration > 0 {
            addAnimation(
                to: gradient,
                keyPath: "colors",
                from: gradient.presentation()?.colors ?? gradient.colors,
                to: colors,
                duration: duration
            )
            addAnimation(
                to: gradient,
                keyPath: "endPoint",
                from: gradient.presentation()?.endPoint ?? gradient.endPoint,
                to: endPoint,
                duration: duration
            )
            addAnimation(
                to: gradient,
                keyPath: "position",
                from: gradient.presentation()?.position ?? gradient.position,
                to: CGPoint(x: frame.midX, y: frame.midY),
                duration: duration
            )
            addAnimation(
                to: gradient,
                keyPath: "bounds",
                from: gradient.presentation()?.bounds ?? gradient.bounds,
                to: CGRect(origin: .zero, size: frame.size),
                duration: duration
            )
        } else {
            gradient.removeAllAnimations()
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = frame
        gradient.colors = colors
        gradient.endPoint = endPoint
        CATransaction.commit()
    }

    private func addAnimation(
        to layer: CALayer,
        keyPath: String,
        from: Any?,
        to: Any,
        duration: CFTimeInterval
    ) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "onboardingGradient.\(keyPath)")
    }
}

package struct OnboardingNavigationBackdrop: View {
    @SortyHotReload private var hotReload

    package init() {}
    package var body: some View {
        LinearGradient(
            colors: [
                Color(NSColor.windowBackgroundColor).opacity(0),
                Color(NSColor.windowBackgroundColor).opacity(0.20),
                Color(NSColor.windowBackgroundColor).opacity(0.34)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea(edges: .bottom)
    }
}
