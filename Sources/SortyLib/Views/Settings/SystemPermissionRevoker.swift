import AppKit
import SwiftUI
import UserNotifications
import Permiso

enum SystemPermissionRevoker {
    typealias Result = TCCPermissionResetter.Result

    static func revoke(
        _ type: PermissionType,
        bundleIdentifier: String
    ) async -> Result {
        let services: [String]
        switch type {
        case .filesAndFolders:
            services = [
                "SystemPolicyDesktopFolder",
                "SystemPolicyDocumentsFolder",
                "SystemPolicyDownloadsFolder",
                "SystemPolicyNetworkVolumes",
                "SystemPolicyRemovableVolumes"
            ]
        case .fullDiskAccess:
            return Result(
                succeeded: false,
                message: "macOS requires Full Disk Access to be removed in System Settings."
            )
        case .automation:
            services = ["AppleEvents"]
        case .notifications:
            return Result(
                succeeded: false,
                message: "macOS requires notification authorization to be changed in System Settings."
            )
        }

        return await TCCPermissionResetter.reset(
            services: services,
            bundleIdentifier: bundleIdentifier
        )
    }
}
