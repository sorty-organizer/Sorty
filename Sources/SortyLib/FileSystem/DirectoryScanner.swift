//
//  DirectoryScanner.swift
//  Sorty
//
//  Recursively scans directories and builds file tree
//

import CryptoKit
import Darwin
import Foundation
import os.log

struct DuplicateScanInventory: Sendable {
    let exactCandidates: [FileItem]
    let semanticCandidates: [FileItem]
    let scannedFileCount: Int
    let semanticSkippedFileCount: Int
    let unavailableFiles: [UnavailableDuplicateFile]
}

struct UnavailableDuplicateFile: Identifiable, Hashable, Sendable {
    enum Reason: Hashable, Sendable {
        case permissionDenied
        case fileMissing
        case cloudFileUnavailable
        case storageUnavailable
        case changedWhileScanning
        case other(stage: String, systemMessage: String)

        var description: String {
            switch self {
            case .permissionDenied:
                return "Sorty does not have permission to read this file."
            case .fileMissing:
                return "The file was moved or deleted during the scan."
            case .cloudFileUnavailable:
                return "The cloud file is not downloaded or its provider is unavailable."
            case .storageUnavailable:
                return "The drive or network location is no longer available."
            case .changedWhileScanning:
                return "The file changed while Sorty was reading it."
            case .other(let stage, let systemMessage):
                return "\(stage) failed: \(systemMessage)"
            }
        }

        static func metadata(error: Error, at url: URL) -> Self {
            classify(error: error, at: url, stage: "Reading file information")
        }

        static func contents(failure: HashUtility.ReadFailure, at url: URL) -> Self {
            classify(
                domain: failure.domain,
                code: failure.code,
                message: failure.message,
                at: url,
                stage: "Reading file contents"
            )
        }

        private static func classify(error: Error, at url: URL, stage: String) -> Self {
            let nsError = error as NSError
            return classify(
                domain: nsError.domain,
                code: nsError.code,
                message: nsError.localizedDescription,
                at: url,
                stage: stage
            )
        }

        private static func classify(
            domain: String,
            code: Int,
            message: String,
            at url: URL,
            stage: String
        ) -> Self {
            if domain == NSCocoaErrorDomain, code == NSFileReadNoPermissionError {
                return .permissionDenied
            }
            if domain == NSPOSIXErrorDomain, code == Int(EACCES) || code == Int(EPERM) {
                return .permissionDenied
            }
            if message == "The file changed while it was being read." {
                return .changedWhileScanning
            }

            let pathComponents = Set(url.standardizedFileURL.pathComponents.map { $0.lowercased() })
            let isCloudPath = pathComponents.contains("cloudstorage")
                || pathComponents.contains("mobile documents")
                || pathComponents.contains("dropbox")
            if isCloudPath {
                return .cloudFileUnavailable
            }

            if !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
                return .storageUnavailable
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                return .fileMissing
            }
            return .other(stage: stage, systemMessage: message)
        }
    }

    let path: String
    let reason: Reason

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

actor DirectoryScanner {
    private var isScanning = false
    private var scannedCount = 0
    private var cloudPlaceholdersSkipped = 0
    /// Symlinked entries skipped during the current scan (never followed, so
    /// `A/loop -> ..` style cycles cannot hang or escape the scan root).
    private var symlinksSkipped = 0
    private var isPaused = false
    private var memoryPressureState: MemoryPressureState = .normal
    private var pressureSource: DispatchSourceMemoryPressure?
    private var pauseTimeoutTask: Task<Void, Never>?
    private var isMonitoringSetup = false
    private let contentAnalyzer = ContentAnalyzer()
    private let logger = Logger(subsystem: "com.sorty.app", category: "DirectoryScanner")

    // Configuration
    private var normalBatchSize = 50
    private var pressureBatchSize = 10
    private let enumerationProgressInterval = 1_000
    private let pauseTimeout: Duration = .seconds(30)
    private let duplicateScanBatchSize = 2_048
    private let maximumCompleteSemanticFileCount = 5_000
    /// Deep-content analyses in flight at once during a scan. Content
    /// extraction (OCR, PDF text, EXIF) is I/O- and CPU-bound per file, so a
    /// small bounded TaskGroup keeps all cores busy without the memory spike
    /// of one task per file.
    private let deepScanConcurrencyLimit = 4
    /// Files buffered for concurrent analysis before a flush. Small enough to
    /// keep the deep-scan file budget precise and results near enumeration
    /// order; large enough to keep the 4-wide group saturated.
    private let deepScanFlushThreshold = 8

    /// Lightweight scan descriptor buffered for concurrent content analysis.
    /// FileItem construction stays on the scanner actor after analysis so
    /// ordering and progress accounting match the serial path.
    private struct PendingDeepScan: Sendable {
        let fileURL: URL
        let relativePath: String
        let fileName: String
        let pathExtension: String
        let size: Int64
        let creationDate: Date?
        let modificationDate: Date?
        let lastAccessDate: Date?
        let cloudStatus: CloudFileStatus?
        let finderTags: [String]?
        let finderLabelNumber: Int?
    }

    /// Whether the last scan was degraded due to memory pressure
    private(set) var lastScanWasDegraded = false
    /// Description of degradation that occurred
    private(set) var degradationReason: String?

    /// Callback for deep scan progress updates
    private var deepScanProgressCallback: (@Sendable (_ current: Int, _ total: Int) -> Void)?
    /// Enumeration progress has no stable total until the scan finishes.
    private var scanProgressCallback: (@Sendable (_ current: Int) -> Void)?
    private var deepScanAnalyzedCount = 0

    deinit {
        pressureSource?.cancel()
        pauseTimeoutTask?.cancel()
    }

    /// Memory pressure states for graceful degradation
    public enum MemoryPressureState: String, Sendable {
        case normal = "normal"
        case warning = "warning"
        case critical = "critical"
    }

    /// Initialize and set up memory pressure monitoring
    init() {
        // Setup happens lazily on first scan to avoid actor isolation issues
    }

    func setCustomOCRKeywords(_ keywords: [String]) async {
        await contentAnalyzer.setCustomOCRKeywords(keywords)
    }

    func setOCRLanguages(_ languages: [String]) async {
        await contentAnalyzer.setOCRLanguages(languages)
    }

    /// Scan directory with optional deep content analysis and hash computation
    func scanDirectory(
        at url: URL,
        relativeTo baseDirectoryURL: URL? = nil,
        includeHidden: Bool = false,
        deepScan: Bool = false,
        computeHashes: Bool = false,
        skipCloudPlaceholders: Bool = true,
        deepScanFileLimit: Int? = nil,
        exclusionMatcher: ExclusionMatcher? = nil
    ) async throws -> [FileItem] {
        guard !isScanning else {
            throw ScannerError.alreadyScanning
        }

        isScanning = true
        scannedCount = 0
        cloudPlaceholdersSkipped = 0
        symlinksSkipped = 0
        isPaused = false
        lastScanWasDegraded = false
        degradationReason = nil
        deepScanAnalyzedCount = 0

        // Lazy initialization of memory pressure monitoring
        if !isMonitoringSetup {
            setupMemoryPressureMonitoring()
            isMonitoringSetup = true
        }

        defer {
            isScanning = false
            pauseTimeoutTask?.cancel()
        }

        var files: [FileItem] = []
        let fileManager = FileManager.default

        guard url.isFileURL else {
            throw ScannerError.invalidURL
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ScannerError.pathNotFound
        }
        guard isDirectory.boolValue else {
            throw ScannerError.notDirectory
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw ScannerError.pathNotReadable
        }
        let rootFinderLabelNumber = try? url.resourceValues(
            forKeys: [.labelNumberKey]
        ).labelNumber
        if exclusionMatcher?.shouldPruneDirectory(
            at: url,
            finderLabelNumber: rootFinderLabelNumber
        ) == true {
            return []
        }

        // Check initial memory pressure
        await checkMemoryPressure()

        try await scanDirectoryRecursive(
            at: url,
            relativeTo: baseDirectoryURL ?? url,
            fileManager: fileManager,
            includeHidden: includeHidden,
            deepScan: deepScan,
            computeHashes: computeHashes,
            skipCloudPlaceholders: skipCloudPlaceholders,
            deepScanFileLimit: deepScanFileLimit,
            exclusionMatcher: exclusionMatcher,
            files: &files
        )

        if deepScan {
            await contentAnalyzer.scheduleCacheFlush()
        }

        logger.info(
            "Scan completed: \(self.scannedCount) files, cloud placeholders skipped: \(self.cloudPlaceholdersSkipped), symlinks skipped: \(self.symlinksSkipped), memory pressure: \(self.memoryPressureState.rawValue)"
        )

        return files
    }

    /// Builds a low-memory inventory specifically for duplicate detection.
    ///
    /// The first pass records only file-size frequencies and retains a complete
    /// semantic inventory while it remains safely bounded. Large directories
    /// use a second metadata-only pass that materializes only files whose sizes
    /// occur more than once, so unique files never enter the hashing pipeline.
    /// Small directories (fewer than maximumCompleteSemanticFileCount eligible
    /// files) reuse the lightweight first-pass items directly and skip the
    /// second enumeration entirely.
    func scanDirectoryForDuplicates(
        at url: URL,
        settings: DuplicateSettings,
        includeHidden: Bool = false,
        skipCloudPlaceholders: Bool = true,
        semanticFileLimit: Int? = nil,
        progressHandler: (@MainActor @Sendable (_ scanned: Int, _ stage: String) -> Void)? = nil
    ) async throws -> DuplicateScanInventory {
        guard !isScanning else {
            throw ScannerError.alreadyScanning
        }

        isScanning = true
        scannedCount = 0
        cloudPlaceholdersSkipped = 0
        symlinksSkipped = 0
        isPaused = false
        lastScanWasDegraded = false
        degradationReason = nil

        if !isMonitoringSetup {
            setupMemoryPressureMonitoring()
            isMonitoringSetup = true
        }

        defer {
            isScanning = false
            pauseTimeoutTask?.cancel()
        }

        let fileManager = FileManager.default
        guard url.isFileURL else {
            throw ScannerError.invalidURL
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ScannerError.pathNotFound
        }
        guard isDirectory.boolValue else {
            throw ScannerError.notDirectory
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw ScannerError.pathNotReadable
        }

        await checkMemoryPressure()

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileResourceIdentifierKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden {
            options.insert(.skipsHiddenFiles)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        ) else {
            throw ScannerError.enumerationFailed
        }

        let semanticLimit = max(0, semanticFileLimit ?? maximumCompleteSemanticFileCount)
        let rootPathComponents = Set(
            url.standardizedFileURL.pathComponents.map { $0.lowercased() }
        )
        let isCloudContainer = rootPathComponents.contains("cloudstorage")
            || rootPathComponents.contains("dropbox")
        let duplicateScanFilter = DuplicateScanFilter(settings: settings)
        var singleSizes: Set<Int64> = []
        var duplicateSizes: Set<Int64> = []
        var semanticCandidates: [FileItem] = []
        if settings.includeSemanticDuplicates {
            semanticCandidates.reserveCapacity(min(semanticLimit, 1_024))
        }
        var semanticLimitExceeded = false
        var eligibleFileCount = 0
        var exactCandidateCount = 0
        var unavailableFiles: [UnavailableDuplicateFile] = []
        // Lightweight first-pass items kept only while the eligible set stays
        // small. Small folders then filter these in memory instead of walking
        // the directory tree a second time; large folders drop them and use
        // the metadata-only second pass below.
        var retainedEligibleItems: [FileItem] = []
        retainedEligibleItems.reserveCapacity(1_024)
        // Directory identities already descended into. Symlinked directories
        // are skipped outright, so this only trips on hardlink/bind cycles.
        var visitedDirectoryIDs = Set<String>()
        if let rootID = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]),
           let key = Self.visitedDirectoryKey(for: rootID) {
            visitedDirectoryIDs.insert(key)
        }

        while let fileURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()

            let resourceValues: URLResourceValues
            do {
                resourceValues = try fileURL.resourceValues(forKeys: resourceKeys)
            } catch {
                unavailableFiles.append(
                    UnavailableDuplicateFile(
                        path: fileURL.path,
                        reason: .metadata(error: error, at: fileURL)
                    )
                )
                continue
            }

            // Never follow symlinks: a `ln -s .. A/loop` cycle would otherwise
            // hang the scan, and a dir symlink could escape the scan root.
            if resourceValues.isSymbolicLink == true {
                symlinksSkipped += 1
                if resourceValues.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let enumerationLevel = enumerator.level
            if resourceValues.isDirectory == true {
                if let key = Self.visitedDirectoryKey(for: resourceValues),
                   !visitedDirectoryIDs.insert(key).inserted {
                    enumerator.skipDescendants()
                    continue
                }
                if settings.maxScanDepth >= 0,
                   enumerationLevel > settings.maxScanDepth {
                    enumerator.skipDescendants()
                }
                continue
            }

            let fileDepth = max(0, enumerationLevel - 1)
            if settings.maxScanDepth >= 0, fileDepth > settings.maxScanDepth {
                continue
            }

            let fileSize = Int64(resourceValues.fileSize ?? 0)
            let pathExtension = fileURL.pathExtension
            guard duplicateScanFilter.includes(
                fileSize: fileSize,
                pathExtension: pathExtension,
                displayName: fileURL.lastPathComponent
            ) else {
                continue
            }

            let hasCloudSignals = hasPotentialCloudSignals(
                at: fileURL,
                resourceValues: resourceValues,
                pathExtension: pathExtension,
                pathIsInCloudContainer: isCloudContainer
            )
            if skipCloudPlaceholders && hasCloudSignals && isCloudPlaceholder(at: fileURL) {
                cloudPlaceholdersSkipped += 1
                continue
            }

            eligibleFileCount += 1
            scannedCount = eligibleFileCount

            if eligibleFileCount <= maximumCompleteSemanticFileCount {
                retainedEligibleItems.append(
                    makeDuplicateFileItem(
                        at: fileURL,
                        fileSize: fileSize,
                        resourceValues: resourceValues
                    )
                )
            } else if !retainedEligibleItems.isEmpty {
                retainedEligibleItems.removeAll(keepingCapacity: false)
            }

            if duplicateSizes.contains(fileSize) {
                exactCandidateCount += 1
            } else {
                if singleSizes.remove(fileSize) != nil {
                    duplicateSizes.insert(fileSize)
                    exactCandidateCount += 2
                } else {
                    singleSizes.insert(fileSize)
                }
            }

            if settings.includeSemanticDuplicates, !semanticLimitExceeded {
                if semanticCandidates.count < semanticLimit {
                    semanticCandidates.append(
                        makeDuplicateFileItem(
                            at: fileURL,
                            fileSize: fileSize,
                            resourceValues: resourceValues
                        )
                    )
                } else {
                    semanticCandidates.removeAll(keepingCapacity: false)
                    semanticLimitExceeded = true
                }
            }

            if eligibleFileCount.isMultiple(of: duplicateScanBatchSize) {
                await progressHandler?(eligibleFileCount, "Indexing files...")
                await Task.yield()
                await checkMemoryPressure()
                try await waitIfPaused()
            }
        }

        await progressHandler?(eligibleFileCount, "Preparing duplicate candidates...")
        singleSizes.removeAll(keepingCapacity: false)

        if duplicateSizes.isEmpty {
            return DuplicateScanInventory(
                exactCandidates: [],
                semanticCandidates: semanticCandidates,
                scannedFileCount: eligibleFileCount,
                semanticSkippedFileCount: semanticLimitExceeded ? eligibleFileCount : 0,
                unavailableFiles: unavailableFiles
            )
        }

        if settings.includeSemanticDuplicates, !semanticLimitExceeded {
            return DuplicateScanInventory(
                exactCandidates: semanticCandidates.filter { duplicateSizes.contains($0.size) },
                semanticCandidates: semanticCandidates,
                scannedFileCount: eligibleFileCount,
                semanticSkippedFileCount: 0,
                unavailableFiles: unavailableFiles
            )
        }

        if eligibleFileCount < maximumCompleteSemanticFileCount {
            // Single-pass fast path: every eligible file is already retained
            // above, so filter by duplicate size in memory instead of
            // enumerating the directory tree a second time.
            let exactCandidates = retainedEligibleItems.filter { duplicateSizes.contains($0.size) }
            logger.info(
                "Duplicate inventory completed in a single pass: \(eligibleFileCount) eligible files, \(exactCandidates.count) exact candidates"
            )
            return DuplicateScanInventory(
                exactCandidates: exactCandidates,
                semanticCandidates: [],
                scannedFileCount: eligibleFileCount,
                semanticSkippedFileCount: semanticLimitExceeded ? eligibleFileCount : 0,
                unavailableFiles: unavailableFiles
            )
        }

        guard let candidateEnumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        ) else {
            throw ScannerError.enumerationFailed
        }

        var exactCandidates: [FileItem] = []
        exactCandidates.reserveCapacity(exactCandidateCount)
        var enumeratedFileCount = 0
        var secondPassVisitedDirectoryIDs = visitedDirectoryIDs

        while let fileURL = candidateEnumerator.nextObject() as? URL {
            try Task.checkCancellation()

            guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                continue
            }

            if resourceValues.isSymbolicLink == true {
                symlinksSkipped += 1
                if resourceValues.isDirectory == true {
                    candidateEnumerator.skipDescendants()
                }
                continue
            }

            let enumerationLevel = candidateEnumerator.level
            if resourceValues.isDirectory == true {
                if let key = Self.visitedDirectoryKey(for: resourceValues),
                   !secondPassVisitedDirectoryIDs.insert(key).inserted {
                    candidateEnumerator.skipDescendants()
                    continue
                }
                if settings.maxScanDepth >= 0,
                   enumerationLevel > settings.maxScanDepth {
                    candidateEnumerator.skipDescendants()
                }
                continue
            }

            let fileDepth = max(0, enumerationLevel - 1)
            if settings.maxScanDepth >= 0, fileDepth > settings.maxScanDepth {
                continue
            }

            enumeratedFileCount += 1
            if enumeratedFileCount.isMultiple(of: duplicateScanBatchSize) {
                await progressHandler?(
                    exactCandidates.count,
                    "Collecting duplicate candidates..."
                )
                await Task.yield()
                await checkMemoryPressure()
                try await waitIfPaused()
            }

            let fileSize = Int64(resourceValues.fileSize ?? 0)
            guard duplicateSizes.contains(fileSize) else {
                continue
            }

            let pathExtension = fileURL.pathExtension
            guard duplicateScanFilter.includes(
                fileSize: fileSize,
                pathExtension: pathExtension,
                displayName: fileURL.lastPathComponent
            ) else {
                continue
            }

            let hasCloudSignals = hasPotentialCloudSignals(
                at: fileURL,
                resourceValues: resourceValues,
                pathExtension: pathExtension,
                pathIsInCloudContainer: isCloudContainer
            )
            if skipCloudPlaceholders && hasCloudSignals && isCloudPlaceholder(at: fileURL) {
                continue
            }

            exactCandidates.append(
                makeDuplicateFileItem(
                    at: fileURL,
                    fileSize: fileSize,
                    resourceValues: resourceValues
                )
            )
        }

        let skippedSymlinks = self.symlinksSkipped
        logger.info(
            "Duplicate inventory completed: \(eligibleFileCount) eligible files, \(exactCandidates.count) exact candidates, symlinks skipped: \(skippedSymlinks)"
        )

        return DuplicateScanInventory(
            exactCandidates: exactCandidates,
            semanticCandidates: [],
            scannedFileCount: eligibleFileCount,
            semanticSkippedFileCount: semanticLimitExceeded ? eligibleFileCount : 0,
            unavailableFiles: unavailableFiles
        )
    }

    /// Scan a single file and return a FileItem
    func scanFile(
        at url: URL,
        relativeTo baseDirectoryURL: URL? = nil,
        deepScan: Bool = false,
        computeHashes: Bool = false,
        skipCloudPlaceholders: Bool = true,
        exclusionMatcher: ExclusionMatcher? = nil
    ) async throws -> FileItem {
        let fileManager = FileManager.default

        guard url.isFileURL else {
            throw ScannerError.invalidURL
        }

        guard fileManager.fileExists(atPath: url.path) else {
            throw ScannerError.pathNotFound
        }

        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .creationDateKey, .isHiddenKey,
            .contentModificationDateKey, .contentAccessDateKey, .tagNamesKey,
            .labelNumberKey,
        ]
        let resourceValues = try? url.resourceValues(forKeys: Set(resourceKeys))

        let isDirectory = resourceValues?.isDirectory ?? false
        let size = resourceValues?.fileSize ?? 0
        let creationDate = resourceValues?.creationDate
        let modificationDate = resourceValues?.contentModificationDate
        let lastAccessDate = resourceValues?.contentAccessDate
        let finderTags = resourceValues?.tagNames
        let finderLabelNumber = resourceValues?.labelNumber

        let pathExtension = url.pathExtension
        let fileName = url.deletingPathExtension().lastPathComponent

        if exclusionMatcher?.shouldExcludeFile(
            at: url,
            size: Int64(size),
            creationDate: creationDate,
            modificationDate: modificationDate,
            finderLabelNumber: finderLabelNumber
        ) == true {
            throw ScannerError.excluded
        }

        let hasCloudSignals = hasPotentialCloudSignals(
            at: url,
            resourceValues: resourceValues,
            pathExtension: pathExtension
        )
        if skipCloudPlaceholders && hasCloudSignals && isCloudPlaceholder(at: url) {
            throw ScannerError.cloudPlaceholder
        }
        let cloudStatus = hasCloudSignals ? detectCloudStatus(at: url) : nil

        // Read Finder comment via extended attribute (tagged subset only;
        // untagged files skip the per-file xattr round-trip).
        let finderComment = Self.finderCommentIfTagged(
            at: url,
            finderTags: finderTags,
            finderLabelNumber: finderLabelNumber
        )

        // Deep scan: extract content metadata
        var contentMetadata: ContentMetadata?
        if deepScan {
            contentMetadata = await contentAnalyzer.analyze(fileURL: url)
        }

        let extractedOCRText = contentMetadata?.ocrText
        let extractedDimensions = Self.extractImageDimensions(from: contentMetadata)

        // Hash computation for duplicate detection
        var sha256Hash: String?
        if computeHashes {
            sha256Hash = HashUtility.computeSHA256(for: url)
        }

        return FileItem(
            path: url.path,
            relativePath: baseDirectoryURL.map { Self.relativePath(for: url, under: $0) },
            name: fileName,
            extension: pathExtension,
            size: Int64(size),
            isDirectory: isDirectory,
            creationDate: creationDate,
            modificationDate: modificationDate,
            lastAccessDate: lastAccessDate,
            contentMetadata: contentMetadata,
            sha256Hash: sha256Hash,
            ocrText: extractedOCRText,
            imageWidth: extractedDimensions?.width,
            imageHeight: extractedDimensions?.height,
            cloudStatus: cloudStatus,
            finderComment: finderComment,
            finderTags: finderTags,
            finderLabelNumber: finderLabelNumber
        )
    }

    /// Stable identity for a visited directory, used to break enumeration
    /// cycles. Symlinks are skipped outright (see below), so this is a second
    /// line of defense against hardlinked or bind-mounted directory loops.
    private static func visitedDirectoryKey(for resourceValues: URLResourceValues) -> String? {
        guard let identifier = resourceValues.fileResourceIdentifier else { return nil }
        return String(describing: identifier)
    }

    private func makeDuplicateFileItem(
        at url: URL,
        fileSize: Int64,
        resourceValues: URLResourceValues
    ) -> FileItem {
        FileItem(
            path: url.path,
            name: url.deletingPathExtension().lastPathComponent,
            extension: url.pathExtension,
            size: fileSize,
            isDirectory: false,
            creationDate: resourceValues.creationDate,
            modificationDate: resourceValues.contentModificationDate
        )
    }

    private func scanDirectoryRecursive(
        at url: URL,
        relativeTo baseDirectoryURL: URL,
        fileManager: FileManager,
        includeHidden: Bool,
        deepScan: Bool,
        computeHashes: Bool,
        skipCloudPlaceholders: Bool,
        deepScanFileLimit: Int?,
        exclusionMatcher: ExclusionMatcher?,
        files: inout [FileItem]
    ) async throws {
        let cloudResourceKeys: [URLResourceKey] = [
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        let resourceKeys: [URLResourceKey] =
            [
                .isDirectoryKey, .isSymbolicLinkKey, .fileResourceIdentifierKey,
                .fileSizeKey, .creationDateKey, .isHiddenKey,
                .contentModificationDateKey, .contentAccessDateKey, .tagNamesKey,
                .labelNumberKey,
            ] + cloudResourceKeys

        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden {
            options.insert(.skipsHiddenFiles)
        }

        try Task.checkCancellation()

        guard
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: resourceKeys,
                options: options
            )
        else {
            throw ScannerError.enumerationFailed
        }

        // Graceful degradation: skip non-essential work under memory pressure
        let effectiveDeepScan = deepScan && !shouldSkipNonEssentialWork()
        let effectiveComputeHashes = computeHashes && !shouldSkipNonEssentialWork()

        if deepScan && !effectiveDeepScan {
            lastScanWasDegraded = true
            degradationReason = "Deep content analysis was skipped due to high memory usage"
            logger.info("Deep scan disabled due to memory pressure")
        }
        if computeHashes && !effectiveComputeHashes {
            lastScanWasDegraded = true
            if degradationReason == nil {
                degradationReason = "File hash computation was skipped due to high memory usage"
            }
            logger.info("Hash computation disabled due to memory pressure")
        }

        var visitedDirectoryIDs = Set<String>()
        if let rootID = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]),
           let key = Self.visitedDirectoryKey(for: rootID) {
            visitedDirectoryIDs.insert(key)
        }

        // Files awaiting concurrent content analysis. Buffering keeps the
        // 4-wide TaskGroup saturated while FileItem construction (and its
        // progress accounting) stays ordered on this actor.
        var pendingAnalyses: [PendingDeepScan] = []
        pendingAnalyses.reserveCapacity(deepScanFlushThreshold)

        while let fileURL = enumerator.nextObject() as? URL {
            // Check and wait if paused due to memory pressure
            try await waitIfPaused()
            try Task.checkCancellation()

            // Get file attributes. The enumerator already skips hidden files when requested,
            // so avoid an extra per-file resource lookup for large directories.
            let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys))

            // Never follow symlinks: breaks `ln -s .. A/loop` cycles and keeps
            // directory symlinks from escaping the scan root.
            if resourceValues?.isSymbolicLink == true {
                symlinksSkipped += 1
                if resourceValues?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let isDirectory = resourceValues?.isDirectory ?? false
            let size = resourceValues?.fileSize ?? 0
            let creationDate = resourceValues?.creationDate
            let modificationDate = resourceValues?.contentModificationDate
            let lastAccessDate = resourceValues?.contentAccessDate
            let finderTags = resourceValues?.tagNames
            let finderLabelNumber = resourceValues?.labelNumber

            if isDirectory {
                if let values = resourceValues,
                   let key = Self.visitedDirectoryKey(for: values),
                   !visitedDirectoryIDs.insert(key).inserted {
                    enumerator.skipDescendants()
                    continue
                }
                if exclusionMatcher?.shouldPruneDirectory(
                    at: fileURL,
                    finderLabelNumber: finderLabelNumber
                ) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let pathExtension = fileURL.pathExtension
            let fileName = fileURL.deletingPathExtension().lastPathComponent

            // Reject excluded files before cloud xattrs, OCR, image analysis,
            // hashing, and FileItem retention.
            if exclusionMatcher?.shouldExcludeFile(
                at: fileURL,
                size: Int64(size),
                creationDate: creationDate,
                modificationDate: modificationDate,
                finderLabelNumber: finderLabelNumber
            ) == true {
                continue
            }

            let hasCloudSignals = hasPotentialCloudSignals(
                at: fileURL,
                resourceValues: resourceValues,
                pathExtension: pathExtension
            )

            // Cloud placeholder detection can require xattr checks, so only run it
            // when the path or prefetched resource values indicate cloud storage.
            if skipCloudPlaceholders && hasCloudSignals && isCloudPlaceholder(at: fileURL) {
                let provider = cloudProviderName(for: fileURL) ?? "Unknown"
                logger.debug(
                    "Skipping cloud placeholder (\(provider)): \(fileURL.lastPathComponent)")
                cloudPlaceholdersSkipped += 1
                continue
            }

            // Determine cloud status for the file
            let cloudStatus = hasCloudSignals ? detectCloudStatus(at: fileURL) : nil

            // Deep scan: buffer for concurrent content analysis (flushed in
            // bounded 4-wide TaskGroups below). Files outside the deep-scan
            // budget or with analysis disabled build their FileItem inline.
            let isWithinDeepScanBudget = deepScanFileLimit.map {
                deepScanAnalyzedCount + pendingAnalyses.count < max(0, $0)
            } ?? true
            if effectiveDeepScan && isWithinDeepScanBudget {
                pendingAnalyses.append(PendingDeepScan(
                    fileURL: fileURL,
                    relativePath: Self.relativePath(for: fileURL, under: baseDirectoryURL),
                    fileName: fileName,
                    pathExtension: pathExtension,
                    size: Int64(size),
                    creationDate: creationDate,
                    modificationDate: modificationDate,
                    lastAccessDate: lastAccessDate,
                    cloudStatus: cloudStatus,
                    finderTags: finderTags,
                    finderLabelNumber: finderLabelNumber
                ))
                if pendingAnalyses.count >= deepScanFlushThreshold {
                    try await flushPendingDeepScans(
                        &pendingAnalyses,
                        effectiveComputeHashes: effectiveComputeHashes,
                        files: &files
                    )
                }
            } else {
                if effectiveDeepScan && !isWithinDeepScanBudget && degradationReason == nil {
                    lastScanWasDegraded = true
                    degradationReason =
                        "Deep content analysis was limited to \(deepScanAnalyzedCount) files to keep this large folder responsive"
                }
                appendScannedFile(
                    to: &files,
                    fileURL: fileURL,
                    relativePath: Self.relativePath(for: fileURL, under: baseDirectoryURL),
                    fileName: fileName,
                    pathExtension: pathExtension,
                    size: size,
                    creationDate: creationDate,
                    modificationDate: modificationDate,
                    lastAccessDate: lastAccessDate,
                    cloudStatus: cloudStatus,
                    finderTags: finderTags,
                    finderLabelNumber: finderLabelNumber,
                    contentMetadata: nil,
                    effectiveComputeHashes: effectiveComputeHashes
                )
                await reportScanProgressIfNeeded()
            }
        }

        try await flushPendingDeepScans(
            &pendingAnalyses,
            effectiveComputeHashes: effectiveComputeHashes,
            files: &files
        )

        scanProgressCallback?(scannedCount)

        // Final memory state logging
        if memoryPressureState != .normal {
            logger.info("Scan completed under memory pressure: \(self.scannedCount) files total")
        }
    }

    /// Analyzes buffered files concurrently (bounded 4-wide, utility priority)
    /// and appends their FileItems in enumeration order. Progress and budget
    /// accounting mirror the old serial path; only the analysis itself runs
    /// off the enumeration critical path.
    private func flushPendingDeepScans(
        _ pending: inout [PendingDeepScan],
        effectiveComputeHashes: Bool,
        files: inout [FileItem]
    ) async throws {
        guard !pending.isEmpty else { return }
        try Task.checkCancellation()
        let batch = pending
        pending.removeAll(keepingCapacity: true)

        let analyzer = contentAnalyzer
        var orderedMetadata: [ContentMetadata?] = Array(repeating: nil, count: batch.count)
        await withTaskGroup(of: (Int, ContentMetadata?).self) { group in
            var iterator = batch.indices.makeIterator()
            for _ in 0..<min(deepScanConcurrencyLimit, batch.count) {
                guard let index = iterator.next() else { break }
                let url = batch[index].fileURL
                group.addTask(priority: .utility) {
                    let metadata = await analyzer.analyze(fileURL: url)
                    return (index, metadata)
                }
            }
            for await (index, metadata) in group {
                orderedMetadata[index] = metadata
                if Task.isCancelled {
                    group.cancelAll()
                } else if let nextIndex = iterator.next() {
                    let url = batch[nextIndex].fileURL
                    group.addTask(priority: .utility) {
                        let nextMetadata = await analyzer.analyze(fileURL: url)
                        return (nextIndex, nextMetadata)
                    }
                }
            }
        }

        for (index, descriptor) in batch.enumerated() {
            try Task.checkCancellation()
            deepScanAnalyzedCount += 1
            deepScanProgressCallback?(deepScanAnalyzedCount, 0)
            appendScannedFile(
                to: &files,
                fileURL: descriptor.fileURL,
                relativePath: descriptor.relativePath,
                fileName: descriptor.fileName,
                pathExtension: descriptor.pathExtension,
                size: Int(descriptor.size),
                creationDate: descriptor.creationDate,
                modificationDate: descriptor.modificationDate,
                lastAccessDate: descriptor.lastAccessDate,
                cloudStatus: descriptor.cloudStatus,
                finderTags: descriptor.finderTags,
                finderLabelNumber: descriptor.finderLabelNumber,
                contentMetadata: orderedMetadata[index],
                effectiveComputeHashes: effectiveComputeHashes
            )
            await reportScanProgressIfNeeded()
        }
    }

    /// Builds one scanned FileItem and advances the enumeration count.
    /// Shared by the inline (no-analysis) path and the concurrent flush so
    /// both produce identical items.
    private func appendScannedFile(
        to files: inout [FileItem],
        fileURL: URL,
        relativePath: String,
        fileName: String,
        pathExtension: String,
        size: Int,
        creationDate: Date?,
        modificationDate: Date?,
        lastAccessDate: Date?,
        cloudStatus: CloudFileStatus?,
        finderTags: [String]?,
        finderLabelNumber: Int?,
        contentMetadata: ContentMetadata?,
        effectiveComputeHashes: Bool
    ) {
        let finderComment = Self.finderCommentIfTagged(
            at: fileURL,
            finderTags: finderTags,
            finderLabelNumber: finderLabelNumber
        )
        let extractedOCRText = contentMetadata?.ocrText
        let extractedDimensions = Self.extractImageDimensions(from: contentMetadata)

        // Hash computation for duplicate detection (skipped under memory pressure)
        var sha256Hash: String?
        if effectiveComputeHashes {
            sha256Hash = HashUtility.computeSHA256(for: fileURL)
        }

        files.append(FileItem(
            path: fileURL.path,
            relativePath: relativePath,
            name: fileName,
            extension: pathExtension,
            size: Int64(size),
            isDirectory: false,
            creationDate: creationDate,
            modificationDate: modificationDate,
            lastAccessDate: lastAccessDate,
            contentMetadata: contentMetadata,
            sha256Hash: sha256Hash,
            ocrText: extractedOCRText,
            imageWidth: extractedDimensions?.width,
            imageHeight: extractedDimensions?.height,
            cloudStatus: cloudStatus,
            finderComment: finderComment,
            finderTags: finderTags,
            finderLabelNumber: finderLabelNumber
        ))
        scannedCount += 1
    }

    /// Yield in small batches, but avoid a task_info syscall and progress
    /// publication for every batch. The memory-pressure dispatch source
    /// still handles urgent pressure changes immediately.
    private func reportScanProgressIfNeeded() async {
        if scannedCount.isMultiple(of: getCurrentBatchSize()) {
            await Task.yield()

            if scannedCount.isMultiple(of: enumerationProgressInterval) {
                scanProgressCallback?(scannedCount)
                await checkMemoryPressure()
                if memoryPressureState != .normal {
                    logger.info(
                        "Scan progress: \(self.scannedCount) files, pressure: \(self.memoryPressureState.rawValue)"
                    )
                }
            }
        }
    }

    /// Reads the Finder comment xattr only for the tagged subset. The xattr
    /// round-trip costs a syscall per file; untagged files almost never carry
    /// comments the planner would consult, so they skip it.
    private static func finderCommentIfTagged(
        at url: URL,
        finderTags: [String]?,
        finderLabelNumber: Int?
    ) -> String? {
        let hasTags = finderTags?.isEmpty == false
        let hasLabel = (finderLabelNumber ?? 0) != 0
        guard hasTags || hasLabel else { return nil }
        return url.finderComment
    }

    func setDeepScanProgressCallback(
        _ callback: (@Sendable (_ current: Int, _ total: Int) -> Void)?
    ) {
        deepScanProgressCallback = callback
    }

    func setScanProgressCallback(
        _ callback: (@Sendable (_ current: Int) -> Void)?
    ) {
        scanProgressCallback = callback
    }

    // MARK: - Finder Metadata

    private static func relativePath(for itemURL: URL, under baseDirectoryURL: URL) -> String {
        let itemPath = itemURL.standardizedFileURL.path
        let basePath = baseDirectoryURL.standardizedFileURL.path
        guard itemPath.hasPrefix(basePath + "/") else {
            return itemURL.lastPathComponent
        }
        return String(itemPath.dropFirst(basePath.count + 1))
    }

    private static func extractImageDimensions(from metadata: ContentMetadata?) -> (
        width: Int, height: Int
    )? {
        guard let dimensionsString = metadata?.exifData?["dimensions"] else {
            return nil
        }

        let parts = dimensionsString.split(separator: "x", maxSplits: 1).map(String.init)
        guard parts.count == 2,
            let width = Int(parts[0]),
            let height = Int(parts[1])
        else {
            return nil
        }

        return (width, height)
    }

    // MARK: - Cloud Storage Detection

    private func hasPotentialCloudSignals(
        at url: URL,
        resourceValues: URLResourceValues?,
        pathExtension: String,
        pathIsInCloudContainer: Bool? = nil
    ) -> Bool {
        if resourceValues?.ubiquitousItemDownloadingStatus != nil
            || resourceValues?.ubiquitousItemIsDownloading == true
        {
            return true
        }

        let lowercasedExtension = pathExtension.lowercased()
        if lowercasedExtension == "icloud" || lowercasedExtension == "cloud"
            || googleDriveNativeExtensions.contains(lowercasedExtension)
        {
            return true
        }

        if let pathIsInCloudContainer {
            return pathIsInCloudContainer
        }

        let pathComponents = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
        return pathComponents.contains("cloudstorage") || pathComponents.contains("dropbox")
    }

    private func isCloudPlaceholder(at url: URL) -> Bool {
        // iCloud: check ubiquitous item download status
        if let resourceValues = try? url.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
        ]) {
            if let status = resourceValues.ubiquitousItemDownloadingStatus,
                status == .notDownloaded
            {
                return true
            }
        }

        // iCloud: .icloud wrapper file (e.g., ".Document.icloud")
        let fileName = url.lastPathComponent
        if fileName.hasPrefix(".") && url.pathExtension == "icloud" {
            return true
        }

        // Google Drive exposes cloud-native Docs, Sheets, and Slides as small
        // local files. They can be moved in Finder and should be organized.

        // Dropbox: check for extended attribute or zero-size placeholder
        let path = url.path
        let xattrLength = getxattr(path, "com.dropbox.attrs", nil, 0, 0, 0)
        if xattrLength > 0 {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            if size == 0 {
                return true
            }
        }

        // OneDrive: check for .cloud file or zero-byte placeholder with attributes
        if url.pathExtension == "cloud" {
            return true
        }

        return false
    }

    private func cloudProviderName(for url: URL) -> String? {
        // iCloud detection
        if let resourceValues = try? url.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey
        ]) {
            if resourceValues.ubiquitousItemDownloadingStatus != nil {
                return "iCloud"
            }
        }
        let fileName = url.lastPathComponent
        if fileName.hasPrefix(".") && url.pathExtension == "icloud" {
            return "iCloud"
        }

        let pathComponents = Set(url.standardizedFileURL.pathComponents.map { $0.lowercased() })
        if pathComponents.contains("cloudstorage") {
            if let provider = fileProviderName(for: url) {
                return provider
            }
            return "Cloud Storage"
        }

        if googleDriveNativeExtensions.contains(url.pathExtension.lowercased()) {
            return "Google Drive"
        }

        // Dropbox extended attribute
        let xattrLength = getxattr(url.path, "com.dropbox.attrs", nil, 0, 0, 0)
        if xattrLength > 0 {
            return "Dropbox"
        }

        // OneDrive
        if url.pathExtension == "cloud" {
            return "OneDrive"
        }

        return nil
    }

    private func detectCloudStatus(at url: URL) -> CloudFileStatus? {
        if let resourceValues = try? url.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
        ]) {
            if let isDownloading = resourceValues.ubiquitousItemIsDownloading, isDownloading {
                return .downloading
            }
            if let status = resourceValues.ubiquitousItemDownloadingStatus {
                switch status {
                case .notDownloaded:
                    return .cloudOnly
                case .downloaded, .current:
                    return .synced
                default:
                    break
                }
            }
        }

        let fileName = url.lastPathComponent
        if fileName.hasPrefix(".") && url.pathExtension == "icloud" {
            return .cloudOnly
        }

        if googleDriveNativeExtensions.contains(url.pathExtension.lowercased()) {
            return .synced
        }

        let xattrLength = getxattr(url.path, "com.dropbox.attrs", nil, 0, 0, 0)
        if xattrLength > 0 {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            if size == 0 {
                return .cloudOnly
            }
            return .synced
        }

        if url.pathExtension == "cloud" {
            return .cloudOnly
        }

        if cloudProviderName(for: url) != nil {
            return .synced
        }

        return nil
    }

    private var googleDriveNativeExtensions: Set<String> {
        ["gdoc", "gsheet", "gslides", "gdraw", "gform", "gmap", "gsite", "jam"]
    }

    private func fileProviderName(for url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        guard
            let cloudStorageIndex = components.firstIndex(where: {
                $0.caseInsensitiveCompare("CloudStorage") == .orderedSame
            }),
            components.indices.contains(cloudStorageIndex + 1)
        else {
            return nil
        }

        let providerFolder = components[cloudStorageIndex + 1].lowercased()
        if providerFolder.contains("googledrive") || providerFolder.contains("google drive") {
            return "Google Drive"
        }
        if providerFolder.contains("onedrive") || providerFolder.contains("one drive") {
            return "OneDrive"
        }
        if providerFolder.contains("dropbox") {
            return "Dropbox"
        }
        if providerFolder.contains("box") {
            return "Box"
        }
        if providerFolder.contains("icloud") {
            return "iCloud"
        }

        return nil
    }

    // MARK: - Memory Pressure Handling

    private func setupMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: DispatchQueue.global())

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            Task { await self.handleMemoryPressureEvent() }
        }

        pressureSource = source
        source.resume()
        logger.debug("Memory pressure monitoring initialized")
    }

    private func handleMemoryPressureEvent() async {
        let eventMask = pressureSource?.data ?? []

        if eventMask.contains(.critical) {
            await setMemoryPressureState(.critical)
        } else if eventMask.contains(.warning) {
            await setMemoryPressureState(.warning)
        }
    }

    private func setMemoryPressureState(_ state: MemoryPressureState) async {
        let previousState = memoryPressureState
        memoryPressureState = state

        if state != previousState {
            logger.warning(
                "Memory pressure changed: \(previousState.rawValue) -> \(state.rawValue)")

            switch state {
            case .warning:
                isPaused = true
                startPauseTimeout()
                logger.info("Scan paused due to memory warning")
            case .critical:
                isPaused = true
                // Clear caches immediately
                await contentAnalyzer.clearCache()
                logger.warning("Scan paused, caches cleared due to critical memory pressure")
            case .normal:
                isPaused = false
                pauseTimeoutTask?.cancel()
                logger.info("Scan resumed, memory pressure normal")
            }
        }
    }

    private func checkMemoryPressure() async {
        // Check physical memory availability
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let usedMemory = getCurrentMemoryUsage()
        let memoryPressure = Double(usedMemory) / Double(physicalMemory)

        if memoryPressure > 0.85 {
            await setMemoryPressureState(.critical)
        } else if memoryPressure > 0.70 {
            await setMemoryPressureState(.warning)
        } else {
            await setMemoryPressureState(.normal)
        }
    }

    private func getCurrentMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count)
            }
        }

        guard kerr == KERN_SUCCESS else {
            return 0
        }

        return info.resident_size
    }

    private func startPauseTimeout() {
        pauseTimeoutTask?.cancel()
        pauseTimeoutTask = Task {
            try? await Task.sleep(for: pauseTimeout)

            guard !Task.isCancelled else { return }

            // Force resume after timeout
            if isPaused && isScanning {
                logger.warning("Pause timeout reached, forcing resume")
                isPaused = false
                memoryPressureState = .normal
            }
        }
    }

    private func shouldSkipNonEssentialWork() -> Bool {
        memoryPressureState == .warning || memoryPressureState == .critical
    }

    private func getCurrentBatchSize() -> Int {
        switch memoryPressureState {
        case .normal:
            return normalBatchSize
        case .warning, .critical:
            return pressureBatchSize
        }
    }

    private func waitIfPaused() async throws {
        while isPaused && isScanning {
            try Task.checkCancellation()
            await Task.yield()
            await checkMemoryPressure()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

enum ScannerError: LocalizedError {
    case alreadyScanning
    case invalidURL
    case pathNotFound
    case notDirectory
    case pathNotReadable
    case cloudPlaceholder
    case excluded
    case enumerationFailed

    var errorDescription: String? {
        switch self {
        case .alreadyScanning:
            return "A scan is already in progress"
        case .invalidURL:
            return "Invalid URL provided"
        case .pathNotFound:
            return "The specified path does not exist"
        case .notDirectory:
            return "The specified scan location is not a directory"
        case .pathNotReadable:
            return "The specified scan location is not readable"
        case .cloudPlaceholder:
            return "The cloud file is not available locally"
        case .excluded:
            return "The file is excluded by the current rules"
        case .enumerationFailed:
            return "Failed to enumerate directory contents"
        }
    }
}
