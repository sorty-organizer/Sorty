//
//  LearningsModels.swift
//  Sorty
//
//  Core data models for "The Learnings" feature - trainable, example-based file organization
//

import Foundation
import SortyModels

// MARK: - Labeled Example

/// A single src → dst mapping provided by user (from manual organization or explicit labeling)
public struct LabeledExample: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let srcPath: String
    public let dstPath: String
    public let metadata: [String: String]?
    public let action: ExampleAction
    public let timestamp: Date
    
    public init(
        id: String = UUID().uuidString,
        srcPath: String,
        dstPath: String,
        metadata: [String: String]? = nil,
        action: ExampleAction = .accept,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.srcPath = srcPath
        self.dstPath = dstPath
        self.metadata = metadata
        self.action = action
        self.timestamp = timestamp
    }
}

/// Action that created the labeled example
public enum ExampleAction: String, Codable, Sendable {
    case accept        // User accepted a proposal
    case edit          // User edited a proposal
    case reject        // User rejected a proposal
    case addToExamples // User explicitly added to examples
}

/// Scope for rule applicability
public enum RuleScope: Codable, Sendable, Equatable, Hashable {
    case global
    case folder(String)
    case activePersona(UUID)
    
    public var displayName: String {
        switch self {
        case .global: return "Global"
        case .folder(let path):
            let name = URL(fileURLWithPath: path).lastPathComponent
            return "Folder: \(name)"
        case .activePersona(let id):
            return "Persona: \(id.uuidString.prefix(8))..."
        }
    }
}

/// Status of an inferred rule in the approval pipeline
public enum RuleStatus: String, Codable, Sendable {
    case active
    case pendingApproval
    case rejected
    case cooldown
}

// MARK: - Session Timeline

public enum OrganizationSessionReaction: String, Codable, Sendable {
    case inProgress
    case unreviewed
    case accepted
    case corrected
    case reverted
    case cancelled
    case regenerated
}

public enum OrganizationSessionEventKind: String, Codable, Sendable {
    case started
    case applied
    case completionPending
    case accepted
    case correction
    case rejection
    case reverted
    case cancelled
    case regenerated
    case additionalInstruction
    case guidingInstruction
    case steeringPrompt
    case renameFeedback
    case feedback // Quick outcome feedback from history view
}

public struct OrganizationSessionEvent: Codable, Identifiable, Sendable {
    public let id: String
    public let timestamp: Date
    public let kind: OrganizationSessionEventKind
    public let summary: String
    public let sourcePath: String?
    public let destinationPath: String?
    public let ruleId: String?
    public let metadata: [String: String]?

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        kind: OrganizationSessionEventKind,
        summary: String,
        sourcePath: String? = nil,
        destinationPath: String? = nil,
        ruleId: String? = nil,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.summary = summary
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.ruleId = ruleId
        self.metadata = metadata
    }
}

public struct OrganizationSessionMovedFile: Codable, Sendable {
    public let sourcePath: String
    public let destinationPath: String
    public let fileName: String
    public let destinationFolderPath: String
    public var ruleId: String?

    public init(
        sourcePath: String,
        destinationPath: String,
        fileName: String? = nil,
        destinationFolderPath: String? = nil,
        ruleId: String? = nil
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.fileName = fileName ?? URL(fileURLWithPath: sourcePath).lastPathComponent
        self.destinationFolderPath = destinationFolderPath ?? URL(fileURLWithPath: destinationPath).deletingLastPathComponent().path
        self.ruleId = ruleId
    }
}

public struct OrganizationSessionFolderPattern: Codable, Sendable {
    public let relativePath: String
    public let folderName: String
    public let fileCount: Int
    public let fileExtensions: [String]
    public let sampleFileNames: [String]

    public init(
        relativePath: String,
        folderName: String,
        fileCount: Int,
        fileExtensions: [String] = [],
        sampleFileNames: [String] = []
    ) {
        self.relativePath = relativePath
        self.folderName = folderName
        self.fileCount = fileCount
        self.fileExtensions = fileExtensions
        self.sampleFileNames = sampleFileNames
    }
}

public struct OrganizationSession: Codable, Identifiable, Sendable {
    public let id: String
    public var timestamp: Date
    public var completedAt: Date?
    public var folderPath: String
    public var historyEntryId: String?
    public var planSummary: String?
    public var steeringPrompts: [String]
    public var additionalInstructions: [UserInstruction]
    public var guidingInstructions: [UserInstruction]
    public var userCorrections: [DirectoryChange]
    public var renameFeedback: [RenameFeedbackEvent]
    public var wasReverted: Bool
    public var appliedRules: [String: String]
    public var usedRuleIds: Set<String>
    public var failedRuleIds: Set<String>
    public var filesMoved: [OrganizationSessionMovedFile]
    public var folderPatterns: [OrganizationSessionFolderPattern]
    public var reaction: OrganizationSessionReaction
    public var timeToReaction: TimeInterval?
    public var events: [OrganizationSessionEvent]

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        completedAt: Date? = nil,
        folderPath: String,
        historyEntryId: String? = nil,
        planSummary: String? = nil,
        steeringPrompts: [String] = [],
        additionalInstructions: [UserInstruction] = [],
        guidingInstructions: [UserInstruction] = [],
        userCorrections: [DirectoryChange] = [],
        renameFeedback: [RenameFeedbackEvent] = [],
        wasReverted: Bool = false,
        appliedRules: [String: String] = [:],
        usedRuleIds: Set<String> = [],
        failedRuleIds: Set<String> = [],
        filesMoved: [OrganizationSessionMovedFile] = [],
        folderPatterns: [OrganizationSessionFolderPattern] = [],
        reaction: OrganizationSessionReaction = .inProgress,
        timeToReaction: TimeInterval? = nil,
        events: [OrganizationSessionEvent] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.completedAt = completedAt
        self.folderPath = folderPath
        self.historyEntryId = historyEntryId
        self.planSummary = planSummary
        self.steeringPrompts = steeringPrompts
        self.additionalInstructions = additionalInstructions
        self.guidingInstructions = guidingInstructions
        self.userCorrections = userCorrections
        self.renameFeedback = renameFeedback
        self.wasReverted = wasReverted
        self.appliedRules = appliedRules
        self.usedRuleIds = usedRuleIds
        self.failedRuleIds = failedRuleIds
        self.filesMoved = filesMoved
        self.folderPatterns = folderPatterns
        self.reaction = reaction
        self.timeToReaction = timeToReaction
        self.events = events
    }

    public var acceptedWithoutCorrections: Bool {
        reaction == .accepted && userCorrections.isEmpty && !wasReverted
    }
}

// MARK: - Inferred Rule

/// A regex + template rule learned from examples
/// Enhanced with success/failure tracking and enable/disable controls
public struct InferredRule: Codable, Identifiable, Sendable {
    public let id: String
    public let pattern: String           // Regex pattern
    public let template: String           // Output template with placeholders
    public let metadataCues: [String]     // e.g., ["exif:DateTimeOriginal", "fs:ctime"]
    public var priority: Int              // Higher = more specific/preferred (0-100)
    public let exampleIds: [String]       // IDs of examples that contributed to this rule
    public let explanation: String        // Human-readable explanation
    
    // Quality tracking
    public var successCount: Int          // Times applied without correction
    public var failureCount: Int          // Times user corrected after applying
    public var isEnabled: Bool            // Can be toggled by user
    public var lastAppliedAt: Date?       // Last time this rule was used
    public var supportCount: Int          // Number of examples supporting this rule
    
    // Initial confidence from LLM (used before usage data is available)
    public var initialConfidence: RuleConfidence?
    
    // Scope & approval
    public var scope: RuleScope
    public var status: RuleStatus
    
    // Evidence lineage
    public var evidenceIds: [String]
    public var evidenceDescription: String?
    
    // Cooling off (for rejected rules)
    public var rejectedAt: Date?
    public var cooldownUntil: Date?
    
    /// Calculate failure rate for quality assessment
    public var failureRate: Double {
        let total = successCount + failureCount
        guard total > 0 else { return 0 }
        return Double(failureCount) / Double(total)
    }
    
    /// Calculate success rate for quality assessment
    public var successRate: Double {
        let total = successCount + failureCount
        guard total > 0 else { return 0 }
        return Double(successCount) / Double(total)
    }
    
    /// Confidence level based on support, failure rate, and initial LLM confidence
    public var confidenceLevel: RuleConfidence {
        // If we have usage data, calculate from that
        let totalUsage = successCount + failureCount
        if totalUsage >= 3 {
            if failureRate > 0.3 { return .low }
            if supportCount >= 5 && failureRate < 0.1 { return .high }
            return .medium
        }
        
        // Otherwise use initial confidence from LLM if available
        if let initial = initialConfidence {
            return initial
        }
        
        // Default fallback based on support count
        if failureRate > 0.3 { return .low }
        if supportCount >= 5 && failureRate < 0.1 { return .high }
        return .medium
    }

    /// True when this rule encodes an avoidance ("do NOT place here") rather than a destination.
    /// Avoid rules use the `AVOID:` template prefix and must never be applied as literal paths.
    public var isAvoidRule: Bool {
        template.hasPrefix("AVOID:")
    }

    /// The folder name this avoid rule warns against, if any.
    public var avoidedFolderName: String? {
        guard isAvoidRule else { return nil }
        let payload = template.dropFirst("AVOID:".count)
        guard let folder = payload.split(separator: "/").first, !folder.isEmpty else { return nil }
        return String(folder)
    }

    /// Whether the rule may currently be applied or surfaced to the model.
    ///
    /// Rejection is a time-limited cooldown: while it runs the rule is
    /// ineligible even though rejection also disabled it, and once the cooldown
    /// elapses the rule returns to service. Rejections saved before the
    /// `.cooldown` status existed (`.rejected` with an end date) follow the same
    /// lifecycle; a rejection without an end date stays permanent. Explicit
    /// disables clear the end date, so they never revive.
    public func isEligible(at date: Date = Date()) -> Bool {
        switch status {
        case .cooldown, .rejected:
            guard let cooldownUntil else { return false }
            return cooldownUntil <= date
        case .pendingApproval:
            return false
        case .active:
            guard isEnabled else { return false }
            if let cooldownUntil, cooldownUntil > date { return false }
            return true
        }
    }

    /// Applies the rule's effective status for `date`: an elapsed rejection
    /// cooldown becomes active and enabled again. Runtime eligibility and UI
    /// consumers both read `isEnabled`/`status`, so callers normalize before
    /// counting, attributing, or persisting rules. An explicit disable clears
    /// `cooldownUntil`, so deliberately disabled rules are never revived.
    public mutating func normalizeExpiredCooldown(at date: Date = Date()) {
        switch status {
        case .cooldown, .rejected:
            guard let cooldownUntil, cooldownUntil <= date else { return }
            status = .active
            isEnabled = true
            self.cooldownUntil = nil
            rejectedAt = nil
        case .active, .pendingApproval:
            break
        }
    }

    /// Unified 0-1 confidence combining priority, observed outcomes, support, and recency.
    /// This is the single score used for ranking rules in prompt context and for
    /// scoring proposed mappings, replacing the previous priority-only heuristics.
    public func effectiveConfidence(at now: Date = Date()) -> Double {
        // Avoid rules carry negative priority by convention; magnitude is the signal.
        let base = Double(min(abs(priority), 100)) / 100.0
        let usageTotal = successCount + failureCount
        // Laplace-smoothed success rate: 0.5 with no usage data, converges to the true rate.
        let smoothedSuccessRate = Double(successCount + 1) / Double(usageTotal + 2)
        let supportBoost = min(log10(Double(max(supportCount, 0) + 1)) * 0.2, 0.3)
        var confidence = 0.3 * base + 0.5 * smoothedSuccessRate + supportBoost
        if let lastAppliedAt {
            let daysSinceUse = now.timeIntervalSince(lastAppliedAt) / 86_400
            if daysSinceUse > 90 {
                confidence *= 0.8
            } else if daysSinceUse > 30 {
                confidence *= 0.9
            }
        }
        return min(max(confidence, 0), 1)
    }
    
    public init(
        id: String = UUID().uuidString,
        pattern: String,
        template: String,
        metadataCues: [String] = [],
        priority: Int = 0,
        exampleIds: [String] = [],
        explanation: String,
        successCount: Int = 0,
        failureCount: Int = 0,
        isEnabled: Bool = true,
        lastAppliedAt: Date? = nil,
        supportCount: Int = 1,
        initialConfidence: RuleConfidence? = nil,
        scope: RuleScope = .global,
        status: RuleStatus = .active,
        evidenceIds: [String] = [],
        evidenceDescription: String? = nil,
        rejectedAt: Date? = nil,
        cooldownUntil: Date? = nil
    ) {
        self.id = id
        self.pattern = pattern
        self.template = template
        self.metadataCues = metadataCues
        self.priority = priority
        self.exampleIds = exampleIds
        self.explanation = explanation
        self.successCount = successCount
        self.failureCount = failureCount
        self.isEnabled = isEnabled
        self.lastAppliedAt = lastAppliedAt
        self.supportCount = supportCount
        self.initialConfidence = initialConfidence
        self.scope = scope
        self.status = status
        self.evidenceIds = evidenceIds
        self.evidenceDescription = evidenceDescription
        self.rejectedAt = rejectedAt
        self.cooldownUntil = cooldownUntil
    }
}

public enum RuleConfidence: String, Codable, Sendable {
    case high, medium, low
}

// MARK: - Proposed Mapping

/// A single file's proposed destination
public struct ProposedMapping: Codable, Identifiable, Sendable {
    public let id: String
    public let srcPath: String
    public let proposedDstPath: String
    public let ruleId: String?
    public let confidence: Double         // 0.0 - 1.0
    public let explanation: String
    public let alternatives: [AlternativeMapping]
    
    public init(
        id: String = UUID().uuidString,
        srcPath: String,
        proposedDstPath: String,
        ruleId: String? = nil,
        confidence: Double,
        explanation: String,
        alternatives: [AlternativeMapping] = []
    ) {
        self.id = id
        self.srcPath = srcPath
        self.proposedDstPath = proposedDstPath
        self.ruleId = ruleId
        self.confidence = confidence
        self.explanation = explanation
        self.alternatives = alternatives
    }
    
    /// Confidence category for UI display
    public var confidenceLevel: ConfidenceLevel {
        if confidence >= 0.8 { return .high }
        if confidence >= 0.5 { return .medium }
        return .low
    }
}

public struct AlternativeMapping: Codable, Sendable {
    public let proposedDstPath: String
    public let confidence: Double
    public let explanation: String
    
    public init(proposedDstPath: String, confidence: Double, explanation: String) {
        self.proposedDstPath = proposedDstPath
        self.confidence = confidence
        self.explanation = explanation
    }
}

public enum ConfidenceLevel: String, Codable, Sendable {
    case high, medium, low
    
    public var color: String {
        switch self {
        case .high: return "green"
        case .medium: return "orange"
        case .low: return "red"
        }
    }
}

// MARK: - Confidence Summary

/// Distribution of confidence levels in analysis
public struct ConfidenceSummary: Codable, Sendable {
    public let high: Int
    public let medium: Int
    public let low: Int
    
    public init(high: Int, medium: Int, low: Int) {
        self.high = high
        self.medium = medium
        self.low = low
    }
    
    public var total: Int { high + medium + low }
}

// MARK: - Conflict

/// Naming collision detected during analysis
public struct MappingConflict: Codable, Sendable {
    public let srcPaths: [String]
    public let proposedDstPath: String
    public let suggestedResolution: ConflictResolution
    
    public init(srcPaths: [String], proposedDstPath: String, suggestedResolution: ConflictResolution) {
        self.srcPaths = srcPaths
        self.proposedDstPath = proposedDstPath
        self.suggestedResolution = suggestedResolution
    }
}

public enum ConflictResolution: String, Codable, Sendable {
    case autoSuffix  // Append _1, _2, etc.
    case keepBoth    // Keep source filename if conflict
    case prompt      // Ask user to resolve
}

// MARK: - Staged Plan

/// One stage of staged execution
public struct StagedPlanStep: Codable, Sendable {
    public let stageDescription: String
    public let folderExamples: [String]
    public let estimatedCount: Int
    public let riskLevel: RiskLevel
    
    public init(stageDescription: String, folderExamples: [String], estimatedCount: Int, riskLevel: RiskLevel) {
        self.stageDescription = stageDescription
        self.folderExamples = folderExamples
        self.estimatedCount = estimatedCount
        self.riskLevel = riskLevel
    }
}

public enum RiskLevel: String, Codable, Sendable {
    case low, medium, high
}

// MARK: - Analysis Result

/// Full analysis result (matches required output schema)
public struct LearningsAnalysisResult: Codable, Sendable {
    public let inferredRules: [InferredRule]
    public let proposedMappings: [ProposedMapping]
    public let stagedPlan: [StagedPlanStep]
    public let confidenceSummary: ConfidenceSummary
    public let conflicts: [MappingConflict]
    public let jobManifestTemplate: String
    public let humanSummary: [String]
    
    public init(
        inferredRules: [InferredRule],
        proposedMappings: [ProposedMapping],
        stagedPlan: [StagedPlanStep] = [],
        confidenceSummary: ConfidenceSummary,
        conflicts: [MappingConflict] = [],
        jobManifestTemplate: String = "",
        humanSummary: [String] = []
    ) {
        self.inferredRules = inferredRules
        self.proposedMappings = proposedMappings
        self.stagedPlan = stagedPlan
        self.confidenceSummary = confidenceSummary
        self.conflicts = conflicts
        self.jobManifestTemplate = jobManifestTemplate
        self.humanSummary = humanSummary
    }
    
    /// Export to JSON for preview
    public func toJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

// MARK: - File Type Classification

/// Classification of files for pattern matching
public enum FileCategory: String, Codable, Sendable, CaseIterable {
    case photo
    case video
    case music
    case document
    case archive
    case code
    case other
    
    /// File extensions for this category
    public var extensions: [String] {
        switch self {
        case .photo:
            return ["jpg", "jpeg", "png", "gif", "heic", "heif", "raw", "cr2", "nef", "arw", "dng", "tiff", "tif", "webp"]
        case .video:
            return ["mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "mpg", "mpeg", "3gp"]
        case .music:
            return ["mp3", "m4a", "flac", "wav", "aac", "ogg", "wma", "aiff", "alac"]
        case .document:
            return ["pdf", "doc", "docx", "txt", "rtf", "odt", "pages", "xls", "xlsx", "ppt", "pptx", "md"]
        case .archive:
            return ["zip", "rar", "7z", "tar", "gz", "bz2", "dmg", "iso"]
        case .code:
            return ["swift", "py", "js", "ts", "java", "cpp", "c", "h", "go", "rs", "rb", "php", "html", "css", "json", "xml", "yaml", "yml"]
        case .other:
            return []
        }
    }
    
    /// Determine category from file extension
    public static func from(extension ext: String) -> FileCategory {
        let lowered = ext.lowercased()
        for category in FileCategory.allCases where category != .other {
            if category.extensions.contains(lowered) {
                return category
            }
        }
        return .other
    }
}

// MARK: - Reference Model Directory

/// A directory used as a reference for organization structure and naming conventions.
/// Sorty scans these directories (structure and folder names only) to learn how the user
/// prefers to organize files, then injects that context into AI prompts.
public struct ReferenceModelDirectory: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let path: String
    public var displayName: String
    public var isEnabled: Bool
    public var bookmarkData: Data?
    public var lastScannedAt: Date?
    public var scanSnapshot: ReferenceDirectorySnapshot?
    
    public init(
        id: String = UUID().uuidString,
        path: String,
        displayName: String? = nil,
        isEnabled: Bool = true,
        bookmarkData: Data? = nil,
        lastScannedAt: Date? = nil,
        scanSnapshot: ReferenceDirectorySnapshot? = nil
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
        self.isEnabled = isEnabled
        self.bookmarkData = bookmarkData
        self.lastScannedAt = lastScannedAt
        self.scanSnapshot = scanSnapshot
    }
    
    /// Canonical path for deduplication (resolves symlinks, trailing slashes)
    public var canonicalPath: String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.path
    }
    
    /// Whether the directory currently exists on disk
    public var isAccessible: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - Reference Directory Snapshot

/// Cached scan results for a reference model directory
public struct ReferenceDirectorySnapshot: Codable, Hashable, Sendable {
    public static let currentVersion = 2

    public let version: Int
    public let scannedAt: Date
    public let folderHierarchy: [ReferenceFolder]
    public let namingConventions: [String]
    public let fileNamingConventions: [String]
    public let fileCategoryDistribution: [FileCategory: Int]
    public let fileExtensionDistribution: [String: Int]
    public let totalFolderCount: Int
    public let totalFileCount: Int
    public let maximumDepth: Int
    public let warnings: [String]
    public let isTruncated: Bool
    
    public init(
        version: Int = ReferenceDirectorySnapshot.currentVersion,
        scannedAt: Date,
        folderHierarchy: [ReferenceFolder],
        namingConventions: [String],
        fileNamingConventions: [String] = [],
        fileCategoryDistribution: [FileCategory: Int] = [:],
        fileExtensionDistribution: [String: Int] = [:],
        totalFolderCount: Int,
        totalFileCount: Int,
        maximumDepth: Int? = nil,
        warnings: [String] = [],
        isTruncated: Bool = false
    ) {
        self.version = version
        self.scannedAt = scannedAt
        self.folderHierarchy = folderHierarchy
        self.namingConventions = namingConventions
        self.fileNamingConventions = fileNamingConventions
        self.fileCategoryDistribution = fileCategoryDistribution
        self.fileExtensionDistribution = fileExtensionDistribution
        self.totalFolderCount = totalFolderCount
        self.totalFileCount = totalFileCount
        self.maximumDepth = maximumDepth ?? folderHierarchy.map(\.depth).max() ?? 0
        self.warnings = warnings
        self.isTruncated = isTruncated
    }

    public var needsRescan: Bool {
        version < Self.currentVersion
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case scannedAt
        case folderHierarchy
        case namingConventions
        case fileNamingConventions
        case fileCategoryDistribution
        case fileExtensionDistribution
        case totalFolderCount
        case totalFileCount
        case maximumDepth
        case warnings
        case isTruncated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        scannedAt = try container.decode(Date.self, forKey: .scannedAt)
        folderHierarchy = try container.decode([ReferenceFolder].self, forKey: .folderHierarchy)
        namingConventions = try container.decode([String].self, forKey: .namingConventions)
        fileNamingConventions = try container.decodeIfPresent(
            [String].self,
            forKey: .fileNamingConventions
        ) ?? []
        fileCategoryDistribution = try container.decodeIfPresent(
            [FileCategory: Int].self,
            forKey: .fileCategoryDistribution
        ) ?? [:]
        fileExtensionDistribution = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .fileExtensionDistribution
        ) ?? [:]
        totalFolderCount = try container.decode(Int.self, forKey: .totalFolderCount)
        totalFileCount = try container.decode(Int.self, forKey: .totalFileCount)
        maximumDepth = try container.decodeIfPresent(Int.self, forKey: .maximumDepth)
            ?? folderHierarchy.map(\.depth).max() ?? 0
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        isTruncated = try container.decodeIfPresent(Bool.self, forKey: .isTruncated) ?? false
    }
}

/// A single folder entry within a reference directory scan
public struct ReferenceFolder: Codable, Hashable, Sendable {
    public let relativePath: String
    public let name: String
    public let depth: Int
    public let fileCount: Int
    public let fileTypeDistribution: [String: Int]
    public let sampleFileNames: [String]
    
    public init(
        relativePath: String,
        name: String,
        depth: Int,
        fileCount: Int,
        fileTypeDistribution: [String: Int],
        sampleFileNames: [String]
    ) {
        self.relativePath = relativePath
        self.name = name
        self.depth = depth
        self.fileCount = fileCount
        self.fileTypeDistribution = fileTypeDistribution
        self.sampleFileNames = sampleFileNames
    }
}

public struct LearningsModelSelection: Codable, Sendable, Equatable {
    public var provider: AIProvider
    public var model: String

    public init(provider: AIProvider, model: String) {
        self.provider = provider
        self.model = model
    }
}

// MARK: - Inline Learning Moments

/// A contextual, folder-specific question shown after organization completes
public struct InlineLearningMoment: Identifiable, Codable, Sendable {
    public let id: String
    public let sessionId: String?
    public let folderPath: String
    public let prompt: String
    public let options: [String]
    public let kind: Kind
    public let relatedFilePath: String?
    public let timestamp: Date
    
    public enum Kind: String, Codable, Sendable {
        case folderPlacement    // "Should X go in A or B?"
        case fileGrouping       // "Should these be kept together?"
    }
    
    public init(
        id: String = UUID().uuidString,
        sessionId: String? = nil,
        folderPath: String,
        prompt: String,
        options: [String],
        kind: Kind,
        relatedFilePath: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.folderPath = folderPath
        self.prompt = prompt
        self.options = options
        self.kind = kind
        self.relatedFilePath = relatedFilePath
        self.timestamp = timestamp
    }
}

/// The user's answer to an inline learning moment
public struct InlineLearningMomentAnswer: Codable, Sendable, Identifiable {
    public let id: String
    public let momentId: String
    public let sessionId: String?
    public let selectedOption: String
    public let timestamp: Date
    
    public init(
        id: String = UUID().uuidString,
        momentId: String,
        sessionId: String? = nil,
        selectedOption: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.momentId = momentId
        self.sessionId = sessionId
        self.selectedOption = selectedOption
        self.timestamp = timestamp
    }
}

// MARK: - Utilities

extension Sequence where Element: Hashable {
    /// Returns a new array with unique elements, preserving original order
    public func orderedDeduplicated() -> [Element] {
        var set = Set<Element>()
        return filter { set.insert($0).inserted }
    }
}
