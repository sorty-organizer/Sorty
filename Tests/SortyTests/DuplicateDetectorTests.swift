
import XCTest
import Darwin
@testable import SortyLib
@testable import SortyCore
@testable import SortyFileSystem

class DuplicateDetectorTests: XCTestCase {
    
    var detector: DuplicateDetector!
    
    override func setUp() {
        super.setUp()
        detector = DuplicateDetector()
    }
    
    func testLargeUniqueSizeInventoryAvoidsHashWork() async {
        let files = (0..<100_000).map { index in
            FileItem(
                path: "/virtual/\(index).bin",
                name: "\(index)",
                extension: "bin",
                size: Int64(index + 1)
            )
        }

        let result = await detector.findExactDuplicates(in: files)

        XCTAssertEqual(result.candidateCount, 0)
        XCTAssertEqual(result.sampledCount, 0)
        XCTAssertEqual(result.hashedCount, 0)
        XCTAssertTrue(result.groups.isEmpty)
    }

    func testLargeFilesUseSamplesBeforeFullHashing() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("DuplicateSampleTests-\(UUID().uuidString)", isDirectory: true)
        let originalURL = directory.appendingPathComponent("original.bin")
        let copyURL = directory.appendingPathComponent("copy.bin")
        let differentURL = directory.appendingPathComponent("different.bin")

        defer {
            try? fileManager.removeItem(at: directory)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let duplicateData = Data(repeating: 0x41, count: 256 * 1_024)
        try duplicateData.write(to: originalURL)
        try duplicateData.write(to: copyURL)
        try Data(repeating: 0x42, count: duplicateData.count).write(to: differentURL)

        let files = [originalURL, copyURL, differentURL].map { url in
            FileItem(
                path: url.path,
                name: url.deletingPathExtension().lastPathComponent,
                extension: "bin",
                size: Int64(duplicateData.count)
            )
        }

        let result = await detector.findExactDuplicates(in: files)

        XCTAssertEqual(result.candidateCount, 3)
        XCTAssertEqual(result.sampledCount, 3)
        XCTAssertEqual(result.hashedCount, 2)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups.first?.files.count, 2)
    }

    func testStreamingHashStopsAfterCancellation() async throws {
        let fileManager = FileManager.default
        let fileURL = fileManager.temporaryDirectory
            .appendingPathComponent("DuplicateCancellationTests-\(UUID().uuidString).bin")

        defer {
            try? fileManager.removeItem(at: fileURL)
        }

        try Data(repeating: 0x5A, count: 16 * 1_024 * 1_024).write(to: fileURL)
        let hashTask = Task(priority: .utility) {
            HashUtility.computeSHA256(for: fileURL)
        }
        hashTask.cancel()

        let hash = await hashTask.value

        XCTAssertNil(hash)
    }

    func testDuplicateInventoryHonorsDepthWithoutRetainingUniqueFiles() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("DuplicateInventoryTests-\(UUID().uuidString)", isDirectory: true)
        let nestedDirectory = directory.appendingPathComponent("Nested", isDirectory: true)

        defer {
            try? fileManager.removeItem(at: directory)
        }

        try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data("same".utf8).write(to: directory.appendingPathComponent("first.txt"))
        try Data("same".utf8).write(to: directory.appendingPathComponent("second.txt"))
        try Data("same".utf8).write(to: nestedDirectory.appendingPathComponent("third.txt"))

        var settings = DuplicateSettings()
        settings.maxScanDepth = 0
        settings.includeSemanticDuplicates = false
        let scanner = DirectoryScanner()

        let inventory = try await scanner.scanDirectoryForDuplicates(
            at: directory,
            settings: settings
        )

        XCTAssertEqual(inventory.scannedFileCount, 2)
        XCTAssertEqual(inventory.exactCandidates.count, 2)
        XCTAssertTrue(inventory.exactCandidates.allSatisfy { $0.fileSystemIdentity != nil })
        XCTAssertTrue(inventory.semanticCandidates.isEmpty)
    }

    func testDuplicateInventorySecondPassScansDirectoriesSeenInFirstPass() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("DuplicateSecondPassTests-\(UUID().uuidString)", isDirectory: true)
        let nestedDirectory = directory.appendingPathComponent("Nested", isDirectory: true)

        defer {
            try? fileManager.removeItem(at: directory)
        }

        try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data("same-content".utf8).write(to: nestedDirectory.appendingPathComponent("first.txt"))
        try Data("same-content".utf8).write(to: nestedDirectory.appendingPathComponent("second.txt"))

        var settings = DuplicateSettings()
        settings.includeSemanticDuplicates = true
        let inventory = try await DirectoryScanner().scanDirectoryForDuplicates(
            at: directory,
            settings: settings,
            semanticFileLimit: 0
        )

        XCTAssertEqual(inventory.exactCandidates.count, 2)
        XCTAssertEqual(
            Set(inventory.exactCandidates.map {
                URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path
            }),
            Set(["first.txt", "second.txt"].map {
                nestedDirectory.appendingPathComponent($0).resolvingSymlinksInPath().standardizedFileURL.path
            })
        )
    }

    func testDuplicateInventorySkipsUnboundedSemanticAnalysis() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("DuplicateSemanticLimitTests-\(UUID().uuidString)", isDirectory: true)

        defer {
            try? fileManager.removeItem(at: directory)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<3 {
            try Data("file-\(index)".utf8).write(
                to: directory.appendingPathComponent("\(index).txt")
            )
        }

        let scanner = DirectoryScanner()
        let inventory = try await scanner.scanDirectoryForDuplicates(
            at: directory,
            settings: DuplicateSettings(),
            semanticFileLimit: 2
        )

        XCTAssertEqual(inventory.scannedFileCount, 3)
        XCTAssertEqual(inventory.semanticSkippedFileCount, 3)
        XCTAssertTrue(inventory.semanticCandidates.isEmpty)
    }

    @MainActor
    func testManagerCompletesEmptyScanWithoutInvalidProgress() async {
        let manager = DuplicateDetectionManager()

        await manager.scanForDuplicates(files: [], settings: DuplicateSettings())

        XCTAssertEqual(manager.state, .completed(count: 0))
        XCTAssertEqual(manager.scanProgress, 1.0)
        XCTAssertFalse(manager.isScanning)
        XCTAssertTrue(manager.duplicateGroups.isEmpty)
        XCTAssertTrue(manager.semanticGroups.isEmpty)
    }

    @MainActor
    func testCancelledManagerScanDoesNotReplaceExistingResults() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("DuplicateCancelledManagerScan-\(UUID().uuidString)", isDirectory: true)
        let firstURL = directory.appendingPathComponent("first.txt")
        let secondURL = directory.appendingPathComponent("second.txt")

        defer {
            try? fileManager.removeItem(at: directory)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("same".utf8).write(to: firstURL)
        try Data("same".utf8).write(to: secondURL)
        let files = [firstURL, secondURL].map {
            FileItem(path: $0.path, name: $0.lastPathComponent, extension: "txt", size: 4)
        }
        var settings = DuplicateSettings()
        settings.includeSemanticDuplicates = false
        let manager = DuplicateDetectionManager()
        await manager.scanForDuplicates(files: files, settings: settings)
        let originalGroupID = try XCTUnwrap(manager.duplicateGroups.first?.id)

        let cancelledScan = Task { @MainActor in
            await manager.scanForDuplicates(files: [], settings: settings)
        }
        cancelledScan.cancel()
        await cancelledScan.value

        XCTAssertEqual(manager.duplicateGroups.map(\.id), [originalGroupID])
    }

    @MainActor
    func testManagerRequiresMatchingContentEvenWhenFastModeIsSelected() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("DuplicateExactnessTests-\(UUID().uuidString)", isDirectory: true)
        let firstURL = directory.appendingPathComponent("First/report.txt")
        let secondURL = directory.appendingPathComponent("Second/report.txt")

        defer {
            try? fileManager.removeItem(at: directory)
        }

        try fileManager.createDirectory(
            at: firstURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: secondURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("ABCD".utf8).write(to: firstURL)
        try Data("WXYZ".utf8).write(to: secondURL)

        let timestamp = Date()
        let files = [
            FileItem(
                path: firstURL.path,
                name: "report",
                extension: "txt",
                size: 4,
                modificationDate: timestamp
            ),
            FileItem(
                path: secondURL.path,
                name: "report",
                extension: "txt",
                size: 4,
                modificationDate: timestamp
            )
        ]
        var settings = DuplicateSettings()
        settings.comparisonMethod = .fast
        settings.includeSemanticDuplicates = false
        let manager = DuplicateDetectionManager()

        await manager.scanForDuplicates(files: files, settings: settings)

        XCTAssertTrue(manager.duplicateGroups.isEmpty)
        XCTAssertEqual(manager.hashCandidateCount, 2)
        XCTAssertEqual(manager.hashedFileCount, 2)
    }

    @MainActor
    func testManagerGroupsAllExactCopiesAndReusesCachedHashes() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("DuplicateGroupingTests-\(UUID().uuidString)", isDirectory: true)
        let exactURLs = [
            directory.appendingPathComponent("original.txt"),
            directory.appendingPathComponent("renamed-copy.txt"),
            directory.appendingPathComponent("Nested/another-name.txt")
        ]
        let uniqueURL = directory.appendingPathComponent("unique.txt")

        defer {
            try? fileManager.removeItem(at: directory)
        }

        for url in exactURLs {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("same-content".utf8).write(to: url)
        }
        try Data("unique".utf8).write(to: uniqueURL)

        let timestamp = Date()
        let files = exactURLs.enumerated().map { index, url in
            FileItem(
                path: url.path,
                name: "file-\(index)",
                extension: "txt",
                size: 12,
                modificationDate: timestamp
            )
        } + [
            FileItem(
                path: uniqueURL.path,
                name: "unique",
                extension: "txt",
                size: 6,
                modificationDate: timestamp
            )
        ]
        var settings = DuplicateSettings()
        settings.includeSemanticDuplicates = false
        let manager = DuplicateDetectionManager()

        await manager.scanForDuplicates(files: files, settings: settings)

        XCTAssertEqual(manager.duplicateGroups.count, 1)
        XCTAssertEqual(manager.duplicateGroups.first?.files.count, 3)
        XCTAssertEqual(manager.hashCandidateCount, 3)
        XCTAssertEqual(manager.hashedFileCount, 3)
        XCTAssertEqual(manager.hashCacheHitCount, 0)

        await manager.scanForDuplicates(files: files, settings: settings)

        XCTAssertEqual(manager.duplicateGroups.first?.files.count, 3)
        XCTAssertEqual(manager.hashedFileCount, 0)
        XCTAssertEqual(manager.hashCacheHitCount, 3)
    }

    @MainActor
    func testManagerReportsFilesThatDisappearBeforeHashing() async {
        let missingFiles = ["first.bin", "second.bin"].map { name in
            FileItem(
                path: "/missing/\(name)",
                name: (name as NSString).deletingPathExtension,
                extension: "bin",
                size: 8,
                isDirectory: false
            )
        }
        var settings = DuplicateSettings()
        settings.includeSemanticDuplicates = false
        let manager = DuplicateDetectionManager()

        await manager.scanForDuplicates(files: missingFiles, settings: settings)

        XCTAssertEqual(manager.hashCandidateCount, 2)
        XCTAssertEqual(manager.hashedFileCount, 0)
        XCTAssertEqual(manager.unreadableFileCount, 2)
        XCTAssertTrue(manager.duplicateGroups.isEmpty)
    }

    @MainActor
    func testManagerPromotesSemanticCandidatesWithIdenticalContentToExactDuplicates() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("DuplicatePromotionTests-\(UUID().uuidString)", isDirectory: true)
        let firstURL = directory.appendingPathComponent("proposal-v1.txt")
        let secondURL = directory.appendingPathComponent("proposal-v2.txt")

        defer {
            try? fileManager.removeItem(at: directory)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("same proposal content".utf8).write(to: firstURL)
        try Data("same proposal content".utf8).write(to: secondURL)

        let files = [
            FileItem(
                path: firstURL.path,
                name: "proposal-v1",
                extension: "txt",
                size: 21
            ),
            FileItem(
                path: secondURL.path,
                name: "proposal-v2",
                extension: "txt",
                size: 21
            )
        ]
        var settings = DuplicateSettings()
        settings.includeSemanticDuplicates = true
        let manager = DuplicateDetectionManager()

        await manager.scanForDuplicates(files: files, settings: settings)

        XCTAssertEqual(manager.duplicateGroups.count, 1)
        XCTAssertEqual(manager.duplicateGroups.first?.files.count, 2)
        XCTAssertTrue(manager.semanticGroups.isEmpty)
    }

    func testFIFOIsNeverHashedOrCollectedAsCandidate() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("DuplicateFIFOTests-\(UUID().uuidString)", isDirectory: true)
        let fifoURL = directory.appendingPathComponent("pipe")
        let firstURL = directory.appendingPathComponent("empty-one.txt")
        let secondURL = directory.appendingPathComponent("empty-two.txt")

        defer {
            try? fileManager.removeItem(at: directory)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(fileManager.createFile(atPath: firstURL.path, contents: Data()))
        XCTAssertTrue(fileManager.createFile(atPath: secondURL.path, contents: Data()))
        XCTAssertEqual(mkfifo(fifoURL.path, 0o644), 0, "Failed to create FIFO fixture")

        // Opening a FIFO blocks until a writer appears; hashing must refuse it.
        XCTAssertNil(HashUtility.computeSHA256(for: fifoURL))

        var settings = DuplicateSettings()
        settings.includeSemanticDuplicates = false
        let inventory = try await DirectoryScanner().scanDirectoryForDuplicates(
            at: directory,
            settings: settings
        )

        XCTAssertEqual(
            Set(inventory.exactCandidates.map {
                URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path
            }),
            Set([firstURL, secondURL].map {
                $0.resolvingSymlinksInPath().standardizedFileURL.path
            })
        )
    }

    func testReplacedFileWithPreservedMetadataIsRehashed() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("DuplicateCacheIdentityTests-\(UUID().uuidString)", isDirectory: true)
        let firstURL = directory.appendingPathComponent("first.txt")
        let secondURL = directory.appendingPathComponent("second.txt")
        let replacementURL = directory.appendingPathComponent("replacement.tmp")

        defer {
            try? fileManager.removeItem(at: directory)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("AAAA".utf8).write(to: firstURL)
        try Data("AAAA".utf8).write(to: secondURL)

        let secondModified = try XCTUnwrap(
            fileManager.attributesOfItem(atPath: secondURL.path)[.modificationDate] as? Date
        )
        let firstItem = FileItem(
            path: firstURL.path,
            name: "first",
            extension: "txt",
            size: 4
        )
        let secondItem = FileItem(
            path: secondURL.path,
            name: "second",
            extension: "txt",
            size: 4,
            modificationDate: secondModified
        )

        let firstResult = await detector.findExactDuplicates(in: [firstItem, secondItem])
        XCTAssertEqual(firstResult.groups.count, 1)

        // Swap in different bytes while preserving path, size, and modification
        // date; only the new file identity can reveal that the cached digest is
        // stale.
        try Data("BBBB".utf8).write(to: replacementURL)
        try fileManager.removeItem(at: secondURL)
        try fileManager.moveItem(at: replacementURL, to: secondURL)
        try fileManager.setAttributes(
            [.modificationDate: secondModified],
            ofItemAtPath: secondURL.path
        )

        let secondResult = await detector.findExactDuplicates(in: [firstItem, secondItem])
        XCTAssertTrue(secondResult.groups.isEmpty)
        XCTAssertEqual(secondResult.hashedCount, 1, "Replaced file should be hashed again")
    }
}
