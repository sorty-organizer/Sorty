//
//  FolderSuggestionTests.swift
//  SortyTests
//
//  Tests for enhanced FolderSuggestion with tagging support
//

import XCTest
@testable import SortyOrganizer
@testable import SortyLib
@testable import SortyCore

final class FolderSuggestionTests: XCTestCase {
    
    // MARK: - FileRenameMapping Tests
    
    func testFileRenameMappingCreation() {
        let file = FileItem(path: "/test/old.txt", name: "old", extension: "txt", size: 100, isDirectory: false)
        let mapping = FileRenameMapping(
            originalFile: file,
            suggestedName: "new.txt",
            renameReason: "Better naming"
        )
        
        XCTAssertEqual(mapping.originalFile.name, "old")
        XCTAssertEqual(mapping.suggestedName, "new.txt")
        XCTAssertEqual(mapping.renameReason, "Better naming")
    }
    
    func testFinalFilenameWithSuggestion() {
        let file = FileItem(path: "/test/old.txt", name: "old", extension: "txt", size: 100, isDirectory: false)
        let mapping = FileRenameMapping(
            originalFile: file,
            suggestedName: "new.txt"
        )
        
        XCTAssertEqual(mapping.finalFilename, "new.txt")
    }
    
    func testFinalFilenameWithoutSuggestion() {
        let file = FileItem(path: "/test/file.txt", name: "file", extension: "txt", size: 100, isDirectory: false)
        let mapping = FileRenameMapping(originalFile: file)
        
        XCTAssertEqual(mapping.finalFilename, file.displayName)
    }
    
    func testHasRename() {
        let file = FileItem(path: "/test/file.txt", name: "file", extension: "txt", size: 100, isDirectory: false)
        
        let withRename = FileRenameMapping(originalFile: file, suggestedName: "renamed.txt")
        XCTAssertTrue(withRename.hasRename)
        
        let withoutRename = FileRenameMapping(originalFile: file)
        XCTAssertFalse(withoutRename.hasRename)
        
        let sameName = FileRenameMapping(originalFile: file, suggestedName: file.displayName)
        XCTAssertFalse(sameName.hasRename)
    }
    
    // MARK: - FileTagMapping Tests
    
    func testFileTagMappingCreation() {
        let file = FileItem(path: "/test/doc.pdf", name: "doc", extension: "pdf", size: 1000, isDirectory: false)
        let tagMapping = FileTagMapping(
            originalFile: file,
            tags: ["Important", "Work", "2024"]
        )
        
        XCTAssertEqual(tagMapping.tags.count, 3)
        XCTAssertTrue(tagMapping.tags.contains("Important"))
        XCTAssertTrue(tagMapping.tags.contains("Work"))
        XCTAssertTrue(tagMapping.tags.contains("2024"))
    }
    
    func testFileTagMappingEmpty() {
        let file = FileItem(path: "/test/file.txt", name: "file", extension: "txt", size: 100, isDirectory: false)
        let tagMapping = FileTagMapping(originalFile: file, tags: [])
        
        XCTAssertTrue(tagMapping.tags.isEmpty)
    }
    
    // MARK: - FolderSuggestion Enhanced Tests
    
    func testFolderSuggestionWithTags() {
        let file = FileItem(path: "/test/invoice.pdf", name: "invoice", extension: "pdf", size: 500, isDirectory: false)
        let tagMapping = FileTagMapping(originalFile: file, tags: ["Finance", "Invoice"])
        
        let suggestion = FolderSuggestion(
            folderName: "Finances",
            files: [file],
            fileTagMappings: [tagMapping]
        )
        
        XCTAssertEqual(suggestion.fileTagMappings.count, 1)
        
        let tags = suggestion.tags(for: file)
        XCTAssertEqual(tags.count, 2)
        XCTAssertTrue(tags.contains("Finance"))
        XCTAssertTrue(tags.contains("Invoice"))
    }
    
    func testAddTagToFile() {
        let file = FileItem(path: "/test/doc.txt", name: "doc", extension: "txt", size: 100, isDirectory: false)
        var suggestion = FolderSuggestion(folderName: "Docs", files: [file])
        
        suggestion.addTag("Important", for: file)
        suggestion.addTag("Review", for: file)
        
        let tags = suggestion.tags(for: file)
        XCTAssertEqual(tags.count, 2)
        XCTAssertTrue(tags.contains("Important"))
        XCTAssertTrue(tags.contains("Review"))
    }
    
    func testAddDuplicateTag() {
        let file = FileItem(path: "/test/file.txt", name: "file", extension: "txt", size: 100, isDirectory: false)
        var suggestion = FolderSuggestion(folderName: "Test", files: [file])
        
        suggestion.addTag("Tag1", for: file)
        suggestion.addTag("Tag1", for: file) // Duplicate
        
        let tags = suggestion.tags(for: file)
        XCTAssertEqual(tags.count, 1) // Should not add duplicate
    }
    
    func testTagsForFileInNestedFolder() {
        let file = FileItem(path: "/test/nested/file.txt", name: "file", extension: "txt", size: 100, isDirectory: false)
        let tagMapping = FileTagMapping(originalFile: file, tags: ["Nested"])
        
        let subfolder = FolderSuggestion(
            folderName: "Subfolder",
            files: [file],
            fileTagMappings: [tagMapping]
        )
        
        let parent = FolderSuggestion(
            folderName: "Parent",
            subfolders: [subfolder]
        )
        
        let tags = parent.tags(for: file)
        XCTAssertEqual(tags.count, 1)
        XCTAssertTrue(tags.contains("Nested"))
    }
    
    func testTagsForNonexistentFile() {
        let file = FileItem(path: "/test/file.txt", name: "file", extension: "txt", size: 100, isDirectory: false)
        let otherFile = FileItem(path: "/test/other.txt", name: "other", extension: "txt", size: 100, isDirectory: false)
        
        let suggestion = FolderSuggestion(folderName: "Test", files: [file])
        
        let tags = suggestion.tags(for: otherFile)
        XCTAssertTrue(tags.isEmpty)
    }
    
    // MARK: - Rename Count Tests
    
    func testRenameCount() {
        let file1 = FileItem(path: "/test/file1.txt", name: "file1", extension: "txt", size: 100, isDirectory: false)
        let file2 = FileItem(path: "/test/file2.txt", name: "file2", extension: "txt", size: 100, isDirectory: false)
        let file3 = FileItem(path: "/test/file3.txt", name: "file3", extension: "txt", size: 100, isDirectory: false)
        
        let rename1 = FileRenameMapping(originalFile: file1, suggestedName: "renamed1.txt")
        let rename2 = FileRenameMapping(originalFile: file2, suggestedName: "renamed2.txt")
        let noRename = FileRenameMapping(originalFile: file3) // No rename
        
        let suggestion = FolderSuggestion(
            folderName: "Test",
            files: [file1, file2, file3],
            fileRenameMappings: [rename1, rename2, noRename]
        )
        
        XCTAssertEqual(suggestion.renameCount, 2)
    }
    
    func testRenameCountWithNestedFolders() {
        let file1 = FileItem(path: "/test/file1.txt", name: "file1", extension: "txt", size: 100, isDirectory: false)
        let file2 = FileItem(path: "/test/nested/file2.txt", name: "file2", extension: "txt", size: 100, isDirectory: false)
        
        let rename1 = FileRenameMapping(originalFile: file1, suggestedName: "renamed1.txt")
        let rename2 = FileRenameMapping(originalFile: file2, suggestedName: "renamed2.txt")
        
        let subfolder = FolderSuggestion(
            folderName: "Nested",
            files: [file2],
            fileRenameMappings: [rename2]
        )
        
        let parent = FolderSuggestion(
            folderName: "Parent",
            files: [file1],
            subfolders: [subfolder],
            fileRenameMappings: [rename1]
        )
        
        XCTAssertEqual(parent.renameCount, 2)
    }
    
    // MARK: - Rename Mapping Retrieval Tests
    
    func testRenameMappingForFile() {
        let file = FileItem(path: "/test/file.txt", name: "file", extension: "txt", size: 100, isDirectory: false)
        let rename = FileRenameMapping(originalFile: file, suggestedName: "renamed.txt")
        
        let suggestion = FolderSuggestion(
            folderName: "Test",
            files: [file],
            fileRenameMappings: [rename]
        )
        
        let mapping = suggestion.renameMapping(for: file)
        XCTAssertNotNil(mapping)
        XCTAssertEqual(mapping?.suggestedName, "renamed.txt")
    }
    
    func testRenameMappingForFileInNested() {
        let file = FileItem(path: "/test/nested/file.txt", name: "file", extension: "txt", size: 100, isDirectory: false)
        let rename = FileRenameMapping(originalFile: file, suggestedName: "renamed.txt")
        
        let subfolder = FolderSuggestion(
            folderName: "Nested",
            files: [file],
            fileRenameMappings: [rename]
        )
        
        let parent = FolderSuggestion(
            folderName: "Parent",
            subfolders: [subfolder]
        )
        
        let mapping = parent.renameMapping(for: file)
        XCTAssertNotNil(mapping)
        XCTAssertEqual(mapping?.suggestedName, "renamed.txt")
    }
    
    // MARK: - Files With Final Names Tests
    
    func testFilesWithFinalNames() {
        let file1 = FileItem(path: "/test/file1.txt", name: "file1", extension: "txt", size: 100, isDirectory: false)
        let file2 = FileItem(path: "/test/file2.txt", name: "file2", extension: "txt", size: 100, isDirectory: false)
        
        let rename1 = FileRenameMapping(originalFile: file1, suggestedName: "renamed1.txt")
        
        let suggestion = FolderSuggestion(
            folderName: "Test",
            files: [file1, file2],
            fileRenameMappings: [rename1]
        )
        
        let withNames = suggestion.filesWithFinalNames
        
        XCTAssertEqual(withNames.count, 2)
        XCTAssertEqual(withNames[0].finalName, "renamed1.txt")
        XCTAssertEqual(withNames[1].finalName, file2.displayName)
    }
    
    // MARK: - Mutating Helper Tests
    
    func testAddFileWithRename() {
        var suggestion = FolderSuggestion(folderName: "Test")
        
        let file = FileItem(path: "/test/file.txt", name: "file", extension: "txt", size: 100, isDirectory: false)
        suggestion.addFile(file, suggestedName: "new_name.txt", renameReason: "Better name")
        
        XCTAssertEqual(suggestion.files.count, 1)
        XCTAssertEqual(suggestion.fileRenameMappings.count, 1)
        XCTAssertEqual(suggestion.fileRenameMappings.first?.suggestedName, "new_name.txt")
    }
    
    func testAddFileWithoutRename() {
        var suggestion = FolderSuggestion(folderName: "Test")
        
        let file = FileItem(path: "/test/file.txt", name: "file", extension: "txt", size: 100, isDirectory: false)
        suggestion.addFile(file)
        
        XCTAssertEqual(suggestion.files.count, 1)
        XCTAssertTrue(suggestion.fileRenameMappings.isEmpty)
    }
    
    func testRemoveFile() {
        let file1 = FileItem(path: "/test/file1.txt", name: "file1", extension: "txt", size: 100, isDirectory: false)
        let file2 = FileItem(path: "/test/file2.txt", name: "file2", extension: "txt", size: 100, isDirectory: false)
        
        let rename1 = FileRenameMapping(originalFile: file1, suggestedName: "renamed.txt")
        
        var suggestion = FolderSuggestion(
            folderName: "Test",
            files: [file1, file2],
            fileRenameMappings: [rename1]
        )
        
        suggestion.removeFile(file1)
        
        XCTAssertEqual(suggestion.files.count, 1)
        XCTAssertTrue(suggestion.fileRenameMappings.isEmpty) // Should remove rename mapping too
    }
    
    func testUpdateRename() {
        let file = FileItem(path: "/test/file.txt", name: "file", extension: "txt", size: 100, isDirectory: false)
        let rename = FileRenameMapping(originalFile: file, suggestedName: "old_name.txt")
        
        var suggestion = FolderSuggestion(
            folderName: "Test",
            files: [file],
            fileRenameMappings: [rename]
        )
        
        suggestion.updateRename(for: file, newName: "new_name.txt", reason: "Updated reason")
        
        XCTAssertEqual(suggestion.fileRenameMappings.count, 1)
        XCTAssertEqual(suggestion.fileRenameMappings.first?.suggestedName, "new_name.txt")
        XCTAssertEqual(suggestion.fileRenameMappings.first?.renameReason, "Updated reason")
    }
    
    func testUpdateRenameForNewFile() {
        let file = FileItem(path: "/test/file.txt", name: "file", extension: "txt", size: 100, isDirectory: false)
        var suggestion = FolderSuggestion(folderName: "Test", files: [file])
        
        suggestion.updateRename(for: file, newName: "new_name.txt")
        
        XCTAssertEqual(suggestion.fileRenameMappings.count, 1)
        XCTAssertEqual(suggestion.fileRenameMappings.first?.suggestedName, "new_name.txt")
    }

    func testFileRenameMappingPreservesOriginalExtension() {
        let file = FileItem(path: "/test/photo.jpg", name: "photo", extension: "jpg", size: 100, isDirectory: false)
        let mapping = FileRenameMapping(originalFile: file, suggestedName: "renamed.png")

        XCTAssertEqual(mapping.suggestedName, "renamed.jpg")
        XCTAssertTrue(mapping.preservesOriginalExtension)
    }

    func testFileRenameMappingConfidenceClampsAndFlagsLowConfidence() {
        let file = FileItem(path: "/test/file.txt", name: "file", extension: "txt", size: 100, isDirectory: false)

        let low = FileRenameMapping(originalFile: file, suggestedName: "uncertain.txt", renameConfidence: 0.1)
        XCTAssertTrue(low.isLowConfidence)
        XCTAssertTrue(low.isAutoSkippedForLowConfidence)
        XCTAssertEqual(low.finalFilename, file.displayName)

        let high = FileRenameMapping(originalFile: file, suggestedName: "renamed.txt", renameConfidence: 1.4)
        XCTAssertEqual(high.renameConfidence, 1.0)
        XCTAssertFalse(high.isLowConfidence)
        XCTAssertTrue(high.shouldApplyRename)
    }

    func testOrganizeModePlanEnforcerStripsAllRenameIntent() {
        var file = FileItem(
            path: "/test/file.txt",
            name: "file",
            extension: "txt",
            suggestedFilename: "legacy-name.txt"
        )
        file.suggestedFilename = "legacy-name.txt"
        let mapping = FileRenameMapping(originalFile: file, suggestedName: "renamed.txt")
        let nested = FolderSuggestion(
            folderName: "Nested",
            files: [file],
            fileRenameMappings: [mapping]
        )
        let plan = OrganizationPlan(
            suggestions: [FolderSuggestion(folderName: "Documents", subfolders: [nested])]
        )

        let enforced = OrganizationModePlanEnforcer.enforce(
            plan,
            mode: .organize,
            baseURL: URL(fileURLWithPath: "/test")
        )

        let enforcedNested = enforced.suggestions[0].subfolders[0]
        XCTAssertTrue(enforcedNested.fileRenameMappings.isEmpty)
        XCTAssertNil(enforcedNested.files[0].suggestedFilename)
    }

    func testRenameOnlyPlanEnforcerKeepsFilesInTheirSourceFolders() {
        let rootFile = FileItem(path: "/test/root.pdf", name: "root", extension: "pdf")
        let nestedFile = FileItem(path: "/test/Receipts/scan.pdf", name: "scan", extension: "pdf")
        let rootRename = FileRenameMapping(originalFile: rootFile, suggestedName: "report.pdf")
        let nestedRename = FileRenameMapping(originalFile: nestedFile, suggestedName: "receipt.pdf")
        let unsafeModelGrouping = FolderSuggestion(
            folderName: "AI Invented Destination",
            files: [rootFile, nestedFile],
            fileRenameMappings: [rootRename, nestedRename]
        )
        let plan = OrganizationPlan(suggestions: [unsafeModelGrouping])

        let enforced = OrganizationModePlanEnforcer.enforce(
            plan,
            mode: .renameOnly,
            baseURL: URL(fileURLWithPath: "/test")
        )

        XCTAssertEqual(Set(enforced.suggestions.map(\.folderName)), Set(["", "Receipts"]))
        XCTAssertEqual(
            enforced.suggestions.first(where: { $0.folderName.isEmpty })?.files,
            [rootFile]
        )
        XCTAssertEqual(
            enforced.suggestions.first(where: { $0.folderName == "Receipts" })?.files,
            [nestedFile]
        )
        XCTAssertEqual(enforced.suggestions.reduce(0) { $0 + $1.renameCount }, 2)
    }

    func testRenameOnlyPlanEnforcerRejectsFilesOutsideWatchedRoot() {
        let outsideFile = FileItem(path: "/private/outside.txt", name: "outside", extension: "txt")
        let mapping = FileRenameMapping(originalFile: outsideFile, suggestedName: "renamed.txt")
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(folderName: "Unsafe", files: [outsideFile], fileRenameMappings: [mapping])
        ])

        let enforced = OrganizationModePlanEnforcer.enforce(
            plan,
            mode: .renameOnly,
            baseURL: URL(fileURLWithPath: "/test")
        )

        XCTAssertTrue(enforced.suggestions.isEmpty)
        XCTAssertEqual(enforced.unorganizedFiles, [outsideFile])
    }

    func testRenameOnlyValidationAllowsExistingDeepSourceFolders() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nestedURL = rootURL.appendingPathComponent("A/B/C/D", isDirectory: true)
        let fileURL = nestedURL.appendingPathComponent("scan.pdf")
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: fileURL.path, contents: Data("test".utf8))
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let file = FileItem(path: fileURL.path, name: "scan", extension: "pdf")
        let mapping = FileRenameMapping(originalFile: file, suggestedName: "receipt.pdf")
        let modelPlan = OrganizationPlan(suggestions: [
            FolderSuggestion(folderName: "Made Up", files: [file], fileRenameMappings: [mapping])
        ])
        let enforced = OrganizationModePlanEnforcer.enforce(
            modelPlan,
            mode: .renameOnly,
            baseURL: rootURL
        )

        XCTAssertNoThrow(
            try FileOrganizationValidator.validate(
                enforced,
                at: rootURL,
                mode: .renameOnly
            )
        )
    }

    func testValidationAllowsContextSupportedPlansWithManyTopLevelFolders() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let suggestions = try (1...24).map { index in
            let fileURL = rootURL.appendingPathComponent("source-\(index).txt")
            try Data("test".utf8).write(to: fileURL)
            let file = FileItem(path: fileURL.path, name: "source-\(index)", extension: "txt")
            return FolderSuggestion(folderName: "Category \(index)", files: [file])
        }
        let plan = OrganizationPlan(suggestions: suggestions)

        XCTAssertNoThrow(
            try FileOrganizationValidator.validate(plan, at: rootURL)
        )
    }

    func testDestinationHierarchyNormalizationMergesFlattenedAndNestedBatchPaths() throws {
        let flattenedFile = FileItem(
            path: "/test/flattened.png",
            name: "flattened",
            extension: "png"
        )
        let nestedFile = FileItem(
            path: "/test/nested.png",
            name: "nested",
            extension: "png"
        )
        let plan = OrganizationPlan(suggestions: [
            FolderSuggestion(
                folderName: "CodexBar Project Files/Images And Icons",
                files: [flattenedFile]
            ),
            FolderSuggestion(
                folderName: "CodexBar Project Files",
                subfolders: [
                    FolderSuggestion(
                        folderName: "Images And Icons",
                        files: [nestedFile]
                    )
                ]
            )
        ])

        let normalized = FolderOrganizer.normalizingDestinationHierarchy(in: plan)
        let parent = try XCTUnwrap(normalized.suggestions.first)
        let child = try XCTUnwrap(parent.subfolders.first)

        XCTAssertEqual(normalized.suggestions.count, 1)
        XCTAssertEqual(parent.folderName, "CodexBar Project Files")
        XCTAssertEqual(parent.subfolders.count, 1)
        XCTAssertEqual(child.folderName, "Images And Icons")
        XCTAssertEqual(Set(child.files.map(\.id)), Set([flattenedFile.id, nestedFile.id]))
    }
}
