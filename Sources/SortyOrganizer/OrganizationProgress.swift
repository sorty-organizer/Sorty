/// Fine-grained activity inside the AI analysis phase. The coarse
/// `OrganizationState` stays `.organizing` across all of these, so the UI
/// uses this to label live progress accurately (for example, distinguishing
/// local vision image preparation from the network wait for a response).
public enum AIAnalysisActivity: Equatable, Sendable {
    case none
    case preparingImages
    case requesting
    case validating
}

/// Progress backed by a concrete count of completed work items.
public struct MeasuredWorkProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int

    public var percentage: Double {
        guard total > 0 else { return 0 }
        return max(0, min(1, Double(completed) / Double(total)))
    }

    public init(completed: Int, total: Int) {
        self.total = max(0, total)
        self.completed = max(0, min(completed, self.total))
    }
}

public struct VisionAnalysisSummary: Equatable, Sendable {
    public let analyzedCount: Int
    public let totalImageCount: Int
    public let skippedCount: Int
    public let failedCount: Int
    public let warningMessage: String?

    public var summaryText: String {
        var text = "Analyzed \(analyzedCount) of \(totalImageCount) images with Sorty Vision"
        if skippedCount > 0 {
            text += " (\(skippedCount) skipped)"
        }
        if failedCount > 0 {
            text += " (\(failedCount) failed to preprocess)"
        }
        return text
    }
}
