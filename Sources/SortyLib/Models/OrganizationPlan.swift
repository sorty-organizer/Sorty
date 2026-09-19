//
//  OrganizationPlan.swift
//  Sorty
//
//  Complete Organization Proposal
//

import Foundation

public struct UnorganizedFile: Codable, Hashable, Sendable, Identifiable {
    public var id: String { filename }
    public let filename: String
    public let reason: String
}

public struct LearningToolCall: Codable, Hashable, Sendable {
    public static let excludeCurrentRunToolName = "exclude_current_run_from_learning"

    public let name: String
    public let reason: String
    public let source: String

    public init(name: String, reason: String, source: String) {
        self.name = name
        self.reason = reason
        self.source = source
    }

    public var excludesCurrentRun: Bool {
        name == Self.excludeCurrentRunToolName
            && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct OrganizationPlan: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var sessionName: String?
    public var suggestions: [FolderSuggestion]
    public var unorganizedFiles: [FileItem] // Keep for backward compatibility/UI logic
    public var unorganizedDetails: [UnorganizedFile]
    public var notes: String
    public var timestamp: Date
    public var version: Int
    public var generationStats: GenerationStats?
    public var qualityAssessment: PlanQualityAssessment?
    public var learningToolCall: LearningToolCall?
    /// True when the AI response omitted, garbled, or hallucinated mappings.
    /// UI should surface a retry hint instead of presenting the plan as fully valid.
    public var isPartial: Bool
    public var needsReview: Bool
    public var parseWarnings: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionName
        case suggestions
        case unorganizedFiles
        case unorganizedDetails
        case notes
        case timestamp
        case version
        case generationStats
        case qualityAssessment
        case learningToolCall
        case isPartial
        case needsReview
        case parseWarnings
    }

    public init(
        id: UUID = UUID(),
        sessionName: String? = nil,
        suggestions: [FolderSuggestion] = [],
        unorganizedFiles: [FileItem] = [],
        unorganizedDetails: [UnorganizedFile] = [],
        notes: String = "",
        timestamp: Date = Date(),
        version: Int = 1,
        generationStats: GenerationStats? = nil,
        qualityAssessment: PlanQualityAssessment? = nil,
        learningToolCall: LearningToolCall? = nil,
        isPartial: Bool = false,
        needsReview: Bool = false,
        parseWarnings: [String] = []
    ) {
        self.id = id
        self.sessionName = sessionName
        self.suggestions = suggestions
        self.unorganizedFiles = unorganizedFiles
        self.unorganizedDetails = unorganizedDetails
        self.notes = notes
        self.timestamp = timestamp
        self.version = version
        self.generationStats = generationStats
        self.qualityAssessment = qualityAssessment
        self.learningToolCall = learningToolCall
        self.isPartial = isPartial
        self.needsReview = needsReview
        self.parseWarnings = parseWarnings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName)
        suggestions = try container.decodeIfPresent([FolderSuggestion].self, forKey: .suggestions) ?? []
        unorganizedFiles = try container.decodeIfPresent([FileItem].self, forKey: .unorganizedFiles) ?? []
        unorganizedDetails = try container.decodeIfPresent([UnorganizedFile].self, forKey: .unorganizedDetails) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        generationStats = try container.decodeIfPresent(GenerationStats.self, forKey: .generationStats)
        qualityAssessment = try container.decodeIfPresent(PlanQualityAssessment.self, forKey: .qualityAssessment)
        learningToolCall = try container.decodeIfPresent(LearningToolCall.self, forKey: .learningToolCall)
        isPartial = try container.decodeIfPresent(Bool.self, forKey: .isPartial) ?? false
        needsReview = try container.decodeIfPresent(Bool.self, forKey: .needsReview) ?? false
        parseWarnings = try container.decodeIfPresent([String].self, forKey: .parseWarnings) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(sessionName, forKey: .sessionName)
        try container.encode(suggestions, forKey: .suggestions)
        try container.encode(unorganizedFiles, forKey: .unorganizedFiles)
        try container.encode(unorganizedDetails, forKey: .unorganizedDetails)
        try container.encode(notes, forKey: .notes)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(generationStats, forKey: .generationStats)
        try container.encodeIfPresent(qualityAssessment, forKey: .qualityAssessment)
        try container.encodeIfPresent(learningToolCall, forKey: .learningToolCall)
        try container.encode(isPartial, forKey: .isPartial)
        try container.encode(needsReview, forKey: .needsReview)
        try container.encode(parseWarnings, forKey: .parseWarnings)
    }
    
    public var totalFiles: Int {
        suggestions.reduce(0) { $0 + $1.totalFileCount } + unorganizedFiles.count
    }
    
    public var totalFolders: Int {
        func countFolders(_ folders: [FolderSuggestion]) -> Int {
            folders.count + folders.reduce(0) { $0 + countFolders($1.subfolders) }
        }
        return countFolders(suggestions)
    }
}

public struct PlanQualityAssessment: Codable, Hashable, Sendable {
    public static let passingScore = 75

    public let score: Int
    public let issues: [PlanQualityIssue]
    public let didRetry: Bool

    public init(score: Int, issues: [PlanQualityIssue], didRetry: Bool = false) {
        self.score = min(max(score, 0), 100)
        self.issues = issues
        self.didRetry = didRetry
    }

    public var passes: Bool { score >= Self.passingScore }
    public var uncertainFileIDs: Set<UUID> {
        Set(issues
            .filter { $0.kind == .unorganizedFolderDestination }
            .flatMap(\.fileIDs))
    }
}

public struct PlanQualityIssue: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case duplicateFolderNames
        case vagueOrSingleFileFolder
        case excessiveUnorganizedFiles
        case unorganizedFolderDestination
        case mixedFileTypes
        case unnecessaryNesting
        case existingConventionMismatch
        case missingExplanation
    }

    public let id: UUID
    public let kind: Kind
    public let message: String
    public let folderPaths: [String]
    public let fileIDs: [UUID]
    public let deduction: Int

    public init(
        id: UUID = UUID(),
        kind: Kind,
        message: String,
        folderPaths: [String],
        fileIDs: [UUID],
        deduction: Int
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.folderPaths = folderPaths
        self.fileIDs = fileIDs
        self.deduction = deduction
    }
}

/// Enforces workflow-mode safety at the filesystem boundary instead of relying on AI output.
enum OrganizationModePlanEnforcer {
    static func enforce(
        _ plan: OrganizationPlan,
        mode: OrganizationMode,
        baseURL: URL
    ) -> OrganizationPlan {
        switch mode {
        case .organize:
            return removingRenameSuggestions(from: plan)
        case .organizeAndRename:
            return plan
        case .renameOnly:
            return keepingFilesInPlace(in: plan, baseURL: baseURL)
        }
    }

    private static func removingRenameSuggestions(from plan: OrganizationPlan) -> OrganizationPlan {
        var updated = plan
        updated.suggestions = updated.suggestions.map(removingRenameSuggestions)
        return updated
    }

    private static func removingRenameSuggestions(from suggestion: FolderSuggestion) -> FolderSuggestion {
        var updated = suggestion
        updated.files = updated.files.map { file in
            var updatedFile = file
            updatedFile.suggestedFilename = nil
            return updatedFile
        }
        updated.fileRenameMappings = []
        updated.subfolders = updated.subfolders.map(removingRenameSuggestions)
        return updated
    }

    private struct RenameOnlyGroup {
        var files: [FileItem] = []
        var fileIDs: Set<UUID> = []
        var renameMappings: [FileRenameMapping] = []
        var tagMappings: [FileTagMapping] = []
    }

    private static func keepingFilesInPlace(
        in plan: OrganizationPlan,
        baseURL: URL
    ) -> OrganizationPlan {
        let canonicalBasePath = canonicalPath(baseURL)
        var groups: [String: RenameOnlyGroup] = [:]
        var rejectedFiles: [FileItem] = []

        func collect(_ suggestion: FolderSuggestion) {
            let renameMappings = Dictionary(
                suggestion.fileRenameMappings.map { ($0.originalFile.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            let tagMappings = Dictionary(
                suggestion.fileTagMappings.map { ($0.originalFile.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )

            for file in suggestion.files {
                guard let fileURL = file.url else {
                    rejectedFiles.append(file)
                    continue
                }

                let parentPath = canonicalPath(fileURL.deletingLastPathComponent())
                guard isPath(parentPath, within: canonicalBasePath) else {
                    rejectedFiles.append(file)
                    continue
                }

                let relativeParent = relativePath(of: parentPath, within: canonicalBasePath)
                var group = groups[relativeParent, default: RenameOnlyGroup()]
                if group.fileIDs.insert(file.id).inserted {
                    group.files.append(file)
                    if let mapping = renameMappings[file.id] {
                        group.renameMappings.append(mapping)
                    }
                    if let mapping = tagMappings[file.id] {
                        group.tagMappings.append(mapping)
                    }
                }
                groups[relativeParent] = group
            }

            suggestion.subfolders.forEach(collect)
        }

        plan.suggestions.forEach(collect)

        var updated = plan
        updated.suggestions = groups.keys.sorted().map { relativeParent in
            let group = groups[relativeParent] ?? RenameOnlyGroup()
            return FolderSuggestion(
                folderName: relativeParent,
                description: "Keep files in their current folder",
                files: group.files,
                reasoning: "Rename in place",
                fileRenameMappings: group.renameMappings,
                fileTagMappings: group.tagMappings
            )
        }

        var unorganizedIDs = Set(updated.unorganizedFiles.map(\.id))
        for file in rejectedFiles where unorganizedIDs.insert(file.id).inserted {
            updated.unorganizedFiles.append(file)
        }
        return updated
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isPath(_ path: String, within rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func relativePath(of path: String, within rootPath: String) -> String {
        guard path != rootPath else { return "" }
        return String(path.dropFirst(rootPath.count + 1))
    }
}


public struct GenerationStats: Codable, Sendable, Hashable {
    /// A manual pass includes inspecting the file, deciding where it belongs,
    /// moving or renaming it, and checking the result.
    public static let estimatedManualSecondsPerFile: TimeInterval = 20

    public let duration: TimeInterval
    public let tps: Double
    public let ttft: TimeInterval
    public let totalTokens: Int
    public let model: String
    
    // Additional metrics
    public var filesScanned: Int?
    public var totalFileSize: Int64?
    public var duplicatesFound: Int?
    public var promptTokens: Int?
    public var retryCount: Int?
    public var provider: String?
    public var scanDuration: TimeInterval?
    public var estimatedCost: Decimal?
    
    /// User productivity metrics
    public var estimatedTimeSaved: TimeInterval {
        Self.estimatedTimeSaved(forFileCount: filesScanned ?? 0)
    }

    public static func estimatedTimeSaved(forFileCount fileCount: Int) -> TimeInterval {
        Double(max(fileCount, 0)) * estimatedManualSecondsPerFile
    }
    
    /// Automatically calculated cost based on model and tokens if estimatedCost is nil
    public var computedCost: Decimal {
        if let cost = estimatedCost { return cost }
        return CostCalculator.calculate(
            model: model,
            inputTokens: promptTokens ?? 0,
            outputTokens: totalTokens
        )
    }

    public var responseTokens: Int {
        totalTokens
    }

    public var totalContextTokens: Int? {
        guard let promptTokens else { return nil }
        return promptTokens + totalTokens
    }

    public var hasBillableCost: Bool {
        computedCost > 0
    }

    public var formattedTotalFileSize: String? {
        guard let totalFileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: totalFileSize, countStyle: .file)
    }

    public var compactModelName: String {
        model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ".")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? model
    }

    public static func formatDuration(_ interval: TimeInterval) -> String {
        let normalizedInterval = max(interval, 0)
        if normalizedInterval < 10 {
            return String(format: "%.1fs", normalizedInterval)
        }
        if normalizedInterval < 60 {
            return String(format: "%.0fs", normalizedInterval)
        }
        if normalizedInterval < 3600 {
            let minutes = Int(normalizedInterval / 60)
            let seconds = Int(normalizedInterval.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(seconds)s"
        }

        let hours = Int(normalizedInterval / 3600)
        let minutes = Int((normalizedInterval.truncatingRemainder(dividingBy: 3600)) / 60)
        return "\(hours)h \(minutes)m"
    }

    public static func formatCount(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    public static func formatCost(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        let number = NSDecimalNumber(decimal: value)
        let usesExtendedPrecision = number.doubleValue < 0.01
        formatter.minimumFractionDigits = usesExtendedPrecision ? 4 : 2
        formatter.maximumFractionDigits = usesExtendedPrecision ? 4 : 2
        return formatter.string(from: number) ?? "$0.00"
    }
    
    public init(
        duration: TimeInterval, 
        tps: Double, 
        ttft: TimeInterval, 
        totalTokens: Int, 
        model: String,
        filesScanned: Int? = nil,
        totalFileSize: Int64? = nil,
        duplicatesFound: Int? = nil,
        promptTokens: Int? = nil,
        retryCount: Int? = nil,
        provider: String? = nil,
        scanDuration: TimeInterval? = nil,
        estimatedCost: Decimal? = nil
    ) {
        self.duration = duration
        self.tps = tps
        self.ttft = ttft
        self.totalTokens = totalTokens
        self.model = model
        self.filesScanned = filesScanned
        self.totalFileSize = totalFileSize
        self.duplicatesFound = duplicatesFound
        self.promptTokens = promptTokens
        self.retryCount = retryCount
        self.provider = provider
        self.scanDuration = scanDuration
        self.estimatedCost = estimatedCost
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
