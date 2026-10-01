import XCTest
@testable import SortyOrganizer
@testable import SortyLib
@testable import SortyCore
@testable import SortyFileSystem

final class StorageDestinationNormalizerTests: XCTestCase {
    func testNormalizeMapsGenericStorageAliasWhenSingleLocationConfigured() {
        let archiveRoot = "/tmp/archive-root"
        let file = FileItem(path: "/tmp/source/budget.xlsx", name: "budget", extension: "xlsx", size: 10, isDirectory: false)
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "storage/Excel Sheets", files: [file])],
            unorganizedFiles: []
        )

        let normalized = StorageDestinationNormalizer.normalize(
            plan: plan,
            allowedStorageLocations: [StorageLocation(path: archiveRoot, name: "Archive")]
        )

        let expectedPath = URL(fileURLWithPath: archiveRoot, isDirectory: true)
            .appendingPathComponent("Excel Sheets", isDirectory: true)
            .path

        XCTAssertEqual(
            normalized.suggestions.first?.folderName,
            StorageLocationPathResolver.canonicalPath(expectedPath)
        )
    }

    func testNormalizeMapsLocationNameAliasWithMultipleLocations() {
        let archiveRoot = "/tmp/archive-root"
        let projectsRoot = "/tmp/projects-root"
        let file = FileItem(path: "/tmp/source/notes.txt", name: "notes", extension: "txt", size: 5, isDirectory: false)
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Archive/2025", files: [file])],
            unorganizedFiles: []
        )

        let normalized = StorageDestinationNormalizer.normalize(
            plan: plan,
            allowedStorageLocations: [
                StorageLocation(path: archiveRoot, name: "Archive"),
                StorageLocation(path: projectsRoot, name: "Projects")
            ]
        )

        let expectedPath = URL(fileURLWithPath: archiveRoot, isDirectory: true)
            .appendingPathComponent("2025", isDirectory: true)
            .path

        XCTAssertEqual(
            normalized.suggestions.first?.folderName,
            StorageLocationPathResolver.canonicalPath(expectedPath)
        )
    }

    func testNormalizeDoesNotMapAmbiguousGenericAliasWithMultipleLocations() {
        let file = FileItem(path: "/tmp/source/notes.txt", name: "notes", extension: "txt", size: 5, isDirectory: false)
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "storage", files: [file])],
            unorganizedFiles: []
        )

        let normalized = StorageDestinationNormalizer.normalize(
            plan: plan,
            allowedStorageLocations: [
                StorageLocation(path: "/tmp/archive-root", name: "Archive"),
                StorageLocation(path: "/tmp/projects-root", name: "Projects")
            ]
        )

        XCTAssertEqual(normalized.suggestions.first?.folderName, "storage")
    }

    func testNormalizeDoesNotImplicitlyMapToKnownStorageSubfolderWithoutExplicitStorageIntent() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageRoot = tempRoot.appendingPathComponent("Documents", isDirectory: true)
        let existingStorageSubfolder = storageRoot.appendingPathComponent("AyuGram Desktop", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: existingStorageSubfolder, withIntermediateDirectories: true)

        let file = FileItem(
            path: "/tmp/source/Bio ia practice.xlsx",
            name: "Bio ia practice",
            extension: "xlsx",
            size: 10,
            isDirectory: false
        )
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "AyuGramDesktop", files: [file])],
            unorganizedFiles: []
        )

        let normalized = StorageDestinationNormalizer.normalize(
            plan: plan,
            allowedStorageLocations: [StorageLocation(path: storageRoot.path, name: "Documents")]
        )

        XCTAssertEqual(normalized.suggestions.first?.folderName, "AyuGramDesktop")
    }

    func testNormalizeRemapsAbsoluteSourceDirPathToStorageLocation() {
        let sourceDir = URL(fileURLWithPath: "/Users/test/Downloads/AyuGram Desktop", isDirectory: true)
        let storageRoot = "/Users/test/Documents"
        let file = FileItem(path: "/Users/test/Downloads/AyuGram Desktop/budget.xlsx", name: "budget", extension: "xlsx", size: 10, isDirectory: false)

        // AI mistakenly outputs sourceDir + "Documents" instead of the storage location path
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "/Users/test/Downloads/AyuGram Desktop/Documents", files: [file])],
            unorganizedFiles: []
        )

        let normalized = StorageDestinationNormalizer.normalize(
            plan: plan,
            allowedStorageLocations: [StorageLocation(path: storageRoot, name: "Documents")],
            sourceDirectoryURL: sourceDir
        )

        XCTAssertEqual(
            normalized.suggestions.first?.folderName,
            StorageLocationPathResolver.canonicalPath(storageRoot)
        )
    }

    func testNormalizeRemapsAbsoluteSourceDirSubpathToStorageSubfolder() {
        let sourceDir = URL(fileURLWithPath: "/Users/test/Downloads/MyFolder", isDirectory: true)
        let storageRoot = "/Users/test/Archive"
        let file = FileItem(path: "/Users/test/Downloads/MyFolder/report.pdf", name: "report", extension: "pdf", size: 5, isDirectory: false)

        // AI outputs sourceDir + "Archive/2025" instead of storageRoot + "/2025"
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "/Users/test/Downloads/MyFolder/Archive/2025", files: [file])],
            unorganizedFiles: []
        )

        let normalized = StorageDestinationNormalizer.normalize(
            plan: plan,
            allowedStorageLocations: [StorageLocation(path: storageRoot, name: "Archive")],
            sourceDirectoryURL: sourceDir
        )

        let expectedPath = URL(fileURLWithPath: storageRoot, isDirectory: true)
            .appendingPathComponent("2025", isDirectory: true)
            .path

        XCTAssertEqual(
            normalized.suggestions.first?.folderName,
            StorageLocationPathResolver.canonicalPath(expectedPath)
        )
    }

    func testNormalizeDoesNotRemapUnknownSourceDirSubpathToStorageWhenSingleRoot() {
        let sourceDir = URL(fileURLWithPath: "/Users/test/Downloads/MyFolder", isDirectory: true)
        let storageRoot = "/Users/test/Archive"
        let file = FileItem(path: "/Users/test/Downloads/MyFolder/notes.txt", name: "notes", extension: "txt", size: 5, isDirectory: false)

        // AI outputs sourceDir + "RandomFolder" which doesn't match storage aliases.
        // This should remain a regular local relative destination.
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "/Users/test/Downloads/MyFolder/RandomFolder", files: [file])],
            unorganizedFiles: []
        )

        let normalized = StorageDestinationNormalizer.normalize(
            plan: plan,
            allowedStorageLocations: [StorageLocation(path: storageRoot, name: "Archive")],
            sourceDirectoryURL: sourceDir
        )

        XCTAssertEqual(normalized.suggestions.first?.folderName, "RandomFolder")
    }

    func testNormalizeDoesNotRemapRepeatedSourceComponentWithoutRootAlias() {
        let sourceDir = URL(fileURLWithPath: "/Users/test/Documents/Documents", isDirectory: true)
        let storageRoot = "/Users/test/Downloads"
        let file = FileItem(
            path: "/Users/test/Documents/Documents/Bio ia practice.xlsx",
            name: "Bio ia practice",
            extension: "xlsx",
            size: 16000,
            isDirectory: false
        )

        // AI mistakenly repeats "Documents" under the source directory.
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "/Users/test/Documents/Documents/Documents", files: [file])],
            unorganizedFiles: []
        )

        let normalized = StorageDestinationNormalizer.normalize(
            plan: plan,
            allowedStorageLocations: [StorageLocation(path: storageRoot, name: "Downloads")],
            sourceDirectoryURL: sourceDir
        )

        XCTAssertEqual(normalized.suggestions.first?.folderName, "Documents")
    }

    func testNormalizeResolvesRootAlias() {
        let storageRoot = "/tmp/Documents"
        let file = FileItem(path: "/tmp/source/report.pdf", name: "report", extension: "pdf", size: 5, isDirectory: false)

        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Documents", files: [file])],
            unorganizedFiles: []
        )

        let normalized = StorageDestinationNormalizer.normalize(
            plan: plan,
            allowedStorageLocations: [StorageLocation(path: storageRoot, name: "Documents")]
        )

        XCTAssertEqual(
            normalized.suggestions.first?.folderName,
            StorageLocationPathResolver.canonicalPath(storageRoot)
        )
    }

    func testNormalizeFallbackSkippedConditions() {
        // Phase 1: relative folder is not fallback-remapped to a single storage root.
        let storageRoot = "/tmp/storage-root"
        let singleFile = FileItem(path: "/tmp/source/budget.xlsx", name: "budget", extension: "xlsx", size: 10, isDirectory: false)
        let singlePlan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Spreadsheets", files: [singleFile])],
            unorganizedFiles: []
        )

        let singleNormalized = StorageDestinationNormalizer.normalize(
            plan: singlePlan,
            allowedStorageLocations: [StorageLocation(path: storageRoot, name: "Archive")]
        )

        XCTAssertEqual(singleNormalized.suggestions.first?.folderName, "Spreadsheets")

        // Phase 2: fallback skipped with multiple storage locations.
        let multiFile = FileItem(path: "/tmp/source/budget.xlsx", name: "budget", extension: "xlsx", size: 10, isDirectory: false)
        let multiPlan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Spreadsheets", files: [multiFile])],
            unorganizedFiles: []
        )

        // With multiple storage locations the fallback should NOT trigger
        // because we can't determine which root to use.
        let multiNormalized = StorageDestinationNormalizer.normalize(
            plan: multiPlan,
            allowedStorageLocations: [
                StorageLocation(path: "/tmp/archive-root", name: "Archive"),
                StorageLocation(path: "/tmp/projects-root", name: "Projects")
            ]
        )

        XCTAssertEqual(multiNormalized.suggestions.first?.folderName, "Spreadsheets")

        // Phase 3: fallback skipped when another suggestion already resolved to storage.
        let file1 = FileItem(path: "/tmp/source/budget.xlsx", name: "budget", extension: "xlsx", size: 10, isDirectory: false)
        let file2 = FileItem(path: "/tmp/source/notes.txt", name: "notes", extension: "txt", size: 5, isDirectory: false)
        let mixedPlan = OrganizationPlan(
            suggestions: [
                FolderSuggestion(folderName: "/tmp/storage-root/Invoices", files: [file1]),
                FolderSuggestion(folderName: "LocalStuff", files: [file2])
            ],
            unorganizedFiles: []
        )

        // One folder already points to storage, so fallback should NOT remap the other.
        let mixedNormalized = StorageDestinationNormalizer.normalize(
            plan: mixedPlan,
            allowedStorageLocations: [StorageLocation(path: storageRoot, name: "Archive")]
        )

        XCTAssertEqual(
            mixedNormalized.suggestions[0].folderName,
            StorageLocationPathResolver.canonicalPath("/tmp/storage-root/Invoices")
        )
        XCTAssertEqual(mixedNormalized.suggestions[1].folderName, "LocalStuff")
    }

    func testNormalizeKeepsValidStorageAbsolutePathUnchanged() {
        let sourceDir = URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)
        let storageRoot = "/Users/test/Archive"
        let file = FileItem(path: "/Users/test/Downloads/report.pdf", name: "report", extension: "pdf", size: 5, isDirectory: false)

        // AI correctly uses the storage location path
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "/Users/test/Archive/Reports", files: [file])],
            unorganizedFiles: []
        )

        let normalized = StorageDestinationNormalizer.normalize(
            plan: plan,
            allowedStorageLocations: [StorageLocation(path: storageRoot, name: "Archive")],
            sourceDirectoryURL: sourceDir
        )

        XCTAssertEqual(
            normalized.suggestions.first?.folderName,
            StorageLocationPathResolver.canonicalPath("/Users/test/Archive/Reports")
        )
    }
}
