//
//  NamingPresetManager.swift
//  Sorty
//
//  Manages naming presets (built-in and custom)
//

import Foundation
import Combine

@MainActor
public class NamingPresetManager: ObservableObject {
    @Published public private(set) var customPresets: [NamingPreset] = []
    @Published public private(set) var hasLoadedPersistedState = false

    private static let storageKey = "sorty.namingPresets"

    private let userDefaults: UserDefaults
    private let persistedDataReader: UserDefaultsDataReader
    private var loadTask: Task<[NamingPreset], Never>?
    private var loadGeneration = 0
    private var hasPendingChanges = false

    public static let shared = NamingPresetManager()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.persistedDataReader = UserDefaultsDataReader(userDefaults)
        setupNotificationObservers()
    }

    /// Decodes custom presets away from the main actor. In-memory additions are merged before saving.
    public func loadPersistedState() async {
        guard !hasLoadedPersistedState else { return }

        let generation = loadGeneration
        let task: Task<[NamingPreset], Never>
        if let loadTask {
            task = loadTask
        } else {
            let persistedDataReader = persistedDataReader
            let storageKey = Self.storageKey
            task = Task.detached(priority: .utility) {
                guard let data = persistedDataReader.data(forKey: storageKey),
                      let decoded = try? JSONDecoder().decode([NamingPreset].self, from: data) else {
                    return []
                }
                return decoded
            }
            loadTask = task
        }

        let persistedPresets = await task.value
        guard !hasLoadedPersistedState, generation == loadGeneration else { return }

        let inMemoryByID = Dictionary(uniqueKeysWithValues: customPresets.map { ($0.id, $0) })
        let persistedIDs = Set(persistedPresets.map(\.id))
        var merged = persistedPresets.map { inMemoryByID[$0.id] ?? $0 }
        merged.append(contentsOf: customPresets.filter { !persistedIDs.contains($0.id) })
        customPresets = merged

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

    // MARK: - Stable UUID Generation

    private static func stableUUID(for rawValue: String) -> UUID {
        let data = Data(rawValue.utf8)
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, byte) in data.enumerated() {
            bytes[i % 16] ^= byte
        }
        // Set version 4 and variant bits
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Built-in Presets

    public var builtInPresets: [NamingPreset] {
        NamingStyle.allCases.compactMap { style in
            guard style != .custom else { return nil }
            return NamingPreset(
                id: NamingPresetManager.stableUUID(for: style.rawValue),
                name: style.displayName,
                instructions: style.promptInstructions,
                dateCreated: Date(timeIntervalSince1970: 0),
                isBuiltIn: true
            )
        }
    }

    // MARK: - All Presets

    public var allPresets: [NamingPreset] {
        builtInPresets + customPresets
    }

    // MARK: - CRUD Operations

    public func addPreset(_ preset: NamingPreset) {
        customPresets.append(preset)
        save()
    }

    public func updatePreset(_ preset: NamingPreset) {
        guard let index = customPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        customPresets[index].name = preset.name
        customPresets[index].instructions = preset.instructions
        save()
    }

    public func deletePreset(id: UUID) {
        // Refuse to delete built-in presets
        guard !builtInPresets.contains(where: { $0.id == id }) else { return }
        customPresets.removeAll { $0.id == id }
        save()
    }

    public func clearAll() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        hasLoadedPersistedState = true
        hasPendingChanges = false
        customPresets.removeAll()
        userDefaults.removeObject(forKey: Self.storageKey)
    }

    public func preset(for id: UUID) -> NamingPreset? {
        allPresets.first { $0.id == id }
    }

    // MARK: - Mapping Helpers
    /// Returns the NamingStyle that corresponds to a built-in preset ID, if any.
    public func namingStyle(for presetId: UUID) -> NamingStyle? {
        for style in NamingStyle.allCases where style != .custom {
            if NamingPresetManager.stableUUID(for: style.rawValue) == presetId {
                return style
            }
        }
        return nil
    }

    /// Returns the stable preset ID for a given NamingStyle (excluding .custom).
    public func presetId(for style: NamingStyle) -> UUID? {
        guard style != .custom else { return nil }
        return NamingPresetManager.stableUUID(for: style.rawValue)
    }

    // MARK: - Persistence

    private func save() {
        guard hasLoadedPersistedState else {
            hasPendingChanges = true
            return
        }
        do {
            let data = try JSONEncoder().encode(customPresets)
            userDefaults.set(data, forKey: Self.storageKey)
        } catch {
            print("[NamingPresetManager] Failed to encode presets: \(error)")
        }
    }
}
