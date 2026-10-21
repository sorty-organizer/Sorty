import SwiftUI
import UniformTypeIdentifiers
import Beam

// MARK: - Analysis Icon Provider

@MainActor
package enum AnalysisIconProvider {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 160
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    package static func icon(for contentType: UTType) -> NSImage {
        let key = "type:\(contentType.identifier)"
        if let image = cache.object(forKey: key as NSString) {
            return image
        }
        let image = copiedIcon(NSWorkspace.shared.icon(for: contentType))
        image.size = NSSize(width: 32, height: 32)
        cache.setObject(image, forKey: key as NSString, cost: imageCost(image))
        return image
    }

    package static func icon(forFileExtension fileExtension: String) -> NSImage {
        let normalizedExtension =
            fileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedExtension.isEmpty else {
            return icon(for: .data)
        }

        let key = "ext:\(normalizedExtension)"
        if let image = cache.object(forKey: key as NSString) {
            return image
        }
        let image = copiedIcon(NSWorkspace.shared.icon(forFileType: normalizedExtension))
        image.size = NSSize(width: 32, height: 32)
        cache.setObject(image, forKey: key as NSString, cost: imageCost(image))
        return image
    }

    /// Copies a shared workspace icon so view recycling never mutates the
    /// shared instance. Falls back to the original on copy failure instead
    /// of trapping on `as!`.
    private static func copiedIcon(_ icon: NSImage) -> NSImage {
        (icon.copy() as? NSImage) ?? icon
    }

    private static func imageCost(_ image: NSImage) -> Int {
        let pixels = max(1, Int(image.size.width * 2 * image.size.height * 2))
        return pixels * 4
    }
}
