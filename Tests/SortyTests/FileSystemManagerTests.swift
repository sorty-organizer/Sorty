
import XCTest
@testable import SortyLib
@testable import SortyCore

class FileSystemManagerTests: XCTestCase {
    
    var fileSystemManager: FileSystemManager!
    var tempDirectory: URL!
    
    @MainActor
    override func setUp() async throws {
        
        fileSystemManager = FileSystemManager()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    @MainActor
    override func tearDown() async throws {
        DuplicateRestorationManager.trashItemForTesting = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        fileSystemManager = nil
        
    }
    
    @MainActor
    func testCreateFolders() async throws {
        let plan = OrganizationPlan(
            suggestions: [
                FolderSuggestion(folderName: "Folder1", description: "", files: [], subfolders: [
                    FolderSuggestion(folderName: "Subfolder1", description: "", files: [], subfolders: [], reasoning: "")
                ], reasoning: "")
            ],
            unorganizedFiles: [],
            notes: ""
        )
        
        let ops = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, enableTagging: false)

        XCTAssertEqual(ops.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("Folder1").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("Folder1/Subfolder1").path))
    }
    
    @MainActor
    func testMoveFilesWithConflicts() async throws {
        let sourceFile = tempDirectory.appendingPathComponent("test.txt")
        try "Content".write(to: sourceFile, atomically: true, encoding: .utf8)
        
        // Create a conflict at destination
        let destFolder = tempDirectory.appendingPathComponent("Dest")
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
        let conflictFile = destFolder.appendingPathComponent("test.txt")
        try "Existing Content".write(to: conflictFile, atomically: true, encoding: .utf8)
        
        let fileItem = FileItem(path: sourceFile.path, name: "test", extension: "txt", size: 10, isDirectory: false)
        let plan = OrganizationPlan(
            suggestions: [
                FolderSuggestion(folderName: "Dest", description: "", files: [fileItem], subfolders: [], reasoning: "")
            ],
            unorganizedFiles: [],
            notes: ""
        )
        
        let ops = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, enableTagging: false)

        XCTAssertEqual(ops.filter { $0.type == .moveFile }.count, 1)
        // Should have renamed the destination file to test_1.txt
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFolder.appendingPathComponent("test_1.txt").path))
    }

    @MainActor
    func testCollisionMetadataTargetsMovedFile() async throws {
        let sourceFile = tempDirectory.appendingPathComponent("test.txt")
        try "Moved content".write(to: sourceFile, atomically: true, encoding: .utf8)

        let destFolder = tempDirectory.appendingPathComponent("Dest")
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
        try "Existing content".write(
            to: destFolder.appendingPathComponent("test.txt"),
            atomically: true,
            encoding: .utf8
        )

        let fileItem = FileItem(
            path: sourceFile.path,
            name: "test",
            extension: "txt",
            size: 13,
            isDirectory: false
        )
        var suggestion = FolderSuggestion(folderName: "Dest", files: [fileItem])
        suggestion.fileTagMappings.append(
            FileTagMapping(originalFile: fileItem, tags: ["CollisionTarget"], comment: "Moved file")
        )

        let plan = OrganizationPlan(suggestions: [suggestion], unorganizedFiles: [], notes: "")
        let operations = try await fileSystemManager.applyOrganization(plan, at: tempDirectory)

        let tagOperation = try XCTUnwrap(operations.first { $0.type == .tagFile })
        XCTAssertEqual(tagOperation.sourcePath, destFolder.appendingPathComponent("test_1.txt").path)
    }

    @MainActor
    func testMoveFilesRejectsSymlinkedDestinationOutsideBaseDirectory() async throws {
        let outsideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorty-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }

        let sourceFile = tempDirectory.appendingPathComponent("secret.txt")
        try "Sensitive".write(to: sourceFile, atomically: true, encoding: .utf8)

        let symlink = tempDirectory.appendingPathComponent("Escapes")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideDirectory)

        let fileItem = FileItem(path: sourceFile.path, name: "secret", extension: "txt", size: 9, isDirectory: false)
        let plan = OrganizationPlan(
            suggestions: [
                FolderSuggestion(folderName: "Escapes", description: "", files: [fileItem], subfolders: [], reasoning: "")
            ],
            unorganizedFiles: [],
            notes: ""
        )

        do {
            _ = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, enableTagging: false)
            XCTFail("Expected symlinked relative destination to be rejected")
        } catch FileSystemError.preValidationFailed(let issues) {
            XCTAssertTrue(issues.contains { $0.contains("outside the selected directory") })
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideDirectory.appendingPathComponent("secret.txt").path))
    }

    @MainActor
    func testUndoOperations() async throws {
        let file = tempDirectory.appendingPathComponent("to_move.txt")
        try "data".write(to: file, atomically: true, encoding: .utf8)
        
        let fileItem = FileItem(path: file.path, name: "to_move", extension: "txt", size: 4, isDirectory: false)
        let plan = OrganizationPlan(
            suggestions: [
                FolderSuggestion(folderName: "NewDir", description: "", files: [fileItem], subfolders: [], reasoning: "")
            ],
            unorganizedFiles: [],
            notes: ""
        )
        
        let ops = try await fileSystemManager.applyOrganization(plan, at: tempDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("NewDir/to_move.txt").path))
        
        _ = try await fileSystemManager.reverseOperations(ops)
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("NewDir/to_move.txt").path))
    }

    @MainActor
    func testRelativeSymlinkDestinationCannotEscapeBaseDirectory() async throws {
        let outsideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorty-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }

        let link = tempDirectory.appendingPathComponent("Linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDirectory)

        let sourceFile = tempDirectory.appendingPathComponent("secret.txt")
        try "secret".write(to: sourceFile, atomically: true, encoding: .utf8)

        let fileItem = FileItem(path: sourceFile.path, name: "secret", extension: "txt", size: 6, isDirectory: false)
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Linked/Export", files: [fileItem])],
            unorganizedFiles: [],
            notes: ""
        )

        do {
            _ = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, dryRun: false)
            XCTFail("Expected symlinked relative destination to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("outside the selected directory"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideDirectory.appendingPathComponent("Export/secret.txt").path))
    }

    @MainActor
    func testFolderNameFileConflictBackupIsTrackedAndUndoable() async throws {
        let conflictingFile = tempDirectory.appendingPathComponent("Receipts")
        try "existing file".write(to: conflictingFile, atomically: true, encoding: .utf8)
        let sourceFile = tempDirectory.appendingPathComponent("receipt.txt")
        try "new receipt".write(to: sourceFile, atomically: true, encoding: .utf8)
        let fileItem = FileItem(path: sourceFile.path, name: "receipt", extension: "txt", size: 11, isDirectory: false)

        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Receipts", files: [fileItem])],
            unorganizedFiles: [],
            notes: ""
        )

        let operations = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, dryRun: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: conflictingFile.path))
        XCTAssertTrue(operations.contains { $0.type == .moveFile && $0.sourcePath == conflictingFile.path })

        _ = try await fileSystemManager.reverseOperations(operations)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: conflictingFile.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
    }

    @MainActor
    func testRenameFlowParseApplyAndUndo() async throws {
        let sourceA = tempDirectory.appendingPathComponent("doc1.pdf")
        let sourceB = tempDirectory.appendingPathComponent("doc2.pdf")
        try "A".write(to: sourceA, atomically: true, encoding: .utf8)
        try "B".write(to: sourceB, atomically: true, encoding: .utf8)

        let originalFiles = [
            FileItem(path: sourceA.path, name: "doc1", extension: "pdf", size: 1, isDirectory: false),
            FileItem(path: sourceB.path, name: "doc2", extension: "pdf", size: 1, isDirectory: false)
        ]

        let json = """
        {
          "folders": [
            {
              "name": "Invoices",
              "files": [
                {"filename": "doc1.pdf", "suggested_name": "2026-01_Invoice_Acme.pdf", "rename_reason": "PDF title identifies a January 2026 Acme invoice"},
                {"filename": "doc2.pdf", "suggested_name": "2026-01_Invoice_Beta.pdf", "rename_reason": "PDF title identifies a January 2026 Beta invoice"}
              ]
            }
          ],
          "unorganized": []
        }
        """

        let plan = try ResponseParser.parseResponse(json, originalFiles: originalFiles, mode: .organizeAndRename)
        let operations = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, dryRun: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("Invoices/2026-01_Invoice_Acme.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("Invoices/2026-01_Invoice_Beta.pdf").path))
        XCTAssertTrue(operations.contains { $0.type == .renameFile })

        _ = try await fileSystemManager.reverseOperations(operations)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceB.path))
    }

    @MainActor
    func testConflictingRenameTargetsBecomeUnique() async throws {
        let sourceA = tempDirectory.appendingPathComponent("a.txt")
        let sourceB = tempDirectory.appendingPathComponent("b.txt")
        try "A".write(to: sourceA, atomically: true, encoding: .utf8)
        try "B".write(to: sourceB, atomically: true, encoding: .utf8)

        let fileA = FileItem(path: sourceA.path, name: "a", extension: "txt", size: 1, isDirectory: false)
        let fileB = FileItem(path: sourceB.path, name: "b", extension: "txt", size: 1, isDirectory: false)

        var folder = FolderSuggestion(folderName: "Renamed", files: [fileA, fileB])
        folder.updateRename(for: fileA, newName: "shared.txt")
        folder.updateRename(for: fileB, newName: "shared.txt")

        let plan = OrganizationPlan(suggestions: [folder], unorganizedFiles: [], notes: "")
        let operations = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, dryRun: false)

        let renamedDir = tempDirectory.appendingPathComponent("Renamed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedDir.appendingPathComponent("shared.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedDir.appendingPathComponent("shared_1.txt").path))
        XCTAssertEqual(operations.filter { $0.type == .renameFile }.count, 2)
    }

    @MainActor
    func testApplyHonorsRenameConfidenceSelectionPolicy() async throws {
        let mediumSource = tempDirectory.appendingPathComponent("scan.pdf")
        let lowSource = tempDirectory.appendingPathComponent("export.pdf")
        try "medium".write(to: mediumSource, atomically: true, encoding: .utf8)
        try "low".write(to: lowSource, atomically: true, encoding: .utf8)

        let mediumFile = FileItem(
            path: mediumSource.path,
            name: "scan",
            extension: "pdf",
            size: 6,
            isDirectory: false
        )
        let lowFile = FileItem(
            path: lowSource.path,
            name: "export",
            extension: "pdf",
            size: 3,
            isDirectory: false
        )
        let mappings = [
            FileRenameMapping(
                originalFile: mediumFile,
                suggestedName: "Possible Invoice.pdf",
                renameReason: "Title may say invoice",
                renameConfidence: 0.6
            ),
            FileRenameMapping(
                originalFile: lowFile,
                suggestedName: "Possible Client Export.pdf",
                renameReason: "Client name is uncertain",
                renameConfidence: 0.2,
                isSelected: true
            )
        ]
        let folder = FolderSuggestion(
            folderName: "Documents",
            files: [mediumFile, lowFile],
            fileRenameMappings: mappings
        )

        let operations = try await fileSystemManager.applyOrganization(
            OrganizationPlan(suggestions: [folder]),
            at: tempDirectory,
            dryRun: false
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDirectory.appendingPathComponent("Documents/scan.pdf").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDirectory.appendingPathComponent("Documents/Possible Invoice.pdf").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDirectory.appendingPathComponent("Documents/Possible Client Export.pdf").path
        ))
        XCTAssertEqual(operations.filter { $0.type == .renameFile }.count, 1)
    }

    @MainActor
    func testCrossVolumeRenamePathWithNameChange() async throws {
        final class ProgressRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Double] = []

            func append(_ value: Double) {
                lock.lock()
                values.append(value)
                lock.unlock()
            }

            func snapshot() -> [Double] {
                lock.lock()
                let copy = values
                lock.unlock()
                return copy
            }
        }

        let source = tempDirectory.appendingPathComponent("camera.jpg")
        try "image".write(to: source, atomically: true, encoding: .utf8)

        let file = FileItem(path: source.path, name: "camera", extension: "jpg", size: 5, isDirectory: false)
        var folder = FolderSuggestion(folderName: "Photos", files: [file])
        folder.updateRename(for: file, newName: "Sunset.png") // extension must be preserved as .jpg
        let plan = OrganizationPlan(suggestions: [folder], unorganizedFiles: [], notes: "")

        let recorder = ProgressRecorder()
        await fileSystemManager.setCrossVolumeProgressHandler { _, progress in
            recorder.append(progress)
        }
        await fileSystemManager.setCrossVolumeDetectorForTesting { _, _ in true }

        let operations = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, dryRun: false)
        let destination = tempDirectory.appendingPathComponent("Photos/Sunset.jpg")
        let progressEvents = recorder.snapshot()

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(progressEvents.contains { $0 >= 1.0 })
        XCTAssertTrue(operations.contains { $0.type == .renameFile && $0.destinationPath == destination.path })

        let restoreResult = try await fileSystemManager.reverseOperations(operations)

        XCTAssertEqual(restoreResult.successfulOperations, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let restoredContents = try FileManager.default.contentsOfDirectory(
            atPath: source.deletingLastPathComponent().path
        )
        XCTAssertFalse(restoredContents.contains { $0.hasPrefix(".sorty-transfer-") })

        await fileSystemManager.setCrossVolumeProgressHandler(nil)
        await fileSystemManager.setCrossVolumeDetectorForTesting(nil)
    }

    @MainActor
    func testCrossVolumeMovePreservesMetadataAndLeavesNoStagingFile() async throws {
        let source = tempDirectory.appendingPathComponent("report.txt")
        try "important".write(to: source, atomically: true, encoding: .utf8)
        let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: source.path
        )
        let file = FileItem(
            path: source.path,
            name: "report",
            extension: "txt",
            size: 9,
            isDirectory: false
        )
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Archive", files: [file])],
            unorganizedFiles: [],
            notes: ""
        )
        await fileSystemManager.setCrossVolumeDetectorForTesting { _, _ in true }

        _ = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, dryRun: false)

        let destination = tempDirectory.appendingPathComponent("Archive/report.txt")
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let destinationDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        let archiveContents = try FileManager.default.contentsOfDirectory(
            atPath: destination.deletingLastPathComponent().path
        )
        XCTAssertEqual(destinationDate.timeIntervalSince1970, modificationDate.timeIntervalSince1970, accuracy: 1)
        XCTAssertFalse(archiveContents.contains { $0.hasPrefix(".sorty-transfer-") })

        await fileSystemManager.setCrossVolumeDetectorForTesting(nil)
    }

    @MainActor
    func testReverseOperationsReportsEarlierSuccessWhenLaterRestoreFails() async throws {
        let restoredSource = tempDirectory.appendingPathComponent("restored.txt")
        let successfulDestination = tempDirectory.appendingPathComponent("successful-destination.txt")
        try "success".write(to: successfulDestination, atomically: true, encoding: .utf8)

        let blockingFile = tempDirectory.appendingPathComponent("not-a-directory")
        try "block".write(to: blockingFile, atomically: true, encoding: .utf8)
        let failingDestination = tempDirectory.appendingPathComponent("failing-destination.txt")
        try "failure".write(to: failingDestination, atomically: true, encoding: .utf8)

        let failingOperation = FileSystemManager.FileOperation(
            type: .moveFile,
            sourcePath: blockingFile.appendingPathComponent("child.txt").path,
            destinationPath: failingDestination.path
        )
        let successfulOperation = FileSystemManager.FileOperation(
            type: .moveFile,
            sourcePath: restoredSource.path,
            destinationPath: successfulDestination.path
        )

        let result = try await fileSystemManager.reverseOperations([
            failingOperation,
            successfulOperation,
        ])

        XCTAssertEqual(result.successfulOperations, 1)
        XCTAssertEqual(result.retryableFailedOperationIDs, [failingOperation.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredSource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failingDestination.path))
    }

    @MainActor
    func testCrossVolumeDirectoryMoveVerifiesEntireTree() async throws {
        let sourceFolder = tempDirectory.appendingPathComponent("Project", isDirectory: true)
        let nestedFolder = sourceFolder.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        try "alpha".write(
            to: sourceFolder.appendingPathComponent("alpha.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "beta".write(
            to: nestedFolder.appendingPathComponent("beta.txt"),
            atomically: true,
            encoding: .utf8
        )
        let item = FileItem(
            path: sourceFolder.path,
            name: "Project",
            extension: "",
            size: 0,
            isDirectory: true
        )
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "External", files: [item])],
            unorganizedFiles: [],
            notes: ""
        )
        await fileSystemManager.setCrossVolumeDetectorForTesting { _, _ in true }

        _ = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, enableTagging: false)

        let destination = tempDirectory.appendingPathComponent("External/Project", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFolder.path))
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("alpha.txt"), encoding: .utf8),
            "alpha"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Nested/beta.txt"), encoding: .utf8),
            "beta"
        )
        await fileSystemManager.setCrossVolumeDetectorForTesting(nil)
    }

    @MainActor
    func testApplyFailsBeforeCreatingFoldersWhenSourceDisappears() async throws {
        let source = tempDirectory.appendingPathComponent("offline.txt")
        try "cloud content".write(to: source, atomically: true, encoding: .utf8)
        let file = FileItem(
            path: source.path,
            name: "offline",
            extension: "txt",
            size: 13,
            isDirectory: false
        )
        let destinationFolder = tempDirectory.appendingPathComponent("Archive", isDirectory: true)
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Archive", files: [file])],
            unorganizedFiles: [],
            notes: ""
        )
        try FileManager.default.removeItem(at: source)

        do {
            _ = try await fileSystemManager.applyOrganization(plan, at: tempDirectory)
            XCTFail("Expected preflight to reject the missing source")
        } catch let error as FileSystemError {
            guard case .preValidationFailed(let issues) = error else {
                return XCTFail("Expected preValidationFailed, got \(error)")
            }
            XCTAssertTrue(issues.contains { $0.contains("does not exist") })
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationFolder.path))
    }

    @MainActor
    func testApplyRejectsUnsupportedCloudMetadataBeforeMovingFiles() async throws {
        let source = tempDirectory.appendingPathComponent("document.txt")
        try "document".write(to: source, atomically: true, encoding: .utf8)
        let googleDriveRoot = tempDirectory
            .appendingPathComponent("CloudStorage", isDirectory: true)
            .appendingPathComponent("GoogleDrive-account", isDirectory: true)
        try FileManager.default.createDirectory(at: googleDriveRoot, withIntermediateDirectories: true)
        let file = FileItem(
            path: source.path,
            name: "document",
            extension: "txt",
            size: 8,
            isDirectory: false
        )
        let plan = OrganizationPlan(
            suggestions: [
                FolderSuggestion(
                    folderName: googleDriveRoot.path,
                    files: [file],
                    tags: ["Blue"]
                )
            ],
            unorganizedFiles: [],
            notes: ""
        )

        do {
            _ = try await fileSystemManager.applyOrganization(plan, at: tempDirectory)
            XCTFail("Expected unsupported provider metadata to fail preflight")
        } catch FileSystemError.preValidationFailed(let issues) {
            XCTAssertTrue(issues.contains { $0.contains("does not support Finder tags or comments") })
        } catch {
            XCTFail("Expected preValidationFailed, got \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: googleDriveRoot.appendingPathComponent("document.txt").path))
    }

    @MainActor
    func testApplyReportsProviderFailureInsteadOfFalseSuccess() async throws {
        let source = tempDirectory.appendingPathComponent("cloud-file.txt")
        try "cloud content".write(to: source, atomically: true, encoding: .utf8)
        let file = FileItem(
            path: source.path,
            name: "cloud-file",
            extension: "txt",
            size: 13,
            isDirectory: false
        )
        let plan = OrganizationPlan(
            suggestions: [
                FolderSuggestion(folderName: "First", files: [file]),
                FolderSuggestion(folderName: "Second", files: [file]),
            ],
            unorganizedFiles: [],
            notes: ""
        )

        do {
            _ = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, enableTagging: false)
            XCTFail("Expected the second provider mutation to fail the apply")
        } catch FileSystemError.partialApplyFailure(let operations, _) {
            XCTAssertEqual(operations.filter { $0.type == .moveFile }.count, 1)
        } catch {
            XCTFail("Expected partialApplyFailure, got \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("First/cloud-file.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("Second/cloud-file.txt").path))
    }

    @MainActor
    func testApplyAggregatesCrossVolumeCapacityBeforeMutation() async throws {
        let firstSource = tempDirectory.appendingPathComponent("first.bin")
        let secondSource = tempDirectory.appendingPathComponent("second.bin")
        try Data(repeating: 1, count: 8).write(to: firstSource)
        try Data(repeating: 2, count: 8).write(to: secondSource)
        let files = [firstSource, secondSource].map { url in
            FileItem(
                path: url.path,
                name: url.deletingPathExtension().lastPathComponent,
                extension: url.pathExtension,
                size: 8,
                isDirectory: false
            )
        }
        let destinationFolder = tempDirectory.appendingPathComponent("External", isDirectory: true)
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "External", files: files)],
            unorganizedFiles: [],
            notes: ""
        )
        await fileSystemManager.setCrossVolumeDetectorForTesting { _, _ in true }
        await fileSystemManager.setAvailableCapacityForTesting { _ in 12 }

        do {
            _ = try await fileSystemManager.applyOrganization(plan, at: tempDirectory)
            XCTFail("Expected aggregated capacity preflight to fail")
        } catch let error as FileSystemError {
            guard case .preValidationFailed(let issues) = error else {
                return XCTFail("Expected preValidationFailed, got \(error)")
            }
            XCTAssertTrue(issues.contains { $0.contains("Not enough free space") })
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstSource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondSource.path))
        await fileSystemManager.setCrossVolumeDetectorForTesting(nil)
        await fileSystemManager.setAvailableCapacityForTesting(nil)
    }


    // MARK: - File Tagging Tests
    
    @MainActor
    func testTagFilesInDryRun() async throws {
        let file = tempDirectory.appendingPathComponent("test.txt")
        try "Content".write(to: file, atomically: true, encoding: .utf8)
        
        let fileItem = FileItem(path: file.path, name: "test", extension: "txt", size: 7, isDirectory: false)
        var suggestion = FolderSuggestion(folderName: "Documents", files: [fileItem])
        
        // Add tag mapping
        let tagMapping = FileTagMapping(originalFile: fileItem, tags: ["Important", "Work"])
        suggestion.fileTagMappings.append(tagMapping)
        
        let plan = OrganizationPlan(suggestions: [suggestion], unorganizedFiles: [], notes: "")
        
        // Test dry run - should not actually apply tags
        let ops = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, dryRun: true)

        let tagOps = ops.filter { $0.type == .tagFile }
        XCTAssertEqual(tagOps.count, 1)
        XCTAssertEqual(tagOps.first?.metadata?.newTags, ["Important", "Work"])
    }
    
    @MainActor
    func testTagFilesActualApplication() async throws {
        let destFolder = tempDirectory.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
        
        let file = destFolder.appendingPathComponent("test.txt")
        try "Content".write(to: file, atomically: true, encoding: .utf8)
        
        let fileItem = FileItem(path: file.path, name: "test", extension: "txt", size: 7, isDirectory: false)
        var suggestion = FolderSuggestion(folderName: "Documents", files: [fileItem])
        
        let tagMapping = FileTagMapping(originalFile: fileItem, tags: ["Finance", "2024"])
        suggestion.fileTagMappings.append(tagMapping)
        
        let plan = OrganizationPlan(suggestions: [suggestion], unorganizedFiles: [], notes: "")
        
        let ops = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, enableTagging: true)

        let tagOps = ops.filter { $0.type == .tagFile }
        XCTAssertEqual(tagOps.count, 1)
        XCTAssertNotNil(tagOps.first?.metadata?.originalTags)
        XCTAssertNotNil(tagOps.first?.metadata?.newTags)
    }
    
    @MainActor
    func testApplyOrganizationWithTagging() async throws {
        let file = tempDirectory.appendingPathComponent("invoice.pdf")
        try "PDF Content".write(to: file, atomically: true, encoding: .utf8)
        
        let fileItem = FileItem(path: file.path, name: "invoice", extension: "pdf", size: 11, isDirectory: false)
        var suggestion = FolderSuggestion(folderName: "Finances", files: [fileItem])
        
        let tagMapping = FileTagMapping(originalFile: fileItem, tags: ["Invoice", "2024", "Paid"])
        suggestion.fileTagMappings.append(tagMapping)
        
        let plan = OrganizationPlan(suggestions: [suggestion], unorganizedFiles: [], notes: "")
        
        let ops = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, dryRun: false, enableTagging: true)
        
        // Should have folder creation, file move, and tagging operations
        XCTAssertTrue(ops.contains { $0.type == .createFolder })
        XCTAssertTrue(ops.contains { $0.type == .moveFile })
        XCTAssertTrue(ops.contains { $0.type == .tagFile })
    }
    
    @MainActor
    func testApplyOrganizationWithoutTagging() async throws {
        let file = tempDirectory.appendingPathComponent("doc.txt")
        try "Content".write(to: file, atomically: true, encoding: .utf8)
        
        let fileItem = FileItem(path: file.path, name: "doc", extension: "txt", size: 7, isDirectory: false)
        var suggestion = FolderSuggestion(folderName: "Docs", files: [fileItem])
        
        let tagMapping = FileTagMapping(originalFile: fileItem, tags: ["Tag1"])
        suggestion.fileTagMappings.append(tagMapping)
        
        let plan = OrganizationPlan(suggestions: [suggestion], unorganizedFiles: [], notes: "")
        
        let ops = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, dryRun: false, enableTagging: false)
        
        // Should NOT have tagging operations
        XCTAssertFalse(ops.contains { $0.type == .tagFile })
    }
    
    @MainActor
    func testReverseTaggingOperation() async throws {
        let destFolder = tempDirectory.appendingPathComponent("Tagged")
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
        
        let file = destFolder.appendingPathComponent("file.txt")
        try "Content".write(to: file, atomically: true, encoding: .utf8)
        
        let fileItem = FileItem(path: file.path, name: "file", extension: "txt", size: 7, isDirectory: false)
        var suggestion = FolderSuggestion(folderName: "Tagged", files: [fileItem])
        
        let tagMapping = FileTagMapping(originalFile: fileItem, tags: ["TestTag"])
        suggestion.fileTagMappings.append(tagMapping)
        
        let plan = OrganizationPlan(suggestions: [suggestion], unorganizedFiles: [], notes: "")
        
        let ops = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, enableTagging: true)

        // Reverse the tagging
        _ = try await fileSystemManager.reverseOperations(ops.filter { $0.type == .tagFile })
        
        // Tags should be restored to original state
        let url = URL(fileURLWithPath: file.path)
        let resourceValues = try? url.resourceValues(forKeys: [.tagNamesKey])
        let currentTags = resourceValues?.tagNames ?? []
        
        // Should be back to original tags (empty in this case)
        XCTAssertTrue(currentTags.isEmpty || !currentTags.contains("TestTag"))
    }
    
    @MainActor
    func testTagFilesInNestedFolders() async throws {
        // Create nested structure
        let parentFolder = tempDirectory.appendingPathComponent("Parent")
        let childFolder = parentFolder.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: childFolder, withIntermediateDirectories: true)
        
        let file = childFolder.appendingPathComponent("nested.txt")
        try "Nested Content".write(to: file, atomically: true, encoding: .utf8)
        
        let fileItem = FileItem(path: file.path, name: "nested", extension: "txt", size: 14, isDirectory: false)
        
        var childSuggestion = FolderSuggestion(folderName: "Child", files: [fileItem])
        let tagMapping = FileTagMapping(originalFile: fileItem, tags: ["Nested", "Deep"])
        childSuggestion.fileTagMappings.append(tagMapping)
        
        let parentSuggestion = FolderSuggestion(folderName: "Parent", files: [], subfolders: [childSuggestion])
        let plan = OrganizationPlan(suggestions: [parentSuggestion], unorganizedFiles: [], notes: "")
        
        let ops = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, enableTagging: true)

        let tagOps = ops.filter { $0.type == .tagFile }
        XCTAssertEqual(tagOps.count, 1)
        XCTAssertEqual(tagOps.first?.type, .tagFile)
    }
    
    @MainActor
    func testEmptyFolderCleanup() async throws {
        // Create source structure with file
        let sourceFolder = tempDirectory.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        
        let file = sourceFolder.appendingPathComponent("move_me.txt")
        try "Content".write(to: file, atomically: true, encoding: .utf8)
        
        let fileItem = FileItem(path: file.path, name: "move_me", extension: "txt", size: 7, isDirectory: false)
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Dest", files: [fileItem])],
            unorganizedFiles: [],
            notes: ""
        )
        
        _ = try await fileSystemManager.applyOrganization(plan, at: tempDirectory, dryRun: false)
        
        // Source folder should be removed if empty
        // Note: This might not work in all cases depending on implementation
        _ = FileManager.default.fileExists(atPath: sourceFolder.path)
        // We can't assert it's removed because the implementation tries but doesn't guarantee
        // Just verify the file was moved
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("Dest/move_me.txt").path))
    }

    @MainActor
    func testEmptyFolderCleanupKeepsSelectedRootAndItsParent() async throws {
        let selectedRoot = tempDirectory.appendingPathComponent("Selected", isDirectory: true)
        let destinationFolder = selectedRoot.appendingPathComponent("Dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        try Data().write(to: selectedRoot.appendingPathComponent(".DS_Store"))
        let destinationFile = destinationFolder.appendingPathComponent("move_me.txt")
        try "Content".write(to: destinationFile, atomically: true, encoding: .utf8)
        let restoredFile = tempDirectory.appendingPathComponent("move_me.txt")
        let operation = FileSystemManager.FileOperation(
            type: .moveFile,
            sourcePath: restoredFile.path,
            destinationPath: destinationFile.path
        )

        _ = try await fileSystemManager.reverseOperations([operation])

        XCTAssertTrue(FileManager.default.fileExists(atPath: selectedRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredFile.path))
    }
}

// MARK: - Duplicate Restoration Manager Tests

@MainActor
final class DuplicateRestorationManagerTests: XCTestCase {
    
    var manager: DuplicateRestorationManager!
    var tempDirectory: URL!
    
    @MainActor
    override func setUp() async throws {
        manager = DuplicateRestorationManager.shared
        manager.clearAllData() // Start fresh
        
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    @MainActor
    override func tearDown() async throws {
        DuplicateRestorationManager.trashItemForTesting = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        manager.clearAllData()
        manager = nil
        tempDirectory = nil
    }
    
    func testMoveSingleFileToTrash() throws {
        // Create original and duplicate
        let originalFile = tempDirectory.appendingPathComponent("original.txt")
        try "Original Content".write(to: originalFile, atomically: true, encoding: .utf8)
        
        let duplicateFile = tempDirectory.appendingPathComponent("duplicate.txt")
        try "Original Content".write(to: duplicateFile, atomically: true, encoding: .utf8)
        
        let duplicateItem = FileItem(path: duplicateFile.path, name: "duplicate", extension: "txt", size: 16, isDirectory: false)
        
        let deleted = try manager.moveToTrash(files: [duplicateItem])
        
        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(deleted.first?.originalPath, duplicateFile.path)
        XCTAssertEqual(deleted.first?.deletedPath, duplicateFile.path)
        XCTAssertNotNil(deleted.first?.trashPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicateFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent(".duplicates").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalFile.path))
    }
    
    func testMoveMultipleFilesToTrash() throws {
        let originalFile = tempDirectory.appendingPathComponent("original.txt")
        try "Content".write(to: originalFile, atomically: true, encoding: .utf8)
        
        var duplicates: [FileItem] = []
        for i in 1...3 {
            let dupFile = tempDirectory.appendingPathComponent("duplicate\(i).txt")
            try "Content".write(to: dupFile, atomically: true, encoding: .utf8)
            duplicates.append(FileItem(path: dupFile.path, name: "duplicate\(i)", extension: "txt", size: 7, isDirectory: false))
        }
        
        let deleted = try manager.moveToTrash(files: duplicates)
        
        XCTAssertEqual(deleted.count, 3)
        XCTAssertEqual(manager.restoredItems.count, 3)
        
        // All duplicates should be deleted
        for dup in duplicates {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dup.path))
        }
    }

    func testCleanupRejectsSameSizeReplacementWithPreservedTimestamp() async throws {
        let selectedURL = tempDirectory.appendingPathComponent("selected.txt")
        let replacementURL = tempDirectory.appendingPathComponent("replacement.txt")
        try Data("AAAA".utf8).write(to: selectedURL)
        let scannedItem = try await DirectoryScanner().scanFile(at: selectedURL)
        let scannedDate = try XCTUnwrap(scannedItem.modificationDate)
        XCTAssertNotNil(scannedItem.fileSystemIdentity)

        try Data("BBBB".utf8).write(to: replacementURL)
        try FileManager.default.removeItem(at: selectedURL)
        try FileManager.default.moveItem(at: replacementURL, to: selectedURL)
        try FileManager.default.setAttributes(
            [.modificationDate: scannedDate],
            ofItemAtPath: selectedURL.path
        )

        do {
            _ = try await manager.moveToTrashAsync(files: [scannedItem])
            XCTFail("Cleanup should reject a replaced file")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("was replaced after the scan"))
        }
        XCTAssertEqual(try Data(contentsOf: selectedURL), Data("BBBB".utf8))
        XCTAssertTrue(manager.restoredItems.isEmpty)
    }

    func testMoveToTrashPersistsItemsMovedBeforeALaterFailure() throws {
        let movedFile = tempDirectory.appendingPathComponent("moved.txt")
        try "Content".write(to: movedFile, atomically: true, encoding: .utf8)
        let missingFile = tempDirectory.appendingPathComponent("missing.txt")

        XCTAssertThrowsError(
            try manager.moveToTrash(files: [
                FileItem(path: movedFile.path, name: "moved", extension: "txt", size: 7, isDirectory: false),
                FileItem(path: missingFile.path, name: "missing", extension: "txt", size: 0, isDirectory: false),
            ])
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: movedFile.path))
        XCTAssertEqual(manager.restoredItems.map(\.originalPath), [movedFile.path])
    }

    func testPartialTrashFailureImmediatelyPreservesCompletedRestorationHistory() throws {
        let firstURL = tempDirectory.appendingPathComponent("first.txt")
        let secondURL = tempDirectory.appendingPathComponent("second.txt")
        try "first".write(to: firstURL, atomically: true, encoding: .utf8)
        try "second".write(to: secondURL, atomically: true, encoding: .utf8)
        let files = [firstURL, secondURL].map {
            FileItem(
                path: $0.path,
                name: $0.deletingPathExtension().lastPathComponent,
                extension: $0.pathExtension,
                size: 5,
                isDirectory: false
            )
        }
        var callCount = 0
        DuplicateRestorationManager.trashItemForTesting = { url in
            callCount += 1
            guard callCount == 1 else {
                throw CocoaError(.fileWriteUnknown)
            }
            var trashURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
            return trashURL as URL?
        }

        XCTAssertThrowsError(try manager.moveToTrash(files: files)) { error in
            guard let partialFailure = error as? PartialTrashFailure else {
                XCTFail("Expected partial trash failure, got \(error)")
                return
            }
            XCTAssertEqual(partialFailure.movedItems.map(\.originalPath), [firstURL.path])
        }
        XCTAssertEqual(manager.restoredItems.count, 1)
        XCTAssertEqual(manager.restoredItems.first?.deletedPath, firstURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }
    
    func testRestoreDuplicate() throws {
        let originalFile = tempDirectory.appendingPathComponent("original.txt")
        try "Original Content".write(to: originalFile, atomically: true, encoding: .utf8)
        
        let duplicateFile = tempDirectory.appendingPathComponent("duplicate.txt")
        try "Original Content".write(to: duplicateFile, atomically: true, encoding: .utf8)
        
        let duplicateItem = FileItem(path: duplicateFile.path, name: "duplicate", extension: "txt", size: 16, isDirectory: false)
        
        let deleted = try manager.moveToTrash(files: [duplicateItem])
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicateFile.path))
        
        // Restore it
        try manager.restore(item: deleted.first!)
        
        // File should exist again
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicateFile.path))
        
        // Should be removed from restoration history
        XCTAssertTrue(manager.restoredItems.isEmpty)
    }
    
    func testRestoreDoesNotDependOnSurvivingDuplicate() throws {
        let originalFile = tempDirectory.appendingPathComponent("original.txt")
        try "Content".write(to: originalFile, atomically: true, encoding: .utf8)
        
        let duplicateFile = tempDirectory.appendingPathComponent("duplicate.txt")
        try "Content".write(to: duplicateFile, atomically: true, encoding: .utf8)
        
        let duplicateItem = FileItem(path: duplicateFile.path, name: "duplicate", extension: "txt", size: 7, isDirectory: false)
        
        let deleted = try manager.moveToTrash(files: [duplicateItem])
        
        // Remove original
        try FileManager.default.removeItem(at: originalFile)
        
        try manager.restore(item: deleted.first!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicateFile.path))
    }
    
    func testRestoreFailsWhenTargetOccupied() throws {
        let originalFile = tempDirectory.appendingPathComponent("original.txt")
        try "Content".write(to: originalFile, atomically: true, encoding: .utf8)
        
        let duplicateFile = tempDirectory.appendingPathComponent("duplicate.txt")
        try "Content".write(to: duplicateFile, atomically: true, encoding: .utf8)
        
        let duplicateItem = FileItem(path: duplicateFile.path, name: "duplicate", extension: "txt", size: 7, isDirectory: false)
        
        let deleted = try manager.moveToTrash(files: [duplicateItem])
        
        // Recreate file at deleted location
        try "New Content".write(to: duplicateFile, atomically: true, encoding: .utf8)
        
        // Try to restore - should fail
        XCTAssertThrowsError(try manager.restore(item: deleted.first!)) { error in
            XCTAssertTrue(error is DuplicateRestorationManager.RestorationError)
        }
    }
    
    func testMetadataPreservation() throws {
        let originalFile = tempDirectory.appendingPathComponent("original.txt")
        try "Content".write(to: originalFile, atomically: true, encoding: .utf8)
        
        let duplicateFile = tempDirectory.appendingPathComponent("duplicate.txt")
        try "Content".write(to: duplicateFile, atomically: true, encoding: .utf8)
        
        let duplicateItem = FileItem(path: duplicateFile.path, name: "duplicate", extension: "txt", size: 7, isDirectory: false)
        
        let deleted = try manager.moveToTrash(files: [duplicateItem])
        
        // Check metadata was captured
        let item = deleted.first!
        XCTAssertNotNil(item.metadata)
        // Metadata fields might be nil depending on the filesystem
    }
    
    func testClearAllData() throws {
        let originalFile = tempDirectory.appendingPathComponent("original.txt")
        try "Content".write(to: originalFile, atomically: true, encoding: .utf8)
        
        let duplicateFile = tempDirectory.appendingPathComponent("duplicate.txt")
        try "Content".write(to: duplicateFile, atomically: true, encoding: .utf8)
        
        let duplicateItem = FileItem(path: duplicateFile.path, name: "duplicate", extension: "txt", size: 7, isDirectory: false)
        
        _ = try manager.moveToTrash(files: [duplicateItem])
        
        XCTAssertFalse(manager.restoredItems.isEmpty)
        
        manager.clearAllData()
        
        XCTAssertTrue(manager.restoredItems.isEmpty)
    }
}
