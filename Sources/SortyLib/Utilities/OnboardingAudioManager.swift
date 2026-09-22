//
//  OnboardingAudioManager.swift
//  Sorty
//
//  Manages audio for the onboarding demo animation.
//  Uses AVAudioEngine with synthesized sine-wave tones to play a gentle,
//  looping pentatonic melody with a bass drone, replacing system sounds.
//

import AppKit
@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
class OnboardingAudioManager: ObservableObject {
    nonisolated private static let defaultMelodyVolume: Float = 0.20
    nonisolated private static let defaultBassVolume: Float = 0.12

    private(set) var isPlaying = false

    // MARK: - Audio Engine State (isolated in @unchecked Sendable AudioState)

    /// All mutable state touched by the audio render thread lives here. The
    /// render callback is the only writer while the engine is running;
    /// main-thread code only writes when the engine is stopped.
    private final class AudioState: @unchecked Sendable {
        // Engine & nodes
        var engine: AVAudioEngine?
        var melodyNode: AVAudioSourceNode?
        var bassNode: AVAudioSourceNode?

        // Melody sequencer state
        var melodyPhase: Double = 0
        var bassPhase: Double = 0
        var currentNoteIndex: Int = 0
        var sampleCounter: Int = 0

        // Volume / running
        var melodyVolume: Float = OnboardingAudioManager.defaultMelodyVolume
        var bassVolume: Float = OnboardingAudioManager.defaultBassVolume
        var isRunning: Bool = false

        // Fanfare overlay
        var fanfareActive: Bool = false
        var fanfareNoteIndex: Int = 0
        var fanfareSampleCounter: Int = 0
        var fanfarePhase: Double = 0
        var fanfareEnvelopeSample: Int = 0
    }

    private let state = AudioState()

    private var audioPlayer: AVAudioPlayer?
    private var fadeTask: Task<Void, Never>?
    private var playerStopTask: Task<Void, Never>?

    // MARK: - Constants

    /// Suspended-quality pentatonic scale rooted on C4 (Hz) for a warm, ambient feel.
    nonisolated private static let melodyNotes: [Double] = [
        261.63,  // C4
        293.66,  // D4
        349.23,  // F4
        392.00,  // G4
        440.00,  // A4
    ]

    /// A meditative, repeating melodic pattern (indices into melodyNotes).
    nonisolated private static let melodyPattern: [Int] = [
        0, 2, 3, 4,   // C F G A   (rising)
        3, 2, 0, 2,   // G F C F   (settling)
        0, 3, 4, 2,   // C G A F   (gentle movement)
        4, 3, 2, 0,   // A G F C   (descending home)
    ]

    /// Gentle rising arpeggio for completion (Hz values).
    nonisolated private static let fanfareNotes: [Double] = [
        261.63,  // C4
        349.23,  // F4
        440.00,  // A4
        523.25,  // C5
    ]

    /// Bass drone frequency: C3.
    nonisolated private static let bassFrequency: Double = 130.81

    /// Duration of each melody note in seconds (slow for ambient pacing).
    nonisolated private static let noteDuration: Double = 0.55

    /// Duration of each fanfare note in seconds.
    nonisolated private static let fanfareNoteDuration: Double = 0.30

    // MARK: - Public API

    enum Phase: String {
        case messy
        case scanning
        case thinking
        case comparing
        case organizing
        case complete
    }

    /// Load and prepare the bundled soundtrack before a reveal begins.
    func prepareBackgroundMelody() async {
        guard audioPlayer == nil, !state.isRunning,
              let soundURL = resolvedBackgroundMelodyURL()
        else { return }

        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: soundURL, options: .mappedIfSafe)
        }.value

        guard !Task.isCancelled, audioPlayer == nil, !state.isRunning, let data else { return }
        do {
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = 0
            player.volume = 0.25
            player.prepareToPlay()
            audioPlayer = player
        } catch {
            print("[OnboardingAudioManager] Failed to prepare OnboardingSound.m4a: \(error)")
        }
    }

    /// Start the bundled background melody, falling back to the synthesized loop.
    func startBackgroundMelody(after delay: TimeInterval = 0) {
        // A pending fade-out owns the engine volumes; cancel it so a restart
        // does not get its levels zeroed or its engine stopped mid-fade.
        fadeTask?.cancel()
        fadeTask = nil
        playerStopTask?.cancel()
        playerStopTask = nil
        guard !state.isRunning else { return }

        if let audioPlayer {
            audioPlayer.currentTime = 0
            audioPlayer.volume = 0.25
            if delay > 0 {
                audioPlayer.play(atTime: audioPlayer.deviceCurrentTime + delay)
            } else {
                audioPlayer.play()
            }
            state.isRunning = true
            isPlaying = true
            return
        }

        if let soundURL = resolvedBackgroundMelodyURL() {
            do {
                let player = try AVAudioPlayer(contentsOf: soundURL)
                player.numberOfLoops = 0
                player.volume = 0.25
                if delay > 0 {
                    player.play(atTime: player.deviceCurrentTime + delay)
                } else {
                    player.play()
                }
                audioPlayer = player
                state.isRunning = true
                isPlaying = true
                return
            } catch {
                print("[OnboardingAudioManager] Failed to play OnboardingSound.m4a: \(error)")
            }
        } else {
            print("[OnboardingAudioManager] OnboardingSound.m4a not found in any bundle location")
        }
        
        // Fallback to synthesized melody
        setupAndStartEngine()
        isPlaying = true
    }

    private func resolvedBackgroundMelodyURL() -> URL? {
        SortyResources.onboardingSoundURL()
            ?? Bundle.main.url(forResource: "OnboardingSound", withExtension: "m4a")
    }

    /// Play a phase-transition accent.  Use soft, ambient system sounds
    /// that layer gently on top of the melody.
    func playPhaseSound(_ phase: Phase) {
        let soundName: NSSound.Name
        let volume: Float
        switch phase {
        case .messy:
            return
        case .scanning:
            soundName = "Submarine"
            volume = 0.15
        case .thinking:
            soundName = "Glass"
            volume = 0.10
        case .comparing:
            return  // Let the melody carry this transition
        case .organizing:
            soundName = "Submarine"
            volume = 0.10
        case .complete:
            soundName = "Glass"
            volume = 0.20
        }
        if let sound = NSSound(named: soundName) {
            sound.volume = volume
            sound.play()
        }
    }

    /// Start the ambient pulse — delegates to the background melody.
    func startAmbientPulse(interval: TimeInterval = 1.0) {
        startBackgroundMelody()
    }

    /// Stop ambient pulse (convenience; calls through to stopAll).
    func stopAmbientPulse() {
        // Don't tear down the whole engine here — just note that the pulse
        // has been conceptually stopped.  The melody keeps going until
        // stopAll() is called.  This preserves the call-site pattern where
        // stopAmbientPulse() is called between phases.
    }

    /// Play a rising arpeggio completion fanfare overlaid on the melody.
    func playCompletionFanfare() {
        // If the melody engine isn't running, start it so we have a place
        // to play the fanfare.
        if !state.isRunning {
            setupAndStartEngine()
        }
        state.fanfareNoteIndex = 0
        state.fanfareSampleCounter = 0
        state.fanfarePhase = 0
        state.fanfareEnvelopeSample = 0
        state.fanfareActive = true
    }

    /// Stop all audio and tear down the engine.
    func stopAll() {
        guard state.isRunning || audioPlayer != nil else {
            isPlaying = false
            return
        }

        let fadeDuration: TimeInterval = 0.35

        fadeTask?.cancel()
        playerStopTask?.cancel()

        // Fade file-based audio instead of abruptly stopping.
        if let player = audioPlayer {
            player.setVolume(0, fadeDuration: fadeDuration)
            let playerToStop = player
            playerStopTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(fadeDuration))
                guard !Task.isCancelled else { return }
                playerToStop.stop()
                playerStopTask = nil
            }
            audioPlayer = nil
        }

        let engine = state.engine
        let startingMelodyVolume = state.melodyVolume
        let startingBassVolume = state.bassVolume

        // Prevent new fanfare from being mixed during fade.
        state.fanfareActive = false
        isPlaying = false

        // Fade synthesized audio before stopping to avoid abrupt cutoff.
        // Runs off the main actor at utility QoS with cancellable Task.sleep
        // instead of parking a userInitiated GCD thread with Thread.sleep.
        if engine != nil {
            let state = state
            fadeTask = Task.detached(priority: .utility) {
                let steps = 20
                let stepNanos = UInt64((fadeDuration / Double(steps)) * 1_000_000_000)
                for i in 0..<steps {
                    try? await Task.sleep(nanoseconds: stepNanos)
                    guard !Task.isCancelled else { return }
                    let factor = Float(steps - i - 1) / Float(steps)
                    state.melodyVolume = startingMelodyVolume * factor
                    state.bassVolume = startingBassVolume * factor
                }
                guard !Task.isCancelled else { return }

                state.isRunning = false
                state.engine?.stop()

                // Reset for next play.
                state.melodyVolume = OnboardingAudioManager.defaultMelodyVolume
                state.bassVolume = OnboardingAudioManager.defaultBassVolume
            }
        } else {
            state.isRunning = false
            state.melodyVolume = OnboardingAudioManager.defaultMelodyVolume
            state.bassVolume = OnboardingAudioManager.defaultBassVolume
        }
    }

    deinit {
        state.isRunning = false
        state.fanfareActive = false
        state.engine?.stop()
        // audioPlayer will be cleaned up automatically
    }

    // MARK: - Engine Setup

    /// Engine setup is nonisolated so that AVAudioSourceNode render callbacks
    /// do NOT inherit @MainActor isolation.  Render callbacks run on the
    /// real-time audio IO thread; inheriting @MainActor causes a
    /// _dispatch_assert_queue_fail crash (EXC_BREAKPOINT / SIGTRAP).
    nonisolated private func setupAndStartEngine() {
        let engine = AVAudioEngine()
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = outputFormat.sampleRate
        let st = state

        // Reset sequencer state.
        st.melodyPhase = 0
        st.bassPhase = 0
        st.currentNoteIndex = 0
        st.sampleCounter = 0
        st.fanfareActive = false
        st.isRunning = true

        let noteSamples = Int(Self.noteDuration * sampleRate)
        let fanfareNoteSamples = Int(Self.fanfareNoteDuration * sampleRate)

        // ---- Melody source node ----
        let melodyNode = AVAudioSourceNode(format: outputFormat) {
            [st] (_, _, frameCount, bufferList) -> OSStatus in

            guard st.isRunning else {
                // Silence
                let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
                for buffer in ablPointer {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                return noErr
            }

            let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
            let patternLength = OnboardingAudioManager.melodyPattern.count
            let noteCount = OnboardingAudioManager.melodyNotes.count

            for frame in 0..<Int(frameCount) {
                // Determine current note frequency.
                let patIdx = st.currentNoteIndex % patternLength
                let noteIdx = OnboardingAudioManager.melodyPattern[patIdx] % noteCount
                let freq = OnboardingAudioManager.melodyNotes[noteIdx]

                // Sine oscillator.
                let increment = 2.0 * Double.pi * freq / sampleRate
                st.melodyPhase += increment
                if st.melodyPhase > 2.0 * Double.pi { st.melodyPhase -= 2.0 * Double.pi }
                var sample = sin(st.melodyPhase)

                // Envelope: smooth attack (first 5%) and release (last 10%)
                // of each note to eliminate clicks.
                let posInNote = st.sampleCounter
                let attackSamples = max(noteSamples / 20, 1)
                let releaseSamples = max(noteSamples / 10, 1)
                var envelope: Double = 1.0
                if posInNote < attackSamples {
                    envelope = Double(posInNote) / Double(attackSamples)
                } else if posInNote > noteSamples - releaseSamples {
                    let releasePos = posInNote - (noteSamples - releaseSamples)
                    envelope = 1.0 - Double(releasePos) / Double(releaseSamples)
                }
                // Use a cosine curve for smoother fades.
                envelope = 0.5 * (1.0 - cos(Double.pi * envelope))

                sample *= envelope * Double(st.melodyVolume)

                // ---- Fanfare overlay ----
                if st.fanfareActive {
                    let fNoteCount = OnboardingAudioManager.fanfareNotes.count
                    if st.fanfareNoteIndex < fNoteCount {
                        let fFreq = OnboardingAudioManager.fanfareNotes[st.fanfareNoteIndex]
                        let fInc = 2.0 * Double.pi * fFreq / sampleRate
                        st.fanfarePhase += fInc
                        if st.fanfarePhase > 2.0 * Double.pi { st.fanfarePhase -= 2.0 * Double.pi }
                        var fSample = sin(st.fanfarePhase)

                        // Envelope for fanfare note.
                        let fAttack = max(fanfareNoteSamples / 20, 1)
                        let fRelease = max(fanfareNoteSamples / 5, 1)
                        var fEnvelope: Double = 1.0
                        let fPos = st.fanfareEnvelopeSample
                        if fPos < fAttack {
                            fEnvelope = Double(fPos) / Double(fAttack)
                        } else if fPos > fanfareNoteSamples - fRelease {
                            let rp = fPos - (fanfareNoteSamples - fRelease)
                            fEnvelope = 1.0 - Double(rp) / Double(fRelease)
                        }
                        fEnvelope = 0.5 * (1.0 - cos(Double.pi * fEnvelope))

                        fSample *= fEnvelope * 0.45

                        sample += fSample

                        st.fanfareEnvelopeSample += 1
                        if st.fanfareEnvelopeSample >= fanfareNoteSamples {
                            st.fanfareEnvelopeSample = 0
                            st.fanfarePhase = 0
                            st.fanfareNoteIndex += 1
                            if st.fanfareNoteIndex >= fNoteCount {
                                st.fanfareActive = false
                            }
                        }
                    }
                }

                let floatSample = Float(sample)
                for buffer in ablPointer {
                    let buf = buffer.mData!.assumingMemoryBound(to: Float.self)
                    buf[frame] = floatSample
                }

                // Advance note sequencer.
                st.sampleCounter += 1
                if st.sampleCounter >= noteSamples {
                    st.sampleCounter = 0
                    st.melodyPhase = 0   // reset phase to avoid drift
                    st.currentNoteIndex += 1
                    if st.currentNoteIndex >= patternLength {
                        st.currentNoteIndex = 0
                    }
                }
            }

            return noErr
        }

        // ---- Bass drone source node ----
        let bassNode = AVAudioSourceNode(format: outputFormat) {
            [st] (_, _, frameCount, bufferList) -> OSStatus in

            guard st.isRunning else {
                let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
                for buffer in ablPointer {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                return noErr
            }

            let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
            let freq = OnboardingAudioManager.bassFrequency
            let increment = 2.0 * Double.pi * freq / sampleRate

            for frame in 0..<Int(frameCount) {
                st.bassPhase += increment
                if st.bassPhase > 2.0 * Double.pi { st.bassPhase -= 2.0 * Double.pi }
                let sample = Float(sin(st.bassPhase) * Double(st.bassVolume))

                for buffer in ablPointer {
                    let buf = buffer.mData!.assumingMemoryBound(to: Float.self)
                    buf[frame] = sample
                }
            }
            return noErr
        }

        // Wire up the graph: melody + bass -> mixer -> output.
        engine.attach(melodyNode)
        engine.attach(bassNode)

        let mixer = engine.mainMixerNode
        engine.connect(melodyNode, to: mixer, format: outputFormat)
        engine.connect(bassNode, to: mixer, format: outputFormat)

        // Keep overall output moderate.
        mixer.outputVolume = 1.0

        do {
            try engine.start()
        } catch {
            print("[OnboardingAudioManager] Failed to start AVAudioEngine: \(error)")
            st.isRunning = false
            st.engine = nil
            st.melodyNode = nil
            st.bassNode = nil
            return
        }

        st.engine = engine
        st.melodyNode = melodyNode
        st.bassNode = bassNode
    }
}
