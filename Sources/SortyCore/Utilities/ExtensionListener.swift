//
//  ExtensionListener.swift
//  Sorty
//
//  Listens for Finder extension notifications
//

import Foundation
import SwiftUI
import Combine

/// Bridges validated Finder handoffs to `MainWindowRouter`, which picks a
/// single target window. Broadcasting the selection from this app-wide object
/// would make every open window react to one Finder action.
@MainActor
public class ExtensionListener: ObservableObject {
    nonisolated(unsafe) private var notificationObserver: NSObjectProtocol?

    public init() {
        notificationObserver = ExtensionCommunication.setupNotificationObserver { @MainActor [weak self] url in
            // ExtensionCommunication validates the IPC payload off-main before
            // calling this handler.
            self?.route(url)
        }
    }

    private func route(_ directoryURL: URL) {
        MainWindowRouter.shared.routeFinderDirectory(directoryURL)
    }

    deinit {
        if let notificationObserver {
            ExtensionCommunication.removeNotificationObserver(notificationObserver)
        }
    }
}
