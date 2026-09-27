import Foundation
import Darwin

/// Shared cloud placeholder check used by watched folders and reference scans.
package enum CloudPlaceholderDetector {
    private static let negativeCacheLock = NSLock()
    nonisolated(unsafe) private static var negativeCache: [String: Date] = [:]
    private static let negativeCacheTTL: TimeInterval = 60

    package static func shouldIgnore(
        at url: URL,
        resourceValues: URLResourceValues? = nil
    ) -> Bool {
        if resourceValues?.ubiquitousItemDownloadingStatus == .notDownloaded {
            return true
        }

        let fileName = url.lastPathComponent
        let pathExtension = url.pathExtension.lowercased()
        if (fileName.hasPrefix(".") && pathExtension == "icloud") || pathExtension == "cloud" {
            return true
        }

        guard resourceValues?.fileSize == 0 else { return false }
        if cachedNegative(for: url.path) { return false }
        let hasAttribute = getxattr(url.path, "com.dropbox.attrs", nil, 0, 0, 0) > 0
        if !hasAttribute { cacheNegative(for: url.path) }
        return hasAttribute
    }

    private static func cachedNegative(for path: String) -> Bool {
        negativeCacheLock.lock()
        defer { negativeCacheLock.unlock() }
        guard let expires = negativeCache[path] else { return false }
        if expires < Date() {
            negativeCache.removeValue(forKey: path)
            return false
        }
        return true
    }

    private static func cacheNegative(for path: String) {
        negativeCacheLock.lock()
        defer { negativeCacheLock.unlock() }
        if negativeCache.count > 4_096 {
            let cutoff = Date()
            negativeCache = negativeCache.filter { $0.value > cutoff }
        }
        negativeCache[path] = Date().addingTimeInterval(negativeCacheTTL)
    }
}
