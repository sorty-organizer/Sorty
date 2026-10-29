import Foundation
import SortyFileSystem

struct BookmarkRestoreSnapshot: Sendable {
    let id: UUID
    let bookmarkData: Data?
    let path: String
}

struct BookmarkRestoreResult: Sendable {
    let id: UUID
    let originalBookmark: Data?
    let status: FolderAccessStatus
    let newBookmark: Data?
    let resolvedPath: String?
    let url: URL?
    let didAccess: Bool

    init(
        id: UUID, originalBookmark: Data?, status: FolderAccessStatus,
        newBookmark: Data? = nil, resolvedPath: String? = nil,
        url: URL? = nil, didAccess: Bool = false
    ) {
        self.id = id
        self.originalBookmark = originalBookmark
        self.status = status
        self.newBookmark = newBookmark
        self.resolvedPath = resolvedPath
        self.url = url
        self.didAccess = didAccess
    }
}

/// Resolves snapshots off-actor. Managers retain generation checks, persistence,
/// and ownership of every security scope returned with didAccess set.
enum BookmarkRestorer {
    enum Purpose {
        case storageLocation
        case watchedFolder
    }

    static func resolve(_ snapshots: [BookmarkRestoreSnapshot], purpose: Purpose) -> [BookmarkRestoreResult] {
        var results: [BookmarkRestoreResult] = []
        results.reserveCapacity(snapshots.count)
        // Watched folders snapshot sandbox state once, as their original loop did.
        let watchedRequiresAccess = purpose == .watchedFolder ? SandboxEnvironment.isSandboxed : nil

        for snapshot in snapshots {
            guard !Task.isCancelled else { break }
            guard let bookmarkData = snapshot.bookmarkData else {
                let exists = FileManager.default.fileExists(atPath: snapshot.path)
                results.append(BookmarkRestoreResult(
                    id: snapshot.id, originalBookmark: nil, status: exists ? .valid : .lost
                ))
                continue
            }

            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmarkData, options: .withSecurityScope,
                    relativeTo: nil, bookmarkDataIsStale: &isStale
                )
                switch purpose {
                case .watchedFolder:
                    if watchedRequiresAccess == false {
                        results.append(BookmarkRestoreResult(
                            id: snapshot.id, originalBookmark: bookmarkData, status: .valid,
                            newBookmark: renewedBookmark(for: url, isStale: isStale), resolvedPath: url.path
                        ))
                        continue
                    }
                    guard url.startAccessingSecurityScopedResource() else {
                        results.append(BookmarkRestoreResult(id: snapshot.id, originalBookmark: bookmarkData, status: .lost))
                        continue
                    }
                    results.append(BookmarkRestoreResult(
                        id: snapshot.id, originalBookmark: bookmarkData, status: isStale ? .stale : .valid,
                        newBookmark: renewedBookmark(for: url, isStale: isStale),
                        resolvedPath: url.path, url: url, didAccess: true
                    ))
                case .storageLocation:
                    // Storage renews before access, even when access later fails.
                    let newBookmark = renewedBookmark(for: url, isStale: isStale)
                    guard url.startAccessingSecurityScopedResource() else {
                        if SandboxEnvironment.isSandboxed {
                            results.append(BookmarkRestoreResult(id: snapshot.id, originalBookmark: bookmarkData, status: .lost))
                        } else {
                            results.append(BookmarkRestoreResult(
                                id: snapshot.id, originalBookmark: bookmarkData, status: .valid,
                                newBookmark: newBookmark, resolvedPath: StorageLocationPathResolver.canonicalPath(url.path)
                            ))
                        }
                        continue
                    }
                    results.append(BookmarkRestoreResult(
                        id: snapshot.id, originalBookmark: bookmarkData, status: .valid,
                        newBookmark: newBookmark, resolvedPath: StorageLocationPathResolver.canonicalPath(url.path),
                        url: url, didAccess: true
                    ))
                }
            } catch {
                results.append(BookmarkRestoreResult(id: snapshot.id, originalBookmark: bookmarkData, status: .lost))
            }
        }
        return results
    }

    private static func renewedBookmark(for url: URL, isStale: Bool) -> Data? {
        guard isStale else { return nil }
        return try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        )
    }
}
