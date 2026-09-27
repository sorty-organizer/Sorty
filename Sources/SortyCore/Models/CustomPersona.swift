//
//  CustomPersona.swift
//  Sorty
//
//  Model and manager for user-created custom personas
//

import Foundation
import Combine

// MARK: - Custom Persona Model

public struct PersonaInstructionSuggestions: Codable, Hashable, Sendable {
    public var organize: [String]
    public var organizeAndRename: [String]
    public var renameOnly: [String]

    public init(
        organize: [String] = [],
        organizeAndRename: [String] = [],
        renameOnly: [String] = []
    ) {
        self.organize = organize
        self.organizeAndRename = organizeAndRename
        self.renameOnly = renameOnly
    }

    public func suggestions(for mode: OrganizationMode) -> [String] {
        let suggestions: [String]
        switch mode {
        case .organize:
            suggestions = organize
        case .organizeAndRename:
            suggestions = organizeAndRename
        case .renameOnly:
            suggestions = renameOnly
        }

        return suggestions.filter(Self.isReadyToUse)
    }

    private static func isReadyToUse(_ suggestion: String) -> Bool {
        suggestion.range(
            of: #"\[[^\[\]\n]+\]|\{[^{}\n]+\}|<[^<>\n]+>"#,
            options: .regularExpression
        ) == nil
    }
}

/// A user-created organization persona
public struct CustomPersona: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var icon: String
    public var description: String
    public var promptModifier: String
    public var instructionSuggestions: PersonaInstructionSuggestions
    public let createdAt: Date
    public var modifiedAt: Date
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        icon: String = "star.fill",
        description: String = "",
        promptModifier: String = "",
        instructionSuggestions: PersonaInstructionSuggestions = PersonaInstructionSuggestions()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.description = description
        self.promptModifier = promptModifier
        self.instructionSuggestions = instructionSuggestions
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
    
    public mutating func update(
        name: String,
        icon: String,
        description: String,
        prompt: String,
        instructionSuggestions: PersonaInstructionSuggestions? = nil
    ) {
        self.name = name
        self.icon = icon
        self.description = description
        self.promptModifier = prompt
        if let instructionSuggestions {
            self.instructionSuggestions = instructionSuggestions
        }
        self.modifiedAt = Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case icon
        case description
        case promptModifier
        case instructionSuggestions
        case createdAt
        case modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        description = try container.decode(String.self, forKey: .description)
        promptModifier = try container.decode(String.self, forKey: .promptModifier)
        instructionSuggestions = try container.decodeIfPresent(
            PersonaInstructionSuggestions.self,
            forKey: .instructionSuggestions
        ) ?? PersonaInstructionSuggestions()
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
    }
}

// MARK: - Custom Persona Store

/// Manager for persisting custom personas
@MainActor
public class CustomPersonaStore: ObservableObject {
    @Published public var customPersonas: [CustomPersona] = []
    @Published public private(set) var hasLoadedPersistedState = false

    private let userDefaults: UserDefaults
    private let persistedDataReader: UserDefaultsDataReader
    private let storageKey = "customPersonas"
    nonisolated(unsafe) private var clearUsageObserver: NSObjectProtocol?
    private var loadTask: Task<[CustomPersona], Never>?
    private var loadGeneration = 0
    private var hasPendingChanges = false

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.persistedDataReader = UserDefaultsDataReader(userDefaults)
        setupNotificationObservers()
    }

    /// Decodes personas away from the main actor. In-memory additions are merged before saving.
    public func loadPersistedState() async {
        guard !hasLoadedPersistedState else { return }

        let generation = loadGeneration
        let task: Task<[CustomPersona], Never>
        if let loadTask {
            task = loadTask
        } else {
            let persistedDataReader = persistedDataReader
            let storageKey = storageKey
            task = Task.detached(priority: .userInitiated) {
                guard let data = persistedDataReader.data(forKey: storageKey),
                      let decoded = try? JSONDecoder().decode([CustomPersona].self, from: data) else {
                    return []
                }
                return decoded
            }
            loadTask = task
        }

        let persistedPersonas = await task.value
        guard !hasLoadedPersistedState, generation == loadGeneration else { return }

        let inMemoryByID = Dictionary(uniqueKeysWithValues: customPersonas.map { ($0.id, $0) })
        let persistedIDs = Set(persistedPersonas.map(\.id))
        var merged = persistedPersonas.map { inMemoryByID[$0.id] ?? $0 }
        merged.append(contentsOf: customPersonas.filter { !persistedIDs.contains($0.id) })
        customPersonas = merged

        hasLoadedPersistedState = true
        loadTask = nil

        if hasPendingChanges {
            hasPendingChanges = false
            savePersonas()
        }
    }
    private func setupNotificationObservers() {
        clearUsageObserver = NotificationCenter.default.addMainActorObserver(forName: .clearAllUsageData, object: nil, queue: .main) { [weak self] in
            self?.clearAll()
        }
    }

    deinit {
        if let clearUsageObserver {
            NotificationCenter.default.removeObserver(clearUsageObserver)
        }
    }
    
    public func addPersona(_ persona: CustomPersona) {
        customPersonas.append(persona)
        savePersonas()
    }

    public func clearAll() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        hasLoadedPersistedState = true
        hasPendingChanges = false
        customPersonas.removeAll()
        userDefaults.removeObject(forKey: storageKey)
    }
    
    public func updatePersona(_ persona: CustomPersona) {
        if let index = customPersonas.firstIndex(where: { $0.id == persona.id }) {
            customPersonas[index] = persona
            savePersonas()
        }
    }
    
    public func deletePersona(id: String) {
        customPersonas.removeAll { $0.id == id }
        savePersonas()
    }

    public func selectionAfterDeletingPersona(id: String) -> String? {
        guard let index = customPersonas.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        if index > customPersonas.startIndex {
            return customPersonas[customPersonas.index(before: index)].id
        }

        let nextIndex = customPersonas.index(after: index)
        return nextIndex < customPersonas.endIndex ? customPersonas[nextIndex].id : nil
    }
    
    public func persona(named name: String) -> CustomPersona? {
        customPersonas.first { $0.name.lowercased() == name.lowercased() }
    }
    
    private func savePersonas() {
        guard hasLoadedPersistedState else {
            hasPendingChanges = true
            return
        }
        if let encoded = try? JSONEncoder().encode(customPersonas) {
            userDefaults.set(encoded, forKey: storageKey)
        }
    }
}

// MARK: - Available Icons

public let personaIconOptions: [String] = [
    "star.fill",
    "sparkles",
    "wand.and.stars",
    "leaf.fill",
    "leaf.arrow.circlepath",
    "paintbrush.fill",
    "pencil",
    "scissors",
    "music.note",
    "microphone.fill",
    "headphones",
    "waveform",
    "film.fill",
    "camera.fill",
    "photo.on.rectangle.angled",
    "gamecontroller.fill",
    "book.fill",
    "books.vertical.fill",
    "newspaper.fill",
    "doc.text.fill",
    "briefcase.fill",
    "building.2.fill",
    "storefront.fill",
    "banknote.fill",
    "chart.bar.fill",
    "house.fill",
    "graduationcap.fill",
    "heart.fill",
    "cross.case.fill",
    "stethoscope",
    "cart.fill",
    "fork.knife",
    "airplane",
    "car.fill",
    "hammer.fill",
    "wrench.and.screwdriver.fill",
    "terminal.fill",
    "curlybraces",
    "desktopcomputer",
    "cpu.fill",
    "network",
    "externaldrive.fill",
    "folder.fill.badge.person.crop",
    "tray.2.fill",
    "archivebox.fill",
    "shippingbox.fill",
    "cube.fill",
    "calendar",
    "globe",
    "hammer.circle.fill",
    "theatermasks.fill",
    "sportscourt.fill",
    "pawprint.fill",
    "flask.fill"
]
