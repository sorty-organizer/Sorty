//
//  LearningsConsentManager.swift
//  Sorty
//
//  Manages user consent for the Learnings feature.
//  Ensures strict opt-in before any data collection.
//

import Foundation
import Combine
import SwiftUI

/// Manages user consent state for the Learnings feature
@MainActor
public class LearningsConsentManager: ObservableObject {
    
    // MARK: - Published State
    
    @Published public private(set) var hasConsented: Bool = false
    @Published public private(set) var consentDate: Date?
    @Published public private(set) var hasCompletedInitialSetup: Bool = false
    
    // MARK: - Private
    
    private let consentKey = "learnings_consent_granted"
    private let consentDateKey = "learnings_consent_date"
    private let setupCompleteKey = "learnings_initial_setup_complete"
    private let userDefaults: UserDefaults
    
    // MARK: - Init
    
    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadConsentState()
    }
    
    // MARK: - Public API
    
    /// Grant consent with timestamp
    public func grantConsent() {
        let now = Date()
        hasConsented = true
        consentDate = now
        
        userDefaults.set(true, forKey: consentKey)
        userDefaults.set(now.timeIntervalSince1970, forKey: consentDateKey)
        
        LogManager.shared.log("Consent granted at \(now)", category: "ConsentManager")
    }
    
    /// Revoke consent (stops data collection but keeps existing data)
    public func withdrawConsent() {
        hasConsented = false
        
        userDefaults.set(false, forKey: consentKey)
        
        LogManager.shared.log("Consent withdrawn", category: "ConsentManager")
    }
    
    /// Mark initial setup as complete (triggers Touch ID requirement)
    public func completeInitialSetup() {
        hasCompletedInitialSetup = true
        userDefaults.set(true, forKey: setupCompleteKey)
        
        LogManager.shared.log("Initial setup complete, Touch ID will be required", category: "ConsentManager")
    }
    
    /// Reset initial setup (for testing or re-onboarding)
    public func resetInitialSetup() {
        hasCompletedInitialSetup = false
        userDefaults.set(false, forKey: setupCompleteKey)
    }
    
    /// Delete ALL user learning data securely
    public func deleteAllData() async throws {
        try LearningsFileManager.deleteAllData()

        hasConsented = false
        hasCompletedInitialSetup = false
        consentDate = nil

        userDefaults.removeObject(forKey: consentKey)
        userDefaults.removeObject(forKey: consentDateKey)
        userDefaults.removeObject(forKey: setupCompleteKey)
        
        LogManager.shared.log("All data deleted successfully", category: "ConsentManager")
    }
    
    /// Check if data collection is allowed
    public var canCollectData: Bool {
        return hasConsented
    }
    
    // MARK: - Private
    
    private func loadConsentState() {
        hasConsented = userDefaults.bool(forKey: consentKey)
        hasCompletedInitialSetup = userDefaults.bool(forKey: setupCompleteKey)
        
        if let timestamp = userDefaults.object(forKey: consentDateKey) as? TimeInterval {
            consentDate = Date(timeIntervalSince1970: timestamp)
        }
    }
}
