import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A view that displays a file thumbnail with fallback and async loading
public struct FileThumbnailView: View {
    @SortyHotReload private var hotReload
    let url: URL
    let size: CGSize
    let utTypeHint: UTType?

    @State private var thumbnail: NSImage?
    @State private var isLoading = true

    public init(url: URL, size: CGSize = CGSize(width: 20, height: 20), utTypeHint: UTType? = nil) {
        self.url = url
        self.size = size
        self.utTypeHint = utTypeHint
    }

    /// Computed placeholder - avoids stale @State across LazyVStack view recycling
    private var placeholder: NSImage {
        Self.resolveIcon(for: url, utTypeHint: utTypeHint)
    }

    public var body: some View {
        AppKitImageView(
            image: thumbnail ?? placeholder,
            size: size,
            cornerRadius: 3,
            opacity: thumbnail == nil && isLoading ? 0.6 : 1
        )
        .frame(width: size.width, height: size.height)
        .task(id: "\(url.path)|\(Int(size.width.rounded()))x\(Int(size.height.rounded()))") {
            let currentURL = url
            isLoading = true
            let newThumbnail = await FileThumbnailProvider.shared.thumbnail(for: currentURL, size: size)
            if !Task.isCancelled, url == currentURL {
                thumbnail = newThumbnail
                isLoading = false
            }
        }
        .onChange(of: url) { _, _ in
            thumbnail = nil
            isLoading = true
        }
    }

    /// Cached fallback icon to avoid repeated NSWorkspace lookups
    private static let fallbackIcon: NSImage = {
        copiedIcon(NSWorkspace.shared.icon(for: .data))
    }()

    nonisolated(unsafe) private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 160
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    /// Resolve the system icon for a URL once, returning a copied image to avoid
    /// shared reference invalidation during view recycling
    private static func resolveIcon(for url: URL, utTypeHint: UTType?) -> NSImage {
        // Optimized: Avoid synchronous disk I/O in view body
        let ext = url.pathExtension

        if !ext.isEmpty {
            let key = "ext:\(ext.lowercased())" as NSString
            if let cached = iconCache.object(forKey: key) {
                return cached
            }

            if let utType = UTType(filenameExtension: ext) ??
                UTType(tag: ext, tagClass: .filenameExtension, conformingTo: nil) {
                let icon = copiedIcon(NSWorkspace.shared.icon(for: utType))
                iconCache.setObject(icon, forKey: key, cost: imageCost(icon))
                return icon
            }
        }

        if let hint = utTypeHint {
            let key = "hint:\(hint.identifier)" as NSString
            if let cached = iconCache.object(forKey: key) {
                return cached
            }

            let icon = copiedIcon(NSWorkspace.shared.icon(for: hint))
            iconCache.setObject(icon, forKey: key, cost: imageCost(icon))
            return icon
        }
        
        return fallbackIcon
    }

    private static func imageCost(_ image: NSImage) -> Int {
        let pixels = max(1, Int(image.size.width * 2 * image.size.height * 2))
        return pixels * 4
    }

    /// Copies a shared workspace icon so view recycling never mutates the
    /// shared instance. Falls back to the original instead of trapping on `as!`.
    private static func copiedIcon(_ icon: NSImage) -> NSImage {
        (icon.copy() as? NSImage) ?? icon
    }
}
