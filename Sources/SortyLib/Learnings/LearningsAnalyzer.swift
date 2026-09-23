//
//  LearningsAnalyzer.swift
//  Sorty
//
//  Main analyzer that orchestrates rule induction and proposal generation
//

import Foundation
import Combine

/// Main analyzer for "The Learnings" feature
@MainActor
public class LearningsAnalyzer: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published public var isAnalyzing: Bool = false
    @Published public var progress: Double = 0.0
    @Published public var currentStatus: String = ""
    @Published public var lastResult: LearningsAnalysisResult?
    
    // MARK: - Dependencies
    
    private let ruleInducer = RuleInducer() // Legacy pattern matcher
    private let localRuleInferenceEngine = LocalRuleInferenceEngine()
    private var llmInducer: LLMRuleInducer?
    private let contentAnalyzer = ContentAnalyzer()
    
    public init() {}
    
    // MARK: - Compiled rule regex cache

    nonisolated(unsafe) private static var ruleRegexCache: [String: NSRegularExpression] = [:]
    nonisolated(unsafe) private static let ruleRegexCacheLock = NSLock()

    /// Compiles each unique rule pattern once; proposeMapping used to compile
    /// every pattern for every file.
    nonisolated private static func cachedRuleRegex(for pattern: String) -> NSRegularExpression? {
        ruleRegexCacheLock.lock()
        if let cached = ruleRegexCache[pattern] {
            ruleRegexCacheLock.unlock()
            return cached
        }
        ruleRegexCacheLock.unlock()
        guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
        ruleRegexCacheLock.lock()
        if ruleRegexCache.count > 512 {
            ruleRegexCache.removeAll()
        }
        ruleRegexCache[pattern] = compiled
        ruleRegexCacheLock.unlock()
        return compiled
    }

    nonisolated private static func ruleMatches(_ rule: InferredRule, filename: String) -> Bool {
        guard let regex = cachedRuleRegex(for: rule.pattern) else { return false }
        return regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)) != nil
    }

    // Configure with AI Client for advanced learning
    public func configure(aiClient: AIClientProtocol) {
        self.llmInducer = LLMRuleInducer(aiClient: aiClient)
    }
    
    // MARK: - Public API
    
    /// Analyze using profile data and target paths
    public func analyze(
        profile: LearningsProfile,
        rootPaths: [String],
        examplePaths: [String]
    ) async throws -> LearningsAnalysisResult {
        isAnalyzing = true
        progress = 0.0
        currentStatus = "Starting analysis..."
        
        defer {
            isAnalyzing = false
            currentStatus = ""
        }
        
        // Step 1: Gather rules from the strongest available signals.
        currentStatus = "Reviewing recent learnings..."
        progress = 0.1
        
        var rules: [InferredRule] = []
        let exampleFolderURLs = examplePaths.map { URL(fileURLWithPath: $0) }
        
        // Combine manual corrections/rejections/positive examples into training set
        let trainingExamples = profile.corrections + profile.rejections + profile.positiveExamples

        let localRules = await localRuleInferenceEngine.inferRules(from: profile)
        rules.append(contentsOf: localRules)
        
        if let llm = llmInducer {
            // Enhanced rule induction with steering prompts and guiding instructions
            currentStatus = "Asking AI to find patterns..."
            let aiRules = await llm.induceRules(
                from: trainingExamples,
                exampleFolders: exampleFolderURLs,
                steeringPrompts: profile.steeringPrompts,
                guidingInstructions: profile.guidingInstructionsHistory,
                regenerationEvidence: profile.regenerationPreferenceEvidence
            )
            rules.append(contentsOf: aiRules)
        }
        
        // Legacy pattern induction still adds value for template extraction from examples.
        // It treats every example as positive destination evidence and ignores the action,
        // so rejected examples must be excluded or rejected destinations become rules.
        currentStatus = "Scanning for structural patterns..."
        let legacyRules = await ruleInducer.induceRules(
            from: trainingExamples.filter { $0.action != .reject },
            exampleFolders: exampleFolderURLs
        )
        rules.append(contentsOf: legacyRules)
        rules = mergeRules(rules)
        
        progress = 0.3
        
        var mappings: [ProposedMapping] = []
        var conflicts: [MappingConflict] = []
        
        if let primaryRootPath = rootPaths.first {
            // Step 2: Scan root paths for files to organize
            currentStatus = "Scanning files..."
            var allFiles: [URL] = []
            
            for rootPath in rootPaths {
                let rootURL = URL(fileURLWithPath: rootPath)
                let files = await scanDirectory(rootURL, sampleSize: 100)
                allFiles.append(contentsOf: files)
            }
            
            progress = 0.5
            
            // Step 3: Generate proposals for each file in 20-file chunks on
            // .utility. Regex matching stays off the main actor, progress
            // updates stay coarse, and cancellation is honored between chunks.
            currentStatus = "Generating proposals..."
            var destinationCounts: [String: [String]] = [:]
            let proposalChunkSize = 20
            
            for chunkStart in stride(from: 0, to: allFiles.count, by: proposalChunkSize) {
                try Task.checkCancellation()
                let chunkEnd = min(chunkStart + proposalChunkSize, allFiles.count)
                let chunk = Array(allFiles[chunkStart..<chunkEnd])
                let chunkMappings = await Task.detached(priority: .utility) {
                    Self.mappings(for: chunk, using: rules, rootPath: primaryRootPath)
                }.value
                for mapping in chunkMappings {
                    mappings.append(mapping)
                    destinationCounts[mapping.proposedDstPath, default: []].append(mapping.srcPath)
                }
                
                progress = 0.5 + (Double(chunkEnd) / Double(allFiles.count)) * 0.4
                await Task.yield()
            }
            
            // Step 4: Detect conflicts
            for (dst, srcs) in destinationCounts where srcs.count > 1 {
                conflicts.append(MappingConflict(
                    srcPaths: srcs,
                    proposedDstPath: dst,
                    suggestedResolution: .autoSuffix
                ))
            }
        } else {
            currentStatus = "Finalizing insights..."
        }
        
        progress = 0.95
        
        // Step 5: Build result
        let confidenceSummary = calculateConfidenceSummary(mappings)
        let stagedPlan = buildStagedPlan(mappings: mappings, rules: rules)
        let humanSummary = generateHumanSummary(rules: rules, mappings: mappings)
        
        let result = LearningsAnalysisResult(
            inferredRules: rules,
            proposedMappings: mappings,
            stagedPlan: stagedPlan,
            confidenceSummary: confidenceSummary,
            conflicts: conflicts,
            jobManifestTemplate: "~/Library/Application Support/Sorty/Learnings/Jobs/",
            humanSummary: humanSummary
        )
        
        lastResult = result
        progress = 1.0
        currentStatus = "Analysis complete"
        
        return result
    }
    
    /// Generate proposal for a single file.
    /// Nonisolated so batch inference can run on `.utility` tasks; the pure
    /// mapping core is `makeMapping`.
    nonisolated public func proposeMapping(
        for fileURL: URL,
        using rules: [InferredRule],
        rootPath: String
    ) async -> ProposedMapping {
        Self.makeMapping(for: fileURL, using: rules, rootPath: rootPath, now: Date())
    }

    nonisolated private static func mappings(
        for files: [URL],
        using rules: [InferredRule],
        rootPath: String
    ) -> [ProposedMapping] {
        let now = Date()
        return files.map { makeMapping(for: $0, using: rules, rootPath: rootPath, now: now) }
    }

    nonisolated private static func makeMapping(
        for fileURL: URL,
        using rules: [InferredRule],
        rootPath: String,
        now: Date
    ) -> ProposedMapping {
        let filename = fileURL.lastPathComponent
        let ext = fileURL.pathExtension
        let category = FileCategory.from(extension: ext)

        var bestMatch: (rule: InferredRule, confidence: Double)?
        var alternatives: [AlternativeMapping] = []

        // Only enabled, active, non-cooldown rules may influence mappings.
        let eligibleRules = rules.filter { $0.isEligible(at: now) }

        // Folders that matching avoid rules veto for this file. Avoid rules are never
        // destinations themselves; they only suppress candidates.
        let avoidedFolders = Set(
            eligibleRules
                .filter { $0.isAvoidRule && ruleMatches($0, filename: filename) }
                .compactMap { $0.avoidedFolderName?.lowercased() }
        )

        for rule in eligibleRules where !rule.isAvoidRule {
            guard ruleMatches(rule, filename: filename) else { continue }

            let dst = applyTemplate(rule.template, to: fileURL, rootPath: rootPath)
            let destinationFolder = URL(fileURLWithPath: dst).deletingLastPathComponent().lastPathComponent.lowercased()
            if avoidedFolders.contains(destinationFolder) { continue }

            // Unified confidence from outcomes, support, and recency (not just priority).
            let confidence = rule.effectiveConfidence(at: now)

            if bestMatch == nil || confidence > bestMatch!.confidence {
                if let prev = bestMatch {
                    // Demote previous best to alternative
                    let altDst = applyTemplate(prev.rule.template, to: fileURL, rootPath: rootPath)
                    alternatives.append(AlternativeMapping(
                        proposedDstPath: altDst,
                        confidence: prev.confidence,
                        explanation: "Alternative using rule: \(prev.rule.explanation)"
                    ))
                }
                bestMatch = (rule, confidence)
            } else {
                // Add as alternative
                alternatives.append(AlternativeMapping(
                    proposedDstPath: dst,
                    confidence: confidence,
                    explanation: "Alternative using rule: \(rule.explanation)"
                ))
            }
        }
        
        // If no rule matched, use fallback
        let proposedDstPath: String
        let ruleId: String?
        let confidence: Double
        let explanation: String
        
        if let match = bestMatch {
            proposedDstPath = applyTemplate(match.rule.template, to: fileURL, rootPath: rootPath)
            ruleId = match.rule.id
            confidence = min(match.confidence, 0.95)  // Cap at 0.95
            explanation = "Matched rule: \(match.rule.explanation)"
        } else {
            // Fallback: organize by category
            proposedDstPath = "\(rootPath)/\(category.rawValue.capitalized)/\(filename)"
            ruleId = nil
            confidence = 0.3
            explanation = "No matching rule found - using category-based fallback"
        }
        
        return ProposedMapping(
            srcPath: fileURL.path,
            proposedDstPath: proposedDstPath,
            ruleId: ruleId,
            confidence: confidence,
            explanation: explanation,
            alternatives: alternatives
        )
    }
    
    // MARK: - Private Methods
    
    /// Scan directory for files
    private func scanDirectory(_ url: URL, sampleSize: Int) async -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        
        var files: [URL] = []
        var scannedSinceYield = 0
        
        while let fileURL = enumerator.nextObject() as? URL {
            guard !Task.isCancelled else { break }
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDirectory {
                files.append(fileURL)
                
                // Sample size limit for performance
                if files.count >= sampleSize {
                    break
                }
            }
            scannedSinceYield += 1
            if scannedSinceYield >= 20 {
                scannedSinceYield = 0
                await Task.yield()
            }
        }
        
        return files
    }
    
    /// Apply template to generate destination path
    nonisolated private static func applyTemplate(_ template: String, to fileURL: URL, rootPath: String) -> String {
        var result = template
        let filename = fileURL.lastPathComponent
        let ext = fileURL.pathExtension
        let category = FileCategory.from(extension: ext)
        
        // Extract date from filename or use file date
        let date = PatternMatcher.extractDate(from: filename) ?? Date()
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        let month = String(format: "%02d", calendar.component(.month, from: date))
        let day = String(format: "%02d", calendar.component(.day, from: date))
        let dateStr = "\(year)-\(month)-\(day)"
        
        // Replace placeholders
        result = result.replacingOccurrences(of: "{filename}", with: filename)
        result = result.replacingOccurrences(of: "{category}", with: category.rawValue.capitalized)
        result = result.replacingOccurrences(of: "{year}", with: String(year))
        result = result.replacingOccurrences(of: "{month}", with: month)
        result = result.replacingOccurrences(of: "{date}", with: dateStr)
        
        // Prepend root path if template is relative
        if !result.hasPrefix("/") {
            result = rootPath + "/" + result
        }
        
        return result
    }
    
    /// Calculate confidence summary
    private func calculateConfidenceSummary(_ mappings: [ProposedMapping]) -> ConfidenceSummary {
        var high = 0, medium = 0, low = 0
        
        for mapping in mappings {
            switch mapping.confidenceLevel {
            case .high: high += 1
            case .medium: medium += 1
            case .low: low += 1
            }
        }
        
        return ConfidenceSummary(high: high, medium: medium, low: low)
    }
    
    /// Build staged execution plan
    private func buildStagedPlan(mappings: [ProposedMapping], rules: [InferredRule]) -> [StagedPlanStep] {
        guard !mappings.isEmpty else { return [] }
        
        // If many low-confidence mappings, recommend staged apply
        let lowConfidenceCount = mappings.filter { $0.confidenceLevel == .low }.count
        let lowConfidenceRatio = Double(lowConfidenceCount) / Double(mappings.count)
        
        if lowConfidenceRatio > 0.3 {
            // High risk - recommend careful staging
            return [
                StagedPlanStep(
                    stageDescription: "Apply to 5 sample files first for review",
                    folderExamples: Array(mappings.prefix(5).map { $0.srcPath }),
                    estimatedCount: 5,
                    riskLevel: .low
                ),
                StagedPlanStep(
                    stageDescription: "After review, apply to remaining high-confidence files",
                    folderExamples: [],
                    estimatedCount: mappings.filter { $0.confidenceLevel == .high }.count,
                    riskLevel: .medium
                ),
                StagedPlanStep(
                    stageDescription: "Finally, apply to medium/low-confidence files with prompts",
                    folderExamples: [],
                    estimatedCount: mappings.filter { $0.confidenceLevel != .high }.count,
                    riskLevel: .high
                )
            ]
        } else {
            // Lower risk - simpler staging
            return [
                StagedPlanStep(
                    stageDescription: "Apply to all \(mappings.count) files",
                    folderExamples: [],
                    estimatedCount: mappings.count,
                    riskLevel: lowConfidenceRatio > 0.1 ? .medium : .low
                )
            ]
        }
    }
    
    /// Generate human-readable summary
    private func generateHumanSummary(rules: [InferredRule], mappings: [ProposedMapping]) -> [String] {
        var summary: [String] = []
        
        if !rules.isEmpty {
            summary.append("Learned \(rules.count) organization rule\(rules.count == 1 ? "" : "s") from examples")
        }
        
        // Describe top rules
        for rule in rules.prefix(3) {
            summary.append("• \(rule.explanation)")
        }
        
        // Confidence overview (only when proposals were generated)
        if !mappings.isEmpty {
            let confidenceSummary = calculateConfidenceSummary(mappings)
            summary.append("Proposal confidence: \(confidenceSummary.high) high, \(confidenceSummary.medium) medium, \(confidenceSummary.low) low")
        }
        
        return summary
    }

    private func mergeRules(_ rules: [InferredRule]) -> [InferredRule] {
        guard !rules.isEmpty else { return [] }

        var merged: [String: InferredRule] = [:]

        for rule in rules {
            let key = "\(rule.pattern)|\(rule.template)"

            if let existing = merged[key] {
                merged[key] = InferredRule(
                    id: existing.id,
                    pattern: existing.pattern,
                    template: existing.template,
                    metadataCues: Array(Set(existing.metadataCues + rule.metadataCues)),
                    priority: max(existing.priority, rule.priority),
                    exampleIds: Array(Set(existing.exampleIds + rule.exampleIds)),
                    explanation: existing.explanation.count >= rule.explanation.count ? existing.explanation : rule.explanation,
                    successCount: max(existing.successCount, rule.successCount),
                    failureCount: max(existing.failureCount, rule.failureCount),
                    isEnabled: existing.isEnabled && rule.isEnabled,
                    lastAppliedAt: [existing.lastAppliedAt, rule.lastAppliedAt].compactMap { $0 }.max(),
                    supportCount: max(existing.supportCount, rule.supportCount),
                    initialConfidence: rule.initialConfidence ?? existing.initialConfidence,
                    scope: existing.scope == .global ? rule.scope : existing.scope,
                    status: existing.status == .active ? .active : rule.status,
                    evidenceIds: Array(Set(existing.evidenceIds + rule.evidenceIds)),
                    evidenceDescription: existing.evidenceDescription ?? rule.evidenceDescription,
                    rejectedAt: existing.rejectedAt,
                    cooldownUntil: existing.cooldownUntil
                )
            } else {
                merged[key] = rule
            }
        }

        return merged.values.sorted { $0.priority > $1.priority }
    }
}
