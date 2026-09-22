//
//  RuleInducer.swift
//  Sorty
//
//  Core rule induction logic - learns regex+template rules from examples
//

import Foundation

/// Induces organization rules from labeled examples and example folders
public actor RuleInducer {
    
    // MARK: - Properties
    
    private var examples: [LabeledExample] = []
    private var exampleFolders: [URL] = []
    
    // MARK: - Public API
    
    /// Induce rules from examples and example folders
    public func induceRules(
        from examples: [LabeledExample],
        exampleFolders: [URL]
    ) async -> [InferredRule] {
        self.examples = examples
        self.exampleFolders = exampleFolders
        
        var rules: [InferredRule] = []
        
        // 1. Analyze example folders first (high priority)
        for folder in exampleFolders {
            guard !Task.isCancelled else { break }
            let folderRules = await analyzeExampleFolder(folder)
            rules.append(contentsOf: folderRules)
            await Task.yield()
        }
        
        // 2. Analyze labeled examples by file category
        let categorizedExamples = categorizeExamples(examples)
        for (category, categoryExamples) in categorizedExamples {
            let categoryRules = induceRulesFromCategory(category, examples: categoryExamples)
            rules.append(contentsOf: categoryRules)
        }
        
        // 3. Merge and deduplicate rules
        rules = mergeRules(rules)
        
        // 4. Sort by priority (higher first)
        rules.sort { $0.priority > $1.priority }
        
        return rules
    }

    // MARK: - Private Methods
    
    /// Analyze an example folder to infer rules
    private func analyzeExampleFolder(_ folderURL: URL) async -> [InferredRule] {
        var rules: [InferredRule] = []
        
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        
        var filePaths: [String] = []
        var folderStructure: [String: [String]] = [:]  // folder path -> file names
        var scannedSinceYield = 0
        
        while let url = enumerator.nextObject() as? URL {
            guard !Task.isCancelled else { break }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDirectory {
                filePaths.append(url.path)
                let parent = url.deletingLastPathComponent().path
                folderStructure[parent, default: []].append(url.lastPathComponent)
            }
            scannedSinceYield += 1
            if scannedSinceYield >= 20 {
                scannedSinceYield = 0
                await Task.yield()
            }
        }
        
        // Analyze folder structure
        let structureAnalysis = PatternMatcher.analyzeFolderStructure(from: filePaths)
        
        // Group files by category
        var filesByCategory: [FileCategory: [String]] = [:]
        for path in filePaths {
            let ext = URL(fileURLWithPath: path).pathExtension
            let category = FileCategory.from(extension: ext)
            filesByCategory[category, default: []].append(path)
        }
        
        // Create rules for each category found in the example folder
        for (category, paths) in filesByCategory {
            let filenames = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
            
            // Detect patterns
            if let pattern = PatternMatcher.buildPattern(from: filenames) {
                // Build template from folder structure
                let template = buildTemplateFromStructure(structureAnalysis, category: category)
                
                let rule = InferredRule(
                    id: "rule-\(category.rawValue)-\(UUID().uuidString.prefix(8))",
                    pattern: pattern,
                    template: template,
                    metadataCues: metadataCuesForCategory(category),
                    priority: 100, // High priority for example folder rules
                    exampleIds: [],
                    explanation: "Learned from example folder '\(folderURL.lastPathComponent)': \(category.rawValue) files organized by \(structureAnalysis.primaryGroupingKey ?? "name")"
                )
                rules.append(rule)
            }
        }
        
        return rules
    }
    
    /// Categorize examples by file type
    private func categorizeExamples(_ examples: [LabeledExample]) -> [FileCategory: [LabeledExample]] {
        var result: [FileCategory: [LabeledExample]] = [:]
        
        for example in examples {
            let ext = URL(fileURLWithPath: example.srcPath).pathExtension
            let category = FileCategory.from(extension: ext)
            result[category, default: []].append(example)
        }
        
        return result
    }
    
    /// Induce rules from examples of a single category
    private func induceRulesFromCategory(_ category: FileCategory, examples: [LabeledExample]) -> [InferredRule] {
        guard !examples.isEmpty else { return [] }
        
        var rules: [InferredRule] = []
        
        // Extract source filenames
        let srcFilenames = examples.map { URL(fileURLWithPath: $0.srcPath).lastPathComponent }
        
        // Detect common patterns in source filenames
        if let pattern = PatternMatcher.buildPattern(from: srcFilenames) {
            // Analyze destination structure
            let dstPaths = examples.map { $0.dstPath }
            let structureAnalysis = PatternMatcher.analyzeFolderStructure(from: dstPaths)
            
            let template = buildTemplateFromStructure(structureAnalysis, category: category)
            
            // Calculate priority based on number of examples
            let priority = min(examples.count * 5, 50)
            
            let rule = InferredRule(
                id: "rule-\(category.rawValue)-\(UUID().uuidString.prefix(8))",
                pattern: pattern,
                template: template,
                metadataCues: metadataCuesForCategory(category),
                priority: priority,
                exampleIds: examples.map { $0.id },
                explanation: describeRule(category: category, structure: structureAnalysis, exampleCount: examples.count)
            )
            rules.append(rule)
        }
        
        return rules
    }
    
    /// Build template string from structure analysis
    private func buildTemplateFromStructure(_ structure: FolderStructureAnalysis, category: FileCategory) -> String {
        var parts: [String] = []
        
        // Category folder if detected
        if structure.usesCategoryFolders {
            parts.append("{category}")
        }
        
        // Date-based organization
        if structure.usesDateFolders {
            parts.append("{year}/{date}")
        } else if structure.usesYearFolders && structure.usesMonthFolders {
            parts.append("{year}/{month}")
        } else if structure.usesYearFolders {
            parts.append("{year}")
        }
        
        // If no structure detected, use category
        if parts.isEmpty {
            parts.append(category.rawValue.capitalized)
        }
        
        // Add filename
        parts.append("{filename}")
        
        return parts.joined(separator: "/")
    }
    
    /// Get metadata cues for a file category
    private func metadataCuesForCategory(_ category: FileCategory) -> [String] {
        switch category {
        case .photo:
            return ["exif:DateTimeOriginal", "exif:Make", "exif:Model", "fs:ctime"]
        case .video:
            return ["fs:ctime", "fs:mtime"]
        case .music:
            return ["id3:artist", "id3:album", "id3:title", "id3:track"]
        case .document:
            return ["pdf:title", "pdf:author", "fs:ctime"]
        default:
            return ["fs:ctime", "fs:mtime"]
        }
    }
    
    /// Generate human-readable description of a rule
    private func describeRule(category: FileCategory, structure: FolderStructureAnalysis, exampleCount: Int) -> String {
        var description = "\(category.rawValue.capitalized) files"
        
        if let grouping = structure.primaryGroupingKey {
            description += " organized by \(grouping)"
        }
        
        description += " (based on \(exampleCount) example\(exampleCount == 1 ? "" : "s"))"
        
        return description
    }
    
    /// Merge similar rules
    private func mergeRules(_ rules: [InferredRule]) -> [InferredRule] {
        // Group by pattern
        let grouped = Dictionary(grouping: rules) { $0.pattern }
        
        return grouped.values.map { group in
            guard let first = group.first else { return group }
            
            if group.count == 1 {
                return group
            }
            
            // Merge into single rule with combined examples
            let mergedExampleIds = group.flatMap { $0.exampleIds }
            let highestPriority = group.map { $0.priority }.max() ?? 0
            
            return [InferredRule(
                id: first.id,
                pattern: first.pattern,
                template: first.template,
                metadataCues: first.metadataCues,
                priority: highestPriority,
                exampleIds: mergedExampleIds,
                explanation: first.explanation
            )]
        }.flatMap { $0 }
    }
}
