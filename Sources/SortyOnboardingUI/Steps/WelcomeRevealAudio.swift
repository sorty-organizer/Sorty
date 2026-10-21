import AppKit
import AVFoundation
import Combine
import SwiftUI

// MARK: - Welcome Reveal Audio

/// Synthesizes a short swell/shimmer sound for the reveal animation
@MainActor
final class WelcomeRevealAudio: ObservableObject {
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
                    guard let data = buffer.mData else { continue }
                    memset(data, 0, Int(buffer.mDataByteSize))
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
                        guard let data = buffer.mData else { continue }
                        let buf = data.assumingMemoryBound(to: Float.self)
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
                    guard let data = buffer.mData else { continue }
                    let buf = data.assumingMemoryBound(to: Float.self)
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
