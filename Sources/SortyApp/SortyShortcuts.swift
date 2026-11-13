import AppIntents
import AppKit
import Foundation
#if canImport(SortyLib)
import SortyLib
#endif

enum SortyShortcutDestination: String, AppEnum {
    case organize
    case history
    case watchedFolders

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Sorty Destination")

    static let caseDisplayRepresentations: [SortyShortcutDestination: DisplayRepresentation] = [
        .organize: DisplayRepresentation(title: "Organize"),
        .history: DisplayRepresentation(title: "History"),
        .watchedFolders: DisplayRepresentation(title: "Watched Folders")
    ]

    var deeplink: DeeplinkDestination {
        switch self {
        case .organize:
            return .organize(path: nil, persona: nil, mode: nil, autostart: false)
        case .history:
            return .history()
        case .watchedFolders:
            return .watched(action: nil, path: nil)
        }
    }

    var dialog: IntentDialog {
        switch self {
        case .organize:
            return "Opening Sorty Organizer."
        case .history:
            return "Opening Sorty History."
        case .watchedFolders:
            return "Opening Watched Folders in Sorty."
        }
    }
}

struct OpenSortyDestinationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Sorty"
    static let description = IntentDescription("Open a specific Sorty workspace.")
    static let openAppWhenRun = true

    @Parameter(title: "Destination")
    var destination: SortyShortcutDestination

    init() {
        destination = .organize
    }

    init(destination: SortyShortcutDestination) {
        self.destination = destination
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$destination) in Sorty")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let url = DeeplinkHandler.url(for: destination.deeplink) else {
            return .result(dialog: "Sorty couldn't build that shortcut.")
        }

        NSWorkspace.shared.open(url)
        return .result(dialog: destination.dialog)
    }
}

struct OrganizeFolderInSortyIntent: AppIntent {
    static let title: LocalizedStringResource = "Organize Folder in Sorty"
    static let description = IntentDescription(
        "Open Sorty with a folder path ready to organize. Start analysis inside Sorty."
    )
    static let openAppWhenRun = true

    @Parameter(
        title: "Folder Path",
        requestValueDialog: IntentDialog("Which folder should Sorty organize?")
    )
    var folderPath: String

    @Parameter(title: "Legacy Autostart (Ignored)", default: false)
    var startImmediately: Bool

    init() {
        folderPath = ""
        startImmediately = true
    }

    init(folderPath: String, startImmediately: Bool = true) {
        self.folderPath = folderPath
        self.startImmediately = startImmediately
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Organize \(\.$folderPath) in Sorty")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmedPath = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return .result(dialog: "Provide a folder path to organize.")
        }

        let normalizedPath = URL(fileURLWithPath: trimmedPath).standardizedFileURL.path
        guard let url = DeeplinkHandler.url(
            for: .organize(path: normalizedPath, persona: nil, mode: nil, autostart: startImmediately)
        ) else {
            return .result(dialog: "Sorty couldn't build that folder shortcut.")
        }

        NSWorkspace.shared.open(url)
        return .result(
            dialog: "Opening Sorty with that folder ready to organize. Start analysis in Sorty."
        )
    }
}

struct SortyAppShortcutsProvider: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .teal

    static var appShortcuts: [AppShortcut] {
        let shortcuts = [
            AppShortcut(
                intent: OpenSortyDestinationIntent(destination: .organize),
                phrases: [
                    "Open \(.applicationName)",
                    "Open organize in \(.applicationName)"
                ],
                shortTitle: "Open Sorty",
                systemImageName: "sparkles"
            ),

            AppShortcut(
                intent: OpenSortyDestinationIntent(destination: .history),
                phrases: [
                    "Open \(.applicationName) history",
                    "Show history in \(.applicationName)"
                ],
                shortTitle: "History",
                systemImageName: "clock.arrow.circlepath"
            ),

            AppShortcut(
                intent: OrganizeFolderInSortyIntent(),
                phrases: [
                    "Organize a folder with \(.applicationName)",
                    "Run \(.applicationName) on a folder"
                ],
                shortTitle: "Organize Folder",
                systemImageName: "folder.badge.gearshape"
            )
        ]

        return shortcuts
    }
}
