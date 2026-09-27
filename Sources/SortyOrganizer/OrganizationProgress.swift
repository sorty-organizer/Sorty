import Foundation
import SortyFileSystem
import SortyModels
import SortyAI
import SortyLearnings
import SortyFS


/// Progress update for real-time UI feedback
public struct OrganizationProgress: Sendable {
    public let phase: Phase
    public let current: Int
    public let total: Int
    public let detail: String?

    public enum Phase: String, Sendable {
        case scanning = "Scanning"
        case analyzing = "Analyzing"
        case aiProcessing = "AI Processing"
        case validating = "Validating"
        case applying = "Applying"
        case complete = "Complete"
    }

    public var percentage: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }

    public var phaseWeight: Double {
        switch phase {
        case .scanning: return 0.15
        case .analyzing: return 0.15
        case .aiProcessing: return 0.50
        case .validating: return 0.10
        case .applying: return 0.10
        case .complete: return 1.0
        }
    }

    public var phaseBaseProgress: Double {
        switch phase {
        case .scanning: return 0.0
        case .analyzing: return 0.15
        case .aiProcessing: return 0.30
        case .validating: return 0.80
        case .applying: return 0.90
        case .complete: return 1.0
        }
    }

    public var overallProgress: Double {
        if phase == .complete { return 1.0 }
        return phaseBaseProgress + (percentage * (phaseWeight - phaseBaseProgress.truncatingRemainder(dividingBy: 1.0)))
    }
}

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

    public var hasWarning: Bool {
        warningMessage != nil
    }

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
