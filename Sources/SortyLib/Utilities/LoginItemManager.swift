//
//  LoginItemManager.swift
//  Sorty
//
//  SMAppService-based login item management for macOS 13+
//

import Foundation
import AppKit
import Combine
import ServiceManagement

private struct LoginItemServiceStatus: Sendable {
    let isLaunchAtLoginEnabled: Bool
    let isBackgroundAgentEnabled: Bool
    let registrationStatus: String
    let agentStatus: String
    /// A preference value the app should adopt when SMAppService disagrees and
    /// the change came from outside the app (System Settings). Nil means the
    /// current preference already reflects the registration state.
    let launchAtLoginPreference: Bool?
}

@MainActor
public class LoginItemManager: ObservableObject {

    public static let shared = LoginItemManager()
    public nonisolated static let backgroundAgentPlistName = "com.sorty.app.background-agent.plist"
    public nonisolated static let legacyBackgroundAgentPlistName = "com.sorty.app.plist"
    public nonisolated static let backgroundAgentServiceLabel = "com.sorty.app.background-agent"
    public nonisolated static let backgroundAgentBundleProgram = "Contents/MacOS/Sorty"
    private nonisolated static let registeredBackgroundAgentBundleProgramKey = "registeredBackgroundAgentBundleProgram"

    @Published public var isLaunchAtLoginEnabled: Bool = false
    @Published public var isBackgroundAgentEnabled: Bool = false
    @Published public var registrationStatus: String = "Unknown"
    @Published public var agentStatus: String = "Unknown"

    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false
    private var serviceSyncTask: Task<Void, Never>?
    private var serviceSyncGeneration = 0
    /// When the app itself last changed the Launch at Login preference. A
    /// `.notRegistered` status observed outside this short window is treated as
    /// the user's System Settings opt-out instead of a missing registration.
    private var lastUserInitiatedLaunchAtLoginChange: Date?
    private static let userInitiatedChangeWindow: TimeInterval = 30

    private init() {}

    /// Starts system registration observation after the first window is visible.
    /// Querying SMAppService during construction can block scene creation.
    public func startUp() {
        guard !hasStarted else { return }
        hasStarted = true
        setupObservations()
    }

    public nonisolated static func backgroundAgentConfigurationIssues(
        label: String,
        bundleProgram: String,
        mainAppServiceLabel: String
    ) -> [String] {
        var issues: [String] = []

        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Background agent label is missing")
        } else if label == mainAppServiceLabel {
            issues.append("Background agent label collides with the main app service label")
        }

        if bundleProgram.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Background agent BundleProgram is missing")
        } else if bundleProgram != backgroundAgentBundleProgram {
            issues.append("Background agent BundleProgram must remain \(backgroundAgentBundleProgram)")
        }

        return issues
    }

    // MARK: - Observations

    private func setupObservations() {
        // Observe UserDefaults for background and login item settings
        // This ensures system registration stays in sync even when main window is closed
        
        UserDefaults.standard.publisher(for: \.launchAtLogin, options: [.new])
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            let launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
            let keepInBackground = UserDefaults.standard.bool(forKey: "keepInBackground")
            self?.lastUserInitiatedLaunchAtLoginChange = Date()
            self?.syncServiceRegistration(
                launchAtLogin: launchAtLogin,
                keepInBackground: keepInBackground,
                initiatedByUser: true
            )
        }
        .store(in: &cancellables)

        UserDefaults.standard.publisher(for: \.keepInBackground, options: [.new])
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            let launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
            let keepInBackground = UserDefaults.standard.bool(forKey: "keepInBackground")
            self?.syncServiceRegistration(
                launchAtLogin: launchAtLogin,
                keepInBackground: keepInBackground
            )
        }
        .store(in: &cancellables)
    }

    // MARK: - Status

    /// Refreshes the current login item registration status from SMAppService.
    public func refreshStatus() {
        // Main App Status (Launch at Login)
        let status = SMAppService.mainApp.status
        // `.requiresApproval` is a registration awaiting System Settings
        // approval, not an absent one; reporting it as enabled keeps the toggle
        // aligned with the stored preference so a click can unregister it.
        self.isLaunchAtLoginEnabled = (status == .enabled || status == .requiresApproval)
        self.registrationStatus = Self.describe(status)

        // Background Agent Status
        // plist name must include the .plist extension per Apple documentation
        let agent = SMAppService.agent(plistName: Self.backgroundAgentPlistName)
        let aStatus = agent.status
        self.isBackgroundAgentEnabled = (aStatus == .enabled)
        self.agentStatus = Self.describe(aStatus)
        
        DebugLogger.log("Login Item status: Main App \(registrationStatus), Background Agent \(agentStatus)")
    }
    
    private nonisolated static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "Enabled"
        case .notRegistered: return "Not Registered"
        case .notFound: return "Not Found"
        case .requiresApproval: return "Requires Approval"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Toggle

    /// Toggles the launch-at-login registration state.
    /// Registers the app as a login item if currently disabled, or unregisters it if enabled.
    public func toggleLaunchAtLogin() {
        setLaunchAtLogin(!isLaunchAtLoginEnabled)
    }

    /// Applies a user-driven Launch at Login change from Settings or the menu
    /// bar: writes the preference, publishes the intent immediately, and
    /// asserts the registration without waiting for the defaults observer.
    public func setLaunchAtLogin(_ enabled: Bool) {
        lastUserInitiatedLaunchAtLoginChange = Date()
        isLaunchAtLoginEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
        syncServiceRegistration(
            launchAtLogin: enabled,
            keepInBackground: UserDefaults.standard.bool(forKey: "keepInBackground"),
            initiatedByUser: true
        )
    }

    /// Synchronizes the SMAppService registration based on current settings.
    /// Launch at login uses mainApp, while background activity uses a LaunchAgent.
    /// - Parameter initiatedByUser: Pass true only when the change came from an
    ///   in-app toggle; launch-time syncs leave it false so a System Settings
    ///   opt-out is not silently re-registered.
    public func syncServiceRegistration(
        launchAtLogin: Bool,
        keepInBackground: Bool,
        showMenuBarExtra: Bool = false,
        initiatedByUser: Bool = false
    ) {
        let recentlyInitiated = lastUserInitiatedLaunchAtLoginChange.map {
            Date().timeIntervalSince($0) < Self.userInitiatedChangeWindow
        } ?? false
        let assertLaunchRegistration = initiatedByUser || recentlyInitiated
        serviceSyncGeneration &+= 1
        let generation = serviceSyncGeneration
        serviceSyncTask?.cancel()
        serviceSyncTask = Task { [weak self] in
            let status = await Task.detached(priority: .utility) {
                Self.synchronizeServiceRegistration(
                    launchAtLogin: launchAtLogin,
                    keepInBackground: keepInBackground,
                    assertLaunchRegistration: assertLaunchRegistration
                )
            }.value

            guard let self,
                  !Task.isCancelled,
                  generation == self.serviceSyncGeneration else {
                return
            }
            // Preference corrections land here, after the generation guard, so
            // a slow launch-time sync cannot undo a fresh user toggle.
            if let corrected = status.launchAtLoginPreference,
               UserDefaults.standard.bool(forKey: "launchAtLogin") != corrected {
                UserDefaults.standard.set(corrected, forKey: "launchAtLogin")
            }
            self.isLaunchAtLoginEnabled = status.isLaunchAtLoginEnabled
            self.isBackgroundAgentEnabled = status.isBackgroundAgentEnabled
            self.registrationStatus = status.registrationStatus
            self.agentStatus = status.agentStatus
            DebugLogger.log(
                "Login Item status: Main App \(status.registrationStatus), Background Agent \(status.agentStatus)"
            )
        }
    }

    private nonisolated static func synchronizeServiceRegistration(
        launchAtLogin: Bool,
        keepInBackground: Bool,
        assertLaunchRegistration: Bool
    ) -> LoginItemServiceStatus {
        // 1. Sync Login Item (mainApp)
        let mainAppStatus = SMAppService.mainApp.status
        var launchAtLoginPreference: Bool?

        if launchAtLogin && (mainAppStatus == .notRegistered || mainAppStatus == .notFound) {
            if assertLaunchRegistration {
                try? SMAppService.mainApp.register()
                DebugLogger.log("Registered main app service (Login Item)")
            } else {
                // The user removed Sorty from Login Items in System Settings
                // (or a previous registration never completed). Re-registering
                // here would silently undo that opt-out.
                launchAtLoginPreference = false
                DebugLogger.log("Login item is not registered; keeping the user's opt-out")
            }
        } else if launchAtLogin && mainAppStatus == .requiresApproval {
            DebugLogger.log("Login item registration requires user approval in System Settings")
        } else if !launchAtLogin && (mainAppStatus == .enabled || mainAppStatus == .requiresApproval) {
            if assertLaunchRegistration {
                try? SMAppService.mainApp.unregister()
                DebugLogger.log("Unregistered main app service (Login Item)")
            } else {
                // Enabled from System Settings while Sorty was closed; publish
                // the real state instead of immediately undoing the opt-in.
                launchAtLoginPreference = true
                DebugLogger.log("Login item is registered; keeping the user's opt-in")
            }
        }

        // Migrate off the legacy agent plist that reused the app's service label.
        let legacyAgent = SMAppService.agent(plistName: Self.legacyBackgroundAgentPlistName)
        let legacyAgentStatus = legacyAgent.status
        if legacyAgentStatus == .enabled || legacyAgentStatus == .requiresApproval {
            do {
                try legacyAgent.unregister()
                DebugLogger.log("Removed legacy Sorty background agent registration")
            } catch {
                DebugLogger.log("Failed to remove legacy background agent registration: \(error.localizedDescription)")
            }
        }

        // 2. Sync Background Activity (Agent)
        // Background permission is required for keepInBackground logic to work reliably
        // Decoupled from showMenuBarExtra to give user control over System Settings entry
        let agent = SMAppService.agent(plistName: Self.backgroundAgentPlistName)
        let shouldBeBackgroundAgent = keepInBackground
        let agentCurrentStatus = agent.status
        let registeredBundleProgram = UserDefaults.standard.string(forKey: Self.registeredBackgroundAgentBundleProgramKey)
        let needsAgentRegistrationRefresh = registeredBundleProgram != Self.backgroundAgentBundleProgram

        if shouldBeBackgroundAgent && agentCurrentStatus == .enabled && needsAgentRegistrationRefresh {
            do {
                try agent.unregister()
                try agent.register()
                UserDefaults.standard.set(Self.backgroundAgentBundleProgram, forKey: Self.registeredBackgroundAgentBundleProgramKey)
                DebugLogger.log("Refreshed agent service registration (Background Activity)")
            } catch {
                DebugLogger.log("Failed to refresh background agent registration: \(error.localizedDescription)")
            }
        } else if shouldBeBackgroundAgent && (agentCurrentStatus == .notRegistered || agentCurrentStatus == .notFound) {
            do {
                try agent.register()
                UserDefaults.standard.set(Self.backgroundAgentBundleProgram, forKey: Self.registeredBackgroundAgentBundleProgramKey)
                DebugLogger.log("Registered agent service (Background Activity)")
            } catch {
                DebugLogger.log("Failed to register background agent: \(error.localizedDescription)")
            }
        } else if shouldBeBackgroundAgent && agentCurrentStatus == .requiresApproval {
            DebugLogger.log("Background agent registration requires user approval in System Settings")
        } else if !shouldBeBackgroundAgent && (agentCurrentStatus == .enabled || agentCurrentStatus == .requiresApproval) {
            do {
                try agent.unregister()
                UserDefaults.standard.removeObject(forKey: Self.registeredBackgroundAgentBundleProgramKey)
                DebugLogger.log("Unregistered agent service (Background Activity)")
            } catch {
                DebugLogger.log("Failed to unregister background agent: \(error.localizedDescription)")
            }
        }

        let finalMainAppStatus = SMAppService.mainApp.status
        let finalAgentStatus = agent.status
        return LoginItemServiceStatus(
            // `.requiresApproval` counts as registered so the published toggle
            // reflects the stored preference and can be turned back off.
            isLaunchAtLoginEnabled: finalMainAppStatus == .enabled || finalMainAppStatus == .requiresApproval,
            isBackgroundAgentEnabled: finalAgentStatus == .enabled,
            registrationStatus: describe(finalMainAppStatus),
            agentStatus: describe(finalAgentStatus),
            launchAtLoginPreference: launchAtLoginPreference
        )
    }

    // MARK: - Settings

    /// Opens the macOS Login Items settings pane in System Settings.
    public func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Background Activity
    // Deprecated: use syncServiceRegistration instead
}

// MARK: - UserDefaults Extensions

extension UserDefaults {
    @objc dynamic var keepInBackground: Bool {
        bool(forKey: "keepInBackground")
    }
    
    @objc dynamic var launchAtLogin: Bool {
        bool(forKey: "launchAtLogin")
    }
    
    @objc dynamic var showMenuBarExtra: Bool {
        bool(forKey: "showMenuBarExtra")
    }
}
