import SwiftUI
import Combine
@preconcurrency import QuickLookThumbnailing
import UniformTypeIdentifiers

private struct FileThumbnailMetadata: Sendable {
    let exists: Bool
    let isDirectory: Bool
    let contentTypeIdentifier: String?
}

private actor FileThumbnailMetadataProbe {
    func metadata(for url: URL) -> FileThumbnailMetadata {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        )
        let contentTypeIdentifier = exists
            ? (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier)
            : nil

        return FileThumbnailMetadata(
            exists: exists,
            isDirectory: exists && isDirectory.boolValue,
            contentTypeIdentifier: contentTypeIdentifier
        )
    }
}

private struct SendableThumbnailImage: @unchecked Sendable {
    let image: NSImage
}

@MainActor
private struct PendingThumbnailRequest {
    var id: UUID
    let url: URL
    let size: CGSize
    var waiters: [UUID: CheckedContinuation<SendableThumbnailImage, Never>]
    var task: Task<Void, Never>?
    var isCancelling = false
}

/// Provides cached thumbnails for files using QuickLook and NSWorkspace
@MainActor
public class FileThumbnailProvider: ObservableObject {
    public static let shared = FileThumbnailProvider()

    private static let maximumConcurrentRequests = 4
    private let cache = NSCache<NSString, NSImage>()
    private var pendingRequests: [String: PendingThumbnailRequest] = [:]
    private var queuedKeys: [String] = []
    private var activeKeys: Set<String> = []
    private var cancelledWaiters: Set<UUID> = []
    private var liveWaiters: Set<UUID> = []
    private let waveformCache = NSCache<NSString, NSImage>()
    private let metadataProbe = FileThumbnailMetadataProbe()
    
    private init() {
        cache.countLimit = 180
        cache.totalCostLimit = 16 * 1024 * 1024
        waveformCache.countLimit = 60
        waveformCache.totalCostLimit = 6 * 1024 * 1024
    }
    
    /// Get a thumbnail for a file at the given URL
    public func thumbnail(for url: URL, size: CGSize = CGSize(width: 40, height: 40)) async -> NSImage {
        let key = cacheKey(for: url, size: size)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        let waiterID = UUID()
        liveWaiters.insert(waiterID)
        let sendableImage = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                      cancelledWaiters.remove(waiterID) == nil else {
                    liveWaiters.remove(waiterID)
                    continuation.resume(
                        returning: SendableThumbnailImage(image: fallbackIcon(for: url))
                    )
                    return
                }
                enqueue(
                    key: key,
                    url: url,
                    size: size,
                    waiterID: waiterID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor in
                FileThumbnailProvider.shared.cancelWaiter(waiterID, forKey: key)
            }
        }
        return sendableImage.image
    }

    private func enqueue(
        key: String,
        url: URL,
        size: CGSize,
        waiterID: UUID,
        continuation: CheckedContinuation<SendableThumbnailImage, Never>
    ) {
        if var request = pendingRequests[key] {
            request.waiters[waiterID] = continuation
            pendingRequests[key] = request
        } else {
            pendingRequests[key] = PendingThumbnailRequest(
                id: UUID(),
                url: url,
                size: size,
                waiters: [waiterID: continuation],
                task: nil
            )
            queuedKeys.append(key)
        }
        startQueuedRequestsIfPossible()
    }

    private func startQueuedRequestsIfPossible() {
        while activeKeys.count < Self.maximumConcurrentRequests,
              let key = queuedKeys.first {
            queuedKeys.removeFirst()
            guard var request = pendingRequests[key], !request.waiters.isEmpty else {
                pendingRequests.removeValue(forKey: key)
                continue
            }

            activeKeys.insert(key)
            let url = request.url
            let size = request.size
            let requestID = request.id
            request.task = Task { [weak self] in
                guard let self else { return }
                let image = await generateThumbnail(for: url, size: size)
                finishGeneration(image, forKey: key, requestID: requestID)
            }
            pendingRequests[key] = request
        }
    }

    private func finishGeneration(_ image: NSImage, forKey key: String, requestID: UUID) {
        guard var request = pendingRequests[key], request.id == requestID else { return }
        activeKeys.remove(key)
        if request.isCancelling {
            if request.waiters.isEmpty {
                pendingRequests.removeValue(forKey: key)
            } else {
                request.id = UUID()
                request.task = nil
                request.isCancelling = false
                pendingRequests[key] = request
                queuedKeys.append(key)
            }
        } else if let request = pendingRequests.removeValue(forKey: key), !request.waiters.isEmpty {
            cache.setObject(
                image,
                forKey: key as NSString,
                cost: image.thumbnailCost(scale: NSScreen.main?.backingScaleFactor ?? 2.0)
            )
            let sendableImage = SendableThumbnailImage(image: image)
            for continuation in request.waiters.values {
                continuation.resume(returning: sendableImage)
            }
            liveWaiters.subtract(request.waiters.keys)
        }
        startQueuedRequestsIfPossible()
    }

    private func cancelWaiter(_ waiterID: UUID, forKey key: String) {
        guard liveWaiters.remove(waiterID) != nil else { return }
        guard var request = pendingRequests[key] else {
            cancelledWaiters.insert(waiterID)
            return
        }
        guard let continuation = request.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(
            returning: SendableThumbnailImage(image: fallbackIcon(for: request.url))
        )

        if request.waiters.isEmpty {
            let wasActive = request.task != nil
            queuedKeys.removeAll { $0 == key }
            if wasActive {
                request.isCancelling = true
                request.task?.cancel()
                pendingRequests[key] = request
            } else {
                pendingRequests.removeValue(forKey: key)
            }
        } else {
            pendingRequests[key] = request
        }
    }
    
    private func generateThumbnail(for url: URL, size: CGSize) async -> NSImage {
        let metadata = await metadataProbe.metadata(for: url)
        guard !Task.isCancelled else { return fallbackIcon(for: url) }

        // Directories get the system's per-folder icon; QuickLook only yields a generic one
        if metadata.isDirectory {
            let icon = copiedIcon(NSWorkspace.shared.icon(forFile: url.path))
            icon.size = size
            return icon
        }

        // Handle audio files with custom waveform generator (only for larger sizes)
        if let identifier = metadata.contentTypeIdentifier,
           let type = UTType(identifier),
           type.conforms(to: .audio) {
            if size.width >= 32 && size.height >= 32 {
                let waveformKey = "\(url.path)|\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
                if let cachedWaveform = waveformCache.object(forKey: waveformKey as NSString) {
                    return cachedWaveform
                }
                if let waveform = await AudioWaveformGenerator.shared.generateWaveform(for: url, size: size) {
                    waveformCache.setObject(
                        waveform,
                        forKey: waveformKey as NSString,
                        cost: waveform.thumbnailCost(scale: NSScreen.main?.backingScaleFactor ?? 2.0)
                    )
                    return waveform
                }
            }
            let icon = copiedIcon(NSWorkspace.shared.icon(for: type))
            icon.size = size
            return icon
        }
        
        if !metadata.exists {
            return fallbackIcon(for: url)
        }
        
        // Try QuickLook first for rich thumbnails (images, PDFs, etc.)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        
        do {
            let thumbnail = try await withTaskCancellationHandler {
                try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            } onCancel: {
                QLThumbnailGenerator.shared.cancel(request)
            }
            return thumbnail.nsImage
        } catch {
            // Fall back to system icon from NSWorkspace, copying to avoid shared reference invalidation
            return copiedIcon(NSWorkspace.shared.icon(forFile: url.path))
        }
    }
    
    private func cacheKey(for url: URL, size: CGSize) -> String {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        return "\(url.path)|\(width)x\(height)"
    }
    
    private func fallbackIcon(for url: URL) -> NSImage {
        // Prioritize extension-based icon lookup before directory check
        // This ensures moved files still get proper icons
        // Copy icons to avoid shared reference invalidation during view recycling
        let ext = url.pathExtension
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
            return copiedIcon(NSWorkspace.shared.icon(for: utType))
        }
        if !ext.isEmpty {
            return copiedIcon(NSWorkspace.shared.icon(forFileType: ext))
        }
        if url.hasDirectoryPath {
            return copiedIcon(NSWorkspace.shared.icon(for: .folder))
        }
        return copiedIcon(NSWorkspace.shared.icon(for: .data))
    }

    /// Copies a shared workspace icon so cached thumbnails never mutate the
    /// shared instance. Falls back to the original instead of trapping on `as!`.
    private func copiedIcon(_ icon: NSImage) -> NSImage {
        (icon.copy() as? NSImage) ?? icon
    }
    
    /// Clear the thumbnail cache
    public func clearCache() {
        cache.removeAllObjects()
        waveformCache.removeAllObjects()

        let emptyImage = SendableThumbnailImage(image: NSImage(size: NSSize(width: 1, height: 1)))
        for request in pendingRequests.values {
            request.task?.cancel()
            for continuation in request.waiters.values {
                continuation.resume(returning: emptyImage)
            }
        }
        pendingRequests.removeAll()
        queuedKeys.removeAll()
        activeKeys.removeAll()
        cancelledWaiters.removeAll()
        liveWaiters.removeAll()
        startQueuedRequestsIfPossible()
    }
}

extension NSImage {
    func thumbnailCost(scale: CGFloat = 2) -> Int {
        let pixels = max(1, Int(size.width * scale * size.height * scale))
        return pixels * 4
    }
}
