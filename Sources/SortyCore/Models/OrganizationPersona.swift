//
//  OrganizationPersona.swift
//  Sorty
//
//  Custom organization presets that modify AI behavior
//

import Foundation
import Combine

public enum PersonaType: String, Codable, CaseIterable, Sendable {
    case general = "general"
    case developer = "developer"
    case photographer = "photographer"
    case office = "office"
    
    public var displayName: String {
        switch self {
        case .general: return "General"
        case .developer: return "Developer Mode"
        case .photographer: return "Photographer Mode"
        case .office: return "Office Mode"
        }
    }
    
    public var description: String {
        switch self {
        case .general:
            return "Organize by file type and context"
        case .developer:
            return "Tidy root clutter without breaking code"
        case .photographer:
            return "Sort photos by date, event, and camera"
        case .office:
            return "Organize work by client, project, and document type"
        }
    }
    
    public var icon: String {
        switch self {
        case .general: return "folder"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .photographer: return "camera"
        case .office: return "building.2"
        }
    }
    
    /// Additional prompt instructions for this persona
    public var promptModifier: String {
        switch self {
        case .general:
            return """
            ## General Organization Strategy:
            - **Primary grouping**: By file category (e.g., Documents, Images, Audio, Video, Archives)
            - **Sub-grouping**: By specific type or context (e.g., Documents/Invoices, Images/Screenshots)
            - **Date-based organization**: For time-sensitive files (e.g. photos, logs, receipts), group by Year/Month.
            - **Context clustering**: Group related files together (e.g. a project proposal and its assets).
            - **Clean up**: Move temporary files (installers, dmg, zip) to a specific 'Installers' or 'Archives' folder.
            
            Aim for a clean, intuitive structure that anybody could understand.
            """
            
        case .developer:
            return """
            
            ## Developer Mode Specialization — codebase-safe root hygiene:
            - **Assume a live codebase**: package.json, Cargo.toml, go.mod, *.xcodeproj, Package.swift, pom.xml, build.gradle, Gemfile, pyproject.toml, Makefile, CMakeLists.txt, .git/ mean imports/builds depend on current paths. This overrides the generic Project Detection rule — do NOT consolidate the repo into a new Projects/ folder.
            - **Root hygiene first**: only move loose files in the root that clearly don't belong there — screenshots, downloads, installers (.dmg/.pkg), stray zips, random PDFs/notes, exported logs/dumps, one-off scratch scripts. Leave everything else in place.
            - **Respect conventions**: reuse existing folders (docs/, scripts/, tools/, assets/) with their exact casing; keep moves shallow (depth ≤2); match the repo's naming style. Never re-group source by language/stack, never re-nest src/, lib/, Sources/, Tests/, and never move manifests, lockfiles, Makefiles, Dockerfiles, CI configs, dotfiles, or .git/.
            - **Never touch build output or deps**: node_modules/, vendor/, target/, build/, dist/, .venv/, Pods/, DerivedData/, .cache/. Never rename source or config files tied to imports/builds.
            - **Prefer leaving in place**: a clean repo with nothing stray is a valid near-no-op. Use `unorganized` (leave in place) over any risky move.
            - **Multi-project dumps only**: when the target is a downloads-style dump of unrelated projects (not one live repo), group per-project under Projects/[ProjectName]/, loose scripts under Scripts/[Language]/, shared docs under Documentation/, installers/zips under Archives/.
            """
            
        case .photographer:
            return """
            
            ## Photographer Mode Specialization:
            - **Primary grouping**: By date (Year/Month or Year/Event)
            - **Use EXIF data**: Extract camera model, date taken, GPS location
            - **Event detection**: Group photos taken on same day/location
            - **Camera organization**: Optionally sub-group by camera/device
            - **RAW vs Processed**: Separate RAW files from JPEGs
            - **Edited files**: Detect "_edit", "_final", "-2" suffixes
            
            Preferred folder structure:
            - Photos/[Year]/[Month] or Photos/[Year]/[Event]/
            - RAW/
            - Edited/
            - Screenshots/
            - Videos/
            
            Pay special attention to EXIF metadata if available.
            """
            
        case .office:
            return """
            
            ## Office Mode Specialization:
            - **Primary grouping**: By client or project name
            - **Document types**: Contracts, Invoices, Reports, Proposals, Correspondence
            - **Date-based subfolders**: Year/Quarter for time-sensitive documents
            - **Client detection**: Look for company names in filenames
            - **Version tracking**: Keep v1, v2, draft, final together
            
            Preferred folder structure:
            - Clients/[ClientName]/[Year]/
            - Projects/[ProjectName]/
            - Templates/
            - Archives/[Year]/
            - Finance/Invoices/, Finance/Receipts/
            - Legal/Contracts/
            
            Look for invoice numbers, client names, and project codes in filenames.
            """
        }
    }
}

/// Manager for persona settings
@MainActor
public class PersonaManager: ObservableObject {
    @Published public var selectedPersona: PersonaType = .general
    @Published public private(set) var selectedCustomPersonaId: String?
    
    @Published public var customPrompts: [PersonaType: String] = [:]
    
    private let userDefaults: UserDefaults
    private let persistedDataReader: UserDefaultsDataReader
    private let storageKey = "selectedPersona"
    private let customPromptsKey = "customPersonaPrompts"
    private let customIdKey = "selectedCustomPersonaId"
    @Published public private(set) var hasLoadedPersistedState = false
    private var loadTask: Task<PersistedSnapshot, Never>?
    private var loadGeneration = 0
    private var hasPendingChanges = false
    private var hasPendingScalarChanges = false

    private struct PersistedSnapshot: Sendable {
        var selectedPersonaRaw: String?
        var customPrompts: [PersonaType: String] = [:]
        var selectedCustomPersonaId: String?
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.persistedDataReader = UserDefaultsDataReader(userDefaults)
        setupNotificationObservers()
    }

    /// Reads small persona preferences off the main actor. Early selections win over persisted state.
    public func loadPersistedState() async {
        guard !hasLoadedPersistedState else { return }

        let generation = loadGeneration
        let task: Task<PersistedSnapshot, Never>
        if let loadTask {
            task = loadTask
        } else {
            let persistedDataReader = persistedDataReader
            let storageKey = storageKey
            let customPromptsKey = customPromptsKey
            let customIdKey = customIdKey
            task = Task.detached(priority: .userInitiated) {
                var snapshot = PersistedSnapshot()
                snapshot.selectedPersonaRaw = persistedDataReader.string(forKey: storageKey)
                snapshot.selectedCustomPersonaId = persistedDataReader.string(forKey: customIdKey)
                if let data = persistedDataReader.data(forKey: customPromptsKey),
                   let decoded = try? JSONDecoder().decode([PersonaType: String].self, from: data) {
                    snapshot.customPrompts = decoded
                }
                return snapshot
            }
            loadTask = task
        }

        let snapshot = await task.value
        guard !hasLoadedPersistedState, generation == loadGeneration else { return }

        if !hasPendingScalarChanges {
            if let rawValue = snapshot.selectedPersonaRaw,
               let persona = PersonaType(rawValue: rawValue) {
                selectedPersona = persona
            }
            if let id = snapshot.selectedCustomPersonaId {
                selectedCustomPersonaId = id
            }
        }
        var mergedPrompts = snapshot.customPrompts
        for (type, prompt) in customPrompts {
            mergedPrompts[type] = prompt
        }
        customPrompts = mergedPrompts

        hasLoadedPersistedState = true
        loadTask = nil

        if hasPendingChanges || hasPendingScalarChanges {
            hasPendingChanges = false
            hasPendingScalarChanges = false
            savePersona()
            saveCustomPrompts()
            saveCustomPersonaId()
        }
    }
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addMainActorObserver(forName: .clearAllUsageData, object: nil, queue: .main) { [weak self] in
            self?.reset()
        }
    }
    
    public func selectPersona(_ persona: PersonaType) {
        let personaChanged = selectedPersona != persona
        let customSelectionChanged = selectedCustomPersonaId != nil
        guard personaChanged || customSelectionChanged else { return }

        if personaChanged {
            selectedPersona = persona
            savePersona()
        }

        if customSelectionChanged {
            selectedCustomPersonaId = nil
            saveCustomPersonaId()
        }
    }
    
    public func selectCustomPersona(_ id: String) {
        guard selectedCustomPersonaId != id else { return }
        selectedCustomPersonaId = id
        saveCustomPersonaId()
    }
    
    public func getPrompt(for persona: PersonaType) -> String {
        if let custom = customPrompts[persona], !custom.isEmpty {
            return custom
        }
        return persona.promptModifier
    }

    /// Returns the effective prompt based on the current selection (custom or standard)
    public func getEffectivePrompt(customStore: CustomPersonaStore) -> String {
        if let customId = selectedCustomPersonaId,
           let custom = customStore.customPersonas.first(where: { $0.id == customId }) {
            return custom.promptModifier
        }
        return getPrompt(for: selectedPersona)
    }
    
    public func saveCustomPrompt(for persona: PersonaType, prompt: String) {
        if prompt.isEmpty || prompt == persona.promptModifier {
            customPrompts.removeValue(forKey: persona)
        } else {
            customPrompts[persona] = prompt
        }
        saveCustomPrompts()
    }
    
    public func resetCustomPrompt(for persona: PersonaType) {
        customPrompts.removeValue(forKey: persona)
        saveCustomPrompts()
    }

    public func reset() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        hasLoadedPersistedState = true
        hasPendingChanges = false
        hasPendingScalarChanges = false
        selectedPersona = .general
        selectedCustomPersonaId = nil
        customPrompts.removeAll()
        userDefaults.removeObject(forKey: storageKey)
        userDefaults.removeObject(forKey: customPromptsKey)
        userDefaults.removeObject(forKey: customIdKey)
    }

    private func savePersona() {
        guard hasLoadedPersistedState else {
            hasPendingChanges = true
            hasPendingScalarChanges = true
            return
        }
        userDefaults.set(selectedPersona.rawValue, forKey: storageKey)
    }

    private func saveCustomPrompts() {
        guard hasLoadedPersistedState else {
            hasPendingChanges = true
            return
        }
        if let encoded = try? JSONEncoder().encode(customPrompts) {
            userDefaults.set(encoded, forKey: customPromptsKey)
        }
    }

    private func saveCustomPersonaId() {
        guard hasLoadedPersistedState else {
            hasPendingChanges = true
            hasPendingScalarChanges = true
            return
        }
        if let id = selectedCustomPersonaId {
            userDefaults.set(id, forKey: customIdKey)
        } else {
            userDefaults.removeObject(forKey: customIdKey)
        }
    }
}
