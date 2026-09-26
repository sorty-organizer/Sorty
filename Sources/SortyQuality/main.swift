import Foundation
import SortyQualitySupport

@main
enum SortyQualityCommand {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let corpusIndex = arguments.firstIndex(of: "--corpus"), arguments.indices.contains(corpusIndex + 1) else {
            throw CommandError.usage
        }
        let corpusURL = URL(fileURLWithPath: arguments[corpusIndex + 1], isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: corpusURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw CommandError.emptyCorpus(corpusURL.path) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cases = try files.map { try decoder.decode(OrganizationQualityCorpusCase.self, from: Data(contentsOf: $0)) }
        let report = OrganizationQualityEvaluator.evaluate(cases)

        if arguments.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        } else {
            printMarkdown(report)
        }
    }

    private static func printMarkdown(_ report: OrganizationQualityReport) {
        print("# Sorty quality report")
        print("")
        print("Cases: \(report.caseCount), files: \(report.fileCount)")
        print("Observed cases: \(report.observedCaseCount), observed files: \(report.observedFileCount)")
        printMetric("Placement acceptance", report.placementAcceptanceRate)
        printMetric("Placement expectation match", report.placementExpectationMatchRate)
        printMetric("Rename acceptance", report.renameAcceptanceRate)
        printMetric("Rename edit", report.renameEditRate)
        printMetric("Rename rejection", report.renameRejectionRate)
        printMetric("Rename expectation match", report.renameExpectationMatchRate)
        printMetric("Protected-name preservation", report.protectedNamePreservationRate)
        printMetric("Ambiguous items sent to review", report.ambiguousReviewRate)
        printMetric("Undo or revert", report.revertRate)
        if let edits = report.manualPreviewEditsPer100Files {
            print(String(format: "Manual preview edits per 100 files: %.2f", edits))
        }
        printMetric("Rename calibration error", report.calibrationError)
        for bin in report.calibrationBins {
            print(String(
                format: "Confidence %.0f-%.0f%%: n=%d, mean %.1f%%, accepted %.1f%%",
                bin.lowerBound * 100,
                bin.upperBound * 100,
                bin.sampleCount,
                bin.meanConfidence * 100,
                bin.acceptanceRate * 100
            ))
        }
    }

    private static func printMetric(_ label: String, _ value: Double?) {
        guard let value else {
            print("\(label): n/a")
            return
        }
        print(String(format: "\(label): %.1f%%", value * 100))
    }
}

private enum CommandError: LocalizedError {
    case usage
    case emptyCorpus(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: swift run SortyQuality --corpus <directory> [--json]"
        case .emptyCorpus(let path):
            return "No JSON corpus cases found in \(path)"
        }
    }
}
