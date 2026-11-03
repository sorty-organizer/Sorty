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
    case expiringFiles = "labs.expiringFiles"

    public var id: String { rawValue }

    /// The `UserDefaults` key that stores whether the feature is on.
    public var defaultsKey: String { rawValue }

    public var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    public var title: String {
        switch self {
        case .expiringFiles: "Expiring Files"
        }
    }

    public var summary: String {
        switch self {
        case .expiringFiles:
            "Old installers, archives and screenshots in Downloads and on the Desktop show up under Clean Up, in Watched Folders and the menu bar. Nothing is trashed without your review."
        }
    }

    public var systemImage: String {
        switch self {
        case .expiringFiles: "hourglass"
        }
    }
}
