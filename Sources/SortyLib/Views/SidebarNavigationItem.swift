//
//  SidebarNavigationItem.swift
//  Sorty
//

import Foundation

struct SidebarNavigationItem: Identifiable, Hashable {
    let view: AppState.AppView
    let title: String
    let systemImage: String
    let accessibilityIdentifier: String
    let accessibilityHint: String
    let helpText: String

    var id: AppState.AppView { view }

    @MainActor
    static var mainItems: [SidebarNavigationItem] {
        items(includingInbox: SortyLabsFeature.expiringFiles.isEnabled)
    }

    /// Sidebar rows in order. Inbox sits under Organize while a Labs feature uses it.
    @MainActor
    static func items(includingInbox: Bool) -> [SidebarNavigationItem] {
        var items: [SidebarNavigationItem] = [
            SidebarNavigationItem(
                view: .organize,
                title: "Organize",
                systemImage: "folder.badge.gearshape",
                accessibilityIdentifier: "OrganizeSidebarItem",
                accessibilityHint: "Open the main organization workflow",
                helpText: "Organize files with Sorty suggestions"
            )
        ]

        if includingInbox {
            items.append(SidebarNavigationItem(
                view: .inbox,
                title: "Inbox",
                systemImage: "tray.and.arrow.down",
                accessibilityIdentifier: "InboxSidebarItem",
                accessibilityHint: "Review new downloads and old files waiting for the Trash",
                helpText: "File new downloads and clear out old ones"
            ))
        }

        items.append(contentsOf: [
            SidebarNavigationItem(
                view: .watchedFolders,
                title: "Watched Folders",
                systemImage: "eye",
                accessibilityIdentifier: "WatchedFoldersSidebarItem",
                accessibilityHint: "Configure folders monitored for automation",
                helpText: "Manage watched folders and triggers"
            ),
            SidebarNavigationItem(
                view: .duplicates,
                title: "Duplicates",
                systemImage: "doc.on.doc",
                accessibilityIdentifier: "DuplicatesSidebarItem",
                accessibilityHint: "Find and review duplicate files",
                helpText: "Detect and manage duplicate files"
            ),
            SidebarNavigationItem(
                view: .history,
                title: "History",
                systemImage: "clock",
                accessibilityIdentifier: "HistorySidebarItem",
                accessibilityHint: "Review past organization sessions",
                helpText: "View organization history and outcomes"
            ),
            SidebarNavigationItem(
                view: .learnings,
                title: "Learnings",
                systemImage: "brain",
                accessibilityIdentifier: "LearningsSidebarItem",
                accessibilityHint: "Review and manage learned preferences",
                helpText: "See what Sorty has learned from your edits"
            ),
            SidebarNavigationItem(
                view: .exclusions,
                title: "Exclusions",
                systemImage: "eye.slash",
                accessibilityIdentifier: "ExclusionsSidebarItem",
                accessibilityHint: "Define files and folders Sorty should skip",
                helpText: "Manage exclusion rules"
            ),
            SidebarNavigationItem(
                view: .settings,
                title: "Settings",
                systemImage: "gear",
                accessibilityIdentifier: "SettingsSidebarItem",
                accessibilityHint: "Configure Sorty behavior and AI providers",
                helpText: "Adjust provider, strategy, automation, and system settings"
            )
        ])

        return items
    }
}
