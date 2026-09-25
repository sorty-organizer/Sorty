import XCTest
@testable import SortyLib

final class CacheMaintenanceTests: XCTestCase {
    private var sandbox: URL!
    private var caches: URL!
    private var appSupport: URL!
    private var temporary: URL!

    override func setUp() async throws {
        let fileManager = FileManager.default
        sandbox = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        caches = sandbox.appendingPathComponent("Caches", isDirectory: true)
        appSupport = sandbox.appendingPathComponent("Application Support", isDirectory: true)
        temporary = sandbox.appendingPathComponent("Temporary", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
    }

    func testClearRemovesCacheContentsAndRecreatesRoots() throws {
        let fileManager = FileManager.default
        let bundleIdentifier = "com.sorty.app"
        let directories = CacheMaintenance.cacheDirectories(
            bundleIdentifier: bundleIdentifier,
            cachesDirectory: caches,
            appSupportDirectory: appSupport
        )
        XCTAssertEqual(directories.count, 4)

        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 1024).write(to: directory.appendingPathComponent("cached.bin"))
        }
        let ownedTemporaryFile = temporary.appendingPathComponent("sorty-preview-123.tmp")
        let unrelatedTemporaryFile = temporary.appendingPathComponent("unrelated.txt")
        try Data("temp".utf8).write(to: ownedTemporaryFile)
        try Data("keep".utf8).write(to: unrelatedTemporaryFile)

        let measured = CacheMaintenance.totalSize(
            of: directories,
            temporaryDirectory: temporary
        )
        XCTAssertGreaterThanOrEqual(measured, 4 * 1024)

        let failures = CacheMaintenance.clear(
            bundleIdentifier: bundleIdentifier,
            cachesDirectory: caches,
            appSupportDirectory: appSupport,
            temporaryDirectory: temporary
        )

        XCTAssertTrue(failures.isEmpty)
        for directory in directories {
            XCTAssertTrue(fileManager.fileExists(atPath: directory.path))
            XCTAssertEqual(
                try fileManager.contentsOfDirectory(atPath: directory.path).count,
                0
            )
        }
        XCTAssertFalse(fileManager.fileExists(atPath: ownedTemporaryFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedTemporaryFile.path))
        XCTAssertEqual(
            CacheMaintenance.totalSize(of: directories, temporaryDirectory: temporary),
            0
        )
    }
}

final class ContentMetadataCachePersistenceTests: XCTestCase {
    private func key(_ path: String = "/sample.txt") -> SharedContentMetadataCache.Key {
        .init(filePath: path, modificationDate: Date(timeIntervalSince1970: 100), fileSize: 100,
              options: .init(performsOCR: false, performsDeepScan: true,
                             ocrLanguages: ["en-US"], customOCRKeywords: []))
    }

    func testCompressedRoundTripAndReadOnlyFlush() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SharedContentMetadataCache(directory: directory)
        let metadata = ContentMetadata(textPreview: String(repeating: "Invoice item description. ", count: 400))
        let cacheKey = key()
        _ = await cache.value(for: cacheKey) { metadata }
        await cache.flush()
        let file = directory.appendingPathComponent("content-metadata-cache.json.lzfse")
        let compressed = try Data(contentsOf: file)
        let json = try (compressed as NSData).decompressed(using: .lzfse)
        XCTAssertLessThan(compressed.count, json.length)
        print("Metadata cache fixture: JSON \(json.length) bytes, LZFSE \(compressed.count) bytes")
        let timestamp = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
        let reloaded = SharedContentMetadataCache(directory: directory)
        let value = await reloaded.value(for: cacheKey) { nil }
        XCTAssertEqual(value, metadata)
        await reloaded.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, timestamp)
        await reloaded.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLegacyMigrationRecomputesCostAndBoundsLongPaths() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        struct LegacyEntry: Encodable {
            let key: SharedContentMetadataCache.Key
            let metadata: ContentMetadata
            let lastAccessedAt: Date
            let byteCost: Int
        }
        let normalKey = key()
        let longKey = key(String(repeating: "long-path/", count: 300))
        let legacy = directory.appendingPathComponent("content-metadata-cache.json")
        try JSONEncoder().encode([
            LegacyEntry(key: normalKey, metadata: .init(textPreview: "kept"), lastAccessedAt: Date(), byteCost: 1),
            LegacyEntry(key: longKey, metadata: .init(textPreview: "too big"), lastAccessedAt: Date(), byteCost: 1)
        ]).write(to: legacy)
        let cache = SharedContentMetadataCache(directory: directory, maximumByteCost: 1024)
        let normal = await cache.value(for: normalKey) { nil }
        let oversized = await cache.value(for: longKey) { nil }
        XCTAssertEqual(normal?.textPreview, "kept")
        XCTAssertNil(oversized)
        await cache.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("content-metadata-cache.json.lzfse").path))
    }

    func testConcurrentColdReadsSharePersistedValues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheKey = key()
        let writer = SharedContentMetadataCache(directory: directory)
        _ = await writer.value(for: cacheKey) { ContentMetadata(textPreview: "persisted") }
        await writer.flush()
        let reader = SharedContentMetadataCache(directory: directory)
        let values = await withTaskGroup(of: ContentMetadata?.self) { group in
            for _ in 0..<32 {
                group.addTask { await reader.value(for: cacheKey) { nil } }
            }
            var values: [ContentMetadata?] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(values.count, 32)
        XCTAssertTrue(values.allSatisfy { $0?.textPreview == "persisted" })
    }

    func testCorruptCacheFallsBackToExtraction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("content-metadata-cache.json.lzfse")
        try Data("broken".utf8).write(to: file)
        let cache = SharedContentMetadataCache(directory: directory)
        let value = await cache.value(for: key()) { ContentMetadata(textPreview: "fresh") }
        XCTAssertEqual(value?.textPreview, "fresh")
        await cache.flush()
        let reloaded = SharedContentMetadataCache(directory: directory)
        let saved = await reloaded.value(for: key()) { nil }
        XCTAssertEqual(saved, value)
    }

    func testClearDuringAnalysisDoesNotRepopulateCache() async {
        actor Gate {
            var continuation: CheckedContinuation<ContentMetadata?, Never>?
            func wait() async -> ContentMetadata? {
                await withCheckedContinuation { continuation = $0 }
            }
            func started() -> Bool { continuation != nil }
            func finish() { continuation?.resume(returning: .init(textPreview: "old")) }
        }
        let gate = Gate()
        let cache = SharedContentMetadataCache(directory: nil)
        let cacheKey = key()
        let request = Task { await cache.value(for: cacheKey) { await gate.wait() } }
        while !(await gate.started()) { await Task.yield() }
        await cache.clear()
        await gate.finish()
        _ = await request.value
        let value = await cache.value(for: cacheKey) { nil }
        XCTAssertNil(value)
    }
}
