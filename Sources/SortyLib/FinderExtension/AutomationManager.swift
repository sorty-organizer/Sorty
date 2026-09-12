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
    @Published public private(set) var selectedFinderItems: [URL] = []
    @Published public private(set) var hasValidFinderSelection: Bool = false
    @Published public private(set) var statusMessage: String = "Waiting for permission check"
    @Published public private(set) var lastPermissionError: String?
    @Published public private(set) var lastSelectionRefresh: Date?
    
    // MARK: - Private Properties
    
    private var selectionCheckTimer: Timer?
    private var selectionRefreshTask: Task<Void, Never>?
    private var selectionMonitoringDemandCount = 0
    private let selectionCheckInterval: TimeInterval = 8.0
    private var isInitializing = true
    private var isStartedUp = false
    private var automationChecksEnabled = false
    private var isApplicationActive = NSApp.isActive
    
    // MARK: - UserDefaults Keys
    
    private let enableSelectionMonitoringKey = "automation.enableSelectionMonitoring"
    private let autoSelectOrganizedFoldersKey = "automation.autoSelectOrganizedFolders"
    private let autoSelectOptInMigrationKey = "automation.autoSelectOrganizedFoldersMigratedToOptIn"
    private let previouslyGrantedKey = "automation.previouslyGranted"
    
    // MARK: - Settings
    
    @Published public var enableSelectionMonitoring: Bool {
        didSet {
            guard !isInitializing else { return }
            UserDefaults.standard.set(enableSelectionMonitoring, forKey: enableSelectionMonitoringKey)
            guard isStartedUp else { return }
            if enableSelectionMonitoring && selectionMonitoringDemandCount > 0 {
                startSelectionMonitoring()
            } else {
                stopSelectionMonitoring()
            }
        }
    }
    
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
        self.enableSelectionMonitoring = defaults.bool(forKey: enableSelectionMonitoringKey)
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
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

        if isStartedUp,
           enableSelectionMonitoring,
           selectionMonitoringDemandCount > 0,
           automationStatus == .granted {
            startSelectionMonitoring()
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
    
    // MARK: - Finder Selection

    /// Retain Finder selection updates while a visible feature consumes them.
    public func beginSelectionMonitoring() {
        selectionMonitoringDemandCount += 1
        guard selectionMonitoringDemandCount == 1, enableSelectionMonitoring else { return }
        startSelectionMonitoring()
    }

    /// Release a feature's interest without stopping updates needed elsewhere.
    public func endSelectionMonitoring() {
        selectionMonitoringDemandCount = max(0, selectionMonitoringDemandCount - 1)
        if selectionMonitoringDemandCount == 0 {
            stopSelectionMonitoring()
        }
    }
    
    /// Start monitoring Finder selection periodically
    public func startSelectionMonitoring() {
        guard selectionMonitoringDemandCount > 0 else {
            pauseSelectionMonitoring()
            return
        }
        guard automationChecksEnabled else {
            DebugLogger.log("Automation checks not enabled; deferring selection monitoring")
            statusMessage = "Selection monitoring deferred until permission check"
            return
        }
        guard automationStatus == .granted else {
            DebugLogger.log("Cannot start selection monitoring: Automation permission not granted")
            statusMessage = "Selection monitoring unavailable (permission not granted)"
            return
        }
        guard isApplicationActive else {
            pauseSelectionMonitoring()
            return
        }
        
        pauseSelectionMonitoring()
        
        // Check immediately
        updateFinderSelection()
        
        // Setup timer for periodic checks
        selectionCheckTimer = Timer.scheduledTimer(
            withTimeInterval: selectionCheckInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isApplicationActive else { return }
                self.updateFinderSelection()
            }
        }
        selectionCheckTimer?.tolerance = selectionCheckInterval * 0.3
        statusMessage = "Monitoring Finder selection"
    }
    
    /// Stop monitoring Finder selection
    public func stopSelectionMonitoring() {
        pauseSelectionMonitoring()
        selectedFinderItems = []
        hasValidFinderSelection = false
        statusMessage = "Finder selection monitoring paused"
    }
    
    /// Manually update the Finder selection
    public func updateFinderSelection() {
        guard automationStatus == .granted else {
            statusMessage = "Cannot refresh Finder selection without permission"
            return
        }

        guard selectionRefreshTask == nil else { return }
        selectionRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let selection = await FinderAutomation.getSelectedFiles()
            guard !Task.isCancelled else { return }
            applyFinderSelection(selection)
            selectionRefreshTask = nil
        }
    }

    private func applyFinderSelection(_ selection: [URL]?) {
        let updatedItems = selection ?? []
        let updatedHasValidSelection = !updatedItems.isEmpty
        let updatedStatus = selection == nil
            ? "Finder selection unavailable"
            : updatedItems.isEmpty
                ? "Finder selection is empty"
                : "Finder selection updated (\(updatedItems.count) item\(updatedItems.count == 1 ? "" : "s"))"

        guard updatedItems != selectedFinderItems
                || updatedHasValidSelection != hasValidFinderSelection
                || updatedStatus != statusMessage
        else { return }

        selectedFinderItems = updatedItems
        hasValidFinderSelection = updatedHasValidSelection
        lastSelectionRefresh = Date()
        statusMessage = updatedStatus
    }

    private func pauseSelectionMonitoring() {
        selectionCheckTimer?.invalidate()
        selectionCheckTimer = nil
        selectionRefreshTask?.cancel()
        selectionRefreshTask = nil
    }
    
    /// Get the path of the frontmost Finder window
    public func getFrontmostFinderWindow() -> URL? {
        guard automationStatus == .granted else { return nil }
        return FinderAutomation.getFrontmostFinderWindowPath()
    }
    
    /// Check if current selection is a valid organization target
    public func canOrganizeSelection() -> Bool {
        return hasValidFinderSelection && automationStatus == .granted
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
    
    /// Reveal a specific file or folder in Finder
    public func revealInFinder(url: URL) {
        guard automationStatus == .granted else { return }
        FinderAutomation.revealInFinder(url: url)
    }
    
    /// Open a folder in a new Finder window
    public func openInNewFinderWindow(url: URL) {
        guard automationStatus == .granted else { return }
        FinderAutomation.openInNewFinderWindow(url: url)
    }
    
    /// Refresh Finder windows showing the organized path
    public func refreshFinder(at url: URL) {
        guard automationStatus == .granted else { return }
        FinderAutomation.refreshFinder(at: url)
    }

    /// Attempt recovery from stale/denied automation states without app restart.
    public func recoverAutomationState() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await recoverAutomationStateAfterPermissionRequest()
        }
    }

    private func recoverAutomationStateAfterPermissionRequest() async {
        await requestAutomationPermissionCheck()

        guard automationStatus == .granted else {
            if automationStatus == .denied {
                statusMessage = "Automation still denied. Open System Settings to allow Finder control."
            }
            return
        }

        if enableSelectionMonitoring && selectionMonitoringDemandCount > 0 {
            startSelectionMonitoring()
        } else {
            updateFinderSelection()
        }
        statusMessage = "Automation state refreshed"
    }

    /// Updates Sorty's in-memory state after its Finder Automation TCC decision is reset.
    public func markAutomationPermissionReset() {
        stopSelectionMonitoring()
        automationStatus = .unknown
        statusMessage = "Finder automation permission removed"
        lastPermissionError = nil
        UserDefaults.standard.removeObject(forKey: previouslyGrantedKey)
    }
    
    // MARK: - Notification Handler
    
    @objc private func appDidBecomeActive() {
        Task { @MainActor [weak self] in
            guard let self = self, self.isStartedUp else { return }
            self.isApplicationActive = true
            guard self.automationChecksEnabled else { return }
            self.checkPermissions()

            if self.enableSelectionMonitoring,
               self.selectionMonitoringDemandCount > 0,
               self.automationStatus == .granted {
                self.startSelectionMonitoring()
            }
        }
    }

    @objc private func appDidResignActive() {
        isApplicationActive = false
        pauseSelectionMonitoring()
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
