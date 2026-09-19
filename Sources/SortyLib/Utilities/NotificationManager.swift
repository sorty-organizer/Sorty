//
//  NotificationManager.swift
//  Sorty
//
//  Unified notification manager for HUD and system notifications
//  Supports native macOS notifications and in-app HUD overlays.
//

import Foundation
import Combine
import SwiftUI
@preconcurrency import UserNotifications
@preconcurrency import AppKit

// MARK: - Notification Names for Actions

public extension NSNotification.Name {
    /// Posted when user clicks "Undo" on a notification
    static let undoLastOrganization = NSNotification.Name("SortyUndoLastOrganization")

    /// Posted when a notification action should open an in-app undo confirmation first
    static let requestUndoOrganizationConfirmation = NSNotification.Name("SortyRequestUndoOrganizationConfirmation")
    
    /// Posted when user clicks "Retry" on an error notification
    static let retryLastOrganization = NSNotification.Name("SortyRetryLastOrganization")

    /// Posted when a notification action should open an in-app retry confirmation first
    static let requestRetryOrganizationConfirmation = NSNotification.Name("SortyRequestRetryOrganizationConfirmation")
    
    /// Posted when user clicks "Show Details" on a notification
    static let showOrganizationDetails = NSNotification.Name("SortyShowOrganizationDetails")

    /// Posted when user clicks "Review/Preview" on a notification
    static let showOrganizationPreview = NSNotification.Name("SortyShowOrganizationPreview")

    /// Posted when a notification action should open an in-app apply confirmation first
    static let requestApplyOrganizationConfirmation = NSNotification.Name("SortyRequestApplyOrganizationConfirmation")
    
    /// Posted when user clicks "Open Folder" on a notification
    static let openOrganizedFolder = NSNotification.Name("SortyOpenOrganizedFolder")

    /// Posted when user wants to redo the last organization using a different model
    static let redoOrganizationWithModel = NSNotification.Name("SortyRedoOrganizationWithModel")

    /// Posted when a notification action should open an in-app redo confirmation first
    static let requestRedoOrganizationWithModelConfirmation = NSNotification.Name("SortyRequestRedoOrganizationWithModelConfirmation")
}

/// Detailed statistics for batch organization summary
public struct BatchSummaryStats: Codable, Sendable {
    public let filesMoved: Int
    public let foldersCreated: Int
    public let filesRenamed: Int
    public let filesTagged: Int
    public let duplicatesFound: Int
    public let errorsEncountered: Int
    public let duration: TimeInterval
    public let folderName: String
    public let folderPath: String?
    public let canUndo: Bool
    
    public init(
        filesMoved: Int = 0,
        foldersCreated: Int = 0,
        filesRenamed: Int = 0,
        filesTagged: Int = 0,
        duplicatesFound: Int = 0,
        errorsEncountered: Int = 0,
        duration: TimeInterval = 0,
        folderName: String = "",
        folderPath: String? = nil,
        canUndo: Bool = false
    ) {
        self.filesMoved = filesMoved
        self.foldersCreated = foldersCreated
        self.filesRenamed = filesRenamed
        self.filesTagged = filesTagged
        self.duplicatesFound = duplicatesFound
        self.errorsEncountered = errorsEncountered
        self.duration = duration
        self.folderName = folderName
        self.folderPath = folderPath
        self.canUndo = canUndo
    }
    
    /// Total number of operations performed
    public var totalOperations: Int {
        filesMoved + filesRenamed + filesTagged
    }
    
    /// Whether the batch had any errors
    public var hasErrors: Bool {
        errorsEncountered > 0
    }
    
    /// Whether the batch was successful (at least some operations completed)
    public var isSuccessful: Bool {
        totalOperations > 0 || foldersCreated > 0
    }
}

/// Actions that can be performed from notification buttons
public enum NotificationAction: Sendable {
    case apply
    case undo
    case openFolder(path: String)
    case showDetails
    case retry
    case redoWithModel
    case dismiss
}

/// Callback type for handling notification actions
public typealias NotificationActionHandler = @Sendable (NotificationAction) async -> Void

private enum NativeNotificationActionIdentifier {
    static let apply = "SORTY_APPLY"
    static let undo = "SORTY_UNDO"
    static let undoAll = "SORTY_UNDO_ALL"
    static let openFolder = "SORTY_OPEN_FOLDER"
    static let retry = "SORTY_RETRY"
    static let showDetails = "SORTY_SHOW_DETAILS"
    static let review = "SORTY_REVIEW"
    static let redoModel = "SORTY_REDO_MODEL"
}

private enum NativeNotificationUserInfoKey {
    static let folderPath = "folderPath"
    static let folderName = "folderName"
    static let notificationType = "notificationType"
    static let fileCount = "fileCount"
    static let canUndo = "canUndo"
    static let isAutomated = "isAutomated"
    static let message = "message"
    static let isCritical = "isCritical"
    static let canRetry = "canRetry"
    static let batchStats = "batchStats"
    static let planID = "planID"
    static let isWatchedReview = "isWatchedReview"
    static let originSessionID = "originSessionID"
}

private enum CuratedNotificationActionRole {
    case safeImmediate
    case guardedConfirmation
    case deferredNavigation
}

private struct CuratedNotificationAction {
    let label: String
    let identifier: String
    let action: NotificationAction
    let role: CuratedNotificationActionRole
    let confirmationNotificationName: NSNotification.Name?
}

private enum NotificationFailureClass {
    case timeout
    case configuration
    case permissions
    case filesystem
    case aiModel
    case unknown

    init(message: String) {
        let normalized = message.lowercased()

        if normalized.contains("timed out") || normalized.contains("timeout") {
            self = .timeout
        } else if normalized.contains("no ai provider") ||
                    normalized.contains("api key") ||
                    normalized.contains("not configured") ||
                    normalized.contains("configuration") ||
                    normalized.contains("model") && normalized.contains("unavailable") {
            self = .configuration
        } else if normalized.contains("permission") ||
                    normalized.contains("access denied") ||
                    normalized.contains("security scoped") ||
                    normalized.contains("not authorized") {
            self = .permissions
        } else if normalized.contains("file") ||
                    normalized.contains("folder") ||
                    normalized.contains("directory") ||
                    normalized.contains("disk") ||
                    normalized.contains("exist") {
            self = .filesystem
        } else if normalized.contains("rate limit") ||
                    normalized.contains("server") ||
                    normalized.contains("network") ||
                    normalized.contains("overloaded") ||
                    normalized.contains("context") {
            self = .aiModel
        } else {
            self = .unknown
        }
    }

    var shouldOfferRetry: Bool {
        switch self {
        case .configuration, .permissions:
            return false
        case .timeout, .filesystem, .aiModel, .unknown:
            return true
        }
    }

    var shouldOfferRedoWithModel: Bool {
        switch self {
        case .timeout, .aiModel, .unknown:
            return true
        case .configuration, .permissions, .filesystem:
            return false
        }
    }
}

private final class NativeNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private final class CompletionHandlerBox: @unchecked Sendable {
        let handler: () -> Void

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let completion = CompletionHandlerBox(completionHandler)
        Task { @MainActor in
            NotificationManager.shared.handleNativeNotificationResponse(response)
            completion.handler()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil {
            options.insert(.sound)
        }
        completionHandler(options)
    }
}

    /// Types of notifications the app can show
    public enum NotificationType: Sendable {
        case processingComplete(fileCount: Int, folderName: String, folderPath: String?, canUndo: Bool, isAutomated: Bool = false)
        case previewReady(
            folderName: String,
            folderPath: String? = nil,
            planID: UUID? = nil,
            originSessionID: UUID? = nil,
            isWatchedReview: Bool = false
        )
        case processingError(message: String, folderPath: String? = nil, isCritical: Bool, canRetry: Bool, isAutomated: Bool = false)
        case batchSummary(stats: BatchSummaryStats, isAutomated: Bool = false)
        case watchedFolderStarted(fileCount: Int, folderName: String, folderPath: String)
        case info(title: String, message: String)
        
        // Legacy initializers for backwards compatibility
        public static func processingComplete(fileCount: Int, folderName: String) -> NotificationType {
            return .processingComplete(fileCount: fileCount, folderName: folderName, folderPath: nil, canUndo: false, isAutomated: false)
        }
        
        public static func processingError(message: String, isCritical: Bool = false) -> NotificationType {
            return .processingError(message: message, folderPath: nil, isCritical: isCritical, canRetry: false, isAutomated: false)
        }
        
        public static func batchSummary(processed: Int, errors: Int, duration: TimeInterval) -> NotificationType {
            return .batchSummary(stats: BatchSummaryStats(
                filesMoved: processed,
                errorsEncountered: errors,
                duration: duration
            ), isAutomated: false)
        }
        
        var isCritical: Bool {
            if case .processingError(_, _, let critical, _, _) = self {
                return critical
            }
            return false
        }

        var folderPath: String? {
            switch self {
            case .processingComplete(_, _, let folderPath, _, _):
                return folderPath
            case .previewReady(_, let folderPath, _, _, _):
                return folderPath
            case .processingError(_, let folderPath, _, _, _):
                return folderPath
            case .batchSummary(let stats, _):
                return stats.folderPath
            case .watchedFolderStarted(_, _, let folderPath):
                return folderPath
            case .info:
                return nil
            }
        }

        var isAutomated: Bool {
            switch self {
            case .processingComplete(_, _, _, _, let isAutomated),
                 .processingError(_, _, _, _, let isAutomated),
                 .batchSummary(_, let isAutomated):
                return isAutomated
            case .watchedFolderStarted:
                return true
            case .previewReady, .info:
                return false
            }
        }
        
        /// Whether the app is currently in the foreground
        @MainActor
        private static var isAppActive: Bool {
            return NSApplication.shared.isActive
        }
        
        /// Should this notification be shown as a system notification?
        @MainActor
        var shouldShowSystem: Bool {
            // Always show if backgrounded or if it's a critical error
            if !Self.isAppActive || isCritical {
                return true
            }
            
            // Check if previewReady should show in foreground
            if case .previewReady = self {
                return NotificationSettingsManager.shared.settings.showPreviewReadyInForeground
            }
            
            // Otherwise, respect user settings for in-app HUD vs system
            return false
        }
    }

/// HUD notification data for display
public struct HUDNotification: Identifiable, Equatable {
    public let id = UUID()
    public let identifier: String?
    public let title: String
    public let message: String
    public let icon: String
    public let iconColor: Color
    public let timestamp: Date
    public let playSound: Bool
    public let isPersistent: Bool
    public let actions: [HUDNotificationAction]
    public let defaultAction: (@MainActor () -> Void)?

    public init(
        identifier: String? = nil,
        title: String,
        message: String,
        icon: String,
        iconColor: Color,
        timestamp: Date,
        playSound: Bool,
        isPersistent: Bool = false,
        actions: [HUDNotificationAction] = [],
        defaultAction: (@MainActor () -> Void)? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.message = message
        self.icon = icon
        self.iconColor = iconColor
        self.timestamp = timestamp
        self.playSound = playSound
        self.isPersistent = isPersistent
        self.actions = actions
        self.defaultAction = defaultAction
    }
    
    public static func == (lhs: HUDNotification, rhs: HUDNotification) -> Bool {
        lhs.id == rhs.id
    }
}

public struct HUDNotificationAction: Identifiable {
    public let id = UUID()
    public let title: String
    public let systemImage: String?
    public let role: ButtonRole?
    public let action: @MainActor () -> Void

    public init(
        title: String,
        systemImage: String? = nil,
        role: ButtonRole? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }
}

public struct NotificationAnalyticsEvent: Identifiable, Sendable {
    public enum EventType: String, Sendable {
        case shown
        case suppressed
        case action
        case failed
    }

    public let id: UUID
    public let timestamp: Date
    public let eventType: EventType
    public let backend: String
    public let notificationType: String
    public let detail: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        eventType: EventType,
        backend: String,
        notificationType: String,
        detail: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.eventType = eventType
        self.backend = backend
        self.notificationType = notificationType
        self.detail = detail
    }
}

/// Manages all app notifications (HUD overlays and system notifications)
@MainActor
public class NotificationManager: ObservableObject {
    public nonisolated static let transientHUDDuration: TimeInterval = 4
    public static let shared = NotificationManager()
    
    @Published public var currentHUDNotification: HUDNotification?
    @Published public var hudNotificationQueue: [HUDNotification] = []
    @Published public var notificationPermissionStatus: UNAuthorizationStatus = .notDetermined
    @Published public private(set) var analyticsEvents: [NotificationAnalyticsEvent] = []
    
    private var settings: NotificationSettingsManager { NotificationSettingsManager.shared }
    private var dismissTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var permissionCached: Bool = false
    private let nativeNotificationDelegate = NativeNotificationDelegate()
    private var pendingNativeActionHandlers: [String: NotificationActionHandler] = [:]
    private var pendingNativeNotificationTypes: [String: NotificationType] = [:]
    private var pendingNativeActions: [String: [CuratedNotificationAction]] = [:]
    private var registeredNativeCategories: [String: UNNotificationCategory] = [:]
    
    private init() {
        if isSafeToUseSystemNotifications {
            UNUserNotificationCenter.current().delegate = nativeNotificationDelegate
        }
        Task {
            await setupNotificationSystem()
        }
    }
    
    /// Check if it's safe to use UNUserNotificationCenter (requires bundle ID and not running in tests)
    private var isSafeToUseSystemNotifications: Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        
        // Avoid running in xctest tool environment which crashes UNUserNotificationCenter with "bundleProxyForCurrentProcess is nil"
        if bundleID == "com.apple.dt.xctest.tool" {
            return false
        }
        
        return true
    }
    
    /// Initialize the notification system (call on app startup for faster first notification)
    private func setupNotificationSystem() async {
        // Check current notification permission status (without requesting)
        if isSafeToUseSystemNotifications {
            await checkNotificationPermission()
        } else {
            DebugLogger.log("NotificationManager: Skipping system notification setup (CLI/Test environment)")
            await MainActor.run {
                self.notificationPermissionStatus = .denied
            }
        }
        
        if isSafeToUseSystemNotifications {
            DebugLogger.log("NotificationManager: Using native macOS notifications")
        }
    }
    
    // MARK: - Public API
    
    /// Check current notification permission status
    public func checkNotificationPermission() async {
        guard isSafeToUseSystemNotifications else { return }
        
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            self.notificationPermissionStatus = settings.authorizationStatus
        }
    }
    
    /// Request notification permission
    public func requestPermission() async -> Bool {
        guard isSafeToUseSystemNotifications else { return false }

        await checkNotificationPermission()
        switch notificationPermissionStatus {
        case .authorized, .provisional:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                // Use callback-based authorization request for maximum compatibility.
                let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: granted)
                        }
                    }
                }

                await checkNotificationPermission()

                // Some environments can return stale status; keep UI state actionable.
                if notificationPermissionStatus == .notDetermined {
                    notificationPermissionStatus = granted ? .authorized : .denied
                }

                return notificationPermissionStatus == .authorized || notificationPermissionStatus == .provisional || granted
            } catch {
                DebugLogger.log("NotificationManager: Failed to request permission: \(error)")
                await checkNotificationPermission()
                return notificationPermissionStatus == .authorized || notificationPermissionStatus == .provisional
            }
        @unknown default:
            return false
        }
    }
    
    /// Show a notification based on type and user preferences
    public func show(_ type: NotificationType) {
        let settingsValue = settings.settings
        
        DebugLogger.log("NotificationManager: show() called with type, inAppHUD=\(settingsValue.inAppHUD), systemNotifications=\(settingsValue.systemNotifications)")
        
        // Handle automated organization filter
        switch type {
        case .watchedFolderStarted:
            guard settingsValue.watchedFolderStartNotificationsEnabled else {
                trackAnalytics(.suppressed, type: type, backend: "native", detail: "watched folder started disabled")
                return
            }
        case .processingComplete(_, _, _, _, let isAutomated),
             .batchSummary(_, let isAutomated):
            if isAutomated && !settingsValue.watchedFolderCompletionNotificationsEnabled {
                DebugLogger.log("NotificationManager: Automated organization notification suppressed by settings")
                trackAnalytics(.suppressed, type: type, backend: "native", detail: "automated notifications disabled")
                return
            }
        case .processingError(_, _, _, _, let isAutomated):
            if isAutomated && !settingsValue.notifyOnAutoOrganize && !type.isCritical {
                DebugLogger.log("NotificationManager: Automated organization error suppressed by settings")
                trackAnalytics(.suppressed, type: type, backend: "native", detail: "automated notifications disabled")
                return
            }
        default:
            break
        }
        
        // Check if we should show this notification type
        switch type {
        case .processingComplete:
            guard settingsValue.processingComplete else {
                DebugLogger.log("NotificationManager: processingComplete notifications disabled")
                trackAnalytics(.suppressed, type: type, backend: "native", detail: "processing complete disabled")
                return
            }
        case .previewReady:
            guard settingsValue.previewReady else {
                DebugLogger.log("NotificationManager: previewReady notifications disabled")
                trackAnalytics(.suppressed, type: type, backend: "native", detail: "preview ready disabled")
                return
            }
        case .processingError(_, _, let isCritical, _, _):
            if isCritical && settingsValue.alwaysShowCriticalErrors {
                // Always show critical errors
            } else if !settingsValue.processingErrors {
                DebugLogger.log("NotificationManager: processingErrors notifications disabled")
                trackAnalytics(.suppressed, type: type, backend: "native", detail: "processing errors disabled")
                return
            }
        case .batchSummary:
            guard settingsValue.processingComplete && settingsValue.batchSummary else {
                DebugLogger.log("NotificationManager: batchSummary notifications disabled")
                trackAnalytics(.suppressed, type: type, backend: "native", detail: "batch summary disabled")
                return
            }
        case .watchedFolderStarted:
            break
        case .info:
            // Info notifications are always allowed
            break
        }
        
        // Create notification content
        let (title, message, icon, iconColor) = notificationContent(for: type)

        if shouldPlayCompletionSound(for: type) {
            playCompletionSoundIfEnabled()
        }
        
        // Show in-app HUD if enabled AND app is active
        if settingsValue.inAppHUD && NSApplication.shared.isActive {
            showHUD(
                title: title,
                message: message,
                icon: icon,
                iconColor: iconColor,
                playSound: settingsValue.hudSounds,
                defaultAction: defaultHUDAction(for: type)
            )
        } else {
            DebugLogger.log("NotificationManager: skipping HUD (inAppHUD=\(settingsValue.inAppHUD), isActive=\(NSApplication.shared.isActive))")
        }
        
        // Show system notification: always for critical errors, otherwise when enabled + shouldShow
        let isCriticalError = type.isCritical
        let isAppBackgrounded = !NSApplication.shared.isActive
        let shouldShowSystem = type.shouldShowSystem
        
        // Request user attention (dock bounce) for critical errors and key background events
        if shouldRequestAttention(for: type, isAppBackgrounded: isAppBackgrounded) {
            requestAttention(isCritical: isCriticalError)
        }
        
        if isCriticalError || (settingsValue.systemNotifications && (shouldShowSystem || isAppBackgrounded)) {
            Task {
                await showSystemNotification(
                    type: type,
                    title: title,
                    message: message,
                    playSound: settingsValue.systemNotificationSounds
                )
            }
        } else {
            DebugLogger.log("NotificationManager: skipping system notification (enabled=\(settingsValue.systemNotifications), shouldShow=\(shouldShowSystem), critical=\(isCriticalError))")
            trackAnalytics(.shown, type: type, backend: "native", detail: "hud only")
        }
    }
    
    /// Show a notification with a custom action handler
    public func show(_ type: NotificationType, actionHandler: @escaping NotificationActionHandler) {
        let settingsValue = settings.settings
        
        // Create notification content
        let (title, message, icon, iconColor) = notificationContent(for: type)

        if shouldPlayCompletionSound(for: type) {
            playCompletionSoundIfEnabled()
        }
        
        // Show in-app HUD if enabled AND app is active
        if settingsValue.inAppHUD && NSApplication.shared.isActive {
            showHUD(
                title: title,
                message: message,
                icon: icon,
                iconColor: iconColor,
                playSound: settingsValue.hudSounds,
                defaultAction: defaultHUDAction(for: type, actionHandler: actionHandler)
            )
        }
        
        // Show system notification: always for critical errors, otherwise when enabled + shouldShow or backgrounded
        let isCriticalError = type.isCritical
        let isAppBackgrounded = !NSApplication.shared.isActive

        if shouldRequestAttention(for: type, isAppBackgrounded: isAppBackgrounded) {
            requestAttention(isCritical: isCriticalError)
        }
        
        if isCriticalError || (settingsValue.systemNotifications && (type.shouldShowSystem || isAppBackgrounded)) {
            Task {
                await showSystemNotification(
                    type: type,
                    title: title,
                    message: message,
                    playSound: settingsValue.systemNotificationSounds,
                    actionHandler: actionHandler
                )
            }
        }
    }
    
    /// Show a simple info notification
    public func showInfo(title: String, message: String) {
        show(.info(title: title, message: message))
    }

    public func showHUDInfo(
        title: String,
        message: String,
        icon: String = "info.circle.fill",
        iconColor: Color = .blue,
        identifier: String? = nil,
        isPersistent: Bool = false,
        actions: [HUDNotificationAction] = []
    ) {
        showHUD(
            identifier: identifier,
            title: title,
            message: message,
            icon: icon,
            iconColor: iconColor,
            playSound: false,
            isPersistent: isPersistent,
            actions: actions
        )
    }
    
    /// Show processing complete notification
    public func showProcessingComplete(fileCount: Int, folderName: String) {
        show(.processingComplete(fileCount: fileCount, folderName: folderName))
    }
    
    /// Show processing complete notification with folder path and undo support
    public func showProcessingComplete(
        fileCount: Int,
        folderName: String,
        folderPath: String?,
        canUndo: Bool = false,
        isAutomated: Bool = false,
        onAction: NotificationActionHandler? = nil
    ) {
        let type = NotificationType.processingComplete(
            fileCount: fileCount,
            folderName: folderName,
            folderPath: folderPath,
            canUndo: canUndo,
            isAutomated: isAutomated
        )
        if let handler = onAction {
            show(type, actionHandler: handler)
        } else {
            show(type)
        }
    }
    
    /// Show processing error notification
    public func showError(message: String, isCritical: Bool = false) {
        show(.processingError(message: message, isCritical: isCritical, canRetry: false, isAutomated: false))
    }
    
    /// Show processing error notification with retry option
    public func showError(
        message: String,
        folderPath: String? = nil,
        isCritical: Bool = false,
        canRetry: Bool = false,
        isAutomated: Bool = false,
        onAction: NotificationActionHandler? = nil
    ) {
        let type = NotificationType.processingError(
            message: message,
            folderPath: folderPath,
            isCritical: isCritical,
            canRetry: canRetry,
            isAutomated: isAutomated
        )
        if let handler = onAction {
            show(type, actionHandler: handler)
        } else {
            show(type)
        }
    }
    
    /// Show batch summary notification
    public func showBatchSummary(processed: Int, errors: Int, duration: TimeInterval) {
        show(.batchSummary(processed: processed, errors: errors, duration: duration))
    }
    
    /// Show batch summary notification with detailed stats
    public func showBatchSummary(stats: BatchSummaryStats, isAutomated: Bool = false) {
        show(.batchSummary(stats: stats, isAutomated: isAutomated))
    }

    public func showWatchedFolderStarted(fileCount: Int, folderName: String, folderPath: String) {
        show(.watchedFolderStarted(fileCount: fileCount, folderName: folderName, folderPath: folderPath))
    }

    /// Show a representative watched-folder notification from Settings.
    public func previewWatchedFolderActivity() {
        showWatchedFolderStarted(
            fileCount: 3,
            folderName: "Downloads",
            folderPath: NSHomeDirectory() + "/Downloads"
        )
    }

    /// Plays the organization completion sound when enabled. Used by real
    /// completions and the Settings preview so both hear the same sound.
    public func playCompletionSoundIfEnabled() {
        guard settings.settings.playCompletionSound else { return }
        Self.playRetainedSound(named: "Glass")
    }

    /// Unconditional completion-sound demo for the Settings preview.
    public func previewCompletionSound() {
        Self.playRetainedSound(named: "Glass")
    }
    
    /// Request user attention (dock bounce)
    public func requestAttention(isCritical: Bool = false) {
        let requestType: NSApplication.RequestUserAttentionType = isCritical ? .criticalRequest : .informationalRequest
        guard let app = NSApp else { return }
        app.requestUserAttention(requestType)
    }
    
    /// Dismiss current HUD notification
    public func dismissHUD() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            currentHUDNotification = nil
        }
        processQueue()
    }

    /// Advance to the next queued HUD notification immediately.
    public func showNextHUDNotification() {
        guard !hudNotificationQueue.isEmpty else { return }

        dismissTask?.cancel()
        queueTask?.cancel()
        currentHUDNotification = nil
        processQueue(delayNanoseconds: 80_000_000)
    }

    /// Clear the current HUD and any queued HUD notifications.
    public func dismissAllHUDNotifications() {
        dismissTask?.cancel()
        queueTask?.cancel()
        hudNotificationQueue.removeAll()
        withAnimation(.easeOut(duration: 0.2)) {
            currentHUDNotification = nil
        }
    }

    public func dismissHUD(identifier: String) {
        hudNotificationQueue.removeAll { $0.identifier == identifier }
        guard currentHUDNotification?.identifier == identifier else { return }
        dismissHUD()
    }

    public func clearAnalytics() {
        analyticsEvents = []
    }

    public func recordActionLifecycle(_ action: String, stage: String, failed: Bool = false, detail: String = "") {
        let stageDetail = detail.isEmpty ? stage : "\(stage): \(detail)"
        trackAnalytics(
            failed ? .failed : .action,
            type: .info(title: "action", message: action),
            backend: "native",
            detail: stageDetail
        )
    }

    public func sendInFlowPreviewSample() {
        show(.previewReady(folderName: "Current Preview"))
    }

    /// Show a demo of the in-app HUD delivery style.
    public func previewInAppHUDDelivery() {
        showHUD(
            title: "In-App HUD Demo",
            message: "This is how subtle in-app overlays appear in Sorty.",
            icon: "rectangle.bottomthird.inset.filled",
            iconColor: .pink,
            playSound: settings.settings.hudSounds
        )
        trackAnalytics(
            .shown,
            type: .info(title: "deliveryPreview", message: "inAppHUD"),
            backend: "native",
            detail: "manual HUD delivery preview"
        )
    }

    /// Show a demo in macOS Notification Center using native notifications only.
    public func previewSystemNotificationDelivery() {
        requestAttention(isCritical: false)
        Task {
            await showNativeNotification(
                type: .info(title: "System Notification Test", message: "This is a test notification from Sorty."),
                title: "System Notification Test",
                message: "This is a test notification from Sorty.",
                playSound: settings.settings.systemNotificationSounds,
                actionHandler: nil
            )
        }
    }
    
    // MARK: - Private Methods

    private func analyticsTypeLabel(for type: NotificationType) -> String {
        switch type {
        case .processingComplete:
            return "processingComplete"
        case .previewReady:
            return "previewReady"
        case .processingError:
            return "processingError"
        case .batchSummary:
            return "batchSummary"
        case .watchedFolderStarted:
            return "watchedFolderStarted"
        case .info:
            return "info"
        }
    }

    private func trackAnalytics(
        _ eventType: NotificationAnalyticsEvent.EventType,
        type: NotificationType,
        backend: String,
        detail: String
    ) {
        analyticsEvents.insert(
            NotificationAnalyticsEvent(
                eventType: eventType,
                backend: backend,
                notificationType: analyticsTypeLabel(for: type),
                detail: detail
            ),
            at: 0
        )
        if analyticsEvents.count > 200 {
            analyticsEvents = Array(analyticsEvents.prefix(200))
        }
    }
    
    private func notificationContent(for type: NotificationType) -> (title: String, message: String, icon: String, iconColor: Color) {
        switch type {
        case .processingComplete(let fileCount, let folderName, _, _, _):
            return (
                "\(folderName) Organized",
                "Sorty organized \(fileCount) file\(fileCount == 1 ? "" : "s"). Open Sorty to review what changed.",
                "checkmark.circle.fill",
                .green
            )
        case .previewReady(let folderName, _, _, _, _):
            return (
                "Review \(folderName)",
                "Your plan is saved. Review and adjust it before Sorty moves any files.",
                "eye.fill",
                .blue
            )
        case .processingError(let message, _, let isCritical, _, _):
            return (
                isCritical ? "Sorty Needs Attention" : "Couldn't Organize Files",
                "\(message) Open Sorty to review details and recover.",
                isCritical ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                isCritical ? .red : .orange
            )
        case .batchSummary(let stats, _):
            let durationStr = formatDuration(stats.duration)
            
            // Build a detailed message
            var parts: [String] = []
            
            if stats.filesMoved > 0 {
                parts.append("\(stats.filesMoved) file\(stats.filesMoved == 1 ? "" : "s") moved")
            }
            if stats.foldersCreated > 0 {
                parts.append("\(stats.foldersCreated) folder\(stats.foldersCreated == 1 ? "" : "s") created")
            }
            if stats.filesRenamed > 0 {
                parts.append("\(stats.filesRenamed) renamed")
            }
            if stats.filesTagged > 0 {
                parts.append("\(stats.filesTagged) tagged")
            }
            if stats.duplicatesFound > 0 {
                parts.append("\(stats.duplicatesFound) duplicate\(stats.duplicatesFound == 1 ? "" : "s") found")
            }
            
            // Create the message
            let message: String
            let title: String
            let iconColor: Color
            
            if parts.isEmpty && stats.errorsEncountered == 0 {
                // No operations performed
                message = "No files needed organizing. Open Sorty to review the result."
                title = "Organization Complete"
                iconColor = .secondary
            } else if stats.errorsEncountered > 0 {
                let errorSuffix = " with \(stats.errorsEncountered) error\(stats.errorsEncountered == 1 ? "" : "s")"
                if parts.isEmpty {
                    message = "Completed\(errorSuffix) in \(durationStr). Open Sorty to recover."
                } else {
                    message = "\(parts.joined(separator: ", "))\(errorSuffix) in \(durationStr). Open Sorty to review."
                }
                title = stats.folderName.isEmpty ? "Organization Complete" : "Organized \(stats.folderName)"
                iconColor = .orange
            } else {
                message = "\(parts.joined(separator: ", ")) in \(durationStr). Open Sorty to review what changed."
                title = stats.folderName.isEmpty ? "Organization Complete" : "Organized \(stats.folderName)"
                iconColor = .green
            }
            
            return (title, message, "folder.fill.badge.gearshape", iconColor)
        case .watchedFolderStarted(let fileCount, let folderName, _):
            return (
                "Organizing \(folderName)",
                "Sorty found \(fileCount) new file\(fileCount == 1 ? "" : "s"). You'll be notified when it finishes.",
                "folder.fill.badge.gearshape",
                .blue
            )
        case .info(let title, let message):
            return (title, message, "info.circle.fill", .blue)
        }
    }

    private func shouldRequestAttention(for type: NotificationType, isAppBackgrounded: Bool) -> Bool {
        if type.isCritical {
            return true
        }

        guard isAppBackgrounded else {
            return false
        }

        switch type {
        case .processingComplete, .previewReady, .batchSummary, .watchedFolderStarted:
            return true
        case .processingError, .info:
            return false
        }
    }
    
    private func showHUD(
        identifier: String? = nil,
        title: String,
        message: String,
        icon: String,
        iconColor: Color,
        playSound: Bool,
        isPersistent: Bool = false,
        actions: [HUDNotificationAction] = [],
        defaultAction: (@MainActor () -> Void)? = nil
    ) {
        DebugLogger.log("NotificationManager: showHUD called - title: \(title), message: \(message)")
        
        let notification = HUDNotification(
            identifier: identifier,
            title: title,
            message: message,
            icon: icon,
            iconColor: iconColor,
            timestamp: Date(),
            playSound: playSound,
            isPersistent: isPersistent,
            actions: actions,
            defaultAction: defaultAction
        )

        if let identifier {
            hudNotificationQueue.removeAll { $0.identifier == identifier }
            if currentHUDNotification?.identifier == identifier {
                presentHUD(notification)
                return
            }
        }
        
        if currentHUDNotification == nil {
            DebugLogger.log("NotificationManager: Presenting HUD immediately")
            presentHUD(notification)
        } else {
            DebugLogger.log("NotificationManager: Queuing HUD notification (queue size: \(hudNotificationQueue.count + 1))")
            hudNotificationQueue.append(notification)
        }
    }
    
    private func presentHUD(_ notification: HUDNotification) {
        DebugLogger.log("NotificationManager: presentHUD - \(notification.title)")
        
        if notification.playSound {
            playHUDSound()
        }
        
        withAnimation(.easeOut(duration: 0.2)) {
            currentHUDNotification = notification
        }
        
        // Force publish change for observers
        objectWillChange.send()
        
        DebugLogger.log("NotificationManager: currentHUDNotification set, scheduling auto-dismiss")
        
        dismissTask?.cancel()
        guard !notification.isPersistent else { return }

        // Auto-dismiss transient HUDs after the shared HUD duration.
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(Self.transientHUDDuration))
            if !Task.isCancelled {
                dismissHUD()
            }
        }
    }

    private func defaultHUDAction(
        for type: NotificationType,
        actionHandler: NotificationActionHandler? = nil
    ) -> (@MainActor () -> Void)? {
        if case .info = type {
            return nil
        }

        return { [weak self] in
            guard let self else { return }
            self.dismissHUD()
            Task {
                await self.handleDefaultNotificationActivation(
                    for: type,
                    actionHandler: actionHandler,
                    backend: "native"
                )
            }
        }
    }
    
    private func processQueue(delayNanoseconds: UInt64 = 300_000_000) {
        guard !hudNotificationQueue.isEmpty else { return }
        queueTask?.cancel()
        
        // Small delay before showing next notification
        queueTask = Task {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            if let next = hudNotificationQueue.first {
                hudNotificationQueue.removeFirst()
                presentHUD(next)
            }
        }
    }
    
    private func showSystemNotification(
        type: NotificationType,
        title: String,
        message: String,
        playSound: Bool,
        actionHandler: NotificationActionHandler? = nil
    ) async {
        await showNativeNotification(
            type: type,
            title: title,
            message: message,
            playSound: playSound,
            actionHandler: actionHandler
        )
    }

    /// Show notification using native macOS UNUserNotificationCenter (fallback)
    private func showNativeNotification(
        type: NotificationType,
        title: String,
        message: String,
        playSound: Bool,
        actionHandler: NotificationActionHandler?
    ) async {
        guard isSafeToUseSystemNotifications else {
            DebugLogger.log("NotificationManager: Skipping native notification (CLI/Test environment)")
            return
        }
        
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        var status = notificationSettings.authorizationStatus
        
        if status == .notDetermined {
            await requestSystemNotificationPermission()
            let updatedSettings = await UNUserNotificationCenter.current().notificationSettings()
            status = updatedSettings.authorizationStatus
        }
        
        guard status == .authorized else {
            DebugLogger.log("NotificationManager: System notifications not authorized (status: \(status.rawValue))")
            trackAnalytics(.failed, type: type, backend: "native", detail: "authorization denied")
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        // Force high-visibility delivery so notifications surface on-screen immediately.
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1.0

        let actions = settings.settings.showActionButtons ? notificationActions(for: type) : []
        if let categoryIdentifier = ensureNativeCategoryIdentifier(for: actions) {
            content.categoryIdentifier = categoryIdentifier
        }

        let userInfo = nativeUserInfo(for: type)
        if !userInfo.isEmpty {
            content.userInfo = userInfo
        }
        
        if let iconAttachment = NotificationManager.createAppIconAttachment() {
            content.attachments = [iconAttachment]
        }
        
        let requestIdentifier = UUID().uuidString
        let request = UNNotificationRequest(
            identifier: requestIdentifier,
            content: content,
            trigger: nil
        )

        if let actionHandler = actionHandler {
            pendingNativeActionHandlers[requestIdentifier] = actionHandler
        }
        if !actions.isEmpty {
            pendingNativeActions[requestIdentifier] = actions
        }
        pendingNativeNotificationTypes[requestIdentifier] = type
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            let actionSummary = actions.isEmpty ? "no actions" : actions.map(\.label).joined(separator: ", ")
            DebugLogger.log("NotificationManager: Native system notification sent successfully")
            trackAnalytics(.shown, type: type, backend: "native", detail: "native notification sent [\(actionSummary)]")
        } catch {
            DebugLogger.log("NotificationManager: Failed to send system notification: \(error)")
            trackAnalytics(.failed, type: type, backend: "native", detail: error.localizedDescription)
        }
    }

    private func nativeUserInfo(for type: NotificationType) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            NativeNotificationUserInfoKey.notificationType: analyticsTypeLabel(for: type)
        ]

        switch type {
        case .processingComplete(let fileCount, let folderName, let folderPath, let canUndo, let isAutomated):
            userInfo[NativeNotificationUserInfoKey.fileCount] = fileCount
            userInfo[NativeNotificationUserInfoKey.folderName] = folderName
            userInfo[NativeNotificationUserInfoKey.canUndo] = canUndo
            userInfo[NativeNotificationUserInfoKey.isAutomated] = isAutomated
            if let path = folderPath {
                userInfo[NativeNotificationUserInfoKey.folderPath] = path
            }
        case .previewReady(let folderName, let folderPath, let planID, let originSessionID, let isWatchedReview):
            userInfo[NativeNotificationUserInfoKey.folderName] = folderName
            userInfo[NativeNotificationUserInfoKey.planID] = planID?.uuidString
            userInfo[NativeNotificationUserInfoKey.originSessionID] = originSessionID?.uuidString
            userInfo[NativeNotificationUserInfoKey.isWatchedReview] = isWatchedReview
            if let path = folderPath {
                userInfo[NativeNotificationUserInfoKey.folderPath] = path
            }
        case .processingError(let message, let folderPath, let isCritical, let canRetry, let isAutomated):
            userInfo[NativeNotificationUserInfoKey.message] = message
            userInfo[NativeNotificationUserInfoKey.isCritical] = isCritical
            userInfo[NativeNotificationUserInfoKey.canRetry] = canRetry
            userInfo[NativeNotificationUserInfoKey.isAutomated] = isAutomated
            if let path = folderPath {
                userInfo[NativeNotificationUserInfoKey.folderPath] = path
            }
        case .batchSummary(let stats, let isAutomated):
            userInfo[NativeNotificationUserInfoKey.batchStats] = try? JSONEncoder().encode(stats).base64EncodedString()
            userInfo[NativeNotificationUserInfoKey.isAutomated] = isAutomated
            if let path = stats.folderPath {
                userInfo[NativeNotificationUserInfoKey.folderPath] = path
            }
        case .watchedFolderStarted(let fileCount, let folderName, let folderPath):
            userInfo[NativeNotificationUserInfoKey.fileCount] = fileCount
            userInfo[NativeNotificationUserInfoKey.folderName] = folderName
            userInfo[NativeNotificationUserInfoKey.folderPath] = folderPath
        case .info(let title, let message):
            userInfo[NativeNotificationUserInfoKey.folderName] = title
            userInfo[NativeNotificationUserInfoKey.message] = message
        }
        return userInfo
    }

    private func nativeNotificationType(from content: UNNotificationContent) -> NotificationType? {
        let userInfo = content.userInfo
        guard let type = userInfo[NativeNotificationUserInfoKey.notificationType] as? String else {
            return .info(title: content.title, message: content.body)
        }

        let folderPath = userInfo[NativeNotificationUserInfoKey.folderPath] as? String
        let folderName = userInfo[NativeNotificationUserInfoKey.folderName] as? String ??
            folderPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Files"
        let fileCount = userInfo[NativeNotificationUserInfoKey.fileCount] as? Int ?? 0
        let isAutomated = userInfo[NativeNotificationUserInfoKey.isAutomated] as? Bool ?? false

        switch type {
        case "processingComplete":
            return .processingComplete(
                fileCount: fileCount,
                folderName: folderName,
                folderPath: folderPath,
                canUndo: userInfo[NativeNotificationUserInfoKey.canUndo] as? Bool ?? false,
                isAutomated: isAutomated
            )
        case "previewReady":
            return .previewReady(
                folderName: folderName,
                folderPath: folderPath,
                planID: (userInfo[NativeNotificationUserInfoKey.planID] as? String).flatMap(UUID.init(uuidString:)),
                originSessionID: (userInfo[NativeNotificationUserInfoKey.originSessionID] as? String).flatMap(UUID.init(uuidString:)),
                isWatchedReview: userInfo[NativeNotificationUserInfoKey.isWatchedReview] as? Bool ?? false
            )
        case "processingError":
            return .processingError(
                message: userInfo[NativeNotificationUserInfoKey.message] as? String ?? content.body,
                folderPath: folderPath,
                isCritical: userInfo[NativeNotificationUserInfoKey.isCritical] as? Bool ?? false,
                canRetry: userInfo[NativeNotificationUserInfoKey.canRetry] as? Bool ?? false,
                isAutomated: isAutomated
            )
        case "batchSummary":
            guard let encodedStats = userInfo[NativeNotificationUserInfoKey.batchStats] as? String,
                  let data = Data(base64Encoded: encodedStats),
                  let stats = try? JSONDecoder().decode(BatchSummaryStats.self, from: data) else {
                return .batchSummary(
                    stats: BatchSummaryStats(folderName: folderName, folderPath: folderPath),
                    isAutomated: isAutomated
                )
            }
            return .batchSummary(stats: stats, isAutomated: isAutomated)
        case "watchedFolderStarted":
            guard let folderPath else { return nil }
            return .watchedFolderStarted(fileCount: fileCount, folderName: folderName, folderPath: folderPath)
        case "info":
            return .info(
                title: userInfo[NativeNotificationUserInfoKey.folderName] as? String ?? content.title,
                message: userInfo[NativeNotificationUserInfoKey.message] as? String ?? content.body
            )
        default:
            return .info(title: content.title, message: content.body)
        }
    }

    private func ensureNativeCategoryIdentifier(for actions: [CuratedNotificationAction]) -> String? {
        guard !actions.isEmpty else { return nil }

        let identifier = "SORTY_" + actions.map(\.identifier).joined(separator: "_")
        if registeredNativeCategories[identifier] == nil {
            let category = UNNotificationCategory(
                identifier: identifier,
                actions: actions.map(nativeNotificationAction(for:)),
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
            registeredNativeCategories[identifier] = category
            UNUserNotificationCenter.current().setNotificationCategories(Set(registeredNativeCategories.values))
        }

        return identifier
    }

    private func nativeNotificationAction(for action: CuratedNotificationAction) -> UNNotificationAction {
        UNNotificationAction(
            identifier: action.identifier,
            title: action.label,
            options: [.foreground]
        )
    }

    func handleNativeNotificationResponse(_ response: UNNotificationResponse) {
        let identifier = response.notification.request.identifier
        let actionHandler = pendingNativeActionHandlers.removeValue(forKey: identifier)
        let notificationType = pendingNativeNotificationTypes.removeValue(forKey: identifier) ??
            nativeNotificationType(from: response.notification.request.content)
        let actions = pendingNativeActions.removeValue(forKey: identifier) ??
            notificationType.map(notificationActions(for:)) ?? []

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            if let notificationType {
                Task {
                    await handleDefaultNotificationActivation(for: notificationType, actionHandler: actionHandler, backend: "native")
                }
            }

        case UNNotificationDismissActionIdentifier:
            Task { await actionHandler?(.dismiss) }
            trackAnalytics(.action, type: .info(title: "action", message: "dismiss"), backend: "native", detail: "dismiss")

        default:
            guard let notificationType,
                  let action = actions.first(where: { $0.identifier == response.actionIdentifier }) else {
                return
            }

            Task {
                await handleCuratedActionSelection(
                    action,
                    type: notificationType,
                    actionHandler: actionHandler,
                    backend: "native"
                )
            }
        }
    }

    func notificationActionLabels(for type: NotificationType) -> [String] {
        notificationActions(for: type).map(\.label)
    }

    private func notificationActions(for type: NotificationType) -> [CuratedNotificationAction] {
        let maxActions = 4
        var candidates: [(priority: Int, action: CuratedNotificationAction)] = []

        func add(_ priority: Int, _ action: CuratedNotificationAction?) {
            guard let action else { return }
            candidates.append((priority, action))
        }
        switch type {
        case .processingComplete(let fileCount, _, let folderPath, let canUndo, let isAutomated):
            add(100, folderPath.map(openFolderAction))
            add(90, deferredDetailsAction())
            add(isAutomated ? 70 : 80, canUndo ? undoAction() : nil)
            add(isAutomated ? 50 : (fileCount > 200 ? 55 : 65), redoWithModelAction())

        case .batchSummary(let stats, let isAutomated):
            if stats.hasErrors {
                add(100, deferredDetailsAction())
                add(stats.folderPath != nil ? 90 : 0, stats.folderPath.map(openFolderAction))
                add(stats.canUndo ? 80 : 0, stats.canUndo ? undoAction(label: "Undo All", identifier: NativeNotificationActionIdentifier.undoAll) : nil)
                add(isAutomated ? 40 : 60, redoWithModelAction())
            } else {
                add(100, stats.folderPath.map(openFolderAction))
                add(90, deferredDetailsAction())
                add(stats.canUndo ? 80 : 0, stats.canUndo ? undoAction(label: "Undo All", identifier: NativeNotificationActionIdentifier.undoAll) : nil)
                add(isAutomated ? 45 : 65, redoWithModelAction())
            }

        case .previewReady:
            add(100, reviewAction())

        case .processingError(let message, let folderPath, _, let canRetry, let isAutomated):
            let failureClass = NotificationFailureClass(message: message)
            add(100, deferredDetailsAction())
            add(canRetry && failureClass.shouldOfferRetry ? 90 : 0, canRetry && failureClass.shouldOfferRetry ? retryAction() : nil)
            add(folderPath != nil ? 70 : 0, folderPath.map(openFolderAction))
            add(isAutomated || !failureClass.shouldOfferRedoWithModel ? 0 : 65, !isAutomated && failureClass.shouldOfferRedoWithModel ? redoWithModelAction() : nil)

        case .watchedFolderStarted:
            add(100, type.folderPath.map(openFolderAction))

        case .info:
            break
        }

        var seenIdentifiers: Set<String> = []
        return candidates
            .sorted { lhs, rhs in
                if lhs.priority == rhs.priority {
                    return lhs.action.label < rhs.action.label
                }
                return lhs.priority > rhs.priority
            }
            .compactMap { candidate in
                guard seenIdentifiers.insert(candidate.action.identifier).inserted else { return nil }
                return candidate.action
            }
            .prefix(maxActions)
            .map { $0 }
    }

    private func applyAction() -> CuratedNotificationAction {
        CuratedNotificationAction(
            label: "Apply Now",
            identifier: NativeNotificationActionIdentifier.apply,
            action: .apply,
            role: .guardedConfirmation,
            confirmationNotificationName: .requestApplyOrganizationConfirmation
        )
    }

    private func undoAction(label: String = "Undo", identifier: String = NativeNotificationActionIdentifier.undo) -> CuratedNotificationAction {
        CuratedNotificationAction(
            label: label,
            identifier: identifier,
            action: .undo,
            role: .guardedConfirmation,
            confirmationNotificationName: .requestUndoOrganizationConfirmation
        )
    }

    private func openFolderAction(path: String) -> CuratedNotificationAction {
        CuratedNotificationAction(
            label: "Open Folder",
            identifier: NativeNotificationActionIdentifier.openFolder,
            action: .openFolder(path: path),
            role: .safeImmediate,
            confirmationNotificationName: nil
        )
    }

    private func deferredDetailsAction() -> CuratedNotificationAction {
        CuratedNotificationAction(
            label: "Show Details",
            identifier: NativeNotificationActionIdentifier.showDetails,
            action: .showDetails,
            role: .deferredNavigation,
            confirmationNotificationName: nil
        )
    }

    private func reviewAction() -> CuratedNotificationAction {
        CuratedNotificationAction(
            label: "Review Plan",
            identifier: NativeNotificationActionIdentifier.review,
            action: .showDetails,
            role: .deferredNavigation,
            confirmationNotificationName: nil
        )
    }

    private func retryAction() -> CuratedNotificationAction {
        CuratedNotificationAction(
            label: "Retry",
            identifier: NativeNotificationActionIdentifier.retry,
            action: .retry,
            role: .guardedConfirmation,
            confirmationNotificationName: .requestRetryOrganizationConfirmation
        )
    }

    private func redoWithModelAction() -> CuratedNotificationAction {
        CuratedNotificationAction(
            label: "Try Another Model",
            identifier: NativeNotificationActionIdentifier.redoModel,
            action: .redoWithModel,
            role: .guardedConfirmation,
            confirmationNotificationName: .requestRedoOrganizationWithModelConfirmation
        )
    }

    private func handleCuratedActionSelection(
        _ curatedAction: CuratedNotificationAction,
        type: NotificationType,
        actionHandler: NotificationActionHandler?,
        backend: String
    ) async {
        switch curatedAction.role {
        case .safeImmediate:
            await dispatchImmediateAction(curatedAction.action, type: type, actionHandler: actionHandler, backend: backend, label: curatedAction.label)
        case .deferredNavigation:
            await dispatchDeferredAction(curatedAction, type: type, actionHandler: actionHandler, backend: backend)
        case .guardedConfirmation:
            activateAppForNotificationAction()
            if let confirmationNotificationName = curatedAction.confirmationNotificationName {
                postMainWindowNotification(confirmationNotificationName, type: type)
            }
            trackAnalytics(.action, type: .info(title: "action", message: String(describing: curatedAction.action)), backend: backend, detail: "requested confirmation: \(curatedAction.label)")
        }
    }

    private func dispatchImmediateAction(
        _ action: NotificationAction,
        type: NotificationType,
        actionHandler: NotificationActionHandler?,
        backend: String,
        label: String
    ) async {
        switch action {
        case .apply:
            await actionHandler?(.apply)
            activateAppForNotificationAction()
            postMainWindowNotification(.requestApplyOrganizationConfirmation, type: type)
        case .undo:
            await actionHandler?(.undo)
            NotificationCenter.default.post(name: .undoLastOrganization, object: nil, userInfo: notificationUserInfo(for: type))
        case .openFolder(let path):
            await actionHandler?(.openFolder(path: path))
            NotificationCenter.default.post(name: .openOrganizedFolder, object: nil, userInfo: [NativeNotificationUserInfoKey.folderPath: path])
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        case .showDetails:
            await actionHandler?(.showDetails)
            postMainWindowNotification(.showOrganizationDetails, type: type)
        case .retry:
            await actionHandler?(.retry)
            NotificationCenter.default.post(name: .retryLastOrganization, object: nil, userInfo: notificationUserInfo(for: type))
        case .redoWithModel:
            await actionHandler?(.redoWithModel)
            postMainWindowNotification(.redoOrganizationWithModel, type: type)
        case .dismiss:
            await actionHandler?(.dismiss)
        }

        trackAnalytics(.action, type: .info(title: "action", message: String(describing: action)), backend: backend, detail: label)
    }

    private func dispatchDeferredAction(
        _ curatedAction: CuratedNotificationAction,
        type: NotificationType,
        actionHandler: NotificationActionHandler?,
        backend: String
    ) async {
        activateAppForNotificationAction()

        switch curatedAction.identifier {
        case NativeNotificationActionIdentifier.review:
            await actionHandler?(.showDetails)
            postMainWindowNotification(.showOrganizationPreview, type: type)
        default:
            await actionHandler?(.showDetails)
            postMainWindowNotification(.showOrganizationDetails, type: type)
        }

        trackAnalytics(.action, type: .info(title: "action", message: "navigation"), backend: backend, detail: curatedAction.label)
    }

    private func handleDefaultNotificationActivation(
        for type: NotificationType,
        actionHandler: NotificationActionHandler?,
        backend: String
    ) async {
        switch type {
        case .previewReady:
            activateAppForNotificationAction()
            postMainWindowNotification(.showOrganizationPreview, type: type)
            await actionHandler?(.showDetails)
            trackAnalytics(.action, type: .info(title: "action", message: "defaultPreview"), backend: backend, detail: "default click")
        case .processingComplete, .processingError, .batchSummary:
            activateAppForNotificationAction()
            postMainWindowNotification(.showOrganizationDetails, type: type)
            await actionHandler?(.showDetails)
            trackAnalytics(.action, type: .info(title: "action", message: "defaultDetails"), backend: backend, detail: "default click")
        case .watchedFolderStarted:
            activateAppForNotificationAction()
            postMainWindowNotification(.showWatchedFolders, type: type)
            trackAnalytics(.action, type: .info(title: "action", message: "defaultWatchedFolders"), backend: backend, detail: "default click")
        case .info:
            activateAppForNotificationAction()
            await actionHandler?(.showDetails)
            trackAnalytics(.action, type: .info(title: "action", message: "defaultActivate"), backend: backend, detail: "default click")
        }
    }

    private func postMainWindowNotification(_ name: Notification.Name, type: NotificationType) {
        let userInfo = notificationUserInfo(for: type)
        let originSessionID: UUID?
        if case .previewReady(_, _, _, let origin, _) = type,
           let origin,
           MainWindowRouter.shared.hasSession(origin) {
            originSessionID = origin
        } else {
            originSessionID = nil
        }
        let didQueue = MainWindowRouter.shared.postOrQueue(
            name: name,
            userInfo: userInfo,
            targetSessionID: originSessionID
        )
        if didQueue,
           let openURL = DeeplinkHandler.url(for: .open(path: nil)) {
            NSWorkspace.shared.open(openURL)
        }
    }

    private func notificationUserInfo(for type: NotificationType) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            NativeNotificationUserInfoKey.notificationType: analyticsTypeLabel(for: type)
        ]
        if let path = type.folderPath {
            userInfo[NativeNotificationUserInfoKey.folderPath] = path
        }
        if case .previewReady(_, _, let planID, let originSessionID, let isWatchedReview) = type {
            userInfo[NativeNotificationUserInfoKey.planID] = planID?.uuidString
            userInfo[NativeNotificationUserInfoKey.originSessionID] = originSessionID?.uuidString
            userInfo[NativeNotificationUserInfoKey.isWatchedReview] = isWatchedReview
        }
        return userInfo
    }

    private func activateAppForNotificationAction() {
        if MainWindowRouter.shared.activatePreferredWindow() {
            return
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        if let keyWindow = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            keyWindow.makeKeyAndOrderFront(nil)
        }
    }
    
    private func requestSystemNotificationPermission() async {
        guard isSafeToUseSystemNotifications else { return }
        guard !permissionCached else { return }
        
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            permissionCached = true
            await MainActor.run {
                self.notificationPermissionStatus = granted ? .authorized : .denied
            }
            DebugLogger.log("NotificationManager: Permission \(granted ? "granted" : "denied")")
        } catch {
            DebugLogger.log("NotificationManager: Permission request failed: \(error)")
        }
    }
    
    // Sounds started with NSSound.play() stop if the instance is released
    // mid-playback, so hold each sound until it has finished playing.
    // ponytail: unbounded array, fine at notification volume; cap if abused.
    private static var retainedSounds: [NSSound] = []

    private static func playRetainedSound(named name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else {
            NSSound.beep()
            return
        }
        retainedSounds.append(sound)
        sound.play()
        let releaseAfter = max(sound.duration + 0.5, 1.5)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(releaseAfter))
            retainedSounds.removeAll { $0 === sound }
        }
    }

    private func playHUDSound() {
        // Use a subtle glass sound if available, fallback to beep
        Self.playRetainedSound(named: "Glass")
    }

    func shouldPlayCompletionSound(for type: NotificationType) -> Bool {
        switch type {
        case .processingComplete:
            return true
        case .batchSummary(let stats, _):
            return stats.isSuccessful && !stats.hasErrors
        default:
            return false
        }
    }
    
    /// Creates a notification attachment for the app icon to ensure it displays in notifications
    /// - Returns: A UNNotificationAttachment for the app icon, or nil if unavailable
    public static func createAppIconAttachment() -> UNNotificationAttachment? {
        guard let iconImage = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage else {
            return nil
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let iconURL = tempDir.appendingPathComponent("SortyNotificationIcon-\(UUID().uuidString).png")
        
        guard let tiffData = iconImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            return nil
        }
        
        do {
            try pngData.write(to: iconURL)
            let attachment = try UNNotificationAttachment(
                identifier: "appIcon",
                url: iconURL,
                options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"]
            )
            return attachment
        } catch {
            try? FileManager.default.removeItem(at: iconURL)
            return nil
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 60 {
            return "\(Int(duration))s"
        } else if duration < 3600 {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return "\(minutes)m \(seconds)s"
        } else {
            let hours = Int(duration) / 3600
            let minutes = (Int(duration) % 3600) / 60
            return "\(hours)h \(minutes)m"
        }
    }
}
