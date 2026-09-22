//
//  WelcomeStepView.swift
//  Sorty
//
//  Welcome step of the onboarding flow
//

import AppKit
import AVFoundation
import Combine
import SwiftUI

// MARK: - Animated Gradient Background

struct AnimatedGradientBackground: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var animate = false
    @State private var isWindowVisible = true
    var revealed: Bool = true
    var color1: Color = .purple
    var color2: Color = .blue
    var color3: Color = .teal

    private var motionPaused: Bool {
        reduceMotion || reduceTransparency || !isWindowVisible
            || controlActiveState == .inactive || scenePhase != .active
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(colors: [color1.opacity(revealed ? 0.3 : 0), .clear], center: .center, startRadius: 0, endRadius: 200)
                )
                .frame(width: 400, height: 400)
                .offset(x: animate ? 50 : -50, y: animate ? -30 : 30)
                .blur(radius: reduceTransparency ? 0 : 28)

            Circle()
                .fill(
                    RadialGradient(colors: [color2.opacity(revealed ? 0.2 : 0), .clear], center: .center, startRadius: 0, endRadius: 250)
                )
                .frame(width: 500, height: 500)
                .offset(x: animate ? -40 : 60, y: animate ? 40 : -20)
                .blur(radius: reduceTransparency ? 0 : 32)

            Circle()
                .fill(
                    RadialGradient(colors: [color3.opacity(revealed ? 0.15 : 0), .clear], center: .center, startRadius: 0, endRadius: 180)
                )
                .frame(width: 350, height: 350)
                .offset(x: animate ? 30 : -30, y: animate ? 50 : -50)
                .blur(radius: reduceTransparency ? 0 : 24)
        }
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .onAppear {
            guard !motionPaused else { return }
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
        .onChange(of: motionPaused) { _, paused in
            if paused {
                withAnimation(nil) {
                    animate = false
                }
            } else {
                withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) {
                    animate = true
                }
            }
        }
    }
}

// MARK: - Reveal Gradient Blob

/// A vibrant gradient blob that expands from center to create the "reveal" moment
private struct RevealGradientBlob: View {
    @SortyHotReload private var hotReload
    let scale: CGFloat
    let opacity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var colorPhase: Double = 0
    @State private var isWindowVisible = true

    private var motionPaused: Bool {
        reduceMotion || reduceTransparency || !isWindowVisible || controlActiveState == .inactive
    }

    var body: some View {
        ZStack {
            // Primary blob - purple/indigo
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.purple.opacity(0.7),
                            Color.indigo.opacity(0.5),
                            Color.blue.opacity(0.3),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 300
                    )
                )
                .frame(width: 600, height: 500)
                .blur(radius: reduceTransparency ? 0 : 24)

            // Secondary blob - shifting hue
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.blue.opacity(0.5),
                            Color.purple.opacity(0.3),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 250
                    )
                )
                .frame(width: 450, height: 400)
                .offset(x: 30 * sin(colorPhase), y: -20 * cos(colorPhase))
                .blur(radius: reduceTransparency ? 0 : 20)

            // Bright core
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.15),
                            Color.purple.opacity(0.2),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 120
                    )
                )
                .frame(width: 240, height: 240)
                .blur(radius: reduceTransparency ? 0 : 12)
        }
        .scaleEffect(scale)
        .opacity(opacity)
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .onAppear {
            guard !motionPaused else { return }
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                colorPhase = .pi * 2
            }
        }
        .onChange(of: motionPaused) { _, paused in
            if paused {
                withAnimation(nil) {
                    colorPhase = 0
                }
            } else {
                withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                    colorPhase = .pi * 2
                }
            }
        }
    }
}

// MARK: - Glow Ring

/// A pulsing glow ring behind the app icon during reveal
private struct GlowRing: View {
    @SortyHotReload private var hotReload
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var pulseScale: CGFloat = 1.0
    @State private var isWindowVisible = true

    private var motionPaused: Bool {
        reduceMotion || reduceTransparency || !isWindowVisible || controlActiveState == .inactive
    }

    // How the ring is drawn: a static stroked circle whenever motion or
    // transparency is reduced. The pulse runs only while fully active.

    var body: some View {
        Circle()
            .stroke(
                AngularGradient(
                    colors: [.purple, .blue, .indigo, .purple],
                    center: .center
                ),
                lineWidth: 3
            )
            .frame(width: 120, height: 120)
            .scaleEffect(isActive ? pulseScale : 0.5)
            .opacity(isActive ? 0.6 : 0)
            .blur(radius: reduceTransparency ? 0 : 4)
            .background(WindowVisibilityReader(isVisible: $isWindowVisible))
            .onAppear {
                guard !motionPaused else { return }
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                    pulseScale = 1.15
                }
            }
            .onChange(of: motionPaused) { _, paused in
                if paused {
                    withAnimation(nil) {
                        pulseScale = 1
                    }
                } else {
                    withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                        pulseScale = 1.15
                    }
                }
            }
    }
}

// MARK: - Floating Particle

struct FloatingParticle: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var yOffset: CGFloat = 0
    @State private var opacity: Double = 0
    @State private var isWindowVisible = true
    let delay: Double
    let size: CGFloat
    let xPosition: CGFloat

    private var motionPaused: Bool {
        reduceMotion || !isWindowVisible || controlActiveState == .inactive
    }

    var body: some View {
        Circle()
            .fill(.white.opacity(0.3))
            .frame(width: size, height: size)
            .offset(x: xPosition, y: yOffset)
            .opacity(opacity)
            .background(WindowVisibilityReader(isVisible: $isWindowVisible))
            .onAppear {
                guard !motionPaused else { return }
                startDrift()
            }
            .onChange(of: motionPaused) { _, paused in
                if paused {
                    withAnimation(nil) {
                        yOffset = 0
                        opacity = 0
                    }
                } else {
                    startDrift()
                }
            }
    }

    // How particles resume: the same drift used on appear, so unpausing
    // (window visible again) restarts motion instead of leaving them parked.
    private func startDrift() {
        withAnimation(.easeInOut(duration: Double.random(in: 3...6)).repeatForever(autoreverses: false).delay(delay)) {
            yOffset = -300
            opacity = 0
        }
        withAnimation(.easeIn(duration: 1).delay(delay)) {
            opacity = 0.6
        }
    }
}

// MARK: - Welcome Step View

public struct WelcomeStepView: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var revealScale: CGFloat = 0.05
    @State private var revealOpacity: Double = 0
    @State private var backgroundRevealed = false
    @State private var hasAppeared = false
    @State private var featuresAppeared = false
    @State private var showGlowRing = false
    @State private var showParticles = false
    @State private var hasPlayedSound = false
    @State private var animationTask: Task<Void, Never>?
    @StateObject private var revealAudio = WelcomeRevealAudio()
    @StateObject private var onboardingAudio = OnboardingAudioManager()

    public init() {}

    public var body: some View {
        ZStack {
            // Base dark layer
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            // Reveal gradient blob - expands from center
            RevealGradientBlob(scale: revealScale, opacity: revealOpacity)
                .allowsHitTesting(false)

            // Ambient gradient (fades in after reveal)
            AnimatedGradientBackground(revealed: backgroundRevealed)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Floating particles (appear after reveal). Size and lane are
            // seeded from the index so parent re-renders never re-randomize them.
            if showParticles {
                ZStack {
                    ForEach(0..<7, id: \.self) { i in
                        FloatingParticle(
                            delay: Double(i) * 0.4,
                            size: 3 + CGFloat((i * 37 + 11) % 30) / 10,
                            xPosition: CGFloat((i * 137 + 43) % 400) - 200
                        )
                    }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            // Content
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 18) {
                    ZStack {
                        GlowRing(isActive: showGlowRing)

                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 104, height: 104)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .shadow(color: .purple.opacity(hasAppeared ? 0.25 : 0), radius: 20, x: 0, y: 8)
                            .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
                    }
                    .scaleEffect(hasAppeared ? 1 : 0.3)
                    .opacity(hasAppeared ? 1 : 0)
                    .animation(.spring(response: 0.9, dampingFraction: 0.7).delay(0.6), value: hasAppeared)

                    VStack(spacing: 12) {
                        Text("Welcome to Sorty")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.9), value: hasAppeared)

                        Text("Sorty-powered file organization for your Mac")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 15)
                            .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(1.1), value: hasAppeared)
                    }
                }

                Spacer()
                    .frame(height: 24)

                VStack(alignment: .leading, spacing: 12) {
                    WelcomeFeatureRow(
                        icon: "wand.and.stars",
                        iconColor: .purple,
                        title: "Smart Organization",
                        description: "Sorty analyzes your files and creates a logical folder structure"
                    )
                    .opacity(featuresAppeared ? 1 : 0)
                    .offset(x: featuresAppeared ? 0 : -30)
                    .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(1.3), value: featuresAppeared)

                    WelcomeFeatureRow(
                        icon: "lock.shield.fill",
                        iconColor: .green,
                        title: "Privacy Focused",
                        description: "File names and metadata are sent to Sorty for organization - file contents stay on your Mac unless Deep Scan is enabled"
                    )
                    .opacity(featuresAppeared ? 1 : 0)
                    .offset(x: featuresAppeared ? 0 : -30)
                    .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(1.5), value: featuresAppeared)

                    WelcomeFeatureRow(
                        icon: "arrow.uturn.backward.circle.fill",
                        iconColor: .blue,
                        title: "Fully Reversible",
                        description: "Every change can be undone with a single click"
                    )
                    .opacity(featuresAppeared ? 1 : 0)
                    .offset(x: featuresAppeared ? 0 : -30)
                    .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(1.7), value: featuresAppeared)

                    WelcomeFeatureRow(
                        icon: "person.crop.circle.badge.checkmark",
                        iconColor: .orange,
                        title: "Custom Workflows",
                        description: "Create personas tailored to your specific organization needs"
                    )
                    .opacity(featuresAppeared ? 1 : 0)
                    .offset(x: featuresAppeared ? 0 : -30)
                    .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(1.9), value: featuresAppeared)
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, 40)

                Spacer()
                    .frame(height: 16)

                HStack(spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.system(size: 18))

                    Text("Before organizing, always ensure you have backups of important files.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(14)
                .frame(maxWidth: 460)
                .systemLiquidGlassBackground(cornerRadius: 12)
                .opacity(featuresAppeared ? 1 : 0)
                .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(2.1), value: featuresAppeared)

                Spacer()
            }
        }
        .onAppear {
            startRevealSequence()
        }
        .onDisappear {
            animationTask?.cancel()
            animationTask = nil
            revealAudio.stop()
            onboardingAudio.stopAll()
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            if shouldReduceMotion {
                settleRevealSequence()
            }
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome Step")
    }

    private func startRevealSequence() {
        animationTask?.cancel()

        // Phase 1: Gradient blob reveal (0 - 0.8s)
        revealAudio.playRevealSwell()
        onboardingAudio.startBackgroundMelody()

        guard !reduceMotion else {
            settleRevealSequence()
            return
        }

        withAnimation(.easeOut(duration: 1.0)) {
            revealScale = 1.2
            revealOpacity = 1.0
        }

        // Phase 2+: async sequence stored for cancellation on disappear
        animationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 1.2)) {
                backgroundRevealed = true
                revealOpacity = 0.3
                revealScale = 1.5
            }

            // Phase 3: Content appears (0.6s)
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }

            withAnimation(.spring(response: 0.8, dampingFraction: 0.85)) {
                hasAppeared = true
                showGlowRing = true
            }

            // Play sparkle sound as icon appears
            if !hasPlayedSound {
                if let sound = NSSound(named: "Glass") {
                    sound.volume = 0.15
                    sound.play()
                }
                hasPlayedSound = true
            }

            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            // Phase 4: Particles and features
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.8)) {
                showParticles = true
            }

            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85)) {
                featuresAppeared = true
            }
        }
    }

    private func settleRevealSequence() {
        animationTask?.cancel()
        animationTask = nil
        withAnimation(nil) {
            revealScale = 1.5
            revealOpacity = 0.3
            backgroundRevealed = true
            hasAppeared = true
            featuresAppeared = true
            showGlowRing = true
            showParticles = false
        }
    }
}

// MARK: - Welcome Reveal Audio

/// Synthesizes a short swell/shimmer sound for the reveal animation
@MainActor
private class WelcomeRevealAudio: ObservableObject {
    private final class AudioState: @unchecked Sendable {
        var engine: AVAudioEngine?
        var sourceNode: AVAudioSourceNode?
        var phase: Double = 0
        var isRunning: Bool = false
        var sampleCounter: Int = 0
    }

    private let state = AudioState()
    private var stopWorkItem: DispatchWorkItem?

    func playRevealSwell() {
        createAndStartEngine()

        // Auto-stop after the swell completes (cancellable)
        stopWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.stop()
        }
        stopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    /// Engine setup is nonisolated so the AVAudioSourceNode render callback
    /// does NOT inherit @MainActor isolation.  The render callback runs on the
    /// real-time audio IO thread; inheriting @MainActor causes a
    /// _dispatch_assert_queue_fail crash (EXC_BREAKPOINT / SIGTRAP).
    nonisolated private func createAndStartEngine() {
        let engine = AVAudioEngine()
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = outputFormat.sampleRate
        let st = state

        st.phase = 0
        st.sampleCounter = 0
        st.isRunning = true

        // Total duration ~1.2 seconds
        let totalSamples = Int(1.2 * sampleRate)

        // Shimmer: ascending blend of harmonics with volume swell
        let sourceNode = AVAudioSourceNode(format: outputFormat) {
            [st] (_, _, frameCount, bufferList) -> OSStatus in

            guard st.isRunning else {
                let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
                for buffer in ablPointer {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                return noErr
            }

            let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)

            for frame in 0..<Int(frameCount) {
                let pos = st.sampleCounter
                guard pos < totalSamples else {
                    st.isRunning = false
                    let floatSample = Float(0)
                    for buffer in ablPointer {
                        let buf = buffer.mData!.assumingMemoryBound(to: Float.self)
                        buf[frame] = floatSample
                    }
                    continue
                }

                let t = Double(pos) / sampleRate
                let progress = Double(pos) / Double(totalSamples)

                // Volume envelope: swell up then fade
                let envelope: Double
                if progress < 0.4 {
                    // Swell in
                    envelope = progress / 0.4
                } else if progress < 0.7 {
                    // Sustain
                    envelope = 1.0
                } else {
                    // Fade out
                    envelope = (1.0 - progress) / 0.3
                }
                // Smooth the envelope with cosine
                let smoothEnvelope = 0.5 * (1.0 - cos(Double.pi * max(0, min(1, envelope))))

                // Ascending shimmer: blend of frequencies that rise over time
                let baseFreq = 400.0 + progress * 800.0  // 400 Hz → 1200 Hz
                let inc1 = 2.0 * Double.pi * baseFreq / sampleRate
                let inc2 = 2.0 * Double.pi * (baseFreq * 1.5) / sampleRate  // Perfect fifth
                let inc3 = 2.0 * Double.pi * (baseFreq * 2.0) / sampleRate  // Octave

                st.phase += inc1
                if st.phase > 2.0 * Double.pi { st.phase -= 2.0 * Double.pi }

                var sample = sin(st.phase) * 0.5
                sample += sin(st.phase * 1.5 + t * 3) * 0.25  // Fifth with slight detune
                sample += sin(st.phase * 2.0 + t * 5) * 0.15  // Octave shimmer
                _ = inc2; _ = inc3

                sample *= smoothEnvelope * 0.12  // Keep it subtle

                let floatSample = Float(sample)
                for buffer in ablPointer {
                    let buf = buffer.mData!.assumingMemoryBound(to: Float.self)
                    buf[frame] = floatSample
                }

                st.sampleCounter += 1
            }

            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: outputFormat)
        engine.mainMixerNode.outputVolume = 1.0

        do {
            try engine.start()
        } catch {
            st.isRunning = false
            return
        }

        st.engine = engine
        st.sourceNode = sourceNode
    }

    func stop() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        state.isRunning = false
        state.engine?.stop()
        state.engine = nil
        state.sourceNode = nil
    }

    deinit {
        state.isRunning = false
        state.engine?.stop()
    }
}

// MARK: - Welcome Feature Row

struct WelcomeFeatureRow: View {
    @SortyHotReload private var hotReload
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    var badge: String? = nil

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.1))
                    .frame(width: 40, height: 40)

                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(title))
                        .font(.headline)

                    if let badge {
                        OnboardingCapsuleBadge(text: badge)
                    }
                }

                Text(LocalizedStringKey(description))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .systemLiquidGlassBackground(cornerRadius: 14)
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    WelcomeStepView()
}
