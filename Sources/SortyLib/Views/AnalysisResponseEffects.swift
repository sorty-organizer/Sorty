import SwiftUI

/// Dotted globe shown while analysis waits for an AI response.
public struct ThinkingOrbLoaderView: View {
    @SortyHotReload private var hotReload
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            // The sphere does not change as it rotates. Build its vertices outside
            // the timeline so frame updates only project and shade existing points.
            let vertices = Self.sphereVertices(size: geometry.size)
            SwiftUI.TimelineView(
                .animation(
                    minimumInterval: 1.0 / 60.0,
                    paused: reduceMotion || controlActiveState == .inactive
                )
            ) { timeline in
                let raw = reduceMotion ? 0.6 : timeline.date.timeIntervalSinceReferenceDate
                let isDark = colorScheme == .dark
                Canvas(rendersAsynchronously: true) { context, size in
                    Self.drawGlobe(context: &context, size: size, vertices: vertices, rawTime: raw, dark: isDark)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thinking activity indicator")
    }

    private struct SphereVertex: Sendable {
        let x, y, z, longitude: CGFloat
    }

    private static func sphereVertices(size: CGSize) -> [SphereVertex] {
        let s = min(size.width, size.height)
        guard s > 0 else { return [] }
        let f = min(1, max(0, (s - 20) / 44))
        let latRings = Int((6 + f * (11 - 6)).rounded())
        let lonDensity: CGFloat = 14 + f * (29 - 14)
        var vertices: [SphereVertex] = []
        vertices.reserveCapacity((latRings + 1) * Int(lonDensity.rounded()))
        for li in 0...latRings {
            let lat = -CGFloat.pi / 2 + CGFloat(li) / CGFloat(latRings) * .pi
            let cosLat = cos(lat), sinLat = sin(lat)
            let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
            for lj in 0..<lonCount {
                let lon = CGFloat(lj) / CGFloat(lonCount) * 2 * .pi
                vertices.append(SphereVertex(
                    x: cosLat * cos(lon), y: sinLat,
                    z: cosLat * sin(lon), longitude: lon
                ))
            }
        }
        return vertices
    }

    private static func drawGlobe(
        context: inout GraphicsContext,
        size: CGSize,
        vertices: [SphereVertex],
        rawTime: TimeInterval,
        dark: Bool
    ) {
        let s = min(size.width, size.height)
        guard s > 0 else { return }

        let f = min(1, max(0, (s - 20) / 44))
        let speed: CGFloat = (2.665 + f * (2.015 - 2.665)) * 0.65
        let rBase: CGFloat = 1.05 + f * (0.69 - 1.05)
        let rDepth: CGFloat = 2.975 + f * (1.955 - 2.975)
        let scanMul: CGFloat = 4.335 + f * (4.08 - 4.335)
        let dimBase: CGFloat = 0.45
        let inkFar: CGFloat = 0.62
        let inkSpan: CGFloat = 0.54
        let rMin: CGFloat = 0.3

        let t = CGFloat(rawTime) * speed
        let spin: CGFloat = 0.5
        let cx = size.width / 2
        let cy = size.height / 2
        let radius = (s / 2) * 0.82
        let tilt = 0.4 + 0.06 * sin(t * 0.35)
        let scan = t * (spin + (1.7 - spin) * scanMul)
        let rs = pow(s / 300, 0.6)

        let st = sin(tilt), ct = cos(tilt)
        let sy = sin(t * spin), cyw = cos(t * spin)

        struct Dot {
            let x, y, z, r: CGFloat
            let white: CGFloat
            let alpha: CGFloat
        }
        var dots: [Dot] = []

        dots.reserveCapacity(vertices.count)
        for vertex in vertices {
            let x = vertex.x, y = vertex.y, z = vertex.z
            let lon = vertex.longitude
            let x1 = x * cyw + z * sy
            let z1 = -x * sy + z * cyw
            let y1 = y * ct - z1 * st
            let z2 = y * st + z1 * ct
            let depth = (z2 + 1) / 2
            let a = lon + t * spin - scan
            let d = atan2(sin(a), cos(a))
            let boost = exp(-(d * d) / 0.18) * max(0, z2)

            dots.append(
                Dot(
                    x: cx + x1 * radius,
                    y: cy - y1 * radius,
                    z: z2,
                    r: max(rMin, (rBase + rDepth * depth + boost) * rs),
                    white: inkFar - inkSpan * depth,
                    alpha: dimBase + (1 - dimBase) * min(1, boost)
                )
            )
        }

        dots.sort { $0.z < $1.z }
        for dot in dots where dot.alpha >= 0.02 {
            let w = min(1, max(0, dot.white))
            let gray = dark ? 1 - w : w
            let rect = CGRect(x: dot.x - dot.r, y: dot.y - dot.r, width: dot.r * 2, height: dot.r * 2)
            context.fill(
                Path(ellipseIn: rect),
                with: .color(Color(white: gray).opacity(dot.alpha))
            )
        }
    }
}

/// Brightness sweep shown on analysis status text while a response is pending.
public struct TextSweepModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    private let bandSize: CGFloat = 0.3
    private let sweepDuration: TimeInterval = 2.0
    private let sweepDelay: TimeInterval = 0.35
    private let gradient = Gradient(colors: [
        .black.opacity(0.3),
        .black,
        .black.opacity(0.3),
    ])

    public func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .mask(
                    SwiftUI.TimelineView(
                        .animation(
                            minimumInterval: 1.0 / 30.0,
                            paused: controlActiveState == .inactive
                        )
                    ) { timeline in
                        let cycleDuration = sweepDuration + sweepDelay
                        let cycleTime = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: cycleDuration)
                        let progress = min(1, max(0, (cycleTime - sweepDelay) / sweepDuration))
                        let position = CGFloat(progress)

                        LinearGradient(
                            gradient: gradient,
                            startPoint: UnitPoint(
                                x: -bandSize + ((1 + bandSize) * position),
                                y: -bandSize + ((1 + bandSize) * position)
                            ),
                            endPoint: UnitPoint(
                                x: (1 + bandSize) * position,
                                y: (1 + bandSize) * position
                            )
                        )
                    }
                )
        }
    }
}

extension View {
    public func textSweep() -> some View {
        modifier(TextSweepModifier())
    }
}
