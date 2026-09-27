import Foundation
import SortyOrganizer

/// Connects organization to Core services after the first window yields.
public enum LiveOrganizerServices {
    @MainActor public static func configure() {
        OrganizerServices.logSink = { message, level, category in
            let logLevel: LogLevel = switch level {
            case .debug: .debug
            case .info: .info
            case .warning: .warning
            case .error: .error
            case .fault: .fault
            }
            LogManager.shared.log(message, level: logLevel, category: category)
        }
        OrganizerServices.workflowReporter = { workflow, stage, outcome, properties in
            AnalyticsManager.shared.captureWorkflow(
                workflow: workflow, stage: stage, outcome: outcome, properties: properties
            )
        }
        OrganizerServices.bucketCount = { AnalyticsManager.countBucket($0) }
        OrganizerServices.describeDuration = { AnalyticsManager.durationProperties($0) }
        OrganizerServices.describeGeneration = { AnalyticsManager.generationDurationProperties($0) }
        OrganizerServices.errorReporter = { error, feature, operation, recoverable in
            ReliabilityManager.shared.capture(
                error: error, feature: feature, operation: operation, recoverable: recoverable
            )
        }
        OrganizerServices.spanStarter = { name, operation, feature in
            guard let span = ReliabilityManager.shared.startSpan(
                name: name, operation: operation, feature: feature
            ) else { return nil }
            return OrganizerSpan { span.finish() }
        }
        OrganizerServices.previewReporter = { folderName, folderPath, planID, originSessionID in
            NotificationManager.shared.show(.previewReady(
                folderName: folderName, folderPath: folderPath,
                planID: planID, originSessionID: originSessionID
            ))
        }
        OrganizerServices.errorNotification = { message, folderPath, isCritical in
            NotificationManager.shared.showError(
                message: message, folderPath: folderPath, isCritical: isCritical
            )
        }
        OrganizerServices.hudReporter = { title, message, icon, iconColor, identifier in
            NotificationManager.shared.showHUDInfo(
                title: title, message: message, icon: icon,
                iconColor: iconColor, identifier: identifier
            )
        }
        OrganizerServices.learningConcernReporter = { concern, folderPath in
            let destination: DeeplinkDestination
            let actionTitle: String
            let actionIcon: String
            switch concern.reviewTarget {
            case .instructions:
                destination = .organize(path: folderPath, persona: nil, mode: nil, autostart: false)
                actionTitle = "Review Instructions"
                actionIcon = "text.alignleft"
            case .persona:
                destination = .persona(action: nil, prompt: nil, generate: false)
                actionTitle = "Review Persona"
                actionIcon = "person.text.rectangle"
            case .watchedFolder:
                destination = .watched(action: nil, path: folderPath)
                actionTitle = "Review Watched Folder"
                actionIcon = "folder.badge.gearshape"
            }
            NotificationManager.shared.showHUDInfo(
                title: "Learning Is Being Skipped Often",
                message: "Sorty skipped learning for \(concern.excludedRunCount) of the last \(concern.evaluatedRunCount) runs. Review the instructions that triggered it.",
                icon: "exclamationmark.triangle.fill",
                iconColor: .orange,
                identifier: "frequent-learning-exclusions",
                actions: [HUDNotificationAction(title: actionTitle, systemImage: actionIcon) {
                    guard let url = DeeplinkHandler.url(for: destination) else { return }
                    _ = MainWindowRouter.shared.routeDeeplink(url)
                }]
            )
        }
        OrganizerServices.attentionRequester = { NotificationManager.shared.requestAttention() }
        OrganizerServices.visionSupportChecker = {
            ModelCatalog.shared.supportsVision(modelId: $0, provider: $1)
        }
        OrganizerServices.keychainReader = { KeychainManager.get(key: $0) }
        OrganizerServices.finderSelectionReader = { await FinderAutomation.getSelectedFiles() }
    }
}

extension AutomationManager: OrganizerAutomation {
    public var isAutomationGranted: Bool { automationStatus == .granted }
}
