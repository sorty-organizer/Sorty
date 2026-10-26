import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import os

struct OnboardingOrbitFile: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let ext: String
    // Scattered resting position (offset from center).
    let baseX: CGFloat
    let baseY: CGFloat
    // Lazy floating motion.
    let driftPhase: Double
    let driftSpeed: Double
    let driftRadius: CGFloat
    let orbitWidth: CGFloat
    let orbitHeight: CGFloat
    // Messy presentation.
    let rotation: Double
    let scale: CGFloat
    let appearDelay: Double
    // Relative placement within the Get Started button when the pile collapses.
    let collapseX: CGFloat
    let collapseY: CGFloat

    // Stagger phases and speeds to keep neighboring files from moving together.
    static let files: [OnboardingOrbitFile] = [
        OnboardingOrbitFile(name: "Q3 Report", ext: "pdf", baseX: -292, baseY: -118, driftPhase: 0.0, driftSpeed: 0.62, driftRadius: 22, orbitWidth: 84, orbitHeight: 46, rotation: -13, scale: 1.04, appearDelay: 0.05, collapseX: -30, collapseY: -18),
        OnboardingOrbitFile(name: "Budget 2024", ext: "xlsx", baseX: 286, baseY: -104, driftPhase: 1.3, driftSpeed: 0.74, driftRadius: 20, orbitWidth: 72, orbitHeight: 52, rotation: 11, scale: 0.96, appearDelay: 0.12, collapseX: 26, collapseY: -22),
        OnboardingOrbitFile(name: "vacation", ext: "jpg", baseX: -244, baseY: 118, driftPhase: 2.1, driftSpeed: 0.68, driftRadius: 24, orbitWidth: 78, orbitHeight: 56, rotation: 8, scale: 1.1, appearDelay: 0.18, collapseX: -34, collapseY: 14),
        OnboardingOrbitFile(name: "Resume", ext: "docx", baseX: 242, baseY: 132, driftPhase: 3.4, driftSpeed: 0.58, driftRadius: 22, orbitWidth: 90, orbitHeight: 48, rotation: -9, scale: 1.0, appearDelay: 0.24, collapseX: 30, collapseY: 20),
        OnboardingOrbitFile(name: "demo", ext: "mp4", baseX: -344, baseY: 8, driftPhase: 0.7, driftSpeed: 0.80, driftRadius: 20, orbitWidth: 68, orbitHeight: 42, rotation: 6, scale: 0.92, appearDelay: 0.3, collapseX: -44, collapseY: 0),
        OnboardingOrbitFile(name: "Keynote", ext: "key", baseX: 350, baseY: 24, driftPhase: 4.2, driftSpeed: 0.66, driftRadius: 24, orbitWidth: 80, orbitHeight: 52, rotation: -7, scale: 0.94, appearDelay: 0.36, collapseX: 44, collapseY: 4),
        OnboardingOrbitFile(name: "logo", ext: "png", baseX: -142, baseY: -194, driftPhase: 5.0, driftSpeed: 0.72, driftRadius: 22, orbitWidth: 68, orbitHeight: 42, rotation: 14, scale: 0.88, appearDelay: 0.1, collapseX: -16, collapseY: -28),
        OnboardingOrbitFile(name: "playlist", ext: "mp3", baseX: 152, baseY: -198, driftPhase: 2.7, driftSpeed: 0.78, driftRadius: 22, orbitWidth: 70, orbitHeight: 48, rotation: -12, scale: 0.9, appearDelay: 0.16, collapseX: 18, collapseY: -30),
        OnboardingOrbitFile(name: "data", ext: "csv", baseX: -126, baseY: 194, driftPhase: 1.8, driftSpeed: 0.64, driftRadius: 20, orbitWidth: 64, orbitHeight: 42, rotation: -5, scale: 0.86, appearDelay: 0.22, collapseX: -14, collapseY: 26),
        OnboardingOrbitFile(name: "archive", ext: "zip", baseX: 128, baseY: 204, driftPhase: 3.9, driftSpeed: 0.76, driftRadius: 24, orbitWidth: 70, orbitHeight: 48, rotation: 10, scale: 0.9, appearDelay: 0.28, collapseX: 16, collapseY: 28)
    ]
}

struct OnboardingSourceIcon: @unchecked Sendable {
    let fileExtension: String
    let image: CGImage
}

struct OnboardingRasterizedIcon: @unchecked Sendable {
    let fileExtension: String
    let image: CGImage
}

/// Provides (and caches) the real macOS file-type icon for a given extension.
@MainActor
enum OnboardingFileIconProvider {
    private static var cache: [String: NSImage] = [:]
    private static let iconPointSize = NSSize(width: 46, height: 46)

    static func icons(for files: [OnboardingOrbitFile]) async -> [String: NSImage] {
        let extensions = Set(files.map(\.ext))
        var resolved = cache.filter { extensions.contains($0.key) }
        let missing = extensions.subtracting(resolved.keys)
        let sources = missing.compactMap(sourceIcon(for:))
        let rasterized = await Task.detached(priority: .userInitiated) {
            sources.compactMap(rasterizedIcon)
        }.value
        for item in rasterized {
            let bitmap = NSBitmapImageRep(cgImage: item.image)
            bitmap.size = iconPointSize
            let image = NSImage(size: iconPointSize)
            image.addRepresentation(bitmap)
            cache[item.fileExtension] = image
            resolved[item.fileExtension] = image
        }
        return resolved
    }

    private static func sourceIcon(for ext: String) -> OnboardingSourceIcon? {
        let workspaceImage: NSImage
        if let type = UTType(filenameExtension: ext) {
            workspaceImage = NSWorkspace.shared.icon(for: type)
        } else {
            workspaceImage = NSWorkspace.shared.icon(forFileType: ext)
        }
        var proposedRect = NSRect(origin: .zero, size: iconPointSize)
        guard let image = workspaceImage.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        return OnboardingSourceIcon(fileExtension: ext, image: image)
    }

    /// `NSWorkspace` returns shared, multi-representation images whose best
    /// representation may be decoded or replaced on a later draw. Resolve one
    /// immutable Retina bitmap before the reveal so moving cards never trigger
    /// icon decoding or representation changes mid-animation.
    nonisolated private static func rasterizedIcon(
        _ source: OnboardingSourceIcon
    ) -> OnboardingRasterizedIcon? {
        let pixelsWide = 92
        let pixelsHigh = 92
        guard let context = CGContext(
            data: nil,
            width: pixelsWide,
            height: pixelsHigh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(source.image, in: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        guard let image = context.makeImage() else { return nil }
        return OnboardingRasterizedIcon(fileExtension: source.fileExtension, image: image)
    }
}

struct OnboardingOrbitFileChip: View, @MainActor Equatable {
    @SortyHotReload private var hotReload
    let file: OnboardingOrbitFile
    let icon: NSImage
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.file.id == rhs.file.id && lhs.icon === rhs.icon
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 46, height: 46)

            Text("\(file.name).\(file.ext)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardFill)
        )
        .systemLiquidGlassBackground(
            cornerRadius: 16,
            clear: colorScheme == .light,
            interactive: false
        )
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.30 : 0.06),
            radius: colorScheme == .dark ? 16 : 10,
            x: 0,
            y: colorScheme == .dark ? 12 : 6
        )
        .accessibilityHidden(true)
    }

    private var cardFill: Color {
        colorScheme == .dark
            ? Color.primary.opacity(0.025)
            : Color(nsColor: .controlBackgroundColor).opacity(0.58)
    }
}

struct OnboardingOrbitField: NSViewRepresentable {
    @SortyHotReload private var hotReload
    let icons: [String: NSImage]
    let filesVisible: Bool
    let isCollapsed: Bool
    let collapseOrigin: CGSize
    let reduceMotion: Bool
    let isActive: Bool

    func makeNSView(context: Context) -> OnboardingOrbitFieldView {
        OnboardingOrbitFieldView()
    }

    func updateNSView(_ nsView: OnboardingOrbitFieldView, context: Context) {
        nsView.update(
            icons: icons,
            filesVisible: filesVisible,
            isCollapsed: isCollapsed,
            collapseOrigin: collapseOrigin,
            reduceMotion: reduceMotion,
            isActive: isActive
        )
    }
}

/// Keeps every material-backed file chip mounted and updates only compositor
/// state. Each chip's hosting view sits at a fixed frame inside a full-size
/// wrapper, and all motion is applied through the wrapper layer's
/// `sublayerTransform`. AppKit owns the `position` and `transform` of
/// layer-backed views and resets them on its next geometry sync (the first
/// layout pass, any `frame` assignment, hosting-view resizes); writing them
/// directly made chips snap to the corner or lose their scale for a frame.
/// Visibility goes through `alphaValue` for the same reason. The display link
/// runs only during hover transitions.
@MainActor
final class OnboardingOrbitFieldView: NSView {
    /// Matches ProMotion while the hover spring runs. The idle orbit already
    /// animates at the display's rate on the compositor, so a 60 Hz spring
    /// visibly halved the motion's frame rate the moment the pointer reached
    /// Get Started. The link is paused outside those short springs.
    private static let interactionFrameRate: Float = 120
    nonisolated private static let idleSampleRate = 60.0
    private static let springResponse = 0.48
    private static let springDamping = 0.90

    private var wrappers: [UUID: OnboardingOrbitChipWrapper] = [:]
    private var hosts: [UUID: NSHostingView<OnboardingOrbitFileChip>] = [:]
    private var hostedIcons: [UUID: NSImage] = [:]
    private var hostSizes: [UUID: CGSize] = [:]
    private var revealWorkItems: [DispatchWorkItem] = []
    private var revealedFileIDs: Set<UUID> = []
    private var orbitDisplayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var orbitPhase: CFTimeInterval = 0
    private var idleAnimationStartedAt: CFTimeInterval?
    private var idleAnimationBasePhase: CFTimeInterval = 0
    private var collapseProgress: CGFloat = 0
    private var collapseVelocity: CGFloat = 0
    private var collapseTarget: CGFloat = 0
    private var collapseOrigin: CGSize = .zero
    private var filesVisible = false
    private var reduceMotion = false
    private var isActive = true
    private var configuredIcons: [String: NSImage] = [:]
    struct IdleSamples: Sendable {
        let fileID: UUID
        let positions: [CGPoint]
        let rotations: [Double]
    }

    private var animationBounds: CGRect = .zero
    private var idlePreparationTask: Task<Void, Never>?
    private var idleOffsets: [UUID: [CGPoint]] = [:]
    private var translationAnimations: [UUID: CAKeyframeAnimation] = [:]
    private var rotationAnimations: [UUID: CAKeyframeAnimation] = [:]

    override var isFlipped: Bool { true }

    /// The orbit spans the full intro window but is entirely decorative. Keep
    /// AppKit from traversing its material-backed hosting views for every mouse
    /// event; SwiftUI's `allowsHitTesting(false)` does not prevent that native
    /// subtree walk inside an `NSViewRepresentable`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
        installHosts(icons: [:])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            prepareIdleAnimationsIfNeeded()
            updateHostRasterizationScale()
            installDisplayLinkIfNeeded()
        } else {
            idlePreparationTask?.cancel()
            idlePreparationTask = nil
            stopIdleAnimations(preservingPhase: false)
            revealWorkItems.forEach { $0.cancel() }
            revealWorkItems.removeAll()
            orbitDisplayLink?.invalidate()
            orbitDisplayLink = nil
            lastTimestamp = nil
        }
    }

    override func layout() {
        super.layout()
        for wrapper in wrappers.values where wrapper.frame != bounds {
            wrapper.frame = bounds
        }
        if idleAnimationStartedAt != nil, animationBounds != bounds {
            stopIdleAnimations(preservingPhase: true)
            updateMotionState()
        } else if idleAnimationStartedAt == nil {
            renderFrame()
        }
    }

    func update(
        icons: [String: NSImage],
        filesVisible: Bool,
        isCollapsed: Bool,
        collapseOrigin: CGSize,
        reduceMotion: Bool,
        isActive: Bool
    ) {
        let iconsChanged = !iconsMatchConfiguredImages(icons)
        let stateChanged = self.filesVisible != filesVisible
            || collapseTarget != (isCollapsed ? 1 : 0)
            || self.collapseOrigin != collapseOrigin
            || self.reduceMotion != reduceMotion
            || self.isActive != isActive

        guard iconsChanged || stateChanged else { return }

        if iconsChanged {
            installHosts(icons: icons)
            updateHostedIcons(icons)
            configuredIcons = icons
        }

        if self.filesVisible != filesVisible {
            self.filesVisible = filesVisible
            updateReveal(visible: filesVisible)
        }

        if collapseTarget != (isCollapsed ? 1 : 0), idleAnimationStartedAt != nil {
            stopIdleAnimations(preservingPhase: true)
        }

        self.collapseOrigin = collapseOrigin
        self.reduceMotion = reduceMotion
        self.isActive = isActive
        collapseTarget = isCollapsed ? 1 : 0

        if reduceMotion {
            collapseProgress = collapseTarget
            collapseVelocity = 0
        }

        updateMotionState()
        if idleAnimationStartedAt == nil {
            renderFrame()
        }
    }

    private func iconsMatchConfiguredImages(_ icons: [String: NSImage]) -> Bool {
        guard icons.count == configuredIcons.count else { return false }
        return icons.allSatisfy { key, image in
            configuredIcons[key] === image
        }
    }

    private func installHosts(icons: [String: NSImage]) {
        for file in OnboardingOrbitFile.files where hosts[file.id] == nil {
            guard let icon = icons[file.ext] else { continue }
            let wrapper = OnboardingOrbitChipWrapper(frame: bounds)
            wrapper.alphaValue = 0
            let host = NSHostingView(rootView: OnboardingOrbitFileChip(file: file, icon: icon))
            host.wantsLayer = true
            host.layer?.masksToBounds = false
            host.layer?.shouldRasterize = true
            host.layer?.rasterizationScale = window?.backingScaleFactor ?? 2
            wrapper.addSubview(host)
            addSubview(wrapper)
            wrappers[file.id] = wrapper
            hosts[file.id] = host
            hostedIcons[file.id] = icon
            placeHost(host, for: file)
        }
    }

    /// Centers the chip on the wrapper's origin, so the wrapper's
    /// `sublayerTransform` rotates and scales it about its own center.
    private func placeHost(_ host: NSHostingView<OnboardingOrbitFileChip>, for file: OnboardingOrbitFile) {
        let size = host.fittingSize
        hostSizes[file.id] = size
        let frame = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        if host.frame != frame {
            host.frame = frame
        }
    }

    /// Cache each finished material card as one compositor surface. The cards'
    /// contents change only when their resolved file icons change, while their
    /// wrapper transforms animate continuously.
    private func updateHostRasterizationScale() {
        let scale = window?.backingScaleFactor ?? 2
        for host in hosts.values {
            host.layer?.rasterizationScale = scale
        }
    }

    private func updateHostedIcons(_ icons: [String: NSImage]) {
        for file in OnboardingOrbitFile.files {
            guard let icon = icons[file.ext] else { continue }
            guard hostedIcons[file.id] !== icon, let host = hosts[file.id] else { continue }
            hostedIcons[file.id] = icon
            host.rootView = OnboardingOrbitFileChip(file: file, icon: icon)
            placeHost(host, for: file)
        }
    }

    private func updateReveal(visible: Bool) {
        revealWorkItems.forEach { $0.cancel() }
        revealWorkItems.removeAll()

        guard visible else {
            revealedFileIDs.removeAll()
            wrappers.values.forEach { $0.alphaValue = 0 }
            return
        }

        for file in OnboardingOrbitFile.files {
            let workItem = DispatchWorkItem { [weak self] in
                self?.reveal(file: file)
            }
            revealWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + file.appearDelay, execute: workItem)
        }
    }

    private func reveal(file: OnboardingOrbitFile) {
        guard let wrapper = wrappers[file.id] else { return }
        revealedFileIDs.insert(file.id)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.7
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            wrapper.animator().alphaValue = 1
        }
    }

    private func installDisplayLinkIfNeeded() {
        guard orbitDisplayLink == nil else { return }
        let displayLink = self.displayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:))
        )
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60,
            maximum: Self.interactionFrameRate,
            preferred: Self.interactionFrameRate
        )
        displayLink.add(to: .main, forMode: .common)
        orbitDisplayLink = displayLink
        updateMotionState()
    }

    private func updateMotionState() {
        let springIsMoving = abs(collapseProgress - collapseTarget) > 0.0005
            || abs(collapseVelocity) > 0.0005
        // The display link only drives hover-transition springs; idle drift
        // runs on compositor keyframes. Paused while inactive, occluded, or
        // under Reduce Motion so no frames burn offscreen.
        let isOccluded = window.map { !$0.occlusionState.contains(.visible) } ?? false
        let shouldRunIdleAnimations = filesVisible
            && isActive
            && !isOccluded
            && !reduceMotion
            && collapseTarget == 0
            && !springIsMoving

        if shouldRunIdleAnimations {
            if idleAnimationStartedAt == nil {
                startIdleAnimationsIfNeeded()
            } else {
                configureIdleBaseLayers()
            }
            orbitDisplayLink?.isPaused = true
            lastTimestamp = nil
            return
        }

        if idleAnimationStartedAt != nil {
            stopIdleAnimations(preservingPhase: !reduceMotion)
        }

        let shouldDriveSpring = filesVisible && isActive && !isOccluded && !reduceMotion && springIsMoving
        orbitDisplayLink?.isPaused = !shouldDriveSpring
        if !shouldDriveSpring {
            lastTimestamp = nil
        }
    }

    @objc private func displayLinkDidFire(_ sender: CADisplayLink) {
        let timestamp = sender.timestamp
        let delta = min(max(timestamp - (lastTimestamp ?? timestamp), 0), 1.0 / 15.0)
        lastTimestamp = timestamp
        orbitPhase += delta
        advanceCollapseSpring(delta: delta)
        renderFrame()
        updateMotionState()
    }

    private func prepareIdleAnimationsIfNeeded() {
        guard idleOffsets.isEmpty, idlePreparationTask == nil else { return }
        let files = OnboardingOrbitFile.files
        idlePreparationTask = Task { [weak self] in
            let preparation = Task.detached(priority: .userInitiated) {
                Self.makeIdleSamples(files: files)
            }
            let samples = await withTaskCancellationHandler {
                await preparation.value
            } onCancel: {
                preparation.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            idlePreparationTask = nil
            for sample in samples {
                idleOffsets[sample.fileID] = sample.positions

                let rotation = CAKeyframeAnimation(keyPath: "sublayerTransform.rotation.z")
                rotation.values = sample.rotations.map { NSNumber(value: $0) }
                rotation.duration = 2 * .pi / 0.7
                rotation.repeatCount = .infinity
                rotation.calculationMode = .linear
                rotationAnimations[sample.fileID] = rotation
            }
            updateMotionState()
        }
    }

    nonisolated private static func makeIdleSamples(files: [OnboardingOrbitFile]) -> [IdleSamples] {
        files.compactMap { file in
            guard !Task.isCancelled else { return nil }
            let duration = 2 * Double.pi / file.driftSpeed
            let count = max(120, Int(ceil(duration * idleSampleRate)))
            let positions = (0...count).map { index in
                let phase = duration * Double(index) / Double(count)
                let offset = orbitOffset(for: file, phase: phase)
                return CGPoint(x: offset.width, y: offset.height)
            }
            let rotationCount = max(120, Int(ceil(2 * .pi / 0.7 * idleSampleRate)))
            let rotations = (0...rotationCount).map { index in
                let phase = file.driftPhase + 2 * .pi * Double(index) / Double(rotationCount)
                return (file.rotation + sin(phase) * 3) * .pi / 180
            }
            return IdleSamples(fileID: file.id, positions: positions, rotations: rotations)
        }
    }

    private func startIdleAnimationsIfNeeded() {
        guard idleAnimationStartedAt == nil, !bounds.isEmpty, !idleOffsets.isEmpty else { return }
        if animationBounds != bounds || translationAnimations.isEmpty {
            animationBounds = bounds
            for file in OnboardingOrbitFile.files {
                guard let offsets = idleOffsets[file.id] else { continue }
                let anchor = chipAnchorOffset(for: file, scale: file.scale)
                let animation = CAKeyframeAnimation(keyPath: "sublayerTransform.translation")
                animation.values = offsets.map {
                    NSValue(size: CGSize(
                        width: bounds.midX + $0.x + anchor.width,
                        height: bounds.midY + $0.y + anchor.height
                    ))
                }
                animation.duration = 2 * .pi / file.driftSpeed
                animation.repeatCount = .infinity
                animation.calculationMode = .linear
                translationAnimations[file.id] = animation
            }
        }
        let startedAt = CACurrentMediaTime()
        idleAnimationStartedAt = startedAt
        idleAnimationBasePhase = orbitPhase

        // Install model transforms and animations together to avoid a handoff snap.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        configureIdleBaseLayers()
        for file in OnboardingOrbitFile.files {
            guard let wrapperLayer = wrappers[file.id]?.layer,
                  let translation = translationAnimations[file.id],
                  let rotation = rotationAnimations[file.id] else { continue }
            let localStartTime = wrapperLayer.convertTime(startedAt, from: nil)
            for animation in [translation, rotation] {
                animation.beginTime = localStartTime
                animation.timeOffset = orbitPhase.truncatingRemainder(dividingBy: animation.duration)
            }
            wrapperLayer.add(translation, forKey: "idleTranslation")
            wrapperLayer.add(rotation, forKey: "idleRotation")
        }
        CATransaction.commit()
    }

    private func stopIdleAnimations(preservingPhase: Bool) {
        guard let startedAt = idleAnimationStartedAt else { return }
        if preservingPhase {
            orbitPhase += max(0, CACurrentMediaTime() - startedAt)
        }
        idleAnimationStartedAt = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for wrapper in wrappers.values {
            Self.idleAnimationKeys.forEach { wrapper.layer?.removeAnimation(forKey: $0) }
        }
        renderFrame()
        CATransaction.commit()
    }

    private func configureIdleBaseLayers() {
        guard !bounds.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for file in OnboardingOrbitFile.files {
            guard let wrapperLayer = wrappers[file.id]?.layer else { continue }
            let orbit = Self.orbitOffset(for: file, phase: idleAnimationBasePhase)
            let rotation = file.rotation
                + sin(idleAnimationBasePhase * 0.7 + file.driftPhase) * 3
            wrapperLayer.sublayerTransform = chipTransform(
                for: file,
                offset: orbit,
                rotationDegrees: rotation,
                scale: file.scale
            )
        }
        CATransaction.commit()
    }

    private static let idleAnimationKeys = ["idleTranslation", "idleRotation"]

    /// The orbit layout was tuned while chips were positioned by their corner.
    /// Shifting the center by the scaled half size keeps every resting and
    /// collapsed position where it was, while rotation now pivots on the
    /// chip's center.
    private func chipAnchorOffset(for file: OnboardingOrbitFile, scale: CGFloat) -> CGSize {
        let size = hostSizes[file.id] ?? .zero
        return CGSize(width: size.width / 2 * scale, height: size.height / 2 * scale)
    }

    private func chipTransform(
        for file: OnboardingOrbitFile,
        offset: CGSize,
        rotationDegrees: Double,
        scale: CGFloat
    ) -> CATransform3D {
        let anchor = chipAnchorOffset(for: file, scale: scale)
        var transform = CATransform3DMakeTranslation(
            bounds.midX + offset.width + anchor.width,
            bounds.midY + offset.height + anchor.height,
            0
        )
        transform = CATransform3DRotate(transform, rotationDegrees * .pi / 180, 0, 0, 1)
        return CATransform3DScale(transform, scale, scale, 1)
    }

    private func advanceCollapseSpring(delta: CFTimeInterval) {
        let displacement = collapseProgress - collapseTarget
        guard abs(displacement) > 0.0005 || abs(collapseVelocity) > 0.0005 else {
            collapseProgress = collapseTarget
            collapseVelocity = 0
            return
        }
        let omega = 2 * Double.pi / Self.springResponse
        let acceleration = -omega * omega * Double(displacement)
            - 2 * Self.springDamping * omega * Double(collapseVelocity)
        collapseVelocity += CGFloat(acceleration * delta)
        collapseProgress += collapseVelocity * CGFloat(delta)
    }

    private func renderFrame() {
        guard !bounds.isEmpty else { return }
        let phase = reduceMotion ? 0 : orbitPhase
        let t = min(max(collapseProgress, 0), 1)
        let fadeProgress = min(max((t - 0.70) / 0.30, 0), 1)
        let collapseOpacity = 1 - fadeProgress * fadeProgress * (3 - 2 * fadeProgress)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for file in OnboardingOrbitFile.files {
            guard let wrapper = wrappers[file.id], let wrapperLayer = wrapper.layer else { continue }
            let orbit = Self.orbitOffset(for: file, phase: phase)
            let collapse = CGSize(
                width: collapseOrigin.width + file.collapseX * 0.65,
                height: collapseOrigin.height + file.collapseY * 0.18
            )
            let travelX = collapse.width - orbit.width
            let travelY = collapse.height - orbit.height
            let travelLength = max(hypot(travelX, travelY), 1)
            let arc = sin(t * .pi) * (10 + abs(file.rotation) * 0.45)
            let offset = CGSize(
                width: orbit.width + travelX * t - travelY / travelLength * arc,
                height: orbit.height + travelY * t + travelX / travelLength * arc
            )
            let rotation = (file.rotation + sin(phase * 0.7 + file.driftPhase) * 3)
                * Double(1 - t)
            let scale = file.scale + (0.08 - file.scale) * t
            wrapperLayer.sublayerTransform = chipTransform(
                for: file,
                offset: offset,
                rotationDegrees: rotation,
                scale: scale
            )
            // The reveal's animator already set the model alpha to 1, so an
            // in-flight fade is untouched until the collapse changes opacity.
            guard revealedFileIDs.contains(file.id) else { continue }
            if abs(wrapper.alphaValue - collapseOpacity) > 0.001 {
                wrapper.alphaValue = collapseOpacity
            }
        }
        CATransaction.commit()
    }

    nonisolated private static func orbitOffset(for file: OnboardingOrbitFile, phase: Double) -> CGSize {
        let orbitalAngle = phase * file.driftSpeed + file.driftPhase
        let orbitalX = cos(orbitalAngle) * file.orbitWidth * 1.18
        let orbitalY = sin(orbitalAngle) * file.orbitHeight * 1.22
        // Harmonics share the orbit period so the compositor loop has no seam.
        let driftX = cos(orbitalAngle * 2) * file.driftRadius
        let driftY = sin(orbitalAngle * 2) * file.driftRadius
        return CGSize(
            width: file.baseX * 1.18 + orbitalX + driftX,
            height: file.baseY * 1.18 + orbitalY + driftY
        )
    }

}

/// Full-size, flipped carrier for one chip. Its layer's `sublayerTransform`
/// is the only animated geometry, which AppKit leaves alone.
final class OnboardingOrbitChipWrapper: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
