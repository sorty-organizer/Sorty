import Cocoa
import FinderSync
import OSLog

final class SortyFinderSync: FIFinderSync {
    private static let logger = Logger(subsystem: "com.sorty.app.SortyFinderSync", category: "FinderSync")
    private static let heartbeatNotificationName = Notification.Name("SortyFinderSyncHeartbeat")
    private static let directorySelectedNotificationName = Notification.Name("SortyDirectorySelected")
    private static let heartbeatMinimumInterval: TimeInterval = 30
    private static let heartbeatLock = NSLock()
    nonisolated(unsafe) private static var lastHeartbeatDate: Date?
    private static let iconStyleDefaults = UserDefaults(suiteName: "group.com.sorty.app") ?? .standard
    private static let iconStylePreferenceKey = "useWhiteMenuBarIcons"

    override init() {
        super.init()

        refreshMonitoredDirectories()

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(mountedVolumesDidChange(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(mountedVolumesDidChange(_:)),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )

        Self.reportHeartbeat(event: "launch")
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override var toolbarItemName: String {
        String(localized: "Sorty")
    }

    override var toolbarItemImage: NSImage {
        Self.finderActionImage(
            named: "SortyMenuOrganizing",
            appleNativeResourceName: "SortyMenuWhiteOrganizing",
            symbolName: "folder.fill.badge.gearshape",
            accessibilityDescription: "Organize with Sorty"
        )
    }

    override var toolbarItemToolTip: String {
        String(localized: "Organize with Sorty")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        Self.reportHeartbeat(event: Self.menuEventName(for: menuKind))
        let menu = NSMenu()
        let organizeImage = Self.finderActionImage(
            named: "SortyMenuOrganizing",
            appleNativeResourceName: "SortyMenuWhiteOrganizing",
            symbolName: "folder.fill.badge.gearshape",
            accessibilityDescription: "Organize with Sorty"
        )
        let watchImage = Self.finderActionImage(
            named: "SortyWatchMascot",
            symbolName: "eye",
            accessibilityDescription: "Watch with Sorty"
        )
        let excludeImage = Self.finderActionImage(
            named: "SortyExcludeMascot",
            symbolName: "folder.badge.minus",
            accessibilityDescription: "Exclude from Sorty"
        )

        switch menuKind {
        case .contextualMenuForItems, .contextualMenuForContainer, .contextualMenuForSidebar:
            let organizeItem = NSMenuItem(
                title: String(localized: "Organize with Sorty"),
                action: #selector(organizeAction(_:)),
                keyEquivalent: ""
            )
            organizeItem.image = organizeImage
            organizeItem.target = self
            menu.addItem(organizeItem)

            let watchItem = NSMenuItem(
                title: String(localized: "Watch with Sorty"),
                action: #selector(watchAction(_:)),
                keyEquivalent: ""
            )
            watchItem.image = watchImage
            watchItem.target = self
            menu.addItem(watchItem)

            let excludeItem = NSMenuItem(
                title: String(localized: "Exclude from Sorty"),
                action: #selector(excludeAction(_:)),
                keyEquivalent: ""
            )
            excludeItem.image = excludeImage
            excludeItem.target = self
            menu.addItem(excludeItem)
        case .toolbarItemMenu:
            let organizeItem = NSMenuItem(
                title: String(localized: "Organize Folder"),
                action: #selector(organizeAction(_:)),
                keyEquivalent: ""
            )
            organizeItem.image = organizeImage
            organizeItem.target = self
            menu.addItem(organizeItem)

            let watchItem = NSMenuItem(
                title: String(localized: "Watch Folder"),
                action: #selector(watchAction(_:)),
                keyEquivalent: ""
            )
            watchItem.image = watchImage
            watchItem.target = self
            menu.addItem(watchItem)
        @unknown default:
            return nil
        }

        return menu.items.isEmpty ? nil : menu
    }

    @objc private func organizeAction(_ sender: AnyObject?) {
        _ = sender

        guard let url = Self.selectedDirectoryURL() else { return }
        guard let organizeURL = Self.urlForOrganizing(path: url.path) else { return }

        Self.open(organizeURL, directoryURL: url, event: "action.organize")
    }

    @objc private func watchAction(_ sender: AnyObject?) {
        _ = sender

        guard let url = Self.selectedDirectoryURL() else { return }
        guard let watchURL = Self.urlForWatching(path: url.path) else { return }

        Self.open(watchURL, directoryURL: url, event: "action.watch")
    }

    @objc private func excludeAction(_ sender: AnyObject?) {
        _ = sender

        guard let url = Self.selectedDirectoryURL() else { return }
        guard let excludeURL = Self.urlForExcluding(path: url.path) else { return }

        Self.open(excludeURL, directoryURL: url, event: "action.exclude")
    }

    private static func selectedDirectoryURL() -> URL? {
        let selectedURLs = FIFinderSyncController.default().selectedItemURLs() ?? []
        let targetURL = FIFinderSyncController.default().targetedURL()

        if selectedURLs.count == 1,
           let selectedURL = selectedURLs.first,
           let directoryURL = normalizedDirectoryURL(for: selectedURL) {
            return directoryURL
        }

        // Finder can report several unrelated selections. The targeted container
        // is the only unambiguous folder in that case; using the first item can
        // silently organize a different directory than the menu the user opened.
        if let targetURL,
           let directoryURL = normalizedDirectoryURL(for: targetURL) {
            return directoryURL
        }

        let parentDirectories = Set(selectedURLs.compactMap { url -> URL? in
            guard url.isFileURL else { return nil }
            return url.deletingLastPathComponent().standardizedFileURL
        })
        return parentDirectories.count == 1 ? parentDirectories.first : nil
    }

    private static func normalizedDirectoryURL(for url: URL) -> URL? {
        guard url.isFileURL else { return nil }

        let standardizedURL = url.standardizedFileURL
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
           values.isDirectory == false {
            return standardizedURL.deletingLastPathComponent()
        }
        return standardizedURL
    }

    @objc private func mountedVolumesDidChange(_ notification: Notification) {
        _ = notification
        refreshMonitoredDirectories()
        Self.reportHeartbeat(event: "volumes.changed")
    }

    private func refreshMonitoredDirectories() {
        var directoryURLs = Set(
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: nil,
                options: .skipHiddenVolumes
            ) ?? []
        )
        directoryURLs.insert(FileManager.default.homeDirectoryForCurrentUser)
        let controller = FIFinderSyncController.default()
        guard controller.directoryURLs != directoryURLs else { return }
        controller.directoryURLs = directoryURLs
    }

    private static func open(_ actionURL: URL, directoryURL: URL, event: String) {
        reportHeartbeat(event: event)
        guard !NSWorkspace.shared.open(actionURL) else { return }

        // A stale Launch Services URL-scheme registration should not turn the
        // Finder command into a silent no-op when Sorty is already running.
        if event == "action.organize" {
            DistributedNotificationCenter.default().post(
                name: directorySelectedNotificationName,
                object: nil,
                userInfo: ["path": directoryURL.path]
            )
        } else if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.sorty.app") {
            NSWorkspace.shared.open(
                [actionURL],
                withApplicationAt: applicationURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                if let error {
                    logger.error("Could not deliver Sorty Finder action: \(error.localizedDescription)")
                }
            }
        }
        logger.error("Could not open Sorty action URL for path: \(directoryURL.path, privacy: .private)")
    }

    private static func urlForOrganizing(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "sorty"
        components.host = "organize"
        components.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "source", value: "finder")
        ]
        return components.url
    }

    private static func urlForWatching(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "sorty"
        components.host = "watched"
        components.queryItems = [
            URLQueryItem(name: "action", value: "add"),
            URLQueryItem(name: "path", value: path)
        ]
        return components.url
    }

    private static func urlForExcluding(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "sorty"
        components.host = "exclude"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    private static func finderActionImage(
        named sortyResourceName: String,
        appleNativeResourceName: String? = nil,
        symbolName: String,
        accessibilityDescription: String
    ) -> NSImage {
        let usesAppleNativeStyle = iconStyleDefaults.bool(forKey: iconStylePreferenceKey)
        if usesAppleNativeStyle,
           let appleNativeResourceName,
           let imageURL = Bundle.main.url(forResource: appleNativeResourceName, withExtension: "png"),
           let image = NSImage(contentsOf: imageURL) {
            image.isTemplate = true
            return normalizedMenuIcon(image)
        }

        if !usesAppleNativeStyle,
           let imageURL = Bundle.main.url(forResource: sortyResourceName, withExtension: "png"),
           let image = NSImage(contentsOf: imageURL) {
            image.isTemplate = false
            return normalizedMenuIcon(image)
        }

        let fallback = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        ) ?? NSImage(size: NSSize(width: 16, height: 16))
        fallback.isTemplate = true
        return normalizedMenuIcon(fallback)
    }

    private static func normalizedMenuIcon(_ image: NSImage) -> NSImage {
        let icon = (image.copy() as? NSImage) ?? image
        icon.size = NSSize(width: 16, height: 16)
        icon.isTemplate = image.isTemplate
        return icon
    }

    private static func reportHeartbeat(event: String) {
        let now = Date()
        heartbeatLock.lock()
        if event != "launch",
           let lastHeartbeatDate,
           now.timeIntervalSince(lastHeartbeatDate) < heartbeatMinimumInterval {
            heartbeatLock.unlock()
            return
        }
        lastHeartbeatDate = now
        heartbeatLock.unlock()

        let userInfo: [String: Any] = [
            "event": event,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "path": Bundle.main.bundleURL.path,
            "timestamp": now.timeIntervalSince1970
        ]

        DistributedNotificationCenter.default().post(
            name: heartbeatNotificationName,
            object: nil,
            userInfo: userInfo
        )
    }

    private static func menuEventName(for menuKind: FIMenuKind) -> String {
        switch menuKind {
        case .contextualMenuForItems:
            return "menu.items"
        case .contextualMenuForContainer:
            return "menu.container"
        case .contextualMenuForSidebar:
            return "menu.sidebar"
        case .toolbarItemMenu:
            return "menu.toolbar"
        @unknown default:
            return "menu.unknown"
        }
    }
}
