//
//  DuplicateSettings.swift
//  Sorty
//
//  Settings model for duplicate detection configuration
//

import Foundation
import Combine

/// Settings for duplicate detection behavior
public struct DuplicateSettings: Codable, Sendable {
    public static let minSemanticSimilarityThreshold: Double = 0.70
    public static let maxSemanticSimilarityThreshold: Double = 1.00
    public static let defaultSemanticSimilarityThreshold: Double = 0.90

    /// Method used to determine if files are duplicates
    public var comparisonMethod: ComparisonMethod

    /// Minimum file size to include in scan (bytes)
    public var minFileSize: Int64
    
    /// Maximum scan depth (-1 for unlimited)
    public var maxScanDepth: Int
    
    /// File extensions to include (empty = all)
    public var includeExtensions: [String]
    
    /// File extensions to exclude
    public var excludeExtensions: [String]
    
    /// Default keep strategy when bulk deleting
    public var defaultKeepStrategy: KeepStrategy

    /// Auto-start scan when opening duplicates view
    public var autoStartScan: Bool
    
    /// Show semantic/similar duplicates (not just exact matches)
    public var includeSemanticDuplicates: Bool
    
    /// Similarity threshold for semantic duplicates (0.70 - 1.00)
    public var semanticSimilarityThreshold: Double

    public static func clampedSemanticSimilarityThreshold(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSemanticSimilarityThreshold }
        return min(max(value, minSemanticSimilarityThreshold), maxSemanticSimilarityThreshold)
    }

    public var normalizedSemanticSimilarityThreshold: Double {
        Self.clampedSemanticSimilarityThreshold(semanticSimilarityThreshold)
    }

    public init(
        comparisonMethod: ComparisonMethod = .exact,
        minFileSize: Int64 = 0,
        maxScanDepth: Int = -1,
        includeExtensions: [String] = [],
        excludeExtensions: [String] = [".DS_Store", ".localized"],
        defaultKeepStrategy: KeepStrategy = .newest,
        autoStartScan: Bool = true,
        includeSemanticDuplicates: Bool = true,
        semanticSimilarityThreshold: Double = DuplicateSettings.defaultSemanticSimilarityThreshold
    ) {
        self.comparisonMethod = comparisonMethod
        self.minFileSize = minFileSize
        self.maxScanDepth = maxScanDepth
        self.includeExtensions = includeExtensions
        self.excludeExtensions = excludeExtensions
        self.defaultKeepStrategy = defaultKeepStrategy
        self.autoStartScan = autoStartScan
        self.includeSemanticDuplicates = includeSemanticDuplicates
        self.semanticSimilarityThreshold = Self.clampedSemanticSimilarityThreshold(semanticSimilarityThreshold)
    }
}

struct DuplicateScanFilter: Sendable {
    private let minimumFileSize: Int64
    private let includedExtensions: Set<String>
    private let excludedValues: Set<String>

    init(settings: DuplicateSettings) {
        minimumFileSize = settings.minFileSize
        includedExtensions = Set(settings.includeExtensions.map(Self.normalizedExtension))
        excludedValues = Set(settings.excludeExtensions.map { $0.lowercased() })
    }

    func includes(
        fileSize: Int64,
        pathExtension: String,
        displayName: String
    ) -> Bool {
        guard fileSize >= minimumFileSize else {
            return false
        }

        let normalizedExtension = Self.normalizedExtension(pathExtension)
        if !includedExtensions.isEmpty, !includedExtensions.contains(normalizedExtension) {
            return false
        }

        let normalizedDisplayName = displayName.lowercased()
        return !excludedValues.contains(normalizedDisplayName)
            && !excludedValues.contains(normalizedExtension)
            && !excludedValues.contains(".\(normalizedExtension)")
    }

    private static func normalizedExtension(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }
}

public enum ComparisonMethod: String, Codable, CaseIterable, Sendable {
    case exact = "exact"       // Content hash (SHA-256)
    case fast = "fast"         // Name + Size
    case metadata = "metadata" // Name + Size + Modified Date
    
    public var displayName: String {
        switch self {
        case .exact: return "Content Match"
        case .fast: return "Fast Match"
        case .metadata: return "Metadata Match"
        }
    }
    
    public var description: String {
        switch self {
        case .exact: return "Identifies files with identical content using SHA-256 hashing. Very reliable but slower."
        case .fast: return "Matches files with the same name and size. Much faster for large directories."
        case .metadata: return "Matches name, size, and modification date. Good balance of speed and reliability."
        }
    }
}

public enum KeepStrategy: String, Codable, CaseIterable, Sendable {
    case newest = "newest"
    case oldest = "oldest"
    case largest = "largest"
    case smallest = "smallest"
    case shortestPath = "shortestPath"
    
    public var displayName: String {
        switch self {
        case .newest: return "Keep Newest"
        case .oldest: return "Keep Oldest"
        case .largest: return "Keep Largest"
        case .smallest: return "Keep Smallest"
        case .shortestPath: return "Keep Shortest Path"
        }
    }
    
    public var description: String {
        switch self {
        case .newest: return "Keep the most recently modified file"
        case .oldest: return "Keep the oldest file"
        case .largest: return "Keep the largest file (may have better quality)"
        case .smallest: return "Keep the smallest file"
        case .shortestPath: return "Keep the file with the shortest path"
        }
    }
}

extension KeepStrategy {
    /// Strategies that produce a meaningful choice for byte-identical files.
    /// Size-based strategies remain decodable for existing preferences, but
    /// identical files are necessarily the same size.
    public static let usefulCleanupCases: [KeepStrategy] = [
        .newest,
        .oldest,
        .shortestPath,
    ]
}

public enum SimilarFileMatchRange: String, CaseIterable, Sendable {
    case closest
    case balanced
    case broader

    public var displayName: String {
        switch self {
        case .closest: return "Only very close matches"
        case .balanced: return "Balanced"
        case .broader: return "Include more variations"
        }
    }

    public var threshold: Double {
        switch self {
        case .closest: return 0.95
        case .balanced: return DuplicateSettings.defaultSemanticSimilarityThreshold
        case .broader: return 0.80
        }
    }
}

enum CleanupPreferenceResolver {
    static func preferredFileID(in files: [FileItem], strategy: KeepStrategy) -> UUID? {
        switch strategy {
        case .newest:
            return files.max { comparableDate(for: $0) < comparableDate(for: $1) }?.id
        case .oldest:
            return files.min { comparableDate(for: $0) < comparableDate(for: $1) }?.id
        case .largest:
            return files.max { $0.size < $1.size }?.id
        case .smallest:
            return files.min { $0.size < $1.size }?.id
        case .shortestPath:
            return files.min { $0.path.count < $1.path.count }?.id
        }
    }

    private static func comparableDate(for file: FileItem) -> Date {
        file.modificationDate ?? file.creationDate ?? .distantPast
    }
}

/// Manager for duplicate settings persistence
@MainActor
public class DuplicateSettingsManager: ObservableObject {
    @Published public var settings: DuplicateSettings
    
    private let userDefaults = UserDefaults.standard
    private let storageKey = "duplicateSettings"

    private enum OverrideKey {
        static let comparisonMethod = "duplicates.comparisonMethod"
        static let minimumFileSizeMB = "duplicates.minimumFileSizeMB"
        static let maximumScanDepth = "duplicates.maximumScanDepth"
        static let includeExtensions = "duplicates.includeExtensions"
        static let excludeExtensions = "duplicates.excludeExtensions"
        static let autoStartScan = "duplicates.autoStartScan"
        static let semanticMatching = "duplicates.semanticMatching"
        static let semanticThreshold = "duplicates.semanticThreshold"
    }
    
    public init() {
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(DuplicateSettings.self, from: data) {
            self.settings = Self.normalize(Self.applyingOverrides(to: decoded, defaults: userDefaults))
        } else {
            self.settings = Self.normalize(Self.applyingOverrides(to: DuplicateSettings(), defaults: userDefaults))
        }
        setupNotificationObservers()
    }
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addMainActorObserver(forName: .clearAllUsageData, object: nil, queue: .main) { [weak self] in
            self?.reset()
        }
    }
    
    public func save() {
        settings = Self.normalize(settings)
        if let encoded = try? JSONEncoder().encode(settings) {
            userDefaults.set(encoded, forKey: storageKey)
        }
    }
    
    public func reset() {
        Self.allOverrideKeys.forEach(userDefaults.removeObject(forKey:))
        settings = DuplicateSettings()
        save()
    }

    private static func normalize(_ settings: DuplicateSettings) -> DuplicateSettings {
        var normalized = settings
        normalized.semanticSimilarityThreshold = settings.normalizedSemanticSimilarityThreshold
        if !KeepStrategy.usefulCleanupCases.contains(settings.defaultKeepStrategy) {
            normalized.defaultKeepStrategy = .newest
        }
        return normalized
    }

    private static func applyingOverrides(to settings: DuplicateSettings, defaults: UserDefaults) -> DuplicateSettings {
        var overridden = settings

        if let rawMethod = defaults.string(forKey: OverrideKey.comparisonMethod),
           let method = ComparisonMethod(rawValue: rawMethod) {
            overridden.comparisonMethod = method
        }
        if defaults.object(forKey: OverrideKey.minimumFileSizeMB) != nil {
            overridden.minFileSize = Self.minimumFileSizeBytes(
                megabytes: defaults.double(forKey: OverrideKey.minimumFileSizeMB)
            )
        }
        if defaults.object(forKey: OverrideKey.maximumScanDepth) != nil {
            overridden.maxScanDepth = defaults.integer(forKey: OverrideKey.maximumScanDepth)
        }
        if let extensions = defaults.string(forKey: OverrideKey.includeExtensions) {
            overridden.includeExtensions = parsedExtensions(extensions)
        }
        if let extensions = defaults.string(forKey: OverrideKey.excludeExtensions) {
            overridden.excludeExtensions = parsedExtensions(extensions)
        }
        if defaults.object(forKey: OverrideKey.autoStartScan) != nil {
            overridden.autoStartScan = defaults.bool(forKey: OverrideKey.autoStartScan)
        }
        if defaults.object(forKey: OverrideKey.semanticMatching) != nil {
            overridden.includeSemanticDuplicates = defaults.bool(forKey: OverrideKey.semanticMatching)
        }
        if defaults.object(forKey: OverrideKey.semanticThreshold) != nil {
            overridden.semanticSimilarityThreshold = defaults.double(forKey: OverrideKey.semanticThreshold)
        }

        return overridden
    }

    private static func parsedExtensions(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Converts the UserDefaults megabyte override to bytes. `double(forKey:)`
    /// can return `inf`/`nan` or huge values for a hand-edited preference, and
    /// `Int64(_:)` traps on anything outside its range, so the value is
    /// finiteness-checked and clamped before conversion.
    private static func minimumFileSizeBytes(megabytes: Double) -> Int64 {
        guard megabytes.isFinite else { return 0 }
        let clampedMegabytes = min(max(megabytes, 0), maximumMinimumFileSizeMB)
        return Int64(clampedMegabytes * 1_048_576)
    }

    /// Upper bound for the minimum-file-size override (1 TB in MB). Larger
    /// thresholds are meaningless for duplicate scanning.
    private static let maximumMinimumFileSizeMB: Double = 1_048_576

    private static var allOverrideKeys: [String] {
        [
            OverrideKey.comparisonMethod,
            OverrideKey.minimumFileSizeMB,
            OverrideKey.maximumScanDepth,
            OverrideKey.includeExtensions,
            OverrideKey.excludeExtensions,
            OverrideKey.autoStartScan,
            OverrideKey.semanticMatching,
            OverrideKey.semanticThreshold
        ]
    }
}
