//
//  SemanticDuplicateDetector.swift
//  Sorty
//
//  Semantic Duplicate Detection for near-duplicates
//  Finds similar documents, burst photos, and different versions of files
//

import Foundation
import CryptoKit
import Combine
import Vision
import AppKit

/// Represents a group of semantically similar files (near-duplicates)
public struct SemanticDuplicateGroup: Identifiable, Sendable {
    public let id: UUID
    public let groupType: DuplicateType
    public let files: [FileItem]
    public let similarity: Double // 0.0 - 1.0
    public let recommendation: DuplicateRecommendation

    public enum DuplicateType: String, Codable, Sendable {
        case burstPhotos = "Burst Photos"
        case documentVersions = "Document Versions"
        case resolutionVariants = "Resolution Variants"
        case nearIdenticalImages = "Near-Identical Images"
        case similarDocuments = "Similar Documents"
        case exactDuplicates = "Exact Duplicates"
        case vibeGroup = "Vibe Group"
    }

    public enum DuplicateRecommendation: Codable, Sendable, Equatable {
        case keepHighestResolution(fileId: UUID)
        case keepNewest(fileId: UUID)
        case keepOldest(fileId: UUID)
        case keepLargest(fileId: UUID)
        case archiveOlderVersions(keepId: UUID, archiveIds: [UUID])
        case manualReview

        public var description: String {
            switch self {
            case .keepHighestResolution:
                return "Keep the highest resolution version"
            case .keepNewest:
                return "Keep the most recent version"
            case .keepOldest:
                return "Keep the original version"
            case .keepLargest:
                return "Keep the largest file"
            case .archiveOlderVersions:
                return "Archive older drafts"
            case .manualReview:
                return "Review manually"
            }
        }
    }

    public init(
        id: UUID = UUID(),
        groupType: DuplicateType,
        files: [FileItem],
        similarity: Double,
        recommendation: DuplicateRecommendation = .manualReview
    ) {
        self.id = id
        self.groupType = groupType
        self.files = files
        self.similarity = similarity
        self.recommendation = recommendation
    }

    public var totalSize: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    /// Potential savings if keeping only one file
    public var potentialSavings: Int64 {
        guard files.count > 1 else { return 0 }
        let sorted = files.sorted { $0.size > $1.size }
        return sorted.dropFirst().reduce(0) { $0 + $1.size }
    }

    public var formattedSavings: String {
        ByteCountFormatter.string(fromByteCount: potentialSavings, countStyle: .file)
    }

    public var similarityPercentage: String {
        String(format: "%.0f%%", similarity * 100)
    }
}

/// Actor for detecting semantically similar files
public actor SemanticDuplicateDetector {
    private static let perceptualHashBitLength = 64
    private static let maximumVibeCandidateCount = 500
    /// Content comparison is quadratic, so the candidate set is capped and
    /// pairs are generated from a token inverted index (shingle blocking)
    /// instead of comparing every pair.
    private static let maximumContentCandidateCount = 1_500
    private static let maximumContentCandidatePairs = 200_000
    private static let contentPairYieldInterval = 256

    private struct PerceptualHashRecord {
        let file: FileItem
        let value: UInt64
    }

    private static let resolutionSuffixPatterns = [
        #"_\d+x\d+"#,      // _1920x1080
        #"@\d+x"#,         // @2x, @3x
        #"-small"#,
        #"-medium"#,
        #"-large"#,
        #"-thumbnail"#,
        #"-thumb"#,
        #"_hd"#,
        #"_sd"#,
        #"_4k"#,
        #"_1080p"#,
        #"_720p"#,
    ]

    private static let documentVersionPatterns = [
        #"([\s_\-\.]|^)(v|version|rev)\s*\d+(\.\d+)?$"#,
        #"[\s_\-\.]+(draft|final|copy|backup|old|new)(\s*\d+)?$"#,
        #"\s+\(\d+\)$"#
    ]

    private struct HashSegmentKey: Hashable {
        let segment: Int
        let value: UInt64
    }

    private struct SemanticDisjointSet {
        private var parents: [Int]
        private var ranks: [UInt8]
        private var maximumDistances: [Int]

        init(count: Int) {
            parents = Array(0..<count)
            ranks = Array(repeating: 0, count: count)
            maximumDistances = Array(repeating: 0, count: count)
        }

        mutating func union(_ first: Int, _ second: Int, distance: Int) {
            var firstRoot = root(of: first)
            var secondRoot = root(of: second)

            if firstRoot == secondRoot {
                maximumDistances[firstRoot] = max(maximumDistances[firstRoot], distance)
                return
            }

            if ranks[firstRoot] < ranks[secondRoot] {
                swap(&firstRoot, &secondRoot)
            }

            parents[secondRoot] = firstRoot
            maximumDistances[firstRoot] = max(
                distance,
                max(maximumDistances[firstRoot], maximumDistances[secondRoot])
            )
            if ranks[firstRoot] == ranks[secondRoot] {
                ranks[firstRoot] += 1
            }
        }

        mutating func components() -> [(indices: [Int], maximumDistance: Int)] {
            var indicesByRoot: [Int: [Int]] = [:]
            for index in parents.indices {
                let itemRoot = root(of: index)
                indicesByRoot[itemRoot, default: []].append(index)
            }

            return indicesByRoot.compactMap { root, indices in
                guard indices.count > 1 else { return nil }
                return (indices, maximumDistances[root])
            }
        }

        private mutating func root(of index: Int) -> Int {
            var current = index
            while parents[current] != current {
                parents[current] = parents[parents[current]]
                current = parents[current]
            }
            return current
        }
    }

    private let visionAnalyzer = VisionAnalyzer()
    private let similarityThreshold: Double
    private let hammingThreshold: Int
    private let vibeFeaturePrintThreshold: Float
    private let vibeTextSimilarityThreshold: Double

    public init(similarityThreshold: Double = DuplicateSettings.defaultSemanticSimilarityThreshold) {
        let normalizedThreshold = Self.clampedMinimumSimilarity(similarityThreshold)
        self.similarityThreshold = normalizedThreshold
        self.hammingThreshold = Self.hammingThreshold(for: normalizedThreshold, hashBits: Self.perceptualHashBitLength)
        self.vibeFeaturePrintThreshold = Self.vibeFeatureThreshold(for: normalizedThreshold)
        self.vibeTextSimilarityThreshold = Self.vibeTextThreshold(for: normalizedThreshold)
    }

    static func clampedMinimumSimilarity(_ value: Double) -> Double {
        DuplicateSettings.clampedSemanticSimilarityThreshold(value)
    }

    static func hammingThreshold(for minimumSimilarity: Double, hashBits: Int = 64) -> Int {
        let normalizedThreshold = clampedMinimumSimilarity(minimumSimilarity)
        let rawThreshold = Int(floor((1.0 - normalizedThreshold) * Double(hashBits)))
        return max(0, min(hashBits, rawThreshold))
    }

    static func similarityForHammingDistance(_ distance: Int, hashBits: Int = 64) -> Double {
        guard hashBits > 0 else { return 0 }
        let clampedDistance = max(0, min(distance, hashBits))
        let similarity = 1.0 - (Double(clampedDistance) / Double(hashBits))
        return max(0, min(1.0, similarity))
    }

    static func vibeFeatureThreshold(for minimumSimilarity: Double) -> Float {
        let normalizedThreshold = clampedMinimumSimilarity(minimumSimilarity)
        let strictness = (normalizedThreshold - DuplicateSettings.minSemanticSimilarityThreshold)
            / (DuplicateSettings.maxSemanticSimilarityThreshold - DuplicateSettings.minSemanticSimilarityThreshold)
        // Lower feature-print distance is stricter.
        return max(8.0, 15.0 - Float(strictness) * 7.0)
    }

    static func vibeTextThreshold(for minimumSimilarity: Double) -> Double {
        let normalizedThreshold = clampedMinimumSimilarity(minimumSimilarity)
        return max(0.55, min(0.90, normalizedThreshold - 0.20))
    }

    /// Find all semantic duplicates in a list of files
    public func findSemanticDuplicates(
        in files: [FileItem],
        progressHandler: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async -> [SemanticDuplicateGroup] {
        var groups: [SemanticDuplicateGroup] = []
        let shouldRunVibeDetection = similarityThreshold <= 0.85

        // Separate files by type
        let imageFiles = files.filter { isImageFile($0) }
        let documentFiles = files.filter { isDocumentFile($0) }

        let totalSteps = shouldRunVibeDetection ? 5 : 4
        var currentStep = 0

        // Step 1: Find burst photos (images taken within seconds of each other)
        progressHandler?(currentStep, totalSteps, "Analyzing burst photos...")
        let burstGroups = await findBurstPhotos(in: imageFiles)
        groups.append(contentsOf: burstGroups)
        currentStep += 1

        // Step 2: Find near-identical images using perceptual hashing
        progressHandler?(currentStep, totalSteps, "Comparing images...")
        let imageHashes = await perceptualHashRecords(in: imageFiles)
        let similarImageGroups = findSimilarImages(in: imageHashes)
        groups.append(contentsOf: similarImageGroups)
        currentStep += 1

        // Step 3: Find resolution variants (same image, different sizes)
        progressHandler?(currentStep, totalSteps, "Finding resolution variants...")
        let resolutionGroups = await findResolutionVariants(
            in: imageFiles,
            perceptualHashes: Dictionary(uniqueKeysWithValues: imageHashes.map { ($0.file.id, $0.value) })
        )
        groups.append(contentsOf: resolutionGroups)
        currentStep += 1

        // Step 4: Find similar documents
        progressHandler?(currentStep, totalSteps, "Analyzing documents...")
        let documentGroups = await findSimilarDocuments(in: documentFiles)
        groups.append(contentsOf: documentGroups)
        currentStep += 1

        // Step 5: Find vibe groups (only for looser thresholds)
        if shouldRunVibeDetection {
            progressHandler?(currentStep, totalSteps, "Finding vibe groups...")
            let vibeGroups = await findVibeGroups(in: files)
            groups.append(contentsOf: vibeGroups)
            currentStep += 1
        }

        // Keep only groups at or above the configured similarity level.
        let thresholdedGroups = groups.filter { $0.similarity >= similarityThreshold }

        // Remove duplicates between groups and merge overlapping.
        let mergedGroups = mergeOverlappingGroups(thresholdedGroups)

        return mergedGroups.sorted {
            if $0.similarity == $1.similarity {
                return $0.potentialSavings > $1.potentialSavings
            }
            return $0.similarity > $1.similarity
        }
    }

    // MARK: - Burst Photo Detection

    private func findBurstPhotos(in images: [FileItem]) async -> [SemanticDuplicateGroup] {
        var groups: [SemanticDuplicateGroup] = []

        // Group by creation date within a short burst window, but require
        // either camera-style filename continuity or comparable dimensions/size
        // from similarly named files. Timestamp-only grouping is too noisy for
        // large mixed photo folders.
        let sortedByDate = images
            .filter { $0.creationDate != nil }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }

        var currentGroup: [FileItem] = []
        var previousFile: FileItem?

        for file in sortedByDate {
            if let previousFile, shouldTreatAsBurstContinuation(previousFile, file) {
                currentGroup.append(file)
            } else {
                if currentGroup.count > 1 {
                    let recommendation = recommendForBurstPhotos(currentGroup)
                    groups.append(SemanticDuplicateGroup(
                        groupType: .burstPhotos,
                        files: currentGroup,
                        similarity: 0.95,
                        recommendation: recommendation
                    ))
                }
                currentGroup = [file]
            }

            previousFile = file
        }

        // Don't forget the last group
        if currentGroup.count > 1 {
            let recommendation = recommendForBurstPhotos(currentGroup)
            groups.append(SemanticDuplicateGroup(
                groupType: .burstPhotos,
                files: currentGroup,
                similarity: 0.95,
                recommendation: recommendation
            ))
        }

        return groups
    }

    // MARK: - Perceptual Hash Comparison

    private func perceptualHashRecords(in images: [FileItem]) async -> [PerceptualHashRecord] {
        var imageHashes: [PerceptualHashRecord] = []
        imageHashes.reserveCapacity(images.count)

        var processedCount = 0
        for file in images {
            if Task.isCancelled {
                return []
            }

            guard let url = file.url else { continue }

            let hash: String?
            if let existingHash = file.contentFingerprint {
                hash = existingHash
            } else {
                hash = await visionAnalyzer.generatePerceptualHash(at: url)
            }

            guard let hash,
                  let value = Self.perceptualHashValue(hash) else {
                continue
            }
            imageHashes.append(PerceptualHashRecord(file: file, value: value))
            processedCount += 1
            if processedCount.isMultiple(of: 50) {
                await Task.yield()
            }
        }

        return imageHashes
    }

    private func findSimilarImages(in imageHashes: [PerceptualHashRecord]) -> [SemanticDuplicateGroup] {
        guard imageHashes.count > 1 else {
            return []
        }

        var disjointSet = SemanticDisjointSet(count: imageHashes.count)
        var representativeByHash: [UInt64: Int] = [:]
        var indicesBySegment: [HashSegmentKey: [Int]] = [:]

        for (index, record) in imageHashes.enumerated() {
            if Task.isCancelled {
                return []
            }

            if let representative = representativeByHash[record.value] {
                disjointSet.union(index, representative, distance: 0)
                continue
            }

            let segmentKeys = Self.segmentKeys(
                for: record.value,
                maximumDistance: hammingThreshold
            )
            var candidateIndices: Set<Int> = []
            for key in segmentKeys {
                if let matchingIndices = indicesBySegment[key] {
                    candidateIndices.formUnion(matchingIndices)
                }
            }

            for candidateIndex in candidateIndices {
                let distance = (record.value ^ imageHashes[candidateIndex].value).nonzeroBitCount
                if distance <= hammingThreshold {
                    disjointSet.union(index, candidateIndex, distance: distance)
                }
            }

            representativeByHash[record.value] = index
            for key in segmentKeys {
                indicesBySegment[key, default: []].append(index)
            }
        }

        return disjointSet.components().map { component in
            let files = component.indices.map { imageHashes[$0].file }
            let similarity = Self.similarityForHammingDistance(
                component.maximumDistance,
                hashBits: Self.perceptualHashBitLength
            )
            return SemanticDuplicateGroup(
                groupType: .nearIdenticalImages,
                files: files,
                similarity: similarity,
                recommendation: recommendForSimilarImages(files)
            )
        }
    }

    private static func perceptualHashValue(_ hash: String) -> UInt64? {
        if hash.count == perceptualHashBitLength,
           hash.allSatisfy({ $0 == "0" || $0 == "1" }) {
            return UInt64(hash, radix: 2)
        }
        return UInt64(hash, radix: 16)
    }

    private static func segmentKeys(
        for hash: UInt64,
        maximumDistance: Int
    ) -> [HashSegmentKey] {
        let segmentCount = max(1, min(perceptualHashBitLength, maximumDistance + 1))
        var keys: [HashSegmentKey] = []
        keys.reserveCapacity(segmentCount)

        for segment in 0..<segmentCount {
            let lowerBit = segment * perceptualHashBitLength / segmentCount
            let upperBit = (segment + 1) * perceptualHashBitLength / segmentCount
            let width = upperBit - lowerBit
            let mask = width == perceptualHashBitLength
                ? UInt64.max
                : (UInt64(1) << UInt64(width)) - 1
            keys.append(
                HashSegmentKey(
                    segment: segment,
                    value: (hash >> UInt64(lowerBit)) & mask
                )
            )
        }

        return keys
    }

    // MARK: - Resolution Variant Detection

    private func findResolutionVariants(
        in images: [FileItem],
        perceptualHashes: [UUID: UInt64]
    ) async -> [SemanticDuplicateGroup] {
        var groups: [SemanticDuplicateGroup] = []

        // Group by similar filename patterns. Suffix patterns are compiled
        // once per call, not once per file.
        let suffixRegexes = Self.resolutionSuffixPatterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: .caseInsensitive)
        }
        let baseNameGroups = Dictionary(grouping: images) { file -> String in
            // Extract base name without resolution suffix patterns
            var baseName = file.name.lowercased()
            for regex in suffixRegexes {
                let range = NSRange(baseName.startIndex..., in: baseName)
                baseName = regex.stringByReplacingMatches(in: baseName, range: range, withTemplate: "")
            }
            return baseName
        }

        for (_, filesInGroup) in baseNameGroups where filesInGroup.count > 1 {
            var withDimensions: [FileItem] = []
            withDimensions.reserveCapacity(filesInGroup.count)
            for var file in filesInGroup {
                if file.imageWidth == nil || file.imageHeight == nil,
                   let url = file.url,
                   let dimensions = await visionAnalyzer.getImageDimensions(at: url) {
                    file.imageWidth = dimensions.width
                    file.imageHeight = dimensions.height
                }
                if file.imageWidth != nil, file.imageHeight != nil {
                    withDimensions.append(file)
                }
            }

            guard withDimensions.count > 1 else { continue }

            var links: [(Int, Int)] = []
            for firstIndex in withDimensions.indices {
                guard let firstHash = perceptualHashes[withDimensions[firstIndex].id] else { continue }
                for secondIndex in withDimensions.indices where secondIndex > firstIndex {
                    guard let secondHash = perceptualHashes[withDimensions[secondIndex].id] else { continue }
                    let distance = (firstHash ^ secondHash).nonzeroBitCount
                    if distance <= hammingThreshold {
                        links.append((firstIndex, secondIndex))
                    }
                }
            }

            let visuallyMatchedGroups = connectedSemanticGroups(
                itemCount: withDimensions.count,
                links: links
            ) { indexes in
                indexes.map { withDimensions[$0] }
            }

            for matchedFiles in visuallyMatchedGroups {
                let sortedBySize = matchedFiles.sorted { ($0.totalPixels ?? 0) > ($1.totalPixels ?? 0) }
                guard let first = sortedBySize.first?.totalPixels,
                      let last = sortedBySize.last?.totalPixels,
                      first != last,
                      let highestResolutionFile = sortedBySize.first else {
                    continue
                }

                let matchedFileIDs = Set(sortedBySize.map(\.id))
                let worstDistance = links.compactMap { link -> Int? in
                    let firstFile = withDimensions[link.0]
                    let secondFile = withDimensions[link.1]
                    guard matchedFileIDs.contains(firstFile.id),
                          matchedFileIDs.contains(secondFile.id),
                          let firstHash = perceptualHashes[firstFile.id],
                          let secondHash = perceptualHashes[secondFile.id] else {
                        return nil
                    }
                    return (firstHash ^ secondHash).nonzeroBitCount
                }.max() ?? 0

                groups.append(SemanticDuplicateGroup(
                    groupType: .resolutionVariants,
                    files: sortedBySize,
                    similarity: Self.similarityForHammingDistance(worstDistance),
                    recommendation: .keepHighestResolution(fileId: highestResolutionFile.id)
                ))
            }
        }

        return groups
    }

    // MARK: - Similar Document Detection

    private func findSimilarDocuments(in documents: [FileItem]) async -> [SemanticDuplicateGroup] {
        var groups: [SemanticDuplicateGroup] = []
        var processedIds: Set<UUID> = []

        // Group documents by explicit version/copy markers only. Bare numbers
        // often carry meaning (tax year, invoice number, report quarter) and
        // should not create false-positive version groups. Version patterns
        // are compiled once per call, not once per file.
        let versionRegexes = Self.documentVersionPatterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: .caseInsensitive)
        }
        let versionRecords = documents.map { file in
            let versionKey = documentVersionKey(for: file, regexes: versionRegexes)
            return (file: file, key: versionKey.key, hasVersionMarker: versionKey.hasVersionMarker)
        }
        let baseNameGroups = Dictionary(grouping: versionRecords, by: \.key)

        for (_, recordsInGroup) in baseNameGroups where recordsInGroup.count > 1 && recordsInGroup.contains(where: \.hasVersionMarker) {
            let filesInGroup = recordsInGroup.map(\.file)
            for file in filesInGroup {
                processedIds.insert(file.id)
            }

            // Sort by modification date or creation date
            let sortedByDate = filesInGroup.sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }

            let recommendation: SemanticDuplicateGroup.DuplicateRecommendation
            if sortedByDate.count > 2 {
                recommendation = .archiveOlderVersions(
                    keepId: sortedByDate.first!.id,
                    archiveIds: Array(sortedByDate.dropFirst().map { $0.id })
                )
            } else {
                recommendation = .keepNewest(fileId: sortedByDate.first!.id)
            }

            groups.append(SemanticDuplicateGroup(
                groupType: .documentVersions,
                files: sortedByDate,
                similarity: 0.90,
                recommendation: recommendation
            ))
        }

        // Also compare document content if available
        let withContent = documents.filter { $0.hasSemanticContent }
        let contentGroups = await findSimilarByContent(withContent, processedIds: processedIds)
        groups.append(contentsOf: contentGroups)

        return groups
    }

    private func findSimilarByContent(_ documents: [FileItem], processedIds: Set<UUID>) async -> [SemanticDuplicateGroup] {
        // Cap the candidate set deterministically (sorted by path) so huge
        // folders cannot explode the quadratic comparison below.
        let eligible = documents.indices.filter {
            !processedIds.contains(documents[$0].id)
                && documents[$0].semanticTextContent != nil
        }.sorted { documents[$0].path < documents[$1].path }
        let order = Array(eligible.prefix(Self.maximumContentCandidateCount))
        guard order.count > 1 else { return [] }

        let features = order.map { index in
            // Nil was filtered above; fall back to empty features defensively.
            documents[index].semanticTextContent.map(Self.textFeatures)
        }
        var parent = Array(order.indices)
        var rank = Array(repeating: 0, count: order.count)
        var minimumSimilarity = Array(repeating: 1.0, count: order.count)

        func root(of index: Int) -> Int {
            var current = index
            while parent[current] != current {
                current = parent[current]
            }
            return current
        }

        func union(_ first: Int, _ second: Int, similarity: Double) {
            var firstRoot = root(of: first)
            var secondRoot = root(of: second)
            if firstRoot == secondRoot {
                minimumSimilarity[firstRoot] = min(minimumSimilarity[firstRoot], similarity)
                return
            }
            if rank[firstRoot] < rank[secondRoot] {
                swap(&firstRoot, &secondRoot)
            }
            parent[secondRoot] = firstRoot
            minimumSimilarity[firstRoot] = min(
                minimumSimilarity[firstRoot],
                minimumSimilarity[secondRoot],
                similarity
            )
            if rank[firstRoot] == rank[secondRoot] {
                rank[firstRoot] += 1
            }
        }

        // Shingle blocking: a pair with similarity above zero must share at
        // least one token (bigram overlap implies token overlap), so generate
        // candidate pairs from a token inverted index. Rarest tokens first,
        // with a hard pair cap for pathological corpora.
        var postings: [String: [Int]] = [:]
        for (position, feature) in features.enumerated() {
            guard let feature else { continue }
            for token in feature.frequencies.keys {
                postings[token, default: []].append(position)
            }
        }
        var seenPairs = Set<Int64>()
        var candidatePairs: [(Int, Int)] = []
        candidatePairs.reserveCapacity(
            min(Self.maximumContentCandidatePairs, order.count * order.count / 2)
        )
        let tokensByRarity = postings.keys.sorted {
            (postings[$0]?.count ?? 0) < (postings[$1]?.count ?? 0)
        }
        pairGeneration: for token in tokensByRarity {
            guard let list = postings[token] else { continue }
            for a in list.indices {
                for b in list.indices where b > a {
                    // Positions ascend within a posting list, so the key is ordered.
                    let key = (Int64(list[a]) << 32) | Int64(list[b])
                    if seenPairs.insert(key).inserted {
                        candidatePairs.append((list[a], list[b]))
                        if candidatePairs.count >= Self.maximumContentCandidatePairs {
                            break pairGeneration
                        }
                    }
                }
            }
        }

        var comparedCount = 0
        for (first, second) in candidatePairs {
            guard let firstFeatures = features[first],
                  let secondFeatures = features[second] else { continue }

            let similarity = Self.textSimilarity(firstFeatures, secondFeatures)
            if similarity >= similarityThreshold {
                union(first, second, similarity: similarity)
            }

            comparedCount += 1
            if comparedCount.isMultiple(of: Self.contentPairYieldInterval) {
                await Task.yield()
                if Task.isCancelled {
                    return []
                }
            }
        }

        var indexesByRoot: [Int: Set<Int>] = [:]
        for position in order.indices where features[position] != nil {
            indexesByRoot[root(of: position), default: []].insert(order[position])
        }

        return indexesByRoot.compactMap { componentRoot, indexes in
            guard indexes.count > 1 else { return nil }
            let files = indexes.map { documents[$0] }

            return SemanticDuplicateGroup(
                groupType: .similarDocuments,
                files: files,
                similarity: max(similarityThreshold, minimumSimilarity[componentRoot]),
                recommendation: .manualReview
            )
        }
    }

    // MARK: - Vibe Group Detection

    private func findVibeGroups(in files: [FileItem]) async -> [SemanticDuplicateGroup] {
        let imageFiles = files.filter { isImageFile($0) }
        let documentFiles = files.filter { isDocumentFile($0) }

        var groups: [SemanticDuplicateGroup] = []

        let imageVibeGroups = await findImageVibeGroups(in: imageFiles)
        groups.append(contentsOf: imageVibeGroups)

        let documentVibeGroups = await findDocumentVibeGroups(in: documentFiles)
        groups.append(contentsOf: documentVibeGroups)

        return groups
    }

    private func findImageVibeGroups(in images: [FileItem]) async -> [SemanticDuplicateGroup] {
        var groups: [SemanticDuplicateGroup] = []
        var processedIds: Set<UUID> = []

        var featurePrints: [(file: FileItem, featurePrint: VNFeaturePrintObservation)] = []
        let boundedImages = images
            .sorted { $0.path < $1.path }
            .prefix(Self.maximumVibeCandidateCount)

        for file in boundedImages {
            if Task.isCancelled {
                return []
            }
            guard let url = file.url else { continue }
            if let featurePrint = await generateFeaturePrint(at: url) {
                featurePrints.append((file, featurePrint))
            }
        }

        for i in 0..<featurePrints.count {
            guard !processedIds.contains(featurePrints[i].file.id) else { continue }

            var similarFiles: [FileItem] = [featurePrints[i].file]
            var matchedDistances: [Float] = []
            var comparedCount = 0

            for j in (i + 1)..<featurePrints.count {
                guard !processedIds.contains(featurePrints[j].file.id) else { continue }

                var distance: Float = 0
                do {
                    try featurePrints[i].featurePrint.computeDistance(&distance, to: featurePrints[j].featurePrint)
                } catch {
                    continue
                }

                comparedCount += 1
                if comparedCount.isMultiple(of: Self.contentPairYieldInterval) {
                    await Task.yield()
                    if Task.isCancelled {
                        return []
                    }
                }

                if distance < vibeFeaturePrintThreshold {
                    similarFiles.append(featurePrints[j].file)
                    matchedDistances.append(distance)
                    processedIds.insert(featurePrints[j].file.id)
                }
            }

            if similarFiles.count > 1 {
                processedIds.insert(featurePrints[i].file.id)
                let worstDistance = matchedDistances.max() ?? 0
                let normalizedDistance = Double(worstDistance / max(vibeFeaturePrintThreshold, 0.001))
                let normalizedSimilarity = max(0.0, 1.0 - min(1.0, normalizedDistance) * 0.35)

                groups.append(SemanticDuplicateGroup(
                    groupType: .vibeGroup,
                    files: similarFiles,
                    similarity: normalizedSimilarity,
                    recommendation: .manualReview
                ))
            }
        }

        return groups
    }

    private func findDocumentVibeGroups(in documents: [FileItem]) async -> [SemanticDuplicateGroup] {
        var groups: [SemanticDuplicateGroup] = []
        var processedIds: Set<UUID> = []

        let withContent = documents
            .filter { $0.hasSemanticContent }
            .sorted { $0.path < $1.path }
            .prefix(Self.maximumVibeCandidateCount)

        for i in 0..<withContent.count {
            guard !processedIds.contains(withContent[i].id),
                  let content1 = withContent[i].semanticTextContent else { continue }

            var similarFiles: [FileItem] = [withContent[i]]
            var lowestSimilarityInGroup = 1.0
            var comparedCount = 0

            for j in (i + 1)..<withContent.count {
                guard !processedIds.contains(withContent[j].id),
                      let content2 = withContent[j].semanticTextContent else { continue }

                let similarity = Self.textSimilarity(content1, content2)
                comparedCount += 1
                if comparedCount.isMultiple(of: Self.contentPairYieldInterval) {
                    await Task.yield()
                    if Task.isCancelled {
                        return []
                    }
                }
                if similarity >= vibeTextSimilarityThreshold {
                    similarFiles.append(withContent[j])
                    lowestSimilarityInGroup = min(lowestSimilarityInGroup, similarity)
                    processedIds.insert(withContent[j].id)
                }
            }

            if similarFiles.count > 1 {
                processedIds.insert(withContent[i].id)
                let groupSimilarity = max(vibeTextSimilarityThreshold, lowestSimilarityInGroup)

                groups.append(SemanticDuplicateGroup(
                    groupType: .vibeGroup,
                    files: similarFiles,
                    similarity: groupSimilarity,
                    recommendation: .manualReview
                ))
            }
        }

        return groups
    }

    private func generateFeaturePrint(at url: URL) async -> VNFeaturePrintObservation? {
        guard let cgImage = loadCGImage(from: url) else { return nil }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            DebugLogger.log("Failed to generate feature print: \(error.localizedDescription)")
            return nil
        }

        guard let result = request.results?.first else {
            return nil
        }

        return result
    }

    private func loadCGImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: false,
            ] as CFDictionary
        )
    }

    // MARK: - Text Similarity

    static func textSimilarity(_ firstText: String, _ secondText: String) -> Double {
        textSimilarity(textFeatures(firstText), textFeatures(secondText))
    }

    private struct TextFeatures {
        let tokens: [String]
        let frequencies: [String: Int]
        let frequencyMagnitude: Double
        let bigrams: [String: Int]
        let bigramCount: Int
    }

    private static func textFeatures(_ text: String) -> TextFeatures {
        let tokens = normalizedTokens(in: text)
        let frequencies = tokens.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let bigrams = bigrams(from: tokens)
        return TextFeatures(
            tokens: tokens,
            frequencies: frequencies,
            frequencyMagnitude: sqrt(frequencies.values.reduce(0.0) { $0 + Double($1 * $1) }),
            bigrams: bigrams,
            bigramCount: bigrams.values.reduce(0, +)
        )
    }

    private static func textSimilarity(_ first: TextFeatures, _ second: TextFeatures) -> Double {
        guard !first.tokens.isEmpty, !second.tokens.isEmpty else { return 0 }

        let frequencySimilarity = cosineSimilarity(first, second)
        let orderSimilarity = diceSimilarity(first, second)

        if min(first.tokens.count, second.tokens.count) < 4 {
            return first.tokens == second.tokens ? 1 : frequencySimilarity * 0.7
        }

        // Word frequency tolerates small edits, while adjacent word pairs stop
        // documents with the same vocabulary in a different order from looking
        // like versions of one another.
        return frequencySimilarity * 0.65 + orderSimilarity * 0.35
    }

    private static func normalizedTokens(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func cosineSimilarity(_ first: TextFeatures, _ second: TextFeatures) -> Double {
        let dotProduct = first.frequencies.reduce(0.0) { result, entry in
            result + Double(entry.value * (second.frequencies[entry.key] ?? 0))
        }
        guard first.frequencyMagnitude > 0, second.frequencyMagnitude > 0 else { return 0 }
        return dotProduct / (first.frequencyMagnitude * second.frequencyMagnitude)
    }

    private static func bigrams(from tokens: [String]) -> [String: Int] {
        guard tokens.count > 1 else { return [:] }
        return zip(tokens, tokens.dropFirst()).reduce(into: [String: Int]()) { counts, pair in
            counts[pair.0 + "\u{1F}" + pair.1, default: 0] += 1
        }
    }

    private static func diceSimilarity(_ first: TextFeatures, _ second: TextFeatures) -> Double {
        guard first.bigramCount + second.bigramCount > 0 else { return 0 }
        let overlap = first.bigrams.reduce(0) { result, entry in
            result + min(entry.value, second.bigrams[entry.key] ?? 0)
        }
        return Double(2 * overlap) / Double(first.bigramCount + second.bigramCount)
    }

    // MARK: - Helper Methods

    private func isImageFile(_ file: FileItem) -> Bool {
        let imageExtensions = ["jpg", "jpeg", "png", "heic", "tiff", "tif", "bmp", "gif", "webp", "raw", "cr2", "nef", "arw"]
        return imageExtensions.contains(file.extension.lowercased())
    }

    private func isDocumentFile(_ file: FileItem) -> Bool {
        let documentExtensions = ["pdf", "doc", "docx", "txt", "rtf", "md", "pages", "odt", "xls", "xlsx", "ppt", "pptx"]
        return documentExtensions.contains(file.extension.lowercased())
    }

    private func recommendForBurstPhotos(_ files: [FileItem]) -> SemanticDuplicateGroup.DuplicateRecommendation {
        // For burst photos, recommend keeping the highest resolution
        if let best = files.max(by: { ($0.totalPixels ?? 0) < ($1.totalPixels ?? 0) }) {
            return .keepHighestResolution(fileId: best.id)
        }
        // Fallback to largest file
        if let largest = files.max(by: { $0.size < $1.size }) {
            return .keepLargest(fileId: largest.id)
        }
        return .manualReview
    }

    private func recommendForSimilarImages(_ files: [FileItem]) -> SemanticDuplicateGroup.DuplicateRecommendation {
        // Prefer highest resolution
        if let best = files.max(by: { ($0.totalPixels ?? 0) < ($1.totalPixels ?? 0) }),
           best.totalPixels != nil {
            return .keepHighestResolution(fileId: best.id)
        }
        // Then largest size
        if let largest = files.max(by: { $0.size < $1.size }) {
            return .keepLargest(fileId: largest.id)
        }
        return .manualReview
    }

    private func shouldTreatAsBurstContinuation(_ previous: FileItem, _ candidate: FileItem) -> Bool {
        guard let previousDate = previous.creationDate,
              let candidateDate = candidate.creationDate,
              candidateDate.timeIntervalSince(previousDate) <= 2.0,
              URL(fileURLWithPath: previous.path).deletingLastPathComponent().path == URL(fileURLWithPath: candidate.path).deletingLastPathComponent().path,
              previous.extension.lowercased() == candidate.extension.lowercased() else {
            return false
        }

        return hasSequentialCameraName(previous.name, candidate.name)
            || (hasSharedNamePrefix(previous.name, candidate.name) && hasComparableImageShapeAndSize(previous, candidate))
    }

    private func hasSequentialCameraName(_ firstName: String, _ secondName: String) -> Bool {
        guard let first = cameraNameParts(firstName),
              let second = cameraNameParts(secondName),
              first.prefix == second.prefix else {
            return false
        }

        return abs(first.number - second.number) <= 10
    }

    private func cameraNameParts(_ name: String) -> (prefix: String, number: Int)? {
        let lowercasedName = name.lowercased()
        guard let match = lowercasedName.range(
            of: #"^([a-z_\- ]{2,})(\d{2,})$"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let matched = String(lowercasedName[match])
        guard let numberRange = matched.range(of: #"\d{2,}$"#, options: .regularExpression),
              let number = Int(matched[numberRange]) else {
            return nil
        }

        let prefix = String(matched[..<numberRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (prefix, number)
    }

    private func hasSharedNamePrefix(_ firstName: String, _ secondName: String) -> Bool {
        let firstPrefix = alphabeticPrefix(for: firstName)
        let secondPrefix = alphabeticPrefix(for: secondName)
        guard firstPrefix.count >= 4, secondPrefix.count >= 4 else { return false }
        return firstPrefix == secondPrefix
    }

    private func alphabeticPrefix(for name: String) -> String {
        let lowercasedName = name.lowercased()
        guard let range = lowercasedName.range(of: #"^[a-z][a-z_\- ]+"#, options: .regularExpression) else {
            return ""
        }
        return lowercasedName[range]
            .replacingOccurrences(of: #"[\s_\-]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasComparableImageShapeAndSize(_ first: FileItem, _ second: FileItem) -> Bool {
        if let firstPixels = first.totalPixels,
           let secondPixels = second.totalPixels,
           firstPixels > 0,
           secondPixels > 0 {
            let ratio = Double(min(firstPixels, secondPixels)) / Double(max(firstPixels, secondPixels))
            return ratio >= 0.92
        }

        guard first.size > 0, second.size > 0 else { return false }
        let ratio = Double(min(first.size, second.size)) / Double(max(first.size, second.size))
        return ratio >= 0.75
    }

    private func documentVersionKey(for file: FileItem, regexes: [NSRegularExpression]) -> (key: String, hasVersionMarker: Bool) {
        let lowercasedName = file.name.lowercased()

        var normalizedName = lowercasedName
        var hasVersionMarker = false
        for regex in regexes {
            let range = NSRange(normalizedName.startIndex..., in: normalizedName)
            let updated = regex.stringByReplacingMatches(in: normalizedName, range: range, withTemplate: "")
            if updated != normalizedName {
                normalizedName = updated
                hasVersionMarker = true
            }
        }

        normalizedName = normalizedName
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
            .replacingOccurrences(of: #"[\s_\-\.]+"#, with: " ", options: .regularExpression)

        return (normalizedName + "." + file.extension.lowercased(), hasVersionMarker)
    }

    private func mergeOverlappingGroups(_ groups: [SemanticDuplicateGroup]) -> [SemanticDuplicateGroup] {
        let sortedGroups = groups.sorted {
            if $0.similarity == $1.similarity {
                return $0.potentialSavings > $1.potentialSavings
            }
            return $0.similarity > $1.similarity
        }

        var components: [SemanticDuplicateGroup] = []

        for group in sortedGroups {
            var mergedGroup = group
            var mergedIndexes: [Int] = []
            var mergedFileIds = Set(group.files.map(\.id))

            for (index, existingGroup) in components.enumerated() {
                let existingFileIds = Set(existingGroup.files.map(\.id))
                guard !mergedFileIds.isDisjoint(with: existingFileIds) else { continue }

                mergedGroup = merge(mergedGroup, with: existingGroup)
                mergedFileIds.formUnion(existingFileIds)
                mergedIndexes.append(index)
            }

            for index in mergedIndexes.reversed() {
                components.remove(at: index)
            }
            components.append(mergedGroup)
        }

        return components.sorted {
            if $0.similarity == $1.similarity {
                return $0.potentialSavings > $1.potentialSavings
            }
            return $0.similarity > $1.similarity
        }
    }

    private func merge(_ first: SemanticDuplicateGroup, with second: SemanticDuplicateGroup) -> SemanticDuplicateGroup {
        var filesById: [UUID: FileItem] = [:]
        for file in first.files + second.files {
            filesById[file.id] = file
        }

        let strongestEvidence = first.similarity >= second.similarity ? first : second
        let mergedFiles = filesById.values.sorted {
            if $0.displayName == $1.displayName {
                return $0.path < $1.path
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        let recommendation: SemanticDuplicateGroup.DuplicateRecommendation =
            first.groupType == second.groupType ? strongestEvidence.recommendation : .manualReview

        return SemanticDuplicateGroup(
            groupType: strongestEvidence.groupType,
            files: mergedFiles,
            similarity: min(first.similarity, second.similarity),
            recommendation: recommendation
        )
    }

    private func connectedSemanticGroups<Group>(
        itemCount: Int,
        links: [(Int, Int)],
        makeGroup: (Set<Int>) -> Group
    ) -> [Group] {
        guard itemCount > 1, !links.isEmpty else { return [] }

        var parent = Array(0..<itemCount)

        func root(of index: Int) -> Int {
            var current = index
            while parent[current] != current {
                current = parent[current]
            }
            return current
        }

        func union(_ first: Int, _ second: Int) {
            let firstRoot = root(of: first)
            let secondRoot = root(of: second)
            guard firstRoot != secondRoot else { return }
            parent[secondRoot] = firstRoot
        }

        for link in links {
            union(link.0, link.1)
        }

        var indexesByRoot: [Int: Set<Int>] = [:]
        for index in 0..<itemCount {
            let itemRoot = root(of: index)
            indexesByRoot[itemRoot, default: []].insert(index)
        }

        return indexesByRoot.values
            .filter { $0.count > 1 }
            .map(makeGroup)
    }
}
