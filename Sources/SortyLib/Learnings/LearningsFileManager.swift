//
//  LearningsFileManager.swift
//  Sorty
//
//  Secure file storage for user learnings in .learning files.
//  Uses AES-256 encryption with Keychain-stored keys.
//

import Foundation
import CryptoKit

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
    
    /// Save profile to encrypted .learning file
    public static func save(profile: LearningsProfile) throws {
        // Ensure directory exists
        try ensureDirectoryExists()
        
        // Encode profile to JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(profile)
        
        // Get or create encryption key
        let key = try getOrCreateEncryptionKey()
        
        // Encrypt data
        let encryptedData = try encrypt(data: jsonData, using: key)
        
        // Write to file
        try encryptedData.write(to: profileURL)
        
        LogManager.shared.log("Saved profile to \(profileURL.lastPathComponent)", category: "LearningsFile")
    }
    
    /// Load profile from encrypted .learning file
    public static func load() throws -> LearningsProfile? {
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            return nil
        }
        
        // Read encrypted data
        let encryptedData = try Data(contentsOf: profileURL)
        
        // Get encryption key
        guard let key = getEncryptionKey() else {
            throw LearningsFileError.noEncryptionKey
        }
        
        // Decrypt data
        let jsonData = try decrypt(data: encryptedData, using: key)
        
        // Decode profile
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(LearningsProfile.self, from: jsonData)
        
        LogManager.shared.log("Loaded profile from \(profileURL.lastPathComponent)", category: "LearningsFile")
        return profile
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
        try deleteStoredFiles(fileManager: fileManager, directory: targetDirectory)

        guard KeychainManager.delete(key: "learnings_encryption_key") else {
            throw LearningsFileError.keychainDeleteFailed
        }

        LogManager.shared.log("Deleted all Learnings data", category: "LearningsFile")
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
    
    private static func getOrCreateEncryptionKey() throws -> SymmetricKey {
        if let existing = getEncryptionKey() {
            return existing
        }
        
        // Generate new key
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        
        // Store in Keychain
        guard KeychainManager.save(key: "learnings_encryption_key", value: keyData.base64EncodedString()) else {
            throw LearningsFileError.keychainSaveFailed
        }
        
        return key
    }
    
    private static func getEncryptionKey() -> SymmetricKey? {
        guard let base64Key = KeychainManager.get(key: "learnings_encryption_key"),
              let keyData = Data(base64Encoded: base64Key) else {
            return nil
        }
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
}

// MARK: - Errors

public enum LearningsFileError: LocalizedError {
    case noEncryptionKey
    case keychainSaveFailed
    case keychainDeleteFailed
    case encryptionFailed
    case decryptionFailed
    
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
        }
    }
}
