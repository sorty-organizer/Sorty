//
//  AboutView.swift
//  Sorty
//
//  About dialog with liquid glass styling
//

import AppKit
import SwiftUI

struct AboutView: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let sponsorsURL = URL(string: "https://github.com/sponsors/shirishpothi")!
    private let docsURL = URL(string: "https://github.com/shirishpothi/Sorty#readme")!
    private let githubURL = URL(string: "https://github.com/shirishpothi/Sorty")!
    private var versionHistoryURL: URL {
        SparkleVersionHistoryLink.url(for: BuildInfo.version)
    }

    @State private var supportHovered = false
    @State private var docsHovered = false
    @State private var githubHovered = false
    @State private var accreditationsHovered = false
    @State private var versionHovered = false
    @State private var commitHovered = false
    let openAccreditations: (() -> Void)?

    init(openAccreditations: (() -> Void)? = nil) {
        self.openAccreditations = openAccreditations
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // App Icon
            AboutAppIconEasterEgg()
            
            // App Name
            Text("Sorty")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            
            // Description
            Text("The FOSS File Organiser")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            
            Spacer().frame(height: 2)
            
            // Version Info - Centered
            VStack(spacing: 4) {
                Button {
                    HapticFeedbackManager.shared.tap()
                    NSWorkspace.shared.open(versionHistoryURL)
                } label: {
                    Text("Version \(BuildInfo.version)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("AboutVersionHistoryButton")
                .trackHoveredURL(versionHistoryURL)
                .scaleEffect(versionHovered ? 1.02 : 1.0)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) { versionHovered = hovering }
                    if hovering { HapticFeedbackManager.shared.selection() }
                }
                
                Text("Build \(BuildInfo.build)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                
                // Commit link
                if BuildInfo.hasValidCommit,
                   let commitURL = URL(string: "https://github.com/shirishpothi/Sorty/commit/\(BuildInfo.commit)") {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        NSWorkspace.shared.open(commitURL)
                    } label: {
                        Text("Commit \(BuildInfo.shortCommit)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("AboutCommitButton")
                    .trackHoveredURL(commitURL)
                    .scaleEffect(commitHovered ? 1.02 : 1.0)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) { commitHovered = hovering }
                        if hovering { HapticFeedbackManager.shared.selection() }
                    }
                } else {
                    Text("Commit \(BuildInfo.shortCommit)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer().frame(height: 4)
            
            // Buttons
            VStack(spacing: 10) {
                if FeatureFlags.supportDeveloperEnabled {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        NSWorkspace.shared.open(sponsorsURL)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.red)
                            Text("Support the Developer")
                                .foregroundStyle(.white)
                        }
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.sortyProminent)
                    .controlSize(.large)
                    .trackHoveredURL(sponsorsURL)
                    .scaleEffect(supportHovered ? 1.04 : 1.0)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) { supportHovered = hovering }
                        if hovering { HapticFeedbackManager.shared.selection() }
                    }
                }

                HStack(spacing: 10) {
                    Button("Docs") {
                        HapticFeedbackManager.shared.tap()
                        NSWorkspace.shared.open(docsURL)
                    }
                    .buttonStyle(.sortyBordered)
                    .controlSize(.large)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .trackHoveredURL(docsURL)
                    .scaleEffect(docsHovered ? 1.04 : 1.0)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) { docsHovered = hovering }
                        if hovering { HapticFeedbackManager.shared.selection() }
                    }
                    
                    Button("GitHub") {
                        HapticFeedbackManager.shared.tap()
                        NSWorkspace.shared.open(githubURL)
                    }
                    .buttonStyle(.sortyBordered)
                    .controlSize(.large)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .trackHoveredURL(githubURL)
                    .scaleEffect(githubHovered ? 1.04 : 1.0)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) { githubHovered = hovering }
                        if hovering { HapticFeedbackManager.shared.selection() }
                    }
                }

                Button("Accreditations") {
                    HapticFeedbackManager.shared.tap()
                    openAccreditations?()
                }
                .buttonStyle(.sortyBordered)
                .controlSize(.large)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .accessibilityIdentifier("AboutAccreditationsButton")
                .scaleEffect(accreditationsHovered ? 1.04 : 1.0)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) { accreditationsHovered = hovering }
                    if hovering { HapticFeedbackManager.shared.selection() }
                }
            }
            
            Spacer().frame(height: 0)

            Text("© 2026 Shirish Pothi")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 420, height: 510)
        .modifier(WindowGlassBackground())
        .windowLinkHoverPillHost()
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}

// MARK: - About app icon easter egg

/// Tap the icon to flip through Sorty's build-channel icon variants. Auto-rotates
/// on its own (pausing while hovered, à la Ghostty's About window), and once you
/// manually cycle through every variant it bursts apart before settling back to
/// the running app icon.
private struct AboutAppIconEasterEgg: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @StateObject private var carousel = AboutIconCarousel()
    @State private var iconHovered = false
    @State private var isWindowVisible = true

    private let iconSize: CGFloat = 152
    private let stageWidth: CGFloat = 200
    private let stageHeight: CGFloat = 172

    var body: some View {
        Button {
            carousel.handleTap(allowsBurst: !reduceMotion)
        } label: {
            ZStack {
                if carousel.isBursting && !reduceMotion {
                    IconBurst(
                        startDate: carousel.burstStart,
                        isWindowVisible: isWindowVisible
                    )
                        .frame(width: 220, height: 220)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                SortyEnergyScanIcon(
                    image: carousel.currentImage,
                    size: iconSize,
                    cornerRadius: 22,
                    startDelay: 0.25,
                    sweepDuration: 2.2
                )
                .id(carousel.iconID)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                .scaleEffect(iconScale)
                .rotationEffect(.degrees(carousel.isBursting ? 12 : 0))
                .blur(radius: carousel.isBursting ? 6 : 0)
                .opacity(carousel.isBursting ? 0 : 1)
                .transition(.opacity)
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: iconHovered)
            }
            .frame(width: stageWidth, height: stageHeight)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: carousel.iconID)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeIn(duration: 0.24), value: carousel.isBursting)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sorty app icon")
        .accessibilityHint("Click to cycle through icon variants")
        .accessibilityIdentifier("AboutAppIconButton")
        .onHover { hovering in
            iconHovered = hovering
            carousel.isHovering = hovering
            if hovering {
                HapticFeedbackManager.shared.selection()
            }
        }
        .onAppear { updateAutoCycle() }
        .onChange(of: reduceMotion) { _, newValue in
            updateAutoCycle()
        }
        .onChange(of: isWindowVisible) { _, _ in updateAutoCycle() }
        .onChange(of: controlActiveState) { _, _ in updateAutoCycle() }
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .onDisappear { carousel.stop() }
    }

    private var iconScale: CGFloat {
        if carousel.isBursting { return 0.08 }
        return iconHovered ? 1.05 : 1.0
    }

    private func updateAutoCycle() {
        // Note: no scenePhase gate here. This view lives in a manually-created
        // NSWindow (see AppState.showAbout), outside any SwiftUI Scene, so
        // scenePhase never becomes .active and would permanently pause the
        // carousel and the burst clock below.
        carousel.setAutoCycleEnabled(
            !reduceMotion && isWindowVisible && controlActiveState != .inactive
        )
    }
}

/// Drives the About-window icon carousel: holds the ordered variant images,
/// auto-rotates on a timer (paused while hovered), and triggers the burst.
@MainActor
private final class AboutIconCarousel: ObservableObject {
    @Published private(set) var index = 0
    @Published private(set) var iconID = 0
    @Published private(set) var isBursting = false
    @Published var isHovering = false

    private(set) var burstStart = Date()

    private let images: [NSImage]
    private let runningVariant: AboutAppIconVariant?
    private var manualTaps = 0
    private var cycleTask: Task<Void, Never>?
    private var burstTask: Task<Void, Never>?
    private var lastManualTapDate: Date?

    private let autoCycleInterval: Duration = .seconds(8)
    private let burstHoldInterval: Duration = .milliseconds(1700)
    private let manualPauseInterval: TimeInterval = 1.8

    init() {
        runningVariant = AboutAppIconVariant.current
        images = AboutAppIconVariant.cycleImages(current: runningVariant)
    }

    var currentImage: NSImage {
        images.indices.contains(index) ? images[index] : NSApplication.shared.applicationIconImage
    }

    /// Number of taps needed to trigger the burst: a full manual lap of the
    /// variants (typically three or four), with a sensible floor.
    private var tapsToBurst: Int {
        max(2, images.count)
    }

    func setAutoCycleEnabled(_ isEnabled: Bool) {
        guard isEnabled else {
            cycleTask?.cancel()
            cycleTask = nil
            return
        }

        guard cycleTask == nil else { return }
        cycleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.autoCycleInterval)
                if Task.isCancelled { return }
                guard !self.isHovering, !self.isBursting, !self.isManualPauseActive else { continue }
                self.advance()
            }
        }
    }

    func stop() {
        cycleTask?.cancel()
        cycleTask = nil
        burstTask?.cancel()
        burstTask = nil
        reset()
    }

    func handleTap(allowsBurst: Bool) {
        guard !isBursting else { return }
        HapticFeedbackManager.shared.light()

        guard allowsBurst else {
            advance()
            return
        }

        manualTaps += 1
        lastManualTapDate = Date()
        if manualTaps >= tapsToBurst {
            triggerBurst()
        } else {
            advance()
        }
    }

    private func advance() {
        guard images.count > 1 else { return }
        index = (index + 1) % images.count
        iconID += 1
    }

    private func triggerBurst() {
        burstStart = Date()
        isBursting = true
        HapticFeedbackManager.shared.success()

        burstTask?.cancel()
        burstTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.burstHoldInterval ?? .seconds(1.7))
            guard let self, !Task.isCancelled else { return }
            self.reset()
        }
    }

    private func reset() {
        index = 0
        iconID += 1
        manualTaps = 0
        isBursting = false
    }

    private var isManualPauseActive: Bool {
        guard let lastManualTapDate else { return false }
        return Date().timeIntervalSince(lastManualTapDate) < manualPauseInterval
    }
}

private enum AboutAppIconVariant: String, CaseIterable {
    case debug = "Debug"
    case release = "Release"

    /// Build channel recorded by scripts/build.sh in Info.plist (SortyBuildVariant).
    /// Nil for plain Xcode/SPM runs that don't go through the packaging script.
    static var current: AboutAppIconVariant? {
        let candidates = [
            Bundle.main.infoDictionary?["SortyBuildVariant"] as? String,
            Bundle.main.infoDictionary?["APP_ICON_VARIANT"] as? String,
            ProcessInfo.processInfo.environment["APP_ICON_VARIANT"],
            ProcessInfo.processInfo.environment["SORTY_BUILD_VARIANT"]
        ]

        for candidate in candidates {
            if let variant = variant(from: candidate) {
                return variant
            }
        }

        if let iconFile = Bundle.main.infoDictionary?["CFBundleIconFile"] as? String,
           let variant = variant(from: iconFile) {
            return variant
        }

        return nil
    }

    /// Slot 0 is always the running app icon; the remaining slots are the other
    /// variants, excluding the one this build already ships so nothing duplicates.
    @MainActor
    static func cycleImages(current: AboutAppIconVariant?) -> [NSImage] {
        let appIcon = AboutIconImageNormalizer.normalized(
            NSApplication.shared.applicationIconImage,
            opticalScale: current?.opticalScale ?? 1
        )

        let others = allCases.filter { variant in
            guard let current else { return true }
            return variant != current
        }

        var images: [NSImage] = [appIcon]
        images.append(contentsOf: others.compactMap { variant in
            loadImage(for: variant).map {
                AboutIconImageNormalizer.normalized($0, opticalScale: variant.opticalScale)
            }
        })
        return images
    }

    private var opticalScale: CGFloat {
        1
    }

    private static func variant(from rawValue: String?) -> AboutAppIconVariant? {
        guard let rawValue else { return nil }
        let normalized = rawValue
            .replacingOccurrences(of: "AppIcon-", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".icns", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".png", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "debug", "dev", "local", "ci", "blacksmith":
            return .debug
        case "release", "prod", "production":
            return .release
        default:
            return nil
        }
    }

    private static func loadImage(for variant: AboutAppIconVariant) -> NSImage? {
        for url in candidateURLs(for: variant) where FileManager.default.fileExists(atPath: url.path) {
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }

    private static func candidateURLs(for variant: AboutAppIconVariant) -> [URL] {
        let fileName = "AppIcon-\(variant.rawValue).png"
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let roots = [SortyResources.bundle.resourceURL, Bundle.main.resourceURL].compactMap { $0 }

        var urls: [URL] = []
        for root in roots {
            urls.append(root.appendingPathComponent("AppIcons/\(fileName)"))
            urls.append(root.appendingPathComponent(fileName))
            urls.append(root.appendingPathComponent("Sorty_SortyLib.bundle/AppIcons/\(fileName)"))
            urls.append(root.appendingPathComponent("SortyLib_SortyLib.bundle/AppIcons/\(fileName)"))
        }
        urls.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AppIcons/\(fileName)"))
        urls.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Sorty_SortyLib.bundle/AppIcons/\(fileName)"))
        urls.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/SortyLib_SortyLib.bundle/AppIcons/\(fileName)"))
        // Development fallbacks (running directly from the source tree).
        urls.append(cwd.appendingPathComponent("Sources/SortyLib/Resources/AppIcons/\(fileName)"))
        urls.append(cwd.appendingPathComponent("Assets/AppIcon/\(fileName)"))

        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }
}

private enum AboutIconImageNormalizer {
    /// Ignore soft source-image shadows when measuring each icon's visual size.
    /// The carousel adds one consistent shadow after normalization.
    private static let artworkAlphaThreshold: CGFloat = 0.5

    static func normalized(_ image: NSImage, opticalScale: CGFloat) -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let visibleBounds = visibleBounds(in: cgImage),
              let croppedImage = cgImage.cropping(to: visibleBounds) else {
            return image
        }

        let canvasSize = NSSize(width: 512, height: 512)
        let output = NSImage(size: canvasSize)
        output.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: canvasSize).fill()

        let croppedSize = CGSize(width: CGFloat(croppedImage.width), height: CGFloat(croppedImage.height))
        let scale = min(canvasSize.width / croppedSize.width, canvasSize.height / croppedSize.height)
            * opticalScale
        let drawSize = NSSize(width: croppedSize.width * scale, height: croppedSize.height * scale)
        let drawRect = NSRect(
            x: (canvasSize.width - drawSize.width) / 2,
            y: (canvasSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        NSImage(cgImage: croppedImage, size: croppedSize).draw(in: drawRect)
        output.unlockFocus()
        output.size = canvasSize
        return output
    }

    private static func visibleBounds(in image: CGImage) -> CGRect? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            for x in 0..<width where
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= artworkAlphaThreshold
            {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return nil
        }

        return CGRect(
            x: CGFloat(minX),
            y: CGFloat(minY),
            width: CGFloat(maxX - minX + 1),
            height: CGFloat(maxY - minY + 1)
        )
    }
}

// MARK: - Icon burst

/// Premium confetti burst: real confetti shapes with flutter, spin, gravity,
/// and a soft flash — still a single Canvas/TimelineView for zero view churn.
private struct IconBurst: View {
    @SortyHotReload private var hotReload
    let startDate: Date
    var isWindowVisible = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    private let particles = IconBurst.makeParticles()

    var body: some View {
        SwiftUI.TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                // No scenePhase gate: manual NSWindow hosting never reports
                // .active, which would freeze the burst at t=0 (invisible).
                paused: reduceMotion || !isWindowVisible || controlActiveState == .inactive
            )
        ) { context in
            Canvas { ctx, size in
                let t = max(0, context.date.timeIntervalSince(startDate))
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                // Soft flash ring — Sorty rose tinted, not stark white
                let ringDuration = 0.38
                let ringT = min(1, t / ringDuration)
                if ringT < 1 {
                    let radius = 14 + ringT * 82
                    let alpha = pow(1 - ringT, 1.6) * 0.62
                    let rect = CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    ctx.stroke(
                        Path(ellipseIn: rect),
                        with: .color(Color(red: 0.850, green: 0.235, blue: 0.353).opacity(alpha)),
                        lineWidth: 2.8 * (1 - ringT) + 0.7
                    )
                    // Inner highlight
                    ctx.stroke(
                        Path(ellipseIn: rect.insetBy(dx: 2, dy: 2)),
                        with: .color(.white.opacity(alpha * 0.55)),
                        lineWidth: 1.1 * (1 - ringT)
                    )
                }

                for p in particles where t < p.lifetime {
                    let progress = t / p.lifetime
                    // Radial travel with drag (ease-out) + flutter + gravity
                    let drag: Double = 2.9 + p.drag * 0.8
                    let travel = (1 - exp(-drag * t)) / drag
                    let flutter = sin(t * p.wobbleFreq + p.wobblePhase) * p.wobbleAmp * min(1, t * 2.8)
                    var dx = p.velocity.dx * travel + flutter
                    var dy = p.velocity.dy * travel + 0.5 * p.gravity * t * t
                    // Slight air drag on vertical fall
                    dy *= 1 - progress * 0.08
                    // Upward particles arc a bit wider
                    if p.velocity.dy < 0 { dx *= 1 + progress * 0.22 }

                    let alpha = pow(1 - progress, 1.5) * (progress < 0.08 ? progress / 0.08 : 1)
                    let scale = 1 - progress * 0.42
                    let psize = p.size * scale

                    // Per-particle rotation + 3D-ish squash as it spins
                    let spinDeg = p.spin * t * 180 / .pi + p.initialRotation
                    let squash = 0.55 + 0.45 * abs(cos(t * p.spin * 0.9))

                    ctx.opacity = alpha
                    var xform = CGAffineTransform.identity
                        .translatedBy(x: center.x + dx, y: center.y + dy)
                        .rotated(by: spinDeg * .pi / 180)
                        .scaledBy(x: 1, y: CGFloat(squash))

                    // Soft drop shadow for depth
                    var shadowPath: Path
                    switch p.shape {
                    case .circle:
                        shadowPath = Path(ellipseIn: CGRect(x: -psize / 2, y: -psize / 2, width: psize, height: psize))
                    case .rect:
                        shadowPath = Path(roundedRect: CGRect(x: -psize / 2, y: -psize * 0.62 / 2, width: psize, height: psize * 0.62), cornerRadius: psize * 0.18)
                    case .diamond:
                        shadowPath = IconBurst.diamondPath(size: psize)
                    case .squiggle:
                        shadowPath = Path(ellipseIn: CGRect(x: -psize / 2, y: -psize * 0.55 / 2, width: psize, height: psize * 0.55))
                    }
                    ctx.fill(shadowPath.applying(xform), with: .color(.black.opacity(0.16)))
                    // Nudge main shape up-left so shadow peeks
                    xform = xform.translatedBy(x: -0.5, y: -0.7)
                    ctx.fill(shadowPath.applying(xform), with: .color(p.color))

                    ctx.opacity = 1
                }
            }
        }
    }

    private static func diamondPath(size: CGFloat) -> Path {
        var path = Path()
        let h = size / 2
        path.move(to: CGPoint(x: 0, y: -h))
        path.addLine(to: CGPoint(x: h, y: 0))
        path.addLine(to: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: -h, y: 0))
        path.closeSubpath()
        return path
    }

    private static func makeParticles() -> [BurstParticle] {
        var rng = SystemRandomNumberGenerator()
        // Sorty rose + complementary confetti hues
        let palette: [Color] = [
            Color(red: 0.850, green: 0.235, blue: 0.353), // sorty rose
            Color(red: 0.96, green: 0.78, blue: 0.22), // gold
            .teal, .blue, .purple, .pink, .orange, .mint, .white
        ]
        let count = 54

        return (0..<count).map { i in
            let jitter = Double.random(in: -0.22...0.22, using: &rng)
            // Even radial fill + bias: more upward/outward, fewer straight-down (less occlusion of icon shadow)
            let baseAngle = (Double(i) / Double(count)) * .pi * 2 + jitter
            // Push down-quadrant particles slightly outward so burst feels airy, not bottom-heavy
            let angle = baseAngle
            let speed: Double
            let isUpward = sin(angle) < -0.15
            if isUpward {
                speed = Double.random(in: 190...405, using: &rng)
            } else {
                speed = Double.random(in: 150...345, using: &rng)
            }
            let shape: BurstShape
            switch i % 7 {
            case 0, 1: shape = .rect
            case 2: shape = .diamond
            case 3 where i % 14 == 3: shape = .squiggle
            default: shape = .circle
            }
            // Confetti rectangles read bigger than dots — compensate size by shape
            let baseSize: CGFloat
            switch shape {
            case .rect: baseSize = CGFloat.random(in: 7...13, using: &rng)
            case .diamond: baseSize = CGFloat.random(in: 6...10, using: &rng)
            case .squiggle: baseSize = CGFloat.random(in: 5...9, using: &rng)
            case .circle: baseSize = CGFloat.random(in: 4.5...8.5, using: &rng)
            }
            return BurstParticle(
                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                size: baseSize,
                color: palette[i % palette.count],
                lifetime: Double.random(in: 0.82...1.55, using: &rng),
                shape: shape,
                spin: Double.random(in: -9...9, using: &rng),
                initialRotation: Double.random(in: 0...360, using: &rng),
                wobbleFreq: Double.random(in: 7...15, using: &rng),
                wobbleAmp: Double.random(in: 6...18, using: &rng),
                wobblePhase: Double.random(in: 0...(2 * .pi), using: &rng),
                gravity: Double.random(in: 520...740, using: &rng),
                drag: Double.random(in: -0.4...0.6, using: &rng)
            )
        }
    }
}

private enum BurstShape { case circle, rect, diamond, squiggle }

private struct BurstParticle: Identifiable {
    let id = UUID()
    let velocity: CGVector
    let size: CGFloat
    let color: Color
    let lifetime: Double
    let shape: BurstShape
    let spin: Double
    let initialRotation: Double
    let wobbleFreq: Double
    let wobbleAmp: Double
    let wobblePhase: Double
    let gravity: Double
    let drag: Double
}

#Preview {
    AboutView()
}
