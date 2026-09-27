import XCTest
@testable import SortyLib
@testable import SortyCore

/// Focused tests for the live-organization stream parser that drives the
/// files-flying-into-folders animation while the AI response streams in.
final class OrganizingStreamSuggestionsTests: XCTestCase {

    private func makeFile(_ filename: String, directory: String = "/test") -> FileItem {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(filename)
        return FileItem(
            path: url.path,
            name: url.deletingPathExtension().lastPathComponent,
            extension: url.pathExtension,
            size: 1_024
        )
    }

    private func makeFiles(_ names: [String]) -> ([FileItem], [Int: FileItem]) {
        let files = names.map { makeFile($0) }
        let table = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($0.offset + 1, $0.element) })
        return (files, table)
    }

    // MARK: - Preferred compact format (file_ids)

    func testParsesPreferredFileIDsFormat() {
        let (files, table) = makeFiles(["report.pdf", "photo.jpg", "notes.txt"])
        let stream = #"{"folder_assignments":[{"name":"Documents","file_ids":[1,3]},{"name":"Photos","file_ids":[2]}],"notes":""}"#

        let suggestions = OrganizingStreamSuggestions.parse(from: stream, files: files, fileIDTable: table)

        XCTAssertEqual(suggestions.map(\.folderName), ["Documents", "Photos"])
        XCTAssertEqual(suggestions[0].files.map(\.displayName), ["report.pdf", "notes.txt"])
        XCTAssertEqual(suggestions[1].files.map(\.displayName), ["photo.jpg"])
    }

    func testUnclosedFileIDsArrayDropsTrailingNumber() {
        let (files, table) = makeFiles(["a.pdf", "b.pdf", "c.pdf", "d.pdf", "e.pdf", "f.pdf",
                                        "g.pdf", "h.pdf", "i.pdf", "j.pdf", "k.pdf", "l.pdf"])
        // Streaming stopped mid-array right after "1"; that could still become
        // "12", so it must not resolve yet. Completed IDs before it parse.
        let stream = #"{"folder_assignments":[{"name":"Docs","file_ids":[2,3,1"#

        let suggestions = OrganizingStreamSuggestions.parse(from: stream, files: files, fileIDTable: table)

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].files.map(\.displayName), ["b.pdf", "c.pdf"])
    }

    func testFileIDsWithRenameSuggestions() {
        let (files, table) = makeFiles(["IMG_0001.jpg", "scan.pdf"])
        let stream = #"""
        {"folder_assignments":[{"name":"Photos","file_ids":[1,2],"rename_suggestions":[{"file_id":1,"suggested_name":"Beach Sunset.jpg","rename_reason":"EXIF","rename_confidence":0.9}]}]}
        """#

        let suggestions = OrganizingStreamSuggestions.parse(from: stream, files: files, fileIDTable: table)

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].files.count, 2)
        XCTAssertEqual(suggestions[0].fileRenameMappings.count, 1)
        XCTAssertEqual(suggestions[0].fileRenameMappings.first?.suggestedName, "Beach Sunset.jpg")
        XCTAssertEqual(suggestions[0].fileRenameMappings.first?.originalFile.displayName, "IMG_0001.jpg")
    }

    // MARK: - Legacy formats

    func testParsesLegacyPlainStringFilesArray() {
        let (files, _) = makeFiles(["report.pdf", "photo.jpg"])
        let stream = #"{"folders":[{"name":"Documents","files":["report.pdf"],"subfolders":[]},{"name":"Photos","files":["photo.jpg"]}]}"#

        let suggestions = OrganizingStreamSuggestions.parse(from: stream, files: files)

        XCTAssertEqual(suggestions.map(\.folderName), ["Documents", "Photos"])
        XCTAssertEqual(suggestions[0].files.map(\.displayName), ["report.pdf"])
        XCTAssertEqual(suggestions[1].files.map(\.displayName), ["photo.jpg"])
    }

    func testParsesLegacyFilenameObjectFormat() {
        let (files, _) = makeFiles(["IMG_0001.jpg"])
        let stream = #"{"folders":[{"name":"Photos","files":[{"filename":"IMG_0001.jpg","suggested_name":"Beach.jpg"}]}]}"#

        let suggestions = OrganizingStreamSuggestions.parse(from: stream, files: files)

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].files.map(\.displayName), ["IMG_0001.jpg"])
        XCTAssertEqual(suggestions[0].fileRenameMappings.first?.suggestedName, "Beach.jpg")
    }

    // MARK: - Robustness

    func testEscapedCharactersInNamesParse() {
        let (files, table) = makeFiles(["notes.txt"])
        // Folder name contains an escaped quote; the capture must not stop there.
        let stream = #"{"folder_assignments":[{"name":"Bob\"s Files","file_ids":[1]}]}"#

        let suggestions = OrganizingStreamSuggestions.parse(from: stream, files: files, fileIDTable: table)

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].folderName, #"Bob"s Files"#)
    }

    func testDuplicateBasenamesAreNotResolvedByName() {
        let first = makeFile("report.pdf", directory: "/test/a")
        let second = makeFile("report.pdf", directory: "/test/b")
        let stream = #"{"folders":[{"name":"Docs","files":["report.pdf"]}]}"#

        let suggestions = OrganizingStreamSuggestions.parse(from: stream, files: [first, second])

        // Ambiguous basename: never animate an arbitrary one of the two files.
        // The folder itself may still surface as pending (no files).
        XCTAssertTrue(suggestions.allSatisfy { $0.files.isEmpty })
    }

    func testEmptyFileIDTableDoesNotInventFiles() {
        let (files, _) = makeFiles(["report.pdf"])
        let stream = #"{"folder_assignments":[{"name":"Docs","file_ids":[1]}]}"#

        // Without a table the IDs cannot resolve; the folder may show as
        // pending, but no file may be guessed.
        let suggestions = OrganizingStreamSuggestions.parse(from: stream, files: files)
        XCTAssertTrue(suggestions.allSatisfy { $0.files.isEmpty })
    }

    func testFolderBeingGeneratedAppearsAsPending() {
        let (files, table) = makeFiles(["report.pdf", "photo.jpg"])
        // "Photos" has a complete name but its assignments are still streaming.
        let stream = #"{"folder_assignments":[{"name":"Documents","file_ids":[1]},{"name":"Photos","file_i"#

        let suggestions = OrganizingStreamSuggestions.parse(from: stream, files: files, fileIDTable: table)

        XCTAssertEqual(suggestions.map(\.folderName), ["Documents", "Photos"])
        XCTAssertEqual(suggestions[0].files.map(\.displayName), ["report.pdf"])
        XCTAssertTrue(suggestions[1].files.isEmpty, "Pending folder must not invent files")
    }

    func testPendingFolderRequiresCompleteName() {
        let (files, table) = makeFiles(["report.pdf"])
        // The second folder's name is still streaming; it must not appear.
        let stream = #"{"folder_assignments":[{"name":"Documents","file_ids":[1]},{"name":"Pho"#

        let suggestions = OrganizingStreamSuggestions.parse(from: stream, files: files, fileIDTable: table)

        XCTAssertEqual(suggestions.map(\.folderName), ["Documents"])
    }
}
