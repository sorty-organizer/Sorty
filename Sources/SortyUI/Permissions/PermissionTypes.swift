import AppKit
import AVFoundation
import SwiftUI
import UserNotifications
import Permiso
import SortyCore

package enum PermissionType: String, CaseIterable, Identifiable, Sendable {
    case filesAndFolders = "Files & Folders"
    case fullDiskAccess = "Full Disk Access"
    case automation = "Automation"
    case notifications = "Notifications"

    package var id: String { rawValue }

    var icon: String {
        switch self {
        case .filesAndFolders: return "folder.fill"
        case .fullDiskAccess: return "lock.open.fill"
        case .automation: return "gearshape.2.fill"
        case .notifications: return "bell.fill"
        }
    }

    var description: String {
        switch self {
        case .filesAndFolders: return "Choose a folder so Sorty can organize files"
        case .fullDiskAccess: return "Optional for protected folders; may relaunch Sorty"
        case .automation: return "Read Finder selections for Finder Integration"
        case .notifications: return "Get notified when organization completes"
        }
    }

    package func description(for state: PermissionState) -> String {
        if self == .fullDiskAccess, state == .restartRequired {
            return "Full Disk Access is on. Restart Sorty to use it."
        }

        return description
    }

    package var color: Color {
        switch self {
        case .filesAndFolders: return .blue
        case .fullDiskAccess: return .green
        case .automation: return .orange
        case .notifications: return .purple
        }
    }

    var educationTitle: String {
        switch self {
        case .filesAndFolders:
            return "Files & Folders"
        case .fullDiskAccess:
            return "Full Disk Access"
        case .automation:
            return "Finder Automation"
        case .notifications:
            return "Notifications"
        }
    }

    var educationDescription: String {
        switch self {
        case .filesAndFolders:
            return "Lets Sorty access folders you explicitly choose with the macOS picker. This is required before Sorty can scan and organize files."
        case .fullDiskAccess:
            return "Lets Sorty organize protected folders you explicitly choose, such as Desktop, Documents, Downloads, or external locations macOS protects. macOS may relaunch Sorty after this is enabled, so it is usually better to finish onboarding first."
        case .automation:
            return "Lets Sorty read the current Finder selection for Finder Integration actions. Sorty only asks when you use Finder-driven workflows."
        case .notifications:
            return "Lets Sorty send completion and error alerts through macOS Notification Center. In-app HUD alerts still work without it."
        }
    }

    var educationActionTitle: String {
        switch self {
        case .filesAndFolders:
            return "Choose Folder"
        case .fullDiskAccess:
            return "Review Restart Note"
        case .automation:
            return "Enable Finder Automation"
        case .notifications:
            return "Enable Notifications"
        }
    }

    package var compactActionTitle: String {
        switch self {
        case .filesAndFolders:
            return "Choose Folder"
        case .fullDiskAccess:
            return "Review"
        case .automation:
            return "Enable"
        case .notifications:
            return "Enable"
        }
    }
}

package enum PermissionState: Sendable, Equatable {
    case unknown
    case pending
    case granted
    case restartRequired
    case denied

    package init(automationStatus: PermissionStatus) {
        switch automationStatus {
        case .granted: self = .granted
        case .denied: self = .denied
        case .unknown: self = .unknown
        }
    }

    package init(notificationStatus: UNAuthorizationStatus) {
        switch notificationStatus {
        case .authorized, .provisional: self = .granted
        case .denied: self = .denied
        case .notDetermined: self = .unknown
        @unknown default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .unknown: return "Not granted"
        case .pending: return "Check Settings"
        case .granted: return "Granted"
        case .restartRequired: return "Restart Sorty"
        case .denied: return "Needs Attention"
        }
    }

    package func title(for type: PermissionType) -> String {
        guard self == .pending else { return title }

        switch type {
        case .filesAndFolders:
            return "Choosing Folder"
        case .fullDiskAccess:
            return "Finish in Settings"
        case .automation:
            return "Requesting"
        case .notifications:
            return "Enabling"
        }
    }

    package var symbol: String {
        switch self {
        case .unknown: return "circle"
        case .pending: return "arrow.clockwise"
        case .granted: return "checkmark"
        case .restartRequired: return "arrow.clockwise"
        case .denied: return "exclamationmark"
        }
    }

    package var tint: Color {
        switch self {
        case .unknown: return .secondary
        case .pending: return .orange
        case .granted: return .green
        case .restartRequired: return .blue
        case .denied: return .red
        }
    }
}
