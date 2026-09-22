//
//  ReferenceDirectoryScanner.swift
//  Sorty
//
//  Scans a reference model directory off the main actor, capturing folder hierarchy,
//  file-type distribution, and naming conventions for prompt injection.
//

import Foundation

public enum ReferenceDirectoryScanError: LocalizedError, Sendable {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let path):
            return "The reference directory is unavailable: \(path)"
        }
    }
}

public struct ReferenceDirectoryScanner: Sendable {
    
    private static let maxDepth = 3
    private static let maxFolders = 50
    private static let maxSampleFileNames = 5
    
    /// Scan a directory and return a snapshot. Safe to call off the main actor.
    public static func scan(url: URL) async throws -> ReferenceDirectorySnapshot {
        try await Task.detached(priority: .utility) {
            try await performScan(url: url)
        }.value
    }
    
    private static func performScan(url: URL) async throws -> ReferenceDirectorySnapshot {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fm.isReadableFile(atPath: url.path) else {
            throw ReferenceDirectoryScanError.unavailable(url.path)
        }
        var folders: [ReferenceFolder] = []
        var totalFileCount = 0
        var allFolderNames: [String] = []
        var allFileNames: [String] = []
        var categoryDistribution: [FileCategory: Int] = [:]
        var extensionDistribution: [String: Int] = [:]
        var encounteredReadFailure = false
        var reachedDepthLimit = false
        var reachedFolderLimit = false
        // Yield cooperatively every 20 files; the nested scan is async so it
        // can suspend without blocking its executor thread.
        var scannedSinceYield = 0

        func scannedOneFile() async throws {
            scannedSinceYield += 1
            if scannedSinceYield >= 20 {
                scannedSinceYield = 0
                await Task.yield()
            }
            try Task.checkCancellation()
        }
        
        func scanDirectory(_ scanURL: URL, depth: Int, prefix: String) async throws {
            guard !Task.isCancelled else {
                return
            }
            guard depth <= maxDepth else {
                reachedDepthLimit = true
                return
            }
            guard folders.count < maxFolders else {
                reachedFolderLimit = true
                return
            }
            
            let contents: [URL]
            do {
                contents = try fm.contentsOfDirectory(
                    at: scanURL,
                    includingPropertiesForKeys: [
                        .isDirectoryKey,
                        .fileSizeKey,
                        .ubiquitousItemDownloadingStatusKey,
                    ],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            } catch {
                encounteredReadFailure = true
                return
            }
            
            var subdirs: [URL] = []
            var files: [URL] = []
            for item in contents {
                guard let values = try? item.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .fileSizeKey,
                    .ubiquitousItemDownloadingStatusKey,
                ]) else {
                    encounteredReadFailure = true
                    continue
                }
                if values.isDirectory == true {
                    subdirs.append(item)
                } else if !FolderWatcher.shouldIgnoreCloudPlaceholder(
                        at: item,
                        resourceValues: values
                ) {
                    files.append(item)
                }
            }
            subdirs.sort {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
            files.sort {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
            
            var typeDistribution: [String: Int] = [:]
            
            for file in files {
                try await scannedOneFile()
                let ext = file.pathExtension.lowercased()
                let key = ext.isEmpty ? "(none)" : ext
                typeDistribution[key, default: 0] += 1
                extensionDistribution[key, default: 0] += 1
                categoryDistribution[FileCategory.from(extension: ext), default: 0] += 1
            }
            let sampleNames = representativeNames(
                from: files.map(\.lastPathComponent),
                limit: maxSampleFileNames
            )
            allFileNames.append(contentsOf: sampleNames.map {
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
            })
            
            let fileCount = files.count
            totalFileCount += fileCount
            
            if !prefix.isEmpty {
                let folderName = scanURL.lastPathComponent
                allFolderNames.append(folderName)
                folders.append(ReferenceFolder(
                    relativePath: prefix,
                    name: folderName,
                    depth: depth,
                    fileCount: fileCount,
                    fileTypeDistribution: typeDistribution,
                    sampleFileNames: sampleNames
                ))
            }
            
            for subdir in subdirs {
                guard !Task.isCancelled else { return }
                if folders.count >= maxFolders {
                    reachedFolderLimit = true
                    return
                }
                let name = prefix.isEmpty ? subdir.lastPathComponent : "\(prefix)/\(subdir.lastPathComponent)"
                try await scanDirectory(subdir, depth: depth + 1, prefix: name)
            }
        }
        
        try await scanDirectory(url, depth: 0, prefix: "")
        try Task.checkCancellation()
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fm.isReadableFile(atPath: url.path) else {
            throw ReferenceDirectoryScanError.unavailable(url.path)
        }
        
        let conventions = detectNamingConventions(folderNames: allFolderNames)
        let fileConventions = detectNamingConventions(folderNames: allFileNames)
        var warnings: [String] = []
        if encounteredReadFailure {
            warnings.append("Some items could not be read")
        }
        if reachedDepthLimit {
            warnings.append("Folders deeper than \(maxDepth) levels were not scanned")
        }
        if reachedFolderLimit {
            warnings.append("Only the first \(maxFolders) folders were scanned")
        }
        
        return ReferenceDirectorySnapshot(
            scannedAt: Date(),
            folderHierarchy: folders,
            namingConventions: conventions,
            fileNamingConventions: fileConventions,
            fileCategoryDistribution: categoryDistribution,
            fileExtensionDistribution: extensionDistribution,
            totalFolderCount: folders.count,
            totalFileCount: totalFileCount,
            warnings: warnings,
            isTruncated: reachedDepthLimit || reachedFolderLimit
        )
    }

    private static func representativeNames(from names: [String], limit: Int) -> [String] {
        guard names.count > limit, limit > 1 else { return Array(names.prefix(limit)) }
        return (0..<limit).map { index in
            let position = index * (names.count - 1) / (limit - 1)
            return names[position]
        }
    }
    
    // MARK: - Naming Convention Detection
    
    private static func detectNamingConventions(folderNames: [String]) -> [String] {
        guard !folderNames.isEmpty else { return [] }
        
        var conventions: [String] = []
        var kebabCount = 0
        var snakeCount = 0
        var titleCaseCount = 0
        var camelCaseCount = 0
        var datePatternCount = 0
        var uppercaseCount = 0
        
        // Compiled once per pass over both convention inputs, not once per name.
        let dateRegex = try? NSRegularExpression(pattern: #"\d{4}[-_]\d{2}[-_]\d{2}"#)
        let kebabRegex = try? NSRegularExpression(pattern: #"^[a-z0-9]+(-[a-z0-9]+)+$"#)
        let snakeRegex = try? NSRegularExpression(pattern: #"^[a-z0-9]+(_[a-z0-9]+)+$"#)
        
        for name in folderNames {
            let range = NSRange(name.startIndex..., in: name)

            if let dateRegex, dateRegex.firstMatch(in: name, range: range) != nil {
                datePatternCount += 1
            }
            if let kebabRegex, kebabRegex.firstMatch(in: name, range: range) != nil {
                kebabCount += 1
            }
            if let snakeRegex, snakeRegex.firstMatch(in: name, range: range) != nil {
                snakeCount += 1
            }
            if name == name.uppercased() && name.count > 1 && name.contains(where: { $0.isLetter }) {
                uppercaseCount += 1
            }
            if isTitleCase(name) {
                titleCaseCount += 1
            }
            if isCamelCase(name) {
                camelCaseCount += 1
            }
        }
        
        let threshold = max(1, folderNames.count / 5)
        
        if datePatternCount >= threshold { conventions.append("YYYY-MM-DD date prefixes") }
        if kebabCount >= threshold { conventions.append("kebab-case") }
        if snakeCount >= threshold { conventions.append("snake_case") }
        if titleCaseCount >= threshold { conventions.append("Title Case") }
        if camelCaseCount >= threshold { conventions.append("camelCase") }
        if uppercaseCount >= threshold { conventions.append("UPPERCASE") }
        
        if conventions.isEmpty {
            conventions.append("mixed naming")
        }
        
        return conventions
    }
    
    private static func isTitleCase(_ name: String) -> Bool {
        let words = name.components(separatedBy: .whitespaces).filter {
            $0.contains(where: \.isLetter)
        }
        guard words.count >= 2 else { return false }
        return words.allSatisfy { word in
            guard let first = word.first(where: \.isLetter) else { return false }
            return first.isUppercase
        }
    }
    
    private static func isCamelCase(_ name: String) -> Bool {
        guard name.count > 2,
              let first = name.first, first.isLowercase,
              !name.contains(" "), !name.contains("-"), !name.contains("_")
        else { return false }
        return name.contains(where: { $0.isUppercase })
    }
}
