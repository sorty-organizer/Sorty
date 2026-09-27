//
//  LocalRuleInferenceEngine.swift
//  Sorty
//
//  Lightweight local rule inference engine that learns patterns from user behavior
//  without requiring LLM calls. Uses statistical analysis and pattern matching.
//

import Foundation
import SortyModels

/// A lightweight rule inference engine that runs locally without AI
public actor LocalRuleInferenceEngine {
    private struct RegenerationRuleKey: Hashable {
        let fileExtension: String
        let destination: String
        let folderPath: String
    }
    
    // MARK: - Configuration
    
    /// Minimum number of examples needed to infer a rule
    private let minExamplesForRule: Int = 2
    
    /// Minimum confidence threshold for rule creation
    private let minConfidenceThreshold: Double = 0.6
    
    /// Weight multiplier for recent examples (last 7 days)
    private let recentWeightMultiplier: Double = 2.0
    
    // MARK: - Rule Inference
    
    /// Infer rules from user behavior data
    public func inferRules(from profile: LearningsProfile) async -> [InferredRule] {
        var rules: [InferredRule] = []
        
        // 1. Infer rules from corrections (highest signal - user explicitly moved files)
        let correctionRules = inferRulesFromCorrections(profile.postOrganizationChanges)
        rules.append(contentsOf: correctionRules)

        let previewCorrectionRules = inferRulesFromExamples(profile.corrections, action: .edit)
        rules.append(contentsOf: previewCorrectionRules)
        
        // 2. Infer rules from positive examples (user-accepted organization)
        let positiveRules = inferRulesFromExamples(profile.positiveExamples, action: .accept)
        rules.append(contentsOf: positiveRules)

        let regenerationRules = inferRulesFromRegenerationEvidence(profile.regenerationPreferenceEvidence)
        rules.append(contentsOf: regenerationRules)
        
        // Rejections weaken the attributed rule at feedback time. Do not turn an
        // unattributed rejection into a broad negative rule.

        // 3. Infer rules from steering prompts (explicit user instructions)
        let steeringRules = inferRulesFromSteeringPrompts(profile.steeringPrompts)
        rules.append(contentsOf: steeringRules)
        
        // 4. Merge similar rules and boost confidence
        rules = mergeAndDeduplicateRules(rules)
        
        // 5. Sort by priority (existing rules come first, then by confidence)
        rules.sort { $0.priority > $1.priority }
        
        return rules
    }

    /// Regeneration contrasts are implicit feedback, so require support from two separate runs.
    private func inferRulesFromRegenerationEvidence(
        _ evidence: [RegenerationPreferenceEvidence]
    ) -> [InferredRule] {
        var grouped: [RegenerationRuleKey: [String: RegenerationFilePreference]] = [:]

        for record in evidence {
            for change in record.attempts.flatMap(\.fileChanges) {
                guard !change.wasAcceptedAsUnorganized,
                      let destination = change.acceptedDestination,
                      !destination.isEmpty,
                      !change.fileExtension.isEmpty,
                      change.rejectedDestination != destination else { continue }
                let key = RegenerationRuleKey(
                    fileExtension: change.fileExtension,
                    destination: destination,
                    folderPath: record.folderPath
                )
                grouped[key, default: [:]][record.id] = change
            }
        }

        return grouped.compactMap { key, changesByRun in
            guard changesByRun.count >= minExamplesForRule else { return nil }
            let escapedExtension = NSRegularExpression.escapedPattern(for: key.fileExtension)
            let destinationName = URL(fileURLWithPath: key.destination).lastPathComponent
            let evidenceIDs = changesByRun.keys.sorted()
            return InferredRule(
                id: "local-regeneration-\(UUID().uuidString.prefix(8))",
                pattern: ".*\\.\(escapedExtension)$",
                template: "\(key.destination)/{filename}",
                priority: 45,
                exampleIds: evidenceIDs,
                explanation: "After regenerating, .\(key.fileExtension) files repeatedly ended up in '\(destinationName)'.",
                supportCount: evidenceIDs.count,
                initialConfidence: .low,
                scope: .folder(key.folderPath),
                evidenceIds: evidenceIDs,
                evidenceDescription: "Accepted after regeneration in \(evidenceIDs.count) separate organization runs."
            )
        }
    }
    
    // MARK: - Correction-based Inference
    
    private func inferRulesFromCorrections(_ changes: [DirectoryChange]) -> [InferredRule] {
        var rules: [InferredRule] = []
        
        // Group corrections by destination folder pattern
        var destinationPatterns: [String: [DirectoryChange]] = [:]
        
        for change in changes where change.wasAIOrganized {
            let destFolder = URL(fileURLWithPath: change.newPath).deletingLastPathComponent().path
            destinationPatterns[destFolder, default: []].append(change)
        }
        
        // For each destination with multiple corrections, infer a rule
        for (destFolder, changes) in destinationPatterns where changes.count >= minExamplesForRule {
            // Analyze source file patterns
            let srcFilenames = changes.map { URL(fileURLWithPath: $0.originalPath).lastPathComponent }
            
            // Try to find common patterns
            if let pattern = findCommonPattern(in: srcFilenames) {
                let destFolderName = URL(fileURLWithPath: destFolder).lastPathComponent
                let confidence = calculateConfidence(exampleCount: changes.count, isRecent: areRecent(changes.map { $0.timestamp }))
                
                let rule = InferredRule(
                    id: "local-correction-\(UUID().uuidString.prefix(8))",
                    pattern: pattern.regex,
                    template: "\(destFolder)/{filename}",
                    metadataCues: [],
                    priority: Int(confidence * 100),
                    exampleIds: changes.map { $0.id },
                    explanation: "Files matching '\(pattern.description)' should go to '\(destFolderName)/' (learned from \(changes.count) corrections)",
                    successCount: 0,
                    failureCount: 0,
                    isEnabled: true,
                    lastAppliedAt: nil,
                    supportCount: changes.count,
                    scope: .folder(scopePath(forDestinationFolder: destFolder))
                )
                rules.append(rule)
            }
            
            // Also infer rules based on file extensions
            let extensionRules = inferExtensionBasedRules(from: changes, destFolder: destFolder)
            rules.append(contentsOf: extensionRules)
        }
        
        return rules
    }
    
    private func inferExtensionBasedRules(from changes: [DirectoryChange], destFolder: String) -> [InferredRule] {
        var rules: [InferredRule] = []
        
        // Group by file extension
        var byExtension: [String: [DirectoryChange]] = [:]
        for change in changes {
            let ext = URL(fileURLWithPath: change.newPath).pathExtension.lowercased()
            if !ext.isEmpty {
                byExtension[ext, default: []].append(change)
            }
        }
        
        for (ext, extChanges) in byExtension where extChanges.count >= minExamplesForRule {
            let destFolderName = URL(fileURLWithPath: destFolder).lastPathComponent
            let sourceFolderNames = Set(extChanges.map {
                URL(fileURLWithPath: $0.originalPath).deletingLastPathComponent().lastPathComponent
            }).filter { !$0.isEmpty && $0 != destFolderName }
            let sourceClause = sourceFolderNames.count == 1
                ? ", not '\(sourceFolderNames.first!)'"
                : ""
            let confidence = calculateConfidence(exampleCount: extChanges.count, isRecent: areRecent(extChanges.map { $0.timestamp }))
            
            let escapedExt = NSRegularExpression.escapedPattern(for: ext)
            let rule = InferredRule(
                id: "local-ext-\(ext)-\(UUID().uuidString.prefix(8))",
                pattern: ".*\\.\(escapedExt)$",
                template: "\(destFolder)/{filename}",
                metadataCues: [],
                priority: Int(confidence * 80), // Slightly lower priority than pattern-based
                exampleIds: extChanges.map { $0.id },
                explanation: "In this folder, .\(ext.lowercased()) files belong in '\(destFolderName)'\(sourceClause).",
                successCount: 0,
                failureCount: 0,
                isEnabled: true,
                lastAppliedAt: nil,
                supportCount: extChanges.count,
                scope: .folder(scopePath(forDestinationFolder: destFolder))
            )
            rules.append(rule)
        }
        
        return rules
    }
    
    // MARK: - Positive Example Inference
    
    private func inferRulesFromExamples(_ examples: [LabeledExample], action: ExampleAction) -> [InferredRule] {
        var rules: [InferredRule] = []
        
        // Group by destination folder
        var byDestFolder: [String: [LabeledExample]] = [:]
        for example in examples where example.action == action {
            let destFolder = URL(fileURLWithPath: example.dstPath).deletingLastPathComponent().path
            byDestFolder[destFolder, default: []].append(example)
        }
        
        for (destFolder, folderExamples) in byDestFolder where folderExamples.count >= minExamplesForRule {
            let srcFilenames = folderExamples.map { URL(fileURLWithPath: $0.srcPath).lastPathComponent }
            
            if let pattern = findCommonPattern(in: srcFilenames) {
                let destFolderName = URL(fileURLWithPath: destFolder).lastPathComponent
                let sourceFolders = Set(folderExamples.map {
                    URL(fileURLWithPath: $0.srcPath).deletingLastPathComponent().lastPathComponent
                }).filter { !$0.isEmpty && $0 != destFolderName }
                let sourceClause = action == .edit && sourceFolders.count == 1
                    ? ", not '\(sourceFolders.first!)'"
                    : ""
                let confidence = calculateConfidence(exampleCount: folderExamples.count, isRecent: areRecent(folderExamples.map { $0.timestamp }))
                
                let rule = InferredRule(
                    id: "local-positive-\(UUID().uuidString.prefix(8))",
                    pattern: pattern.regex,
                    template: "\(destFolder)/{filename}",
                    metadataCues: [],
                    priority: Int(confidence * (action == .edit ? 90 : 70)),
                    exampleIds: folderExamples.map { $0.id },
                    explanation: action == .edit
                        ? "In this folder, files matching '\(pattern.description)' belong in '\(destFolderName)'\(sourceClause)."
                        : "Files matching '\(pattern.description)' go to '\(destFolderName)' (learned from \(folderExamples.count) accepted examples).",
                    successCount: 0,
                    failureCount: 0,
                    isEnabled: true,
                    lastAppliedAt: nil,
                    supportCount: folderExamples.count,
                    scope: .folder(
                        folderExamples.compactMap { $0.metadata?["folder_scope"] }.first
                            ?? scopePath(forDestinationFolder: destFolder)
                    )
                )
                rules.append(rule)
            }

            if action == .edit {
                let byExtension = Dictionary(grouping: folderExamples) {
                    URL(fileURLWithPath: $0.srcPath).pathExtension.lowercased()
                }
                for (ext, examples) in byExtension where !ext.isEmpty && examples.count >= minExamplesForRule {
                    let destination = URL(fileURLWithPath: destFolder).lastPathComponent
                    let sourceFolders = Set(examples.map {
                        URL(fileURLWithPath: $0.srcPath).deletingLastPathComponent().lastPathComponent
                    }).filter { !$0.isEmpty && $0 != destination }
                    let sourceClause = sourceFolders.count == 1 ? ", not '\(sourceFolders.first!)'" : ""
                    let escapedExtension = NSRegularExpression.escapedPattern(for: ext)
                    rules.append(InferredRule(
                        id: "local-preview-ext-\(ext)-\(UUID().uuidString.prefix(8))",
                        pattern: ".*\\.\(escapedExtension)$",
                        template: "\(destFolder)/{filename}",
                        priority: 85,
                        exampleIds: examples.map(\.id),
                        explanation: "In this folder, .\(ext) files belong in '\(destination)'\(sourceClause).",
                        supportCount: examples.count,
                        initialConfidence: .medium,
                        scope: .folder(
                            examples.compactMap { $0.metadata?["folder_scope"] }.first
                                ?? scopePath(forDestinationFolder: destFolder)
                        )
                    ))
                }
            }
        }
        
        return rules
    }

    private func scopePath(forDestinationFolder destinationFolder: String) -> String {
        let parent = URL(fileURLWithPath: destinationFolder).deletingLastPathComponent().path
        return parent.isEmpty ? destinationFolder : parent
    }
    
    // MARK: - Steering Prompt Inference
    
    private func inferRulesFromSteeringPrompts(_ prompts: [SteeringPrompt]) -> [InferredRule] {
        var rules: [InferredRule] = []
        
        // Parse common patterns from steering prompts
        for prompt in prompts {
            let lowered = prompt.prompt.lowercased()
            
            // Pattern: "put X in Y folder" / "move X to Y"
            rules.append(contentsOf: parseMovementInstructions(prompt.prompt, sessionId: prompt.sessionId))
            
            // Pattern: "don't put X in Y" - could be used for negative rules
            // For now, skip negative patterns
            
            // Pattern: "organize by date/type/project"
            if lowered.contains("by date") || lowered.contains("by year") || lowered.contains("by month") {
                let rule = InferredRule(
                    id: "local-steering-date-\(UUID().uuidString.prefix(8))",
                    pattern: ".*",
                    template: "{year}/{month}/{filename}",
                    metadataCues: ["fs:ctime"],
                    priority: 60,
                    exampleIds: [],
                    explanation: "Organize files by date (from user instruction)",
                    successCount: 0,
                    failureCount: 0,
                    isEnabled: true,
                    lastAppliedAt: nil,
                    supportCount: 1
                )
                rules.append(rule)
            }
            
            if lowered.contains("by type") || lowered.contains("by extension") {
                let rule = InferredRule(
                    id: "local-steering-type-\(UUID().uuidString.prefix(8))",
                    pattern: ".*",
                    template: "{category}/{filename}",
                    metadataCues: [],
                    priority: 55,
                    exampleIds: [],
                    explanation: "Organize files by type (from user instruction)",
                    successCount: 0,
                    failureCount: 0,
                    isEnabled: true,
                    lastAppliedAt: nil,
                    supportCount: 1
                )
                rules.append(rule)
            }
        }
        
        return rules
    }
    
    private func parseMovementInstructions(_ instruction: String, sessionId: String?) -> [InferredRule] {
        // Try to extract "X to Y" or "X in Y" patterns
        let patterns = [
            "put (\\w+) (?:files? )?(?:in|to|into) ([\\w\\s/]+)",
            "move (\\w+) to ([\\w\\s/]+)",
            "(\\w+) should go (?:in|to) ([\\w\\s/]+)"
        ]

        var rules: [InferredRule] = []
        // The file type named most recently lets a later clause refer back to
        // it by pronoun ("Don't put images in Photos, put them in Pictures").
        var lastFileType: String?

        // Negation only scopes to the clause it appears in, so one negative
        // instruction cannot veto a positive instruction elsewhere in the
        // prompt. Commas and em-dashes are clause boundaries: they separate
        // the mirrored positive and negative forms ("... , put them in ...").
        for clause in instructionClauses(from: instruction) {
            for patternStr in patterns {
                guard let regex = try? NSRegularExpression(pattern: patternStr, options: .caseInsensitive) else {
                    continue
                }

                // Every movement instruction in a clause matters; first-match
                // only dropped the rest of a multi-move clause.
                for match in regex.matches(in: clause, range: NSRange(clause.startIndex..., in: clause)) {
                    guard match.numberOfRanges >= 3,
                          let fullRange = Range(match.range, in: clause),
                          let fileTypeRange = Range(match.range(at: 1), in: clause),
                          let folderRange = Range(match.range(at: 2), in: clause) else {
                        continue
                    }

                    let matchedFileType = String(clause[fileTypeRange]).trimmingCharacters(in: .whitespaces)
                    let folderName = String(clause[folderRange]).trimmingCharacters(in: .whitespaces)
                    guard !folderName.isEmpty else { continue }

                    // Pronoun subjects resolve to the file type named earlier
                    // in the prompt; without a referent the clause is not a
                    // rule, and must never become a broad "...them..." pattern.
                    let fileType: String
                    if Self.pronounFileTypes.contains(matchedFileType.lowercased()) {
                        guard let lastFileType else { continue }
                        fileType = lastFileType
                    } else {
                        lastFileType = matchedFileType
                        fileType = matchedFileType
                    }

                    // A negated instruction ("don't put X in Y", "never move X
                    // to Y") must never become a positive rule. The negation
                    // has to sit in the verb phrase immediately before the
                    // matched verb; a whole-prefix scan over-rejects ("Don't
                    // forget to put PNGs in Images").
                    guard !isNegatedInstruction(String(clause[..<fullRange.lowerBound])) else {
                        continue
                    }

                    // Match case-insensitively but keep the folder name exactly as the
                    // user wrote it so templates preserve the original casing.
                    let extensionPattern: String
                    let categoryExtensions: [String] = {
                        switch fileType.lowercased() {
                        case "documents":
                            return ["pdf", "docx", "doc", "xls", "xlsx", "ppt", "pptx", "txt", "rtf"]
                        case "photos", "images":
                            return ["jpg", "jpeg", "png", "gif", "bmp", "svg", "webp", "raw"]
                        case "videos":
                            return ["mp4", "mov", "mkv", "avi", "flv", "wmv", "m4v"]
                        case "music", "audio":
                            return ["mp3", "wav", "flac", "aac", "m4a", "wma", "ogg", "aiff"]
                        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "jpg", "png", "mp3", "mp4":
                            return [fileType.lowercased()]
                        default:
                            // "PNGs"/"PDFs" are common plurals; map them to the
                            // singular extension when it is a known file type.
                            let lowered = fileType.lowercased()
                            if lowered.hasSuffix("s") {
                                let singular = String(lowered.dropLast())
                                if FileCategory.from(extension: singular) != .other {
                                    return [singular]
                                }
                            }
                            return []
                        }
                    }()
                    
                    if !categoryExtensions.isEmpty {
                        let escapedExts = categoryExtensions.map { NSRegularExpression.escapedPattern(for: $0) }
                        extensionPattern = ".*\\.(" + escapedExts.joined(separator: "|") + ")$"
                    } else {
                        // For unknown types, escape the user input before embedding
                        let escapedFileType = NSRegularExpression.escapedPattern(for: fileType.lowercased())
                        extensionPattern = ".*" + escapedFileType + ".*"
                    }
                    
                    rules.append(InferredRule(
                        id: "local-steering-\(UUID().uuidString.prefix(8))",
                        pattern: extensionPattern,
                        template: "\(folderName)/{filename}",
                        metadataCues: [],
                        priority: 75, // High priority for explicit instructions
                        exampleIds: [],
                        explanation: "\(fileType.capitalized) files should go to '\(folderName)/' (from your instruction)",
                        successCount: 0,
                        failureCount: 0,
                        isEnabled: true,
                        lastAppliedAt: nil,
                        supportCount: 1
                    ))
                }
            }
        }
        
        return rules
    }

    /// Sentence-like clauses a steering instruction can contain. Negation must
    /// not leak across these boundaries. Commas and dashes separate mirrored
    /// positive/negative halves ("Don't put images in Photos, put them in Pictures").
    private func instructionClauses(from instruction: String) -> [String] {
        instruction.split { character in
            character == "." || character == "!" || character == "?" || character == ";" || character == "\n"
                || character == "," || character == "—" || character == "–"
        }.map(String.init)
    }

    /// Pronouns that stand in for a file type named in an earlier clause.
    private static let pronounFileTypes: Set<String> = [
        "them", "they", "it", "those", "these", "that", "this"
    ]

    /// True when the words immediately before a movement verb negate that verb.
    /// Only the immediate verb phrase counts: "don't put"/"never move" negate,
    /// while a trailing "to" means the matched verb belongs to a new phrase
    /// ("don't forget to put PNGs in Images" is a positive instruction).
    private func isNegatedInstruction(_ precedingText: String) -> Bool {
        let normalized = precedingText
            .replacingOccurrences(of: "’", with: "'")
            .lowercased()
        let tokens = normalized.split { !$0.isLetter && !$0.isNumber && $0 != "'" }
        guard let last = tokens.last, last != "to" else { return false }
        return tokens.suffix(2).contains { token in
            Self.negationTokens.contains(token.replacingOccurrences(of: "'", with: ""))
        }
    }

    /// Negation words with apostrophes stripped ("don't" -> "dont").
    private static let negationTokens: Set<String> = [
        "dont", "wont", "doesnt", "didnt", "isnt", "arent", "wasnt", "werent",
        "cant", "couldnt", "shouldnt", "wouldnt", "mustnt", "neednt",
        "no", "not", "never", "avoid"
    ]
    
    // MARK: - Pattern Detection
    
    private struct DetectedPattern {
        let regex: String
        let description: String
    }
    
    private func findCommonPattern(in filenames: [String]) -> DetectedPattern? {
        guard !filenames.isEmpty else { return nil }
        
        // 1. Check for common prefix
        if let prefix = findLongestCommonPrefix(filenames), prefix.count >= 3 {
            return DetectedPattern(
                regex: "^\(NSRegularExpression.escapedPattern(for: prefix)).*",
                description: "files starting with '\(prefix)'"
            )
        }
        
        // 2. Check for common extension grouping
        let extensions = Set(filenames.map { URL(fileURLWithPath: $0).pathExtension.lowercased() })
        if extensions.count == 1, let ext = extensions.first, !ext.isEmpty {
            let escapedExt = NSRegularExpression.escapedPattern(for: ext)
            return DetectedPattern(
                regex: ".*\\.\(escapedExt)$",
                description: ".\(ext.uppercased()) files"
            )
        }
        
        // 3. Check for date pattern in filenames
        let hasDatePattern = filenames.allSatisfy { name in
            name.range(of: "\\d{4}[-_]?\\d{2}[-_]?\\d{2}", options: .regularExpression) != nil ||
            name.range(of: "IMG_\\d+", options: .regularExpression) != nil ||
            name.range(of: "VID_\\d+", options: .regularExpression) != nil
        }
        if hasDatePattern {
            return DetectedPattern(
                regex: ".*(\\d{4}[-_]?\\d{2}[-_]?\\d{2}|IMG_\\d+|VID_\\d+).*",
                description: "dated/camera files"
            )
        }
        
        // 4. Check for common keywords
        let keywords = extractCommonKeywords(from: filenames)
        if let keyword = keywords.first, keyword.count >= 3 {
            return DetectedPattern(
                regex: ".*\(NSRegularExpression.escapedPattern(for: keyword)).*",
                description: "files containing '\(keyword)'"
            )
        }
        
        return nil
    }
    
    private func findLongestCommonPrefix(_ strings: [String]) -> String? {
        guard let first = strings.first else { return nil }
        
        var prefix = ""
        for (index, _) in first.enumerated() {
            let candidate = String(first.prefix(index + 1))
            if strings.allSatisfy({ $0.hasPrefix(candidate) }) {
                prefix = candidate
            } else {
                break
            }
        }
        
        return prefix.isEmpty ? nil : prefix
    }
    
    private func extractCommonKeywords(from filenames: [String]) -> [String] {
        // Count distinct filenames per token: a token repeated inside one
        // filename is one observation, not two.
        var counts: [String: Int] = [:]
        for filename in filenames {
            let name = (filename as NSString).deletingPathExtension
            let tokens = Set(name.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
                .map { $0.lowercased() })
            for token in tokens {
                counts[token, default: 0] += 1
            }
        }
        
        // A token seen in a single sample can never justify a rule: require a
        // majority of the filenames and at least two of them.
        let threshold = max(2, filenames.count / 2 + 1)
        return counts.filter { $0.value >= threshold }
            .sorted { $0.value > $1.value }
            .map { $0.key }
    }
    
    // MARK: - Helpers
    
    private func calculateConfidence(exampleCount: Int, isRecent: Bool) -> Double {
        // Base confidence from example count (logarithmic scaling)
        var confidence = min(0.5 + log10(Double(exampleCount + 1)) * 0.3, 0.95)
        
        // Boost for recent examples
        if isRecent {
            confidence = min(confidence * recentWeightMultiplier, 0.98)
        }
        
        return confidence
    }
    
    private func areRecent(_ dates: [Date]) -> Bool {
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        return dates.contains { $0 > sevenDaysAgo }
    }
    
    // MARK: - Rule Merging
    
    private func mergeAndDeduplicateRules(_ rules: [InferredRule]) -> [InferredRule] {
        guard !rules.isEmpty else { return [] }
        
        // Group rules by similar pattern
        var merged: [String: InferredRule] = [:]
        
        for rule in rules {
            // Normalize pattern for comparison
            let key = localRuleMergeKey(rule)
            
            if let existing = merged[key] {
                // Merge: boost priority, combine example IDs, update support count
                let newPriority = min(existing.priority + 10, 100)
                let newSupport = existing.supportCount + rule.supportCount
                
                merged[key] = InferredRule(
                    id: existing.id,
                    pattern: existing.pattern,
                    template: existing.template,
                    metadataCues: existing.metadataCues,
                    priority: newPriority,
                    exampleIds: Array(Set(existing.exampleIds + rule.exampleIds)),
                    explanation: existing.explanation,
                    successCount: existing.successCount + rule.successCount,
                    failureCount: existing.failureCount + rule.failureCount,
                    isEnabled: existing.isEnabled,
                    lastAppliedAt: existing.lastAppliedAt ?? rule.lastAppliedAt,
                    supportCount: newSupport,
                    initialConfidence: existing.initialConfidence ?? rule.initialConfidence,
                    scope: existing.scope,
                    status: existing.status,
                    evidenceIds: Array(Set(existing.evidenceIds + rule.evidenceIds)),
                    evidenceDescription: existing.evidenceDescription ?? rule.evidenceDescription,
                    rejectedAt: existing.rejectedAt,
                    cooldownUntil: existing.cooldownUntil
                )
            } else {
                merged[key] = rule
            }
        }
        
        return Array(merged.values)
    }
}

private func localRuleMergeKey(_ rule: InferredRule) -> String {
    let scope: String
    switch rule.scope {
    case .global:
        scope = "global"
    case .folder(let path):
        scope = "folder:\(URL(fileURLWithPath: path).standardizedFileURL.path)"
    case .activePersona(let id):
        scope = "persona:\(id.uuidString)"
    }
    return "\(rule.pattern)|\(rule.template)|\(scope)"
}

// MARK: - LearningsManager Integration

extension LearningsManager {
    
    /// Run local rule inference without requiring AI
    public func runLocalRuleInference() async {
        guard let profile = currentProfile else { return }
        let sourceProfile = filteredLearningProfile(from: profile)

        let engine = LocalRuleInferenceEngine()
        let inferredRules = await engine.inferRules(from: sourceProfile)

        // Re-read the profile after the await: feedback recorded while
        // inference ran must not be dropped by assigning the pre-await snapshot.
        guard var workingProfile = currentProfile else { return }
        workingProfile = filteredLearningProfile(from: workingProfile)
        workingProfile.inferredRules.removeAll { $0.id.hasPrefix("local-avoid-") }
        
        // Merge with existing rules: strengthen duplicates with new evidence instead of
        // discarding it, so re-inference keeps established rules learning. User-controlled
        // state (enabled, status, cooldown, explanation, scope) and observed outcome counts
        // are always preserved from the existing rule.
        var indexByKey: [String: Int] = [:]
        for (index, rule) in workingProfile.inferredRules.enumerated() {
            indexByKey[localRuleMergeKey(rule)] = index
        }
        
        for newRule in inferredRules {
            let key = localRuleMergeKey(newRule)
            if let index = indexByKey[key] {
                let existing = workingProfile.inferredRules[index]
                workingProfile.inferredRules[index] = InferredRule(
                    id: existing.id,
                    pattern: existing.pattern,
                    template: existing.template,
                    metadataCues: Array(Set(existing.metadataCues + newRule.metadataCues)),
                    // Priority magnitude is the signal (avoid rules are negative), and the
                    // engine recomputes it from the full evidence set each run.
                    priority: abs(newRule.priority) > abs(existing.priority) ? newRule.priority : existing.priority,
                    exampleIds: Array(Set(existing.exampleIds + newRule.exampleIds)),
                    explanation: existing.explanation,
                    successCount: existing.successCount,
                    failureCount: existing.failureCount,
                    isEnabled: existing.isEnabled,
                    lastAppliedAt: existing.lastAppliedAt,
                    // max, not sum: each inference run recounts support from the same profile data.
                    supportCount: max(existing.supportCount, newRule.supportCount),
                    initialConfidence: existing.initialConfidence ?? newRule.initialConfidence,
                    scope: existing.scope,
                    status: existing.status,
                    evidenceIds: Array(Set(existing.evidenceIds + newRule.evidenceIds)),
                    evidenceDescription: existing.evidenceDescription ?? newRule.evidenceDescription,
                    rejectedAt: existing.rejectedAt,
                    cooldownUntil: existing.cooldownUntil
                )
            } else {
                workingProfile.inferredRules.append(newRule)
                indexByKey[key] = workingProfile.inferredRules.count - 1
            }
        }
        
        currentProfile = workingProfile
        await forceSave()
        
        ModelLog.log("Local rule inference complete: \(inferredRules.count) new rules inferred", category: "Learnings")
    }
    
    /// Trigger automatic rule inference when enough new data is available
    public func checkAndTriggerAutoInference() async {
        guard let profile = currentProfile else { return }
        
        // Check if we have enough new data since last inference
        let lastInferenceDate = UserDefaults.standard.object(forKey: "lastLocalRuleInference") as? Date ?? Date.distantPast
        let hoursSinceLastInference = Date().timeIntervalSince(lastInferenceDate) / 3600
        
        // Run inference if:
        // 1. More than 24 hours since last inference, OR
        // 2. We have 2+ new corrections since last inference (Eager learning)
        let recentCorrections = profile.postOrganizationChanges.filter { $0.timestamp > lastInferenceDate }
        
        if hoursSinceLastInference > 24 || recentCorrections.count >= 2 {
            await runLocalRuleInference()
            UserDefaults.standard.set(Date(), forKey: "lastLocalRuleInference")
        }
    }
}
