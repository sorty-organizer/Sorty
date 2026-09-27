import SortyFS

/// Keeps duplicate scan telemetry in Core without coupling file operations to it.
public enum LiveSortyFSServices {
    @MainActor public static func configure() {
        SortyFSTelemetry.reportWorkflow = { workflow, stage, outcome, properties in
            AnalyticsManager.shared.captureWorkflow(
                workflow: workflow,
                stage: stage,
                outcome: outcome,
                properties: properties
            )
        }
        SortyFSTelemetry.bucketCount = { AnalyticsManager.countBucket($0) }
        SortyFSTelemetry.describeDuration = { AnalyticsManager.durationProperties($0) }
    }
}
