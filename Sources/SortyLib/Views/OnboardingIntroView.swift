import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import os

// MARK: - Onboarding Title Bar

@MainActor
final class OnboardingIntroTaskController {
    var iconPreparationTask: Task<Void, Never>?
    var revealGeneration = 0
}

struct OnboardingIntroView: View {
    @SortyHotReload private var hotReload
    let onRevealPhaseChanged: (OnboardingIntroRevealPhase) -> Void
    let onGetStarted: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var iconScale: CGFloat = 0.86
    @State private var iconOpacity: Double = 0
    @State private var glowVisible = false
    @State private var chromeRevealed = false
    @State private var textOpacity: Double = 0
    @State private var textOffset: CGFloat = 14
    @State private var filesAppeared = false
    @State private var isGetStartedAvailable = false
    @State private var fileIcons: [String: NSImage] = [:]
    @State private var taskController = OnboardingIntroTaskController()
    @StateObject private var audio = OnboardingAudioManager()

    var body: some View {
        ZStack {
            // Phase 1 of the reveal shows only the icon and its rose glow on a
            // fully transparent window — no backdrop, no "app window" feel.
            // The gradient fades in later together with the title and button.
            OnboardingBottomGradient()
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .opacity(chromeRevealed ? 0.92 : 0)

            OnboardingIntroContentLayer(
                icons: fileIcons,
                filesVisible: filesAppeared,
                iconScale: iconScale,
                iconOpacity: iconOpacity,
                glowVisible: glowVisible,
                textOpacity: textOpacity,
                textOffset: textOffset,
                isGetStartedAvailable: isGetStartedAvailable
            ) {
                HapticFeedbackManager.shared.success()
                taskController.revealGeneration += 1
                taskController.iconPreparationTask?.cancel()
                audio.stopAll()
                onGetStarted()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to Sorty")
        .onAppear {
            runIntroReveal()
        }
        .onDisappear {
            taskController.revealGeneration += 1
            taskController.iconPreparationTask?.cancel()
            audio.stopAll()
        }
    }

    /// Orchestrates the first-screen reveal to the bundled soundtrack:
    /// 1. Only the icon and its rose glow, floating on a transparent window.
    /// 2. The gradient backdrop, title, and button appear on the next accent.
    /// 3. The orbiting file chips drift in last.
    /// The audio engine is deferred so its AVAudioEngine + AVAudioSourceNode
    /// setup does not block the first paint of the icon, and the
    /// `revealGeneration` counter cancels any in-flight reveal if the view
    /// disappears before the sequence finishes.
    private func runIntroReveal() {
        taskController.revealGeneration += 1
        let generation = taskController.revealGeneration
        taskController.iconPreparationTask?.cancel()

        taskController.iconPreparationTask = Task { @MainActor in
            // Let the window commit its empty first frame before NSWorkspace
            // resolves cold file icons. Core Graphics rasterization runs on the
            // concurrent pool; only immutable NSImages return to the view.
            await Task.yield()
            let icons = await measuredIntroIcons()
            guard generation == taskController.revealGeneration, !Task.isCancelled else { return }
            fileIcons = icons

            if reduceMotion {
                iconScale = 1
                iconOpacity = 1
                glowVisible = true
                chromeRevealed = true
                textOpacity = 1
                textOffset = 0
                filesAppeared = true
                isGetStartedAvailable = true
                onRevealPhaseChanged(.files)
                audio.startBackgroundMelody()
                return
            }

            onRevealPhaseChanged(.icon)
            // Construct and prepare the player before the icon's first visible
            // frame, then schedule its cue on the audio clock so no main-actor
            // audio work lands during the icon spring.
            os_signpost(.begin, log: onboardingPerformanceLog, name: "Onboarding audio preparation")
            await audio.prepareBackgroundMelody()
            os_signpost(.end, log: onboardingPerformanceLog, name: "Onboarding audio preparation")
            guard generation == taskController.revealGeneration, !Task.isCancelled else { return }
            let playbackStart = audio.startBackgroundMelody(after: 0.1)
            await beginAnimatedReveal(generation: generation, playbackStart: playbackStart)
        }
    }

    private func measuredIntroIcons() async -> [String: NSImage] {
        os_signpost(.begin, log: onboardingPerformanceLog, name: "Onboarding icon rasterization")
        defer {
            os_signpost(.end, log: onboardingPerformanceLog, name: "Onboarding icon rasterization")
        }
        return await OnboardingFileIconProvider.icons(for: OnboardingOrbitFile.files)
    }

    /// Cue offsets follow the attacks in OnboardingSound.m4a. Absolute deadlines
    /// keep later reveals aligned even when an earlier frame runs late.
    private func beginAnimatedReveal(
        generation: Int,
        playbackStart: ContinuousClock.Instant
    ) async {
        let clock = ContinuousClock()
        do {
            try await clock.sleep(until: playbackStart)
            guard generation == taskController.revealGeneration, !Task.isCancelled else { return }
            if NSApp.isActive { HapticFeedbackManager.shared.light() }
            withAnimation(.easeOut(duration: 0.34)) {
                iconOpacity = 1
            }
            withAnimation(.spring(response: 0.56, dampingFraction: 0.88)) {
                iconScale = 1
            }
            glowVisible = true

            try await clock.sleep(until: playbackStart.advanced(by: .seconds(0.34)))
            guard generation == taskController.revealGeneration, !Task.isCancelled else { return }
            onRevealPhaseChanged(.screenGlow)
            if NSApp.isActive { HapticFeedbackManager.shared.light() }

            try await clock.sleep(until: playbackStart.advanced(by: .seconds(0.96)))
            guard generation == taskController.revealGeneration, !Task.isCancelled else { return }
            onRevealPhaseChanged(.window)
            if NSApp.isActive { HapticFeedbackManager.shared.light() }
            withAnimation(.easeInOut(duration: 0.36)) {
                chromeRevealed = true
            }
            withAnimation(.easeOut(duration: 0.36)) {
                textOpacity = 1
                textOffset = 0
            }

            try await clock.sleep(until: playbackStart.advanced(by: .seconds(1.32)))
            guard generation == taskController.revealGeneration, !Task.isCancelled else { return }
            filesAppeared = true
            onRevealPhaseChanged(.files)
            if NSApp.isActive { HapticFeedbackManager.shared.light() }

            try await clock.sleep(until: playbackStart.advanced(by: .seconds(2.04)))
            guard generation == taskController.revealGeneration, !Task.isCancelled else { return }
            isGetStartedAvailable = true
        } catch {
            // Leaving the intro cancels the remaining soundtrack cues.
            return
        }
    }

}

/// Keeps pointer-driven intro state isolated from the reveal and audio state
/// owned by the surrounding onboarding step.
struct OnboardingIntroContentLayer: View {
    @SortyHotReload private var hotReload
    let icons: [String: NSImage]
    let filesVisible: Bool
    let iconScale: CGFloat
    let iconOpacity: Double
    let glowVisible: Bool
    let textOpacity: Double
    let textOffset: CGFloat
    let isGetStartedAvailable: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var introSize: CGSize = .zero
    @State private var buttonCenter: CGPoint = .zero
    @State private var isHoveringButton = false
    @State private var hoverExitTask: Task<Void, Never>?

    private nonisolated static let coordinateSpace = "OnboardingIntroContentLayer"

    var body: some View {
        ZStack {
            OnboardingOrbitField(
                icons: icons,
                filesVisible: filesVisible,
                isCollapsed: isHoveringButton,
                collapseOrigin: CGSize(
                    width: buttonCenter.x - introSize.width / 2,
                    height: buttonCenter.y - introSize.height / 2
                ),
                reduceMotion: reduceMotion,
                isActive: controlActiveState != .inactive
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            VStack(spacing: 26) {
                VStack(spacing: 20) {
                    ZStack {
                        RetainedIntroGlow(
                            isVisible: glowVisible,
                            reduceMotion: reduceMotion,
                            isActive: controlActiveState != .inactive
                        )
                        .frame(width: 220, height: 220)
                        .accessibilityHidden(true)

                        SortyEnergyScanIcon(
                            image: NSApp.applicationIconImage,
                            size: 156,
                            cornerRadius: 34
                        )
                        .shadow(
                            color: SortyDesignSystem.Colors.resolvedAccent.opacity(0.22),
                            radius: 34
                        )
                        .shadow(color: .black.opacity(0.28), radius: 26, x: 0, y: 16)
                        .accessibilityHidden(true)
                    }
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)

                    Text("Welcome to Sorty")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.88))
                        .opacity(textOpacity)
                        .offset(y: textOffset)
                }

                Button(action: action) {
                    HStack(spacing: 8) {
                        Text("Get Started")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .buttonStyle(
                    .sortyPrimary(
                        size: .large,
                        isGlassInteractive: false
                    )
                )
                .keyboardShortcut(.defaultAction)
                .disabled(!isGetStartedAvailable)
                .opacity(isGetStartedAvailable ? 1 : 0.62)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isGetStartedAvailable)
                .accessibilityIdentifier("OnboardingAdvanceButton")
                .background {
                    Color.clear
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named(Self.coordinateSpace))
                        } action: { frame in
                            let center = CGPoint(x: frame.midX, y: frame.midY)
                            if buttonCenter != center {
                                buttonCenter = center
                            }
                        }
                }
                .onHover { hovering in
                    hoverExitTask?.cancel()

                    if hovering {
                        hoverExitTask = nil
                        isHoveringButton = true
                    } else {
                        hoverExitTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(90))
                            guard !Task.isCancelled else { return }
                            isHoveringButton = false
                        }
                    }
                }
                .opacity(textOpacity)
                .offset(y: textOffset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: Self.coordinateSpace)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            if introSize != size {
                introSize = size
            }
        }
        .onDisappear {
            hoverExitTask?.cancel()
            hoverExitTask = nil
        }
    }
}
