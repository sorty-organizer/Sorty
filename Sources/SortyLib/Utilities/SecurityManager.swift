//
//  SecurityManager.swift
//  Sorty
//
//  Manages biometric authentication and secure access to sensitive features.
//  Enhanced with session timeout and password fallback for Learnings feature.
//

import Foundation
import Combine
import LocalAuthentication
import SwiftUI

@MainActor
public class SecurityManager: ObservableObject {
    public static let shared = SecurityManager()
    
    // MARK: - Published State
    
    @Published public var isUnlocked: Bool = false
    @Published public var biometryType: LABiometryType = .none
    @Published public var error: String?
    @Published public var authenticationMethod: AuthenticationMethod = .none
    
    // MARK: - Session Management
    
    /// Session timeout duration (5 minutes)
    public var sessionTimeoutInterval: TimeInterval = 300 {
        didSet {
            if isUnlocked {
                startSessionTimer()
            }
        }
    }
    
    private var lastAuthenticationTime: Date?
    private var sessionTimer: Timer?

    /// Whether the session has timed out
    public var isSessionExpired: Bool {
        if sessionTimeoutInterval <= 0 {
            return true
        }
        guard let lastAuth = lastAuthenticationTime else { return true }
        return Date().timeIntervalSince(lastAuth) > sessionTimeoutInterval
    }
    
    // MARK: - Init

    /// Construction stays cheap for fast launch; biometry resolves lazily on
    /// first authentication or settings presentation, not in `init`.
    public init() {}

    private var hasResolvedBiometryType = false
    
    // MARK: - Authentication Methods
    
    public enum AuthenticationMethod: String, CaseIterable {
        case none = "None"
        case biometric = "Biometric"
        case password = "Password"
    }
    
    /// Checks what kind of biometry is available on the device
    public func checkBiometryType() {
        hasResolvedBiometryType = true
        let context = LAContext()
        var error: NSError?
        
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            biometryType = context.biometryType
        } else {
            biometryType = .none
            LogManager.shared.log("Biometry not available: \(error?.localizedDescription ?? "Unknown error")", level: .warning, category: "SecurityManager")
        }
    }
    
    /// Display name for the available biometry type
    public var biometryDisplayName: String {
        if !hasResolvedBiometryType {
            checkBiometryType()
        }
        switch biometryType {
        case .touchID:
            return "Touch ID"
        case .faceID:
            return "Face ID"
        case .opticID:
            return "Optic ID"
        case .none:
            return "Password"
        @unknown default:
            return "Biometric"
        }
    }
    
    /// Requests authentication specifically for Learnings access.
    /// Returns `true` when access is granted.
    @discardableResult
    public func authenticateForLearningsAccess() async -> Bool {
        await authenticateForSensitiveAction(
            reason: "Authenticate to access your personal organization learnings."
        )
    }

    /// Central authentication entry point for any sensitive action in the app.
    /// Returns `true` when the action should proceed.
    @discardableResult
    public func authenticateForSensitiveAction(reason: String) async -> Bool {
        guard FeatureFlags.sensitiveActionAuthenticationEnabled else {
            error = nil
            return true
        }

        if !isSessionExpired && isUnlocked {
            refreshSession()
            error = nil
            return true
        }

        checkBiometryType()

        if let biometricResult = await authenticateWithBiometrics(reason: reason) {
            return biometricResult
        }

        return await authenticateWithPassword(reason: reason)
    }

    private func authenticateWithBiometrics(reason: String) async -> Bool? {
        guard biometryType != .none else {
            return nil
        }

        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"

        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
            return nil
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            if success {
                completeSuccessfulAuthentication(method: .biometric)
                LogManager.shared.log("Authentication successful via \(authenticationMethod.rawValue)", category: "SecurityManager")
                return true
            }
        } catch let error as LAError {
            switch error.code {
            case .userFallback:
                return nil
            case .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled:
                return nil
            case .userCancel:
                self.error = "Authentication cancelled"
                self.isUnlocked = false
                return false
            default:
                self.error = "Authentication failed: \(error.localizedDescription)"
                self.isUnlocked = false
                return false
            }
        } catch {
            self.error = "Authentication failed: \(error.localizedDescription)"
            self.isUnlocked = false
            return false
        }

        return false
    }

    /// Authenticate using system password (fallback for non-biometric devices).
    private func authenticateWithPassword(reason: String) async -> Bool {
        let context = LAContext()

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            self.error = "No authentication method available on this device."
            self.isUnlocked = false
            return false
        }

        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if success {
                completeSuccessfulAuthentication(method: .password)
                LogManager.shared.log("Authentication successful via password", category: "SecurityManager")
                return true
            }
            self.error = "Authentication failed."
            self.isUnlocked = false
            return false
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .systemCancel, .appCancel:
                self.error = "Authentication cancelled"
            default:
                self.error = "Password authentication failed: \(error.localizedDescription)"
            }
            self.isUnlocked = false
            return false
        } catch {
            self.error = "Password authentication failed: \(error.localizedDescription)"
            self.isUnlocked = false
            return false
        }
    }

    /// Locks the secure features again
    public func lock() {
        isUnlocked = false
        lastAuthenticationTime = nil
        authenticationMethod = .none
        stopSessionTimer()
        LogManager.shared.log("Session locked", category: "SecurityManager")
    }
    
    /// Refresh the session timer (call on user activity)
    public func refreshSession() {
        lastAuthenticationTime = Date()
        if isUnlocked {
            startSessionTimer()
        }
    }

    private func completeSuccessfulAuthentication(method: AuthenticationMethod) {
        isUnlocked = true
        error = nil
        authenticationMethod = method
        lastAuthenticationTime = Date()
        startSessionTimer()
    }
    
    // MARK: - Session Timer
    
    private func startSessionTimer() {
        stopSessionTimer()
        
        let elapsed = lastAuthenticationTime.map { Date().timeIntervalSince($0) } ?? 0
        let remaining = max(0.001, sessionTimeoutInterval - elapsed)
        sessionTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.checkSessionTimeout()
            }
        }
    }
    
    private func stopSessionTimer() {
        sessionTimer?.invalidate()
        sessionTimer = nil
    }
    
    private func checkSessionTimeout() {
        if isSessionExpired && isUnlocked {
            lock()
            LogManager.shared.log("Session timed out after \(sessionTimeoutInterval) seconds", level: .info, category: "SecurityManager")
        }
    }
}
