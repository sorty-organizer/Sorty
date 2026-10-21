import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI


@MainActor
enum CompletionPalette {
    static var accent: Color { SortyDesignSystem.Colors.resolvedAccent }
    static let softRose = Color(red: 1.0, green: 0.48, blue: 0.58)
    static let deepRose = Color(red: 0.42, green: 0.19, blue: 0.25)
    static let shadowRose = Color(red: 0.22, green: 0.10, blue: 0.14)
}

// MARK: - Completion Celebration Blob

/// Phased ambient backdrop for the completion celebration. The blob leads the
/// entrance (reveal), then settles into a quiet breathing ambient state.
enum CompletionCelebrationPhase: Int {
    case hidden
    case reveal
    case ambient
}

struct RetainedCompletionCelebrationBlob: NSViewRepresentable {
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
final class RetainedCompletionCelebrationBlobView: NSView {
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
    private var lastLayoutBounds: CGRect?

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
        guard lastLayoutBounds != bounds else { return }
        lastLayoutBounds = bounds
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
        let celebrationChanged = lastPhase != phase
            || lastExitTriggered != exitTriggered
            || lastReduceMotion != reduceMotion
        guard celebrationChanged || lastIsActive != isActive else { return }
        lastIsActive = isActive

        // Focus changes only pause the layer clock. Reapplying the phase would
        // restart the reveal/settle and invalidate the settled blur surfaces.
        guard celebrationChanged else {
            if isActive {
                resumeIfNeeded()
            } else {
                pauseIfNeeded()
            }
            return
        }
        lastPhase = phase
        lastExitTriggered = exitTriggered
        lastReduceMotion = reduceMotion
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
