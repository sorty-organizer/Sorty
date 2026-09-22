//
//  GitHubCopilotAuthManager.swift
//  Sorty
//
//  Handles GitHub Device Flow Authentication
//

import Foundation
import AppKit
import Combine

enum GitHubAuthError: Error {
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case decodingError(Error)
    case notAuthenticated
    case authorizationPending
    case slowDown
    case expiredToken
    case accessDenied
    case privacyModeBlocked
    case unknown(String)
}

extension GitHubAuthError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid authentication URL."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "GitHub returned an unexpected response."
        case .decodingError:
            return "Failed to decode authentication response."
        case .notAuthenticated:
            return "Your GitHub session is missing. Please sign in again."
        case .authorizationPending:
            return "Authorization pending. Please complete sign-in in your browser."
        case .slowDown:
            return "GitHub asked us to slow down. Retrying in a moment."
        case .expiredToken:
            return "Your authorization has expired. Please sign in again."
        case .accessDenied:
            return "Access denied. Please check your GitHub Copilot subscription and permissions."
        case .privacyModeBlocked:
            return NetworkPrivacyPolicy.blockedMessage
        case .unknown(let message):
            return "Authentication failed: \(message)"
        }
    }
}

public struct DeviceCodeResponse: Codable {
    public let deviceCode: String
    public let userCode: String
    public let verificationUri: String
    public let expiresIn: Int
    public let interval: Int
    
    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

struct AccessTokenResponse: Codable {
    let accessToken: String
    let tokenType: String
    let scope: String
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
    }
}

struct CopilotTokenResponse: Codable {
    let token: String
    let expiresAt: Int
    
    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}

@MainActor
public class GitHubCopilotAuthManager: ObservableObject {
    public static let shared = GitHubCopilotAuthManager()
    
    // Client ID for VS Code's Copilot integration
    private let clientID = "Iv1.b507a08c87ecfe98"
    
    @Published public var deviceCodeResponse: DeviceCodeResponse?
    @Published public var isAuthenticated = false
    @Published public var username: String?
    @Published public var isPolling = false
    @Published public var authError: String?
    
    private let session = NetworkPrivacyPolicy.sharedSession
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<String, Error>?
    private var authenticationCheckTask: Task<Void, Never>?
    private var signOutTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let persistedAuthStateKey = "github_copilot_persisted_auth_state"
    private let persistedUsernameKey = "github_copilot_persisted_username"

    private func authorizationHeader(token: String) -> String {
        "Bearer \(token)"
    }

    private func ensureNetworkAllowed(_ url: URL) throws {
        guard NetworkPrivacyPolicy.isRequestAllowed(url: url) else {
            throw GitHubAuthError.privacyModeBlocked
        }
    }
    
    init() {
        restorePersistedState()
    }

    private func restorePersistedState() {
        guard defaults.bool(forKey: persistedAuthStateKey) else { return }
        isAuthenticated = true
        username = defaults.string(forKey: persistedUsernameKey)
    }

    private func persistAuthState(authenticated: Bool, username: String? = nil) {
        if defaults.bool(forKey: persistedAuthStateKey) != authenticated {
            defaults.set(authenticated, forKey: persistedAuthStateKey)
        }
        if let username {
            if defaults.string(forKey: persistedUsernameKey) != username {
                defaults.set(username, forKey: persistedUsernameKey)
            }
        } else if defaults.object(forKey: persistedUsernameKey) != nil {
            defaults.removeObject(forKey: persistedUsernameKey)
        }
    }
    
    public func checkAuthenticationStatus() {
        authenticationCheckTask?.cancel()
        authenticationCheckTask = Task { [weak self] in
            await self?.refreshAuthenticationStatus()
        }
    }

    private func refreshAuthenticationStatus() async {
        let hadPersistedSignedInState = defaults.bool(forKey: persistedAuthStateKey)

        let accessToken = await KeychainManager.getAsync(key: "github_access_token")
        guard !Task.isCancelled else { return }
        let hasAccessToken = !(accessToken?.isEmpty ?? true)
        var hasValidCachedCopilotToken = Self.hasValidCachedCopilotToken(
            cachedToken: await KeychainManager.getAsync(key: "github_copilot_token"),
            expiry: UserDefaults.standard.object(forKey: "github_copilot_token_expiry") as? Date
        )
        guard !Task.isCancelled else { return }

        // A Copilot token without an underlying GitHub access token is not recoverable.
        if !hasAccessToken && hasValidCachedCopilotToken {
            await invalidateCachedCopilotTokenNow()
            guard !Task.isCancelled else { return }
            hasValidCachedCopilotToken = false
        }

        let hasRecoverableAuthState = Self.hasRecoverableAuthState(
            hasAccessToken: hasAccessToken,
            hasValidCachedCopilotToken: hasValidCachedCopilotToken
        )

        if isAuthenticated != hasRecoverableAuthState {
            isAuthenticated = hasRecoverableAuthState
        }

        if isAuthenticated {
            let restoredUsername = username ?? defaults.string(forKey: persistedUsernameKey)
            if username != restoredUsername {
                username = restoredUsername
            }
            persistAuthState(authenticated: true, username: username)
            if authError != nil {
                authError = nil
            }
        } else if hadPersistedSignedInState {
            // Persisted UI state without any recoverable token path is stale.
            persistAuthState(authenticated: false)
            if username != nil {
                username = nil
            }
        } else if username != nil {
            username = nil
        }

        if hasAccessToken, !Task.isCancelled {
            // Keep profile refresh inside the coalesced authentication task so
            // repeated onboarding appearances cannot fan out duplicate fetches.
            await fetchUserProfile()
        }
    }

    static func hasValidCachedCopilotToken(cachedToken: String?, expiry: Date?, now: Date = Date()) -> Bool {
        guard let token = cachedToken, !token.isEmpty, let expiry else { return false }
        return expiry > now.addingTimeInterval(300)
    }

    static func hasRecoverableAuthState(hasAccessToken: Bool, hasValidCachedCopilotToken: Bool) -> Bool {
        let _ = hasValidCachedCopilotToken
        // A GitHub access token is required to refresh Copilot tokens reliably.
        return hasAccessToken
    }
    
    func startDeviceFlow() async throws {
        await signOutTask?.value
        if authError != nil {
            authError = nil
        }
        let url = URL(string: "https://github.com/login/device/code")!
        try ensureNetworkAllowed(url)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "client_id": clientID,
            "scope": "read:user user:email" // Added user:email scope
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GitHubAuthError.invalidResponse
        }
        
        let codeResponse = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        self.deviceCodeResponse = codeResponse

        if let verificationURL = URL(string: codeResponse.verificationUri) {
            NSWorkspace.shared.open(verificationURL)
        } else {
            self.authError = "Unable to open GitHub verification page. Use the code shown below at github.com/login/device."
        }

        LogManager.shared.log("Starting polling for access token", level: .debug, category: "AuthManager")
        // Start polling (bounded by the device-code expiry; see startPolling)
        startPolling(interval: Double(codeResponse.interval), expiresIn: codeResponse.expiresIn, deviceCode: codeResponse.deviceCode)
    }

    private func startPolling(interval: Double, expiresIn: Int, deviceCode: String) {
        // Cancel any in-flight poll before starting a new one so overlapping
        // device flows can never fan out duplicate token requests.
        pollTask?.cancel()
        pollTask = nil
        if !isPolling {
            isPolling = true
        }

        // Cap attempts by the device-code lifetime so polling always stops on
        // its own even if the user never completes or cancels the flow.
        let safeInterval = min(max(interval, 5), 30)
        let maxAttempts = max(1, Int(Double(max(expiresIn, 0)) / safeInterval))

        pollTask = Task {
            var attempt = 0
            while !Task.isCancelled, attempt < maxAttempts {
                attempt += 1
                // Jitter (capped at 30s total) avoids lockstep polling storms.
                let jitter = Double.random(in: 0...min(5, safeInterval))
                let wait = min(safeInterval + jitter, 30)
                do {
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }

                // Pause on constrained/expensive links instead of burning radio.
                if NetworkPathProbe.shared.isConstrainedOrExpensive {
                    try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    continue
                }
                
                do {
                    let token = try await requestAccessToken(deviceCode: deviceCode)
                    // Success!
                    guard await KeychainManager.saveAsync(key: "github_access_token", value: token) else {
                        let message = "Authentication succeeded but token could not be saved. Please check Keychain access and try again."
                        if self.authError != message {
                            self.authError = message
                        }
                        if self.isPolling {
                            self.isPolling = false
                        }
                        return
                    }
                    if !self.isAuthenticated {
                        self.isAuthenticated = true
                    }
                    self.persistAuthState(authenticated: true, username: self.username)
                    if self.isPolling {
                        self.isPolling = false
                    }
                    if self.deviceCodeResponse != nil {
                        self.deviceCodeResponse = nil
                    }
                    await fetchUserProfile()
                    return
                } catch GitHubAuthError.authorizationPending {
                    // Continue polling
                    continue
                } catch GitHubAuthError.slowDown {
                    // Wait longer (add 5 seconds)
                    try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                    continue
                } catch {
                    LogManager.shared.log("Error polling for token: \(error)", level: .error, category: "AuthManager")
                    let message = "Authentication failed: \(error.localizedDescription)"
                    if self.authError != message {
                        self.authError = message
                    }
                    if self.isPolling {
                        self.isPolling = false
                    }
                    return
                }
            }
            // Attempts exhausted (device code expired): stop polling with a
            // clear message instead of spinning forever.
            guard !Task.isCancelled else { return }
            let message = "Your authorization has expired. Please sign in again."
            if self.authError != message {
                self.authError = message
            }
            if self.isPolling {
                self.isPolling = false
            }
        }
    }
    
    private func requestAccessToken(deviceCode: String) async throws -> String {
        let url = URL(string: "https://github.com/login/oauth/access_token")!
        try ensureNetworkAllowed(url)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "client_id": clientID,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GitHubAuthError.invalidResponse
        }
        
        // Check for specific error fields in JSON even if 200 OK
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? String {
            switch error {
            case "authorization_pending": throw GitHubAuthError.authorizationPending
            case "slow_down": throw GitHubAuthError.slowDown
            case "expired_token": throw GitHubAuthError.expiredToken
            case "access_denied": throw GitHubAuthError.accessDenied
            default: throw GitHubAuthError.unknown(error)
            }
        }
        
        let tokenResponse = try JSONDecoder().decode(AccessTokenResponse.self, from: data)
        return tokenResponse.accessToken
    }
    
    func fetchUserProfile() async {
        guard let token = await KeychainManager.getAsync(key: "github_access_token") else { return }
        
        let url = URL(string: "https://api.github.com/user")!
        guard NetworkPrivacyPolicy.isRequestAllowed(url: url) else {
            return
        }
        var request = URLRequest(url: url)
        request.setValue(authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Sorty/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 {
                    // A second check avoids false sign-outs from occasional transient GitHub API 401s.
                    let isStillValid = await verifyTokenValidity(token: token)
                    if !isStillValid {
                        LogManager.shared.log("User profile fetch returned 401 and token validation failed, signing out", level: .warning, category: "AuthManager")
                        signOut()
                        return
                    }
                    LogManager.shared.log("User profile fetch returned transient 401, preserving sign-in state", level: .warning, category: "AuthManager")
                }
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let login = json["login"] as? String {
                if username != login {
                    username = login
                }
                persistAuthState(authenticated: true, username: login)
            } else if isAuthenticated {
                persistAuthState(authenticated: true, username: username)
            }
        } catch {
            LogManager.shared.log("Error fetching user profile: \(error)", level: .error, category: "AuthManager")
        }
    }
    
    func signOut() {
        pollTask?.cancel()
        authenticationCheckTask?.cancel()
        refreshTask?.cancel()
        signOutTask?.cancel()
        signOutTask = Task { [weak self] in
            _ = await KeychainManager.deleteAsync(key: "github_access_token")
            _ = await KeychainManager.deleteAsync(key: "github_copilot_token")
            guard !Task.isCancelled, let self else { return }
            UserDefaults.standard.removeObject(forKey: "github_copilot_token_expiry")
            self.isAuthenticated = false
            self.username = nil
            self.persistAuthState(authenticated: false)
            self.isPolling = false
            self.deviceCodeResponse = nil
            self.signOutTask = nil
        }
    }

    func invalidateCachedCopilotToken() {
        UserDefaults.standard.removeObject(forKey: "github_copilot_token_expiry")
        Task {
            _ = await KeychainManager.deleteAsync(key: "github_copilot_token")
        }
    }

    private func invalidateCachedCopilotTokenNow() async {
        UserDefaults.standard.removeObject(forKey: "github_copilot_token_expiry")
        _ = await KeychainManager.deleteAsync(key: "github_copilot_token")
    }

    @discardableResult
    func refreshCopilotTokenAfterCacheInvalidation() async throws -> String {
        await invalidateCachedCopilotTokenNow()
        return try await getCopilotToken(forceRefresh: true)
    }
    
    // Retrieve Copilot-specific token using the auth token
    func getCopilotToken(forceRefresh: Bool = false) async throws -> String {
        // If a refresh is already in progress, wait for it
        if let task = refreshTask {
            return try await task.value
        }

        // Copilot token refresh requires the underlying GitHub access token.
        let accessToken = await KeychainManager.getAsync(key: "github_access_token")
        let hasAccessToken = !(accessToken?.isEmpty ?? true)
        guard hasAccessToken else {
            await invalidateCachedCopilotTokenNow()
            if isAuthenticated {
                isAuthenticated = false
            }
            if username != nil {
                username = nil
            }
            persistAuthState(authenticated: false)
            throw GitHubAuthError.notAuthenticated
        }

        if !forceRefresh {
            // Return cached token if valid
            let cachedToken = await KeychainManager.getAsync(key: "github_copilot_token")
            let cachedExpiry = UserDefaults.standard.object(forKey: "github_copilot_token_expiry") as? Date
            if Self.hasValidCachedCopilotToken(
                cachedToken: cachedToken,
                expiry: cachedExpiry
            ),
               let cached = cachedToken,
               let expiry = cachedExpiry {
                
                // Proactive refresh: if token expires in less than 20 mins, refresh in background if not already refreshing
                if expiry < Date().addingTimeInterval(1200) {
                    Task {
                        try? await refreshCopilotToken()
                    }
                }
                
                return cached
            }
        }
        
        return try await refreshCopilotToken()
    }
    
    @discardableResult
    private func refreshCopilotToken() async throws -> String {
        // Check if there's an ongoing refresh task
        if let existingTask = refreshTask {
            return try await existingTask.value
        }

        // Create a new refresh task
        let task = Task<String, Error> {
            guard let accessToken = await KeychainManager.getAsync(key: "github_access_token") else {
                await MainActor.run {
                    signOut()
                }
                throw GitHubAuthError.notAuthenticated
            }
            
            LogManager.shared.log("Refreshing GitHub Copilot token", level: .debug, category: "AuthManager")
            
            let url = URL(string: "https://api.github.com/copilot_internal/v2/token")!
            guard NetworkPrivacyPolicy.isRequestAllowed(url: url) else {
                throw GitHubAuthError.privacyModeBlocked
            }
            var request = URLRequest(url: url)
            request.setValue(authorizationHeader(token: accessToken), forHTTPHeaderField: "Authorization")
            request.setValue("GithubCopilot/1.138.0", forHTTPHeaderField: "User-Agent")
            request.setValue("vscode/1.85.1", forHTTPHeaderField: "Editor-Version")
            request.setValue("copilot/1.138.0", forHTTPHeaderField: "Editor-Plugin-Version")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                // If 401/403, might need to re-auth. 401 = Token invalid, 403 = No Copilot subscription.
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 401 {
                        LogManager.shared.log("Access token invalid (401) during token refresh", level: .error, category: "AuthManager")
                        
                        // Before signing out, verify if it's a persistent error by checking user profile
                        // This prevents random sign-outs due to transient GitHub API glitched 401s
                        let isStillValid = await verifyTokenValidity(token: accessToken)
                        if !isStillValid {
                            LogManager.shared.log("Token confirmed invalid, force signing out", level: .fault, category: "AuthManager")
                            await MainActor.run {
                                signOut()
                            }
                        } else {
                            LogManager.shared.log("Transient 401 detected, GitHub returned 200 for profile. Skipping signOut.", level: .warning, category: "AuthManager")
                        }
                    } else if httpResponse.statusCode == 403 {
                        LogManager.shared.log("Access denied (403). User may not have an active Copilot subscription.", level: .error, category: "AuthManager")
                    }
                     throw GitHubAuthError.accessDenied
                }
                throw GitHubAuthError.invalidResponse
            }
            
            let tokenResponse = try JSONDecoder().decode(CopilotTokenResponse.self, from: data)
            
            // Cache it
            _ = await KeychainManager.saveAsync(key: "github_copilot_token", value: tokenResponse.token)
            let expiryDate = Date(timeIntervalSince1970: TimeInterval(tokenResponse.expiresAt))
            UserDefaults.standard.set(expiryDate, forKey: "github_copilot_token_expiry")
            
            LogManager.shared.log("Successfully refreshed GitHub Copilot token", level: .debug, category: "AuthManager")
            
            return tokenResponse.token
        }

        self.refreshTask = task
        
        defer {
            // Clear the task after it finishes (regardless of success/failure)
            Task { @MainActor in
                self.refreshTask = nil
            }
        }
        
        return try await task.value
    }

    /// Verifies if the token is still valid by calling the user profile API.
    /// Returns true if the token works, false if it returns 401.
    private func verifyTokenValidity(token: String) async -> Bool {
        let url = URL(string: "https://api.github.com/user")!
        guard NetworkPrivacyPolicy.isRequestAllowed(url: url) else {
            return true
        }
        var request = URLRequest(url: url)
        request.setValue(authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        request.setValue("Sorty/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        
        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode != 401
            }
            return false
        } catch {
            // On network error, assume it might still be valid (don't force sign out)
            return true
        }
    }
}
