//
//  ExclusionRule.swift
//  Sorty
//
//  Comprehensive exclusion rules for file organization
//  Supports multiple rule types, presets, and advanced matching
//

import Foundation
import Combine

// MARK: - Rule Types

public enum ExclusionRuleType: String, Codable, CaseIterable, Identifiable, Sendable {
    case fileExtension = "File Extension"
    case fileName = "File Name"
    case folderName = "Folder Name"
    case pathContains = "Path Contains"
    case regex = "Regular Expression"
    case fileSize = "File Size"
    case creationDate = "Creation Date"
    case modificationDate = "Modification Date"
    case hiddenFiles = "Hidden Files"
    case systemFiles = "System Files"
    case finderTag = "Finder Tag"
    case fileType = "File Type Category"
    case customScript = "Custom Script"

    public var id: String { rawValue }

    public var friendlyName: String {
        switch self {
        case .fileExtension: return "Files with an extension"
        case .fileName: return "Files with a name"
        case .folderName: return "Folders with a name"
        case .pathContains: return "Paths containing text"
        case .regex: return "Advanced name pattern"
        case .fileSize: return "Files by size"
        case .creationDate: return "Files by creation date"
        case .modificationDate: return "Files by modification date"
        case .hiddenFiles: return "Hidden files"
        case .systemFiles: return "macOS system files"
        case .finderTag: return "Files with a Finder tag"
        case .fileType: return "A kind of file"
        case .customScript: return "Custom script"
        }
    }

}

// MARK: - File Type Categories

public enum FileTypeCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case images = "Images"
    case videos = "Videos"
    case audio = "Audio"
    case documents = "Documents"
    case archives = "Archives"
    case code = "Code"
    case applications = "Applications"
    case fonts = "Fonts"
    case databases = "Databases"
    case other = "Other"

    public static var allCases: [FileTypeCategory] {
        [.images, .videos, .audio, .documents, .archives, .code, .applications, .fonts, .databases]
    }

    public var id: String { rawValue }

    public var extensions: [String] {
        switch self {
        case .images:
            return ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp", "svg", "raw", "cr2", "nef", "arw", "dng", "ico", "psd", "ai"]
        case .videos:
            return ["mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "mpeg", "mpg", "3gp", "mts", "m2ts", "vob"]
        case .audio:
            return ["mp3", "wav", "aac", "flac", "ogg", "wma", "m4a", "aiff", "alac", "midi", "mid"]
        case .documents:
            return ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "odt", "ods", "odp", "pages", "numbers", "keynote", "md", "markdown", "epub", "mobi"]
        case .archives:
            return ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "iso", "pkg", "deb", "rpm"]
        case .code:
            return ["swift", "py", "js", "ts", "html", "css", "java", "c", "cpp", "h", "hpp", "m", "mm", "rb", "php", "go", "rs", "kt", "scala", "sh", "bash", "zsh", "json", "xml", "yaml", "yml", "toml", "sql"]
        case .applications:
            return ["app", "exe", "msi", "apk", "ipa"]
        case .fonts:
            return ["ttf", "otf", "woff", "woff2", "eot", "fon"]
        case .databases:
            return ["db", "sqlite", "sqlite3", "mdb", "accdb", "realm"]
        case .other:
            return []
        }
    }

    public var icon: String {
        switch self {
        case .images: return "photo"
        case .videos: return "film"
        case .audio: return "music.note"
        case .documents: return "doc.text"
        case .archives: return "archivebox"
        case .code: return "curlybraces"
        case .applications: return "app.badge"
        case .fonts: return "textformat.abc"
        case .databases: return "cylinder"
        case .other: return "questionmark.folder"
        }
    }
}

public enum ExclusionSizeUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case kilobytes = "KB"
    case megabytes = "MB"
    case gigabytes = "GB"
    case terabytes = "TB"

    public var id: Self { self }

    public var megabyteMultiplier: Double {
        switch self {
        case .kilobytes: 1.0 / 1_024.0
        case .megabytes: 1
        case .gigabytes: 1_024
        case .terabytes: 1_048_576
        }
    }
}

public enum ExclusionAgeUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case seconds
    case minutes
    case hours
    case days
    case weeks
    case months
    case years

    public var id: Self { self }

    public var secondsMultiplier: Double {
        switch self {
        case .seconds: 1
        case .minutes: 60
        case .hours: 3_600
        case .days: 86_400
        case .weeks: 604_800
        case .months: 2_592_000
        case .years: 31_536_000
        }
    }
}

public enum FinderTagColor: Int, Codable, CaseIterable, Identifiable, Sendable {
    case red = 6
    case orange = 7
    case yellow = 5
    case green = 2
    case blue = 4
    case purple = 3
    case gray = 1

    public var id: Self { self }

    public var name: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .gray: "Gray"
        }
    }
}

// MARK: - Exclusion Rule Model

public struct ExclusionRule: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var type: ExclusionRuleType
    public var pattern: String
    public var isEnabled: Bool
    public var description: String?
    public var isBuiltIn: Bool
    public var isAIGenerated: Bool?
    /// Rules sharing this identifier form one AND group. Ungrouped rules remain independent OR exclusions.
    public var conditionGroupID: UUID?

    // For size comparison (in MB)
    public var numericValue: Double?
    // For date comparison direction (true = older than, false = newer than)
    // For size (true = larger than, false = smaller than)
    public var comparisonGreater: Bool?
    public var sizeUnit: ExclusionSizeUnit?
    public var ageUnit: ExclusionAgeUnit?
    public var ageIntervalSeconds: Double?

    // For file type category matching
    public var fileTypeCategory: FileTypeCategory?

    // Case sensitivity for text matching
    public var caseSensitive: Bool

    // Negate the rule (exclude files that DON'T match)
    public var negated: Bool

    public init(
        id: UUID = UUID(),
        type: ExclusionRuleType,
        pattern: String = "",
        isEnabled: Bool = true,
        description: String? = nil,
        isBuiltIn: Bool = false,
        isAIGenerated: Bool = false,
        conditionGroupID: UUID? = nil,
        numericValue: Double? = nil,
        comparisonGreater: Bool? = nil,
        sizeUnit: ExclusionSizeUnit? = nil,
        ageUnit: ExclusionAgeUnit? = nil,
        ageIntervalSeconds: Double? = nil,
        fileTypeCategory: FileTypeCategory? = nil,
        caseSensitive: Bool = false,
        negated: Bool = false
    ) {
        self.id = id
        self.type = type
        self.pattern = pattern
        self.isEnabled = isEnabled
        self.description = description
        self.isBuiltIn = isBuiltIn
        self.isAIGenerated = isAIGenerated
        self.conditionGroupID = conditionGroupID
        self.numericValue = numericValue
        self.comparisonGreater = comparisonGreater
        self.sizeUnit = sizeUnit
        self.ageUnit = ageUnit
        self.ageIntervalSeconds = ageIntervalSeconds
        self.fileTypeCategory = fileTypeCategory
        self.caseSensitive = caseSensitive
        self.negated = negated
    }

    /// Check if a file matches this rule
    public func matches(_ file: FileItem) -> Bool {
        ExclusionMatcher(rules: [self]).shouldExclude(file)
    }

    /// Human-readable description of the rule
    public var displayDescription: String {
        if let desc = description, !desc.isEmpty {
            return desc
        }

        switch type {
        case .fileExtension:
            return ".\(pattern) files"
        case .fileName:
            return "Files containing '\(pattern)'"
        case .folderName:
            return "Folders named '\(pattern)'"
        case .pathContains:
            if pattern.hasPrefix("/") {
                let folderName = URL(fileURLWithPath: pattern).lastPathComponent
                return folderName.isEmpty ? "Excluded folder" : "\(folderName) folder"
            }
            return "Paths containing '\(pattern)'"
        case .regex:
            return "Pattern: \(pattern)"
        case .fileSize:
            let direction = (comparisonGreater ?? true) ? "larger" : "smaller"
            let unit = sizeUnit ?? .megabytes
            let value = (numericValue ?? 0) / unit.megabyteMultiplier
            return "Files \(direction) than \(value.formatted(.number.precision(.fractionLength(0...2)))) \(unit.rawValue)"
        case .creationDate, .modificationDate:
            let direction = (comparisonGreater ?? true) ? "older" : "newer"
            let unit = ageUnit ?? .days
            let seconds = ageIntervalSeconds ?? ((numericValue ?? 0) * ExclusionAgeUnit.days.secondsMultiplier)
            let value = seconds / unit.secondsMultiplier
            return "Files \(direction) than \(value.formatted(.number.precision(.fractionLength(0...2)))) \(unit.rawValue)"
        case .hiddenFiles:
            return "Hidden files"
        case .systemFiles:
            return "System files"
        case .finderTag:
            let colorName = Int(pattern)
                .flatMap(FinderTagColor.init(rawValue:))?.name ?? "selected"
            return "Files and folders with the \(colorName.lowercased()) Finder tag"
        case .fileType:
            return fileTypeCategory?.rawValue ?? "Selected file category"
        case .customScript:
            return "Custom script"
        }
    }

    public var interpretedMatchDescription: String {
        switch type {
        case .fileType: return fileTypeCategory?.rawValue ?? "A file category"
        case .fileSize:
            return "Files \(comparisonGreater == true ? "larger" : "smaller") than \(numericValue?.formatted() ?? "the chosen size") MB"
        case .creationDate, .modificationDate:
            return "Files \(comparisonGreater == true ? "older" : "newer") than \(numericValue?.formatted() ?? "the chosen age") days"
        case .hiddenFiles: return "Hidden files"
        case .systemFiles: return "macOS system files"
        default: return pattern.isEmpty ? type.friendlyName : pattern
        }
    }

    public var aiToolName: String {
        switch type {
        case .fileExtension: "match_file_extension"
        case .fileName: "match_file_name"
        case .folderName: "match_folder_name"
        case .pathContains: pattern.hasPrefix("/") ? "protect_folder" : "match_path"
        case .regex: "match_regular_expression"
        case .fileSize: "compare_file_size"
        case .creationDate: "compare_creation_age"
        case .modificationDate: "compare_modification_age"
        case .hiddenFiles: "match_hidden_files"
        case .systemFiles: "match_macos_files"
        case .finderTag: "match_finder_tag"
        case .fileType: "match_file_category"
        case .customScript: "run_custom_matcher"
        }
    }

    public var aiToolIcon: String {
        switch type {
        case .fileExtension: "doc.badge.gearshape.fill"
        case .fileName: "doc.text.magnifyingglass"
        case .folderName: "folder.badge.minus"
        case .pathContains: pattern.hasPrefix("/") ? "folder.fill.badge.minus" : "point.bottomleft.forward.to.point.topright.scurvepath"
        case .regex: "textformat.alt"
        case .fileSize: "internaldrive.fill"
        case .creationDate: "calendar.badge.minus"
        case .modificationDate: "clock.badge"
        case .hiddenFiles: "eye.slash.fill"
        case .systemFiles: "gearshape.2.fill"
        case .finderTag: "tag.fill"
        case .fileType: "square.grid.2x2.fill"
        case .customScript: "applescript.fill"
        }
    }

    public var aiToolDisplayName: String {
        switch type {
        case .fileExtension: "File extension"
        case .fileName: "File name"
        case .folderName: "Folder name"
        case .pathContains: pattern.hasPrefix("/") ? "Protected folder" : "Path match"
        case .regex: "Name pattern"
        case .fileSize: "File size"
        case .creationDate: "Creation date"
        case .modificationDate: "Modified date"
        case .hiddenFiles: "Hidden files"
        case .systemFiles: "macOS files"
        case .finderTag: "Finder tag"
        case .fileType: "File category"
        case .customScript: "Custom matcher"
        }
    }

    public var promptDescription: String {
        var components = ["tool=\(aiToolName)", "match=\(interpretedMatchDescription)"]
        if caseSensitive { components.append("case-sensitive=true") }
        if negated { components.append("negated=true") }
        if let description, !description.isEmpty { components.append("label=\(description)") }
        return components.joined(separator: "; ")
    }
}

public struct ExclusionRuleUsage: Codable, Equatable, Sendable {
    public var matchCount: Int = 0
    public var lastMatchedAt: Date?
}

private extension String {
    func trimmingLeadingDots() -> String {
        var value = self
        while value.hasPrefix(".") {
            value.removeFirst()
        }
        return value
    }
}

// MARK: - Compiled Matching

/// An immutable, concurrency-safe snapshot of exclusion rules.
///
/// Rules are normalized and regular expressions are compiled once when the
/// snapshot is created. The snapshot can then be shared by manual organization,
/// watched-folder work, and background scanners without main-actor contention.
public struct ExclusionMatcher: Sendable {
    public static let empty = ExclusionMatcher(rules: [])

    private static let systemPatterns = [
        ".DS_Store",
        "Thumbs.db",
        "desktop.ini",
        ".Spotlight-V100",
        ".Trashes",
        ".fseventsd",
        ".TemporaryItems",
    ]

    private let rules: [CompiledExclusionRule]
    private let pathOnlyRules: [CompiledExclusionRule]
    private let metadataRules: [CompiledExclusionRule]
    private let directoryPruningRules: [CompiledExclusionRule]
    private let sourceRules: [ExclusionRule]
    private let referenceDate: Date
    private let hasRelativeDateRules: Bool

    public init(rules: [ExclusionRule], referenceDate: Date = Date()) {
        let compiled = rules.compactMap {
            CompiledExclusionRule(rule: $0, referenceDate: referenceDate)
        }
        self.rules = compiled
        self.pathOnlyRules = compiled
            .filter(\.isPathOnly)
            .sorted { $0.evaluationCost < $1.evaluationCost }
        self.metadataRules = compiled
            .filter { !$0.isPathOnly }
            .sorted { $0.evaluationCost < $1.evaluationCost }
        self.directoryPruningRules = compiled.filter {
            $0.conditionGroupID == nil && $0.canPruneDirectory
        }
        self.sourceRules = rules
        self.referenceDate = referenceDate
        self.hasRelativeDateRules = rules.contains {
            $0.isEnabled && ($0.type == .creationDate || $0.type == .modificationDate)
        }
    }

    public var isEmpty: Bool {
        rules.isEmpty
    }

    public func needsRefresh(
        at date: Date = Date(),
        maximumAge: TimeInterval = 60
    ) -> Bool {
        hasRelativeDateRules
            && date.timeIntervalSince(referenceDate) >= max(0, maximumAge)
    }

    public func refreshed(at date: Date = Date()) -> ExclusionMatcher {
        guard hasRelativeDateRules else { return self }
        return ExclusionMatcher(rules: sourceRules, referenceDate: date)
    }

    public func shouldExclude(_ file: FileItem) -> Bool {
        var cache = ExclusionMatchCache(
            path: file.path,
            name: file.name,
            pathExtension: file.extension,
            size: file.size,
            creationDate: file.creationDate,
            modificationDate: file.modificationDate,
            finderLabelNumber: file.finderLabelNumber
        )
        return matchesAnyRule(cache: &cache)
    }

    /// Fast path for scanners to reject name/path based exclusions before any
    /// resource values, extended attributes, OCR, hashes, or image work.
    public func shouldExcludeUsingPathOnly(at url: URL) -> Bool {
        guard !pathOnlyRules.isEmpty else { return false }
        var cache = ExclusionMatchCache(url: url)
        return matchesAnyRule(in: pathOnlyRules, cache: &cache)
    }

    /// Completes matching once inexpensive filesystem metadata is available.
    public func shouldExcludeFile(
        at url: URL,
        size: Int64,
        creationDate: Date?,
        modificationDate: Date?,
        finderLabelNumber: Int? = nil
    ) -> Bool {
        var cache = ExclusionMatchCache(
            url: url,
            size: size,
            creationDate: creationDate,
            modificationDate: modificationDate,
            finderLabelNumber: finderLabelNumber
        )
        return matchesAnyRule(cache: &cache)
    }

    /// Returns true when an enabled positive rule protects an entire directory tree.
    public func shouldPruneDirectory(
        at url: URL,
        finderLabelNumber: Int? = nil
    ) -> Bool {
        guard !directoryPruningRules.isEmpty else { return false }
        var cache = ExclusionMatchCache(url: url, finderLabelNumber: finderLabelNumber)
        return directoryPruningRules.contains {
            $0.matchesDirectoryForPruning(cache: &cache)
        }
    }

    /// The enabled rule that excludes an entire directory tree, if one applies.
    public func firstBlockingDirectoryRuleID(
        at url: URL,
        finderLabelNumber: Int? = nil
    ) -> UUID? {
        guard !directoryPruningRules.isEmpty else { return nil }
        var cache = ExclusionMatchCache(url: url, finderLabelNumber: finderLabelNumber)
        return directoryPruningRules.first {
            $0.matchesDirectoryForPruning(cache: &cache)
        }?.id
    }

    public func filterFiles(_ files: [FileItem]) -> [FileItem] {
        guard !rules.isEmpty else { return files }

        var included: [FileItem] = []
        included.reserveCapacity(min(files.count, 4_096))
        for file in files where !shouldExclude(file) {
            included.append(file)
        }
        return included
    }

    func shouldExclude(
        path: String,
        name: String,
        pathExtension: String,
        size: Int64 = 0,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        finderLabelNumber: Int? = nil
    ) -> Bool {
        var cache = ExclusionMatchCache(
            path: path,
            name: name,
            pathExtension: pathExtension,
            size: size,
            creationDate: creationDate,
            modificationDate: modificationDate,
            finderLabelNumber: finderLabelNumber
        )
        return matchesAnyRule(cache: &cache)
    }

    func firstMatchingRuleID(for file: FileItem) -> UUID? {
        var cache = ExclusionMatchCache(
            path: file.path,
            name: file.name,
            pathExtension: file.extension,
            size: file.size,
            creationDate: file.creationDate,
            modificationDate: file.modificationDate,
            finderLabelNumber: file.finderLabelNumber
        )
        return matchingRules(cache: &cache).first?.id
    }

    func matchingRuleIDs(for file: FileItem) -> [UUID] {
        var cache = ExclusionMatchCache(
            path: file.path,
            name: file.name,
            pathExtension: file.extension,
            size: file.size,
            creationDate: file.creationDate,
            modificationDate: file.modificationDate,
            finderLabelNumber: file.finderLabelNumber
        )
        return matchingRules(cache: &cache).map(\.id)
    }

    private func matchesAnyRule(cache: inout ExclusionMatchCache) -> Bool {
        matchesAnyRule(in: rules, cache: &cache)
    }

    private func matchesAnyRule(
        in candidates: [CompiledExclusionRule],
        cache: inout ExclusionMatchCache
    ) -> Bool {
        if candidates.contains(where: {
            $0.conditionGroupID == nil && $0.matches(cache: &cache)
        }) {
            return true
        }

        let grouped = Dictionary(grouping: candidates.compactMap { rule in
            rule.conditionGroupID.map { ($0, rule) }
        }, by: \.0)
        return grouped.values.contains { members in
            let groupRules = members.map(\.1)
            guard let groupID = groupRules.first?.conditionGroupID else { return false }
            let completeGroup = rules.filter { $0.conditionGroupID == groupID }
            guard completeGroup.count == groupRules.count else { return false }
            return groupRules.allSatisfy { $0.matches(cache: &cache) }
        }
    }

    private func matchingRules(cache: inout ExclusionMatchCache) -> [CompiledExclusionRule] {
        var matches = rules.filter {
            $0.conditionGroupID == nil && $0.matches(cache: &cache)
        }
        let grouped = Dictionary(grouping: rules.compactMap { rule in
            rule.conditionGroupID.map { ($0, rule) }
        }, by: \.0)
        for members in grouped.values {
            let groupRules = members.map(\.1)
            if groupRules.allSatisfy({ $0.matches(cache: &cache) }) {
                matches.append(contentsOf: groupRules)
            }
        }
        return matches
    }

    fileprivate static func isSystemItem(name: String, path: String) -> Bool {
        systemPatterns.contains { name == $0 || path.contains($0) }
    }
}

private struct ExclusionMatchCache {
    let path: String
    let name: String
    let pathExtension: String
    let size: Int64
    let creationDate: Date?
    let modificationDate: Date?
    let finderLabelNumber: Int?

    private var lowercasedPathStorage: String?
    private var lowercasedNameStorage: String?
    private var normalizedExtensionStorage: String?
    private var fileNameWithExtensionStorage: String?
    private var pathComponentsStorage: [Substring]?
    private var lowercasedPathComponentsStorage: [Substring]?

    init(
        path: String,
        name: String,
        pathExtension: String,
        size: Int64,
        creationDate: Date?,
        modificationDate: Date?,
        finderLabelNumber: Int? = nil
    ) {
        self.path = path
        self.name = name
        self.pathExtension = pathExtension
        self.size = size
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.finderLabelNumber = finderLabelNumber
    }

    init(
        url: URL,
        size: Int64 = 0,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        finderLabelNumber: Int? = nil
    ) {
        self.init(
            path: url.path,
            name: url.deletingPathExtension().lastPathComponent,
            pathExtension: url.pathExtension,
            size: size,
            creationDate: creationDate,
            modificationDate: modificationDate,
            finderLabelNumber: finderLabelNumber
        )
    }

    mutating func lowercasedPath() -> String {
        if let lowercasedPathStorage {
            return lowercasedPathStorage
        }
        let value = path.lowercased()
        lowercasedPathStorage = value
        return value
    }

    mutating func lowercasedName() -> String {
        if let lowercasedNameStorage {
            return lowercasedNameStorage
        }
        let value = name.lowercased()
        lowercasedNameStorage = value
        return value
    }

    mutating func normalizedExtension() -> String {
        if let normalizedExtensionStorage {
            return normalizedExtensionStorage
        }
        let value = pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        normalizedExtensionStorage = value
        return value
    }

    mutating func fileNameWithExtension() -> String {
        if let fileNameWithExtensionStorage {
            return fileNameWithExtensionStorage
        }
        let value = path.split(separator: "/").last.map(String.init) ?? name
        fileNameWithExtensionStorage = value
        return value
    }

    mutating func pathComponents() -> [Substring] {
        if let pathComponentsStorage {
            return pathComponentsStorage
        }
        let value = path.split(separator: "/", omittingEmptySubsequences: false)
        pathComponentsStorage = value
        return value
    }

    mutating func lowercasedPathComponents() -> [Substring] {
        if let lowercasedPathComponentsStorage {
            return lowercasedPathComponentsStorage
        }
        let value = lowercasedPath().split(separator: "/", omittingEmptySubsequences: false)
        lowercasedPathComponentsStorage = value
        return value
    }
}

private struct CompiledExclusionRule: Sendable {
    let id: UUID
    let conditionGroupID: UUID?
    let predicate: CompiledExclusionPredicate
    let negated: Bool

    init?(rule: ExclusionRule, referenceDate: Date) {
        guard rule.isEnabled else { return nil }

        let trimmedPattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let predicate: CompiledExclusionPredicate

        switch rule.type {
        case .fileExtension:
            let pattern = trimmedPattern.trimmingLeadingDots()
            guard !pattern.isEmpty else { return nil }
            predicate = .fileExtension(
                rule.caseSensitive ? pattern : pattern.lowercased(),
                caseSensitive: rule.caseSensitive
            )

        case .fileName:
            guard !trimmedPattern.isEmpty else { return nil }
            predicate = .fileNameContains(
                rule.caseSensitive ? trimmedPattern : trimmedPattern.lowercased(),
                caseSensitive: rule.caseSensitive
            )

        case .folderName:
            guard !trimmedPattern.isEmpty else { return nil }
            predicate = .folderNameContains(
                rule.caseSensitive ? trimmedPattern : trimmedPattern.lowercased(),
                caseSensitive: rule.caseSensitive
            )

        case .pathContains:
            guard !trimmedPattern.isEmpty else { return nil }
            if trimmedPattern.hasPrefix("/") {
                let normalizedPath = URL(fileURLWithPath: trimmedPattern).standardizedFileURL.path
                predicate = .folderTree(
                    rule.caseSensitive ? normalizedPath : normalizedPath.lowercased(),
                    caseSensitive: rule.caseSensitive
                )
            } else {
                predicate = .pathContains(
                    rule.caseSensitive ? trimmedPattern : trimmedPattern.lowercased(),
                    caseSensitive: rule.caseSensitive
                )
            }

        case .regex:
            guard !trimmedPattern.isEmpty else { return nil }
            let options: NSRegularExpression.Options = rule.caseSensitive ? [] : .caseInsensitive
            guard let regex = try? NSRegularExpression(pattern: trimmedPattern, options: options) else {
                return nil
            }
            predicate = .regex(CompiledExclusionRegex(regex))

        case .fileSize:
            guard let limitMB = rule.numericValue,
                  let greater = rule.comparisonGreater else {
                return nil
            }
            predicate = .fileSize(limitMB: limitMB, greater: greater)

        case .creationDate, .modificationDate:
            let interval = rule.ageIntervalSeconds
                ?? ((rule.numericValue ?? 0) * ExclusionAgeUnit.days.secondsMultiplier)
            guard interval.isFinite,
                  interval >= 0,
                  let older = rule.comparisonGreater else {
                return nil
            }
            let threshold = referenceDate.addingTimeInterval(-interval)
            predicate = .date(
                type: rule.type,
                threshold: threshold,
                fallbackDate: referenceDate,
                older: older
            )

        case .hiddenFiles:
            predicate = .hiddenFiles

        case .systemFiles:
            predicate = .systemFiles

        case .finderTag:
            guard let labelNumber = Int(trimmedPattern),
                  FinderTagColor(rawValue: labelNumber) != nil else { return nil }
            predicate = .finderTag(labelNumber)

        case .fileType:
            guard let category = rule.fileTypeCategory else { return nil }
            predicate = .fileType(Set(category.extensions.map { $0.lowercased() }))

        case .customScript:
            predicate = .constant(false)
        }

        self.id = rule.id
        self.conditionGroupID = rule.conditionGroupID
        self.predicate = predicate
        self.negated = rule.negated
    }

    var isPathOnly: Bool {
        predicate.isPathOnly
    }

    var canPruneDirectory: Bool {
        !negated && predicate.canPruneDirectory
    }

    var evaluationCost: Int {
        predicate.evaluationCost
    }

    func matches(cache: inout ExclusionMatchCache) -> Bool {
        let result = predicate.matches(cache: &cache)
        return negated ? !result : result
    }

    func matchesDirectoryForPruning(cache: inout ExclusionMatchCache) -> Bool {
        guard canPruneDirectory else { return false }
        return predicate.matches(cache: &cache)
    }
}

private enum CompiledExclusionPredicate: Sendable {
    case fileExtension(String, caseSensitive: Bool)
    case fileNameContains(String, caseSensitive: Bool)
    case folderNameContains(String, caseSensitive: Bool)
    case pathContains(String, caseSensitive: Bool)
    case folderTree(String, caseSensitive: Bool)
    case regex(CompiledExclusionRegex)
    case fileSize(limitMB: Double, greater: Bool)
    case date(
        type: ExclusionRuleType,
        threshold: Date,
        fallbackDate: Date,
        older: Bool
    )
    case hiddenFiles
    case systemFiles
    case finderTag(Int)
    case fileType(Set<String>)
    case constant(Bool)

    var isPathOnly: Bool {
        switch self {
        case .fileSize, .date, .finderTag:
            return false
        default:
            return true
        }
    }

    var canPruneDirectory: Bool {
        switch self {
        case .folderNameContains, .pathContains, .folderTree, .hiddenFiles, .systemFiles,
             .finderTag:
            return true
        default:
            return false
        }
    }

    var evaluationCost: Int {
        switch self {
        case .fileExtension, .fileType, .constant:
            return 0
        case .fileSize, .date, .hiddenFiles:
            return 1
        case .fileNameContains:
            return 2
        case .systemFiles:
            return 3
        case .finderTag:
            return 2
        case .pathContains, .folderTree:
            return 4
        case .folderNameContains:
            return 5
        case .regex:
            return 6
        }
    }

    func matches(cache: inout ExclusionMatchCache) -> Bool {
        switch self {
        case .fileExtension(let pattern, let caseSensitive):
            if caseSensitive {
                return cache.pathExtension
                    .trimmingCharacters(in: .whitespacesAndNewlines) == pattern
            }
            return cache.normalizedExtension() == pattern

        case .fileNameContains(let pattern, let caseSensitive):
            return caseSensitive
                ? cache.name.contains(pattern)
                : cache.lowercasedName().contains(pattern)

        case .folderNameContains(let pattern, let caseSensitive):
            let components = caseSensitive
                ? cache.pathComponents()
                : cache.lowercasedPathComponents()
            return components.contains { $0 == Substring(pattern) }

        case .pathContains(let pattern, let caseSensitive):
            return caseSensitive
                ? cache.path.contains(pattern)
                : cache.lowercasedPath().contains(pattern)

        case .folderTree(let folderPath, let caseSensitive):
            let path = caseSensitive ? cache.path : cache.lowercasedPath()
            return path == folderPath || path.hasPrefix(folderPath + "/")

        case .regex(let regex):
            return regex.matches(cache.fileNameWithExtension())

        case .fileSize(let limitMB, let greater):
            let sizeMB = Double(cache.size) / (1_024 * 1_024)
            return greater ? sizeMB > limitMB : sizeMB < limitMB

        case .date(let type, let threshold, let fallbackDate, let older):
            let date: Date
            if type == .modificationDate {
                date = cache.modificationDate ?? cache.creationDate ?? fallbackDate
            } else {
                date = cache.creationDate ?? fallbackDate
            }
            return older ? date < threshold : date > threshold

        case .hiddenFiles:
            return cache.name.hasPrefix(".") || cache.path.contains("/.")

        case .systemFiles:
            return ExclusionMatcher.isSystemItem(name: cache.name, path: cache.path)

        case .finderTag(let labelNumber):
            return cache.finderLabelNumber == labelNumber

        case .fileType(let extensions):
            return extensions.contains(cache.normalizedExtension())

        case .constant(let value):
            return value
        }
    }
}

private final class CompiledExclusionRegex: @unchecked Sendable {
    private let expression: NSRegularExpression

    init(_ expression: NSRegularExpression) {
        self.expression = expression
    }

    func matches(_ value: String) -> Bool {
        let range = NSRange(location: 0, length: value.utf16.count)
        return expression.firstMatch(in: value, options: [], range: range) != nil
    }
}

// MARK: - Exclusion Rules Manager

public struct NaturalLanguageException: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var text: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), text: String, isEnabled: Bool = true) {
        self.id = id
        self.text = text
        self.isEnabled = isEnabled
    }

    public var referencedPaths: [String] {
        let pattern = #"(?:\"((?:~/|/)[^\"]+)\"|'((?:~/|/)[^']+)'|((?:~/|/)[^\s,;]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(text.startIndex..., in: text)
        var paths: [String] = []
        for match in expression.matches(in: text, range: range) {
            for captureIndex in 1..<match.numberOfRanges {
                let captureRange = match.range(at: captureIndex)
                guard captureRange.location != NSNotFound,
                      let range = Range(captureRange, in: text)
                else { continue }

                let path = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".!?:)"))
                if !path.isEmpty, !paths.contains(path) {
                    paths.append(path)
                }
                break
            }
        }
        return paths
    }

    var confidentlyStructuredRule: ExclusionRule? {
        if let path = referencedPaths.first {
            let expandedPath = (path as NSString).expandingTildeInPath
            return ExclusionRule(
                type: .pathContains,
                pattern: expandedPath,
                description: URL(fileURLWithPath: expandedPath).lastPathComponent,
                isAIGenerated: true
            )
        }

        let pattern = #"(?i)folders?\s+named\s+(.+?)(?:\s+and\b|[.!]|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }

        let folderName = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folderName.isEmpty else { return nil }
        return ExclusionRule(
            type: .folderName,
            pattern: folderName,
            description: "\(folderName) folders",
            isAIGenerated: true
        )
    }
}

@MainActor
public class ExclusionRulesManager: ObservableObject {
    public static let legacyLearningsLinkedDescription = "Added from Learnings exclusion"

    @Published public private(set) var rules: [ExclusionRule] = []
    @Published public private(set) var naturalLanguageExceptions: [NaturalLanguageException] = []
    @Published public private(set) var compiledMatcher = ExclusionMatcher.empty
    @Published public private(set) var usageByRuleID: [UUID: ExclusionRuleUsage] = [:]
    @Published public private(set) var hasLoadedPersistedState = false

    private let userDefaults: UserDefaults
    private let persistedDataReader: UserDefaultsDataReader
    private let rulesKey = "exclusionRules"
    private let nlExceptionsKey = "naturalLanguageExceptions"
    private let usageKey = "exclusionRuleUsage"
    private var loadTask: Task<PersistedSnapshot, Never>?
    private var loadGeneration = 0
    private var hasPendingChanges = false

    private struct PersistedSnapshot: Sendable {
        var rules: [ExclusionRule] = []
        var naturalLanguageExceptions: [NaturalLanguageException] = []
        var usage: [UUID: ExclusionRuleUsage] = [:]
        var didMigrateLegacyNaturalLanguage = false
    }

    public convenience init() {
        self.init(userDefaults: .standard)
    }

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        self.persistedDataReader = UserDefaultsDataReader(userDefaults)
        setupNotificationObservers()
    }

    /// Decodes rules away from the main actor. In-memory additions are merged before saving.
    public func loadPersistedState() async {
        guard !hasLoadedPersistedState else { return }

        let generation = loadGeneration
        let task: Task<PersistedSnapshot, Never>
        if let loadTask {
            task = loadTask
        } else {
            let persistedDataReader = persistedDataReader
            let rulesKey = rulesKey
            let nlExceptionsKey = nlExceptionsKey
            let usageKey = usageKey
            task = Task.detached(priority: .userInitiated) {
                var snapshot = PersistedSnapshot()
                if let data = persistedDataReader.data(forKey: rulesKey),
                   let decoded = try? JSONDecoder().decode([ExclusionRule].self, from: data) {
                    snapshot.rules = decoded
                }
                if let data = persistedDataReader.data(forKey: usageKey),
                   let decoded = try? JSONDecoder().decode([UUID: ExclusionRuleUsage].self, from: data) {
                    snapshot.usage = decoded
                }
                if let data = persistedDataReader.data(forKey: nlExceptionsKey),
                   let decoded = try? JSONDecoder().decode([NaturalLanguageException].self, from: data) {
                    snapshot.naturalLanguageExceptions = decoded
                } else if let legacyExceptions = persistedDataReader.stringArray(forKey: nlExceptionsKey) {
                    snapshot.naturalLanguageExceptions = legacyExceptions.compactMap {
                        let text = Self.sanitizedExceptionText($0)
                        return text.isEmpty ? nil : NaturalLanguageException(text: text)
                    }
                    snapshot.didMigrateLegacyNaturalLanguage = true
                }
                return snapshot
            }
            loadTask = task
        }

        let snapshot = await task.value
        guard !hasLoadedPersistedState, generation == loadGeneration else { return }

        let inMemoryByID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        let persistedIDs = Set(snapshot.rules.map(\.id))
        var mergedRules = snapshot.rules.map { inMemoryByID[$0.id] ?? $0 }
        mergedRules.append(contentsOf: rules.filter { !persistedIDs.contains($0.id) })

        let persistedNLIDs = Set(snapshot.naturalLanguageExceptions.map(\.id))
        var mergedNL = snapshot.naturalLanguageExceptions
        mergedNL.append(contentsOf: naturalLanguageExceptions.filter { !persistedNLIDs.contains($0.id) })

        var mergedUsage = snapshot.usage
        for (id, usage) in usageByRuleID {
            mergedUsage[id] = usage
        }

        rules = mergedRules
        naturalLanguageExceptions = mergedNL
        usageByRuleID = mergedUsage
        if snapshot.didMigrateLegacyNaturalLanguage {
            hasPendingChanges = true
        }

        removeLegacyLearningsLinkedRules()
        if rules.isEmpty {
            setupDefaultRules()
        }
        migrateConfidentNaturalLanguageExceptions()

        let firstMatcherRules = rules
        var matcher = await Task.detached(priority: .utility) {
            ExclusionMatcher(rules: firstMatcherRules)
        }.value
        if firstMatcherRules != rules {
            let latestMatcherRules = rules
            matcher = await Task.detached(priority: .utility) {
                ExclusionMatcher(rules: latestMatcherRules)
            }.value
        }
        compiledMatcher = matcher

        hasLoadedPersistedState = true
        loadTask = nil

        if hasPendingChanges {
            hasPendingChanges = false
            saveRules()
            saveUsage()
            saveNaturalLanguageExceptions()
        }
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addMainActorObserver(forName: .clearAllUsageData, object: nil, queue: .main) { [weak self] in
            self?.clearEverything()
        }
    }

    // MARK: - Rule Management

    public func addRule(_ rule: ExclusionRule) {
        var labeledRule = rule
        let suppliedLabel = labeledRule.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let suppliedLabel, !suppliedLabel.isEmpty {
            labeledRule.description = suppliedLabel
        } else {
            labeledRule.description = nil
            labeledRule.description = labeledRule.displayDescription
        }
        rules.append(labeledRule)
        saveRules()
    }

    public func clearEverything() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        hasLoadedPersistedState = true
        hasPendingChanges = false
        rules.removeAll()
        naturalLanguageExceptions.removeAll()
        usageByRuleID.removeAll()
        userDefaults.removeObject(forKey: rulesKey)
        userDefaults.removeObject(forKey: nlExceptionsKey)
        userDefaults.removeObject(forKey: usageKey)
        setupDefaultRules()
    }

    public func removeRule(_ rule: ExclusionRule) {
        rules.removeAll { $0.id == rule.id }
        usageByRuleID.removeValue(forKey: rule.id)
        saveRules()
        saveUsage()
    }

    public func removeLegacyLearningsLinkedRules() {
        removeRules { isLegacyLearningsLinkedRule($0) }
    }

    public func removeLegacyLearningsLinkedRules(matchingLearningPattern pattern: String) {
        let normalizedPattern = normalizedLearningsLinkedPattern(pattern)
        removeRules { rule in
            isLegacyLearningsLinkedRule(rule) &&
            normalizedLearningsLinkedPattern(rule.pattern) == normalizedPattern
        }
    }

    public func updateRule(_ rule: ExclusionRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
            saveRules()
        }
    }

    public func toggleRule(_ rule: ExclusionRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index].isEnabled.toggle()
            saveRules()
        }
    }

    public func clearAllRules() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        hasLoadedPersistedState = true
        hasPendingChanges = false
        rules.removeAll()
        usageByRuleID.removeAll()
        saveRules()
        saveUsage()
    }

    // MARK: - Matching

    public func shouldExclude(_ file: FileItem) -> Bool {
        matcherSnapshot().shouldExclude(file)
    }

    public func filterFiles(_ files: [FileItem]) -> [FileItem] {
        let matcher = matcherSnapshot()
        var included: [FileItem] = []
        included.reserveCapacity(min(files.count, 4_096))
        var matchCounts: [UUID: Int] = [:]

        for file in files {
            if let ruleID = matcher.firstMatchingRuleID(for: file) {
                matchCounts[ruleID, default: 0] += 1
            } else {
                included.append(file)
            }
        }

        if !matchCounts.isEmpty {
            let matchedAt = Date()
            for (ruleID, count) in matchCounts {
                var usage = usageByRuleID[ruleID] ?? ExclusionRuleUsage()
                usage.matchCount += count
                usage.lastMatchedAt = matchedAt
                usageByRuleID[ruleID] = usage
            }
            saveUsage()
        }
        return included
    }

    public func firstMatchingRule(for file: FileItem) -> ExclusionRule? {
        guard let matchingID = matcherSnapshot().firstMatchingRuleID(for: file) else {
            return nil
        }
        return rules.first { $0.id == matchingID }
    }

    public func matcherSnapshot() -> ExclusionMatcher {
        if compiledMatcher.needsRefresh() {
            compiledMatcher = compiledMatcher.refreshed()
        }
        return compiledMatcher
    }

    /// Returns the exact enabled rule that prevents Sorty from entering this folder.
    public func blockingRule(forDirectoryAt url: URL) -> ExclusionRule? {
        let finderLabelNumber = try? url.resourceValues(forKeys: [.labelNumberKey]).labelNumber
        guard let ruleID = matcherSnapshot().firstBlockingDirectoryRuleID(
            at: url,
            finderLabelNumber: finderLabelNumber
        ) else {
            return nil
        }
        return rules.first { $0.id == ruleID }
    }

    // MARK: - Statistics

    public var enabledRulesCount: Int {
        rules.filter { $0.isEnabled }.count
    }

    // MARK: - Natural Language Exceptions

    public func addNaturalLanguageException(_ text: String) {
        let sanitized = sanitizeException(text)
        guard !sanitized.isEmpty else { return }
        naturalLanguageExceptions.append(NaturalLanguageException(text: sanitized))
        saveNaturalLanguageExceptions()
    }

    public func updateNaturalLanguageException(_ exception: NaturalLanguageException) {
        guard let index = naturalLanguageExceptions.firstIndex(where: { $0.id == exception.id }) else {
            return
        }
        naturalLanguageExceptions[index] = exception
        saveNaturalLanguageExceptions()
    }

    public func removeNaturalLanguageException(id: UUID) {
        naturalLanguageExceptions.removeAll { $0.id == id }
        saveNaturalLanguageExceptions()
    }

    /// Returns sanitized exceptions formatted for injection into AI prompts
    public var sanitizedExceptionsForPrompt: [String] {
        naturalLanguageExceptions
            .filter(\.isEnabled)
            .map { sanitizeException($0.text) }
            .filter { !$0.isEmpty }
    }

    /// Sanitizes user input to prevent prompt injection
    private func sanitizeException(_ text: String) -> String {
        Self.sanitizedExceptionText(text)
    }

    private nonisolated static func sanitizedExceptionText(_ text: String) -> String {
        var sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Truncate to reasonable length
        if sanitized.count > 200 {
            sanitized = String(sanitized.prefix(200))
        }

        // Remove patterns that could be prompt injection
        let injectionPatterns = [
            "ignore previous", "ignore above", "disregard", "forget",
            "system:", "assistant:", "user:", "```",
            "override", "new instructions", "instead of"
        ]
        let lowered = sanitized.lowercased()
        for pattern in injectionPatterns {
            if lowered.contains(pattern) {
                sanitized = sanitized.replacingOccurrences(
                    of: pattern,
                    with: "",
                    options: .caseInsensitive
                )
            }
        }

        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveNaturalLanguageExceptions() {
        guard hasLoadedPersistedState else {
            hasPendingChanges = true
            return
        }
        guard let data = try? JSONEncoder().encode(naturalLanguageExceptions) else { return }
        userDefaults.set(data, forKey: nlExceptionsKey)
    }

    private func saveUsage() {
        guard hasLoadedPersistedState else {
            hasPendingChanges = true
            return
        }
        guard let data = try? JSONEncoder().encode(usageByRuleID) else { return }
        userDefaults.set(data, forKey: usageKey)
    }

    private func migrateConfidentNaturalLanguageExceptions() {
        var migratedIDs: Set<UUID> = []
        for exception in naturalLanguageExceptions {
            guard let rule = exception.confidentlyStructuredRule else { continue }
            let isDuplicate = rules.contains {
                $0.type == rule.type
                    && $0.pattern.caseInsensitiveCompare(rule.pattern) == .orderedSame
            }
            if !isDuplicate {
                rules.append(rule)
            }
            migratedIDs.insert(exception.id)
        }

        guard !migratedIDs.isEmpty else { return }
        naturalLanguageExceptions.removeAll { migratedIDs.contains($0.id) }
        saveRules()
        saveNaturalLanguageExceptions()
    }

    // MARK: - Persistence

    private func setupDefaultRules() {
        rules = [
            ExclusionRule(type: .folderName, pattern: "node_modules", description: "Node.js modules", isBuiltIn: true),
            ExclusionRule(type: .folderName, pattern: ".git", description: "Git repositories", isBuiltIn: true),
            ExclusionRule(type: .folderName, pattern: ".svn", description: "SVN repositories", isBuiltIn: true),
            ExclusionRule(type: .folderName, pattern: ".hg", description: "Mercurial repositories", isBuiltIn: true),
            ExclusionRule(type: .folderName, pattern: "build", description: "Build folders", isBuiltIn: true),
            ExclusionRule(type: .folderName, pattern: "dist", description: "Distribution folders", isBuiltIn: true),
            ExclusionRule(type: .folderName, pattern: "DerivedData", description: "Xcode derived data", isBuiltIn: true),
            ExclusionRule(type: .folderName, pattern: "__pycache__", description: "Python cache", isBuiltIn: true),
            ExclusionRule(type: .folderName, pattern: ".venv", description: "Python virtual environments", isBuiltIn: true),
            ExclusionRule(type: .folderName, pattern: "Pods", description: "CocoaPods", isBuiltIn: true),
            ExclusionRule(type: .folderName, pattern: "Carthage", description: "Carthage dependencies", isBuiltIn: true),
            ExclusionRule(type: .fileExtension, pattern: "o", description: "Object files", isBuiltIn: true),
            ExclusionRule(type: .fileExtension, pattern: "pyc", description: "Python bytecode", isBuiltIn: true),
        ]
        saveRules()
    }

    private func saveRules() {
        guard hasLoadedPersistedState else {
            hasPendingChanges = true
            return
        }
        rebuildMatcher()
        if let encoded = try? JSONEncoder().encode(rules) {
            userDefaults.set(encoded, forKey: rulesKey)
        }
    }

    private func removeRules(where shouldRemove: (ExclusionRule) -> Bool) {
        let originalCount = rules.count
        rules.removeAll(where: shouldRemove)
        if rules.count != originalCount {
            saveRules()
        }
    }

    private func isLegacyLearningsLinkedRule(_ rule: ExclusionRule) -> Bool {
        rule.type == .folderName &&
        rule.description == Self.legacyLearningsLinkedDescription
    }

    private func normalizedLearningsLinkedPattern(_ pattern: String) -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()
    }

    private func rebuildMatcher() {
        compiledMatcher = ExclusionMatcher(rules: rules)
    }
}
