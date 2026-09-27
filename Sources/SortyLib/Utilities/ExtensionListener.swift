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

    /// Drains the app-group handoff slot after first paint. Reads the shared
    /// defaults slot and validates the payload; call from
    /// `configureGlobalsIfNeeded` rather than init to keep scene creation free
    /// of IPC validation and filesystem checks.
    public func drainHandoffSlot() {
        Task { @MainActor [weak self] in
            guard let url = await ExtensionCommunication.receiveFromExtensionAsync() else { return }
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
