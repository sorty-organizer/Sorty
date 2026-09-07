import Foundation
import AppKit
import Combine

@MainActor
public final class WindowSession: ObservableObject {
    public let id: UUID
    public let history: OrganizationHistory
    @Published public var appState: AppState
    @Published public var organizer: FolderOrganizer

    private var didConfigure = false
    private var highlightDismissTask: Task<Void, Never>?

    public init(
        id: UUID = UUID(),
        updateManager: SparkleUpdateManager = SparkleUpdateManager(),
        history: OrganizationHistory = OrganizationHistory()
    ) {
        self.id = id
        self.history = history
        self.appState = AppState(windowSessionID: id, updateManager: updateManager)
        self.organizer = FolderOrganizer(history: history)
        self.organizer.windowSessionID = id
    }

    public func configureIfNeeded(
        settingsViewModel: SettingsViewModel,
        personaManager: PersonaManager,
        customPersonaStore: CustomPersonaStore,
        exclusionRules: ExclusionRulesManager,
        storageLocationsManager: StorageLocationsManager,
        learningsManager: LearningsManager,
        automationManager: AutomationManager,
        calibrateAction: ((WatchedFolder) -> Void)?,
        onReady: @MainActor () -> Void = {}
    ) async {
        guard !didConfigure else { return }
        didConfigure = true

        // The window session task starts as the view appears. Yield before
        // configuring AI clients and Sparkle so the first frame is not held
        // behind startup work.
        await Task.yield()
        guard !Task.isCancelled else {
            didConfigure = false
            return
        }

        let configurationStartedAt = Date()

        organizer.exclusionRules = exclusionRules
        organizer.personaManager = personaManager
        organizer.customPersonaStore = customPersonaStore
        organizer.storageLocationsManager = storageLocationsManager
        organizer.learningsManager = learningsManager
        organizer.automationManager = automationManager

        appState.organizer = organizer
        appState.calibrateAction = calibrateAction
        organizer.isManualSessionPersistenceEnabled = true

        await applyConfiguration(settingsViewModel.config, learningsManager: learningsManager)
        // A restart forced by macOS (e.g. enabling Full Disk Access) wipes
        // in-memory state; restore the manual folder and ready preview so the
        // user picks up where they left off.
        if let restoredDirectory = await organizer.restorePersistedManualSession(),
           appState.selectedDirectory == nil {
            appState.selectedDirectory = restoredDirectory
        }
        appState.updateManager.checkOnLaunchIfNeeded()
        onReady()
        AnalyticsManager.shared.captureWorkflow(
            workflow: "app_launch",
            stage: "window_ready",
            outcome: "completed",
            properties: AnalyticsManager.durationProperties(
                Date().timeIntervalSince(configurationStartedAt)
            )
        )
    }

    public func applyConfiguration(_ config: AIConfig, learningsManager: LearningsManager) async {
        try? await organizer.configure(with: config)
        learningsManager.configure(with: config)
    }

    public func handle(destination: DeeplinkDestination,
                settingsViewModel: SettingsViewModel,
                personaManager: PersonaManager,
                customPersonaStore: CustomPersonaStore,
                watchedFoldersManager: WatchedFoldersManager,
                exclusionRules: ExclusionRulesManager,
                storageLocationsManager: StorageLocationsManager,
                learningsManager: LearningsManager) {
        switch destination {
        case .organize(let path, let personaId, _, let autostart):
            if let path {
                appState.selectedDirectory = URL(fileURLWithPath: path)
            }
            if let personaId {
                if let persona = PersonaType(rawValue: personaId) {
                    personaManager.selectPersona(persona)
                } else {
                    personaManager.selectCustomPersona(personaId)
                }
            }
            // Reset organizer to idle so user sees ReadyToOrganize page
            if !autostart {
                appState.organizer?.reset()
            }
            appState.currentView = .organize
            if autostart {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if let directory = appState.selectedDirectory {
                        await appState.prepareForManualOrganization(at: directory)
                        try? await appState.organizer?.organize(directory: directory)
                    }
                }
            }

        case .duplicates(let path, _):
            if let path {
                appState.selectedDirectory = URL(fileURLWithPath: path)
            }
            appState.currentView = .duplicates

        case .learnings(let action, _):
            switch action {
            case .stats:
                appState.showLearningsStats()
            case .withdraw:
                appState.currentView = .learnings
                appState.pauseLearning()
            case .export:
                appState.exportLearningsProfile()
            case .importProfile:
                appState.importLearningsProfile()
            case .clear:
                appState.currentView = .learnings
                appState.requestDeleteUsageDataConfirmation()
            case .none:
                appState.currentView = .learnings
            }

        case .settings(let section):
            Task { @MainActor in
                // Avoid mutating @Published navigation state during the same render transaction.
                await Task.yield()
                applySettingsDestination(section: section)
                appState.openSettingsWindow(
                    section: appState.selectedSettingsSection,
                    focusTarget: appState.settingsFocusTarget
                )
            }

        case .help:
            appState.showHelp()

        case .open(let path):
            _ = MainWindowRouter.shared.activateWindow(for: id)
            if let path {
                var isDirectory = ObjCBool(false)
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    appState.selectedDirectory = URL(fileURLWithPath: path)
                }
            }

        case .history(let entryID):
            appState.pendingHistoryEntryID = entryID
            appState.currentView = .history

        case .persona(let action, let prompt, let generate):
            appState.openSettingsWindow(section: .strategy)
            if action == "create" || generate {
                if generate, let prompt {
                    Task<Void, Never> {
                        let generator = PersonaGenerator()
                        do {
                            let result = try await generator.generatePersona(from: prompt, config: settingsViewModel.config)
                            await MainActor.run {
                                let newPersona = CustomPersona(
                                    name: result.name,
                                    icon: result.icon,
                                    description: prompt,
                                    promptModifier: result.prompt,
                                    instructionSuggestions: result.suggestions
                                )
                                customPersonaStore.addPersona(newPersona)
                                personaManager.selectCustomPersona(newPersona.id)
                            }
                        } catch {
                            print("Failed to generate persona: \(error)")
                        }
                    }
                }
            }

        case .watched(let action, let path):
            appState.currentView = .watchedFolders
            if action == "add", let path {
                let folderURL = URL(fileURLWithPath: path).standardizedFileURL
                let normalizedPath = folderURL.path
                let watchedFolder: WatchedFolder

                if let existingFolder = watchedFoldersManager.folders.first(where: {
                    URL(fileURLWithPath: $0.path).standardizedFileURL.path == normalizedPath
                }) {
                    watchedFolder = existingFolder
                } else {
                    watchedFolder = WatchedFolder(
                        path: normalizedPath,
                        bookmarkData: securityScopedBookmark(for: folderURL)
                    )
                    watchedFoldersManager.addFolder(watchedFolder)
                }

                highlightWatchedFolder(watchedFolder.id)
            }

        case .rules(let action, _, let pattern),
             .exclusions(let action, let pattern):
            appState.currentView = .exclusions
            if action == "add", let pattern {
                let rule = ExclusionRule(type: .pathContains, pattern: pattern)
                exclusionRules.addRule(rule)
            }

        case .exclude(let path):
            appState.currentView = .exclusions
            if let path {
                let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
                let alreadyExcluded = exclusionRules.rules.contains {
                    $0.type == .pathContains
                        && $0.pattern.hasPrefix("/")
                        && URL(fileURLWithPath: $0.pattern).standardizedFileURL.path == normalizedPath
                }
                if !alreadyExcluded {
                    let folderName = URL(fileURLWithPath: normalizedPath).lastPathComponent
                    let rule = ExclusionRule(
                        type: .pathContains,
                        pattern: normalizedPath,
                        description: folderName.isEmpty ? "Protected folder" : folderName
                    )
                    exclusionRules.addRule(rule)
                }
            }

        case .storage(let action, let path):
            // Storage locations are managed inline on the Ready to Organize page.
            appState.currentView = .organize
            if action == "add", let path {
                let url = URL(fileURLWithPath: path)
                try? storageLocationsManager.addLocation(url: url)
            }
        }
    }

    private func securityScopedBookmark(for url: URL) -> Data? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func highlightWatchedFolder(_ folderID: UUID) {
        appState.highlightedWatchedFolderID = folderID
        highlightDismissTask?.cancel()
        highlightDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            if self.appState.highlightedWatchedFolderID == folderID {
                self.appState.highlightedWatchedFolderID = nil
            }
        }
    }

    private func applySettingsDestination(section: String?) {
        guard let section = section?.lowercased() else {
            appState.selectedSettingsSection = nil
            appState.settingsFocusTarget = nil
            return
        }

        switch section {
        case "finder", "finder-integration", "finder-services", "services", "quick-actions", "organize-with-sorty", "watch-with-sorty", "exclude-with-sorty", "exclude-from-sorty":
            appState.selectedSettingsSection = .finder
            appState.settingsFocusTarget = nil
        case "watched", "watched-folders", "folders", "exclusions", "rules":
            appState.selectedSettingsSection = .rules
            appState.settingsFocusTarget = nil
        case "storage", "storage-locations":
            appState.selectedSettingsSection = .rules
            appState.settingsFocusTarget = nil
        default:
            let category = SettingsCategory.allCases.first {
                $0.rawValue.lowercased().contains(section) ||
                    String(describing: $0).lowercased() == section
            }
            appState.selectedSettingsSection = category
            appState.settingsFocusTarget = nil
        }
    }
}
