//
//  NotificationsSettingsView.swift
//  Sorty
//
//  Notifications settings section
//

import SwiftUI

struct NotificationsSettingsView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var notificationSettings: NotificationSettingsManager
    @ObservedObject private var notificationManager = NotificationManager.shared
    
    var body: some View {
        VStack(spacing: 16) {
            // Permission Status
            NotificationPermissionCard()
                .settingsFocusable(.notificationsPermission)
            
            // Delivery Method
            SettingsCard(title: "Delivery Method", icon: "bell.badge", color: .pink) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsToggle(
                        isOn: $notificationSettings.settings.inAppHUD,
                        title: "In-App HUD",
                        description: "Show notifications as subtle bottom-left overlays",
                        previewAction: { notificationManager.previewInAppHUDDelivery() },
                        previewIcon: "play.fill",
                        focusTarget: .notificationsInAppHUD
                    )
                    
                    Divider()
                    
                    SettingsToggle(
                        isOn: $notificationSettings.settings.systemNotifications,
                        title: "System Notifications",
                        description: "Show in macOS Notification Center",
                        previewAction: { notificationManager.previewSystemNotificationDelivery() },
                        previewIcon: "play.fill",
                        focusTarget: .notificationsSystem
                    )

                    Divider()

                    SettingsToggle(
                        isOn: $notificationSettings.settings.playCompletionSound,
                        title: "Completion Sound",
                        description: "Play a satisfying sound when organization finishes",
                        previewAction: { previewCompletionSound() },
                        previewIcon: "play.fill",
                        focusTarget: .notificationsCompletionSound
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            // Notification Types
            SettingsCard(title: "Notification Types", icon: "list.bullet", color: .blue) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsToggle(
                        isOn: processingCompleteNotifications,
                        title: "Processing Complete",
                        description: "When file processing finishes successfully",
                        previewAction: { previewProcessingComplete() },
                        previewIcon: "play.fill",
                        focusTarget: .notificationsProcessingComplete
                    )
                    
                    Divider()
                    
                    SettingsToggle(
                        isOn: $notificationSettings.settings.previewReady,
                        title: "Preview Ready",
                        description: "When Sorty has finished generating the organization plan",
                        previewAction: { previewPreviewReady() },
                        previewIcon: "play.fill",
                        focusTarget: .notificationsPreviewReady
                    )
                    
                    Divider()
                    
                    SettingsToggle(
                        isOn: $notificationSettings.settings.processingErrors,
                        title: "Processing Errors",
                        description: "When errors occur during processing",
                        previewAction: { previewProcessingError() },
                        previewIcon: "play.fill",
                        focusTarget: .notificationsProcessingErrors
                    )

                    Divider()

                    SettingsToggle(
                        isOn: watchedFolderActivityNotifications,
                        title: "Watched Folder Activity",
                        description: "When Sorty starts or finishes organizing detected additions",
                        previewAction: { notificationManager.previewWatchedFolderActivity() },
                        previewIcon: "play.fill",
                        focusTarget: .notificationsWatchedFolderFinished
                    )

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .settingsFocusable(.notificationsTypes)
        }
    }

    private func previewProcessingComplete() {
        notificationManager.showBatchSummary(
            stats: BatchSummaryStats(
                filesMoved: 12,
                foldersCreated: 3,
                duration: 8,
                folderName: "Downloads",
                folderPath: NSHomeDirectory() + "/Downloads"
            )
        )
        HapticFeedbackManager.shared.tap()
    }

    private func previewPreviewReady() {
        notificationManager.show(
            .previewReady(
                folderName: "Downloads",
                folderPath: NSHomeDirectory() + "/Downloads"
            )
        )
        HapticFeedbackManager.shared.tap()
    }

    private func previewProcessingError() {
        notificationManager.showError(
            message: "Sample: Sorty couldn't organize 2 files.",
            isCritical: false,
            canRetry: true
        )
        HapticFeedbackManager.shared.tap()
    }

    private func previewCompletionSound() {
        notificationManager.previewCompletionSound()
        HapticFeedbackManager.shared.tap()
    }

    private var processingCompleteNotifications: Binding<Bool> {
        Binding(
            get: {
                notificationSettings.settings.processingComplete &&
                    notificationSettings.settings.batchSummary
            },
            set: { isEnabled in
                notificationSettings.settings.processingComplete = isEnabled
                notificationSettings.settings.batchSummary = isEnabled
            }
        )
    }

    private var watchedFolderActivityNotifications: Binding<Bool> {
        Binding(
            get: {
                notificationSettings.settings.watchedFolderStartNotificationsEnabled &&
                    notificationSettings.settings.watchedFolderCompletionNotificationsEnabled
            },
            set: { isEnabled in
                notificationSettings.settings.watchedFolderStartNotificationsEnabled = isEnabled
                notificationSettings.settings.watchedFolderCompletionNotificationsEnabled = isEnabled
            }
        )
    }

}

#Preview {
    NotificationsSettingsView()
        .frame(width: 500, height: 800)
}
