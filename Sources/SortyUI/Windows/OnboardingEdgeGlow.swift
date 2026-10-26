import AppKit
import QuartzCore
import SwiftUI

/// Screen-sized accent glow hosted by `OnboardingScreenEdgeGlowPresenter`.
/// Four retained gradient layers replace a blurred SwiftUI hierarchy: the
/// render server draws them directly, so showing or resizing the panel never
/// rasterizes and Gaussian-blurs a full display on the main thread. The extra
/// stops near each edge reproduce the softened falloff the blur used to add.
final class OnboardingScreenEdgeGlowView: NSView {
    private static let edges: [(start: CGPoint, end: CGPoint)] = [
        (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
        (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)),
        (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)),
        (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))
    ]

    private let gradients = edges.map { _ in CAGradientLayer() }
    private var strength: Double

    init(strength: Double) {
        self.strength = strength
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(false)
        for (gradient, edge) in zip(gradients, Self.edges) {
            gradient.startPoint = edge.start
            gradient.endPoint = edge.end
            gradient.locations = [0, 0.012, 0.035, 0.07, 0.13]
            layer?.addSublayer(gradient)
        }
        applyColors(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradients.forEach { $0.frame = bounds }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors(animated: false)
    }

    /// Skill setup lifts the glow on an audio cue; the change eases on the
    /// render server instead of re-rendering SwiftUI content per frame.
    func setStrength(_ strength: Double) {
        guard self.strength != strength else { return }
        self.strength = strength
        applyColors(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func applyColors(animated: Bool) {
        let accent = NSColor(SortyDesignSystem.Colors.resolvedAccent)
        let colors = [0.72, 0.62, 0.34, 0.12, 0].map {
            accent.withAlphaComponent(strength * $0).cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for gradient in gradients {
            if animated {
                let animation = CABasicAnimation(keyPath: "colors")
                animation.fromValue = gradient.presentation()?.colors ?? gradient.colors
                animation.toValue = colors
                animation.duration = 0.55
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                gradient.add(animation, forKey: "edgeGlowStrength")
            }
            gradient.colors = colors
        }
        CATransaction.commit()
    }
}
