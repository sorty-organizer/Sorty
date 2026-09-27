//
//  LearningsProfile.swift
//  Sorty
//
//  Single source of truth for user learnings.
//  Persisted as UserProfile.learning (encrypted JSON).
//

import Foundation

public struct LearningsProfile: Codable, Sendable {
    /// Timestamp of when this profile was created
    public let createdAt: Date
    
    // MARK: - Consent
    
    /// Whether user has consented to data collection
    public var consentGranted: Bool
    
    /// When consent was granted
    public var consentDate: Date?
    
    // MARK: - User Behavior Tracking
    
    /// History of additional instructions user has provided
    public var additionalInstructionsHistory: [UserInstruction]
    
    /// History of guiding instructions (for next attempt)
    public var guidingInstructionsHistory: [UserInstruction]
    
    /// Steering prompts (post-organization feedback)
    public var steeringPrompts: [SteeringPrompt]
    
    /// Directory changes user made after AI organization
    public var postOrganizationChanges: [DirectoryChange]

    /// Rename outcomes the user accepted/edited/rejected from AI suggestions
    public var renameFeedbackHistory: [RenameFeedbackEvent]
    
    /// History reverts the user has performed
    public var historyReverts: [RevertEvent]
    
    /// Cancelled organization sessions (user cancelled before applying)
    public var cancelledOrganizations: [CancelledOrganization]
    
    /// Regenerated organization sessions (user wasn't satisfied with first result)
    public var regeneratedOrganizations: [RegeneratedOrganization]

    /// Paired differences between regenerated previews and the plan the user applied.
    public var regenerationPreferenceEvidence: [RegenerationPreferenceEvidence]
    
    // MARK: - Existing Properties
    
    /// Global rules inferred from all past interactions
    public var inferredRules: [InferredRule]
    
    /// Log of manual corrections (User moved A -> B, overriding AI)
    public var corrections: [LabeledExample]
    
    /// Log of rejected operations (User reverted session)
    public var rejections: [LabeledExample]
    
    /// Examples of good organization (User manually filed files correctly)
    public var positiveExamples: [LabeledExample]
    
    /// History of applied jobs (for rollback)
    public var jobHistory: [JobManifest]
    
    /// Rejected rule IDs with cooldown timestamps (ruleId -> cooldown end date)
    public var rejectedRuleCooldowns: [String: Date]
    
    /// Paths excluded from learning
    public var learningExclusionPatterns: [String]
    
    /// Whether session-based learning is enabled (don't persist learnings from this session)
    public var sessionLearningEnabled: Bool

    /// Session-centric timeline of organization behavior and feedback.
    /// Legacy arrays remain for compatibility while callers migrate.
    public var sessions: [OrganizationSession]
    
    /// Answers to inline post-organization learning moments
    public var inlineLearningMomentAnswers: [InlineLearningMomentAnswer]
    
    public init(
        createdAt: Date = Date(),
        consentGranted: Bool = false,
        consentDate: Date? = nil,
        additionalInstructionsHistory: [UserInstruction] = [],
        guidingInstructionsHistory: [UserInstruction] = [],
        steeringPrompts: [SteeringPrompt] = [],
        postOrganizationChanges: [DirectoryChange] = [],
        renameFeedbackHistory: [RenameFeedbackEvent] = [],
        historyReverts: [RevertEvent] = [],
        cancelledOrganizations: [CancelledOrganization] = [],
        regeneratedOrganizations: [RegeneratedOrganization] = [],
        regenerationPreferenceEvidence: [RegenerationPreferenceEvidence] = [],
        inferredRules: [InferredRule] = [],
        corrections: [LabeledExample] = [],
        rejections: [LabeledExample] = [],
        positiveExamples: [LabeledExample] = [],
        jobHistory: [JobManifest] = [],
        rejectedRuleCooldowns: [String: Date] = [:],
        learningExclusionPatterns: [String] = [],
        sessionLearningEnabled: Bool = true,
        sessions: [OrganizationSession] = [],
        inlineLearningMomentAnswers: [InlineLearningMomentAnswer] = []
    ) {
        self.createdAt = createdAt
        self.consentGranted = consentGranted
        self.consentDate = consentDate
        self.additionalInstructionsHistory = additionalInstructionsHistory
        self.guidingInstructionsHistory = guidingInstructionsHistory
        self.steeringPrompts = steeringPrompts
        self.postOrganizationChanges = postOrganizationChanges
        self.renameFeedbackHistory = renameFeedbackHistory
        self.historyReverts = historyReverts
        self.cancelledOrganizations = cancelledOrganizations
        self.regeneratedOrganizations = regeneratedOrganizations
        self.regenerationPreferenceEvidence = regenerationPreferenceEvidence
        self.inferredRules = inferredRules
        self.corrections = corrections
        self.rejections = rejections
        self.positiveExamples = positiveExamples
        self.jobHistory = jobHistory
        self.rejectedRuleCooldowns = rejectedRuleCooldowns
        self.learningExclusionPatterns = learningExclusionPatterns
        self.sessionLearningEnabled = sessionLearningEnabled
        self.sessions = sessions
        self.inlineLearningMomentAnswers = inlineLearningMomentAnswers
    }

    private enum CodingKeys: String, CodingKey {
        case createdAt
        case consentGranted
        case consentDate
        case additionalInstructionsHistory
        case guidingInstructionsHistory
        case steeringPrompts
        case postOrganizationChanges
        case renameFeedbackHistory
        case historyReverts
        case cancelledOrganizations
        case regeneratedOrganizations
        case regenerationPreferenceEvidence
        case inferredRules
        case corrections
        case rejections
        case positiveExamples
        case jobHistory
        case rejectedRuleCooldowns
        case learningExclusionPatterns
        case sessionLearningEnabled
        case sessions
        case inlineLearningMomentAnswers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        consentGranted = try container.decodeIfPresent(Bool.self, forKey: .consentGranted) ?? false
        consentDate = try container.decodeIfPresent(Date.self, forKey: .consentDate)
        additionalInstructionsHistory = try container.decodeIfPresent([UserInstruction].self, forKey: .additionalInstructionsHistory) ?? []
        guidingInstructionsHistory = try container.decodeIfPresent([UserInstruction].self, forKey: .guidingInstructionsHistory) ?? []
        steeringPrompts = try container.decodeIfPresent([SteeringPrompt].self, forKey: .steeringPrompts) ?? []
        postOrganizationChanges = try container.decodeIfPresent([DirectoryChange].self, forKey: .postOrganizationChanges) ?? []
        renameFeedbackHistory = try container.decodeIfPresent([RenameFeedbackEvent].self, forKey: .renameFeedbackHistory) ?? []
        historyReverts = try container.decodeIfPresent([RevertEvent].self, forKey: .historyReverts) ?? []
        cancelledOrganizations = try container.decodeIfPresent([CancelledOrganization].self, forKey: .cancelledOrganizations) ?? []
        regeneratedOrganizations = try container.decodeIfPresent([RegeneratedOrganization].self, forKey: .regeneratedOrganizations) ?? []
        regenerationPreferenceEvidence = try container.decodeIfPresent(
            [RegenerationPreferenceEvidence].self,
            forKey: .regenerationPreferenceEvidence
        ) ?? []
        inferredRules = try container.decodeIfPresent([InferredRule].self, forKey: .inferredRules) ?? []
        corrections = try container.decodeIfPresent([LabeledExample].self, forKey: .corrections) ?? []
        rejections = try container.decodeIfPresent([LabeledExample].self, forKey: .rejections) ?? []
        positiveExamples = try container.decodeIfPresent([LabeledExample].self, forKey: .positiveExamples) ?? []
        jobHistory = try container.decodeIfPresent([JobManifest].self, forKey: .jobHistory) ?? []
        rejectedRuleCooldowns = try container.decodeIfPresent([String: Date].self, forKey: .rejectedRuleCooldowns) ?? [:]
        learningExclusionPatterns = try container.decodeIfPresent([String].self, forKey: .learningExclusionPatterns) ?? []
        sessionLearningEnabled = try container.decodeIfPresent(Bool.self, forKey: .sessionLearningEnabled) ?? true
        sessions = try container.decodeIfPresent([OrganizationSession].self, forKey: .sessions) ?? []
        inlineLearningMomentAnswers = try container.decodeIfPresent([InlineLearningMomentAnswer].self, forKey: .inlineLearningMomentAnswers) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(consentGranted, forKey: .consentGranted)
        try container.encodeIfPresent(consentDate, forKey: .consentDate)
        try container.encode(additionalInstructionsHistory, forKey: .additionalInstructionsHistory)
        try container.encode(guidingInstructionsHistory, forKey: .guidingInstructionsHistory)
        try container.encode(steeringPrompts, forKey: .steeringPrompts)
        try container.encode(postOrganizationChanges, forKey: .postOrganizationChanges)
        try container.encode(renameFeedbackHistory, forKey: .renameFeedbackHistory)
        try container.encode(historyReverts, forKey: .historyReverts)
        try container.encode(cancelledOrganizations, forKey: .cancelledOrganizations)
        try container.encode(regeneratedOrganizations, forKey: .regeneratedOrganizations)
        try container.encode(regenerationPreferenceEvidence, forKey: .regenerationPreferenceEvidence)
        try container.encode(inferredRules, forKey: .inferredRules)
        try container.encode(corrections, forKey: .corrections)
        try container.encode(rejections, forKey: .rejections)
        try container.encode(positiveExamples, forKey: .positiveExamples)
        try container.encode(jobHistory, forKey: .jobHistory)
        try container.encode(rejectedRuleCooldowns, forKey: .rejectedRuleCooldowns)
        try container.encode(learningExclusionPatterns, forKey: .learningExclusionPatterns)
        try container.encode(sessionLearningEnabled, forKey: .sessionLearningEnabled)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(inlineLearningMomentAnswers, forKey: .inlineLearningMomentAnswers)
    }
}

// MARK: - Regeneration Preference Evidence

/// Compact evidence describing what changed between rejected previews and the plan the user applied.
public struct RegenerationPreferenceEvidence: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let timestamp: Date
    public let folderPath: String
    public let acceptedVersion: Int
    public let attempts: [RegenerationAttemptComparison]

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        folderPath: String,
        acceptedVersion: Int,
        attempts: [RegenerationAttemptComparison]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.folderPath = folderPath
        self.acceptedVersion = acceptedVersion
        self.attempts = attempts
    }
}

public struct RegenerationAttemptComparison: Codable, Sendable, Equatable {
    public let rejectedVersion: Int
    public let rejectedFolderCount: Int
    public let acceptedFolderCount: Int
    public let rejectedMaxDepth: Int
    public let acceptedMaxDepth: Int
    public let rejectedUnorganizedCount: Int
    public let acceptedUnorganizedCount: Int
    public let fileChanges: [RegenerationFilePreference]
}

public struct RegenerationFilePreference: Codable, Sendable, Equatable {
    public let fileID: UUID
    public let filename: String
    public let fileExtension: String
    public let rejectedDestination: String?
    public let acceptedDestination: String?
    public let rejectedFilename: String
    public let acceptedFilename: String
    public let wasRejectedAsUnorganized: Bool
    public let wasAcceptedAsUnorganized: Bool
}

enum PlanPreferenceDiffer {
    private static let maxRecordedFileChangesPerAttempt = 200

    private struct FilePlacement {
        let file: FileItem
        let destination: String?
        let outputFilename: String
        let isUnorganized: Bool
    }

    static func compare(
        rejectedPlans: [OrganizationPlan],
        acceptedPlan: OrganizationPlan,
        folderPath: String,
        timestamp: Date = Date()
    ) -> RegenerationPreferenceEvidence? {
        guard !rejectedPlans.isEmpty else { return nil }

        let acceptedPlacements = flatten(acceptedPlan)
        let acceptedDepth = maximumDepth(in: acceptedPlan.suggestions)
        let attempts = rejectedPlans.compactMap { rejectedPlan -> RegenerationAttemptComparison? in
            let rejectedPlacements = flatten(rejectedPlan)
            let changedFiles: [RegenerationFilePreference] = acceptedPlacements.keys
                .sorted { $0.uuidString < $1.uuidString }
                .compactMap { fileID -> RegenerationFilePreference? in
                guard let accepted = acceptedPlacements[fileID],
                      let rejected = rejectedPlacements[fileID],
                      accepted.destination != rejected.destination
                        || accepted.outputFilename != rejected.outputFilename
                        || accepted.isUnorganized != rejected.isUnorganized else {
                    return nil
                }

                return RegenerationFilePreference(
                    fileID: fileID,
                    filename: accepted.file.displayName,
                    fileExtension: accepted.file.extension.lowercased(),
                    rejectedDestination: rejected.destination,
                    acceptedDestination: accepted.destination,
                    rejectedFilename: rejected.outputFilename,
                    acceptedFilename: accepted.outputFilename,
                    wasRejectedAsUnorganized: rejected.isUnorganized,
                    wasAcceptedAsUnorganized: accepted.isUnorganized
                )
            }

            let comparison = RegenerationAttemptComparison(
                rejectedVersion: rejectedPlan.version,
                rejectedFolderCount: rejectedPlan.totalFolders,
                acceptedFolderCount: acceptedPlan.totalFolders,
                rejectedMaxDepth: maximumDepth(in: rejectedPlan.suggestions),
                acceptedMaxDepth: acceptedDepth,
                rejectedUnorganizedCount: rejectedPlan.unorganizedFiles.count,
                acceptedUnorganizedCount: acceptedPlan.unorganizedFiles.count,
                fileChanges: Array(changedFiles.prefix(maxRecordedFileChangesPerAttempt))
            )

            let structureChanged = comparison.rejectedFolderCount != comparison.acceptedFolderCount
                || comparison.rejectedMaxDepth != comparison.acceptedMaxDepth
                || comparison.rejectedUnorganizedCount != comparison.acceptedUnorganizedCount
            return changedFiles.isEmpty && !structureChanged ? nil : comparison
        }

        guard !attempts.isEmpty else { return nil }
        return RegenerationPreferenceEvidence(
            timestamp: timestamp,
            folderPath: folderPath,
            acceptedVersion: acceptedPlan.version,
            attempts: attempts
        )
    }

    private static func flatten(_ plan: OrganizationPlan) -> [UUID: FilePlacement] {
        var placements: [UUID: FilePlacement] = [:]

        func visit(_ suggestion: FolderSuggestion, parentPath: String) {
            let destination = [parentPath, suggestion.folderName]
                .filter { !$0.isEmpty }
                .joined(separator: "/")
            let renameMappings = Dictionary(
                suggestion.fileRenameMappings.map { ($0.originalFile.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )

            for file in suggestion.files {
                let mappedName = renameMappings[file.id].flatMap { mapping in
                    mapping.shouldApplyRename ? mapping.suggestedName : nil
                }
                placements[file.id] = FilePlacement(
                    file: file,
                    destination: destination,
                    outputFilename: mappedName ?? file.suggestedFilename ?? file.displayName,
                    isUnorganized: false
                )
            }
            suggestion.subfolders.forEach { visit($0, parentPath: destination) }
        }

        plan.suggestions.forEach { visit($0, parentPath: "") }
        for file in plan.unorganizedFiles {
            placements[file.id] = FilePlacement(
                file: file,
                destination: nil,
                outputFilename: file.displayName,
                isUnorganized: true
            )
        }
        return placements
    }

    private static func maximumDepth(in suggestions: [FolderSuggestion], depth: Int = 1) -> Int {
        suggestions.reduce(0) { result, suggestion in
            max(result, max(depth, maximumDepth(in: suggestion.subfolders, depth: depth + 1)))
        }
    }
}

// MARK: - Portable Profile Archive

struct LearningsProfileArchive: Codable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String?
    let buildVersion: String?
    let profileCreatedAt: Date
    let summary: LearningsProfileArchiveSummary
    let settings: LearningsProfileSettingsSnapshot
    let profileDigestSHA256: String
    let profile: LearningsProfile
}

struct LearningsProfileSettingsSnapshot: Codable, Sendable {
    let learningStrength: Double
    let usesAIForAnalysis: Bool
    let dataRetentionDays: Int
    let modelSelection: LearningsModelSelection?
}

package struct LearningsProfileArchiveSummary: Codable, Equatable, Sendable {
    package let additionalInstructions: Int
    package let guidingInstructions: Int
    package let steeringPrompts: Int
    package let postOrganizationChanges: Int
    package let renameFeedbackEvents: Int
    package let historyReverts: Int
    package let cancelledOrganizations: Int
    package let regeneratedOrganizations: Int
    package let regenerationPreferenceEvidence: Int
    package let inferredRules: Int
    package let corrections: Int
    package let rejections: Int
    package let positiveExamples: Int
    package let jobHistory: Int
    package let rejectedRuleCooldowns: Int
    package let learningExclusionPatterns: Int
    package let sessions: Int
    package let inlineLearningMomentAnswers: Int

    package init(profile: LearningsProfile) {
        additionalInstructions = profile.additionalInstructionsHistory.count
        guidingInstructions = profile.guidingInstructionsHistory.count
        steeringPrompts = profile.steeringPrompts.count
        postOrganizationChanges = profile.postOrganizationChanges.count
        renameFeedbackEvents = profile.renameFeedbackHistory.count
        historyReverts = profile.historyReverts.count
        cancelledOrganizations = profile.cancelledOrganizations.count
        regeneratedOrganizations = profile.regeneratedOrganizations.count
        regenerationPreferenceEvidence = profile.regenerationPreferenceEvidence.count
        inferredRules = profile.inferredRules.count
        corrections = profile.corrections.count
        rejections = profile.rejections.count
        positiveExamples = profile.positiveExamples.count
        jobHistory = profile.jobHistory.count
        rejectedRuleCooldowns = profile.rejectedRuleCooldowns.count
        learningExclusionPatterns = profile.learningExclusionPatterns.count
        sessions = profile.sessions.count
        inlineLearningMomentAnswers = profile.inlineLearningMomentAnswers.count
    }

    private enum CodingKeys: String, CodingKey {
        case additionalInstructions
        case guidingInstructions
        case steeringPrompts
        case postOrganizationChanges
        case renameFeedbackEvents
        case historyReverts
        case cancelledOrganizations
        case regeneratedOrganizations
        case regenerationPreferenceEvidence
        case inferredRules
        case corrections
        case rejections
        case positiveExamples
        case jobHistory
        case rejectedRuleCooldowns
        case learningExclusionPatterns
        case sessions
        case inlineLearningMomentAnswers
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        additionalInstructions = try container.decode(Int.self, forKey: .additionalInstructions)
        guidingInstructions = try container.decode(Int.self, forKey: .guidingInstructions)
        steeringPrompts = try container.decode(Int.self, forKey: .steeringPrompts)
        postOrganizationChanges = try container.decode(Int.self, forKey: .postOrganizationChanges)
        renameFeedbackEvents = try container.decode(Int.self, forKey: .renameFeedbackEvents)
        historyReverts = try container.decode(Int.self, forKey: .historyReverts)
        cancelledOrganizations = try container.decode(Int.self, forKey: .cancelledOrganizations)
        regeneratedOrganizations = try container.decode(Int.self, forKey: .regeneratedOrganizations)
        regenerationPreferenceEvidence = try container.decodeIfPresent(
            Int.self,
            forKey: .regenerationPreferenceEvidence
        ) ?? 0
        inferredRules = try container.decode(Int.self, forKey: .inferredRules)
        corrections = try container.decode(Int.self, forKey: .corrections)
        rejections = try container.decode(Int.self, forKey: .rejections)
        positiveExamples = try container.decode(Int.self, forKey: .positiveExamples)
        jobHistory = try container.decode(Int.self, forKey: .jobHistory)
        rejectedRuleCooldowns = try container.decode(Int.self, forKey: .rejectedRuleCooldowns)
        learningExclusionPatterns = try container.decode(Int.self, forKey: .learningExclusionPatterns)
        sessions = try container.decode(Int.self, forKey: .sessions)
        inlineLearningMomentAnswers = try container.decode(Int.self, forKey: .inlineLearningMomentAnswers)
    }

    package var totalRecordCount: Int {
        additionalInstructions
            + guidingInstructions
            + steeringPrompts
            + postOrganizationChanges
            + renameFeedbackEvents
            + historyReverts
            + cancelledOrganizations
            + regeneratedOrganizations
            + regenerationPreferenceEvidence
            + inferredRules
            + corrections
            + rejections
            + positiveExamples
            + jobHistory
            + rejectedRuleCooldowns
            + learningExclusionPatterns
            + sessions
            + inlineLearningMomentAnswers
    }

    package var instructionCount: Int {
        additionalInstructions + guidingInstructions + steeringPrompts
    }

    package var feedbackCount: Int {
        postOrganizationChanges
            + renameFeedbackEvents
            + historyReverts
            + cancelledOrganizations
            + regeneratedOrganizations
            + regenerationPreferenceEvidence
            + corrections
            + rejections
            + positiveExamples
            + inlineLearningMomentAnswers
    }

    package var supportingDataCount: Int {
        jobHistory + rejectedRuleCooldowns + learningExclusionPatterns
    }
}

public struct LearningsProfileImportResult: Equatable, Sendable {
    public let importedRecordCount: Int
    public let previousRecordCount: Int
    public let resultingRecordCount: Int
    public let omittedByRetentionPolicy: Int
    public let restoredSettingCount: Int
    public let wasLegacyProfile: Bool
}

enum LearningsProfileTransferError: LocalizedError, Sendable {
    case unsupportedFile
    case fileTooLarge
    case unsupportedSchema(Int)
    case inconsistentArchive
    case tooManyRecords
    case invalidSettings
    case noProfile

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return "This isn't a supported Sorty learnings profile."
        case .fileTooLarge:
            return "This learnings profile is larger than the 25 MB import limit."
        case .unsupportedSchema(let version):
            return "This learnings profile uses schema version \(version), which this version of Sorty does not support."
        case .inconsistentArchive:
            return "This learnings profile is incomplete or has been modified and cannot be imported safely."
        case .tooManyRecords:
            return "This learnings profile contains more than 10,000 records and cannot be imported safely."
        case .invalidSettings:
            return "This learnings profile contains invalid learning settings."
        case .noProfile:
            return "There is no learnings profile to export."
        }
    }
}

// MARK: - Behavior Tracking Models

/// Represents a user instruction (additional or guiding)
public struct UserInstruction: Codable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let instruction: String
    public let context: String?  // e.g., folder path or organization context
    public let folderPath: String?
    public let fileCount: Int?
    public let isRegeneration: Bool?
    
    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        instruction: String,
        context: String? = nil,
        folderPath: String? = nil,
        fileCount: Int? = nil,
        isRegeneration: Bool? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.instruction = instruction
        self.context = context
        self.folderPath = folderPath
        self.fileCount = fileCount
        self.isRegeneration = isRegeneration
    }
}

/// Represents a cancelled organization session with rich context for learning
public struct CancelledOrganization: Codable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let folderPath: String
    public let fileCount: Int
    public let proposedFolderCount: Int
    public let instructions: String?
    public let cancelledAtStage: String
    
    // Enhanced fields for richer learning
    public let proposedFolderNames: [String]?
    public let proposedStructureSummary: String?
    public let fileExtensionCounts: [String: Int]?
    public let regenerationCount: Int
    public let regenerationInstructions: [String]?
    public let aiModel: String?
    
    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        folderPath: String,
        fileCount: Int,
        proposedFolderCount: Int,
        instructions: String? = nil,
        cancelledAtStage: String,
        proposedFolderNames: [String]? = nil,
        proposedStructureSummary: String? = nil,
        fileExtensionCounts: [String: Int]? = nil,
        regenerationCount: Int = 0,
        regenerationInstructions: [String]? = nil,
        aiModel: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.folderPath = folderPath
        self.fileCount = fileCount
        self.proposedFolderCount = proposedFolderCount
        self.instructions = instructions
        self.cancelledAtStage = cancelledAtStage
        self.proposedFolderNames = proposedFolderNames
        self.proposedStructureSummary = proposedStructureSummary
        self.fileExtensionCounts = fileExtensionCounts
        self.regenerationCount = regenerationCount
        self.regenerationInstructions = regenerationInstructions
        self.aiModel = aiModel
    }
}

/// Represents a regenerated organization session
public struct RegeneratedOrganization: Codable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let folderPath: String
    public let previousPlanSummary: String?
    public let guidingInstruction: String?
    public let regenerationCount: Int
    
    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        folderPath: String,
        previousPlanSummary: String? = nil,
        guidingInstruction: String? = nil,
        regenerationCount: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.folderPath = folderPath
        self.previousPlanSummary = previousPlanSummary
        self.guidingInstruction = guidingInstruction
        self.regenerationCount = regenerationCount
    }
}

/// Represents a directory change made by user after AI organization
public struct DirectoryChange: Codable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let originalPath: String
    public let newPath: String
    public let wasAIOrganized: Bool
    public let aiSessionId: String?
    
    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        originalPath: String,
        newPath: String,
        wasAIOrganized: Bool,
        aiSessionId: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.originalPath = originalPath
        self.newPath = newPath
        self.wasAIOrganized = wasAIOrganized
        self.aiSessionId = aiSessionId
    }
}

public struct RenameFeedbackEvent: Codable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let originalName: String
    public let suggestedName: String?
    public let finalName: String?
    public let folderPath: String?
    public let action: ExampleAction
    public let confidence: Double?

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        originalName: String,
        suggestedName: String?,
        finalName: String?,
        folderPath: String? = nil,
        action: ExampleAction,
        confidence: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.originalName = originalName
        self.suggestedName = suggestedName
        self.finalName = finalName
        self.folderPath = folderPath
        self.action = action
        self.confidence = confidence
    }
}

/// Represents a history revert event
public struct RevertEvent: Codable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let entryId: String
    public let operationCount: Int
    public let folderPath: String?
    public let reason: String?
    
    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        entryId: String,
        operationCount: Int,
        folderPath: String? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.entryId = entryId
        self.operationCount = operationCount
        self.folderPath = folderPath
        self.reason = reason
    }
}

/// Represents a steering prompt (post-organization instruction)
public struct SteeringPrompt: Codable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let prompt: String
    public let folderPath: String?
    public let sessionId: String?
    
    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        prompt: String,
        folderPath: String? = nil,
        sessionId: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.prompt = prompt
        self.folderPath = folderPath
        self.sessionId = sessionId
    }
}

// MARK: - Backup Mode

public enum BackupMode: String, Codable, Sendable, CaseIterable {
    case none
    case moveToBackupDir
    case copyToBackupDir
    
    public var displayName: String {
        switch self {
        case .none: return "No Backup"
        case .moveToBackupDir: return "Move to Backup Directory"
        case .copyToBackupDir: return "Copy to Backup Directory"
        }
    }
}

// MARK: - Job Manifest

/// Manifest for a single apply job (for rollback)
public struct JobManifest: Codable, Identifiable, Sendable {
    public let id: String
    public let timestamp: Date
    public let entries: [JobManifestEntry]
    public let projectName: String
    public let backupMode: BackupMode
    public var status: JobStatus
    
    public init(
        id: String = UUID().uuidString,
        projectName: String = "User Profile",
        entries: [JobManifestEntry] = [],
        backupMode: BackupMode = .copyToBackupDir,
        status: JobStatus = .pending
    ) {
        self.id = id
        self.timestamp = Date()
        self.projectName = projectName
        self.entries = entries
        self.backupMode = backupMode
        self.status = status
    }
}

public struct JobManifestEntry: Codable, Sendable {
    public let originalPath: String
    public let destinationPath: String
    public let backupPath: String?
    public let checksum: String?
    public var status: EntryStatus
    
    public init(
        originalPath: String,
        destinationPath: String,
        backupPath: String? = nil,
        checksum: String? = nil,
        status: EntryStatus = .pending
    ) {
        self.originalPath = originalPath
        self.destinationPath = destinationPath
        self.backupPath = backupPath
        self.checksum = checksum
        self.status = status
    }
}

public enum JobStatus: String, Codable, Sendable {
    case pending
    case inProgress
    case completed
    case failed
    case rolledBack
}

public enum EntryStatus: String, Codable, Sendable {
    case pending
    case success
    case failed
    case skipped
    case rolledBack
}
