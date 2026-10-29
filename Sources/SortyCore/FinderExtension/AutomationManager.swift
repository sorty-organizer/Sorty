//
//  AutomationManager.swift
//  Sorty
//
//  Manager for automation permissions and Finder integration
//  Handles Automation (Finder control) permissions
//

import Foundation
import AppKit
import Combine

/// Manager for automation features and permissions
/// Injected via @EnvironmentObject at app root
@MainActor
public final class AutomationManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published public private(set) var automationStatus: PermissionStatus = .unknown
    @Published public private(set) var statusMessage: String = "Waiting for permission check"
    @Published public private(set) var lastPermissionError: String?
    
    // MARK: - Private Properties
    
    private var isInitializing = true
    private var isStartedUp = false
    private var automationChecksEnabled = false
    
    // MARK: - UserDefaults Keys
    
    private let autoSelectOrganizedFoldersKey = "automation.autoSelectOrganizedFolders"
    private let autoSelectOptInMigrationKey = "automation.autoSelectOrganizedFoldersMigratedToOptIn"
    private let previouslyGrantedKey = "automation.previouslyGranted"
    
    // MARK: - Settings
    
    @Published public var autoSelectOrganizedFolders: Bool {
        didSet {
            guard !isInitializing else { return }
            UserDefaults.standard.set(autoSelectOrganizedFolders, forKey: autoSelectOrganizedFoldersKey)
        }
    }
    
    // MARK: - Initialization
    
    public init() {
        let defaults = UserDefaults.standard

        // Load settings from UserDefaults
        self.autoSelectOrganizedFolders = defaults.object(forKey: autoSelectOrganizedFoldersKey) as? Bool ?? false
        self.automationChecksEnabled = defaults.bool(forKey: previouslyGrantedKey)
        if automationChecksEnabled {
            FinderAutomation.enableAutomationChecks()
        }

        // One-time migration: switch post-organization Finder reveal to opt-in.
        if !defaults.bool(forKey: autoSelectOptInMigrationKey) {
            self.autoSelectOrganizedFolders = false
            defaults.set(false, forKey: autoSelectOrganizedFoldersKey)
            defaults.set(true, forKey: autoSelectOptInMigrationKey)
        }
        isInitializing = false
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Lifecycle
    
    /// Called after app launch; automation checks remain gated by user intent.
    public func startUp() {
        isStartedUp = true

        if automationChecksEnabled {
            checkPermissions()
        }
        
        // Register the notification observer here instead of init() to avoid
        // permission checks firing during SwiftUI view graph construction
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    // MARK: - Permission Management

    private func enableAutomationChecksIfNeeded() {
        guard !automationChecksEnabled else { return }
        automationChecksEnabled = true
        FinderAutomation.enableAutomationChecks()
    }
    
    /// Check Automation permission status
    public func checkPermissions(enableChecksIfNeeded: Bool = false) {
        if enableChecksIfNeeded {
            enableAutomationChecksIfNeeded()
        }

        automationStatus = FinderAutomation.checkAutomationPermission()
        switch automationStatus {
        case .granted:
            statusMessage = "Finder automation permission granted"
            lastPermissionError = nil
        case .denied:
            statusMessage = "Finder automation permission denied"
            lastPermissionError = "Grant Finder automation in System Settings > Privacy & Security > Automation."
        case .unknown:
            statusMessage = automationChecksEnabled
                ? "Finder automation permission status unavailable"
                : "Finder automation permission not yet checked"
            lastPermissionError = nil
        }
        if automationStatus == .granted {
            UserDefaults.standard.set(true, forKey: previouslyGrantedKey)
        }
    }

    /// Explicitly trigger automation permission checks after user intent
    public func requestAutomationPermissionCheck() async {
        enableAutomationChecksIfNeeded()
        automationStatus = await FinderAutomation.requestAutomationPermission()
        switch automationStatus {
        case .granted:
            statusMessage = "Finder automation ready"
            lastPermissionError = nil
        case .denied:
            statusMessage = "Finder automation denied"
            lastPermissionError = "Automation permission was denied. Open System Settings to allow Finder control."
        case .unknown:
            statusMessage = "Waiting for automation decision"
        }
        if automationStatus == .granted {
            UserDefaults.standard.set(true, forKey: previouslyGrantedKey)
        }
    }

    /// Open System Settings to Automation permissions
    public func openAutomationSettings(
        sourceFrameInScreen: CGRect? = nil,
        onMissingApp: @escaping () -> Void = {}
    ) {
        FinderAutomation.openAutomationSettings(
            sourceFrameInScreen: sourceFrameInScreen,
            onMissingApp: onMissingApp
        )
    }
    
    // MARK: - Post-Organization Actions
    
    /// Select organized folders in Finder after organization completes
    public func selectOrganizedFolders(folderURLs: [URL]) {
        guard automationStatus == .granted else { return }
        guard autoSelectOrganizedFolders else { return }
        guard !folderURLs.isEmpty else { return }
        
        FinderAutomation.selectInFinder(urls: folderURLs, reveal: true)
        DebugLogger.log("Selected \(folderURLs.count) organized folders in Finder")
    }
    
    /// Refresh Finder windows showing the organized path
    public func refreshFinder(at url: URL) {
        guard automationStatus == .granted else { return }
        FinderAutomation.refreshFinder(at: url)
    }

    /// Updates Sorty's in-memory state after its Finder Automation TCC decision is reset.
    public func markAutomationPermissionReset() {
        automationStatus = .unknown
        statusMessage = "Finder automation permission removed"
        lastPermissionError = nil
        UserDefaults.standard.removeObject(forKey: previouslyGrantedKey)
    }
    
    // MARK: - Notification Handler
    
    @objc private func appDidBecomeActive() {
        Task { @MainActor [weak self] in
            guard let self = self, self.isStartedUp else { return }
            guard self.automationChecksEnabled else { return }
            self.checkPermissions()
        }
    }
}

// MARK: - PermissionStatus Extension

extension PermissionStatus: Equatable {
    public static func == (lhs: PermissionStatus, rhs: PermissionStatus) -> Bool {
        switch (lhs, rhs) {
        case (.granted, .granted), (.denied, .denied), (.unknown, .unknown):
            return true
        default:
            return false
        }
    }
}

extension PermissionStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .granted:
            return "Granted"
        case .denied:
            return "Denied"
        case .unknown:
            return "Unknown"
        }
    }
}
