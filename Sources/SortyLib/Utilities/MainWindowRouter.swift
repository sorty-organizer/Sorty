import SwiftUI
import AppKit

public enum WindowRoutingUserInfoKey {
    public static let targetSessionID = "targetSessionID"
    public static let deeplinkURLString = "deeplinkURLString"
}

public extension Notification.Name {
    static let routeDeeplinkInMainWindow = Notification.Name("SortyRouteDeeplinkInMainWindow")
    static let presentSteeringPromptsInMainWindow = Notification.Name("SortyPresentSteeringPromptsInMainWindow")
    static let openOrganizeDirectoryPickerInMainWindow = Notification.Name("SortyOpenOrganizeDirectoryPickerInMainWindow")
    static let showWatchedFolders = Notification.Name("SortyShowWatchedFolders")
}

public extension Notification {
    func targetsWindowSession(_ sessionID: UUID) -> Bool {
        guard let targetSessionID = userInfo?[WindowRoutingUserInfoKey.targetSessionID] as? String else {
            return true
        }

        return targetSessionID == sessionID.uuidString
    }

    var routedDeeplinkURL: URL? {
        guard let urlString = userInfo?[WindowRoutingUserInfoKey.deeplinkURLString] as? String else {
            return nil
        }

        return URL(string: urlString)
    }
}

@MainActor
public final class MainWindowRouter {
    public static let shared = MainWindowRouter()

    /// Keep all app-owned external events in an existing window. The router
    /// decides whether a Finder request needs its own request-scoped window.
    public static let existingWindowExternalEventMatchers: Set<String> = ["*"]

    private final class SessionRecord {
        weak var window: NSWindow?
        var lastFocusedAt: Date
        var isBusy: Bool
        var isReady: Bool

        init(
            window: NSWindow,
            lastFocusedAt: Date = Date(),
            isBusy: Bool = false,
            isReady: Bool = false
        ) {
            self.window = window
            self.lastFocusedAt = lastFocusedAt
            self.isBusy = isBusy
            self.isReady = isReady
        }
    }

    private struct PendingNotificationRoute {
        let name: Notification.Name
        let userInfo: [AnyHashable: Any]
        let targetSessionID: UUID?
    }

    private var sessions: [UUID: SessionRecord] = [:]
    private var pendingNotificationRoutes: [PendingNotificationRoute] = []

    private init() {}

    public static func scopedUserInfo(
        _ userInfo: [AnyHashable: Any] = [:],
        targetSessionID: UUID
    ) -> [AnyHashable: Any] {
        var scopedUserInfo = userInfo
        scopedUserInfo[WindowRoutingUserInfoKey.targetSessionID] = targetSessionID.uuidString
        return scopedUserInfo
    }

    public func register(window: NSWindow, for sessionID: UUID) {
        pruneClosedSessions()
        if let record = sessions[sessionID] {
            record.window = window
            if window.isKeyWindow || window.isMainWindow {
                record.lastFocusedAt = Date()
            }
            return
        }

        sessions[sessionID] = SessionRecord(window: window)
    }

    public func unregister(sessionID: UUID) {
        sessions.removeValue(forKey: sessionID)
    }

    public func markFocused(sessionID: UUID) {
        pruneClosedSessions()
        sessions[sessionID]?.lastFocusedAt = Date()
    }

    public func setBusy(_ isBusy: Bool, for sessionID: UUID) {
        pruneClosedSessions()
        sessions[sessionID]?.isBusy = isBusy
    }

    public func markReady(sessionID: UUID) {
        pruneClosedSessions()
        guard let session = sessions[sessionID] else { return }
        session.isReady = true
        deliverPendingNotificationRoutes(to: sessionID)
    }

    public var preferredSessionID: UUID? {
        pruneClosedSessions()

        return preferredSessionID(in: sessions)
    }

    public var preferredAvailableSessionID: UUID? {
        pruneClosedSessions()
        return preferredSessionID(in: sessions.filter { !$0.value.isBusy })
    }

    private var preferredReadySessionID: UUID? {
        pruneClosedSessions()
        return preferredSessionID(in: sessions.filter(\.value.isReady))
    }

    public var hasOpenSessions: Bool {
        pruneClosedSessions()
        return !sessions.isEmpty
    }

    public func hasSession(_ sessionID: UUID) -> Bool {
        pruneClosedSessions()
        return sessions[sessionID] != nil
    }

    private func preferredSessionID(in candidates: [UUID: SessionRecord]) -> UUID? {
        if let keyWindowID = candidates.first(where: { $0.value.window?.isKeyWindow == true })?.key {
            return keyWindowID
        }

        if let mainWindowID = candidates.first(where: { $0.value.window?.isMainWindow == true })?.key {
            return mainWindowID
        }

        if let visibleWindowID = (
            candidates
                .filter { $0.value.window?.isVisible == true }
                .max(by: { lhs, rhs in lhs.value.lastFocusedAt < rhs.value.lastFocusedAt })?
                .key
        ) {
            return visibleWindowID
        }

        // A minimized window is still an open, reusable Sorty window. Finder
        // actions should restore it instead of falling through to a new scene.
        return candidates
            .max(by: { lhs, rhs in lhs.value.lastFocusedAt < rhs.value.lastFocusedAt })?
            .key
    }

    @discardableResult
    public func post(name: Notification.Name, userInfo: [AnyHashable: Any] = [:]) -> Bool {
        guard let preferredSessionID else { return false }

        post(name: name, userInfo: userInfo, to: preferredSessionID)
        return true
    }

    @discardableResult
    public func postOrQueue(
        name: Notification.Name,
        userInfo: [AnyHashable: Any] = [:],
        targetSessionID: UUID? = nil
    ) -> Bool {
        let readySessionID = targetSessionID.flatMap { sessions[$0]?.isReady == true ? $0 : nil } ??
            (targetSessionID == nil ? preferredReadySessionID : nil)
        guard let readySessionID else {
            pendingNotificationRoutes.append(
                PendingNotificationRoute(
                    name: name,
                    userInfo: userInfo,
                    targetSessionID: targetSessionID
                )
            )
            return true
        }

        post(name: name, userInfo: userInfo, to: readySessionID)
        return false
    }

    @discardableResult
    public func routeDeeplink(_ url: URL) -> Bool {
        guard let preferredSessionID else { return false }

        return routeDeeplink(url, to: preferredSessionID)
    }

    @discardableResult
    public func routeFinderDeeplink(_ url: URL) -> Bool {
        pruneClosedSessions()

        let availableSessions = sessions.filter { !$0.value.isBusy }
        guard let targetSessionID = preferredSessionID(in: availableSessions) else { return false }
        return routeDeeplink(url, to: targetSessionID)
    }

    private func routeDeeplink(_ url: URL, to sessionID: UUID) -> Bool {

        NotificationCenter.default.post(
            name: .routeDeeplinkInMainWindow,
            object: nil,
            userInfo: Self.scopedUserInfo(
                [WindowRoutingUserInfoKey.deeplinkURLString: url.absoluteString],
                targetSessionID: sessionID
            )
        )

        activateWindow(for: sessionID)
        return true
    }

    private func deliverPendingNotificationRoutes(to sessionID: UUID) {
        let routes = pendingNotificationRoutes.filter {
            $0.targetSessionID == nil || $0.targetSessionID == sessionID
        }
        guard !routes.isEmpty else { return }
        pendingNotificationRoutes.removeAll {
            $0.targetSessionID == nil || $0.targetSessionID == sessionID
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for route in routes {
                self.post(name: route.name, userInfo: route.userInfo, to: sessionID)
            }
            _ = self.activateWindow(for: sessionID)
        }
    }

    private func post(
        name: Notification.Name,
        userInfo: [AnyHashable: Any],
        to sessionID: UUID
    ) {
        NotificationCenter.default.post(
            name: name,
            object: nil,
            userInfo: Self.scopedUserInfo(userInfo, targetSessionID: sessionID)
        )
    }

    @discardableResult
    public func activatePreferredWindow() -> Bool {
        guard let preferredSessionID else { return false }
        return activateWindow(for: preferredSessionID)
    }

    @discardableResult
    public func activateWindow(for sessionID: UUID) -> Bool {
        pruneClosedSessions()

        guard let window = sessions[sessionID]?.window else { return false }

        NSApplication.shared.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        markFocused(sessionID: sessionID)
        return true
    }

    private func pruneClosedSessions() {
        sessions = sessions.filter { _, record in
            guard let window = record.window else { return false }
            return window.isVisible || window.isMiniaturized || window.isKeyWindow || window.isMainWindow
        }
    }
}

public struct MainWindowSessionTracker: NSViewRepresentable {
    @SortyHotReload private var hotReload
    private let sessionID: UUID
    private let activateOnRegistration: Bool

    public init(sessionID: UUID, activateOnRegistration: Bool = false) {
        self.sessionID = sessionID
        self.activateOnRegistration = activateOnRegistration
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            Task { @MainActor in
                context.coordinator.observe(window: window)
            }
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            Task { @MainActor in
                context.coordinator.observe(window: window)
            }
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionID: sessionID,
            activateOnRegistration: activateOnRegistration
        )
    }

    public final class Coordinator: NSObject {
        private let sessionID: UUID
        private let activateOnRegistration: Bool
        private weak var observedWindow: NSWindow?
        private var observations: [NSObjectProtocol] = []

        init(sessionID: UUID, activateOnRegistration: Bool) {
            self.sessionID = sessionID
            self.activateOnRegistration = activateOnRegistration
        }

        @MainActor
        func observe(window: NSWindow) {
            guard observedWindow !== window else { return }

            removeObservations()
            observedWindow = window
            MainWindowRouter.shared.register(window: window, for: sessionID)
            if activateOnRegistration {
                _ = MainWindowRouter.shared.activateWindow(for: sessionID)
            }

            let notificationCenter = NotificationCenter.default
            let sessionID = sessionID

            observations.append(
                notificationCenter.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        MainWindowRouter.shared.markFocused(sessionID: sessionID)
                    }
                }
            )

            observations.append(
                notificationCenter.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        MainWindowRouter.shared.unregister(sessionID: sessionID)
                    }
                }
            )

            if window.isKeyWindow || window.isMainWindow {
                MainWindowRouter.shared.markFocused(sessionID: sessionID)
            }
        }

        private func removeObservations() {
            for observation in observations {
                NotificationCenter.default.removeObserver(observation)
            }
            observations.removeAll()
        }

        deinit {
            let observations = observations
            let sessionID = sessionID

            for observation in observations {
                NotificationCenter.default.removeObserver(observation)
            }

            Task { @MainActor in
                MainWindowRouter.shared.unregister(sessionID: sessionID)
            }
        }
    }
}

// MARK: - External window requests

public struct WindowLaunchRequest: Codable, Hashable, Identifiable {
    public let id: UUID
    public let deeplinkURLString: String?

    public init(id: UUID = UUID(), deeplinkURLString: String? = nil) {
        self.id = id
        self.deeplinkURLString = deeplinkURLString
    }

    public init(url: URL) {
        self.init(deeplinkURLString: url.absoluteString)
    }

    public var deeplinkURL: URL? {
        guard let deeplinkURLString, !deeplinkURLString.isEmpty else {
            return nil
        }
        return URL(string: deeplinkURLString)
    }
}

// MARK: - External URL deduplication

@MainActor
public enum ExternalDeeplinkDeduper {
    private static var lastSignature: String = ""
    private static var lastHandledAt: Date = .distantPast
    private static let dedupeWindow: TimeInterval = 0.8

    public static func shouldHandle(_ url: URL) -> Bool {
        let signature = url.absoluteString
        let now = Date()

        if signature == lastSignature, now.timeIntervalSince(lastHandledAt) < dedupeWindow {
            return false
        }

        lastSignature = signature
        lastHandledAt = now
        return true
    }
}
