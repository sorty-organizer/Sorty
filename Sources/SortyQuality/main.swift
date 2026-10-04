import Foundation
import SortyModels
import SortyOrganizer
import SortyQualitySupport

@main
enum SortyQualityCommand {
    @MainActor
    static func main() async throws {
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
        var cases = try files.map { try decoder.decode(OrganizationQualityCorpusCase.self, from: Data(contentsOf: $0)) }
        if arguments.contains("--replay") {
            guard let configIndex = arguments.firstIndex(of: "--config"), arguments.indices.contains(configIndex + 1),
                  let outputIndex = arguments.firstIndex(of: "--output"), arguments.indices.contains(outputIndex + 1) else {
                throw CommandError.usage
            }
            var config = try decoder.decode(AIConfig.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[configIndex + 1])))
            if let key = ProcessInfo.processInfo.environment["SORTY_QUALITY_API_KEY"], !key.isEmpty {
                config.apiKey = key
            }
            let outputURL = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
            guard outputURL.resolvingSymlinksInPath().standardizedFileURL != corpusURL.resolvingSymlinksInPath().standardizedFileURL else {
                throw CommandError.outputMatchesCorpus
            }
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            for index in cases.indices {
                try Task.checkCancellation()
                cases[index] = try await replay(cases[index], caseURL: files[index], config: config)
                try encoder.encode(cases[index]).write(to: outputURL.appendingPathComponent(files[index].lastPathComponent), options: .atomic)
            }
            let report = OrganizationQualityEvaluator.evaluate(cases)
            let summaryURL = outputURL.appendingPathComponent("_summary", isDirectory: true)
            try FileManager.default.createDirectory(at: summaryURL, withIntermediateDirectories: true)
            try encoder.encode(report).write(to: summaryURL.appendingPathComponent("report.json"), options: .atomic)
        }
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

    /// Replay the production preview pipeline without applying file operations,
    /// learning from its own output, or writing to the user's app history.
    @MainActor
    private static func replay(_ corpusCase: OrganizationQualityCorpusCase, caseURL: URL, config: AIConfig) async throws -> OrganizationQualityCorpusCase {
        guard let directoryPath = corpusCase.replayDirectory, !directoryPath.isEmpty else {
            throw CommandError.missingReplayDirectory(corpusCase.id)
        }
        let directory = directoryPath.hasPrefix("/")
            ? URL(fileURLWithPath: directoryPath, isDirectory: true)
            : caseURL.deletingLastPathComponent().appendingPathComponent(directoryPath, isDirectory: true)
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("sorty-quality-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "SortyQuality.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw CommandError.invalidReplay }
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: storage)
        }
        let history = OrganizationHistory(userDefaults: defaults, storageDirectory: storage)
        let organizer = FolderOrganizer(history: history)
        OrganizerServices.logSink = { _, _, _ in }
        try await organizer.configure(with: config)
        let started = Date()
        try await organizer.organize(directory: directory, customPrompt: corpusCase.replayInstructions)
        guard let plan = organizer.currentPlan else { throw CommandError.invalidReplay }
        let duration = Date().timeIntervalSince(started)

        struct Observation {
            let destination: String?
            let rename: String?
            let renameConfidence: Double?
            let needsReview: Bool
        }
        var observations: [String: Observation] = [:]
        func record(_ file: FileItem, destination: String?, mapping: FileRenameMapping?, needsReview: Bool) {
            let source = URL(fileURLWithPath: file.path).standardizedFileURL.path
            observations[source] = Observation(destination: destination, rename: mapping?.finalFilename,
                                               renameConfidence: mapping?.renameConfidence, needsReview: needsReview)
        }
        func visit(_ folder: FolderSuggestion, parent: String) {
            let path = parent.isEmpty ? folder.folderName : parent + "/" + folder.folderName
            let mappings = Dictionary(folder.fileRenameMappings.map { ($0.originalFile.id, $0) }, uniquingKeysWith: { first, _ in first })
            for file in folder.files {
                let originalParent = ((file.relativePath ?? file.displayName) as NSString).deletingLastPathComponent
                let destination = path == "." || path == originalParent ? nil : path
                record(file, destination: destination, mapping: mappings[file.id], needsReview: plan.needsReview)
            }
            for child in folder.subfolders { visit(child, parent: path) }
        }
        for folder in plan.suggestions { visit(folder, parent: "") }
        for file in plan.unorganizedFiles { record(file, destination: nil, mapping: nil, needsReview: true) }

        let decisions = try corpusCase.decisions.map { decision in
            let source = decision.sourcePath.hasPrefix("/")
                ? URL(fileURLWithPath: decision.sourcePath)
                : directory.appendingPathComponent(decision.sourcePath)
            guard let observation = observations[source.standardizedFileURL.path] else {
                throw CommandError.missingObservation(decision.sourcePath)
            }
            return OrganizationQualityDecision(
                sourcePath: decision.sourcePath, expectedDestination: decision.expectedDestination,
                expectedRename: decision.expectedRename, mustKeepOriginalName: decision.mustKeepOriginalName,
                shouldRemainUncertain: decision.shouldRemainUncertain, observedDestination: observation.destination,
                observedRename: observation.rename, renameConfidence: observation.renameConfidence,
                wasSurfacedForReview: observation.needsReview, isObserved: true,
                acceptableDestinations: decision.acceptableDestinations, expectedProjectPath: decision.expectedProjectPath
            )
        }
        return OrganizationQualityCorpusCase(
            id: corpusCase.id, description: corpusCase.description, decisions: decisions,
            replayDirectory: corpusCase.replayDirectory, replayInstructions: corpusCase.replayInstructions,
            isReplay: true, replayDurationSeconds: duration, replayNeedsReview: plan.needsReview
        )
    }

    private static func printMarkdown(_ report: OrganizationQualityReport) {
        print("# Sorty quality report")
        print("")
        print("Cases: \(report.caseCount), files: \(report.fileCount)")
        print("Observed cases: \(report.observedCaseCount), observed files: \(report.observedFileCount)")
        printMetric("Placement acceptance", report.placementAcceptanceRate)
        printMetric("Placement expectation match", report.placementExpectationMatchRate)
        printMetric("Project preservation", report.projectPreservationRate)
        printMetric("Replay plans needing review", report.replayNeedsReviewRate)
        if let seconds = report.meanReplayDurationSeconds {
            print(String(format: "Mean preview replay duration: %.2f seconds", seconds))
        }
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
    case outputMatchesCorpus
    case missingReplayDirectory(String)
    case missingObservation(String)
    case invalidReplay

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: swift run SortyQuality --corpus <directory> [--json] [--replay --config <AIConfig.json> --output <directory>]"
        case .emptyCorpus(let path):
            return "No JSON corpus cases found in \(path)"
        case .outputMatchesCorpus:
            return "Replay output must be separate from the reviewed corpus."
        case .missingReplayDirectory(let id):
            return "Corpus case \(id) needs replayDirectory before it can be replayed."
        case .missingObservation(let source):
            return "The preview did not include labeled source \(source). Check the fixture path and scanner exclusions."
        case .invalidReplay:
            return "The replay did not produce an organization preview."
        }
    }
}
