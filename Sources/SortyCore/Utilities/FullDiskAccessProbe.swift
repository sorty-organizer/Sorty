import Darwin
import Foundation

package enum FullDiskAccessProbe {
    nonisolated package static func isGranted(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        hasReadAccess(
            toAny: [
                homeDirectory.appendingPathComponent("Library/Safari/Bookmarks.plist").path,
                homeDirectory.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path,
            ]
        )
    }

    nonisolated package static func hasReadAccess(toAny paths: [String]) -> Bool {
        for path in paths {
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            if descriptor >= 0 {
                close(descriptor)
                return true
            }

            let openError = errno
            if openError == EPERM || openError == EACCES {
                return false
            }
            if openError != ENOENT {
                return false
            }
        }

        return false
    }
}
