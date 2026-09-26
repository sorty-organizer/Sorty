import Foundation

public struct OrganizationQualityCorpusCase: Codable, Sendable {
    public let id: String
    public let description: String
    public let decisions: [OrganizationQualityDecision]
    public let manualPreviewEdits: Int
    public let wasReverted: Bool

    public init(
        id: String,
        description: String,
        decisions: [OrganizationQualityDecision],
        manualPreviewEdits: Int = 0,
        wasReverted: Bool = false
    ) {
        self.id = id
        self.description = description
        self.decisions = decisions
        self.manualPreviewEdits = manualPreviewEdits
        self.wasReverted = wasReverted
    }
}

public struct OrganizationQualityDecision: Codable, Sendable {
    public let sourcePath: String
    public let expectedDestination: String?
    public let expectedRename: String?
    public let mustKeepOriginalName: Bool
    public let shouldRemainUncertain: Bool
    public let observedDestination: String?
    public let placementOutcome: QualityDecisionOutcome?
    public let observedRename: String?
    public let renameOutcome: QualityDecisionOutcome?
    public let renameConfidence: Double?
    public let wasSurfacedForReview: Bool
    public let isObserved: Bool?

    public init(
        sourcePath: String,
        expectedDestination: String? = nil,
        expectedRename: String? = nil,
        mustKeepOriginalName: Bool = false,
        shouldRemainUncertain: Bool = false,
        observedDestination: String? = nil,
        placementOutcome: QualityDecisionOutcome? = nil,
        observedRename: String? = nil,
        renameOutcome: QualityDecisionOutcome? = nil,
        renameConfidence: Double? = nil,
        wasSurfacedForReview: Bool = false,
        isObserved: Bool? = true
    ) {
        self.sourcePath = sourcePath
        self.expectedDestination = expectedDestination
        self.expectedRename = expectedRename
        self.mustKeepOriginalName = mustKeepOriginalName
        self.shouldRemainUncertain = shouldRemainUncertain
        self.observedDestination = observedDestination
        self.placementOutcome = placementOutcome
        self.observedRename = observedRename
        self.renameOutcome = renameOutcome
        self.renameConfidence = renameConfidence.map { min(max($0, 0), 1) }
        self.wasSurfacedForReview = wasSurfacedForReview
        self.isObserved = isObserved
    }
}

public enum QualityDecisionOutcome: String, Codable, Sendable {
    case accepted
    case edited
    case rejected
}

public struct OrganizationQualityReport: Codable, Sendable {
    public let caseCount: Int
    public let fileCount: Int
    public let observedCaseCount: Int
    public let observedFileCount: Int
    public let placementAcceptanceRate: Double?
    public let placementExpectationMatchRate: Double?
    public let renameAcceptanceRate: Double?
    public let renameEditRate: Double?
    public let renameRejectionRate: Double?
    public let renameExpectationMatchRate: Double?
    public let protectedNamePreservationRate: Double?
    public let ambiguousReviewRate: Double?
    public let revertRate: Double?
    public let manualPreviewEditsPer100Files: Double?
    public let calibrationError: Double?
    public let calibrationBins: [RenameCalibrationBin]
}

public struct RenameCalibrationBin: Codable, Sendable {
    public let lowerBound: Double
    public let upperBound: Double
    public let sampleCount: Int
    public let meanConfidence: Double
    public let acceptanceRate: Double
}

public enum OrganizationQualityEvaluator {
    public static func evaluate(_ cases: [OrganizationQualityCorpusCase]) -> OrganizationQualityReport {
        let decisions = cases.flatMap(\.decisions)
        let observedDecisions = decisions.filter { $0.isObserved == true }
        let observedCases = cases.filter { $0.decisions.contains { $0.isObserved == true } }
        let placementOutcomes = observedDecisions.compactMap(\.placementOutcome)
        let renameOutcomes = observedDecisions.compactMap(\.renameOutcome)

        let placementExpected = observedDecisions.filter { !$0.shouldRemainUncertain }
        let placementMatches = placementExpected.filter {
            normalizedPath($0.expectedDestination) == normalizedPath($0.observedDestination)
        }.count

        let renameExpected = observedDecisions.filter { $0.expectedRename != nil }
        let renameMatches = renameExpected.filter {
            normalizedName($0.expectedRename) == normalizedName($0.observedRename)
        }.count
        let protectedNames = observedDecisions.filter(\.mustKeepOriginalName)
        let protectedPreserved = protectedNames.filter { decision in
            decision.observedRename == nil
                || normalizedName(decision.observedRename) == normalizedName(URL(fileURLWithPath: decision.sourcePath).lastPathComponent)
        }.count
        let ambiguous = observedDecisions.filter(\.shouldRemainUncertain)
        let reviewedAmbiguous = ambiguous.filter(\.wasSurfacedForReview).count
        let calibrationSamples = observedDecisions.compactMap { decision -> (Double, Bool)? in
            guard let confidence = decision.renameConfidence, let outcome = decision.renameOutcome else { return nil }
            return (confidence, outcome == .accepted)
        }
        let bins = calibrationBins(for: calibrationSamples)
        let calibrationError = weightedCalibrationError(bins: bins, sampleCount: calibrationSamples.count)

        return OrganizationQualityReport(
            caseCount: cases.count,
            fileCount: decisions.count,
            observedCaseCount: observedCases.count,
            observedFileCount: observedDecisions.count,
            placementAcceptanceRate: rate(placementOutcomes.filter { $0 == .accepted }.count, placementOutcomes.count),
            placementExpectationMatchRate: rate(placementMatches, placementExpected.count),
            renameAcceptanceRate: rate(renameOutcomes.filter { $0 == .accepted }.count, renameOutcomes.count),
            renameEditRate: rate(renameOutcomes.filter { $0 == .edited }.count, renameOutcomes.count),
            renameRejectionRate: rate(renameOutcomes.filter { $0 == .rejected }.count, renameOutcomes.count),
            renameExpectationMatchRate: rate(renameMatches, renameExpected.count),
            protectedNamePreservationRate: rate(protectedPreserved, protectedNames.count),
            ambiguousReviewRate: rate(reviewedAmbiguous, ambiguous.count),
            revertRate: rate(observedCases.filter(\.wasReverted).count, observedCases.count),
            manualPreviewEditsPer100Files: observedDecisions.isEmpty
                ? nil
                : Double(observedCases.reduce(0) { $0 + $1.manualPreviewEdits }) / Double(observedDecisions.count) * 100,
            calibrationError: calibrationError,
            calibrationBins: bins
        )
    }

    private static func calibrationBins(for samples: [(Double, Bool)]) -> [RenameCalibrationBin] {
        (0..<10).compactMap { index in
            let lower = Double(index) / 10
            let upper = Double(index + 1) / 10
            let members = samples.filter { sample in
                sample.0 >= lower && (index == 9 ? sample.0 <= upper : sample.0 < upper)
            }
            guard !members.isEmpty else { return nil }
            return RenameCalibrationBin(
                lowerBound: lower,
                upperBound: upper,
                sampleCount: members.count,
                meanConfidence: members.reduce(0) { $0 + $1.0 } / Double(members.count),
                acceptanceRate: Double(members.filter(\.1).count) / Double(members.count)
            )
        }
    }

    private static func weightedCalibrationError(bins: [RenameCalibrationBin], sampleCount: Int) -> Double? {
        guard sampleCount > 0 else { return nil }
        return bins.reduce(0) { total, bin in
            total + abs(bin.meanConfidence - bin.acceptanceRate) * Double(bin.sampleCount) / Double(sampleCount)
        }
    }

    private static func rate(_ numerator: Int, _ denominator: Int) -> Double? {
        denominator == 0 ? nil : Double(numerator) / Double(denominator)
    }

    private static func normalizedPath(_ path: String?) -> String? {
        path?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    private static func normalizedName(_ name: String?) -> String? {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
