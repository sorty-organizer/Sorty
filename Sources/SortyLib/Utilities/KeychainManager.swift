//
//  KeychainManager.swift
//  Sorty
//
//  Secure storage for API keys using Keychain
//

import Foundation
import Security

struct KeychainManager {
    // Use a fixed service name so credentials persist across app rebuilds
    // and bundle ID changes during development
    private static let primaryService = "com.sorty.app.credentials"

    // In-memory cache so hot paths (Learnings saves, provider-key reads) do
    // not hit Security.framework on every call. Security.framework can block
    // while macOS unlocks or searches a keychain; the cache keeps those calls
    // off the main thread after the first read. Invalidated on save/delete.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedValues: [String: String] = [:]

    private static func cacheGet(key: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedValues[key]
    }

    private static func cacheSet(key: String, value: String) {
        cacheLock.lock()
        cachedValues[key] = value
        cacheLock.unlock()
    }

    private static func cacheRemove(key: String) {
        cacheLock.lock()
        cachedValues.removeValue(forKey: key)
        cacheLock.unlock()
    }

    // Accessibility choice: AfterFirstUnlock keeps API keys available to
    // background automation (watched folders, login item) after a restart
    // once the user has unlocked once, without requiring an unlock prompt on
    // every launch. Deliberately NOT ThisDeviceOnly: users expect keys to
    // migrate with encrypted backups. NOT WhenUnlocked: that would break
    // background organize runs while the screen is locked.

    private static var fallbackServices: [String] {
        var services: [String] = []

        if let bundleID = Bundle.main.bundleIdentifier,
           !bundleID.isEmpty,
           bundleID != primaryService {
            services.append(bundleID)
        }

        services.append(contentsOf: [
            "com.sorty.app",
            "com.sorty.Sorty",
            "com.sorty.SortyApp",
            "shirishpothi.Sorty"
        ])

        var seen = Set<String>()
        return services.filter { seen.insert($0).inserted }
    }

    private static var allServices: [String] {
        [primaryService] + fallbackServices
    }
    
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: primaryService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            cacheSet(key: key, value: value)
            cleanupFallbackServices(for: key)
            return true
        }

        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: primaryService,
                kSecAttrAccount as String: key
            ]
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]

            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
            if updateStatus == errSecSuccess {
                cacheSet(key: key, value: value)
                cleanupFallbackServices(for: key)
                return true
            }
            logFailure(operation: "update", status: updateStatus)
            return false
        }

        logFailure(operation: "save", status: status)
        return false
    }

    /// Security.framework can block while macOS unlocks or searches a keychain.
    /// Keep those calls away from the main actor so app and settings construction
    /// can never stall the first window.
    static func saveAsync(key: String, value: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            save(key: key, value: value)
        }.value
    }
    
    static func get(key: String) -> String? {
        if let cached = cacheGet(key: key) {
            return cached
        }

        if let value = readValue(key: key, service: primaryService) {
            cacheSet(key: key, value: value)
            return value
        }

        for service in fallbackServices {
            guard let value = readValue(key: key, service: service) else { continue }
            // Silent migration would hide keychain errors; only migrate after
            // a verified read, and log when the follow-up save fails.
            if !save(key: key, value: value) {
                LogManager.shared.log("Sorty Keychain migration failed for key \(key)", level: .error, category: "KeychainManager")
            } else {
                LogManager.shared.log("Sorty Keychain migrated key \(key) from \(service)", level: .info, category: "KeychainManager")
            }
            return value
        }

        return nil
    }

    /// Cached read: returns the in-memory value without leaving the caller
    /// thread, and only hops to a detached worker on a cache miss.
    static func getAsync(key: String) async -> String? {
        if let cached = cacheGet(key: key) {
            return cached
        }
        return await Task.detached(priority: .userInitiated) {
            get(key: key)
        }.value
    }

    static func delete(key: String) -> Bool {
        // Invalidate the cache up front so a failed delete can never serve
        // a stale credential to later reads.
        cacheRemove(key: key)
        var success = true

        for service in allServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]

            let status = SecItemDelete(query as CFDictionary)
            let isDeleted = status == errSecSuccess || status == errSecItemNotFound
            if !isDeleted {
                logFailure(operation: "delete(\(service))", status: status)
            }
            success = success && isDeleted
        }

        return success
    }

    static func deleteAsync(key: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            delete(key: key)
        }.value
    }

    static func deleteAll() -> Bool {
        cacheLock.lock()
        cachedValues.removeAll()
        cacheLock.unlock()
        var success = true

        for service in allServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]

            let status = SecItemDelete(query as CFDictionary)
            let isDeleted = status == errSecSuccess || status == errSecItemNotFound
            if !isDeleted {
                logFailure(operation: "deleteAll(\(service))", status: status)
            }
            success = success && isDeleted
        }

        return success
    }

    private static func readValue(key: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            // errSecItemNotFound is the normal "no saved key" case; log only
            // real failures so keychain issues are diagnosable.
            if status != errSecItemNotFound {
                logFailure(operation: "read(\(service))", status: status)
            }
            return nil
        }

        return value
    }

    private static func cleanupFallbackServices(for key: String) {
        for service in fallbackServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
    }

    private static func logFailure(operation: String, status: OSStatus) {
        let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "Unknown Keychain error"
        LogManager.shared.log("Sorty Keychain \(operation) failed (OSStatus \(status)): \(message)", level: .error, category: "KeychainManager")
    }
}
