import XCTest
@testable import SortyFS
@testable import SortyModels

/// Filesystem conflict matrix: every way two files can want the same path
/// must resolve to distinct, intact files — never an overwrite, a silent
/// no-op that drops a file, or an unrestorable state.
///
/// Each test owns one collision shape at the FileSystemManager boundary with
/// real temp directories: case-only collisions, same-basename files told
/// apart by ID, rename-target collisions (plus their undo), and
/// byte-identical files.
final class ConflictMatrixTests: XCTestCase {
    private var tempDirectory: URL!
    private var fileSystemManager: FileSystemManager!

    @MainActor
    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        fileSystemManager = FileSystemManager()
    }

    @MainActor
    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        fileSystemManager = nil
        tempDirectory = nil
    }

    private func write(_ name: String, contents: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? tempDirectory!).appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func item(at url: URL) -> FileItem {
        FileItem(
            path: url.path,
            name: url.deletingPathExtension().lastPathComponent,
            extension: url.pathExtension,
            size: (try? Data(contentsOf: url).count).map(Int64.init) ?? 0
        )
    }

    private func contents(of directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            result[name] = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        }
        return result
    }

    // MARK: - Case-insensitive collisions

    /// On case-insensitive APFS, REPORT.TXT collides with an existing
    /// report.txt. The incoming file must be uniquified — the existing file
    /// keeps its bytes and both contents survive in two files.
    @MainActor
    func testCaseInsensitiveCollisionUniquifiesInsteadOfOverwriting() async throws {
        let dest = tempDirectory.appendingPathComponent("Dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try write("report.txt", contents: "original", in: dest)
        let incomingURL = try write("REPORT.TXT", contents: "incoming")
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Dest", files: [item(at: incomingURL)])],
            unorganizedFiles: [],
            notes: "case collision probe"
        )

        _ = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, enableTagging: false)

        let landed = try contents(of: dest)
        XCTAssertEqual(landed.count, 2, "collision must produce two files, not an overwrite")
        XCTAssertEqual(landed["report.txt"], "original", "existing file must keep its bytes")
        XCTAssertTrue(landed.values.contains("incoming"), "incoming file must land intact under a unique name")
        XCTAssertFalse(FileManager.default.fileExists(atPath: incomingURL.path))
    }

    // MARK: - Same basename from different directories

    /// Two files sharing a basename but carrying different IDs (different
    /// source directories) must both land with their own bytes intact — ID
    /// identity, not name equality, decides survival.
    @MainActor
    func testSameBasenameFromDifferentDirectoriesResolvedByID() async throws {
        let dirA = tempDirectory.appendingPathComponent("InboxA", isDirectory: true)
        let dirB = tempDirectory.appendingPathComponent("InboxB", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        let sourceA = try write("note.txt", contents: "alpha", in: dirA)
        let sourceB = try write("note.txt", contents: "beta", in: dirB)
        let fileA = item(at: sourceA)
        let fileB = item(at: sourceB)
        XCTAssertNotEqual(fileA.id, fileB.id, "precondition: same name, distinct IDs")
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Notes", files: [fileA, fileB])],
            unorganizedFiles: [],
            notes: "same-basename probe"
        )

        let operations = try await fileSystemManager.applyOrganization(
            plan,
            at: tempDirectory,
            enableTagging: false
        )

        let notes = tempDirectory.appendingPathComponent("Notes", isDirectory: true)
        let landed = try contents(of: notes)
        XCTAssertEqual(landed.count, 2)
        XCTAssertEqual(Set(landed.values), ["alpha", "beta"], "each ID must keep its own bytes")
        XCTAssertEqual(operations.filter { $0.type == .moveFile }.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceB.path))
    }

    // MARK: - Rename-target collisions + undo

    /// Two files renamed to the same target must land as shared.txt plus a
    /// uniquified sibling, and undo must restore both originals byte-for-byte.
    @MainActor
    func testRenameTargetCollisionUniquifiesAndUndoRestoresBoth() async throws {
        let sourceA = try write("a.txt", contents: "A-content")
        let sourceB = try write("b.txt", contents: "B-content")
        let fileA = item(at: sourceA)
        let fileB = item(at: sourceB)
        var folder = FolderSuggestion(folderName: "Renamed", files: [fileA, fileB])
        folder.updateRename(for: fileA, newName: "shared.txt")
        folder.updateRename(for: fileB, newName: "shared.txt")
        let plan = OrganizationPlan(suggestions: [folder], unorganizedFiles: [], notes: "rename collision probe")

        let operations = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, dryRun: false)

        let renamed = tempDirectory.appendingPathComponent("Renamed", isDirectory: true)
        let landed = try contents(of: renamed)
        XCTAssertEqual(landed.count, 2)
        XCTAssertEqual(Set(landed.values), ["A-content", "B-content"])
        XCTAssertEqual(operations.filter { $0.type == .renameFile }.count, 2)

        _ = try await fileSystemManager.reverseOperations(operations)

        XCTAssertEqual(try String(contentsOf: sourceA, encoding: .utf8), "A-content")
        XCTAssertEqual(try String(contentsOf: sourceB, encoding: .utf8), "B-content")
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.appendingPathComponent("shared.txt").path))
    }

    // MARK: - Hash-identical files

    /// Byte-identical files are still two files: apply must never dedupe,
    /// skip, or merge them — both land with contents intact.
    @MainActor
    func testHashIdenticalFilesBothPreservedDistinctly() async throws {
        let sourceA = try write("dup-a.bin", contents: "SAME-BYTES")
        let sourceB = try write("dup-b.bin", contents: "SAME-BYTES")
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Archive", files: [item(at: sourceA), item(at: sourceB)])],
            unorganizedFiles: [],
            notes: "identical-bytes probe"
        )

        _ = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, enableTagging: false)

        let archive = tempDirectory.appendingPathComponent("Archive", isDirectory: true)
        let landed = try contents(of: archive)
        XCTAssertEqual(landed.count, 2, "hash-identical files must both be preserved")
        XCTAssertEqual(landed["dup-a.bin"], "SAME-BYTES")
        XCTAssertEqual(landed["dup-b.bin"], "SAME-BYTES")
    }
}
