//
//  ExclusionEnforcer.swift
//  Sorty
//
//  Deterministic post-AI validation layer for exclusion rules.
//  Ensures excluded files are NEVER in the final organization plan.
//

import Foundation
import Combine

/// Represents a violation where an excluded file was included in the plan
public struct ExclusionViolation: Identifiable, Sendable {
    public let id = UUID()
    public let file: FileItem
    public let rule: ExclusionRule
    public let suggestedFolder: String
    
    public var description: String {
        "File '\(file.displayName)' matched exclusion rule '\(rule.displayDescription)' but was placed in '\(suggestedFolder)'"
    }
}

/// Result of validating an organization plan against exclusion rules
public struct ExclusionValidationResult: Sendable {
    public let isValid: Bool
    public let violations: [ExclusionViolation]
    public let cleanedPlan: OrganizationPlan?
    
    public var hasViolations: Bool {
        !violations.isEmpty
    }
    
    public var violationCount: Int {
        violations.count
    }
    
    public static let valid = ExclusionValidationResult(isValid: true, violations: [], cleanedPlan: nil)
}

/// Deterministic exclusion validation layer that runs AFTER AI response
@MainActor
public class ExclusionEnforcer: ObservableObject {
    
    // MARK: - Properties
    
    private let exclusionManager: ExclusionRulesManager
    
    /// Track violation patterns for improving prompts
    @Published public private(set) var recentViolations: [ExclusionViolation] = []
    
    /// Maximum number of recent violations to track
    private let maxRecentViolations = 50
    
    // MARK: - Initialization
    
    public init(exclusionManager: ExclusionRulesManager) {
        self.exclusionManager = exclusionManager
    }
    
    // MARK: - Validation
    
    /// Validate an AI-generated organization plan against exclusion rules
    public func validate(_ plan: OrganizationPlan) -> ExclusionValidationResult {
        var violations: [ExclusionViolation] = []
        
        // Check all files in suggestions
        for suggestion in plan.suggestions {
            violations.append(contentsOf: validateFolder(suggestion))
        }
        
        // If valid, return early
        if violations.isEmpty {
            return .valid
        }
        
        // Track violations for pattern analysis
        trackViolations(violations)
        
        // Create cleaned plan
        let cleanedPlan = stripViolations(from: plan, violations: violations)
        
        return ExclusionValidationResult(
            isValid: false,
            violations: violations,
            cleanedPlan: cleanedPlan
        )
    }
    
    /// Recursively validate a folder and its subfolders
    private func validateFolder(_ folder: FolderSuggestion) -> [ExclusionViolation] {
        var violations: [ExclusionViolation] = []
        
        // Check files in this folder
        for file in folder.files {
            if let matchingRule = exclusionManager.firstMatchingRule(for: file) {
                violations.append(ExclusionViolation(
                    file: file,
                    rule: matchingRule,
                    suggestedFolder: folder.folderName
                ))
            }
        }
        
        // Check subfolders recursively
        for subfolder in folder.subfolders {
            violations.append(contentsOf: validateFolder(subfolder))
        }
        
        return violations
    }
    
    // MARK: - Cleaning
    
    /// Remove violations from a plan, returning a cleaned version
    public func stripViolations(from plan: OrganizationPlan, violations: [ExclusionViolation]) -> OrganizationPlan {
        let violatedFileIDs = Set(violations.map { $0.file.id })
        
        var cleanedPlan = plan
        
        // Clean each suggestion, dropping folders that only existed because of
        // excluded files so no empty destination folders are created.
        cleanedPlan.suggestions = plan.suggestions.compactMap { suggestion in
            let cleaned = cleanFolder(suggestion, excludingFileIDs: violatedFileIDs)
            return cleaned.isEmpty && !suggestion.isEmpty ? nil : cleaned
        }
        
        // Add violated files to unorganized list (they stay in place)
        let violatedFiles = violations.map { $0.file }
        cleanedPlan.unorganizedFiles.append(contentsOf: violatedFiles)
        
        return cleanedPlan
    }
    
    /// Recursively clean a folder, removing excluded files
    private func cleanFolder(_ folder: FolderSuggestion, excludingFileIDs: Set<UUID>) -> FolderSuggestion {
        var cleaned = folder
        
        // Remove excluded files
        cleaned.files = folder.files.filter { !excludingFileIDs.contains($0.id) }
        
        // Clean subfolders recursively
        cleaned.subfolders = folder.subfolders
            .map { subfolder in
                cleanFolder(subfolder, excludingFileIDs: excludingFileIDs)
            }
            .filter { !$0.isEmpty }
        
        // Keep only mappings whose files survived somewhere in this subtree.
        // Stale mappings otherwise rename, tag, or comment an unrelated file
        // that happens to share the excluded file's name and folder.
        let retainedFileIDs = Self.retainedFileIDs(in: cleaned)
        cleaned.fileRenameMappings = folder.fileRenameMappings.filter {
            retainedFileIDs.contains($0.originalFile.id)
        }
        cleaned.fileTagMappings = folder.fileTagMappings.filter {
            retainedFileIDs.contains($0.originalFile.id)
        }
        
        return cleaned
    }
    
    /// File IDs still present in a folder and all of its subfolders.
    private static func retainedFileIDs(in folder: FolderSuggestion) -> Set<UUID> {
        var ids = Set(folder.files.map(\.id))
        for subfolder in folder.subfolders {
            ids.formUnion(retainedFileIDs(in: subfolder))
        }
        return ids
    }
    
    // MARK: - Retry Prompt Enhancement
    
    /// Generate an enhanced prompt section for retry after violations
    public func generateRetryPromptEnhancement(for violations: [ExclusionViolation]) -> String {
        guard !violations.isEmpty else { return "" }
        
        var prompt = """
        
        CRITICAL CORRECTION REQUIRED:
        Your previous response VIOLATED exclusion rules. The following files MUST NOT be included in any folder organization:
        
        """
        
        // Group by rule for clarity
        let byRule = Dictionary(grouping: violations) { $0.rule.id }
        
        for (_, ruleViolations) in byRule {
            guard let firstViolation = ruleViolations.first else { continue }
            prompt += "- Rule: \(firstViolation.rule.displayDescription)\n"
            prompt += "  Violated files:\n"
            for violation in ruleViolations.prefix(5) {  // Limit to avoid token bloat
                prompt += "    • \(violation.file.displayName)\n"
            }
            if ruleViolations.count > 5 {
                prompt += "    • ... and \(ruleViolations.count - 5) more\n"
            }
        }
        
        prompt += """
        
        DO NOT include these files in your organization. Leave them in place.
        """
        
        return prompt
    }
    
    // MARK: - Pattern Tracking
    
    private func trackViolations(_ violations: [ExclusionViolation]) {
        recentViolations.append(contentsOf: violations)
        
        // Trim to max size
        if recentViolations.count > maxRecentViolations {
            recentViolations = Array(recentViolations.suffix(maxRecentViolations))
        }
    }
    
    /// Get commonly violated rule types for improving default prompts
    public func getViolationPatterns() -> [ExclusionRuleType: Int] {
        var patterns: [ExclusionRuleType: Int] = [:]
        
        for violation in recentViolations {
            patterns[violation.rule.type, default: 0] += 1
        }
        
        return patterns
    }
    
    /// Clear violation history
    public func clearViolationHistory() {
        recentViolations.removeAll()
    }
}

// MARK: - FolderSuggestion Extension

extension FolderSuggestion {
    /// Check if folder is empty (no files and no non-empty subfolders)
    var isEmpty: Bool {
        files.isEmpty && subfolders.allSatisfy { $0.isEmpty }
    }
}
