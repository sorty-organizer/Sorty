//
//  MascotHeartParticleMorphView.swift
//  Sorty
//
//  Particle morph from Sorty's mascot into a solid heart.

import Foundation
import SwiftUI

struct MascotHeartParticleMorphView: View {
    @SortyHotReload private var hotReload
    private enum Timing {
        static let mascotHold: TimeInterval = 0.5
        static let reverseDuration: TimeInterval = 0.85
        static let morphDuration: TimeInterval = 1.15
        static let heartbeatDuration: TimeInterval = 0.90
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var animationStart: Date?
    @State private var animationRun = 0
    @State private var replayStartProgress = 1.0
    @State private var isSettled = false
    @State private var isWindowVisible = true

    // `color` kept for API compat but mascot uses its true palette, not the accent.
    let color: Color

    var body: some View {
        Button(action: replayAnimation) {
            Group {
                if isSettled || reduceMotion {
                    // Settled heart renders once with no timeline; the looping
                    // heartbeat below is paused instead of ticking forever.
                    ParticleMorphCanvas(
                        progress: 1,
                        heartbeatScale: 1,
                        isHeartComplete: true
                    )
                } else {
                    SwiftUI.TimelineView(
                        .animation(
                            minimumInterval: 1.0 / 30.0,
                            paused: reduceMotion || animationStart == nil || isSettled
                                || !isWindowVisible || controlActiveState == .inactive
                                || scenePhase != .active
                        )
                    ) { timeline in
                        let elapsed = animationStart.map { timeline.date.timeIntervalSince($0) } ?? 0
                        let isReplay = animationRun > 0
                        let isHeartComplete = reduceMotion || heartIsComplete(at: elapsed, isReplay: isReplay)

                        ParticleMorphCanvas(
                            progress: isHeartComplete ? 1 : morphProgress(at: elapsed, isReplay: isReplay),
                            heartbeatScale: reduceMotion ? 1 : heartbeatScale(at: elapsed, isReplay: isReplay),
                            isHeartComplete: isHeartComplete
                        )
                    }
                }
            }
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .help("Replay animation")
        .accessibilityLabel("Replay mascot animation") // [VERIFY] User-facing name for the visual control.
        .accessibilityHint("Plays the mascot-to-heart animation again")
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .task(id: AnimationTaskID(reduceMotion: reduceMotion, run: animationRun)) {
            animationStart = nil
            isSettled = reduceMotion
            guard !reduceMotion else { return }

            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            animationStart = Date()

            guard animationRun > 0 else {
                // First run: settle shortly after the morph completes so the
                // heartbeat does not tick the timeline indefinitely.
                let settleDelay = Timing.mascotHold + Timing.morphDuration + 2 * Timing.heartbeatDuration
                try? await Task.sleep(for: .seconds(settleDelay))
                guard !Task.isCancelled else { return }
                isSettled = true
                return
            }
            let reverseDuration = Timing.reverseDuration * replayStartProgress
            try? await Task.sleep(for: .seconds(reverseDuration))
            guard !Task.isCancelled else { return }
            HapticFeedbackManager.shared.alignment()

            try? await Task.sleep(for: .seconds(Timing.mascotHold))
            guard !Task.isCancelled else { return }
            HapticFeedbackManager.shared.selection()

            try? await Task.sleep(for: .seconds(Timing.morphDuration))
            guard !Task.isCancelled else { return }
            HapticFeedbackManager.shared.success()

            try? await Task.sleep(for: .seconds(2 * Timing.heartbeatDuration))
            guard !Task.isCancelled else { return }
            isSettled = true
        }
    }

    private func replayAnimation() {
        HapticFeedbackManager.shared.tap()
        isSettled = false
        if let animationStart {
            replayStartProgress = morphProgress(
                at: Date().timeIntervalSince(animationStart),
                isReplay: animationRun > 0
            )
        } else {
            replayStartProgress = animationRun > 0 ? replayStartProgress : 0
        }
        animationStart = nil
        animationRun &+= 1
    }

    private func morphProgress(at elapsed: TimeInterval, isReplay: Bool) -> Double {
        guard isReplay else {
            return easedProgress((elapsed - Timing.mascotHold) / Timing.morphDuration)
        }

        let reverseDuration = Timing.reverseDuration * replayStartProgress
        if elapsed < reverseDuration, reverseDuration > 0 {
            return replayStartProgress * (1 - easedProgress(elapsed / reverseDuration))
        }

        let forwardElapsed = elapsed - reverseDuration - Timing.mascotHold
        return easedProgress(forwardElapsed / Timing.morphDuration)
    }

    private func easedProgress(_ rawProgress: Double) -> Double {
        let raw = min(max(rawProgress, 0), 1)
        // easeInOutCubic
        if raw < 0.5 { return 4 * raw * raw * raw }
        let p = 2 * raw - 2
        return 0.5 * p * p * p + 1
    }

    private func heartbeatScale(at elapsed: TimeInterval, isReplay: Bool) -> CGFloat {
        let reverseDuration = isReplay ? Timing.reverseDuration * replayStartProgress : 0
        let heartStart = reverseDuration + Timing.mascotHold + Timing.morphDuration
        guard elapsed >= heartStart else {
            return 1
        }

        let t = (elapsed - heartStart).truncatingRemainder(dividingBy: Timing.heartbeatDuration)
        switch t {
        case 0..<0.11: return 1 + 0.075 * eased(t / 0.11)
        case 0.11..<0.20: return 1.075 - 0.075 * eased((t - 0.11) / 0.09)
        case 0.24..<0.32: return 1 + 0.038 * eased((t - 0.24) / 0.08)
        case 0.32..<0.44: return 1.038 - 0.038 * eased((t - 0.32) / 0.12)
        default: return 1
        }
    }

    private func heartIsComplete(at elapsed: TimeInterval, isReplay: Bool) -> Bool {
        let reverseDuration = isReplay ? Timing.reverseDuration * replayStartProgress : 0
        return elapsed >= reverseDuration + Timing.mascotHold + Timing.morphDuration
    }

    private func eased(_ p: Double) -> CGFloat {
        let c = min(max(p, 0), 1)
        return CGFloat(1 - pow(1 - c, 3))
    }
}

private struct AnimationTaskID: Hashable {
    let reduceMotion: Bool
    let run: Int
}

private struct ParticleMorphCanvas: View {
    @SortyHotReload private var hotReload
    let progress: Double
    let heartbeatScale: CGFloat
    let isHeartComplete: Bool

    var body: some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            drawParticles(in: &context, size: size)
        }
    }

    private func drawParticles(in context: inout GraphicsContext, size: CGSize) {
        let side = min(size.width, size.height)
        let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
        if isHeartComplete {
            drawCompletedHeart(in: &context, origin: origin, side: side)
        } else {
            drawMorphingParticles(in: &context, origin: origin, side: side)
        }
    }

    private func drawCompletedHeart(
        in context: inout GraphicsContext,
        origin: CGPoint,
        side: CGFloat
    ) {
        let diameter: CGFloat = 1.60
        for particle in Self.particles {
            let x = 0.5 + (particle.heart.x - 0.5) * heartbeatScale
            let y = 0.5 + (particle.heart.y - 0.5) * heartbeatScale
            let center = CGPoint(x: origin.x + x * side, y: origin.y + y * side)
            let rect = CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            context.fill(Path(ellipseIn: rect), with: .color(heartColor))
        }
    }

    private func drawMorphingParticles(
        in context: inout GraphicsContext,
        origin: CGPoint,
        side: CGFloat
    ) {
        for particle in Self.particles {
            let rect = particleRect(
                particle: particle,
                origin: origin,
                side: side
            )
            drawParticle(
                in: &context,
                rect: rect,
                particle: particle
            )
        }
    }

    private func particleRect(
        particle: ParticleMorphDefinition,
        origin: CGPoint,
        side: CGFloat
    ) -> CGRect {
        // tiny stagger (max 80ms) prevents pop-in glitch while keeping motion coherent
        let raw = max(0, min((CGFloat(progress) - particle.delay) / (1 - particle.delay), 1))
        // match global cubic easing per-particle with same curve
        let p: CGFloat
        if raw < 0.5 {
            p = 4 * raw * raw * raw
        } else {
            let pp = 2 * raw - 2
            p = 0.5 * pp * pp * pp + 1
        }

        // gentle arc: perpendicular offset peaks at mid-flight, scaled by travel distance
        let arcProgress = CGFloat(sin(.pi * Double(p)))
        let cx = particle.midpoint.x + particle.arcOffset.x * arcProgress
        let cy = particle.midpoint.y + particle.arcOffset.y * arcProgress

        let ipf = 1 - p
        var x = ipf * ipf * particle.mascot.point.x
            + 2 * ipf * p * cx
            + p * p * particle.heart.x
        var y = ipf * ipf * particle.mascot.point.y
            + 2 * ipf * p * cy
            + p * p * particle.heart.y

        x = 0.5 + (x - 0.5) * heartbeatScale
        y = 0.5 + (y - 0.5) * heartbeatScale

        let diameter: CGFloat = 1.60
        let center = CGPoint(x: origin.x + x * side, y: origin.y + y * side)
        return CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
    }

    private func drawParticle(
        in context: inout GraphicsContext,
        rect: CGRect,
        particle: ParticleMorphDefinition
    ) {
        let raw = max(0, min((CGFloat(progress) - particle.delay) / (1 - particle.delay), 1))
        let p: Double
        if raw < 0.5 {
            p = 4 * Double(raw) * Double(raw) * Double(raw)
        } else {
            let pp = 2 * Double(raw) - 2
            p = 0.5 * pp * pp * pp + 1
        }

        // crossfade with brief overlap — avoids muddy gray mid-morph
        let mascotOpacity = max(0, 1 - p * 1.9)
        let heartOpacity = max(0, (p - 0.18) / 0.82)
        let heartEased = heartOpacity * heartOpacity * (3 - 2 * heartOpacity)

        if mascotOpacity > 0.015 {
            context.fill(
                Path(ellipseIn: rect),
                with: .color(particle.mascot.color.opacity(mascotOpacity))
            )
        }
        if heartEased > 0.015 {
            context.fill(
                Path(ellipseIn: rect),
                with: .color(heartColor.opacity(heartEased))
            )
        }
    }

    private var heartColor: Color {
        Color(red: 0.96, green: 0.19, blue: 0.26)
    }

    private static let particles: [ParticleMorphDefinition] =
        MascotHeartParticleTargets.mascot.indices.map { index in
            let mascot = MascotHeartParticleTargets.mascot[index]
            let heart = MascotHeartParticleTargets.heart[index]
            let seed = seed(for: index)
            let angle = atan2(mascot.point.y - 0.5, mascot.point.x - 0.5)
            let angleNorm = abs(angle) / .pi
            let delay = seed * 0.06 + angleNorm * 0.04
            let dx = heart.x - mascot.point.x
            let dy = heart.y - mascot.point.y
            let length = max(hypot(dx, dy), 0.001)
            let arc = (0.012 + seed * 0.012)
                * min(length * 1.5, 1)
                * (seed > 0.5 ? 1 : -1)
            return ParticleMorphDefinition(
                mascot: mascot,
                heart: heart,
                delay: delay,
                midpoint: CGPoint(
                    x: (mascot.point.x + heart.x) * 0.5,
                    y: (mascot.point.y + heart.y) * 0.5
                ),
                arcOffset: CGPoint(x: -dy / length * arc, y: dx / length * arc)
            )
        }

    private static func seed(for index: Int) -> CGFloat {
        let mixed = UInt64(index &* 73_856_093) ^ UInt64(index &* 19_349_663)
        return CGFloat(mixed % 1_000) / 1_000
    }
}

private struct ParticleMorphDefinition {
    let mascot: MascotParticle
    let heart: CGPoint
    let delay: CGFloat
    let midpoint: CGPoint
    let arcOffset: CGPoint
}

private struct MascotParticle {
    let point: CGPoint
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}

private enum MascotHeartParticleTargets {
    private static let heartVertexCount = 2_000

    static let mascot: [MascotParticle] = orderedByAngle(makeMascotParticles())
    static let heart: [CGPoint] = orderedByAngle(makeHeartPoints(count: mascot.count))

    private static func makeMascotParticles() -> [MascotParticle] {
        guard let data = Data(base64Encoded: mascotParticleData) else {
            return []
        }

        let bytes = [UInt8](data)
        var particles: [MascotParticle] = []
        particles.reserveCapacity(bytes.count / 5)

        for index in stride(from: 0, to: bytes.count, by: 5) {
            let point = CGPoint(
                x: CGFloat(bytes[index]) / 255,
                y: CGFloat(bytes[index + 1]) / 255
            )
            let particle = MascotParticle(
                point: point,
                red: Double(bytes[index + 2]) / 255,
                green: Double(bytes[index + 3]) / 255,
                blue: Double(bytes[index + 4]) / 255
            )
            particles.append(particle)
        }

        return particles
    }

    // Quantized particle positions and colors sampled from Sol Light's artwork.
    // The animation renders only these particles, never the source image.
    private static let mascotParticleData = """
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6Xej0u4WeiIyUyd6////K3r5/f0vesLu+jJ6xu78NnrL8/45eoPc8z16i+r9QXqQ7f5EepTu/Eh6nu//S3qk8ftPeqzy/lJ6svL8Vnq58vtaer30/F16wPX8YXrE9Pxkesf1/Gh6yvX8a3rL9fxves/3/XN60Pf9dnrR9/x6etP3/X161Pf9gXrV+P2FetX3/Yh61Pb8jHrV+P2PetP3/ZN60ff8lnrP9/2aetH1/556zff9oXrK9fylesf2/Kh6w/b+rHrA9f6werz0/bN6tvP8t3qu8v26eqnx/L56oPH8wXqc7v3FepPt/cl6DTJczHrJ8v7Qesbt+9N6w+3613r///7aeiA9Zul6oMvgFn4yQGInfv3+/yt+w+j2L37C7/oyfsns+jZ+YrfkOX6B6Pw9fofq/EF+j+37RH6W7vxIfpzw+0t+pPD6T36t8ftSfrfz/lZ+vPX9Wn6/9PxdfsT2/GF+xvb9ZH7I9vxofsv2/Wt+zvX9b37Q9/1zftH3/XZ+1Pf9en7V9/19ftX3/YF+1vb9hX7V9/2IftT3/Yx+1fj9j37U9/6TftX3/ZZ+0vb9mn7R9/2efs33/qF+yvb8pX7I9v6ofsb2/qx+wPX8sH6/9f6zfrj0/rd+s/P9un6p8vu+fqHx/MF+mu/7xX6S7f3Jfovt/sx+AiZf0H7J7vrTfsTr+dd+xej22n4wT3zpfmSJrBaCVGOAIIIJJFYkghAnTyeC9v38K4K55vcvgsTs+zKCEjVeNoKE6v05goLn/j2Chun8QYKN7fpEgpfu+kiCn+76S4Kr8fxPgq/0+1KCuPT7VoK+9fpagsD2/F2Cxfb8YYLI9vxkgsv3/WiCzff8a4LO9/1vgtH3/XOC0vb9doLU+f16gtX5/n2C1ff9gYLV9/6Fgtb4/YiC1fj9jILV+P2PgtX4/ZOC0vf9loLU9/2agtL3/Z6Cz/f9oYLM9/2lgsn3/qiCyPb+rILF9f6wgr31/LOCt/T7t4Kx9P26gqrx/L6CpfH7wYKc7/vFgpTu/cmCkev7zIKK5/7QgsXt/NOCxOv614K86Pjagvb9/t6CFSpV4oJxgaXpgixOeBaFkp24GYWSpcYdhfv+/SCF/v7+JIUnSHQnhdXx+iuFuef6L4W+6voyhW3A4TaFeub8OYWA6fw9hYjt/UGFj+78RIWX7/tIhZ/w+kuFqvH7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sLeO1/izt4fW+Le3hdT3ureA0va+t33Q9cG3d8z2xbdmv+/Jt2a+8cy3Yrvw0LcaQ3fTt4LG69e3eL7t2ren4/bet6Pj+uK3r+T65bcmPWskux41Vye7ZrPoK7ttuOwvu3nD7TK7WLbuNrtguO45u2G97z27Zb7wQbtkv+5Eu3fL9Ei7fM3zS7t90fZPu4PS81K7h9T1VruN1vhau5DX9127k9f3YbuW2vhku5jb9mi7nN33a7uf3vZvu6Db9XO7puD2drsOK056uwwrS327BSpQgbsEKlGFuwUpTYi7CSRLjLsRMViPu6De9ZO7o+H3lrud3/iau5vd+J67l9v4obuT2valu5HX96i7jtf3rLuK1vewu4PS9bO7hND2t7t7zfO6u3vM9L67ecr0wbtmv+/Fu2a88cm7Y7vwzLthue7QuwwzaNO7fMLn17tvuOnau7Xr9yS+R1x6J75osuUrvmaz6i++bbroMr5EebI2vl+27jm+XrfuPb5iuu9BvmK77kS+Zr7uSL50yPJLvnfM8k++fszzUr6DzvRWvoXQ81q+idP2Xb6M0/Zhvo/V9mS+kdf2aL6S1/VrvpjX+G++l9n1c76Y2fZ2vqDb93q+oNv2fb6q3/WBvq7g9oW+qt32iL6n3faMvpva84++ldj2k76T1/SWvpLW9Zq+kNX2nr6N1PWhvojS9KW+itL1qL6F0fasvoLO87C+gMz0s758y/K3vnvJ8rq+dMjxvr5kvO7BvmO77sW+Ybnuyb5gt+7Mvlqw6dC+aZC90751vOnXvme259q+e7rVJ8K97Porwl+u5y/CZbbqMsIDMWY2wmG17jnCXrTuPcJdte5Bwl+460TCX7jsSMJkve1LwnDF8k/CecjyUsJ9yvJWwn/L8lrCgs3yXcKFz/NhwofQ9GTCiNL0aMKM0vZrwo7U9m/CjtT1c8KR1fR2wpDU9HrCj9T2fcKQ1PaBwpDV8oXCkdT2iMKR1PaMwpDU9Y/CjtT0k8KL0vaWwovS9prCitH1nsKH0PahwoPO9KXCg831qMKBzfSswnzM8bDCfMnys8J6x/G3wnLH9LrCZLruvsJiue7Bwl247cXCYLbtycJcs+rMwkKMytDCfcDp08JwuOfXwnW649rCHzlkJ8Y0YJkrxlqp5S/GYLHoMsZwu+s2xlWY0DnGV7DqPcZZs+pBxlu17ETGXrfrSMZgt+pLxmS47k/GZrrsUsZ2w/FWxnrI8VrGgMnyXcZ9y/JhxoLL82TGhM3yaMaGzvVrxobP9G/Gh9Hzc8aI0fJ2xozR9XrGi9H2fcaK0vWBxorR9YXGitHziMaL0fSMxorR9o/GiND0k8aHzvSWxobN85rGg83ynsaAy/OhxoDL86XGfsnzqMZ6yvKsxnvI8rDGdsbys8ZluOu3xmG47brGXbbsvsZftu3Bxl+17MXGYLTqycY+ktfMxho/ZNDGa7Lm08Zjr+PXxsHv+ivJtu35L8lerecyyWGy6DbJb7XjOclSn9g9yVmv6kHJW7HrRMlcs+pIyVy060vJYrbsT8lkt+pSyWO47VbJZLjsWslnu+xdyXHB72HJfcn1ZMmAyfZoyX3L8GvJgcvyb8mFzfRzyYTN8nbJhM7yesmEzfJ9yYTN8YHJhM3yhcmDzfKIyYbN8ozJg83zj8mDzPKTyYLL8pbJgcvymsl/yvCeyX7K8qHJfMjxpcl4xvSoyWi47KzJYbnqsMllt+2zyWS37rfJYbbruslbtOq+yVyz6sHJX7LrxclDldvJyQIvaszJcbjo0MlgreXTyWSz4dfJIjpzK80RKlovzZDM7jLNVajlNs1drOY5zWm05T3NDTpqQc1YsOdEzVmv6EjNWrDqS81csulPzV6z6lLNYLjrVs1huOpazWO56l3NY7jrYc1lue5kzWi672jNZ7zta81pvO1vzWq763PNbr3tds1yve16zXbB733NecTvgc18yPKFzX7I8ojNfMfyjM14xPGPzXG/7pPNarrrls1ouuuazWe5657NZ7jsoc1juO2lzWS37qjNYbXqrM1htuqwzV6367PNYbbrt81es+q6zVyy6b7NNpLXwc04cazFzU5xmMnNa7bnzM1Zq+LQzVKm39PNsev7L9AYMWEy0JLR8jbQWaviOdBZr+U90GW15kHQi8fuRNADLGBI0DVlmUvQWa7mT9BesOlS0Fyz6FbQX7TpWtBgtexd0GC16mHQZrbrZNBluOto0GW462vQZrrsb9Bnuexz0Gi57HbQa7ntetBouut90Gi67YHQabvthdBoueyI0Gi664zQZrjqj9BluOqT0Ge465bQY7fpmtBjt+qe0GS466HQY7TqpdBhs+qo0GGz6qzQYLTqsNBfs+qz0ECY2rfQSpbWutAELmW+0GiWvcHQbbfkxdBdrOHJ0FSn4czQWKfc0NCx6/wy1BYqVDbUuer2OdRcqeE91FSn4kHUVqjiRNRZrOVI1Hm96kvUjcvxT9SZzexS1DNNeVbUCCpVWtQTNGFd1CBGdmHUVpDAZNRlsuRo1GS16WvUYrbsb9Rktuxz1GW27nbUY7btetRluOx91Ge57YHUZ7jrhdRnuO2I1Gq37YzUZLjrj9RktOuT1F+06ZbUYbPqmtRksuie1F2j16HUMV6TpdQFLmCo1AgvX6zUEzJgsNRpncaz1J7U8rfUhcTuutRusOO+1Fen4cHUUqTgxdRPpOHJ1IvM7szUQnCjOdgbLlg92MDv+kHYTqLfRNhMouBI2E6k4UvYT6TgT9hSpt9S2Fuq5FbYarPlWth/v+xd2I7I7mHYnNLyZNim1/Jo2KXX9GvYp9n0b9iq2fRz2K/b9nbYsdz1etiu3PV92KfV8oHYqdbxhdis2POI2K/a9ozYr9v2j9iu2fST2K7Z85bYrNrzmtip1/Ke2KPW86HYmM/zpdiIxe6o2HW56qzYXa3hsNhVp+Cz2E+i4LfYUJ/guthOoOG+2FKi3sHYi87xxdiKy+XJ2C5BbEHbK0NhRNsvVIFI28jv+UvbX6rgT9tHnN1S20ac3VbbRZvcWttGnNxd20md3WHbS53fZNtMnd1o20qc3WvbRpzbb9tMn91z21Gi4HbbVKThettbpuF9216n44HbXanihdtdp+GI21mm34zbVaTej9tPot2T20ye3ZbbS53emttKnd2e20ud3qHbSZzcpdtJm92o20ec3KzbRpzdsNtNnd6z20+d3Lfbc77rutuj3vK+2xUuVk/fJjpbUt8eMVBW3ydPiFrfbbbiXd98vuhh32u15GTfZ7HjaN9dqeFr31Cd3G/fRJjZc99AlNd230GS2XrfP5LXfd89kdiB3z6T2YXfPpLZiN9DlNmM30CV24/fQpXak99FltqW30ia25rfU6Lhnt9hseKh33W+5qXfgsjqqN9psN2s3yZNhrDfEiNNs99peJNr4nuMo2/iL0hsc+IeM1h24hgrUXriGCtVfeITKVWB4hArV4XiFSpUiOIVLVaM4hYuVY/iLUNpk+JfdZQ=
"""

    // MARK: Heart — uniform interior via point-in-polygon + Halton

    private static func makeHeartPoints(count: Int) -> [CGPoint] {
        let outline = makeHeartOutline()
        let outlineCount = min(220, count / 6)
        var points = resampleClosedPolyline(outline, count: outlineCount)
        points.reserveCapacity(count)
        var haltonIndex = 1
        // tight bounding box of heart in normalized 0…1 space (from outline)
        let minX: CGFloat = 0.12, maxX: CGFloat = 0.88
        let minY: CGFloat = 0.18, maxY: CGFloat = 0.95
        while points.count < count {
            let x = minX + halton(haltonIndex, base: 2) * (maxX - minX)
            let y = minY + halton(haltonIndex, base: 3) * (maxY - minY)
            let p = CGPoint(x: x, y: y)
            if isInsidePolygon(p, polygon: outline) {
                points.append(p)
            }
            haltonIndex += 1
            // safety: prevent infinite loop if count unreasonably large
            if haltonIndex > 60_000 { break }
        }
        if points.count < count {
            let needed = count - points.count
            let fallback = resampleClosedPolyline(outline, count: needed)
            points.append(contentsOf: fallback)
        }
        return points
    }

    private static func makeHeartOutline() -> [CGPoint] {
        (0..<heartVertexCount).map { i in
            let a = 2 * Double.pi * Double(i) / Double(heartVertexCount)
            let x = 16 * pow(sin(a), 3)
            let y = 13 * cos(a) - 5 * cos(2 * a) - 2 * cos(3 * a) - cos(4 * a)
            return CGPoint(x: 0.5 + x / 42, y: 0.5 - y / 42)
        }
    }

    private static func isInsidePolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].x, yi = polygon[i].y
            let xj = polygon[j].x, yj = polygon[j].y
            let intersect = ((yi > point.y) != (yj > point.y))
                && (point.x < (xj - xi) * (point.y - yi) / (yj - yi) + xi)
            if intersect { inside.toggle() }
            j = i
        }
        return inside
    }

    private static func orderedByAngle(_ particles: [MascotParticle]) -> [MascotParticle] {
        particles.sorted { lhs, rhs in
            let la = atan2(lhs.point.y - 0.5, lhs.point.x - 0.5)
            let ra = atan2(rhs.point.y - 0.5, rhs.point.x - 0.5)
            if la == ra { return hypot(lhs.point.x - 0.5, lhs.point.y - 0.5) < hypot(rhs.point.x - 0.5, rhs.point.y - 0.5) }
            return la < ra
        }
    }

    private static func orderedByAngle(_ points: [CGPoint]) -> [CGPoint] {
        points.sorted { lhs, rhs in
            let la = atan2(lhs.y - 0.5, lhs.x - 0.5)
            let ra = atan2(rhs.y - 0.5, rhs.x - 0.5)
            if la == ra { return hypot(lhs.x - 0.5, lhs.y - 0.5) < hypot(rhs.x - 0.5, rhs.y - 0.5) }
            return la < ra
        }
    }

    private static func halton(_ index: Int, base: Int) -> CGFloat {
        var r: CGFloat = 0, f: CGFloat = 1, v = index
        while v > 0 { f /= CGFloat(base); r += f * CGFloat(v % base); v /= base }
        return r
    }

    private static func resampleClosedPolyline(_ vertices: [CGPoint], count: Int) -> [CGPoint] {
        guard vertices.count > 1, count > 0 else { return [] }
        let segs = vertices.indices.map { i in
            let n = (i + 1) % vertices.count
            return hypot(vertices[n].x - vertices[i].x, vertices[n].y - vertices[i].y)
        }
        let total = segs.reduce(0, +)
        guard total > 0 else { return Array(repeating: vertices[0], count: count) }
        var pts: [CGPoint] = []
        pts.reserveCapacity(count)
        var segIdx = 0
        var segStart: CGFloat = 0
        for s in 0..<count {
            let target = total * CGFloat(s) / CGFloat(count)
            while segIdx < segs.count - 1, segStart + segs[segIdx] < target {
                segStart += segs[segIdx]; segIdx += 1
            }
            let a = vertices[segIdx], b = vertices[(segIdx + 1) % vertices.count]
            let len = max(segs[segIdx], .leastNonzeroMagnitude)
            let p = (target - segStart) / len
            pts.append(CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p))
        }
        return pts
    }
}
