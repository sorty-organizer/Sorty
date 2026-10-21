import AppKit
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI

// MARK: - Introduction
extension SkillSetupView {
    var isIntroduction: Bool {
        step == .rethink || step == .about || step == .welcome
    }

    var needsImportOptions: Bool {
        step == .preferences || step == .review
    }

    var isWaitingForOptions: Bool {
        needsImportOptions && (isLoading || !hasLoadedOptions)
    }

    var underlinedSkillPhrase: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Sorty can be a skill")
                .overlay(alignment: .bottom) {
                    GeometryReader { geometry in
                        Path { path in
                            let width = geometry.size.width
                            path.move(to: CGPoint(x: 0, y: 5))
                            path.addCurve(
                                to: CGPoint(x: width, y: 3),
                                control1: CGPoint(x: width * 0.3, y: 0),
                                control2: CGPoint(x: width * 0.65, y: 10)
                            )
                        }
                        .trim(from: 0, to: introductionStage >= 3 ? 1 : 0)
                        .stroke(.tint, style: StrokeStyle(lineWidth: titleSize * 0.09, lineCap: .round))
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.32),
                            value: introductionStage >= 3
                        )
                    }
                    .frame(height: 10)
                    .offset(y: 7)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            Text(".")
        }
    }

    func introductionReveal(at stage: Int) -> SkillIntroductionReveal {
        SkillIntroductionReveal(
            isVisible: !isIntroduction || introductionStage >= stage,
            reduceMotion: reduceMotion,
            duration: step == .rethink ? 0.22 : 0.35
        )
    }

    /// Starts the first soundtrack off-main, then follows its playback position.
    func startIntroSound() async -> AVAudioPlayer? {
        if let player = introAudioPlayer {
            player.stop()
            player.currentTime = 0
            return player.play() ? player : nil
        }

        let player = await Self.makePlayingIntroPlayer()
        guard !Task.isCancelled else {
            player?.stop()
            return nil
        }
        introAudioPlayer = player
        return player
    }

    /// Transfers sole ownership after audio-queue setup and the first play call.
    @concurrent
    static func makePlayingIntroPlayer() async -> sending AVAudioPlayer? {
        guard !Task.isCancelled,
              let soundURL = Bundle.main.url(forResource: "SkillOnboardingSound", withExtension: "m4a")
                ?? SortyResources.urlForCopiedResource(named: "SkillOnboardingSound.m4a"),
              let data = try? Data(contentsOf: soundURL, options: .mappedIfSafe),
              let player = try? AVAudioPlayer(data: data)
        else { return nil }

        player.numberOfLoops = 0
        player.volume = 0.6
        player.prepareToPlay()
        guard !Task.isCancelled, player.play() else { return nil }
        return player
    }

    /// Follow playback position, leading each effect so its visible midpoint
    /// coincides with the selected note attack.
    /// Returning to the introduction replays the same sequence.
    func revealIntroduction() async {
        guard isIntroduction else { return }
        if !reduceMotion {
            introductionStage = 0
            if step == .rethink { hasRevealedSkillUnderline = false }
        }
        if step == .rethink, skillIcon == nil {
            let image = await SortyResources.imageAsync(named: "SortySkillIcon")
            guard !Task.isCancelled else { return }
            skillIcon = image
        }
        let clock = ContinuousClock()
        var soundtrack: AVAudioPlayer?
        if isOnboarding && step == .rethink {
            soundtrack = await startIntroSound()
            guard !Task.isCancelled else { return }
        }
        let revealStart = clock.now
        if reduceMotion {
            introductionStage = finalIntroductionStage
            isHeadingFocused = true
            return
        }

        // Match each effect's visible midpoint to its measured audio attack.
        // AppKit render probes include the next-frame delay as well as easing;
        // the slide needs more lead than the fades and underline.
        let cueOffsets: [Double] = step == .rethink
            ? [
                0.120 - 0.115, // Sentence and rail: 220 ms ease-out fade.
                0.985 - 0.115, // Headline: 220 ms ease-out fade.
                2.690 - 0.158, // Underline: 320 ms ease-out stroke.
                3.570 - 0.115, // App icon: 220 ms ease-out fade.
                4.415 - 0.258, // Slide: 450 ms ease-in-out motion.
                5.710 - 0.095, // Arrow: 160 ms ease-out fade.
                6.135 - 0.115, // Skill icon: 220 ms ease-out fade.
                6.925 - 0.137, // Button emphasis: 200 ms ease-in-out.
            ]
            : [0, 0.70, 1.40, 2.00, 2.60]
        do {
            for (index, offset) in cueOffsets.enumerated() {
                if let soundtrack {
                    // Read the audio's position rather than assuming playback
                    // began when the main actor called play(). Only this brief
                    // reveal polls; no idle timer or repeated view updates remain.
                    while soundtrack.isPlaying && soundtrack.currentTime < offset {
                        try await Task.sleep(for: .milliseconds(8))
                    }
                } else {
                    try await clock.sleep(until: revealStart.advanced(by: .seconds(offset)))
                }
                try Task.checkCancellation()
                introductionStage = index + 1
                if introductionStage == 2 { isHeadingFocused = true }
            }
        } catch {
            // SwiftUI cancels the sequence when the user leaves this page.
        }
    }

    var skillIconTransition: some View {
        ZStack {
            SkillIntroductionAppIcon(
                isBlurred: introductionStage >= 5 && !reduceMotion && !reduceTransparency,
                animatesBlur: !reduceMotion
            )
                .frame(width: 160, height: 160)
                .opacity(introductionStage >= 5 ? 0.55 : 1)
                .offset(x: introductionStage >= 5 ? -120 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: introductionStage >= 5)

            Image(systemName: "arrow.right")
                .font(.largeTitle.weight(.medium))
                .foregroundStyle(.secondary)
                .opacity(introductionStage >= 6 ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: introductionStage >= 6)

            if let skillIcon {
                Image(nsImage: skillIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160, height: 160)
                    .offset(x: 120)
                    .opacity(introductionStage >= 7 ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: introductionStage >= 7)
            }
        }
        .frame(width: 400, height: 180)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("From the Sorty app to the Sorty skill")
        .accessibilityIdentifier("skill-import.icon-transition")
    }

    var importProgress: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Importing preferences")
                    .font(headingFont)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($isHeadingFocused)
                Text("Saving your selection to the Sorty skill.")
                    .font(readingFont)
                    .foregroundStyle(.secondary)
            }
            if reduceMotion {
                Label("Import in progress", systemImage: "arrow.down.doc")
                    .font(supportingFont)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                    .accessibilityLabel("Import in progress")
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("skill-import.progress")
        .onAppear {
            isHeadingFocused = true
            AccessibilityNotification.Announcement("Importing preferences").post()
        }
    }

    var progressRail: some View {
        HStack(spacing: 16) {
            ForEach(Array(setupSteps.enumerated()), id: \.element) { index, item in
                HStack(spacing: 8) {
                    Image(systemName: step.rawValue > item.rawValue ? "checkmark.circle.fill" : "\(index + 1).circle\(step == item ? ".fill" : "")")
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .accessibilityHidden(true)
                    Text(item.railTitle)
                        .font(supportingFont.weight(step == item ? .semibold : .regular))
                }
                .foregroundStyle(step.rawValue >= item.rawValue ? Color.primary : Color.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(index + 1), \(item.railTitle)")
                .accessibilityValue(step.rawValue > item.rawValue ? "Completed" : step == item ? "Current" : "Upcoming")
                if item != .review {
                    Rectangle().fill(.secondary.opacity(0.25)).frame(width: 24, height: 1)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}
