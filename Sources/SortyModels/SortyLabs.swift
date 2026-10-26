//
//  SortyLabs.swift
//  Sorty
//
//  Local opt-in switches for experimental features shown in Settings > Experimental.
//

import Foundation

/// Experimental features the user turns on locally. Each one is off until the
/// user enables it in Settings > Experimental, or with
/// `defaults write com.sorty.app <key> -bool true`.
///
/// Reads go straight to `UserDefaults`, so scanners and organizer phases can
/// check a feature from any isolation domain.
public enum SortyLabsFeature: String, CaseIterable, Identifiable, Sendable {
    case routingRules = "labs.routingRules"
    case downloadsInbox = "labs.downloadsInbox"
    case expiringFiles = "labs.expiringFiles"
    case projectDetection = "labs.projectDetection"

    public var id: String { rawValue }

    /// The `UserDefaults` key that stores whether the feature is on.
    public var defaultsKey: String { rawValue }

    public var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    public var title: String {
        switch self {
        case .routingRules: "Routing Rules"
        case .downloadsInbox: "Downloads Inbox"
        case .expiringFiles: "Expiring Files"
        case .projectDetection: "Project Detection"
        }
    }

    public var summary: String {
        switch self {
        case .routingRules:
            "Describe where files go, like \"bank statements go to Finance/Statements/{YYYY}\". Sorty turns it into a rule that runs without AI."
        case .downloadsInbox:
            "New downloads queue up in the menu bar with a suggested folder. Press Return to file the top one."
        case .expiringFiles:
            "Old installers, archives and screenshots in Downloads and on the Desktop are offered for the Trash after a set number of days. Nothing is removed without your review."
        case .projectDetection:
            "Leaves code projects intact and keeps related files, like a trip's photos and its booking PDFs, in one folder."
        }
    }

    public var systemImage: String {
        switch self {
        case .routingRules: "arrow.triangle.branch"
        case .downloadsInbox: "tray.and.arrow.down"
        case .expiringFiles: "hourglass"
        case .projectDetection: "square.stack.3d.up"
        }
    }
}
