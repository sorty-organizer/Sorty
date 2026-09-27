import XCTest
@testable import SortyLib
@testable import SortyCore

final class ReferenceDirectoryScannerTests: XCTestCase {
    func testScanCountsEveryObservedFileAndSamplesAcrossSortedNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ReferenceDirectoryRepresentativeScan-\(UUID().uuidString)",
            isDirectory: true
        )
        let photos = directory.appendingPathComponent("Summer Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<25 {
            let name = String(format: "Summer Beach %02d.jpg", index)
            try Data([UInt8(index)]).write(to: photos.appendingPathComponent(name))
        }

        let snapshot = try await ReferenceDirectoryScanner.scan(url: directory)
        let scannedFolder = try XCTUnwrap(snapshot.folderHierarchy.first)

        XCTAssertEqual(snapshot.version, ReferenceDirectorySnapshot.currentVersion)
        XCTAssertEqual(snapshot.totalFileCount, 25)
        XCTAssertEqual(snapshot.fileExtensionDistribution["jpg"], 25)
        XCTAssertEqual(snapshot.fileCategoryDistribution[.photo], 25)
        XCTAssertEqual(scannedFolder.fileTypeDistribution["jpg"], 25)
        XCTAssertEqual(scannedFolder.sampleFileNames.count, 5)
        XCTAssertEqual(scannedFolder.sampleFileNames.first, "Summer Beach 00.jpg")
        XCTAssertEqual(scannedFolder.sampleFileNames.last, "Summer Beach 24.jpg")
        XCTAssertTrue(snapshot.fileNamingConventions.contains("Title Case"))
    }

    func testScanProducesDeterministicEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ReferenceDirectoryDeterministicScan-\(UUID().uuidString)",
            isDirectory: true
        )
        let documents = directory.appendingPathComponent("Project Files", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["Gamma Notes.pdf", "Alpha Notes.pdf", "Beta Notes.pdf"] {
            try Data(name.utf8).write(to: documents.appendingPathComponent(name))
        }

        let first = try await ReferenceDirectoryScanner.scan(url: directory)
        let second = try await ReferenceDirectoryScanner.scan(url: directory)

        XCTAssertEqual(first.folderHierarchy, second.folderHierarchy)
        XCTAssertEqual(first.namingConventions, second.namingConventions)
        XCTAssertEqual(first.fileNamingConventions, second.fileNamingConventions)
        XCTAssertEqual(first.fileCategoryDistribution, second.fileCategoryDistribution)
        XCTAssertEqual(first.fileExtensionDistribution, second.fileExtensionDistribution)
        XCTAssertEqual(first.warnings, second.warnings)
    }

    func testLegacySnapshotDecodesAndRequestsRescan() throws {
        struct LegacySnapshot: Encodable {
            let scannedAt = Date(timeIntervalSinceReferenceDate: 10)
            let folderHierarchy: [ReferenceFolder] = []
            let namingConventions = ["Title Case"]
            let totalFolderCount = 0
            let totalFileCount = 3
        }

        let data = try JSONEncoder().encode(LegacySnapshot())
        let snapshot = try JSONDecoder().decode(ReferenceDirectorySnapshot.self, from: data)

        XCTAssertEqual(snapshot.version, 1)
        XCTAssertTrue(snapshot.needsRescan)
        XCTAssertTrue(snapshot.fileCategoryDistribution.isEmpty)
        XCTAssertTrue(snapshot.fileNamingConventions.isEmpty)
    }

    func testScanSkipsOfflineCloudPlaceholders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ReferenceDirectoryCloudScan-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "local".write(
            to: directory.appendingPathComponent("example.txt"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: directory.appendingPathComponent("offline.cloud"))

        let snapshot = try await ReferenceDirectoryScanner.scan(url: directory)

        XCTAssertEqual(snapshot.totalFileCount, 1)
    }

    func testScanRejectsUnavailableDirectory() async {
        let missingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MissingReferenceDirectory-\(UUID().uuidString)",
            isDirectory: true
        )

        do {
            _ = try await ReferenceDirectoryScanner.scan(url: missingDirectory)
            XCTFail("Expected unavailable directory scan to fail")
        } catch let error as ReferenceDirectoryScanError {
            guard case .unavailable = error else {
                return XCTFail("Expected unavailable, got \(error)")
            }
        } catch {
            XCTFail("Expected ReferenceDirectoryScanError, got \(error)")
        }
    }
}
