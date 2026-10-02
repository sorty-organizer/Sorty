#if os(macOS)
import AppKit
#endif
import SwiftUI

// MARK: - Public API

public extension View {
  /// Overlays an animated, metal-shader-rendered border beam on the receiver.
  ///
  /// ```swift
  /// RoundedRectangle(cornerRadius: 16)
  ///     .fill(.regularMaterial)
  ///     .beam()                                // default: medium, colorful, dark
  ///
  /// Button("Generate") { ... }
  ///     .beam(.small, palette: .ocean)
  ///
  /// SearchField(...)
  ///     .beam(.line, palette: .sunset, active: isSearching)
  /// ```
  ///
  /// - Parameters:
  ///   - size: `.medium` (card-sized, default), `.small` (button-sized), or
  ///     `.line` (traveling beam along the bottom edge).
  ///   - palette: one of `.colorful`, `.mono`, `.ocean`, `.sunset`.
  ///   - theme: `.dark` (default — white highlights on dark surfaces) or
  ///     `.light` (muted pastel beam on white surfaces).
  ///   - active: drives fade in/out. `true` fades in over 0.6 s, `false`
  ///     fades out over 0.5 s. Rendering is fully suspended while faded out.
  ///   - shape: geometric shape the beam traces. Defaults to a rounded rect
  ///     using `cornerRadius`. `.capsule` pills; `.circle` traces the
  ///     inscribed circle. Only honored for `.medium` and `.small` — `.line`
  ///     always renders its own bottom-edge bar. When `shape` is provided,
  ///     `cornerRadius` is ignored.
  ///   - cornerRadius: corner radius for the default rounded-rect shape.
  ///     Defaults to a size-appropriate value (16 for medium/line, 18 for
  ///     small). Ignored when `shape` is set.
  ///   - duration: seconds per full rotation around the border. Defaults to
  ///     1.96 s for medium/small, 2.4 s for line.
  ///   - strength: overall opacity multiplier in `0...1`. `1.0` is full intensity.
  ///   - lensStrength: pixel magnitude of a liquid-glass distortion that
  ///     warps the content *under* the beam as the head passes over it.
  ///     `0` (default) disables the lens. Try `3...6` for a subtle pull;
  ///     higher values read as an obvious bulge. Applied to the receiver
  ///     before the beam overlay, so it only warps what's behind the beam,
  ///     not the beam itself.
  ///   - pulse: a hashable token (typically an incrementing counter, message
  ///     ID, or UUID) that triggers a one-shot lap whenever its value
  ///     changes. Use for transient affordances — a message landed, a file
  ///     saved, a task finished. Independent of `active`: works even when
  ///     `active: false`.
  ///   - onActivate: called when the fade-in completes (or immediately when
  ///     Reduce Motion is on and the beam snaps in).
  ///   - onDeactivate: called when the fade-out completes (or immediately
  ///     when Reduce Motion is on and the beam snaps out).
  func beam(
    _ size: BeamSize = .medium,
    palette: BeamPalette = .colorful,
    theme: BeamTheme = .dark,
    active: Bool = true,
    shape: BeamShape? = nil,
    cornerRadius: CGFloat? = nil,
    duration: Double? = nil,
    strength: Double = 1.0,
    lensStrength: Double = 0,
    pulse: AnyHashable? = nil,
    onActivate: (() -> Void)? = nil,
    onDeactivate: (() -> Void)? = nil
  ) -> some View {
    let presets = ThemePresets.resolve(size: size, theme: theme)
    let fallbackRadius = cornerRadius ?? (size == .small ? 18 : 16)
    let resolvedShape = shape ?? .roundedRect(cornerRadius: fallbackRadius)
    let resolvedDuration = duration ?? (size == .line ? 2.4 : 1.96)
    return modifier(BeamModifier(
      size: size,
      palette: palette,
      shape: resolvedShape,
      cornerRadiusFallback: fallbackRadius,
      duration: resolvedDuration,
      strength: strength,
      lensStrength: lensStrength,
      presets: presets,
      active: active,
      pulse: pulse,
      onActivate: onActivate,
      onDeactivate: onDeactivate
    ))
  }
}

// MARK: - ViewModifier

/// Implementation detail of `.beam(...)`. Owns the fade-in/out
/// lifecycle state and drives the Metal shader via a `TimelineView`.
///
/// The modifier collapses the shader's many individual uniforms into a
/// single `ThemePresets` bundle at construction time so the stored
/// property count stays manageable. Per-frame uniforms (time, hue) are
/// computed inside the `TimelineView` closure.
struct BeamModifier: ViewModifier {
  // Immutable configuration
  let size: BeamSize
  let palette: BeamPalette
  let shape: BeamShape
  /// Corner radius the shader reads for capsule/circle shapes. The shader
  /// doesn't use it in those cases, but we still forward a sensible number
  /// rather than leaving the uniform lane undefined.
  let cornerRadiusFallback: CGFloat
  let duration: Double
  let strength: Double
  /// Max pixel offset applied to the receiver by the lens distortion
  /// shader. `0` skips the distortion effect entirely. Keep small (3–6)
  /// for a subtle "glass moving over a surface" look.
  let lensStrength: Double
  let presets: ThemePresets
  let active: Bool
  /// Optional one-shot pulse token. Each time this value changes, the beam
  /// plays a single lap regardless of `active`. nil → no pulse behaviour.
  let pulse: AnyHashable?
  let onActivate: (() -> Void)?
  let onDeactivate: (() -> Void)?

  // Respect the system's Reduce Motion preference: freeze the TimelineView at
  // a single frame and snap fade transitions instead of easing them.
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.controlActiveState) private var controlActiveState
  @State private var isWindowVisible = false

  private var isRenderingPaused: Bool {
    reduceMotion || controlActiveState == .inactive
      || !isWindowVisible
  }

  // Lifecycle state — drives the 0.6 s / 0.5 s fade in/out.
  @State private var visualOpacity: Double = 0

  /// Incremented on every state change that schedules a callback. The delayed
  /// task checks that its captured generation still matches before firing —
  /// prevents a rapid `active=true → false → true` toggle from firing stale
  /// `onDeactivate` after a later fade-in already started.
  @State private var transitionGeneration: Int = 0

  /// Content's rendered size, measured via a background GeometryReader.
  /// Used by the lens distortion shader to locate the beam head position.
  @State private var measuredContentSize: CGSize = .zero

  /// Overall opacity multiplier applied to the `.mono` palette. Bright
  /// grayscale values read louder than saturated hues at the same alpha,
  /// so we halve the opacity to keep the mono beam visually matched.
  private var monoMultiplier: Double { palette == .mono ? 0.5 : 1.0 }

  func body(content: Content) -> some View {
    // Apply the optional lens distortion to the receiver *before* the
    // overlay — that way the lens only warps the receiver's content, not
    // the beam itself sitting on top of it.
    lensApplied(content)
      .background {
        #if os(macOS)
        BeamWindowVisibilityReader(isVisible: $isWindowVisible)
        #else
        Color.clear.onAppear { isWindowVisible = true }
        #endif
      }
      .overlay {
      Group {
        if visualOpacity > 0.001 {
          beamOverlay
            .opacity(visualOpacity)
        }
      }
      .allowsHitTesting(false)
      // The beam is purely decorative — VoiceOver shouldn't announce it.
      .accessibilityHidden(true)
    }
    .onAppear {
      guard active else { return }
      withAnimation(fadeInAnimation) { visualOpacity = 1.0 }
      scheduleCallback(isActive: true)
    }
    .onChange(of: active) { _, isActive in
      withAnimation(isActive ? fadeInAnimation : fadeOutAnimation) {
        visualOpacity = isActive ? 1.0 : 0.0
      }
      scheduleCallback(isActive: isActive)
    }
    .onChange(of: pulse) { _, newValue in
      // `.onChange` only fires when the value differs from the previous
      // render, so first-mount doesn't trigger a ghost pulse.
      guard newValue != nil else { return }
      triggerPulse()
    }
  }

  /// Plays a single lap: fade in → hold for one full beam rotation → fade
  /// out. Reuses the same `transitionGeneration` token as `active` so a
  /// rapid pulse-then-active-flip doesn't cross wires with the fade-out
  /// task from a previous pulse.
  private func triggerPulse() {
    transitionGeneration += 1
    let generation = transitionGeneration

    withAnimation(fadeInAnimation) { visualOpacity = 1.0 }

    let inDelay: TimeInterval = reduceMotion ? 0 : 0.6
    let holdDelay: TimeInterval = duration
    let outDelay: TimeInterval = reduceMotion ? 0 : 0.5

    Task { @MainActor in
      if inDelay > 0 { try? await Task.sleep(for: .seconds(inDelay)) }
      guard generation == transitionGeneration else { return }
      onActivate?()

      try? await Task.sleep(for: .seconds(holdDelay))
      guard generation == transitionGeneration else { return }
      withAnimation(fadeOutAnimation) { visualOpacity = 0.0 }

      if outDelay > 0 { try? await Task.sleep(for: .seconds(outDelay)) }
      guard generation == transitionGeneration else { return }
      onDeactivate?()
    }
  }

  /// Fires the appropriate callback after the fade transition completes. When
  /// Reduce Motion is on the delay is zero so the callback runs on the next
  /// runloop tick.
  private func scheduleCallback(isActive: Bool) {
    let callback = isActive ? onActivate : onDeactivate
    guard let callback else { return }

    transitionGeneration += 1
    let generation = transitionGeneration
    let delay: TimeInterval = reduceMotion ? 0 : (isActive ? 0.6 : 0.5)

    Task { @MainActor in
      if delay > 0 {
        try? await Task.sleep(for: .seconds(delay))
      }
      guard generation == transitionGeneration else { return }
      callback()
    }
  }

  /// The animated shader overlay. Split out so the `if visualOpacity` guard
  /// in `body` can suspend the entire `TimelineView` — no GPU work happens
  /// while the beam is faded out. When Reduce Motion is on the schedule is
  /// paused, so `timeline.date` freezes and the shader renders a single
  /// static frame.
  @ViewBuilder
  private var beamOverlay: some View {
    TimelineView(
      .animation(
        minimumInterval: 1.0 / 30.0,
        paused: isRenderingPaused
      )
    ) { timeline in
      // `timeIntervalSinceReferenceDate` is ~2.5e9 s, which loses ~1 ms of
      // precision when downcast to Float. Wrap into a 1000 s window so the
      // shader sees a high-precision time value.
      let t = timeline.date.timeIntervalSinceReferenceDate
        .truncatingRemainder(dividingBy: 1000)
      GeometryReader { proxy in
        Rectangle()
          .foregroundStyle(makeShader(pixelSize: proxy.size, time: t))
      }
    }
  }

  /// Wraps `content` in a distortionEffect that warps its pixels along
  /// with the beam's head position. When `lensStrength` is 0 or the beam
  /// is faded out the effect is fully disabled — no per-frame shader eval,
  /// no max-offset padding, no content re-render.
  @ViewBuilder
  private func lensApplied(_ content: Content) -> some View {
    if lensStrength > 0 && !reduceMotion && visualOpacity > 0.001 {
      TimelineView(
        .animation(
          minimumInterval: 1.0 / 30.0,
          paused: isRenderingPaused
        )
      ) { timeline in
        let t = timeline.date.timeIntervalSinceReferenceDate
          .truncatingRemainder(dividingBy: 1000)
        content
          .distortionEffect(
            ShaderDispatch.lensShader(
              pixelSize: measuredContentSize,
              time: t,
              duration: duration,
              strength: lensStrength * visualOpacity
            ),
            maxSampleOffset: CGSize(width: lensStrength, height: lensStrength)
          )
          .background {
            GeometryReader { proxy in
              Color.clear.task(id: proxy.size) { measuredContentSize = proxy.size }
            }
          }
      }
    } else {
      content
    }
  }

  private var fadeInAnimation: Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.6)
  }

  private var fadeOutAnimation: Animation? {
    reduceMotion ? nil : .easeIn(duration: 0.5)
  }

  private func makeShader(pixelSize: CGSize, time: TimeInterval) -> Shader {
    // Ping-pong hue oscillation driven by a cosine so the curve eases in and
    // out at both extrema without needing a piecewise tween. The beam's hue
    // sweeps across `±hueRangeDeg` once per `hueCycleSeconds`:
    //   t=0 → -30°,   t=6s → +30°,   t=12s → -30°
    let hueShiftDeg = -BeamTiming.hueRangeDeg
    * cos((time / BeamTiming.hueCycleSeconds) * 2.0 * .pi)
    let hueShiftRad = hueShiftDeg * .pi / 180.0

    // The rotation angle is uniform across the draw, so precompute cos/sin
    // here instead of having the shader evaluate them at every pixel.
    let hueCos = cos(hueShiftRad)
    let hueSin = sin(hueShiftRad)

    // Palette ellipses have fixed pixel sizes tuned for the reference card
    // (~370×144 for medium). Grow them with the card's shorter dimension so
    // spots stay visually dense on large iPad cards. Clamped at 1.0 so small
    // cards don't shrink below the reference tuning.
    let paletteScale = BeamTiming.paletteScale(size: size, pixelSize: pixelSize)

    return ShaderDispatch.shader(
      size: size,
      pixelSize: pixelSize,
      cornerRadius: shape.cornerRadiusUniform(fallback: cornerRadiusFallback),
      borderWidth: 1,
      time: time,
      duration: duration,
      strokeOpacity: presets.strokeOpacity * monoMultiplier,
      innerOpacity: presets.innerOpacity * monoMultiplier,
      bloomOpacity: presets.bloomOpacity * monoMultiplier,
      strength: strength,
      brightness: BeamTiming.brightness,
      saturation: presets.saturation,
      variant: Float(palette.rawValue),
      inkLuma: presets.inkLuma,
      innerShadowAlpha: presets.innerShadowAlpha,
      inkAlphaScale: presets.inkAlphaScale,
      hueCos: hueCos,
      hueSin: hueSin,
      paletteScale: paletteScale,
      shapeType: shape.shaderID
    )
  }
}

#if os(macOS)
/// Window visibility is independent of keyboard focus. A minimized or fully
/// covered window must park both timelines even if its controls stay active.
private struct BeamWindowVisibilityReader: NSViewRepresentable {
  @Binding var isVisible: Bool

  func makeCoordinator() -> Coordinator { Coordinator(isVisible: $isVisible) }

  func makeNSView(context: Context) -> ProbeView {
    let view = ProbeView()
    view.onWindowChange = { [weak coordinator = context.coordinator] window in
      coordinator?.observe(window)
    }
    return view
  }

  func updateNSView(_ view: ProbeView, context: Context) {
    context.coordinator.isVisible = $isVisible
    context.coordinator.observe(view.window)
  }

  static func dismantleNSView(_ view: ProbeView, coordinator: Coordinator) {
    coordinator.observe(nil)
    view.onWindowChange = nil
  }

  @MainActor
  final class Coordinator {
    var isVisible: Binding<Bool>
    private weak var observedWindow: NSWindow?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(isVisible: Binding<Bool>) { self.isVisible = isVisible }

    func observe(_ window: NSWindow?) {
      guard observedWindow !== window else { return }
      let center = NotificationCenter.default
      observers.forEach(center.removeObserver)
      observers.removeAll()
      observedWindow = window
      if let window {
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
          observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
          })
        }
      }
      refresh()
    }

    private func refresh() {
      let visible = observedWindow.map {
        $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
      } ?? false
      if isVisible.wrappedValue != visible { isVisible.wrappedValue = visible }
    }

    deinit {
      observers.forEach(NotificationCenter.default.removeObserver)
    }
  }

  final class ProbeView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onWindowChange?(window)
    }
  }
}
#endif

// MARK: - Timing constants

/// Timing and tuning values that are shared across every beam instance. Kept
/// as a single namespace so contributors adjusting the feel of the animation
/// have one obvious place to look.
private enum BeamTiming {
  /// Half-range of the hue oscillation in degrees. The beam's hue sweeps
  /// `-hueRangeDeg ↔ +hueRangeDeg` once per `hueCycleSeconds`.
  static let hueRangeDeg: Double = 30

  /// Period of the hue oscillation in seconds.
  static let hueCycleSeconds: Double = 12

  /// Constant brightness bump applied inside the shader to compensate for the
  /// dimming that premultiplied-alpha compositing introduces at low stroke
  /// opacities. Empirically tuned — values much above 1.3 clip highlights.
  static let brightness: Double = 1.30

  /// Shorter-dimension (pt) the palette spots were originally sized for, per
  /// size variant. When the rendered card is larger than this, the shader's
  /// fixed-pixel spots start leaving visible gaps on the beam's lit edge;
  /// `paletteScale` grows them proportionally to close the gaps.
  ///
  /// The reference is the card size used in the Gallery scenes — the only
  /// place the palette was hand-tuned side-by-side with the React original.
  static func paletteScale(size: BeamSize, pixelSize: CGSize) -> Double {
    let reference: Double
    switch size {
    case .medium, .comet: reference = 144
    case .small:          reference = 36
    case .line:           reference = 40
    }
    let shorter = Double(min(pixelSize.width, pixelSize.height))
    return max(1.0, shorter / reference)
  }
}
