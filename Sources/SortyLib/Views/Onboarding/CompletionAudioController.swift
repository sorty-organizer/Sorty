import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI

// MARK: - Completion Step View

@MainActor
final class CompletionAudioController {
    static let shared = CompletionAudioController()
    private var player: AVAudioPlayer?
    private var revealAccent: NSSound?
    private var fadeTask: Task<Void, Never>?

    func prepare() async {
        if revealAccent == nil {
            revealAccent = NSSound(named: "Glass")
            revealAccent?.volume = 0.15
        }
        guard player == nil else { return }
        guard let soundURL = resolvedSoundURL() else { return }
        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: soundURL, options: .mappedIfSafe)
        }.value
        guard !Task.isCancelled, player == nil, let data else { return }

        preparePlayer(data: data)
    }

    private func prepareSynchronouslyIfNeeded() {
        guard player == nil else { return }
        let soundURL = resolvedSoundURL()
        guard let soundURL else { return }

        do {
            let player = try AVAudioPlayer(contentsOf: soundURL)
            player.numberOfLoops = 0
            player.volume = 0.3
            player.prepareToPlay()
            self.player = player
        } catch {
            print("[CompletionStepView] Failed to prepare Final Onboarding sound: \(error)")
        }
    }

    private func preparePlayer(data: Data) {
        do {
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = 0
            player.volume = 0.3
            player.prepareToPlay()
            self.player = player
        } catch {
            print("[CompletionStepView] Failed to prepare Final Onboarding sound: \(error)")
        }
    }

    private func resolvedSoundURL() -> URL? {
        SortyResources.finalOnboardingSoundURL()
            ?? Bundle.main.url(forResource: "Final Onboarding", withExtension: "m4a")
    }

    func play() {
        fadeTask?.cancel()
        fadeTask = nil
        prepareSynchronouslyIfNeeded()
        player?.currentTime = 0
        player?.volume = 0.3
        player?.play()
    }

    func playRevealAccent() {
        if revealAccent == nil {
            revealAccent = NSSound(named: "Glass")
            revealAccent?.volume = 0.15
        }
        revealAccent?.play()
    }

    func fadeOutAndStop(duration: TimeInterval) {
        fadeTask?.cancel()
        guard let player else { return }
        player.setVolume(0, fadeDuration: duration)
        fadeTask = Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            player?.stop()
            self?.player = nil
            self?.fadeTask = nil
        }
    }
}

@MainActor
enum OnboardingCompletionAudio {
    static func prewarm() async {
        await CompletionAudioController.shared.prepare()
    }
}
