import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import os

package struct SortyEnergyScanIcon: View {
    @SortyHotReload private var hotReload
    let image: NSImage
    let size: CGFloat
    let cornerRadius: CGFloat
    var startDelay: TimeInterval = 0.8
    var sweepDuration: TimeInterval = 2.8
    var repeats = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    package init(
        image: NSImage,
        size: CGFloat,
        cornerRadius: CGFloat,
        startDelay: TimeInterval = 0.8,
        sweepDuration: TimeInterval = 2.8,
        repeats: Bool = false
    ) {
        self.image = image
        self.size = size
        self.cornerRadius = cornerRadius
        self.startDelay = startDelay
        self.sweepDuration = sweepDuration
        self.repeats = repeats
    }

    package var body: some View {
        RetainedEnergyScanIcon(
            image: image,
            size: size,
            cornerRadius: cornerRadius,
            startDelay: startDelay,
            sweepDuration: sweepDuration,
            repeats: repeats,
            reduceMotion: reduceMotion,
            isActive: controlActiveState != .inactive
        )
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct RetainedEnergyScanIcon: NSViewRepresentable {
    @SortyHotReload private var hotReload
    let image: NSImage
    let size: CGFloat
    let cornerRadius: CGFloat
    let startDelay: TimeInterval
    let sweepDuration: TimeInterval
    let repeats: Bool
    let reduceMotion: Bool
    let isActive: Bool

    func makeNSView(context: Context) -> RetainedEnergyScanIconView {
        RetainedEnergyScanIconView()
    }

    func updateNSView(_ nsView: RetainedEnergyScanIconView, context: Context) {
        nsView.update(
            image: image,
            size: size,
            cornerRadius: cornerRadius,
            delay: startDelay,
            duration: sweepDuration,
            repeats: repeats,
            reduceMotion: reduceMotion,
            isActive: isActive
        )
    }
}

/// Renders the icon once and moves retained gradient layers for the scan.
/// This replaces a 60 Hz SwiftUI rebuild of the image, mask, blur, and blend.
@MainActor
final class RetainedEnergyScanIconView: NSView, @preconcurrency CAAnimationDelegate {
    private let imageLayer = CALayer()
    private let scanContainer = CALayer()
    private let imageMask = CALayer()
    private let movingBand = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let scanLine = CAShapeLayer()
    private var configuredImage: NSImage?
    private var configuredSize: CGFloat = 0
    private var isAnimating = false
    private var isPaused = false
    private var hasCompletedSingleSweep = false
    private var lastLayoutBounds: CGRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)

        imageLayer.contentsGravity = .resizeAspect
        imageMask.contentsGravity = .resizeAspect
        scanContainer.mask = imageMask
        scanContainer.compositingFilter = "plusL"
        movingBand.opacity = 0
        gradientLayer.colors = [
            NSColor.clear.cgColor,
            NSColor(srgbRed: 0.84, green: 0.18, blue: 1, alpha: 0.36).cgColor,
            NSColor.white.withAlphaComponent(0.90).cgColor,
            NSColor(srgbRed: 1, green: 0.16, blue: 0.42, alpha: 0.82).cgColor,
            NSColor(srgbRed: 1, green: 0.48, blue: 0.14, alpha: 0.32).cgColor,
            NSColor.clear.cgColor
        ]
        gradientLayer.locations = [0, 0.20, 0.48, 0.60, 0.78, 1]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        scanLine.fillColor = NSColor.white.withAlphaComponent(0.86).cgColor
        scanLine.opacity = 0.72
        movingBand.addSublayer(gradientLayer)
        movingBand.addSublayer(scanLine)
        scanContainer.addSublayer(movingBand)
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(scanContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard lastLayoutBounds != bounds else { return }
        lastLayoutBounds = bounds
        let lineHeight = max(1.5, bounds.width * 0.012)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        scanContainer.frame = bounds
        imageMask.frame = scanContainer.bounds
        movingBand.bounds = CGRect(x: 0, y: 0, width: bounds.width * 1.7, height: bounds.height * 0.42)
        movingBand.position = CGPoint(x: bounds.midX, y: bounds.midY)
        movingBand.setAffineTransform(CGAffineTransform(rotationAngle: -11 * .pi / 180))
        gradientLayer.frame = movingBand.bounds
        scanLine.frame = CGRect(
            x: movingBand.bounds.midX - bounds.width * 1.45 / 2,
            y: movingBand.bounds.midY - lineHeight / 2,
            width: bounds.width * 1.45,
            height: lineHeight
        )
        scanLine.path = CGPath(
            roundedRect: scanLine.bounds,
            cornerWidth: lineHeight / 2,
            cornerHeight: lineHeight / 2,
            transform: nil
        )
        CATransaction.commit()
    }

    func update(
        image: NSImage,
        size: CGFloat,
        cornerRadius: CGFloat,
        delay: TimeInterval,
        duration: TimeInterval,
        repeats: Bool,
        reduceMotion: Bool,
        isActive: Bool
    ) {
        if configuredImage !== image || configuredSize != size {
            configuredImage = image
            configuredSize = size
            var proposedRect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            let contents = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
            imageLayer.contents = contents
            imageMask.contents = contents
            layer?.cornerRadius = cornerRadius
            needsLayout = true
        }

        if reduceMotion || hasCompletedSingleSweep {
            stopAnimating()
            return
        }

        startAnimatingIfNeeded(delay: delay, duration: duration, repeats: repeats)
        if isActive {
            resumeIfNeeded()
        } else {
            pauseIfNeeded()
        }
    }

    private func startAnimatingIfNeeded(delay: TimeInterval, duration: TimeInterval, repeats: Bool) {
        guard !isAnimating else { return }
        isAnimating = true
        let samples = (0...64).map { Double($0) / 64 }
        let eased = samples.map { $0 * $0 * (3 - 2 * $0) }

        let translation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        translation.values = eased.map { NSNumber(value: (-0.74 + $0 * 1.48) * configuredSize) }
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = samples.map { NSNumber(value: sin($0 * .pi) * 0.88) }

        let group = CAAnimationGroup()
        group.animations = [translation, opacity]
        group.duration = duration
        group.beginTime = movingBand.convertTime(CACurrentMediaTime(), from: nil) + delay
        group.fillMode = .backwards
        group.repeatCount = repeats ? .infinity : 0
        group.delegate = self
        group.setValue(!repeats, forKey: "isSingleEnergyScanSweep")
        movingBand.add(group, forKey: "energyScanSweep")
    }

    private func stopAnimating() {
        guard isAnimating || isPaused
                || movingBand.animation(forKey: "energyScanSweep") != nil else { return }
        resumeIfNeeded()
        isAnimating = false
        movingBand.removeAnimation(forKey: "energyScanSweep")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        movingBand.opacity = 0
        CATransaction.commit()
    }

    private func pauseIfNeeded() {
        guard isAnimating, !isPaused else { return }
        let pausedTime = movingBand.convertTime(CACurrentMediaTime(), from: nil)
        movingBand.speed = 0
        movingBand.timeOffset = pausedTime
        isPaused = true
    }

    private func resumeIfNeeded() {
        guard isPaused else { return }
        let pausedTime = movingBand.timeOffset
        movingBand.speed = 1
        movingBand.timeOffset = 0
        movingBand.beginTime = 0
        movingBand.beginTime = movingBand.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        isPaused = false
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag,
              anim.value(forKey: "isSingleEnergyScanSweep") as? Bool == true else { return }
        hasCompletedSingleSweep = true
        stopAnimating()
    }
}
