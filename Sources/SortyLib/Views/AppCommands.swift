//
//  AppCommands.swift
//  Sorty
//
//  Comprehensive menu bar commands with keyboard shortcuts
//

import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

// MARK: - App Commands

public struct AppStateFocusedKey: FocusedValueKey {
    public typealias Value = AppState
}

public struct OrganizerFocusedKey: FocusedValueKey {
    public typealias Value = FolderOrganizer
}

public extension FocusedValues {
    var appState: AppState? {
        get { self[AppStateFocusedKey.self] }
        set { self[AppStateFocusedKey.self] = newValue }
    }

    var organizer: FolderOrganizer? {
        get { self[OrganizerFocusedKey.self] }
        set { self[OrganizerFocusedKey.self] = newValue }
    }
}

public struct SortyCommands: Commands {
    @FocusedValue(\.appState) private var appState

    private var sidebarItems: [SidebarNavigationItem] {
        SidebarNavigationItem.mainItems
    }

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Sorty", systemImage: "info.circle") {
                appState?.showAbout()
            }
            .disabled(appState == nil)
            
            Button("Check for Updates...", systemImage: "arrow.triangle.2.circlepath") {
                appState?.checkForUpdatesInteractive()
            }
            .disabled(appState == nil)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings...", systemImage: "gearshape") {
                appState?.openSettingsWindow()
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(appState == nil)
        }

        // Replace default New/Open with custom commands
        CommandGroup(replacing: .newItem) {
            Button("New Session", systemImage: "plus.square") {
                appState?.resetSession()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(appState == nil)

            Button("Open Directory...", systemImage: "folder") {
                appState?.requestDirectoryPicker()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(appState == nil)

            Divider()

            Button("Export Results...", systemImage: "square.and.arrow.up") {
                appState?.exportResults()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!(appState?.hasResults ?? false))
        }

        // Edit menu additions
        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Select All Files", systemImage: "checkmark.circle") {
                appState?.selectAllFiles()
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(!(appState?.hasFiles ?? false))
        }

        // View menu - use CommandGroup to add to existing View menu, not create a new one
        CommandGroup(replacing: .sidebar) {
            Button((appState?.showingSidebar ?? true) ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left") {
                appState?.showingSidebar.toggle()
            }
            .keyboardShortcut("\\", modifiers: .command)
            .disabled(appState == nil)
        }
        
        // Navigation commands added to View menu
        CommandGroup(after: .sidebar) {
            Divider()
            
            // Main Views section
            Text("Navigation")
                .font(.caption)

            ForEach(Array(sidebarItems.prefix(9).enumerated()), id: \.element.id) { index, item in
                Button(item.title, systemImage: item.systemImage) {
                    appState?.currentView = item.view
                }
                .keyboardShortcut(Self.commandKeyEquivalent(for: index), modifiers: .command)
                .disabled(appState == nil)
            }
        }

        // Organize menu
        organizationCommands
        // Learnings menu
        CommandMenu("Learnings") {
            Button("Open Dashboard", systemImage: "chart.bar") {
                appState?.currentView = .learnings
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(appState == nil)
            
            Divider()
            
            Button(
                (appState?.isLearningPaused ?? false) ? "Resume Learning" : "Pause Learning",
                systemImage: (appState?.isLearningPaused ?? false) ? "play.circle" : "pause.circle"
            ) {
                appState?.toggleLearning()
            }
            .disabled(appState == nil)
            
            Button("Export Learning Profile...", systemImage: "square.and.arrow.up") {
                appState?.exportLearningsProfile()
            }
            .disabled(appState == nil)
            
            Button("Import Learning Profile...", systemImage: "square.and.arrow.down") {
                appState?.importLearningsProfile()
            }
            .disabled(appState == nil)
        }

        // History menu
        historyCommands
        CommandGroup(replacing: .help) {
            Button("Sorty Help", systemImage: "questionmark.circle") {
                appState?.showHelp()
            }
            .keyboardShortcut("?", modifiers: .command)
            .disabled(appState == nil)

            Button("Restart Onboarding...", systemImage: "sparkles") {
                appState?.showOnboarding()
            }
            .disabled(appState == nil)

            Divider()

            Button("Report Bug", systemImage: "ladybug") {
                appState?.showBugReport()
            }
            .disabled(appState == nil)

            Link(destination: URL(string: "https://github.com/shirishpothi/Sorty")!) { Label("GitHub Repository", systemImage: "chevron.left.forwardslash.chevron.right") }

            if FeatureFlags.supportDeveloperEnabled {
                Link(destination: URL(string: "https://github.com/sponsors/shirishpothi")!) { Label("Support the Developer", systemImage: "heart") }
            }

            Button("Thank you for using Sorty", systemImage: "heart.fill") {
                appState?.showThanksForUsingSorty()
            }
            .keyboardShortcut("♥", modifiers: .command)
            .disabled(appState == nil)

            Divider()

            Button("Accreditations", systemImage: "rosette") {
                appState?.showAccreditations(entryPoint: .help)
            }
            .keyboardShortcut("©", modifiers: .command)
            .disabled(appState == nil)

            Button("Internet Access Policy", systemImage: "network") {
                appState?.showInternetAccessPolicy()
            }
            .keyboardShortcut("🌐", modifiers: .command)
            .disabled(appState == nil)

            Divider()

            Button("Uninstall Sorty...", systemImage: "trash") {
                appState?.requestUninstallConfirmation()
            }
            .disabled(appState == nil)
        }
    }

    private static func commandKeyEquivalent(for index: Int) -> KeyEquivalent {
        KeyEquivalent(Character("\(index + 1)"))
    }

    private var organizationCommands: some Commands {
        CommandMenu("Organize") {
            Button("Start Organization", systemImage: "play.circle") {
                appState?.startOrganization()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!(appState?.canStartOrganization ?? false))

            Button("Regenerate Organization", systemImage: "arrow.clockwise") {
                appState?.regenerateOrganization()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!(appState?.canRegenerateOrganization ?? false))

            Divider()

            Button("Apply Changes", systemImage: "checkmark.circle.fill") {
                appState?.applyChanges()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!(appState?.canApply ?? false))

            Button("Preview Changes", systemImage: "eye") {
                appState?.previewChanges()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!(appState?.hasCurrentPlan ?? false))

            Divider()

            Button("Cancel", systemImage: "xmark.circle") {
                appState?.cancelOperation()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(!(appState?.isOperationInProgress ?? false))
        }
    }

    private var historyCommands: some Commands {
        CommandMenu("History") {
            Button("Open History", systemImage: "clock") {
                appState?.currentView = .history
            }
            .disabled(appState == nil)

            Divider()

            Menu("Export History", systemImage: "square.and.arrow.up") {
                Button("As CSV") {
                    appState?.exportHistory(format: .csv)
                }

                Button("As JSON") {
                    appState?.exportHistory(format: .json)
                }
            }
            .disabled(appState == nil)

            Button("Import History", systemImage: "square.and.arrow.down") {
                appState?.importHistory()
            }
            .disabled(appState == nil)

            Divider()

            Button("Clear History", systemImage: "trash") {
                appState?.clearHistoryWithConfirmation()
            }
            .disabled(appState == nil)
        }
    }
}

