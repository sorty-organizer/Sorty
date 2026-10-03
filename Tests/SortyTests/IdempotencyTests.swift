import XCTest
@testable import SortyOrganizer
@testable import SortyFS
@testable import SortyModels

/// Idempotency contracts: organizing or applying twice must converge instead
/// of duplicating, losing, or shuffling files.
///
/// Each test owns a distinct boundary:
/// - dry-run determinism pins the planner/apply mapping (same plan in, same
///   destinations out) without touching disk;
/// - the in-place apply pins the filesystem boundary (a file already at its
///   destination records no move/rename);
/// - the empty-plan organize pins the workflow boundary (nothing confident
///   to do still reaches .ready without moving files);
/// - batch-merge determinism pins the model merge (split batches converge to
///   the same folders regardless of split order).
final class IdempotencyTests: XCTestCase {
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

    private func makeFile(named name: String, contents: String) throws -> FileItem {
        let url = tempDirectory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return FileItem(
            path: url.path,
            name: url.deletingPathExtension().lastPathComponent,
            extension: url.pathExtension,
            size: Int64(contents.utf8.count)
        )
    }

    private func moveDestinations(in operations: [FileSystemManager.FileOperation]) -> [String] {
        operations
            .filter { $0.type == .moveFile || $0.type == .renameFile }
            .compactMap(\.destinationPath)
            .sorted()
    }

    // MARK: - Plan mapping determinism

    /// Two dry-run applies of the same plan must record identical
    /// destinations: the plan-to-disk mapping is a pure function of the plan.
    @MainActor
    func testDryRunApplyTwiceYieldsIdenticalDestinations() async throws {
        let alpha = try makeFile(named: "alpha.txt", contents: "alpha")
        let beta = try makeFile(named: "beta.txt", contents: "beta")
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Docs", files: [alpha, beta])],
            unorganizedFiles: [],
            notes: "idempotency probe"
        )

        let first = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, dryRun: true)
        let second = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, dryRun: true)

        XCTAssertEqual(moveDestinations(in: first), moveDestinations(in: second))
        XCTAssertEqual(moveDestinations(in: first).count, 2)
        // Dry runs must not move anything.
        XCTAssertTrue(FileManager.default.fileExists(atPath: alpha.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: beta.path))
    }

    // MARK: - Already-organized inputs

    /// Files already sitting at their planned destination are a no-op: no
    /// move/rename operations, contents untouched.
    @MainActor
    func testApplyPlanForFilesAlreadyInPlaceRecordsNoMoves() async throws {
        let docs = tempDirectory.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let settledURL = docs.appendingPathComponent("settled.txt")
        try "settled".write(to: settledURL, atomically: true, encoding: .utf8)
        let settled = FileItem(path: settledURL.path, name: "settled", extension: "txt", size: 7)
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Docs", files: [settled])],
            unorganizedFiles: [],
            notes: "already organized"
        )

        let operations = try await fileSystemManager.applyOrganization(
            plan,
            at: tempDirectory,
            enableTagging: false
        )

        XCTAssertTrue(moveDestinations(in: operations).isEmpty, "in-place files must record no moves")
        XCTAssertEqual(try String(contentsOf: settledURL, encoding: .utf8), "settled")
    }

    /// Re-organizing an organized folder can yield an empty plan (nothing left
    /// the model places confidently). The workflow must reach .ready with no
    /// suggestions and leave every file where it is.
    @MainActor
    func testOrganizeAlreadyOrganizedYieldsEmptyPlanWithoutMovingFiles() async throws {
        let organizer = FolderOrganizer()
        let config = AIConfig(apiKey: "test-key", model: "test-model")
        let mockClient = MockAIClient(config: config)
        organizer.setAIClientForTesting(mockClient)

        let names = ["keep-a.txt", "keep-b.txt"]
        for name in names {
            try "contents of \(name)".write(
                to: tempDirectory.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }
        await mockClient.setHandler { files in
            OrganizationPlan(suggestions: [], unorganizedFiles: files, notes: "nothing confident to place")
        }

        try await organizer.organize(directory: tempDirectory)

        XCTAssertEqual(organizer.state, .ready)
        XCTAssertTrue(organizer.currentPlan?.suggestions.isEmpty == true)
        for name in names {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent(name).path),
                "\(name) must stay in place when the plan is empty"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("Docs").path)
        )
    }

    // MARK: - Batch-merge determinism

    /// The same file IDs split across batches in different orders must merge
    /// into the same folders with the same membership: batching is a
    /// transport detail, not an organization decision.
    func testBatchMergeDeterminismAcrossSplitOrders() {
        func item(_ displayName: String) -> FileItem {
            let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(displayName)
            return FileItem(
                path: url.path,
                name: url.deletingPathExtension().lastPathComponent,
                extension: url.pathExtension
            )
        }

        let files = ["a.txt", "b.txt", "c.txt", "d.jpg"].map(item)
        func membership(of plan: OrganizationPlan) -> [String: [String]] {
            var result: [String: [String]] = [:]
            for suggestion in plan.suggestions {
                result[suggestion.folderName] = suggestion.files.map(\.id.uuidString).sorted()
            }
            return result
        }

        // Split 1: "Docs" + "docs " (case/whitespace variant a real batch
        // boundary can produce) vs. Split 2: one batch, reversed file order.
        let splitPlan = OrganizationPlan(suggestions: [
            FolderSuggestion(folderName: "Docs", files: Array(files.prefix(2)), reasoning: "Text documents"),
            FolderSuggestion(folderName: "docs ", files: [files[2]], reasoning: "Text documents"),
            FolderSuggestion(folderName: "Photos", files: [files[3]], reasoning: "Trip photo"),
        ])
        let wholePlan = OrganizationPlan(suggestions: [
            FolderSuggestion(folderName: "Photos", files: [files[3]], reasoning: "Trip photo"),
            FolderSuggestion(folderName: "Docs", files: files.prefix(3).reversed(), reasoning: "Text documents"),
        ])

        let mergedSplit = FolderOrganizer.normalizingDestinationHierarchy(in: splitPlan)
        let mergedWhole = FolderOrganizer.normalizingDestinationHierarchy(in: wholePlan)

        XCTAssertEqual(membership(of: mergedSplit), membership(of: mergedWhole))
        XCTAssertEqual(Set(mergedSplit.suggestions.map(\.folderName)), ["Docs", "Photos"])
        XCTAssertEqual(mergedSplit.totalFiles, 4)
    }
}
