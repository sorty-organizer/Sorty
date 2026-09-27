import Foundation

/// Core supplies the analytics implementation before duplicate scans start.
@MainActor
public enum SortyFSTelemetry {
    public static var reportWorkflow: (String, String, String, [String: Any]) -> Void =
        { _, _, _, _ in }
    public static var bucketCount: (Int) -> String = { _ in "unknown" }
    public static var describeDuration: (TimeInterval) -> [String: Any] = { _ in [:] }

    public static func captureWorkflow(
        workflow: String,
        stage: String,
        outcome: String,
        properties: [String: Any] = [:]
    ) {
        reportWorkflow(workflow, stage, outcome, properties)
    }

    public static func countBucket(_ count: Int) -> String { bucketCount(count) }

    public static func durationProperties(_ duration: TimeInterval) -> [String: Any] {
        describeDuration(duration)
    }
}
