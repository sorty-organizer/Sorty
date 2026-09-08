//
//  CompletionStepView.swift
//  Sorty
//
//  Completion step of the onboarding flow
//

import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI

@MainActor
private enum CompletionPalette {
    static var accent: Color { SortyDesignSystem.Colors.resolvedAccent }
    static let softRose = Color(red: 1.0, green: 0.48, blue: 0.58)
    static let deepRose = Color(red: 0.42, green: 0.19, blue: 0.25)
    static let shadowRose = Color(red: 0.22, green: 0.10, blue: 0.14)
}

// MARK: - Completion Celebration Blob

/// Phased ambient backdrop for the completion celebration. The blob leads the
/// entrance (reveal), then settles into a quiet breathing ambient state.
private enum CompletionCelebrationPhase: Int {
    case hidden
    case reveal
    case ambient
}

private struct RetainedCompletionCelebrationBlob: NSViewRepresentable {
    @SortyHotReload private var hotReload
    let phase: CompletionCelebrationPhase
    let exitTriggered: Bool
    let reduceMotion: Bool
    let isActive: Bool

    func makeNSView(context: Context) -> RetainedCompletionCelebrationBlobView {
        RetainedCompletionCelebrationBlobView()
    }

    func updateNSView(_ nsView: RetainedCompletionCelebrationBlobView, context: Context) {
        nsView.update(
            phase: phase,
            exitTriggered: exitTriggered,
            reduceMotion: reduceMotion,
            isActive: isActive
        )
    }
}

/// Retained two-layer celebration blob. Gradient color lives on small shape
/// layers under Gaussian blur containers, so the compositor animates scale,
/// opacity, and blur radius without re-rendering any SwiftUI content.
@MainActor
private final class RetainedCompletionCelebrationBlobView: NSView {
    private let blobContainer = CALayer()
    private let blobShape = CALayer()
    private let blobBlur = CIFilter.gaussianBlur()
    private let coreContainer = CALayer()
    private let coreShape = CALayer()
    private let coreBlur = CIFilter.gaussianBlur()
    private var isBreathing = false
    private var isPaused = false
    private var lastPhase: CompletionCelebrationPhase?
    private var lastExitTriggered: Bool?
    private var lastReduceMotion: Bool?
    private var lastIsActive: Bool?
    private var rasterizationTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)

        blobBlur.name = "celebrationBlobBlur"
        blobBlur.radius = 48
        blobContainer.filters = [blobBlur]
        blobContainer.opacity = 0
        coreBlur.name = "celebrationCoreBlur"
        coreBlur.radius = 26
        coreContainer.filters = [coreBlur]
        coreContainer.opacity = 0
        blobContainer.addSublayer(blobShape)
        coreContainer.addSublayer(coreShape)
        layer?.addSublayer(blobContainer)
        layer?.addSublayer(coreContainer)
        refreshPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        disableSettledRasterization()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let blurOutset: CGFloat = 64
        blobContainer.frame = bounds.insetBy(dx: -blurOutset, dy: -blurOutset)
        coreContainer.frame = bounds.insetBy(dx: -blurOutset, dy: -blurOutset)
        let blobSize = CGSize(width: 400, height: 320)
        blobShape.frame = CGRect(
            x: blobContainer.bounds.midX - blobSize.width / 2,
            y: blobContainer.bounds.midY - blobSize.height / 2,
            width: blobSize.width,
            height: blobSize.height
        )
        blobShape.cornerRadius = blobSize.height / 2
        let coreSize = CGSize(width: 220, height: 200)
        coreShape.frame = CGRect(
            x: coreContainer.bounds.midX - coreSize.width / 2,
            y: coreContainer.bounds.midY - coreSize.height / 2,
            width: coreSize.width,
            height: coreSize.height
        )
        coreShape.cornerRadius = coreSize.height / 2
        CATransaction.commit()
        if lastPhase == .ambient {
            scheduleSettledRasterization(delay: 0)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshPalette()
        disableSettledRasterization()
        if lastPhase == .ambient {
            scheduleSettledRasterization(delay: 0)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        disableSettledRasterization()
        if lastPhase == .ambient {
            scheduleSettledRasterization(delay: 0)
        }
    }

    func update(
        phase: CompletionCelebrationPhase,
        exitTriggered: Bool,
        reduceMotion: Bool,
        isActive: Bool
    ) {
        guard lastPhase != phase
            || lastExitTriggered != exitTriggered
            || lastReduceMotion != reduceMotion
            || lastIsActive != isActive else { return }
        lastPhase = phase
        lastExitTriggered = exitTriggered
        lastReduceMotion = reduceMotion
        lastIsActive = isActive

        refreshPalette()

        if reduceMotion {
            stopBreathing()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let visible = !exitTriggered && phase != .hidden
            blobContainer.opacity = visible ? 0.75 : 0
            coreContainer.opacity = visible ? 0.7 : 0
            blobContainer.transform = CATransform3DIdentity
            coreContainer.transform = CATransform3DIdentity
            blobBlur.radius = 56
            coreBlur.radius = 32
            CATransaction.commit()
            scheduleSettledRasterization(delay: 0)
        } else if exitTriggered || phase == .hidden {
            disableSettledRasterization()
            stopBreathing()
            fadeOut()
        } else if phase == .reveal {
            disableSettledRasterization()
            stopBreathing()
            animateReveal()
        } else {
            disableSettledRasterization()
            animateSettleToAmbient()
        }

        if isActive {
            resumeIfNeeded()
        } else {
            pauseIfNeeded()
        }
    }

    private func refreshPalette() {
        blobShape.backgroundColor = NSColor(CompletionPalette.accent)
            .withAlphaComponent(0.32).cgColor
        coreShape.backgroundColor = NSColor(CompletionPalette.accent)
            .withAlphaComponent(0.30).cgColor
    }

    private func animateReveal() {
        let now = blobContainer.convertTime(CACurrentMediaTime(), from: nil)
        setModel(opacity: 1, scale: 1, blobBlur: 40, coreBlur: 22)

        // Slight overshoot so the blob lands with a soft settle instead of a
        // flat ease-out stop.
        let blobScale = CAKeyframeAnimation(keyPath: "transform.scale")
        blobScale.values = [0.3, 1.04, 1.0].map { NSNumber(value: $0) }
        blobScale.keyTimes = [0, 0.7, 1].map { NSNumber(value: $0) }
        blobScale.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        blobScale.beginTime = now
        blobScale.duration = 1.0
        blobScale.fillMode = .backwards
        blobContainer.add(blobScale, forKey: "celebrationRevealScale")

        let blobOpacity = CAKeyframeAnimation(keyPath: "opacity")
        blobOpacity.values = [0, 1, 1].map { NSNumber(value: $0) }
        blobOpacity.keyTimes = [0, 0.75, 1].map { NSNumber(value: $0) }
        blobOpacity.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        blobOpacity.beginTime = now
        blobOpacity.duration = 0.8
        blobOpacity.fillMode = .backwards
        blobContainer.add(blobOpacity, forKey: "celebrationRevealOpacity")

        let coreScale = CAKeyframeAnimation(keyPath: "transform.scale")
        coreScale.values = [0.35, 1.03, 1.0].map { NSNumber(value: $0) }
        coreScale.keyTimes = [0, 0.7, 1].map { NSNumber(value: $0) }
        coreScale.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        coreScale.beginTime = now + 0.1
        coreScale.duration = 0.95
        coreScale.fillMode = .backwards
        coreContainer.add(coreScale, forKey: "celebrationRevealScale")

        let coreOpacity = CAKeyframeAnimation(keyPath: "opacity")
        coreOpacity.values = [0, 1, 1].map { NSNumber(value: $0) }
        coreOpacity.keyTimes = [0, 0.75, 1].map { NSNumber(value: $0) }
        coreOpacity.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        coreOpacity.beginTime = now + 0.1
        coreOpacity.duration = 0.8
        coreOpacity.fillMode = .backwards
        coreContainer.add(coreOpacity, forKey: "celebrationRevealOpacity")
    }

    private func animateSettleToAmbient() {
        // Soften rather than dim: hold presence while the blur blooms outward,
        // with a slight outward drift so the settle reads as motion, not as
        // the reveal reversing.
        setModel(opacity: 0.75, scale: 1.02, blobBlur: 56, coreBlur: 32, coreOpacity: 0.7)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = blobContainer.presentation()?.opacity ?? 1
        fade.toValue = 0.75
        fade.duration = 1.0
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        blobContainer.add(fade, forKey: "celebrationSettleOpacity")

        let coreFade = CABasicAnimation(keyPath: "opacity")
        coreFade.fromValue = coreContainer.presentation()?.opacity ?? 1
        coreFade.toValue = 0.7
        coreFade.duration = 1.0
        coreFade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        coreContainer.add(coreFade, forKey: "celebrationSettleOpacity")

        let drift = CABasicAnimation(keyPath: "transform.scale")
        drift.fromValue = (blobContainer.presentation()?.value(forKeyPath: "transform.scale") as? Double) ?? 1
        drift.toValue = 1.02
        drift.duration = 1.0
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        blobContainer.add(drift, forKey: "celebrationSettleScale")

        let coreDrift = CABasicAnimation(keyPath: "transform.scale")
        coreDrift.fromValue = (coreContainer.presentation()?.value(forKeyPath: "transform.scale") as? Double) ?? 1
        coreDrift.toValue = 1.02
        coreDrift.duration = 1.0
        coreDrift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        coreContainer.add(coreDrift, forKey: "celebrationSettleScale")

        let blur = CABasicAnimation(keyPath: "filters.celebrationBlobBlur.inputRadius")
        blur.fromValue = 40
        blur.toValue = 56
        blur.duration = 1.0
        blur.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        blobContainer.add(blur, forKey: "celebrationSettleBlur")

        let coreBlurAnimation = CABasicAnimation(keyPath: "filters.celebrationCoreBlur.inputRadius")
        coreBlurAnimation.fromValue = 22
        coreBlurAnimation.toValue = 32
        coreBlurAnimation.duration = 1.0
        coreBlurAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        coreContainer.add(coreBlurAnimation, forKey: "celebrationSettleBlur")

        startBreathing(delay: 0.95)
        scheduleSettledRasterization(delay: 0.95)
    }

    private func fadeOut() {
        let blobFade = CABasicAnimation(keyPath: "opacity")
        blobFade.fromValue = blobContainer.presentation()?.opacity ?? blobContainer.opacity
        blobFade.toValue = 0
        blobFade.duration = 0.45
        blobFade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        blobContainer.add(blobFade, forKey: "celebrationExitOpacity")

        let coreFade = CABasicAnimation(keyPath: "opacity")
        coreFade.fromValue = coreContainer.presentation()?.opacity ?? coreContainer.opacity
        coreFade.toValue = 0
        coreFade.duration = 0.45
        coreFade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        coreContainer.add(coreFade, forKey: "celebrationExitOpacity")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blobContainer.opacity = 0
        coreContainer.opacity = 0
        CATransaction.commit()
    }

    private func setModel(opacity: Float, scale: CGFloat, blobBlur: Float, coreBlur: Float, coreOpacity: Float? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blobContainer.opacity = opacity
        coreContainer.opacity = coreOpacity ?? opacity
        blobContainer.transform = CATransform3DMakeScale(scale, scale, 1)
        coreContainer.transform = CATransform3DMakeScale(scale, scale, 1)
        self.blobBlur.radius = blobBlur
        self.coreBlur.radius = coreBlur
        CATransaction.commit()
    }

    private func startBreathing(delay: CFTimeInterval = 0) {
        guard !isBreathing else { return }
        isBreathing = true
        let base = blobContainer.convertTime(CACurrentMediaTime(), from: nil) + delay
        let blobBreath = CABasicAnimation(keyPath: "transform.scale")
        blobBreath.fromValue = 1.02
        blobBreath.toValue = 1.07
        blobBreath.beginTime = base
        blobBreath.duration = 3.8
        blobBreath.autoreverses = true
        blobBreath.repeatCount = .infinity
        blobBreath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        blobContainer.add(blobBreath, forKey: "celebrationAmbientBreath")

        let coreBreath = CABasicAnimation(keyPath: "transform.scale")
        coreBreath.fromValue = 1.02
        coreBreath.toValue = 1.09
        coreBreath.beginTime = base + 0.6
        coreBreath.duration = 2.9
        coreBreath.autoreverses = true
        coreBreath.repeatCount = .infinity
        coreBreath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        coreContainer.add(coreBreath, forKey: "celebrationAmbientBreath")
    }

    private func stopBreathing() {
        guard isBreathing else { return }
        isBreathing = false
        blobContainer.removeAnimation(forKey: "celebrationAmbientBreath")
        coreContainer.removeAnimation(forKey: "celebrationAmbientBreath")
    }

    private func scheduleSettledRasterization(delay: TimeInterval) {
        rasterizationTask?.cancel()
        rasterizationTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self, self.lastPhase == .ambient else { return }
            let scale = self.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            self.blobContainer.rasterizationScale = scale
            self.coreContainer.rasterizationScale = scale
            self.blobContainer.shouldRasterize = true
            self.coreContainer.shouldRasterize = true
            self.rasterizationTask = nil
        }
    }

    private func disableSettledRasterization() {
        rasterizationTask?.cancel()
        rasterizationTask = nil
        blobContainer.shouldRasterize = false
        coreContainer.shouldRasterize = false
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

private struct CompletionParticleBackdrop: View {
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

private struct RetainedCompletionParticles: NSViewRepresentable {
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
private final class RetainedCompletionParticlesView: NSView {
    private let particleLayers = (0..<7).map { _ in CAShapeLayer() }
    private var isAnimating = false
    private var isPaused = false
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
            resumeIfNeeded()
        } else {
            pauseIfNeeded()
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

    private func pauseIfNeeded() {
        guard isAnimating, !isPaused, let layer else { return }
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

    private func seededParticleValue(index: Int, range: ClosedRange<Double>) -> Double {
        let value = Double((index * 53 + 17) % 101) / 100
        return range.lowerBound + (range.upperBound - range.lowerBound) * value
    }
}

private struct CompletionHero: View {
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

private struct CompletionRippleField: View {
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

private struct CompletionGlowRingGraphic: View {
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

private struct RetainedCompletionHeroEffects: NSViewRepresentable {
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
private final class RetainedCompletionHeroEffectsView: NSView {
    private let glowHost = NSHostingView(rootView: CompletionGlowRingGraphic())
    private let rippleLayers = (0..<3).map { _ in CAShapeLayer() }
    private var isVisible = false
    private var isAnimating = false
    private var isPaused = false
    private var lastReduceMotion: Bool?
    private var lastIsActive: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)

        glowHost.wantsLayer = true
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
            resumeIfNeeded()
        } else {
            pauseIfNeeded()
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
        guard isAnimating || isPaused else { return }
        resumeIfNeeded()
        isAnimating = false
        glowHost.layer?.removeAnimation(forKey: "completionGlowPulse")
        rippleLayers.forEach { $0.removeAllAnimations() }
    }

    private func pauseIfNeeded() {
        guard isAnimating, !isPaused, let layer else { return }
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

private struct CompletionCheckmarkIcon: View {
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

private struct CompletionCopy: View {
    @SortyHotReload private var hotReload
    let hasAppeared: Bool
    let contentDismissed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            Text("Ready to Organize")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 20)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.85).delay(0.2),
                    value: hasAppeared
                )

            Text("Drop in a folder, preview the plan, and undo anything you change.")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 15)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.85).delay(0.4),
                    value: hasAppeared
                )
        }
        .opacity(contentDismissed ? 0 : 1)
        .offset(y: contentDismissed ? 30 : 0)
    }
}

private struct CompletionTipsGrid: View {
    @SortyHotReload private var hotReload
    let tipsAppeared: Bool
    let contentDismissed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            VStack(alignment: .leading, spacing: 14) {
                quickTip(icon: "folder.badge.plus", text: "Organize from Finder", delay: 0)
                quickTip(icon: "arrow.uturn.backward", text: "Undo from History", delay: 0.08)
            }
            VStack(alignment: .leading, spacing: 14) {
                quickTip(icon: "keyboard", text: "⌘O opens a folder", delay: 0.04)
                quickTip(icon: "gearshape", text: "Swap models in Settings", delay: 0.12)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(contentDismissed ? 0 : 1)
        .offset(y: contentDismissed ? 40 : 0)
    }

    private func quickTip(icon: String, text: String, delay: Double) -> some View {
        QuickTipRow(icon: icon, text: text)
            .opacity(tipsAppeared ? 1 : 0)
            .offset(y: tipsAppeared ? 0 : 12)
            .animation(
                reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.85).delay(delay),
                value: tipsAppeared
            )
    }
}

private struct CompletionPrimaryAction: View {
    @SortyHotReload private var hotReload
    let tipsAppeared: Bool
    let contentDismissed: Bool
    let isChecking: Bool
    let action: () -> Void
    let onHoverChanged: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("Start Using Sorty")
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .buttonStyle(.sortyPrimary(size: .large))
        .onboardingBeamBorder(variant: .featured, active: !isChecking)
        .keyboardShortcut(.defaultAction)
        .disabled(isChecking)
        .onHover { hovering in
            onHoverChanged(hovering)
        }
        .opacity(tipsAppeared && !contentDismissed ? 1 : 0)
        .offset(y: tipsAppeared ? (contentDismissed ? 50 : 0) : 16)
        .animation(
            reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.85).delay(0.2),
            value: tipsAppeared
        )
        .padding(.top, 6)
        .accessibilityIdentifier("OnboardingCompleteButton")
    }
}

private struct CompletionAnalyticsPreference: View {
    @Environment(\.colorScheme) private var colorScheme
    @SortyHotReload private var hotReload
    @Binding var isEnabled: Bool
    @State private var isShowingDetails = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $isEnabled) {
                Text("Share anonymous analytics")
                    .font(.system(size: 13.5, weight: .medium, design: .rounded))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier("OnboardingAnalyticsToggle")

            Button {
                HapticFeedbackManager.shared.tap()
                isShowingDetails.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    HapticFeedbackManager.shared.selection()
                }
            }
            .help("What anonymous analytics includes")
            .accessibilityLabel("About anonymous analytics")
            .accessibilityIdentifier("OnboardingAnalyticsInfoButton")
            .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
                analyticsDetails
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            if colorScheme == .light {
                Capsule()
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.72))
                    .padding(-8)
                    .blur(radius: 12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            Capsule()
                .fill(
                    colorScheme == .dark
                        ? CompletionPalette.shadowRose.opacity(0.18)
                        : Color(NSColor.controlBackgroundColor)
                )
        }
    }

    private var analyticsDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Anonymous analytics")
                .font(.headline)

            Text("When this is on, Sorty sends limited product and reliability events so we can see which parts of the app are useful and where failures occur.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            detailSection(
                title: "What is included",
                systemImage: "checkmark.circle.fill",
                color: .green,
                text: "Screens and features used; broad actions, outcomes, counts, and timings; app and macOS versions and device category; sanitized errors and crashes with messages and sensitive values redacted."
            )

            detailSection(
                title: "What is never included",
                systemImage: "xmark.circle.fill",
                color: .red,
                text: "Your identity, folder or file names, paths, file contents, prompts, custom instructions, AI responses, API keys, or other credentials. Sorty does not record your screen or keystrokes."
            )

            Text("You can change this at any time in Settings → Advanced. Turning it off stops analytics and clears locally stored analytics data.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 390, alignment: .leading)
        .systemLiquidGlassPopover(cornerRadius: 12)
    }

    private func detailSection(
        title: String,
        systemImage: String,
        color: Color,
        text: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Completion Step View

@MainActor
private final class CompletionAudioController {
    static let shared = CompletionAudioController()
    private var player: AVAudioPlayer?
    private var revealAccent: NSSound?
    private var fadeTask: Task<Void, Never>?

    func prepare() async {
        if revealAccent == nil {
            revealAccent = NSSound(named: "Glass")
            revealAccent?.volume = 0.15
        }
        guard player == nil else { return }
        guard let soundURL = resolvedSoundURL() else { return }
        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: soundURL, options: .mappedIfSafe)
        }.value
        guard !Task.isCancelled, player == nil, let data else { return }

        preparePlayer(data: data)
    }

    private func prepareSynchronouslyIfNeeded() {
        guard player == nil else { return }
        let soundURL = resolvedSoundURL()
        guard let soundURL else { return }

        do {
            let player = try AVAudioPlayer(contentsOf: soundURL)
            player.numberOfLoops = 0
            player.volume = 0.3
            player.prepareToPlay()
            self.player = player
        } catch {
            print("[CompletionStepView] Failed to prepare Final Onboarding sound: \(error)")
        }
    }

    private func preparePlayer(data: Data) {
        do {
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = 0
            player.volume = 0.3
            player.prepareToPlay()
            self.player = player
        } catch {
            print("[CompletionStepView] Failed to prepare Final Onboarding sound: \(error)")
        }
    }

    private func resolvedSoundURL() -> URL? {
        SortyResources.finalOnboardingSoundURL()
            ?? Bundle.main.url(forResource: "Final Onboarding", withExtension: "m4a")
    }

    func play() {
        fadeTask?.cancel()
        fadeTask = nil
        prepareSynchronouslyIfNeeded()
        player?.currentTime = 0
        player?.volume = 0.3
        player?.play()
    }

    func playRevealAccent() {
        if revealAccent == nil {
            revealAccent = NSSound(named: "Glass")
            revealAccent?.volume = 0.15
        }
        revealAccent?.play()
    }

    func fadeOutAndStop(duration: TimeInterval) {
        fadeTask?.cancel()
        guard let player else { return }
        player.setVolume(0, fadeDuration: duration)
        fadeTask = Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            player?.stop()
            self?.player = nil
            self?.fadeTask = nil
        }
    }
}

@MainActor
enum OnboardingCompletionAudio {
    static func prewarm() async {
        await CompletionAudioController.shared.prepare()
    }
}

@MainActor
private final class CompletionRuntimeController {
    var animationTask: Task<Void, Never>?
}

public struct CompletionStepView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var runtimeController = CompletionRuntimeController()

    let providerSetupStatus: ProviderSetupStatus
    let onFinish: () -> Void

    // Entry animation states
    @State private var celebrationPhase: CompletionCelebrationPhase = .hidden
    @State private var hasAppeared = false
    @State private var showGlowRing = false
    @State private var showParticles = false
    @State private var tipsAppeared = false
    @State private var isCompletionButtonHovered = false
    @State private var completionHoverTask: Task<Void, Never>?
    @State private var lockedHoverForExit: Bool?

    private let audioController = CompletionAudioController.shared
    @State private var readinessState: ReadinessState = .idle
    @State private var isAnalyticsEnabled = true

    // Exit animation states
    @State private var exitTriggered = false
    @State private var finishTask: Task<Void, Never>?
    @State private var contentDismissed = false

    private enum ReadinessState: Equatable {
        case idle
        case checking
        case failed(String)
    }

    public init(
        providerSetupStatus: ProviderSetupStatus,
        onFinish: @escaping () -> Void
    ) {
        self.providerSetupStatus = providerSetupStatus
        self.onFinish = onFinish
        _isAnalyticsEnabled = State(
            initialValue: AnalyticsManager.shared.consent != .denied
        )
    }

    public var body: some View {
        ZStack {
            CompletionContrastBackdrop()
                .allowsHitTesting(false)

            CompletionParticleBackdrop(
                showParticles: showParticles,
                exitTriggered: exitTriggered
            )

            VStack(spacing: 16) {
                CompletionHero(
                    hasAppeared: hasAppeared,
                    showGlowRing: showGlowRing,
                    celebrationPhase: celebrationPhase,
                    exitTriggered: exitTriggered,
                    contentDismissed: contentDismissed,
                    isButtonHovered: lockedHoverForExit ?? isCompletionButtonHovered
                )
                CompletionCopy(hasAppeared: hasAppeared, contentDismissed: contentDismissed)
                CompletionTipsGrid(tipsAppeared: tipsAppeared, contentDismissed: contentDismissed)
                CompletionAnalyticsPreference(isEnabled: $isAnalyticsEnabled)
                    .opacity(tipsAppeared && !contentDismissed ? 1 : 0)
                    .offset(y: tipsAppeared ? (contentDismissed ? 40 : 0) : 12)
                    .animation(
                        reduceMotion
                            ? nil
                            : .spring(response: 0.65, dampingFraction: 0.85).delay(0.16),
                        value: tipsAppeared
                    )
                CompletionPrimaryAction(
                    tipsAppeared: tipsAppeared,
                    contentDismissed: contentDismissed,
                    isChecking: readinessState == .checking,
                    action: verifyAndFinish,
                    onHoverChanged: { isHovered in
                        guard lockedHoverForExit == nil else { return }
                        completionHoverTask?.cancel()
                        // Small enter delay filters a sub-40ms swipe that would
                        // otherwise flash the app icon; leave delay keeps the
                        // exit from jittering when the cursor brushes the edge.
                        let delayMs: Int = isHovered ? 40 : 90
                        completionHoverTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(delayMs))
                            guard !Task.isCancelled else { return }
                            if reduceMotion {
                                isCompletionButtonHovered = isHovered
                            } else {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    isCompletionButtonHovered = isHovered
                                }
                            }
                        }
                    }
                )

                if case .failed(let message) = readinessState {
                    completionFailureCard(message: message)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .accessibilityIdentifier("OnboardingCompletionHealthError")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 48)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .onAppear(perform: startRevealSequence)
        .onDisappear {
            completionHoverTask?.cancel()
            completionHoverTask = nil
            finishTask?.cancel()
            finishTask = nil
            runtimeController.animationTask?.cancel()
            runtimeController.animationTask = nil
            fadeOutAndStopAudio(duration: 0.25)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Completion Step")
    }

    // MARK: - Reveal Sequence

    private func startRevealSequence() {
        runtimeController.animationTask?.cancel()

        if reduceMotion {
            audioController.play()
            celebrationPhase = .ambient
            hasAppeared = true
            showGlowRing = true
            tipsAppeared = true
            return
        }

        // Keep the appear frame free of heavy work: first paint lands the
        // static backdrop, then the bloom (audio + blob + hero) starts on the
        // next frame so blur rasterization and audio startup can't hitch it.
        // Choreography from there: glow ring at +220 ms, blob settles to
        // ambient at +540 ms, tips plus particles land together at +720 ms.
        runtimeController.animationTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            audioController.play()
            celebrationPhase = .reveal
            hasAppeared = true

            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            showGlowRing = true
            audioController.playRevealAccent()

            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            celebrationPhase = .ambient

            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            tipsAppeared = true
            showParticles = true
        }
    }

    private func fadeOutAndStopAudio(duration: TimeInterval) {
        audioController.fadeOutAndStop(duration: duration)
    }

    // MARK: - Exit Transition

    @ViewBuilder
    private func completionFailureCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Provider check failed")
                        .font(.headline)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            Text("Retry now, or skip verification and land in provider setup repair before your first organization.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Retry") {
                    verifyAndFinish()
                }
                .buttonStyle(.sortyProminent)
                .controlSize(.small)
                .accessibilityIdentifier("OnboardingCompletionRetryButton")

                Button("Skip for Now") {
                    skipVerificationAndFinish()
                }
                .buttonStyle(.sortyBordered)
                .controlSize(.small)
                .accessibilityIdentifier("OnboardingCompletionSkipButton")
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.orange.opacity(0.035))
        )
        .systemLiquidGlassBackground(cornerRadius: 16, interactive: false)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.orange.opacity(0.15), lineWidth: 1)
        )
    }

    private func verifyAndFinish() {
        let configurationStatus = providerSetupStatus
        guard configurationStatus.isReady else {
            readinessState = .failed(configurationStatus.message)
            HapticFeedbackManager.shared.error()
            return
        }

        readinessState = .idle
        startTransition(verifyProvider: true)
    }

    private func skipVerificationAndFinish() {
        appState.startSetupRepair(
            message: "Sorty could not verify \(settingsViewModel.config.provider.displayName) during onboarding. Finish provider setup in Settings before organizing files.",
            navigateToSettings: true
        )
        readinessState = .idle
        startTransition()
    }

    private func startTransition(verifyProvider: Bool = false) {
        guard !exitTriggered else { return }
        runtimeController.animationTask?.cancel()
        runtimeController.animationTask = nil
        // Lock the hero icon to its current hover state so a click while
        // showing the Sorty app icon doesn't flick back to the checkmark
        // during the exit animation.
        lockedHoverForExit = isCompletionButtonHovered
        if lockedHoverForExit == false, completionHoverTask != nil {
            // Hover-enter was still in its 40ms debounce (raw hover true but
            // delayed state not yet flipped). Treat as hovered so Sorty stays.
            lockedHoverForExit = true
            completionHoverTask?.cancel()
            completionHoverTask = nil
        }
        let exitDuration = reduceMotion ? 0 : 0.52
        HapticFeedbackManager.shared.success()
        fadeOutAndStopAudio(duration: exitDuration)

        // Let the completed onboarding settle away before the main window
        // appears, rather than replacing the whole experience in one frame.
        withAnimation(reduceMotion ? nil : .easeInOut(duration: exitDuration)) {
            exitTriggered = true
            contentDismissed = true
            showParticles = false
            showGlowRing = false
        }

        finishTask?.cancel()
        finishTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(exitDuration))
            guard !Task.isCancelled, exitTriggered else { return }
            AnalyticsManager.shared.setConsent(isAnalyticsEnabled ? .granted : .denied)
            onFinish()

            if verifyProvider {
                // Outlive this view, but let the main app's 220 ms dissolve
                // settle before provider setup can publish repair state.
                let viewModel = settingsViewModel
                let state = appState
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    do {
                        try await viewModel.testConnection()
                        state.clearSetupRepairState()
                    } catch {
                        state.startSetupRepair(
                            message: "Sorty could not verify \(viewModel.config.provider.displayName). "
                                + error.localizedDescription,
                            navigateToSettings: false
                        )
                    }
                }
            }
        }
    }
}

private struct CompletionContrastBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @SortyHotReload private var hotReload
    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).opacity(0.38)

            LinearGradient(
                colors: [
                    Color.black.opacity(colorScheme == .dark ? 0.22 : 0),
                    Color.clear,
                    Color.black.opacity(colorScheme == .dark ? 0.10 : 0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    CompletionPalette.softRose.opacity(0.18),
                    CompletionPalette.accent.opacity(0.08),
                    Color.clear
                ],
                center: UnitPoint(x: 0.50, y: 0.42),
                startRadius: 20,
                endRadius: 520
            )
        }
        .mask(alignment: .top) {
            VStack(spacing: 0) {
                LinearGradient(
                    stops: [
                        .init(color: Color.clear, location: 0.00),
                        .init(color: Color.clear, location: 0.16),
                        .init(color: Color.black.opacity(0.18), location: 0.46),
                        .init(color: Color.black.opacity(0.62), location: 0.76),
                        .init(color: Color.black, location: 1.00)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 300)

                Color.black
            }
        }
        .ignoresSafeArea()
    }
}

struct QuickTipRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @SortyHotReload private var hotReload
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(CompletionPalette.accent.opacity(0.14))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                CompletionPalette.softRose.opacity(0.24),
                                lineWidth: 0.5
                            )
                    )

                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? CompletionPalette.softRose : CompletionPalette.deepRose)
            }

            Text(text)
                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    let codexAuthManager = CodexCLIAuthManager()

    CompletionStepView(
        providerSetupStatus: ProviderSetupStatus(
            isReady: true,
            title: "Setup complete",
            message: "Provider is ready."
        ),
        onFinish: {}
    )
        .environmentObject(SettingsViewModel())
        .environmentObject(AppState())
        .environmentObject(codexAuthManager)
}
