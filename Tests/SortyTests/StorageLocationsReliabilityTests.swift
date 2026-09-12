import XCTest
@testable import SortyLib

final class StorageLocationsReliabilityTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testValidatorAcceptsTrailingSlashForAllowedStoragePath() throws {
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let storageDir = tempRoot.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)

        let fileURL = sourceDir.appendingPathComponent("notes.txt")
        let contents = "hello".data(using: .utf8)!
        try contents.write(to: fileURL)

        let file = FileItem(
            path: fileURL.path,
            name: "notes",
            extension: "txt",
            size: Int64(contents.count),
            isDirectory: false
        )

        let plan = OrganizationPlan(
            suggestions: [
                FolderSuggestion(folderName: storageDir.path + "/", files: [file])
            ],
            unorganizedFiles: [],
            notes: "test"
        )

        XCTAssertNoThrow(
            try FileOrganizationValidator.validate(
                plan,
                at: sourceDir,
                allowedStorageLocations: [StorageLocation(path: storageDir.path)]
            )
        )
    }

    func testOffMainValidatorPreservesValidationResult() async throws {
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let fileURL = sourceDir.appendingPathComponent("notes.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)
        let file = FileItem(path: fileURL.path, name: "notes", extension: "txt", size: 5)
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Documents", files: [file])]
        )

        try await FileOrganizationValidator.validateOffMain(plan, at: sourceDir)
    }

    func testValidatorRejectsAbsoluteStorageDestinationThatEscapesThroughSymlink() throws {
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let storageDir = tempRoot.appendingPathComponent("Archive", isDirectory: true)
        let outsideDir = tempRoot.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)

        let link = storageDir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDir)
        let fileURL = sourceDir.appendingPathComponent("secret.txt")
        try "secret".write(to: fileURL, atomically: true, encoding: .utf8)
        let file = FileItem(path: fileURL.path, name: "secret", extension: "txt", size: 6, isDirectory: false)
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: link.path, files: [file])],
            unorganizedFiles: [],
            notes: "symlink escape"
        )

        XCTAssertThrowsError(
            try FileOrganizationValidator.validate(
                plan,
                at: sourceDir,
                allowedStorageLocations: [StorageLocation(path: storageDir.path)]
            )
        ) { error in
            guard case ValidationError.invalidStorageLocation = error else {
                return XCTFail("Expected an invalid storage location error, got \(error)")
            }
        }
    }

    func testGoogleDriveProfileSeparatesFilesystemAndNativeActions() {
        let location = StorageLocation(
            path: "/Users/test/Library/CloudStorage/GoogleDrive-user@example.com/My Drive"
        )

        let profile = location.capabilityProfile

        XCTAssertEqual(profile.provider, .googleDrive)
        XCTAssertTrue(profile.supportedFileSystemActions.contains(.createFolders))
        XCTAssertTrue(profile.supportedFileSystemActions.contains(.moveItems))
        XCTAssertFalse(profile.supportedFileSystemActions.contains(.starItems))
        XCTAssertTrue(profile.providerActionsRequiringIntegration.contains(.starItems))
        XCTAssertTrue(location.promptContext.contains("Starred is per-user Google Drive metadata"))
    }

    func testDropboxProfileDoesNotClaimFinderTagsAsProviderMetadata() {
        let location = StorageLocation(
            path: "/Users/test/Library/CloudStorage/Dropbox/Projects"
        )

        let profile = location.capabilityProfile

        XCTAssertEqual(profile.provider, .dropbox)
        XCTAssertFalse(profile.supportedFileSystemActions.contains(.finderTags))
        XCTAssertTrue(profile.providerActionsRequiringIntegration.contains(.customMetadata))
    }

    func testValidatorAllowsStorageSubfolderWhenSourceAlreadyInStorage() throws {
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let storageDir = tempRoot.appendingPathComponent("Archive", isDirectory: true)
        let storageSubfolder = storageDir.appendingPathComponent("2025", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storageSubfolder, withIntermediateDirectories: true)

        let fileURL = storageDir.appendingPathComponent("receipt.pdf")
        let contents = "data".data(using: .utf8)!
        try contents.write(to: fileURL)

        let file = FileItem(
            path: fileURL.path,
            name: "receipt",
            extension: "pdf",
            size: Int64(contents.count),
            isDirectory: false
        )

        let plan = OrganizationPlan(
            suggestions: [
                FolderSuggestion(
                    folderName: storageDir.path,
                    files: [],
                    subfolders: [
                        FolderSuggestion(folderName: "2025", files: [file])
                    ]
                )
            ],
            unorganizedFiles: [],
            notes: "test"
        )

        XCTAssertNoThrow(
            try FileOrganizationValidator.validate(
                plan,
                at: sourceDir,
                allowedStorageLocations: [StorageLocation(path: storageDir.path)]
            )
        )
    }

    func testValidatorAcceptsAbsoluteStorageSubfolderDestination() throws {
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let storageDir = tempRoot.appendingPathComponent("Archive", isDirectory: true)
        let excelSubfolder = storageDir.appendingPathComponent("Excel Sheets", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: excelSubfolder, withIntermediateDirectories: true)

        let fileURL = sourceDir.appendingPathComponent("budget.xlsx")
        let contents = "sheet".data(using: .utf8)!
        try contents.write(to: fileURL)

        let file = FileItem(
            path: fileURL.path,
            name: "budget",
            extension: "xlsx",
            size: Int64(contents.count),
            isDirectory: false
        )

        let plan = OrganizationPlan(
            suggestions: [
                FolderSuggestion(folderName: excelSubfolder.path, files: [file])
            ],
            unorganizedFiles: [],
            notes: "test"
        )

        XCTAssertNoThrow(
            try FileOrganizationValidator.validate(
                plan,
                at: sourceDir,
                allowedStorageLocations: [StorageLocation(path: storageDir.path)]
            )
        )
    }

    func testValidatorRejectsAbsoluteDestinationEscapingAllowedStorageThroughSymlink() throws {
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let storageDir = tempRoot.appendingPathComponent("Archive", isDirectory: true)
        let outsideDir = tempRoot.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)

        let link = storageDir.appendingPathComponent("Outside Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDir)
        let sourceFile = sourceDir.appendingPathComponent("private.txt")
        try "private".write(to: sourceFile, atomically: true, encoding: .utf8)
        let file = FileItem(
            path: sourceFile.path,
            name: "private",
            extension: "txt",
            size: 7,
            isDirectory: false
        )
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: link.path, files: [file])],
            unorganizedFiles: [],
            notes: "test"
        )

        XCTAssertThrowsError(
            try FileOrganizationValidator.validate(
                plan,
                at: sourceDir,
                allowedStorageLocations: [StorageLocation(path: storageDir.path)]
            )
        )
    }

    func testValidatorAllowsMovingDirectoryItemToStorage() throws {
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let storageDir = tempRoot.appendingPathComponent("Archive", isDirectory: true)
        let projectDir = sourceDir.appendingPathComponent("Project Alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)

        let directoryItem = FileItem(
            path: projectDir.path,
            name: "Project Alpha",
            extension: "",
            size: 0,
            isDirectory: true
        )

        let plan = OrganizationPlan(
            suggestions: [
                FolderSuggestion(folderName: storageDir.path, files: [directoryItem])
            ],
            unorganizedFiles: [],
            notes: "directory to storage"
        )

        XCTAssertNoThrow(
            try FileOrganizationValidator.validate(
                plan,
                at: sourceDir,
                allowedStorageLocations: [StorageLocation(path: storageDir.path)]
            )
        )
    }

    func testValidatorAllowsBulkFolderMigrationToStorage() throws {
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let storageDir = tempRoot.appendingPathComponent("Archive", isDirectory: true)
        let invoicesDir = sourceDir.appendingPathComponent("Invoices", isDirectory: true)
        try FileManager.default.createDirectory(at: invoicesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)

        let fileURLs = (1...3).map { index in
            invoicesDir.appendingPathComponent("invoice-\(index).pdf")
        }
        for (index, url) in fileURLs.enumerated() {
            try "invoice-\(index + 1)".write(to: url, atomically: true, encoding: .utf8)
        }

        let files = fileURLs.map { url in
            FileItem(
                path: url.path,
                name: url.deletingPathExtension().lastPathComponent,
                extension: url.pathExtension,
                size: 1,
                isDirectory: false
            )
        }

        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: storageDir.path, files: files)],
            unorganizedFiles: [],
            notes: "bulk storage migration"
        )

        XCTAssertNoThrow(
            try FileOrganizationValidator.validate(
                plan,
                at: sourceDir,
                allowedStorageLocations: [StorageLocation(path: storageDir.path)]
            )
        )
    }

    func testValidatorAllowsSelectiveStorageMoveFromSubfolder() throws {
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let storageDir = tempRoot.appendingPathComponent("Archive", isDirectory: true)
        let receiptsDir = sourceDir.appendingPathComponent("Receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: receiptsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)

        let moveURL = receiptsDir.appendingPathComponent("receipt-jan.pdf")
        let stayURL = receiptsDir.appendingPathComponent("draft-notes.txt")
        try "receipt".write(to: moveURL, atomically: true, encoding: .utf8)
        try "notes".write(to: stayURL, atomically: true, encoding: .utf8)

        let moveFile = FileItem(
            path: moveURL.path,
            name: "receipt-jan",
            extension: "pdf",
            size: 10,
            isDirectory: false
        )
        let stayFile = FileItem(
            path: stayURL.path,
            name: "draft-notes",
            extension: "txt",
            size: 5,
            isDirectory: false
        )

        let plan = OrganizationPlan(
            suggestions: [
                FolderSuggestion(folderName: storageDir.path, files: [moveFile]),
                FolderSuggestion(folderName: "LocalNotes", files: [stayFile])
            ],
            unorganizedFiles: [],
            notes: "selective storage"
        )

        XCTAssertNoThrow(
            try FileOrganizationValidator.validate(
                plan,
                at: sourceDir,
                allowedStorageLocations: [StorageLocation(path: storageDir.path)]
            )
        )
    }

    func testValidatorAllowsOrganizingFromStorageLocationIntoSourceFolder() throws {
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let cloudDir = tempRoot.appendingPathComponent("Cloud", isDirectory: true)
        let cloudFile = cloudDir.appendingPathComponent("project-notes.txt")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloudDir, withIntermediateDirectories: true)
        try "notes".write(to: cloudFile, atomically: true, encoding: .utf8)

        let file = FileItem(
            path: cloudFile.path,
            name: "project-notes",
            extension: "txt",
            size: 5,
            isDirectory: false
        )
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Projects", files: [file])],
            unorganizedFiles: [],
            notes: "cloud to source"
        )

        XCTAssertNoThrow(
            try FileOrganizationValidator.validate(
                plan,
                at: sourceDir,
                allowedStorageLocations: [StorageLocation(path: cloudDir.path)]
            )
        )
    }

    @MainActor
    func testApplyRevalidatesAndRejectsUnapprovedStoragePath() async throws {
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let fileURL = sourceDir.appendingPathComponent("todo.txt")
        let contents = "todo".data(using: .utf8)!
        try contents.write(to: fileURL)

        let file = FileItem(
            path: fileURL.path,
            name: "todo",
            extension: "txt",
            size: Int64(contents.count),
            isDirectory: false
        )

        let organizer = FolderOrganizer()
        organizer.currentPlan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "/tmp/not-approved", files: [file])],
            unorganizedFiles: [],
            notes: "invalid storage destination"
        )

        do {
            try await organizer.apply(at: sourceDir, dryRun: true)
            XCTFail("Expected validation failure for unapproved absolute destination")
        } catch let error as ValidationError {
            guard case .invalidStorageLocation = error else {
                XCTFail("Expected invalidStorageLocation error, got: \(error)")
                return
            }
        }
    }

    @MainActor
    func testStoragePromptContextIncludesValidPathList() async {
        let manager = StorageLocationsManager()
        manager.clearAll()
        defer { manager.clearAll() }

        let archive = tempRoot.appendingPathComponent("Archive", isDirectory: true)
        let projects = tempRoot.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        manager.addLocation(StorageLocation(path: archive.path, name: "Archive"))
        manager.addLocation(StorageLocation(path: projects.path, name: "Projects"))

        let context = await manager.generatePromptContext()
        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("VALID_STORAGE_PATHS") == true)
        XCTAssertTrue(context?.contains(archive.path) == true)
        XCTAssertTrue(context?.contains(projects.path) == true)
        XCTAssertTrue(context?.contains("actively compare the source folder with these locations") == true)
        XCTAssertTrue(context?.contains("explicit mention of storage is not required") == true)
        XCTAssertTrue(context?.contains("read-only location may be used as a source but never as a destination") == true)
    }

    @MainActor
    func testPersistedLocationsLoadAfterConstruction() async {
        let firstManager = StorageLocationsManager()
        firstManager.clearAll()
        defer { firstManager.clearAll() }

        let archive = tempRoot.appendingPathComponent("Deferred Archive", isDirectory: true)
        try? FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        firstManager.addLocation(StorageLocation(path: archive.path, name: "Deferred Archive"))

        let reloadedManager = StorageLocationsManager()
        XCTAssertFalse(reloadedManager.hasLoadedPersistedState)
        XCTAssertTrue(reloadedManager.locations.isEmpty)

        await reloadedManager.loadPersistedState()

        XCTAssertTrue(reloadedManager.hasLoadedPersistedState)
        XCTAssertEqual(reloadedManager.locations.map(\.path), [archive.path])
    }

    @MainActor
    func testStoragePromptExplainsPurposeAndExactDestinationPath() async {
        let manager = StorageLocationsManager()
        manager.clearAll()
        defer { manager.clearAll() }

        let archive = tempRoot.appendingPathComponent("Archive", isDirectory: true)
        try? FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        manager.addLocation(
            StorageLocation(
                path: archive.path,
                name: "Long-term Archive",
                description: "Completed projects and records that are no longer active"
            )
        )

        let context = await manager.generatePromptContext()
        XCTAssertTrue(context?.contains("Exact path: \(archive.path)") == true)
        XCTAssertTrue(context?.contains("Purpose: Completed projects and records that are no longer active") == true)
        XCTAssertTrue(context?.contains("Prefer a well-matched organization location over creating a parallel local category") == true)
    }

    @MainActor
    func testAddLocationFromURLCreatesEntry() throws {
        let manager = StorageLocationsManager()
        manager.clearAll()
        defer { manager.clearAll() }

        let archive = tempRoot.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)

        XCTAssertNoThrow(try manager.addLocation(url: archive, customName: "Archive"))
        XCTAssertEqual(manager.locations.count, 1)
        XCTAssertEqual(manager.locations.first?.name, "Archive")
        XCTAssertEqual(
            manager.locations.first?.path,
            StorageLocationPathResolver.canonicalPath(archive.path)
        )
        XCTAssertNotNil(manager.locations.first?.bookmarkData)
        XCTAssertEqual(manager.locations.first?.accessStatus, .valid)
    }

    @MainActor
    func testAddingDuplicateLocationThrowsClearError() throws {
        let manager = StorageLocationsManager()
        manager.clearAll()
        defer { manager.clearAll() }

        let archive = tempRoot.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try manager.addLocation(url: archive)

        XCTAssertThrowsError(try manager.addLocation(url: archive)) { error in
            XCTAssertEqual(error as? StorageLocationError, .duplicateLocation)
        }
        XCTAssertEqual(manager.locations.count, 1)
    }

    @MainActor
    func testRepeatedAccessRefreshKeepsLocationValid() async throws {
        let manager = StorageLocationsManager()
        manager.clearAll()
        defer { manager.clearAll() }

        let archive = tempRoot.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try manager.addLocation(url: archive)

        await manager.refreshAccessStatus()
        await manager.refreshAccessStatus()

        XCTAssertEqual(manager.locations.first?.accessStatus, .valid)
        XCTAssertEqual(manager.enabledLocations.count, 1)
    }

    @MainActor
    func testDiscoverAllSubfoldersIncludesMoreThanPromptLimitedSet() async throws {
        let manager = StorageLocationsManager()
        manager.clearAll()
        defer { manager.clearAll() }

        let archive = tempRoot.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)

        for index in 1...20 {
            let folder = archive.appendingPathComponent(String(format: "Folder%02d", index), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        manager.addLocation(StorageLocation(path: archive.path, name: "Archive"))

        let discovered = await manager.discoverAllSubfolders()
        let paths = discovered[StorageLocationPathResolver.canonicalPath(archive.path)] ?? []

        XCTAssertTrue(paths.contains(archive.appendingPathComponent("Folder20", isDirectory: true).path))
        XCTAssertGreaterThanOrEqual(paths.count, 20)
    }
}
