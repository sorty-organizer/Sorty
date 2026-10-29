import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI

struct CompletionParticleBackdrop: View {
    @SortyHotReload private var hotReload
    let showParticles: Bool
    let exitTriggered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        RetainedCompletionParticles(
            isVisible: showParticles && !exitTriggered,
            reduceMotion: reduceMotion,
            isActive: controlActiveState != .inactive
        )
        .frame(width: 520, height: 420)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

}

struct RetainedCompletionParticles: NSViewRepresentable {
    @SortyHotReload private var hotReload
    let isVisible: Bool
    let reduceMotion: Bool
    let isActive: Bool

    func makeNSView(context: Context) -> RetainedCompletionParticlesView {
        RetainedCompletionParticlesView()
    }

    func updateNSView(_ nsView: RetainedCompletionParticlesView, context: Context) {
        nsView.update(
            isVisible: isVisible,
            reduceMotion: reduceMotion,
            isActive: isActive
        )
    }
}

@MainActor
final class RetainedCompletionParticlesView: NSView {
    private let particleLayers = (0..<7).map { _ in CAShapeLayer() }
    private var isAnimating = false
    private var animationClock = OnboardingLayerClock()
    private var lastIsVisible: Bool?
    private var lastReduceMotion: Bool?
    private var lastIsActive: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
        particleLayers.forEach {
            $0.fillColor = NSColor(CompletionPalette.accent).withAlphaComponent(0.30).cgColor
            $0.opacity = 0
            layer?.addSublayer($0)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        for (index, particleLayer) in particleLayers.enumerated() {
            let size = 3 + CGFloat((index * 17 + 5) % 30) / 10
            particleLayer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            particleLayer.path = CGPath(ellipseIn: particleLayer.bounds, transform: nil)
            particleLayer.position = CGPoint(
                x: bounds.midX - 200 + CGFloat((index * 137 + 43) % 400),
                y: bounds.midY - 80
            )
        }
    }

    func update(isVisible: Bool, reduceMotion: Bool, isActive: Bool) {
        guard lastIsVisible != isVisible
                || lastReduceMotion != reduceMotion
                || lastIsActive != isActive else { return }
        lastIsVisible = isVisible
        lastReduceMotion = reduceMotion
        lastIsActive = isActive

        if reduceMotion || !isVisible {
            stopAnimating()
        } else if !isAnimating {
            startAnimating()
        }

        if isActive {
            animationClock.resume(layer)
        } else if isAnimating {
            animationClock.pause(layer)
        }
    }

    private func startAnimating() {
        isAnimating = true
        for (index, particleLayer) in particleLayers.enumerated() {
            let now = particleLayer.convertTime(CACurrentMediaTime(), from: nil)
            let duration = 3 + seededParticleValue(index: index, range: 0...3)
            let travel = CAKeyframeAnimation(keyPath: "transform.translation")
            travel.values = [
                NSValue(point: .zero),
                NSValue(point: CGPoint(x: 12, y: 75)),
                NSValue(point: CGPoint(x: 16, y: 150)),
                NSValue(point: CGPoint(x: 8, y: 225)),
                NSValue(point: CGPoint(x: 0, y: 300))
            ]
            travel.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            travel.beginTime = now + Double(index) * 0.4
            travel.duration = duration
            travel.repeatCount = .infinity
            travel.fillMode = .backwards
            travel.calculationMode = .cubic
            particleLayer.add(travel, forKey: "completionParticleTravel")

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 0.6, 0.6, 0]
            opacity.keyTimes = [0, 0.12, 0.72, 1]
            opacity.beginTime = now + Double(index) * 0.4
            opacity.duration = duration
            opacity.repeatCount = .infinity
            opacity.fillMode = .backwards
            opacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            particleLayer.add(opacity, forKey: "completionParticleOpacity")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            particleLayer.opacity = 0.6
            CATransaction.commit()
        }
    }

    private func stopAnimating() {
        guard isAnimating else { return }
        isAnimating = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        particleLayers.forEach {
            $0.removeAnimation(forKey: "completionParticleTravel")
            $0.removeAnimation(forKey: "completionParticleOpacity")
            $0.opacity = 0
        }
        CATransaction.commit()
    }



    private func seededParticleValue(index: Int, range: ClosedRange<Double>) -> Double {
        let value = Double((index * 53 + 17) % 101) / 100
        return range.lowerBound + (range.upperBound - range.lowerBound) * value
    }
}
