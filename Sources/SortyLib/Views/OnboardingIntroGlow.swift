import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import os

struct RetainedIntroGlow: NSViewRepresentable {
    @SortyHotReload private var hotReload
    let isVisible: Bool
    let reduceMotion: Bool
    let isActive: Bool

    func makeNSView(context: Context) -> RetainedIntroGlowView {
        RetainedIntroGlowView()
    }

    func updateNSView(_ nsView: RetainedIntroGlowView, context: Context) {
        nsView.update(
            isVisible: isVisible,
            reduceMotion: reduceMotion,
            isActive: isActive
        )
    }
}

/// Preserves the intro's 28-to-38 point Gaussian bloom on one retained layer.
/// SwiftUI no longer rerenders the blurred 220-point shape during the reveal.
@MainActor
final class RetainedIntroGlowView: NSView {
    private let glowLayer = CALayer()
    private let glowShapeLayer = CALayer()
    private let blurFilter = CIFilter.gaussianBlur()
    private var hasStartedReveal = false
    private var isPaused = false
    private var lastIsVisible: Bool?
    private var lastReduceMotion: Bool?
    private var lastIsActive: Bool?
    private var lastLayoutBounds: CGRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)

        glowLayer.shouldRasterize = true
        updateGlowRasterizationScale()
        blurFilter.name = "introGlowBlur"
        blurFilter.radius = 16
        glowShapeLayer.backgroundColor = NSColor(SortyDesignSystem.Colors.resolvedAccent)
            .withAlphaComponent(0.30)
            .cgColor
        glowShapeLayer.cornerRadius = 44
        glowLayer.opacity = 0
        glowLayer.filters = [blurFilter]
        glowLayer.addSublayer(glowShapeLayer)
        layer?.addSublayer(glowLayer)
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
        let blurOutset: CGFloat = 60
        glowLayer.frame = bounds.insetBy(dx: -blurOutset, dy: -blurOutset)
        glowShapeLayer.frame = CGRect(
            x: blurOutset,
            y: blurOutset,
            width: bounds.width,
            height: bounds.height
        )
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        glowShapeLayer.backgroundColor = NSColor(SortyDesignSystem.Colors.resolvedAccent)
            .withAlphaComponent(0.30).cgColor
    }

    private func updateGlowRasterizationScale() {
        glowLayer.rasterizationScale = window?.backingScaleFactor ?? 2
    }

    func update(isVisible: Bool, reduceMotion: Bool, isActive: Bool) {
        guard lastIsVisible != isVisible
                || lastReduceMotion != reduceMotion
                || lastIsActive != isActive else { return }
        lastIsVisible = isVisible
        lastReduceMotion = reduceMotion
        lastIsActive = isActive

        if reduceMotion {
            finishImmediately(isVisible: isVisible)
        } else if isVisible, !hasStartedReveal {
            startReveal()
        } else if !isVisible {
            resetReveal()
        }

        if isActive {
            resumeIfNeeded()
        } else {
            pauseIfNeeded()
        }
    }

    private func startReveal() {
        hasStartedReveal = true
        let now = glowLayer.convertTime(CACurrentMediaTime(), from: nil)

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.beginTime = now + 0.2
        opacity.duration = 1.2
        opacity.fillMode = .backwards
        opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)
        glowLayer.add(opacity, forKey: "introGlowOpacity")

        // The blur radius stays fixed; only opacity animates so the GPU
        // never re-rasterizes the blurred layer mid-reveal.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.opacity = 1
        blurFilter.radius = 16
        CATransaction.commit()
    }

    private func finishImmediately(isVisible: Bool) {
        hasStartedReveal = isVisible
        glowLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.opacity = isVisible ? 1 : 0
        blurFilter.radius = 16
        CATransaction.commit()
    }

    private func resetReveal() {
        hasStartedReveal = false
        glowLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.opacity = 0
        blurFilter.radius = 16
        CATransaction.commit()
    }

    private func pauseIfNeeded() {
        guard !isPaused, let layer else { return }
        let pausedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = pausedTime
        isPaused = true
    }

    private func resumeIfNeeded() {
        guard isPaused, let layer else { return }
        let pausedTime = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        isPaused = false
    }
}
