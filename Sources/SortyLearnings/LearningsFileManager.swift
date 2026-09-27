//
//  LearningsFileManager.swift
//  Sorty
//
//  Secure file storage for user learnings in .learning files.
//  Uses AES-256 encryption with Keychain-stored keys.
//

import Foundation
import CryptoKit
import SortyModels

/// Manages secure storage of learning profiles in encrypted .learning files
public struct LearningsFileManager {
    
    // MARK: - Configuration
    
    private static var learningsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Sorty/Learnings")
    }
    
    private static var userIdentifier: String {
        NSUserName()
    }
    
    private static var profileURL: URL {
        learningsDirectory.appendingPathComponent("\(userIdentifier).learning")
    }
    
    // MARK: - Public API
    
    /// Save profile to encrypted .learning file.
    /// Call from a worker (Task.detached/serial queue), never the main actor:
    /// encoding, Keychain access, AES, and the file write all block.
    public static func save(profile: LearningsProfile) throws {
        // Ensure directory exists
        try ensureDirectoryExists()
        
        // Encode profile to JSON. Compact at rest (.sortedKeys only):
        // .prettyPrinted bloats every save with whitespace; exports keep it.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let jsonData = try encoder.encode(profile)
        
        // Get or create encryption key
        let key = try getOrCreateEncryptionKey()
        
        // Encrypt data
        let encryptedData = try encrypt(data: jsonData, using: key)
        
        // Write to file atomically so a crash or power loss can never
        // leave a truncated profile behind.
        try encryptedData.write(to: profileURL, options: .atomic)
        
        ModelLog.log("Saved profile to \(profileURL.lastPathComponent)", category: "LearningsFile")
    }
    
    /// Load profile from encrypted .learning file
    public static func load() throws -> LearningsProfile? {
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            return nil
        }
        
        // Read encrypted data
        let encryptedData = try Data(contentsOf: profileURL)
        
        // Get encryption key. A missing key alongside an existing file means
        // the data is currently undecryptable, but the cause matters: if the
        // Keychain is temporarily unavailable, leave the file in place so a
        // later launch with the key can read it; if the item is definitively
        // gone, the file can never be decrypted again and must be recovered.
        guard let key = getEncryptionKey() else {
            guard LearningsKeychain.shared.itemStatus(key: encryptionKeychainKey) == .notFound else {
                throw LearningsFileError.noEncryptionKey
            }

            // Definitive loss (Keychain reset). Quarantine the orphaned bytes
            // and rotate so learning can continue instead of staying dead
            // forever. `getOrCreateEncryptionKey` performs the quarantine and
            // stores/caches the new key; callers retry with a fresh profile.
            _ = try getOrCreateEncryptionKey()
            ModelLog.log(
                "Learnings encryption key was missing; quarantined the profile and rotated the key",
                level: .warning,
                category: "LearningsFile"
            )
            throw LearningsFileError.corruptProfileQuarantined
        }

        do {
            // Decrypt data
            let jsonData = try decrypt(data: encryptedData, using: key)

            // Decode profile
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let profile = try decoder.decode(LearningsProfile.self, from: jsonData)

            ModelLog.log("Loaded profile from \(profileURL.lastPathComponent)", category: "LearningsFile")
            return profile
        } catch {
            // The key is available yet the contents are unreadable (truncated
            // write, corruption, unknown schema). Quarantine the file before
            // callers fall back to an empty profile whose next save would
            // otherwise destroy the evidence silently.
            quarantineCorruptProfile()
            throw LearningsFileError.corruptProfileQuarantined
        }
    }
    
    /// Delete all persisted Learnings files and destroy the encryption key.
    public static func secureDelete() throws {
        try deleteAllData()
    }

    public static func deleteAllData(
        fileManager: FileManager = .default,
        directory: URL? = nil
    ) throws {
        let targetDirectory = directory ?? learningsDirectory
        guard LearningsKeychain.shared.delete(key: encryptionKeychainKey) else {
            throw LearningsFileError.keychainDeleteFailed
        }
        invalidateCachedKey()
        try deleteStoredFiles(fileManager: fileManager, directory: targetDirectory)

        ModelLog.log("Deleted all Learnings data", category: "LearningsFile")
    }

    static func deleteStoredFiles(
        fileManager: FileManager,
        directory: URL
    ) throws {
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        try fileManager.removeItem(at: directory)
    }
    
    /// Check if a profile exists
    public static var profileExists: Bool {
        FileManager.default.fileExists(atPath: profileURL.path)
    }
    
    /// Directory containing encrypted .learning profiles
    public static var storageDirectoryPath: String {
        learningsDirectory.path
    }
    
    // MARK: - Encryption

    private static let encryptionKeychainKey = "learnings_encryption_key"

    /// In-memory SymmetricKey bytes so saves do not hit the Keychain on
    /// every write. Guarded by a lock; cleared on deleteAllData.
    private static let keyCacheLock = NSLock()
    nonisolated(unsafe) private static var cachedKeyData: Data?

    private static func cachedKey() -> SymmetricKey? {
        keyCacheLock.lock()
        defer { keyCacheLock.unlock() }
        guard let cachedKeyData else { return nil }
        return SymmetricKey(data: cachedKeyData)
    }

    private static func cacheKey(_ key: SymmetricKey) {
        let keyData = key.withUnsafeBytes { Data($0) }
        keyCacheLock.lock()
        cachedKeyData = keyData
        keyCacheLock.unlock()
    }

    private static func invalidateCachedKey() {
        keyCacheLock.lock()
        cachedKeyData = nil
        keyCacheLock.unlock()
    }
    
    private static func getOrCreateEncryptionKey() throws -> SymmetricKey {
        if let existing = cachedKey() ?? getEncryptionKey() {
            return existing
        }

        // `LearningsKeychain.shared.get` returns nil both when no key was ever stored and
        // when the Keychain is temporarily unreadable (locked keychain, denied
        // access). Only a definitive "every service says item-not-found" may
        // rotate the key: treating a transient failure as "missing" quarantines
        // a healthy profile and orphans its data under a fresh key.
        guard LearningsKeychain.shared.itemStatus(key: encryptionKeychainKey) == .notFound else {
            ModelLog.log(
                "Learnings encryption key is currently unavailable; keeping the existing key and profile",
                level: .warning,
                category: "LearningsFile"
            )
            throw LearningsFileError.noEncryptionKey
        }

        // A profile file without a key is orphaned (Keychain reset). Quarantine
        // it before rotating so the bytes survive for forensics instead of
        // being overwritten silently.
        if FileManager.default.fileExists(atPath: profileURL.path) {
            quarantineCorruptProfile()
        }

        // Generate new key
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        
        // Store in Keychain
        guard LearningsKeychain.shared.save(key: encryptionKeychainKey, value: keyData.base64EncodedString()) else {
            throw LearningsFileError.keychainSaveFailed
        }

        cacheKey(key)
        return key
    }

    /// Reads the cached or Keychain-stored Learnings key.
    private static func getEncryptionKey() -> SymmetricKey? {
        if let cached = cachedKey() {
            return cached
        }
        guard let base64Key = LearningsKeychain.shared.get(key: encryptionKeychainKey),
              let keyData = Data(base64Encoded: base64Key) else {
            return nil
        }
        keyCacheLock.lock()
        cachedKeyData = keyData
        keyCacheLock.unlock()
        return SymmetricKey(data: keyData)
    }
    
    private static func encrypt(data: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw LearningsFileError.encryptionFailed
        }
        return combined
    }
    
    private static func decrypt(data: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: key)
    }
    
    // MARK: - Helpers
    
    private static func ensureDirectoryExists() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: learningsDirectory.path) {
            try fm.createDirectory(at: learningsDirectory, withIntermediateDirectories: true)
        }
    }

    /// Moves an unreadable or orphaned profile aside (single slot) so a fresh
    /// profile can be written without destroying evidence. Never throws: the
    /// worst case is the corrupt file staying where the next save overwrites it.
    private static func quarantineCorruptProfile() {
        let quarantineURL = learningsDirectory
            .appendingPathComponent("\(userIdentifier).corrupt.learning")
        do {
            try FileManager.default.createDirectory(
                at: learningsDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: quarantineURL.path) {
                try FileManager.default.removeItem(at: quarantineURL)
            }
            try FileManager.default.moveItem(at: profileURL, to: quarantineURL)
            ModelLog.log(
                "Quarantined unreadable profile to \(quarantineURL.lastPathComponent)",
                level: .warning, category: "LearningsFile")
        } catch {
            ModelLog.log(
                "Failed to quarantine unreadable profile: \(error.localizedDescription)",
                level: .error, category: "LearningsFile")
        }
    }
}

// MARK: - Errors

public enum LearningsFileError: LocalizedError {
    case noEncryptionKey
    case keychainSaveFailed
    case keychainDeleteFailed
    case encryptionFailed
    case decryptionFailed
    case corruptProfileQuarantined

    public var errorDescription: String? {
        switch self {
        case .noEncryptionKey:
            return "No encryption key found. Cannot decrypt learning data."
        case .keychainSaveFailed:
            return "Failed to save encryption key to Keychain."
        case .keychainDeleteFailed:
            return "Failed to delete the Learnings encryption key from Keychain."
        case .encryptionFailed:
            return "Failed to encrypt learning data."
        case .decryptionFailed:
            return "Failed to decrypt learning data."
        case .corruptProfileQuarantined:
            return "Saved learnings were unreadable, so Sorty set them aside and started fresh."
        }
    }
}
