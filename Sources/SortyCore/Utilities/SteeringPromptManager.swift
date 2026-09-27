//
//  SteeringPromptManager.swift
//  Sorty
//
//  Manages saved steering prompts for AI organization
//

import Foundation
import Combine

public struct SavedSteeringPrompt: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var prompt: String
    public var isPinned: Bool
    public let dateCreated: Date

    public init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        isPinned: Bool = false,
        dateCreated: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.isPinned = isPinned
        self.dateCreated = dateCreated
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case prompt
        case isPinned
        case isDefault
        case dateCreated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        prompt = try container.decode(String.self, forKey: .prompt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned)
            ?? container.decodeIfPresent(Bool.self, forKey: .isDefault)
            ?? false
        dateCreated = try container.decode(Date.self, forKey: .dateCreated)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(dateCreated, forKey: .dateCreated)
    }
}

@MainActor
public class SteeringPromptManager: ObservableObject {
    @Published public private(set) var prompts: [SavedSteeringPrompt] = []
    @Published public private(set) var hasLoadedPersistedState = false

    private static let storageKey = "sorty.steeringPrompts"

    private let userDefaults: UserDefaults
    private let persistedDataReader: UserDefaultsDataReader
    private var loadTask: Task<PersistedSnapshot, Never>?
    private var loadGeneration = 0
    private var hasPendingChanges = false

    private struct PersistedSnapshot: Sendable {
        var prompts: [SavedSteeringPrompt] = []
        var didRemovePlaceholders = false
    }

    public static let shared = SteeringPromptManager()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.persistedDataReader = UserDefaultsDataReader(userDefaults)
        setupNotificationObservers()
    }

    /// Decodes prompts away from the main actor. In-memory additions are merged before saving.
    public func loadPersistedState() async {
        guard !hasLoadedPersistedState else { return }

        let generation = loadGeneration
        let task: Task<PersistedSnapshot, Never>
        if let loadTask {
            task = loadTask
        } else {
            let persistedDataReader = persistedDataReader
            let storageKey = Self.storageKey
            task = Task.detached(priority: .utility) {
                var snapshot = PersistedSnapshot()
                guard let data = persistedDataReader.data(forKey: storageKey),
                      let decoded = try? JSONDecoder().decode([SavedSteeringPrompt].self, from: data) else {
                    return snapshot
                }
                let loadedCount = decoded.count
                let cleaned = decoded.filter { prompt in
                    !(prompt.name.hasPrefix("Placeholder Instruction ")
                        && prompt.prompt == "Use placeholder instruction \(prompt.name.dropFirst("Placeholder Instruction ".count)) while testing long saved-instruction lists.")
                }
                snapshot.prompts = cleaned
                snapshot.didRemovePlaceholders = cleaned.count != loadedCount
                return snapshot
            }
            loadTask = task
        }

        let snapshot = await task.value
        guard !hasLoadedPersistedState, generation == loadGeneration else { return }

        let inMemoryByID = Dictionary(uniqueKeysWithValues: prompts.map { ($0.id, $0) })
        let persistedIDs = Set(snapshot.prompts.map(\.id))
        var merged = snapshot.prompts.map { inMemoryByID[$0.id] ?? $0 }
        merged.append(contentsOf: prompts.filter { !persistedIDs.contains($0.id) })
        prompts = merged
        if snapshot.didRemovePlaceholders {
            hasPendingChanges = true
        }

        hasLoadedPersistedState = true
        loadTask = nil

        if hasPendingChanges {
            hasPendingChanges = false
            save()
        }
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addMainActorObserver(forName: .clearAllUsageData, object: nil, queue: .main) { [weak self] in
            self?.clearAll()
        }
    }

    // MARK: - CRUD

    @discardableResult
    public func addPrompt(_ prompt: SavedSteeringPrompt) -> Bool {
        let normalizedName = prompt.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, !hasPrompt(named: normalizedName) else { return false }

        var prompt = prompt
        prompt.name = normalizedName

        prompts.append(prompt)
        save()
        return true
    }

    @discardableResult
    public func updatePrompt(_ prompt: SavedSteeringPrompt) -> Bool {
        let normalizedName = prompt.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !normalizedName.isEmpty,
            !hasPrompt(named: normalizedName, excluding: prompt.id),
            let index = prompts.firstIndex(where: { $0.id == prompt.id })
        else {
            return false
        }

        var prompt = prompt
        prompt.name = normalizedName

        prompts[index] = prompt
        save()
        return true
    }

    public func hasPrompt(named name: String, excluding promptId: UUID? = nil) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return false }

        return prompts.contains {
            $0.id != promptId
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(normalizedName) == .orderedSame
        }
    }

    public func prompt(id: UUID) -> SavedSteeringPrompt? {
        prompts.first { $0.id == id }
    }

    public func deletePrompt(id: UUID) {
        prompts.removeAll { $0.id == id }
        save()
    }

    public func clearAll() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        hasLoadedPersistedState = true
        hasPendingChanges = false
        prompts.removeAll()
        userDefaults.removeObject(forKey: Self.storageKey)
    }

    public func setPinned(_ isPinned: Bool, id: UUID) {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else { return }
        var updatedPrompts = prompts
        updatedPrompts[index].isPinned = isPinned
        prompts = updatedPrompts
        save()
    }

    // MARK: - Persistence

    private func save() {
        guard hasLoadedPersistedState else {
            hasPendingChanges = true
            return
        }
        do {
            let data = try JSONEncoder().encode(prompts)
            userDefaults.set(data, forKey: Self.storageKey)
        } catch {
            print("[SteeringPromptManager] Failed to encode prompts: \(error)")
        }
    }
}
