//
//  AIKeychain.swift
//  SortyAI
//
//  Keychain access for AI provider credentials. Uses how code is used: AI
//  clients only ever read/write/delete API tokens by key, but KeychainManager
//  lives up in SortyCore (shared infra also used by the organizer and
//  settings), so clients go through this injectable store instead. The app
//  injects the live KeychainManager-backed store at launch; tests and
//  previews fall back to the ephemeral in-memory store.
//

import Foundation

/// Token storage used by AI clients. Mirrors the KeychainManager surface
/// these clients need so the live implementation is a one-line wrapper.
public protocol AIKeychainStore: Sendable {
    func get(key: String) -> String?
    func getAsync(key: String) async -> String?
    func saveAsync(key: String, value: String) async -> Bool
    func deleteAsync(key: String) async -> Bool
}

/// In-memory fallback. Never persists: used by tests, previews, and any
/// client created before the app injects the live store.
public final class EphemeralAIKeychainStore: AIKeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    /// NSLock cannot be touched from async contexts directly; funnel every
    /// access through this synchronous helper instead.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func get(key: String) -> String? {
        withLock { storage[key] }
    }

    public func getAsync(key: String) async -> String? {
        withLock { storage[key] }
    }

    public func saveAsync(key: String, value: String) async -> Bool {
        withLock {
            storage[key] = value
            return true
        }
    }

    public func deleteAsync(key: String) async -> Bool {
        withLock {
            storage.removeValue(forKey: key)
            return true
        }
    }
}

/// Single entry point AI clients use for provider credentials.
public enum AIKeychain {
    nonisolated(unsafe) public static var shared: any AIKeychainStore = EphemeralAIKeychainStore()
}
