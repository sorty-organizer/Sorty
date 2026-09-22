//
//  ExtensionListener.swift
//  Sorty
//
//  Listens for Finder extension notifications
//

import Foundation
import SwiftUI
import Combine

@MainActor
public class ExtensionListener: ObservableObject {
    @Published public var incomingURL: URL?
    nonisolated(unsafe) private var notificationObserver: NSObjectProtocol?

    public init() {
        notificationObserver = ExtensionCommunication.setupNotificationObserver { @MainActor [weak self] url in
            // ExtensionCommunication validates the IPC payload; keep only
            // validated directory URLs here.
            guard case .success = IncomingPathValidator.validatedDirectoryURL(for: url.path) else {
                return
            }
            self?.incomingURL = url
        }
    }

    /// Drains the app-group handoff slot after the first frame. The slot is
    /// read-take, so repeated calls are safe; only validated directories win.
    public func drainHandoffSlot() {
        if let existingURL = ExtensionCommunication.receiveFromExtension() {
            incomingURL = existingURL
        }
    }

    deinit {
        if let notificationObserver {
            ExtensionCommunication.removeNotificationObserver(notificationObserver)
        }
    }
}
