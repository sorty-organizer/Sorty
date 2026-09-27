
import XCTest
@testable import SortyLib
@testable import SortyCore

class DirectoryScannerTests: XCTestCase {
    
    var scanner: DirectoryScanner!
    var tempDirectory: URL!
    
    override func setUp() async throws {
        
        scanner = DirectoryScanner()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        scanner = nil
        
    }
    
    func testBasicScanning() async throws {
        // Create some test files
        let file1 = tempDirectory.appendingPathComponent("test1.txt")
        let file2 = tempDirectory.appendingPathComponent("test2.md")
        try "Content 1".write(to: file1, atomically: true, encoding: .utf8)
        try "Content 2".write(to: file2, atomically: true, encoding: .utf8)
        
        let files = try await scanner.scanDirectory(at: tempDirectory)
        
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.contains(where: { $0.name == "test1" && $0.extension == "txt" }))
        XCTAssertTrue(files.contains(where: { $0.name == "test2" && $0.extension == "md" }))
    }
    
    func testHiddenFileExclusion() async throws {
        let visibleFile = tempDirectory.appendingPathComponent("visible.txt")
        let hiddenFile = tempDirectory.appendingPathComponent(".hidden.txt")
        try "Visible".write(to: visibleFile, atomically: true, encoding: .utf8)
        try "Hidden".write(to: hiddenFile, atomically: true, encoding: .utf8)
        
        // Scan without hidden files
        let files = try await scanner.scanDirectory(at: tempDirectory, includeHidden: false)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.name, "visible")
        
        // Scan with hidden files
        let filesWithHidden = try await scanner.scanDirectory(at: tempDirectory, includeHidden: true)
        XCTAssertEqual(filesWithHidden.count, 2)
    }
    
    func testDeepScan() async throws {
        let textFile = tempDirectory.appendingPathComponent("sample.txt")
        let content = "This is a sample text file for deep scanning."
        try content.write(to: textFile, atomically: true, encoding: .utf8)
        
        let files = try await scanner.scanDirectory(at: tempDirectory, deepScan: true)
        
        XCTAssertEqual(files.count, 1)
        XCTAssertNotNil(files.first?.contentMetadata)
        XCTAssertEqual(files.first?.contentMetadata?.textPreview, content)
    }

    func testFastScanSkipsContentMetadata() async throws {
        let textFile = tempDirectory.appendingPathComponent("sample.txt")
        try "This content must not be read in Fast Mode."
            .write(to: textFile, atomically: true, encoding: .utf8)

        let files = try await scanner.scanDirectory(at: tempDirectory, deepScan: false)

        XCTAssertEqual(files.count, 1)
        XCTAssertNil(files.first?.contentMetadata)
    }
    
    func testHashComputation() async throws {
        let file = tempDirectory.appendingPathComponent("hash_test.txt")
        let content = "hash me"
        try content.write(to: file, atomically: true, encoding: .utf8)
        
        let files = try await scanner.scanDirectory(at: tempDirectory, computeHashes: true)
        
        XCTAssertEqual(files.count, 1)
        XCTAssertNotNil(files.first?.sha256Hash)
        // Verify hash if possible, or just check it's non-empty
        XCTAssertFalse(files.first?.sha256Hash?.isEmpty ?? true)
    }
    
    func testRecursiveScanning() async throws {
        let subDir = tempDirectory.appendingPathComponent("SubDir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let subFile = subDir.appendingPathComponent("sub.txt")
        try "sub content".write(to: subFile, atomically: true, encoding: .utf8)
        
        let files = try await scanner.scanDirectory(at: tempDirectory)
        
        XCTAssertTrue(files.contains(where: { $0.name == "sub" }))
        XCTAssertEqual(files.first(where: { $0.name == "sub" })?.relativePath, "SubDir/sub.txt")
    }

    func testScanningPrunesExcludedSubtreesBeforeDeepAnalysis() async throws {
        let excludedDirectory = tempDirectory
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(
            at: excludedDirectory,
            withIntermediateDirectories: true
        )
        try "dependency".write(
            to: excludedDirectory.appendingPathComponent("index.js"),
            atomically: true,
            encoding: .utf8
        )
        try "report".write(
            to: tempDirectory.appendingPathComponent("report.txt"),
            atomically: true,
            encoding: .utf8
        )
        let matcher = ExclusionMatcher(rules: [
            ExclusionRule(type: .folderName, pattern: "node_modules")
        ])

        let files = try await scanner.scanDirectory(
            at: tempDirectory,
            deepScan: true,
            exclusionMatcher: matcher
        )

        XCTAssertEqual(files.map(\.displayName), ["report.txt"])
        XCTAssertNotNil(files.first?.contentMetadata)
    }

    func testFinderTagExclusionSkipsTaggedFileAndTaggedFolderContents() async throws {
        let taggedFile = tempDirectory.appendingPathComponent("private.txt")
        try "private".write(to: taggedFile, atomically: true, encoding: .utf8)
        var taggedFileURL = taggedFile
        var taggedFileValues = URLResourceValues()
        taggedFileValues.labelNumber = FinderTagColor.red.rawValue
        try taggedFileURL.setResourceValues(taggedFileValues)

        let taggedFolder = tempDirectory.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: taggedFolder,
            withIntermediateDirectories: true
        )
        try "archived".write(
            to: taggedFolder.appendingPathComponent("old.txt"),
            atomically: true,
            encoding: .utf8
        )
        var taggedFolderURL = taggedFolder
        var taggedFolderValues = URLResourceValues()
        taggedFolderValues.labelNumber = FinderTagColor.red.rawValue
        try taggedFolderURL.setResourceValues(taggedFolderValues)

        try "public".write(
            to: tempDirectory.appendingPathComponent("public.txt"),
            atomically: true,
            encoding: .utf8
        )
        let matcher = ExclusionMatcher(rules: [
            ExclusionRule(type: .finderTag, pattern: String(FinderTagColor.red.rawValue))
        ])

        let files = try await scanner.scanDirectory(
            at: tempDirectory,
            exclusionMatcher: matcher
        )

        XCTAssertEqual(files.map(\.displayName), ["public.txt"])
    }

    func testScanFileRejectsExcludedItem() async throws {
        let file = tempDirectory.appendingPathComponent("scratch.tmp")
        try "temporary".write(to: file, atomically: true, encoding: .utf8)
        let matcher = ExclusionMatcher(rules: [
            ExclusionRule(type: .fileExtension, pattern: "tmp")
        ])

        do {
            _ = try await scanner.scanFile(at: file, exclusionMatcher: matcher)
            XCTFail("Expected the excluded file to be rejected")
        } catch let error as ScannerError {
            guard case .excluded = error else {
                return XCTFail("Expected excluded, got \(error)")
            }
        }
    }

    func testGoogleDriveNativeDocumentsAreScanned() async throws {
        let document = tempDirectory.appendingPathComponent("Planning.gdoc")
        let sheet = tempDirectory.appendingPathComponent("Budget.gsheet")
        try #"{"url":"https://docs.google.com/document/d/example"}"#.write(to: document, atomically: true, encoding: .utf8)
        try #"{"url":"https://docs.google.com/spreadsheets/d/example"}"#.write(to: sheet, atomically: true, encoding: .utf8)

        let files = try await scanner.scanDirectory(at: tempDirectory)

        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.contains(where: { $0.displayName == "Planning.gdoc" && $0.cloudStatus == .synced }))
        XCTAssertTrue(files.contains(where: { $0.displayName == "Budget.gsheet" && $0.cloudStatus == .synced }))
    }

    func testCloudStorageProviderDirectoriesAreScannedAsSyncedLocalFiles() async throws {
        let cloudFolder = tempDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("CloudStorage", isDirectory: true)
            .appendingPathComponent("GoogleDrive-user@example.com", isDirectory: true)
            .appendingPathComponent("My Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: cloudFolder, withIntermediateDirectories: true)

        let pdf = cloudFolder.appendingPathComponent("Invoice.pdf")
        try "pdf".write(to: pdf, atomically: true, encoding: .utf8)

        let files = try await scanner.scanDirectory(at: tempDirectory)

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.displayName, "Invoice.pdf")
        XCTAssertEqual(files.first?.cloudStatus, .synced)
    }

    func testScanFileReportsGoogleDriveNativeDocumentAsSynced() async throws {
        let document = tempDirectory.appendingPathComponent("Planning.gdoc")
        try #"{"url":"https://docs.google.com/document/d/example"}"#.write(
            to: document,
            atomically: true,
            encoding: .utf8
        )

        let file = try await scanner.scanFile(at: document)

        XCTAssertEqual(file.cloudStatus, .synced)
    }

    func testScanDirectoryRejectsRegularFile() async throws {
        let file = tempDirectory.appendingPathComponent("not-a-folder.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        do {
            _ = try await scanner.scanDirectory(at: file)
            XCTFail("Expected a regular file scan root to be rejected")
        } catch let error as ScannerError {
            guard case .notDirectory = error else {
                return XCTFail("Expected notDirectory, got \(error)")
            }
        }
    }
}
