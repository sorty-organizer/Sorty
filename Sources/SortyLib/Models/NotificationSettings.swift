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
/// Construction stays scalar-only for fast launch; persisted state loads
/// via `loadPersistedState()` after the first frame.
@MainActor
public class NotificationSettingsManager: ObservableObject {
    @Published public var settings: NotificationSettings = .default {
        didSet {
            save()
        }
    }

    @Published public private(set) var hasLoadedPersistedState = false

    private let userDefaults = UserDefaults.standard
    private let persistedDataReader = UserDefaultsDataReader(UserDefaults.standard)
    private let settingsKey = "notificationSettings"
    private var loadTask: Task<NotificationSettings?, Never>?
    private var loadGeneration = 0
    private var hasPendingChanges = false

    public static let shared = NotificationSettingsManager()

    private init() {
        setupNotificationObservers()
    }

    /// Decodes settings away from the main actor. Idempotent; a second caller
    /// awaits the existing task. Edits made during hydration win over disk.
    public func loadPersistedState() async {
        guard !hasLoadedPersistedState else { return }

        let generation = loadGeneration
        let initialSettings = settings
        let task: Task<NotificationSettings?, Never>
        if let loadTask {
            task = loadTask
        } else {
            let reader = persistedDataReader
            let key = settingsKey
            task = Task.detached(priority: .userInitiated) {
                guard let data = reader.data(forKey: key),
                      let decoded = try? JSONDecoder().decode(NotificationSettings.self, from: data) else {
                    return nil
                }
                return decoded
            }
            self.loadTask = task
        }

        let persisted = await task.value
        guard !hasLoadedPersistedState, generation == loadGeneration else { return }

        if settings != initialSettings {
            // Edited during hydration; keep in-memory changes and persist them.
            hasPendingChanges = true
        } else if let persisted {
            settings = persisted
        }

        hasLoadedPersistedState = true
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
        guard hasLoadedPersistedState else {
            hasPendingChanges = true
            return
        }
        if let encoded = try? JSONEncoder().encode(settings) {
            userDefaults.set(encoded, forKey: settingsKey)
        }
    }

    public func reset() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        hasLoadedPersistedState = true
        hasPendingChanges = false
        settings = .default
        userDefaults.removeObject(forKey: settingsKey)
    }
}
