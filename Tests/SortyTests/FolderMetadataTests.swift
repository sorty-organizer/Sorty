
import XCTest
@testable import SortyLib
@testable import SortyCore

final class FolderMetadataTests: XCTestCase {
    
    func testFolderLevelTagsAndComment() throws {
        let json = """
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
        
        let files = [
            FileItem(path: "/path/report.pdf", name: "report", extension: "pdf", size: 100, isDirectory: false)
        ]
        
        let plan = try ResponseParser.parseResponse(json, originalFiles: files)
        
        XCTAssertEqual(plan.suggestions.count, 1)
        let suggestion = plan.suggestions[0]
        
        XCTAssertEqual(suggestion.folderName, "Work")
        XCTAssertEqual(suggestion.tags, ["Urgent", "Internal"])
        XCTAssertEqual(suggestion.comment, "Move these to the NAS after processing")
    }
    
    func testFolderMetadataWithEmptyFields() throws {
        let json = """
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
        
        let files = [
            FileItem(path: "/path/old.txt", name: "old", extension: "txt", size: 50, isDirectory: false)
        ]
        
        let plan = try ResponseParser.parseResponse(json, originalFiles: files)
        
        XCTAssertEqual(plan.suggestions.count, 1)
        let suggestion = plan.suggestions[0]
        
        XCTAssertEqual(suggestion.tags.count, 0)
        XCTAssertTrue(suggestion.comment == nil || suggestion.comment?.isEmpty == true)
    }
    
    func testFolderMetadataMissingFields() throws {
        let json = """
        {
          "folders": [
            {
              "name": "Documents",
              "files": ["doc.doc"]
            }
          ]
        }
        """
        
        let files = [
            FileItem(path: "/path/doc.doc", name: "doc", extension: "doc", size: 50, isDirectory: false)
        ]
        
        let plan = try ResponseParser.parseResponse(json, originalFiles: files)
        
        XCTAssertEqual(plan.suggestions.count, 1)
        let suggestion = plan.suggestions[0]
        
        XCTAssertEqual(suggestion.tags, [])
        XCTAssertNil(suggestion.comment)
    }

    func testNestedFolderMetadata() throws {
        let json = """
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
        
        let files = [
            FileItem(path: "/path/a.txt", name: "a", extension: "txt", size: 50, isDirectory: false)
        ]
        
        let plan = try ResponseParser.parseResponse(json, originalFiles: files)
        
        XCTAssertEqual(plan.suggestions.count, 1)
        let parent = plan.suggestions[0]
        XCTAssertEqual(parent.tags, ["Global"])
        
        XCTAssertEqual(parent.subfolders.count, 1)
        let child = parent.subfolders[0]
        XCTAssertEqual(child.tags, ["LocalA"])
        XCTAssertEqual(child.comment, "Specific to A")
    }
}
