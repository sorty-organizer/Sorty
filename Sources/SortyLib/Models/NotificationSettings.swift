//
//  NotificationSettings.swift
//  Sorty
//
//  Notification preferences for the app
//

import Foundation
import Combine

/// Notification settings model for user preferences
public struct NotificationSettings: Codable, Equatable, Sendable {
    // MARK: - Delivery Method
    
    /// Show notifications as subtle bottom-left overlays
    public var inAppHUD: Bool = true
    
    /// Show in macOS Notification Center
    public var systemNotifications: Bool = true
    
    /// Show action buttons on notifications (Undo, Open Folder, etc.)
    public var showActionButtons: Bool = true
    
    // MARK: - Notification Types
    
    /// When file processing finishes successfully
    public var processingComplete: Bool = true
    
    /// When AI has finished generating a plan and it's ready for review
    public var previewReady: Bool = true
    
    /// Show preview ready notification even when app is in foreground
    public var showPreviewReadyInForeground: Bool = true
    
    /// When errors occur during processing
    public var processingErrors: Bool = true
    
    /// Summary notification after processing multiple files
    public var batchSummary: Bool = true

    /// Specifically notify when automatic organization (watched folders) occurs
    public var notifyOnAutoOrganize: Bool = true

    /// Notify when a watched folder begins organizing newly detected files.
    public var notifyOnWatchedFolderStart: Bool?

    /// Notify when a watched folder finishes organizing detected files.
    public var notifyOnWatchedFolderCompletion: Bool?

    public var watchedFolderStartNotificationsEnabled: Bool {
        get { notifyOnWatchedFolderStart ?? notifyOnAutoOrganize }
        set { notifyOnWatchedFolderStart = newValue }
    }

    public var watchedFolderCompletionNotificationsEnabled: Bool {
        get { notifyOnWatchedFolderCompletion ?? notifyOnAutoOrganize }
        set { notifyOnWatchedFolderCompletion = newValue }
    }
    
    /// Display critical errors even if notifications are off
    public var alwaysShowCriticalErrors: Bool = true
    
    // MARK: - Sounds
    
    /// Play sound with system notifications
    public var systemNotificationSounds: Bool = true
    
    /// Play sound with in-app HUD notifications
    public var hudSounds: Bool = false
    
    /// Play a satisfying "ting" sound when organization completes successfully
    public var playCompletionSound: Bool = true
    
    public init() {}

    @MainActor
    public static let `default` = NotificationSettings()
}

/// Manager for notification settings
@MainActor
public class NotificationSettingsManager: ObservableObject {
    @Published public var settings: NotificationSettings = .default {
        didSet {
            save()
        }
    }

    private let userDefaults = UserDefaults.standard
    private let settingsKey = "notificationSettings"
    private var hasLoaded = false
    private var hasPendingChanges = false
    private var loadGeneration = 0
    private var loadTask: Task<NotificationSettings?, Never>?

    public static let shared = NotificationSettingsManager()

    private init() {
        // Lightweight init with in-memory defaults; persisted state arrives
        // via `loadPersistedState()` after first paint.
        setupNotificationObservers()
    }

    /// Decodes persisted settings off the main actor. Preserves edits made
    /// before hydration finishes and invalidates stale results on reset.
    public func loadPersistedState() async {
        guard !hasLoaded else { return }
        let generation = loadGeneration
        let task: Task<NotificationSettings?, Never>
        if let loadTask {
            task = loadTask
        } else {
            let userDefaults = userDefaults
            let settingsKey = settingsKey
            task = Task.detached(priority: .userInitiated) {
                guard let data = userDefaults.data(forKey: settingsKey) else { return nil }
                return try? JSONDecoder().decode(NotificationSettings.self, from: data)
            }
            self.loadTask = task
        }
        let preHydration = settings
        let decoded = await task.value
        guard !hasLoaded, generation == loadGeneration else { return }
        // Preserve any preference edit made before hydration finishes.
        if settings != preHydration {
            hasLoaded = true
            loadTask = nil
            save()
            return
        }
        if let decoded {
            // Suppress didSet save until hydrated flag is set.
            hasLoaded = true
            settings = decoded
        } else {
            hasLoaded = true
        }
        loadTask = nil
        if hasPendingChanges {
            hasPendingChanges = false
            save()
        }
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addMainActorObserver(forName: .clearAllUsageData, object: nil, queue: .main) { [weak self] in
            self?.reset()
        }
    }

    private func save() {
        // Hold edits made before hydration so an early mutation cannot
        // overwrite saved configuration with defaults.
        guard hasLoaded else {
            hasPendingChanges = true
            return
        }
        if let encoded = try? JSONEncoder().encode(settings) {
            userDefaults.set(encoded, forKey: settingsKey)
        }
    }

    public func reset() {
        // Invalidate any in-flight load so deleted data cannot reappear.
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        hasLoaded = true
        hasPendingChanges = false
        settings = .default
    }
}
