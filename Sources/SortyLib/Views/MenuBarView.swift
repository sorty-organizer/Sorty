//
//  MenuBarView.swift
//  Sorty
//
//  Menu bar extra view for persistent background presence
//

import AppKit
import SwiftUI

// MARK: - Menu Bar Mascot Icon

private struct MenuBarMascotIcon: View {
    @SortyHotReload private var hotReload
    var activity: MenuBarActivity = .idle
    var size: CGSize = CGSize(width: 18, height: 18)

    private var mascotImage: Image {
        if let image = SortyResources.image(named: activity.resourceName, withExtension: "png") {
            return Image(nsImage: image)
        }
        return Image(nsImage: SortyResources.menuBarLabelNSImage())
    }

    var body: some View {
        mascotImage
            .resizable()
            .scaledToFit()
            .frame(width: size.width, height: size.height)
            .accessibilityLabel(activity.accessibilityLabel)
    }
}

// MARK: - Launch at Login Icon

private struct LaunchAtLoginIcon: View {
    @SortyHotReload private var hotReload
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweepProgress: CGFloat = 1
    @State private var sweepTask: Task<Void, Never>?

    private let sweepDuration: TimeInterval = 1.25

    private var symbol: some View {
        Image(systemName: "sunrise.fill")
            .frame(width: 16)
    }

    private var sweepColors: [Color] {
        if isEnabled {
            return [
                .clear,
                .yellow.opacity(0.75),
                .orange,
                .yellow,
                .clear
            ]
        }

        return [
            .clear,
            .orange.opacity(0.8),
            .pink,
            .purple.opacity(0.9),
            .clear
        ]
    }

    var body: some View {
        symbol
            .foregroundStyle(.primary)
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(
                        colors: sweepColors,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 12)
                    .offset(
                        x: -12 + sweepProgress * (geometry.size.width + 24)
                    )
                    .blur(radius: 0.4)
                }
                .mask(symbol)
            }
            .onChange(of: isEnabled) { _, _ in
                runSweep()
            }
            .onDisappear {
                sweepTask?.cancel()
            }
    }

    private func runSweep() {
        guard !reduceMotion else { return }

        sweepTask?.cancel()
        sweepProgress = 0
        sweepTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: sweepDuration)) {
                sweepProgress = 1
            }
        }
    }
}

// MARK: - Menu Bar Label (Icon for menu bar)

public struct MenuBarLabel: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject private var controller: MenuBarController
    @State private var image = NSImage(
        systemSymbolName: "sparkles",
        accessibilityDescription: "Sorty"
    ) ?? NSImage()

    public init() {}

    public var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .accessibilityLabel(controller.activity.accessibilityLabel)
            .task(id: controller.activity) {
                let activity = controller.activity
                guard let loaded = await SortyResources.imageAsync(
                    named: activity.resourceName,
                    withExtension: "png"
                ) else { return }
                guard !Task.isCancelled, controller.activity == activity else { return }
                let resized = (loaded.copy() as? NSImage) ?? loaded
                resized.size = NSSize(width: 18, height: 18)
                resized.isTemplate = false
                image = resized
            }
    }
}

public struct MenuBarView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var watchedFoldersManager: WatchedFoldersManager
    @EnvironmentObject var loginItemManager: LoginItemManager
    @EnvironmentObject var notificationSettings: NotificationSettingsManager
    @EnvironmentObject var menuBarController: MenuBarController

    @AppStorage("keepInBackground") private var keepInBackground = false
    @AppStorage("hideDockIcon") private var hideDockIcon = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    // Derived from watched folders so "Pause All" never goes stale.
    private var isAllPaused: Bool {
        !watchedFoldersManager.folders.isEmpty
            && watchedFoldersManager.folders.allSatisfy { !$0.isEnabled }
    }

    public init() {}

    private var activeWatchedCount: Int {
        watchedFoldersManager.activeFolderCount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader

            Divider()

            quickActions

            if !watchedFoldersManager.folders.isEmpty {
                Divider()

                watchedFoldersList
            }

            Divider()

            backgroundToggle

            Divider()

            bottomActions
        }
        .padding(.vertical, 8)
        .frame(width: 280)
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        HStack(spacing: 8) {
            MenuBarMascotIcon(activity: menuBarController.activity, size: CGSize(width: 22, height: 20))

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityLabel(menuBarController.activity.accessibilityLabel)
                    .accessibilityIdentifier("MenuBarStatusTitle")

                if activeWatchedCount > 0 {
                    Text("\(activeWatchedCount) folder\(activeWatchedCount == 1 ? "" : "s") active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .numericTextTransition(animationValue: activeWatchedCount)
                } else {
                    Text("No watched folders active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if watchedFoldersManager.accessIssueFolderCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("\(watchedFoldersManager.accessIssueFolderCount) folder(s) need attention")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var headerTitle: String {
        // Visible short label; the full VoiceOver string stays in accessibilityLabel above.
        switch menuBarController.activity {
        case .idle: return "Sorty"
        case .greeting: return "Sorty"
        case .organizing: return "Organizing"
        case .renaming: return "Renaming"
        case .watchedFolder: return "Watching"
        case .duplicateScanning: return "Scanning"
        case .learning: return "Learning"
        }
    }

    // MARK: - Quick Actions

    private var quickActions: some View {
        VStack(spacing: 0) {
            MenuBarButton(title: "Open Sorty", icon: "macwindow") {
                openMainWindow()
            }

            MenuBarButton(title: "Organise Folder", icon: "folder.badge.plus") {
                openOrganizeFolderPicker()
            }

            MenuBarButton(title: "View History", icon: "clock") {
                openDestination(.history())
            }

            MenuBarButton(title: "Storage Locations", icon: "externaldrive.fill") {
                openDestination(.storage(action: nil, path: nil))
            }

        }
    }

    // MARK: - Watched Folders List

    private var watchedFoldersList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Watched Folders")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            MenuBarButton(
                title: isAllPaused ? "Resume All" : "Pause All",
                icon: isAllPaused ? "play.fill" : "pause.fill"
            ) {
                togglePauseAll()
            }

            ForEach(watchedFoldersManager.folders.prefix(5)) { folder in
                WatchedFolderMenuItem(folder: folder)
            }

            if watchedFoldersManager.folders.count > 5 {
                Text("+ \(watchedFoldersManager.folders.count - 5) more...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .numericTextTransition(animationValue: watchedFoldersManager.folders.count)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Background Toggle

    private var backgroundToggle: some View {
        VStack(spacing: 0) {
            Toggle(isOn: Binding(
                get: {
                    notificationSettings.settings.watchedFolderStartNotificationsEnabled ||
                    notificationSettings.settings.watchedFolderCompletionNotificationsEnabled
                },
                set: { newValue in
                    notificationSettings.settings.notifyOnAutoOrganize = newValue
                    notificationSettings.settings.watchedFolderStartNotificationsEnabled = newValue
                    notificationSettings.settings.watchedFolderCompletionNotificationsEnabled = newValue
                    HapticFeedbackManager.shared.tap()
                }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: "bell.badge.fill")
                        .frame(width: 16)
                    Text("Notifications")
                    Spacer()
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Toggle(isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    launchAtLogin = newValue
                    HapticFeedbackManager.shared.tap()
                }
            )) {
                HStack(spacing: 8) {
                    LaunchAtLoginIcon(isEnabled: launchAtLogin)
                    Text("Launch at Login")
                    Spacer()
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Toggle(isOn: Binding(
                get: { keepInBackground },
                set: { newValue in
                    keepInBackground = newValue
                    HapticFeedbackManager.shared.tap()
                }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: "moon.fill")
                        .frame(width: 16)
                    Text("Keep in Background")
                    Spacer()
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Toggle(isOn: Binding(
                get: { hideDockIcon },
                set: { newValue in
                    hideDockIcon = newValue
                    HapticFeedbackManager.shared.tap()
                }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: "dock.rectangle")
                        .frame(width: 16)
                    Text("Hide Dock Icon")
                    Spacer()
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            if keepInBackground || launchAtLogin || hideDockIcon {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Running as Background Activity")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    MenuBarButton(title: "System Settings...", icon: "gear.badge") {
                        loginItemManager.openLoginItemsSettings()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Bottom Actions

    private var bottomActions: some View {
        VStack(spacing: 0) {
            MenuBarButton(title: "Settings...", icon: "gear") {
                openSettings()
            }

            if FeatureFlags.supportDeveloperEnabled {
                MenuBarButton(title: "Support the Developer", icon: "heart.fill", hoverIconColor: .red, showsExternalArrow: true) {
                    openSupportDeveloper()
                }
            }

            Divider()

            if keepInBackground {
                MenuBarButton(title: "Close Window", icon: "xmark.rectangle") {
                    for window in NSApp.windows where window.canBecomeMain {
                        window.close()
                    }
                }

                MenuBarButton(title: "Quit Sorty", icon: "power") {
                    NSApplication.shared.terminate(nil)
                }
            } else {
                MenuBarButton(title: "Quit Sorty", icon: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    // MARK: - Actions

    private func openMainWindow() {
        openDestination(.open(path: nil))
    }

    private func openOrganizeFolderPicker() {
        if MainWindowRouter.shared.post(name: .openOrganizeDirectoryPickerInMainWindow) {
            MainWindowRouter.shared.activatePreferredWindow()
            return
        }

        openDestination(.organize(path: nil, persona: nil, mode: .organize, autostart: false))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if MainWindowRouter.shared.post(name: .openOrganizeDirectoryPickerInMainWindow) {
                MainWindowRouter.shared.activatePreferredWindow()
            }
        }
    }

    private func openSettings(section: String? = nil) {
        openDestination(.settings(section: section))
    }

    private func openSupportDeveloper() {
        guard let url = URL(string: "https://github.com/sponsors/shirishpothi") else { return }
        NSWorkspace.shared.open(url)
    }

    private func togglePauseAll() {
        // If everything is already paused, resume; otherwise pause all.
        let shouldPause = !isAllPaused
        HapticFeedbackManager.shared.tap()

        for folder in watchedFoldersManager.folders {
            var updated = folder
            updated.isEnabled = !shouldPause
            watchedFoldersManager.updateFolder(updated)
        }
    }

    private func openDestination(_ destination: DeeplinkDestination) {
        guard let url = DeeplinkHandler.url(for: destination) else { return }
        if MainWindowRouter.shared.routeDeeplink(url) {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Menu Bar Button

private struct MenuBarButton: View {
    @SortyHotReload private var hotReload
    let title: String
    var icon: String? = nil
    var customImage: Image? = nil
    var hoverIconColor: Color? = nil
    var showsExternalArrow = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            HapticFeedbackManager.shared.tap()
            action()
        } label: {
            HStack(spacing: 8) {
                if let customImage = customImage {
                    customImage
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                } else if let icon = icon {
                    Image(systemName: icon)
                        .frame(width: 16)
                        .foregroundStyle(isHovered ? (hoverIconColor ?? .primary) : .primary)
                }
                Text(LocalizedStringKey(title))
                Spacer()
                if showsExternalArrow {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .opacity(isHovered ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.1) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityIdentifier("MenuBarButton-\(title)")
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Watched Folder Menu Item

private struct WatchedFolderMenuItem: View {
    @SortyHotReload private var hotReload
    let folder: WatchedFolder
    @EnvironmentObject var watchedFoldersManager: WatchedFoldersManager

    @State private var isHovered = false

    private var statusIcon: String? {
        switch folder.accessStatus {
        case .valid:
            return folder.isEnabled ? "checkmark.circle.fill" : "pause.circle.fill"
        case .stale:
            return "exclamationmark.circle.fill"
        case .lost:
            return "xmark.circle.fill"
        case .unknown:
            return nil
        }
    }

    private var statusColor: Color {
        switch folder.accessStatus {
        case .valid:
            return folder.isEnabled ? .green : .orange
        case .stale:
            return .yellow
        case .lost:
            return .red
        case .unknown:
            return .gray
        }
    }

    private var folderIcon: NSImage {
        Self.cachedFolderIcon(for: folder.path)
    }

    /// Path-keyed icon cache so scrolling the menu never re-hits
    /// NSWorkspace inside the view body (mirrors FileThumbnailView).
    nonisolated(unsafe) private static let folderIconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    private static func cachedFolderIcon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = folderIconCache.object(forKey: key) {
            return cached
        }
        // Fetch at 32x32 for Retina crispness, display at 18x18
        let icon = (NSWorkspace.shared.icon(forFile: path).copy() as? NSImage)
            ?? NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        let pixels = max(1, Int(icon.size.width * 2 * icon.size.height * 2))
        folderIconCache.setObject(icon, forKey: key, cost: pixels * 4)
        return icon
    }

    var body: some View {
        Button {
            HapticFeedbackManager.shared.tap()
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
        } label: {
            HStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    AppKitImageView(image: folderIcon, size: CGSize(width: 18, height: 18))
                        .frame(width: 18, height: 18)

                    if let statusIcon {
                        Image(systemName: statusIcon)
                            .font(.system(size: 8))
                            .foregroundStyle(statusColor)
                            .symbolReplaceTransition(animationValue: statusIcon)
                            .background(
                                Circle()
                                    .fill(.background)
                                    .frame(width: 10, height: 10)
                            )
                            .offset(x: 3, y: 3)
                    }
                }
                .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.name)
                        .font(.callout)
                        .lineLimit(1)

                    PrivacySensitivePathText(path: folder.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.1) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(folder.name) in Finder")
        .accessibilityIdentifier("MenuBarWatchedFolder-\(folder.id.uuidString)")
        .contextMenu {
            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
            } label: {
                Label("Open in Finder", systemImage: "folder")
            }
            .accessibilityIdentifier("MenuBarFolderOpen-\(folder.id.uuidString)")

            Button {
                HapticFeedbackManager.shared.tap()
                var updated = folder
                updated.isEnabled.toggle()
                watchedFoldersManager.updateFolder(updated)
            } label: {
                Label(
                    folder.isEnabled ? "Pause Watching" : "Resume Watching",
                    systemImage: folder.isEnabled ? "pause.fill" : "play.fill"
                )
            }
            .accessibilityIdentifier("MenuBarFolderToggle-\(folder.id.uuidString)")

            Divider()

            Button(role: .destructive) {
                HapticFeedbackManager.shared.tap()
                watchedFoldersManager.removeFolder(folder)
            } label: {
                Label("Remove from Watch List", systemImage: "trash")
            }
            .accessibilityIdentifier("MenuBarFolderRemove-\(folder.id.uuidString)")
            .disabled(isAwaitingReview)
        }
    }

    private var isAwaitingReview: Bool {
        if case .awaitingReview = watchedFoldersManager.activityByFolder[folder.id] {
            return true
        }
        return false
    }
}

#Preview {
    MenuBarView()
        .environmentObject(WatchedFoldersManager())
        .environmentObject(MenuBarController())
}
