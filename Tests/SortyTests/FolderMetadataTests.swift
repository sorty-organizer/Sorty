
import XCTest
@testable import SortyLib
@testable import SortyCore
@testable import SortyAI
@testable import SortyModels

final class FolderMetadataTests: XCTestCase {
    
    func testFolderMetadataVariants() throws {
        // Row 1: full tags and comment.
        let fullJson = """
        {
          "folders": [
            {
              "name": "Work",
              "description": "Work related documents",
              "tags": ["Urgent", "Internal"],
              "comment": "Move these to the NAS after processing",
              "files": ["report.pdf"]
            }
          ]
        }
        """

        let fullFiles = [
            FileItem(path: "/path/report.pdf", name: "report", extension: "pdf", size: 100, isDirectory: false)
        ]

        let fullPlan = try ResponseParser.parseResponse(fullJson, originalFiles: fullFiles)

        XCTAssertEqual(fullPlan.suggestions.count, 1)
        let fullSuggestion = fullPlan.suggestions[0]

        XCTAssertEqual(fullSuggestion.folderName, "Work")
        XCTAssertEqual(fullSuggestion.tags, ["Urgent", "Internal"])
        XCTAssertEqual(fullSuggestion.comment, "Move these to the NAS after processing")

        // Row 2: empty tags and comment.
        let emptyJson = """
        {
          "folders": [
            {
              "name": "Archive",
              "tags": [],
              "comment": "",
              "files": ["old.txt"]
            }
          ]
        }
        """

        let emptyFiles = [
            FileItem(path: "/path/old.txt", name: "old", extension: "txt", size: 50, isDirectory: false)
        ]

        let emptyPlan = try ResponseParser.parseResponse(emptyJson, originalFiles: emptyFiles)

        XCTAssertEqual(emptyPlan.suggestions.count, 1)
        let emptySuggestion = emptyPlan.suggestions[0]

        XCTAssertEqual(emptySuggestion.tags.count, 0)
        XCTAssertTrue(emptySuggestion.comment == nil || emptySuggestion.comment?.isEmpty == true)

        // Row 3: missing tags and comment fields.
        let missingJson = """
        {
          "folders": [
            {
              "name": "Documents",
              "files": ["doc.doc"]
            }
          ]
        }
        """

        let missingFiles = [
            FileItem(path: "/path/doc.doc", name: "doc", extension: "doc", size: 50, isDirectory: false)
        ]

        let missingPlan = try ResponseParser.parseResponse(missingJson, originalFiles: missingFiles)

        XCTAssertEqual(missingPlan.suggestions.count, 1)
        let missingSuggestion = missingPlan.suggestions[0]

        XCTAssertEqual(missingSuggestion.tags, [])
        XCTAssertNil(missingSuggestion.comment)

        // Row 4: nested folder metadata.
        let nestedJson = """
        {
          "folders": [
            {
              "name": "Projects",
              "tags": ["Global"],
              "subfolders": [
                {
                  "name": "ProjectA",
                  "tags": ["LocalA"],
                  "comment": "Specific to A",
                  "files": ["a.txt"]
                }
              ],
              "files": []
            }
          ]
        }
        """

        let nestedFiles = [
            FileItem(path: "/path/a.txt", name: "a", extension: "txt", size: 50, isDirectory: false)
        ]

        let nestedPlan = try ResponseParser.parseResponse(nestedJson, originalFiles: nestedFiles)

        XCTAssertEqual(nestedPlan.suggestions.count, 1)
        let parent = nestedPlan.suggestions[0]
        XCTAssertEqual(parent.tags, ["Global"])

        XCTAssertEqual(parent.subfolders.count, 1)
        let child = parent.subfolders[0]
        XCTAssertEqual(child.tags, ["LocalA"])
        XCTAssertEqual(child.comment, "Specific to A")
    }
}
