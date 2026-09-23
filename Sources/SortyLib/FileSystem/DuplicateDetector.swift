//
//  DuplicateDetector.swift
//  Sorty
//
//  Detects duplicate files using SHA-256 hashing
//

import Foundation
import CryptoKit
import Combine

/// Group of files with identical content
public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let hash: String
    public let files: [FileItem]
    public let totalSize: Int64
    public let potentialSavings: Int64 // Size that could be recovered by deleting duplicates
    
    public init(hash: String, files: [FileItem]) {
        self.id = UUID()
        self.hash = hash
        self.files = files
        self.totalSize = files.reduce(0) { $0 + $1.size }
        // Savings = total - one copy
        self.potentialSavings = files.dropFirst().reduce(0) { $0 + $1.size }
    }
    
    public var duplicateCount: Int {
        max(0, files.count - 1)
    }
}

/// Unified wrapper for both exact and semantic duplicate groups
public enum UnifiedDuplicateGroup: Identifiable, Hashable {
    case exact(DuplicateGroup)
    case semantic(SemanticDuplicateGroup)
    
    public var id: UUID {
        switch self {
        case .exact(let group): return group.id
        case .semantic(let group): return group.id
        }
    }
    
    public var files: [FileItem] {
        switch self {
        case .exact(let group): return group.files
        case .semantic(let group): return group.files
        }
    }
    
    public var potentialSavings: Int64 {
        switch self {
        case .exact(let group): return group.potentialSavings
        case .semantic(let group): return group.potentialSavings
        }
    }
    
    public var isExact: Bool {
        if case .exact = self { return true }
        return false
    }
    
    public var isSemantic: Bool {
        if case .semantic = self { return true }
        return false
    }
    
    public var displayName: String {
        files.first?.displayName ?? "Unknown File"
    }
    
    public var groupTypeLabel: String {
        switch self {
        case .exact:
            return "Exact Match"
        case .semantic(let group):
            return group.groupType.rawValue
        }
    }
    
    public var similarityPercentage: String? {
        switch self {
        case .exact:
            return "100%"
        case .semantic(let group):
            return group.similarityPercentage
        }
    }
    
    public var similarity: Double {
        switch self {
        case .exact:
            return 1.0
        case .semantic(let group):
            return group.similarity
        }
    }
    
    public var recommendation: SemanticDuplicateGroup.DuplicateRecommendation? {
        switch self {
        case .exact:
            return nil
        case .semantic(let group):
            return group.recommendation
        }
    }
    
    public var recommendedFileId: UUID? {
        switch self {
        case .exact(let group):
            // For exact matches, recommend keeping the oldest (original)
            return group.files.min(by: { ($0.creationDate ?? .distantFuture) < ($1.creationDate ?? .distantFuture) })?.id
        case .semantic(let group):
            switch group.recommendation {
            case .keepHighestResolution(let id), .keepNewest(let id), .keepOldest(let id), .keepLargest(let id), .archiveOlderVersions(let id, _):
                return id
            case .manualReview:
                return nil
            }
        }
    }
    
    /// Confidence level for safe bulk actions
    public var confidenceLevel: ConfidenceLevel {
        switch self {
        case .exact:
            return .high
        case .semantic(let group):
            if group.similarity >= 0.98 {
                return .high
            } else if group.similarity >= 0.90 {
                return .medium
            } else {
                return .low
            }
        }
    }
    
    public enum ConfidenceLevel: String {
        case high = "Safe to Merge"
        case medium = "Review Suggested"
        case low = "Manual Review"
    }
    
    // Hashable conformance
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public static func == (lhs: UnifiedDuplicateGroup, rhs: UnifiedDuplicateGroup) -> Bool {
        lhs.id == rhs.id
    }
}

/// Actor for detecting duplicate files based on content hash
public actor DuplicateDetector {
    private struct HashCacheKey: Hashable {
        let path: String
        let size: Int64
        let modificationDate: Date?
    }

    private struct IndexBucket {
        let firstIndex: Int
        private(set) var duplicateIndices: [Int]?

        init(firstIndex: Int) {
            self.firstIndex = firstIndex
            duplicateIndices = nil
        }

        mutating func append(_ index: Int) {
            if duplicateIndices == nil {
                duplicateIndices = [firstIndex, index]
            } else {
                duplicateIndices?.append(index)
            }
        }

        var count: Int {
            duplicateIndices?.count ?? 1
        }
    }

    public struct ExactScanResult: Sendable {
        public let groups: [DuplicateGroup]
        public let candidateCount: Int
        public let sampledCount: Int
        public let hashedCount: Int
        public let cacheHitCount: Int
        let unavailableFiles: [UnavailableDuplicateFile]
    }

    private var hashCache: [HashCacheKey: String] = [:]
    private let maximumConcurrentHashers = 2
    private let maximumCachedHashes = 50_000
    private let cacheTrimCount = 5_000
    
    public init() {}

    /// Finds byte-identical files while avoiding unnecessary disk reads.
    /// Only files sharing the same size can be exact duplicates, so unique-size
    /// files are discarded before hashing. Large files are sampled at both ends
    /// before a full SHA-256 pass, which avoids reading entire files that differ
    /// immediately while preserving exact-match correctness.
    public func findExactDuplicates(
        in files: [FileItem],
        progressHandler: (@MainActor @Sendable (Int, Int) -> Void)? = nil
    ) async -> ExactScanResult {
        var firstIndexBySize: [Int64: Int] = [:]
        var duplicateIndicesBySize: [Int64: [Int]] = [:]

        for (index, file) in files.enumerated() where !file.isDirectory {
            if duplicateIndicesBySize[file.size] != nil {
                duplicateIndicesBySize[file.size, default: []].append(index)
            } else if let firstIndex = firstIndexBySize.removeValue(forKey: file.size) {
                duplicateIndicesBySize[file.size] = [firstIndex, index]
            } else {
                firstIndexBySize[file.size] = index
            }
        }

        let candidateCount = duplicateIndicesBySize.values.reduce(0) { $0 + $1.count }

        guard candidateCount > 0 else {
            return ExactScanResult(
                groups: [],
                candidateCount: 0,
                sampledCount: 0,
                hashedCount: 0,
                cacheHitCount: 0,
                unavailableFiles: []
            )
        }

        var candidateIndices: [Int] = []
        candidateIndices.reserveCapacity(candidateCount)
        for indices in duplicateIndicesBySize.values {
            candidateIndices.append(contentsOf: indices)
        }

        var indicesByHash: [String: IndexBucket] = [:]
        var pendingSampleIndices: [Int] = []
        pendingSampleIndices.reserveCapacity(candidateCount)
        var completedCount = 0
        var cacheHitCount = 0
        var sampledCount = 0
        var hashedCount = 0
        var unavailableFiles: [UnavailableDuplicateFile] = []
        let progressStride = max(1, min(1_024, candidateCount / 200))

        for index in candidateIndices {
            if Task.isCancelled {
                break
            }

            let file = files[index]
            if let existingHash = file.sha256Hash {
                Self.record(index: index, for: existingHash, in: &indicesByHash)
                completedCount += 1
                if completedCount.isMultiple(of: progressStride) || completedCount == candidateCount {
                    await progressHandler?(completedCount, candidateCount)
                }
                continue
            }

            let key = Self.cacheKey(for: file)
            if let cachedHash = hashCache[key] {
                Self.record(index: index, for: cachedHash, in: &indicesByHash)
                cacheHitCount += 1
                completedCount += 1
                if completedCount.isMultiple(of: progressStride) || completedCount == candidateCount {
                    await progressHandler?(completedCount, candidateCount)
                }
            } else {
                pendingSampleIndices.append(index)
            }
        }

        var sampledIndicesByDigest: [String: IndexBucket] = [:]
        let sampleConcurrencyLimit = min(maximumConcurrentHashers, pendingSampleIndices.count)
        var nextSampleIndex = 0

        await withTaskGroup(of: (Int, HashUtility.ReadResult<HashUtility.SampleFingerprint>).self) { group in
            for _ in 0..<sampleConcurrencyLimit {
                let index = pendingSampleIndices[nextSampleIndex]
                nextSampleIndex += 1
                group.addTask(priority: .utility) {
                    let result = HashUtility.computeSampleFingerprintResult(
                        for: URL(fileURLWithPath: files[index].path)
                    )
                    return (index, result)
                }
            }

            while let (index, result) = await group.next() {
                if case .success(let fingerprint) = result, fingerprint.isFullFileHash {
                    let key = Self.cacheKey(for: files[index])
                    storeCachedHash(fingerprint.digest, for: key)
                    Self.record(
                        index: index,
                        for: fingerprint.digest,
                        in: &indicesByHash
                    )
                    hashedCount += 1
                    completedCount += 1
                } else if case .success(let fingerprint) = result {
                    Self.record(
                        index: index,
                        for: fingerprint.digest,
                        in: &sampledIndicesByDigest
                    )
                    sampledCount += 1
                } else if case .failure(let failure) = result {
                    let fileURL = URL(fileURLWithPath: files[index].path)
                    unavailableFiles.append(
                        UnavailableDuplicateFile(
                            path: files[index].path,
                            reason: .contents(failure: failure, at: fileURL)
                        )
                    )
                    completedCount += 1
                }

                if completedCount.isMultiple(of: progressStride) || completedCount == candidateCount {
                    await progressHandler?(completedCount, candidateCount)
                }

                if nextSampleIndex < pendingSampleIndices.count, !Task.isCancelled {
                    let nextIndex = pendingSampleIndices[nextSampleIndex]
                    nextSampleIndex += 1
                    group.addTask(priority: .utility) {
                        let result = HashUtility.computeSampleFingerprintResult(
                            for: URL(fileURLWithPath: files[nextIndex].path)
                        )
                        return (nextIndex, result)
                    }
                } else if Task.isCancelled {
                    group.cancelAll()
                }
            }
        }

        var pendingFullHashIndices: [Int] = []
        for bucket in sampledIndicesByDigest.values {
            if let duplicateIndices = bucket.duplicateIndices {
                pendingFullHashIndices.append(contentsOf: duplicateIndices)
            } else {
                completedCount += bucket.count
                if completedCount.isMultiple(of: progressStride) || completedCount == candidateCount {
                    await progressHandler?(completedCount, candidateCount)
                }
            }
        }

        let fullHashConcurrencyLimit = min(maximumConcurrentHashers, pendingFullHashIndices.count)
        var nextFullHashIndex = 0

        await withTaskGroup(of: (Int, HashUtility.ReadResult<String>).self) { group in
            for _ in 0..<fullHashConcurrencyLimit {
                let index = pendingFullHashIndices[nextFullHashIndex]
                nextFullHashIndex += 1
                group.addTask(priority: .utility) {
                    let result = HashUtility.computeSHA256Result(
                        for: URL(fileURLWithPath: files[index].path)
                    )
                    return (index, result)
                }
            }

            while let (index, result) = await group.next() {
                if case .success(let hash) = result {
                    let key = Self.cacheKey(for: files[index])
                    storeCachedHash(hash, for: key)
                    Self.record(index: index, for: hash, in: &indicesByHash)
                    hashedCount += 1
                } else if case .failure(let failure) = result {
                    let fileURL = URL(fileURLWithPath: files[index].path)
                    unavailableFiles.append(
                        UnavailableDuplicateFile(
                            path: files[index].path,
                            reason: .contents(failure: failure, at: fileURL)
                        )
                    )
                }

                completedCount += 1
                if completedCount.isMultiple(of: progressStride) || completedCount == candidateCount {
                    await progressHandler?(completedCount, candidateCount)
                }

                if nextFullHashIndex < pendingFullHashIndices.count, !Task.isCancelled {
                    let nextIndex = pendingFullHashIndices[nextFullHashIndex]
                    nextFullHashIndex += 1
                    group.addTask(priority: .utility) {
                        let result = HashUtility.computeSHA256Result(
                            for: URL(fileURLWithPath: files[nextIndex].path)
                        )
                        return (nextIndex, result)
                    }
                } else if Task.isCancelled {
                    group.cancelAll()
                }
            }
        }

        let groups = indicesByHash
            .compactMap { hash, bucket -> DuplicateGroup? in
                guard let duplicateIndices = bucket.duplicateIndices else {
                    return nil
                }
                return DuplicateGroup(
                    hash: hash,
                    files: duplicateIndices.map { files[$0] }
                )
            }
            .sorted { $0.potentialSavings > $1.potentialSavings }

        return ExactScanResult(
            groups: groups,
            candidateCount: candidateCount,
            sampledCount: sampledCount,
            hashedCount: hashedCount,
            cacheHitCount: cacheHitCount,
            unavailableFiles: unavailableFiles
        )
    }
    
    /// Compute hashes for files that don't have them.
    ///
    /// Reads run two at a time on `.utility` tasks (never serially on the
    /// caller), progress reports are throttled to ~4 Hz, and cancellation
    /// stops scheduling new reads.
    public func computeHashes(for files: inout [FileItem], progressHandler: (@Sendable (Int, Int) -> Void)? = nil) async {
        let missing = files.indices.filter { files[$0].sha256Hash == nil }
        guard !missing.isEmpty else {
            progressHandler?(files.count, files.count)
            return
        }

        let total = files.count
        var completed = total - missing.count
        var lastReport = Date.distantPast

        var next = 0
        await withTaskGroup(of: (Int, String?).self) { group in
            while next < min(maximumConcurrentHashers, missing.count) {
                let fileIndex = missing[next]
                next += 1
                let path = files[fileIndex].path
                group.addTask(priority: .utility) {
                    (fileIndex, HashUtility.computeSHA256(for: URL(fileURLWithPath: path)))
                }
            }

            while let (fileIndex, hash) = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                files[fileIndex].sha256Hash = hash
                completed += 1
                let now = Date()
                if now.timeIntervalSince(lastReport) >= 0.25 {
                    lastReport = now
                    progressHandler?(completed, total)
                }

                if next < missing.count {
                    let nextFileIndex = missing[next]
                    next += 1
                    let path = files[nextFileIndex].path
                    group.addTask(priority: .utility) {
                        (nextFileIndex, HashUtility.computeSHA256(for: URL(fileURLWithPath: path)))
                    }
                }
            }
        }
        progressHandler?(completed, total)
    }
    
    private static func cacheKey(for file: FileItem) -> HashCacheKey {
        HashCacheKey(
            path: file.path,
            size: file.size,
            modificationDate: file.modificationDate
        )
    }

    private static func record(
        index: Int,
        for digest: String,
        in buckets: inout [String: IndexBucket]
    ) {
        if buckets[digest] == nil {
            buckets[digest] = IndexBucket(firstIndex: index)
        } else {
            buckets[digest]?.append(index)
        }
    }

    private func storeCachedHash(_ hash: String, for key: HashCacheKey) {
        if hashCache[key] == nil, hashCache.count >= maximumCachedHashes {
            let removalCount = min(cacheTrimCount, hashCache.count)
            let staleKeys = Array(hashCache.keys.prefix(removalCount))
            for staleKey in staleKeys {
                hashCache.removeValue(forKey: staleKey)
            }
        }
        hashCache[key] = hash
    }
}

/// State of the duplicate scan process
public enum DuplicateScanState: Equatable {
    case idle
    case preparing
    case scanning(progress: Double)
    case completed(count: Int)
    case failed(String)
}

/// Manager for duplicate detection settings and results
@MainActor
public class DuplicateDetectionManager: ObservableObject {
    @Published public var state: DuplicateScanState = .idle
    @Published public var duplicateGroups: [DuplicateGroup] = [] {
        didSet { refreshDerivedDuplicateSummary() }
    }
    @Published public var isScanning = false
    @Published public var scanProgress: Double = 0
    @Published public var lastScanDate: Date?
    @Published public var semanticGroups: [SemanticDuplicateGroup] = [] {
        didSet { refreshDerivedDuplicateSummary() }
    }
    @Published public var scanStage: String = ""
    @Published public private(set) var allGroups: [UnifiedDuplicateGroup] = []
    @Published public private(set) var totalDuplicates: Int = 0
    @Published public private(set) var potentialSavings: Int64 = 0
    @Published public private(set) var formattedSavings: String = ByteCountFormatter.string(
        fromByteCount: 0,
        countStyle: .file
    )
    @Published public private(set) var totalDuplicatesIncludingSemantic: Int = 0
    @Published public private(set) var potentialSavingsIncludingSemantic: Int64 = 0
    @Published public private(set) var formattedSavingsIncludingSemantic: String = ByteCountFormatter.string(
        fromByteCount: 0,
        countStyle: .file
    )
    @Published public private(set) var exactGroupCount: Int = 0
    @Published public private(set) var semanticGroupCount: Int = 0
    @Published public private(set) var scannedFileCount: Int = 0
    @Published public private(set) var hashCandidateCount: Int = 0
    @Published public private(set) var sampledFileCount: Int = 0
    @Published public private(set) var hashedFileCount: Int = 0
    @Published public private(set) var hashCacheHitCount: Int = 0
    @Published public private(set) var unreadableFileCount: Int = 0
    @Published private(set) var unavailableFiles: [UnavailableDuplicateFile] = []
    @Published public private(set) var semanticAnalyzedFileCount: Int = 0
    @Published public private(set) var semanticSkippedFileCount: Int = 0
    @Published public private(set) var scanDuration: TimeInterval = 0
    
    private let detector = DuplicateDetector()
    private var lastProgressUpdate = Date.distantPast
    /// Progress store publishes at most ~4 Hz. Result stores below
    /// (duplicateGroups/semanticGroups) are assigned once per scan, never
    /// per file, so 20+ @Published properties never churn in a hot loop.
    private let progressUpdateInterval: TimeInterval = 0.25
    
    public init() {}

    private func refreshDerivedDuplicateSummary() {
        let exactGroups = duplicateGroups.map { UnifiedDuplicateGroup.exact($0) }
        let semanticGroupsMapped = semanticGroups.map { UnifiedDuplicateGroup.semantic($0) }
        let exactSavings = duplicateGroups.reduce(0) { $0 + $1.potentialSavings }
        let semanticSavings = semanticGroups.reduce(0) { $0 + $1.potentialSavings }
        let exactDuplicateCount = duplicateGroups.reduce(0) { $0 + $1.duplicateCount }
        let semanticDuplicateCount = semanticGroups.reduce(0) { $0 + max(0, $1.files.count - 1) }

        allGroups = (exactGroups + semanticGroupsMapped).sorted { $0.potentialSavings > $1.potentialSavings }
        totalDuplicates = exactDuplicateCount
        potentialSavings = exactSavings
        formattedSavings = ByteCountFormatter.string(fromByteCount: exactSavings, countStyle: .file)
        totalDuplicatesIncludingSemantic = exactDuplicateCount + semanticDuplicateCount
        potentialSavingsIncludingSemantic = exactSavings + semanticSavings
        formattedSavingsIncludingSemantic = ByteCountFormatter.string(
            fromByteCount: exactSavings + semanticSavings,
            countStyle: .file
        )
        exactGroupCount = duplicateGroups.count
        semanticGroupCount = semanticGroups.count
    }
    
    public func scanForDuplicates(files: [FileItem], settings: DuplicateSettings) async {
        let eligibleFiles = eligibleFiles(from: files, settings: settings)
        await performScan(
            exactCandidates: eligibleFiles,
            semanticCandidates: eligibleFiles,
            scannedFileCount: eligibleFiles.count,
            semanticSkippedFileCount: 0,
            preflightUnavailableFiles: [],
            settings: settings
        )
    }

    func scanForDuplicates(
        inventory: DuplicateScanInventory,
        settings: DuplicateSettings
    ) async {
        await performScan(
            exactCandidates: inventory.exactCandidates,
            semanticCandidates: inventory.semanticCandidates,
            scannedFileCount: inventory.scannedFileCount,
            semanticSkippedFileCount: inventory.semanticSkippedFileCount,
            preflightUnavailableFiles: inventory.unavailableFiles,
            settings: settings
        )
    }

    private func performScan(
        exactCandidates: [FileItem],
        semanticCandidates: [FileItem],
        scannedFileCount totalScannedFileCount: Int,
        semanticSkippedFileCount skippedSemanticFileCount: Int,
        preflightUnavailableFiles: [UnavailableDuplicateFile],
        settings: DuplicateSettings
    ) async {
        let scanStartedAt = Date()
        AnalyticsManager.shared.captureWorkflow(
            workflow: "duplicate_scan",
            stage: "started",
            outcome: "started",
            properties: [
                "count_bucket": AnalyticsManager.countBucket(totalScannedFileCount),
                "semantic_enabled": settings.includeSemanticDuplicates,
            ]
        )
        state = .scanning(progress: 0)
        isScanning = true
        scanProgress = 0
        scanStage = "Preparing..."
        lastProgressUpdate = .distantPast
        
        scannedFileCount = totalScannedFileCount
        hashCandidateCount = 0
        sampledFileCount = 0
        hashedFileCount = 0
        hashCacheHitCount = 0
        unavailableFiles = preflightUnavailableFiles
        unreadableFileCount = unavailableFiles.count
        semanticAnalyzedFileCount = 0
        semanticSkippedFileCount = skippedSemanticFileCount
        scanDuration = 0

        guard totalScannedFileCount > 0 else {
            duplicateGroups = []
            semanticGroups = []
            lastScanDate = Date()
            isScanning = false
            scanProgress = 1.0
            scanStage = ""
            scanDuration = Date().timeIntervalSince(scanStartedAt)
            state = .completed(count: 0)
            AnalyticsManager.shared.captureWorkflow(
                workflow: "duplicate_scan",
                stage: "completed",
                outcome: "empty",
                properties: AnalyticsManager.durationProperties(scanDuration).merging([
                    "count_bucket": AnalyticsManager.countBucket(0),
                    "result_kind": "no_files",
                    "semantic_enabled": settings.includeSemanticDuplicates,
                ]) { current, _ in current }
            )
            return
        }
        
        // Exact groups always require matching content. Size bucketing keeps
        // this reliable without hashing every file in large directories.
        scanStage = "Comparing file contents..."

        let exactResult = await detector.findExactDuplicates(in: exactCandidates) { current, candidateTotal in
            let candidateProgress = candidateTotal > 0
                ? Double(current) / Double(candidateTotal)
                : 1
            self.publishScanProgress(candidateProgress * 0.7, force: current == candidateTotal)
        }

        hashCandidateCount = exactResult.candidateCount
        sampledFileCount = exactResult.sampledCount
        hashedFileCount = exactResult.hashedCount
        hashCacheHitCount = exactResult.cacheHitCount
        unavailableFiles.append(contentsOf: exactResult.unavailableFiles)
        unavailableFiles = Array(Dictionary(grouping: unavailableFiles, by: \.path).compactMap(\.value.first))
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        unreadableFileCount = unavailableFiles.count
        
        if Task.isCancelled {
            isScanning = false
            state = .idle
            scanStage = ""
            AnalyticsManager.shared.captureWorkflow(
                workflow: "duplicate_scan",
                stage: "scanning",
                outcome: "cancelled",
                properties: AnalyticsManager.durationProperties(
                    Date().timeIntervalSince(scanStartedAt)
                ).merging([
                    "semantic_enabled": settings.includeSemanticDuplicates,
                ]) { current, _ in current }
            )
            return
        }
        
        var groups = exactResult.groups
        duplicateGroups = groups
        
        // Step 3: Semantic duplicate detection (if enabled)
        if settings.includeSemanticDuplicates && !Task.isCancelled {
            let exactFileIDs = Set(groups.flatMap(\.files).map(\.id))
            let remainingSemanticCandidates = semanticCandidates.filter {
                !exactFileIDs.contains($0.id)
            }
            semanticAnalyzedFileCount = remainingSemanticCandidates.count

            if !remainingSemanticCandidates.isEmpty {
                scanStage = "Semantic analysis..."
                let semanticDetector = SemanticDuplicateDetector(
                    similarityThreshold: settings.normalizedSemanticSimilarityThreshold
                )
                let detectedSemanticGroups = await semanticDetector.findSemanticDuplicates(
                    in: remainingSemanticCandidates
                ) { [weak self] current, total, stage in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let semanticProgress = total > 0 ? Double(current) / Double(total) : 1
                        // Stage labels ride the same 4 Hz throttle as progress
                        // instead of hopping to the main actor per file.
                        if self.publishScanProgress(
                            0.7 + semanticProgress * 0.3,
                            force: current == total
                        ) {
                            self.scanStage = stage
                        }
                    }
                }
                let promotedExactGroups = await promoteExactMatches(from: detectedSemanticGroups)
                let promotedFileIDs = Set(promotedExactGroups.flatMap(\.files).map(\.id))
                if !promotedExactGroups.isEmpty {
                    groups = mergeExactGroupsByHash(groups + promotedExactGroups)
                    duplicateGroups = groups
                }
                semanticGroups = detectedSemanticGroups.compactMap { group in
                    let remainingFiles = group.files.filter { !promotedFileIDs.contains($0.id) }
                    guard remainingFiles.count > 1 else { return nil }
                    return SemanticDuplicateGroup(
                        groupType: group.groupType,
                        files: remainingFiles,
                        similarity: group.similarity,
                        recommendation: group.recommendation
                    )
                }
            } else {
                semanticGroups = []
            }
        } else {
            semanticGroups = []
        }
        
        lastScanDate = Date()
        isScanning = false
        scanProgress = 1.0
        scanStage = ""
        scanDuration = Date().timeIntervalSince(scanStartedAt)
        state = .completed(count: allGroups.count)
        AnalyticsManager.shared.captureWorkflow(
            workflow: "duplicate_scan",
            stage: "completed",
            outcome: "success",
            properties: AnalyticsManager.durationProperties(scanDuration).merging([
                "count_bucket": AnalyticsManager.countBucket(allGroups.count),
                "result_kind": allGroups.isEmpty ? "no_duplicates" : "duplicates_found",
                "semantic_enabled": settings.includeSemanticDuplicates,
            ]) { current, _ in current }
        )
    }
    
    public func clearResults() {
        duplicateGroups = []
        semanticGroups = []
        lastScanDate = nil
        scanProgress = 0
        scanStage = ""
        isScanning = false
        state = .idle
        scannedFileCount = 0
        hashCandidateCount = 0
        sampledFileCount = 0
        hashedFileCount = 0
        hashCacheHitCount = 0
        unreadableFileCount = 0
        unavailableFiles = []
        semanticAnalyzedFileCount = 0
        semanticSkippedFileCount = 0
        scanDuration = 0
    }

    private func eligibleFiles(
        from files: [FileItem],
        settings: DuplicateSettings
    ) -> [FileItem] {
        let duplicateScanFilter = DuplicateScanFilter(settings: settings)
        return files.filter { file in
            !file.isDirectory && duplicateScanFilter.includes(
                fileSize: file.size,
                pathExtension: file.extension,
                displayName: file.displayName
            )
        }
    }

    @discardableResult
    private func publishScanProgress(_ progress: Double, force: Bool = false) -> Bool {
        let now = Date()
        guard force || now.timeIntervalSince(lastProgressUpdate) >= progressUpdateInterval else {
            return false
        }

        lastProgressUpdate = now
        scanProgress = progress
        state = .scanning(progress: progress)
        return true
    }

    private func promoteExactMatches(from semanticGroups: [SemanticDuplicateGroup]) async -> [DuplicateGroup] {
        var promotedGroups: [DuplicateGroup] = []

        for group in semanticGroups {
            let sameSizeBuckets = Dictionary(grouping: group.files.filter { !$0.isDirectory }, by: \.size)
                .values
                .filter { $0.count > 1 }

            for files in sameSizeBuckets {
                let exactResult = await detector.findExactDuplicates(in: Array(files))
                promotedGroups.append(contentsOf: exactResult.groups)
            }
        }

        return mergeExactGroupsByHash(promotedGroups)
    }

    private func mergeExactGroupsByHash(_ groups: [DuplicateGroup]) -> [DuplicateGroup] {
        var filesByHash: [String: [UUID: FileItem]] = [:]
        for group in groups {
            for file in group.files {
                filesByHash[group.hash, default: [:]][file.id] = file
            }
        }

        return filesByHash
            .compactMap { hash, filesById in
                let files = filesById.values.sorted {
                    if $0.displayName == $1.displayName {
                        return $0.path < $1.path
                    }
                    return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
                guard files.count > 1 else { return nil }
                return DuplicateGroup(hash: hash, files: files)
            }
            .sorted { $0.potentialSavings > $1.potentialSavings }
    }
}
