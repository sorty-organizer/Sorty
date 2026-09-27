//
//  AIKeychainLive.swift
//  SortyCore
//
//  Live AIKeychainStore backed by KeychainManager. Uses how code is used: AI
//  clients in SortyAI cannot depend on this target, so the app (or whoever
//  configures credentials) sets `AIKeychain.shared` to this once at startup.
//

/// KeychainManager-backed AIKeychainStore for production use.
public struct LiveAIKeychainStore: AIKeychainStore {
    public init() {}

    public func get(key: String) -> String? {
        KeychainManager.get(key: key)
    }

    public func getAsync(key: String) async -> String? {
        await KeychainManager.getAsync(key: key)
    }

    public func saveAsync(key: String, value: String) async -> Bool {
        await KeychainManager.saveAsync(key: key, value: value)
    }

    public func deleteAsync(key: String) async -> Bool {
        await KeychainManager.deleteAsync(key: key)
    }
}
