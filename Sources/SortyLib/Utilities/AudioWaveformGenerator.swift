import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AppKit

private actor AudioReaderLimiter {
    static let shared = AudioReaderLimiter(limit: 2)

    private var permits: Int
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var cancelledWaiters: Set<UUID> = []

    init(limit: Int) {
        permits = limit
    }

    func acquire() async throws {
        try Task.checkCancellation()
        guard permits == 0 else {
            permits -= 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if cancelledWaiters.remove(id) != nil || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        while !waiters.isEmpty {
            let (id, continuation) = waiters.removeFirst()
            if cancelledWaiters.remove(id) != nil {
                continuation.resume(throwing: CancellationError())
                continue
            }
            continuation.resume()
            return
        }
        permits += 1
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            let (_, continuation) = waiters.remove(at: index)
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledWaiters.insert(id)
        }
    }
}

private struct AudioFileVersion: Hashable, Sendable {
    let path: String
    let resourceIdentifier: String?
    let modificationTime: TimeInterval
    let fileSize: Int64

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: [
            .fileResourceIdentifierKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]) else { return nil }

        path = url.standardizedFileURL.path
        resourceIdentifier = values.fileResourceIdentifier.map { String(describing: $0) }
        modificationTime = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        fileSize = Int64(values.fileSize ?? 0)
    }
}

private actor AudioAmplitudeCache {
    private let countLimit = 120
    private var values: [AudioFileVersion: [Float]] = [:]
    private var accessOrder: [AudioFileVersion] = []
    private var inFlight: [AudioFileVersion: Task<[Float]?, Never>] = [:]

    func amplitudes(
        for version: AudioFileVersion,
        loader: @escaping @Sendable () async -> [Float]?
    ) async -> [Float]? {
        if let cached = values[version] {
            touch(version)
            return cached
        }
        if let task = inFlight[version] {
            return await task.value
        }

        let task = Task { await loader() }
        inFlight[version] = task
        let result = await task.value
        if inFlight.removeValue(forKey: version) != nil, let result {
            values[version] = result
            touch(version)
            trimIfNeeded()
        }
        return result
    }

    private func touch(_ version: AudioFileVersion) {
        accessOrder.removeAll { $0 == version }
        accessOrder.append(version)
    }

    private func trimIfNeeded() {
        while values.count > countLimit, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }
}

/// Generates a simple bar-style waveform image from an audio file
@MainActor
public final class AudioWaveformGenerator {
    public static let shared = AudioWaveformGenerator()

    private let amplitudeCache = AudioAmplitudeCache()

    private init() {}
    
    /// Generates a waveform image for the given audio file
    public func generateWaveform(for url: URL, size: CGSize) async -> NSImage? {
        guard let amplitudes = await loadAmplitudes(for: url) else { return nil }
        // drawWaveform is @MainActor, and we're already on MainActor
        return drawWaveform(amplitudes: amplitudes, size: size)
    }
    
    /// Loads audio amplitudes from the file - runs off main thread
    nonisolated
    private func loadAmplitudes(for url: URL) async -> [Float]? {
        let version = await Task.detached(priority: .utility) {
            AudioFileVersion(url: url)
        }.value
        guard let version else { return nil }

        return await amplitudeCache.amplitudes(for: version) {
            await Self.decodeAmplitudes(for: url)
        }
    }

    private nonisolated static func decodeAmplitudes(for url: URL) async -> [Float]? {
        do {
            try await AudioReaderLimiter.shared.acquire()
        } catch {
            return nil
        }

        let readTask = Task.detached(priority: .utility) {
            await Self.readAmplitudes(for: url)
        }
        let amplitudes = await withTaskCancellationHandler {
            await readTask.value
        } onCancel: {
            readTask.cancel()
        }
        await AudioReaderLimiter.shared.release()
        return amplitudes
    }

    private nonisolated static func readAmplitudes(for url: URL) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard !Task.isCancelled,
              let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        guard reader.startReading() else { return nil }

        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let formatDescription = try? await track.load(.formatDescriptions).first
        let audioDescription = formatDescription.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
        }
        let sampleRate = audioDescription?.mSampleRate ?? 44_100
        let channelCount = max(1, Int(audioDescription?.mChannelsPerFrame ?? 1))
        let totalFrames = max(1, Int(duration * sampleRate))
        let barCount = 10
        var maxima = [Int16](repeating: 0, count: barCount)
        var frameOffset = 0

        while !Task.isCancelled, let sampleBuffer = output.copyNextSampleBuffer() {
            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                let length = CMBlockBufferGetDataLength(blockBuffer)
                var samples = [Int16](repeating: 0, count: length / MemoryLayout<Int16>.size)
                guard CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: length,
                    destination: &samples
                ) == kCMBlockBufferNoErr else { continue }

                let frameCount = samples.count / channelCount
                for frame in 0..<frameCount {
                    let bucket = min(barCount - 1, (frameOffset + frame) * barCount / totalFrames)
                    for channel in 0..<channelCount {
                        let sample = samples[frame * channelCount + channel]
                        let magnitude = sample == .min ? Int16.max : abs(sample)
                        maxima[bucket] = max(maxima[bucket], magnitude)
                    }
                }
                frameOffset += frameCount
            }
        }

        if Task.isCancelled {
            reader.cancelReading()
            return nil
        }
        guard frameOffset > 0 else { return nil }
        return maxima.map { Float($0) / Float(Int16.max) }
    }
    
    @MainActor
    private func drawWaveform(amplitudes: [Float], size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        
        let barWidth = size.width / CGFloat(amplitudes.count)
        let spacing: CGFloat = 2.0
        
        NSColor.systemRed.set() // Use red for audio as per existing convention
        
        for (index, amplitude) in amplitudes.enumerated() {
            let height = max(size.height * CGFloat(amplitude), 2.0)
            let x = CGFloat(index) * barWidth + (spacing / 2)
            let y = (size.height - height) / 2
            
            let rect = NSRect(x: x, y: y, width: barWidth - spacing, height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
            path.fill()
        }
        
        image.unlockFocus()
        return image
    }
}
