import QuartzCore

/// Pauses a retained animation tree without resetting its phase. Each view
/// owns a clock and decides when visibility or animation state permits pausing.
@MainActor
struct OnboardingLayerClock {
    private(set) var isPaused = false

    mutating func pause(_ layer: CALayer?) {
        guard !isPaused, let layer else { return }
        let pausedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = pausedTime
        isPaused = true
    }

    mutating func resume(_ layer: CALayer?) {
        guard isPaused, let layer else { return }
        let pausedTime = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        isPaused = false
    }
}
