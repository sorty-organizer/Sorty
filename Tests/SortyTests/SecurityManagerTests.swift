//
//  SecurityManagerTests.swift
//  SortyTests
//
//  Comprehensive tests for SecurityManager state management and helper logic.
//  Note: Actual biometric authentication cannot be tested without hardware.
//

import XCTest
import Combine
import LocalAuthentication
@testable import SortyLib

@MainActor
final class SecurityManagerTests: XCTestCase {
    
    var manager: SecurityManager!
    
    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "sensitiveActionAuthenticationEnabled")
        manager = SecurityManager()
    }
    
    override func tearDown() async throws {
        manager = nil
        UserDefaults.standard.removeObject(forKey: "sensitiveActionAuthenticationEnabled")
    }
    
    // MARK: - Initialization Tests
    
    func testInitialState() {
        XCTAssertFalse(manager.isUnlocked, "Should start locked")
        XCTAssertNil(manager.error, "Should have no error initially")
        XCTAssertEqual(manager.authenticationMethod, .none, "Should have no auth method initially")
    }
    
    func testDefaultSessionTimeout() {
        XCTAssertEqual(manager.sessionTimeoutInterval, 300, "Default timeout should be 5 minutes (300 seconds)")
    }
    
    func testCustomSessionTimeout() {
        manager.sessionTimeoutInterval = 600
        XCTAssertEqual(manager.sessionTimeoutInterval, 600, "Should accept custom timeout value")
    }
    
    // MARK: - Session Expiration Tests
    
    func testSessionExpiredWhenNeverAuthenticated() {
        XCTAssertTrue(manager.isSessionExpired, "Session should be expired when never authenticated")
    }
    
    func testSessionExpiredAfterLock() {
        manager.lock()
        XCTAssertTrue(manager.isSessionExpired, "Session should be expired after lock()")
    }
    
    // MARK: - Lock/Unlock State Transitions
    
    func testLockResetsState() {
        manager.lock()
        
        XCTAssertFalse(manager.isUnlocked, "Should be locked after lock()")
        XCTAssertEqual(manager.authenticationMethod, .none, "Auth method should reset to none")
        XCTAssertTrue(manager.isSessionExpired, "Session should be expired after lock")
    }
    
    func testLockFromUnlockedState() {
        manager.isUnlocked = true
        manager.authenticationMethod = .biometric
        
        manager.lock()
        
        XCTAssertFalse(manager.isUnlocked, "Should transition from unlocked to locked")
        XCTAssertEqual(manager.authenticationMethod, .none, "Auth method should reset")
    }
    
    func testMultipleLockCalls() {
        manager.lock()
        manager.lock()
        manager.lock()
        
        XCTAssertFalse(manager.isUnlocked, "Multiple lock calls should keep state locked")
        XCTAssertEqual(manager.authenticationMethod, .none)
    }
    
    // MARK: - Biometry Display Name Tests
    
    func testBiometryDisplayNameNone() {
        manager.biometryType = .none
        XCTAssertEqual(manager.biometryDisplayName, "Password")
    }
    
    func testBiometryDisplayNameTouchID() {
        manager.checkBiometryType()
        manager.biometryType = .touchID
        XCTAssertEqual(manager.biometryDisplayName, "Touch ID")
    }
    
    func testBiometryDisplayNameFaceID() {
        manager.checkBiometryType()
        manager.biometryType = .faceID
        XCTAssertEqual(manager.biometryDisplayName, "Face ID")
    }
    
    func testBiometryDisplayNameOpticID() {
        manager.checkBiometryType()
        manager.biometryType = .opticID
        XCTAssertEqual(manager.biometryDisplayName, "Optic ID")
    }
    
    // MARK: - AuthenticationMethod Enum Tests
    
    func testAuthenticationMethodRawValues() {
        XCTAssertEqual(SecurityManager.AuthenticationMethod.none.rawValue, "None")
        XCTAssertEqual(SecurityManager.AuthenticationMethod.biometric.rawValue, "Biometric")
        XCTAssertEqual(SecurityManager.AuthenticationMethod.password.rawValue, "Password")
    }
    
    func testAuthenticationMethodCaseIterable() {
        let allCases = SecurityManager.AuthenticationMethod.allCases
        XCTAssertEqual(allCases.count, 3)
        XCTAssertTrue(allCases.contains(.none))
        XCTAssertTrue(allCases.contains(.biometric))
        XCTAssertTrue(allCases.contains(.password))
    }
    
    func testAuthenticationMethodEquality() {
        XCTAssertEqual(SecurityManager.AuthenticationMethod.none, .none)
        XCTAssertNotEqual(SecurityManager.AuthenticationMethod.biometric, .password)
    }
    
    // MARK: - Session Refresh Tests
    
    func testRefreshSessionUpdatesTime() {
        manager.refreshSession()
        XCTAssertFalse(manager.isSessionExpired, "Session should not be expired immediately after refresh")
    }
    
    func testRefreshSessionMultipleTimes() {
        manager.refreshSession()
        let firstCheck = manager.isSessionExpired
        
        manager.refreshSession()
        let secondCheck = manager.isSessionExpired
        
        XCTAssertFalse(firstCheck, "First refresh should keep session valid")
        XCTAssertFalse(secondCheck, "Second refresh should keep session valid")
    }
    
    func testSessionExpiresAfterTimeout() {
        manager.sessionTimeoutInterval = 0.05
        manager.refreshSession()
        
        let expectation = XCTestExpectation(description: "Wait for session to expire")
        
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000) // 0.15s
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
        
        XCTAssertTrue(manager.isSessionExpired, "Session should expire after timeout interval")
    }
    
    // MARK: - Published Properties Tests
    
    func testIsUnlockedPublished() {
        var receivedValues: [Bool] = []
        let cancellable = manager.$isUnlocked.sink { value in
            receivedValues.append(value)
        }
        
        manager.isUnlocked = true
        manager.isUnlocked = false
        
        XCTAssertEqual(receivedValues, [false, true, false], "Should publish isUnlocked changes")
        cancellable.cancel()
    }
    
    func testAuthenticationMethodPublished() {
        var receivedValues: [SecurityManager.AuthenticationMethod] = []
        let cancellable = manager.$authenticationMethod.sink { value in
            receivedValues.append(value)
        }
        
        manager.authenticationMethod = .biometric
        manager.authenticationMethod = .password
        
        XCTAssertEqual(receivedValues, [.none, .biometric, .password], "Should publish authenticationMethod changes")
        cancellable.cancel()
    }
    
    func testErrorPublished() {
        var receivedValues: [String?] = []
        let cancellable = manager.$error.sink { value in
            receivedValues.append(value)
        }
        
        manager.error = "Test error"
        manager.error = nil
        
        XCTAssertEqual(receivedValues.count, 3)
        XCTAssertNil(receivedValues[0])
        XCTAssertEqual(receivedValues[1], "Test error")
        XCTAssertNil(receivedValues[2])
        cancellable.cancel()
    }
    
    // MARK: - State Consistency Tests
    
    func testStateConsistencyAfterLock() {
        manager.isUnlocked = true
        manager.authenticationMethod = .biometric
        manager.error = nil
        
        manager.lock()
        
        XCTAssertFalse(manager.isUnlocked)
        XCTAssertEqual(manager.authenticationMethod, .none)
        XCTAssertTrue(manager.isSessionExpired)
    }
    
    func testBiometryTypePreservedAfterLock() {
        manager.biometryType = .faceID
        
        manager.lock()
        
        XCTAssertEqual(manager.biometryType, .faceID, "Biometry type should not change on lock")
    }
    
    // MARK: - Edge Cases
    
    func testZeroSessionTimeout() {
        manager.sessionTimeoutInterval = 0
        manager.refreshSession()
        XCTAssertTrue(manager.isSessionExpired, "Session should immediately expire with zero timeout")
    }
    
    func testNegativeSessionTimeout() {
        manager.sessionTimeoutInterval = -100
        manager.refreshSession()
        XCTAssertTrue(manager.isSessionExpired, "Session should be expired with negative timeout")
    }
    
    func testVeryLargeSessionTimeout() {
        manager.sessionTimeoutInterval = 86400 * 365
        manager.refreshSession()
        XCTAssertFalse(manager.isSessionExpired, "Session should not be expired with very large timeout")
    }
    
    func testErrorStateNotClearedByLock() {
        manager.error = "Previous error"
        manager.lock()
        XCTAssertEqual(manager.error, "Previous error", "Lock should not clear error state")
    }

    func testSensitiveActionAuthenticationBypassesWhenFeatureFlagDisabled() async {
        UserDefaults.standard.removeObject(forKey: "sensitiveActionAuthenticationEnabled")

        let didAuthenticate = await manager.authenticateForSensitiveAction(reason: "Authenticate for test.")

        XCTAssertTrue(didAuthenticate)
        XCTAssertNil(manager.error)
        XCTAssertFalse(manager.isUnlocked, "Bypass should not create a secure session")
    }

    func testLearningsAuthenticationBypassesWhenFeatureFlagDisabled() async {
        UserDefaults.standard.removeObject(forKey: "sensitiveActionAuthenticationEnabled")

        let didAuthenticate = await manager.authenticateForLearningsAccess()

        XCTAssertTrue(didAuthenticate)
        XCTAssertNil(manager.error)
    }
}
