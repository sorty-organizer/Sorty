import Foundation
import SwiftUI
import SortyModels
import SortyLearnings

@MainActor
public protocol OrganizerAutomation: AnyObject {
    var isAutomationGranted: Bool { get }
    var autoSelectOrganizedFolders: Bool { get }
    func refreshFinder(at url: URL)
    func selectOrganizedFolders(folderURLs: [URL])
}

@MainActor
public struct OrganizerSpan {
    private let finishAction: () -> Void

    public init(finish: @escaping () -> Void) { finishAction = finish }
    public func finish() { finishAction() }
}

/// Core installs live services before organization starts. Tests can supply
/// only the callbacks needed by the behavior they exercise.
@MainActor
public enum OrganizerServices {
    public static var logSink: (String, ModelLogLevel, String) -> Void = {
        ModelLog.log($0, level: $1, category: $2)
    }
    public static var workflowReporter: (String, String, String, [String: Any]) -> Void =
        { _, _, _, _ in }
    public static var bucketCount: (Int) -> String = { _ in "unknown" }
    public static var describeDuration: (TimeInterval) -> [String: Any] = { _ in [:] }
    public static var describeGeneration: (GenerationStats?) -> [String: Any] = { _ in [:] }
    public static var errorReporter: (any Error, String, String, Bool) -> Void =
        { _, _, _, _ in }
    public static var spanStarter: (String, String, String) -> OrganizerSpan? =
        { _, _, _ in nil }
    public static var previewReporter: (String, String?, UUID?, UUID?) -> Void =
        { _, _, _, _ in }
    public static var errorNotification: (String, String?, Bool) -> Void =
        { _, _, _ in }
    public static var hudReporter: (String, String, String, Color, String?) -> Void =
        { _, _, _, _, _ in }
    public static var learningConcernReporter: (LearningExclusionConcern, String) -> Void =
        { _, _ in }
    public static var attentionRequester: () -> Void = {}
    public static var visionSupportChecker: (String, AIProvider) -> Bool = { _, _ in false }
    public static var keychainReader: (String) -> String? = { _ in nil }
    public static var finderSelectionReader: () async -> [URL]? = { nil }

    public static func log(
        _ message: @autoclosure () -> String,
        level: ModelLogLevel = .info,
        category: String = "General"
    ) {
        logSink(message(), level, category)
    }

    public static func captureWorkflow(
        workflow: String,
        stage: String,
        outcome: String,
        properties: [String: Any] = [:]
    ) {
        workflowReporter(workflow, stage, outcome, properties)
    }

    public static func countBucket(_ count: Int) -> String { bucketCount(count) }
    public static func durationProperties(_ duration: TimeInterval) -> [String: Any] {
        describeDuration(duration)
    }
    public static func generationDurationProperties(_ stats: GenerationStats?) -> [String: Any] {
        describeGeneration(stats)
    }

    public static func capture(
        error: any Error,
        feature: String,
        operation: String,
        recoverable: Bool = true
    ) {
        errorReporter(error, feature, operation, recoverable)
    }

    public static func startSpan(
        name: String,
        operation: String,
        feature: String
    ) -> OrganizerSpan? {
        spanStarter(name, operation, feature)
    }

    public static func previewReady(
        folderName: String,
        folderPath: String?,
        planID: UUID?,
        originSessionID: UUID?
    ) {
        previewReporter(folderName, folderPath, planID, originSessionID)
    }

    public static func showError(message: String, folderPath: String?, isCritical: Bool) {
        errorNotification(message, folderPath, isCritical)
    }

    public static func showHUDInfo(
        title: String,
        message: String,
        icon: String,
        iconColor: Color,
        identifier: String?
    ) {
        hudReporter(title, message, icon, iconColor, identifier)
    }
}
