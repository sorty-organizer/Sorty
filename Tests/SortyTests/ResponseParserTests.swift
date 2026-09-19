
import XCTest
@testable import SortyLib

class ResponseParserTests: XCTestCase {
    
    func testValidJSONParsing() throws {
        let json = """
        {
          "session_name": "Vacation Photos",
          "folders": [
            {
              "name": "Images",
              "description": "Photo files",
              "reasoning": "Detected image extensions",
              "files": ["vacation.jpg", "profile.png"]
            }
          ],
          "notes": "Organized by file type"
        }
        """
        
        let files = [
            FileItem(path: "/path/vacation.jpg", name: "vacation", extension: "jpg", size: 100, isDirectory: false),
            FileItem(path: "/path/profile.png", name: "profile", extension: "png", size: 200, isDirectory: false),
            FileItem(path: "/path/notes.txt", name: "notes", extension: "txt", size: 50, isDirectory: false)
        ]
        
        let plan = try ResponseParser.parseResponse(json, originalFiles: files)
        
        XCTAssertEqual(plan.suggestions.count, 1)
        XCTAssertEqual(plan.suggestions.first?.folderName, "Images")
        XCTAssertEqual(plan.suggestions.first?.files.count, 2)
        XCTAssertEqual(plan.sessionName, "Vacation Photos")
        // notes.txt is never mapped by the model, so the plan is partial and
        // the notes carry the review hint instead of staying silently valid.
        XCTAssertTrue(plan.notes.hasPrefix("Organized by file type"))
        XCTAssertTrue(plan.notes.contains("Partial plan"))
        XCTAssertTrue(plan.isPartial)
        XCTAssertTrue(plan.needsReview)
        XCTAssertEqual(plan.parseWarnings.count, 1)
        XCTAssertTrue(plan.parseWarnings[0].contains("1 of 3 file(s) were unmapped"))
        XCTAssertEqual(plan.unorganizedFiles.map(\.name), ["notes"])
    }
    
    func testMarkdownWrappedJSONParsing() throws {
        let json = """
        ```json
        {
          "folders": [
            {
              "name": "Docs",
              "files": ["report.pdf"]
            }
          ]
        }
        ```
        """
        
        let files = [FileItem(path: "/path/report.pdf", name: "report", extension: "pdf", size: 100, isDirectory: false)]
        
        let plan = try ResponseParser.parseResponse(json, originalFiles: files)
        
        XCTAssertEqual(plan.suggestions.count, 1)
        XCTAssertEqual(plan.suggestions.first?.folderName, "Docs")
    }

    func testParsingWithBraceNoiseBeforeJSONUsesFinalValidObject() throws {
        let json = """
        Thinking about {project buckets} before final output.
        {
          "folders": [
            {
              "name": "Docs",
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
        XCTAssertEqual(plan.suggestions[0].folderName, "Docs")
        XCTAssertEqual(plan.suggestions[0].files.count, 1)
    }

    func testParsingWithTrailingCommasRecovers() throws {
        let json = """
        {
          "folders": [
            {
              "name": "Docs",
              "files": ["report.pdf",],
            },
          ],
          "unorganized": [],
        }
        """

        let files = [
            FileItem(path: "/path/report.pdf", name: "report", extension: "pdf", size: 100, isDirectory: false)
        ]

        let plan = try ResponseParser.parseResponse(json, originalFiles: files)
        XCTAssertEqual(plan.suggestions.count, 1)
        XCTAssertEqual(plan.suggestions[0].files.count, 1)
        XCTAssertEqual(plan.unorganizedFiles.count, 0)
    }
    
    func testUnorganizedFilesParsing() throws {
        let json = """
        {
          "folders": [],
          "unorganized": [
            {
              "filename": "unknown.xyz",
              "reason": "Unknown file type"
            }
          ]
        }
        """
        
        let files = [FileItem(path: "/path/unknown.xyz", name: "unknown", extension: "xyz", size: 100, isDirectory: false)]
        
        let plan = try ResponseParser.parseResponse(json, originalFiles: files)
        
        XCTAssertEqual(plan.unorganizedDetails.count, 1)
        XCTAssertEqual(plan.unorganizedDetails.first?.filename, "unknown.xyz")
        XCTAssertEqual(plan.unorganizedFiles.count, 1)
    }

    func testUnorganizedStringEntriesParsing() throws {
        let json = """
        {
          "folders": [],
          "unorganized": ["unknown.xyz"]
        }
        """

        let files = [FileItem(path: "/path/unknown.xyz", name: "unknown", extension: "xyz", size: 100, isDirectory: false)]
        let plan = try ResponseParser.parseResponse(json, originalFiles: files)

        XCTAssertEqual(plan.unorganizedDetails.count, 1)
        XCTAssertEqual(plan.unorganizedDetails.first?.filename, "unknown.xyz")
        XCTAssertEqual(plan.unorganizedFiles.count, 1)
    }


    func testParsingWithTags() throws {
        let json = """
        {
          "folders": [
            {
              "name": "TaggedDocs",
              "files": [
                {
                  "filename": "invoice.pdf",
                  "tags": ["Finance", "2024"]
                }
              ]
            }
          ]
        }
        """
        
        let files = [
            FileItem(path: "/path/invoice.pdf", name: "invoice", extension: "pdf", size: 100, isDirectory: false)
        ]
        
        let plan = try ResponseParser.parseResponse(json, originalFiles: files)
        
        XCTAssertEqual(plan.suggestions.count, 1)
        let suggestion = plan.suggestions.first!
        XCTAssertEqual(suggestion.folderName, "TaggedDocs")
        
        // Check tags
        let tags = suggestion.tags(for: files[0])
        XCTAssertEqual(tags.count, 2)
        XCTAssertTrue(tags.contains("Finance"))
        XCTAssertTrue(tags.contains("2024"))
    }


    func testParsingWithFileRenameSuggestions() throws {
        let json = """
        {
          "folders": [
            {
              "name": "Documents",
              "files": [
                {
                  "filename": "old_name.pdf",
                  "suggested_name": "Invoice_2024_Jan.pdf",
                  "rename_reason": "More descriptive name with date"
                }
              ]
            }
          ]
        }
        """
        
        let files = [
            FileItem(path: "/path/old_name.pdf", name: "old_name", extension: "pdf", size: 1000, isDirectory: false)
        ]
        
        let plan = try ResponseParser.parseResponse(json, originalFiles: files, mode: .organizeAndRename)
        
        XCTAssertEqual(plan.suggestions.count, 1)
        let suggestion = plan.suggestions.first!
        
        // Check rename mapping
        XCTAssertEqual(suggestion.fileRenameMappings.count, 1)
        let mapping = suggestion.fileRenameMappings.first!
        XCTAssertEqual(mapping.suggestedName, "Invoice_2024_Jan.pdf")
        XCTAssertEqual(mapping.renameReason, "More descriptive name with date")
    }

    func testOrganizeModeStripsRenameFields() throws {
        let json = """
        {
          "folders": [
            {
              "name": "Documents",
              "files": [
                {
                  "filename": "old_name.pdf",
                  "suggested_name": "Invoice_2024_Jan.pdf",
                  "rename_reason": "More descriptive name with date",
                  "rename_confidence": 0.92
                }
              ]
            }
          ]
        }
        """

        let files = [
            FileItem(path: "/path/old_name.pdf", name: "old_name", extension: "pdf", size: 1000, isDirectory: false)
        ]

        let plan = try ResponseParser.parseResponse(json, originalFiles: files, mode: .organize)
        XCTAssertEqual(plan.suggestions.count, 1)
        XCTAssertEqual(plan.suggestions[0].fileRenameMappings.count, 0)
        XCTAssertEqual(plan.suggestions[0].renameCount, 0)
    }

    func testOrganizeAndRenamePreservesRenameMetadataWhenFileIDsAlsoAssignFile() throws {
        let json = """
        {
          "folders": [
            {
              "name": "Documents",
              "file_ids": [0],
              "files": [
                {
                  "filename": "old_name.pdf",
                  "suggested_name": "Client Invoice.pdf",
                  "rename_reason": "Uses the document subject",
                  "rename_confidence": 0.9
                }
              ]
            }
          ]
        }
        """

        let file = FileItem(
            path: "/path/old_name.pdf",
            name: "old_name",
            extension: "pdf",
            size: 1000,
            isDirectory: false
        )

        let plan = try ResponseParser.parseResponse(
            json,
            originalFiles: [file],
            mode: .organizeAndRename
        )

        XCTAssertEqual(plan.suggestions[0].files, [file])
        XCTAssertEqual(plan.suggestions[0].renameMapping(for: file)?.suggestedName, "Client Invoice.pdf")
    }

    func testRenameOnlyPreservesReasonForUnchangedFile() throws {
        let json = """
        {
          "folders": [
            {
              "name": ".",
              "files": [
                {
                  "filename": "Invoice 2024 Jan.pdf",
                  "rename_reason": "Already uses a clear invoice title, date, and readable spacing.",
                  "rename_confidence": 0.91
                }
              ]
            }
          ]
        }
        """

        let files = [
            FileItem(path: "/path/Invoice 2024 Jan.pdf", name: "Invoice 2024 Jan", extension: "pdf", size: 1000, isDirectory: false)
        ]

        let plan = try ResponseParser.parseResponse(json, originalFiles: files, mode: .renameOnly)
        let mapping = try XCTUnwrap(plan.suggestions[0].fileRenameMappings.first)
        XCTAssertFalse(mapping.hasRename)
        XCTAssertEqual(mapping.renameReason, "Already uses a clear invoice title, date, and readable spacing.")
        XCTAssertEqual(mapping.renameConfidence, 0.91)
    }

    func testLowConfidenceRenameIsAutoSkipped() throws {
        let json = """
        {
          "folders": [
            {
              "name": "Documents",
              "files": [
                {
                  "filename": "old_name.pdf",
                  "suggested_name": "Invoice_2024_Jan.pdf",
                  "rename_reason": "More descriptive name with date",
                  "rename_confidence": 0.2
                }
              ]
            }
          ]
        }
        """

        let files = [
            FileItem(path: "/path/old_name.pdf", name: "old_name", extension: "pdf", size: 1000, isDirectory: false)
        ]

        let plan = try ResponseParser.parseResponse(json, originalFiles: files, mode: .organizeAndRename)
        XCTAssertEqual(plan.suggestions.count, 1)
        XCTAssertEqual(plan.suggestions[0].fileRenameMappings.count, 1)

        let mapping = try XCTUnwrap(plan.suggestions[0].fileRenameMappings.first)
        XCTAssertTrue(mapping.hasRename)
        XCTAssertTrue(mapping.isAutoSkippedForLowConfidence)
        XCTAssertEqual(mapping.renameConfidence, 0.2)
        XCTAssertEqual(mapping.confidenceBand, .low)
        XCTAssertFalse(mapping.shouldApplyRename)
        XCTAssertEqual(mapping.finalFilename, "old_name.pdf")
    }

    func testRenameWithoutConcreteEvidenceIsDowngradedToLowConfidence() throws {
        let json = """
        {
          "folders": [
            {
              "name": ".",
              "files": [
                {
                  "filename": "scan.pdf",
                  "suggested_name": "Acme Invoice.pdf",
                  "rename_reason": "More descriptive",
                  "rename_confidence": 0.96
                }
              ]
            }
          ]
        }
        """
        let file = FileItem(path: "/path/scan.pdf", name: "scan", extension: "pdf")

        let plan = try ResponseParser.parseResponse(json, originalFiles: [file], mode: .renameOnly)
        let mapping = try XCTUnwrap(plan.suggestions[0].fileRenameMappings.first)

        XCTAssertEqual(mapping.confidenceBand, .low)
        XCTAssertFalse(mapping.shouldApplyRename)
        XCTAssertEqual(mapping.renameConfidence, 0.29)
    }
    
    func testParsingWithMultipleTagsPerFile() throws {
        let json = """
        {
          "folders": [
            {
              "name": "Projects",
              "files": [
                {
                  "filename": "project.pdf",
                  "tags": ["Work", "Important", "2024", "Q1"]
                }
              ]
            }
          ]
        }
        """
        
        let files = [
            FileItem(path: "/path/project.pdf", name: "project", extension: "pdf", size: 500, isDirectory: false)
        ]
        
        let plan = try ResponseParser.parseResponse(json, originalFiles: files)
        
        let tags = plan.suggestions.first!.tags(for: files[0])
        XCTAssertEqual(tags.count, 4)
        XCTAssertTrue(tags.contains("Work"))
        XCTAssertTrue(tags.contains("Important"))
        XCTAssertTrue(tags.contains("2024"))
        XCTAssertTrue(tags.contains("Q1"))
    }
    
    func testParsingWithBothRenameAndTags() throws {
        let json = """
        {
          "folders": [
            {
              "name": "Finances",
              "files": [
                {
                  "filename": "scan.pdf",
                  "suggested_name": "Receipt_Amazon_2024-01.pdf",
                  "rename_reason": "Descriptive name",
                  "tags": ["Receipt", "Amazon", "2024"]
                }
              ]
            }
          ]
        }
        """
        
        let files = [
            FileItem(path: "/path/scan.pdf", name: "scan", extension: "pdf", size: 800, isDirectory: false)
        ]
        
        let plan = try ResponseParser.parseResponse(json, originalFiles: files, mode: .organizeAndRename)
        
        let suggestion = plan.suggestions.first!
        
        // Check rename
        XCTAssertEqual(suggestion.fileRenameMappings.count, 1)
        XCTAssertEqual(suggestion.fileRenameMappings.first?.suggestedName, "Receipt_Amazon_2024-01.pdf")
        
        // Check tags
        let tags = suggestion.tags(for: files[0])
        XCTAssertEqual(tags.count, 3)
        XCTAssertTrue(tags.contains("Receipt"))
    }
    
    func testParsingFilesWithoutTags() throws {
        let json = """
        {
          "folders": [
            {
              "name": "NoTags",
              "files": ["simple.txt"]
            }
          ]
        }
        """
        
        let files = [
            FileItem(path: "/path/simple.txt", name: "simple", extension: "txt", size: 100, isDirectory: false)
        ]
        
        let plan = try ResponseParser.parseResponse(json, originalFiles: files)
        
        let tags = plan.suggestions.first!.tags(for: files[0])
        XCTAssertTrue(tags.isEmpty)
    }

    func testDeduplicationAndFuzzyMatching() throws {
        let json = """
        {
          "folders": [
            {
              "name": "Duplicates",
              "files": [
                "CHANGELOG",
                "CHANGELOG",
                "sh",
                "docker-setup"
              ]
            }
          ]
        }
        """
        
        let files = [
            FileItem(path: "/path/CHANGELOG.md", name: "CHANGELOG", extension: "md", size: 100, isDirectory: false),
            FileItem(path: "/path/docker-setup.sh", name: "docker-setup", extension: "sh", size: 200, isDirectory: false)
        ]
        
        let plan = try ResponseParser.parseResponse(json, originalFiles: files)
        
        XCTAssertEqual(plan.suggestions.count, 1)
        let suggestion = plan.suggestions.first!
        
        // Should have 2 unique files: CHANGELOG.md and docker-setup.sh
        XCTAssertEqual(suggestion.files.count, 2)
        XCTAssertTrue(suggestion.files.contains(where: { $0.name == "CHANGELOG" }))
        XCTAssertTrue(suggestion.files.contains(where: { $0.name == "docker-setup" }))
    }

    func testCompactFileIDAssignmentsParsing() throws {
        let json = """
        {
          "folder_assignments": [
            {
              "name": "Documents",
              "file_ids": [1, 3]
            }
          ]
        }
        """

        let files = [
            FileItem(path: "/path/notes.txt", name: "notes", extension: "txt", size: 100, isDirectory: false),
            FileItem(path: "/path/image.png", name: "image", extension: "png", size: 200, isDirectory: false),
            FileItem(path: "/path/report.pdf", name: "report", extension: "pdf", size: 300, isDirectory: false)
        ]

        let plan = try ResponseParser.parseResponse(json, originalFiles: files)
        XCTAssertEqual(plan.suggestions.count, 1)
        let suggestion = plan.suggestions[0]
        XCTAssertEqual(suggestion.folderName, "Documents")
        XCTAssertEqual(suggestion.files.count, 2)
        XCTAssertTrue(suggestion.files.contains(where: { $0.displayName == "notes.txt" }))
        XCTAssertTrue(suggestion.files.contains(where: { $0.displayName == "report.pdf" }))
    }

    func testCompactFileIDAssignmentsCarryRenameSuggestions() throws {
        let json = """
        {
          "folder_assignments": [
            {
              "name": "Documents",
              "file_ids": [1],
              "rename_suggestions": [
                {
                  "file_id": 1,
                  "suggested_name": "Acme Service Agreement.pdf",
                  "rename_reason": "Document title and client name appear in the scanned text",
                  "rename_confidence": 0.94
                }
              ]
            }
          ]
        }
        """

        let file = FileItem(path: "/path/scan0007.pdf", name: "scan0007", extension: "pdf", size: 300, isDirectory: false)
        let plan = try ResponseParser.parseResponse(json, originalFiles: [file], mode: .organizeAndRename)

        let mapping = try XCTUnwrap(plan.suggestions.first?.renameMapping(for: file))
        XCTAssertEqual(mapping.suggestedName, "Acme Service Agreement.pdf")
        XCTAssertEqual(mapping.renameConfidence, 0.94)
    }

    func testCompactAndLegacyFileMappingTogether() throws {
        let json = """
        {
          "folder_assignments": [
            {
              "name": "Mixed",
              "file_ids": [1],
              "files": ["photo.jpg"]
            }
          ]
        }
        """

        let files = [
            FileItem(path: "/path/todo.md", name: "todo", extension: "md", size: 50, isDirectory: false),
            FileItem(path: "/path/photo.jpg", name: "photo", extension: "jpg", size: 150, isDirectory: false)
        ]

        let plan = try ResponseParser.parseResponse(json, originalFiles: files)
        XCTAssertEqual(plan.suggestions.count, 1)
        XCTAssertEqual(plan.suggestions[0].files.count, 2)
    }

    func testResponseWithoutUsableAssignmentsThrows() {
        let json = """
        {
          "folders": [
            {
              "name": "Docs",
              "files": ["missing-file.pdf"]
            }
          ]
        }
        """

        let files = [
            FileItem(path: "/path/report.pdf", name: "report", extension: "pdf", size: 100, isDirectory: false),
            FileItem(path: "/path/image.jpg", name: "image", extension: "jpg", size: 200, isDirectory: false)
        ]

        XCTAssertThrowsError(try ResponseParser.parseResponse(json, originalFiles: files)) { error in
            guard case ParserError.missingRequiredFields = error else {
                return XCTFail("Expected missingRequiredFields, got \(error)")
            }
        }
    }

    func testPathBasedFilenameIsMatchedToOriginalFile() throws {
        let json = """
        {
          "folders": [
            {
              "name": "Documents",
              "files": ["Archive\\\\report.pdf"]
            }
          ]
        }
        """

        let files = [
            FileItem(path: "/path/report.pdf", name: "report", extension: "pdf", size: 100, isDirectory: false)
        ]

        let plan = try ResponseParser.parseResponse(json, originalFiles: files)
        XCTAssertEqual(plan.suggestions.count, 1)
        XCTAssertEqual(plan.suggestions[0].files.count, 1)
        XCTAssertEqual(plan.suggestions[0].files.first?.displayName, "report.pdf")
        XCTAssertEqual(plan.unorganizedFiles.count, 0)
    }

    func testInvalidCompactFileIDsThrow() {
        let json = """
        {
          "folder_assignments": [
            {
              "name": "Invalid",
              "file_ids": [99]
            }
          ]
        }
        """

        let files = [
            FileItem(path: "/path/notes.txt", name: "notes", extension: "txt", size: 100, isDirectory: false),
            FileItem(path: "/path/photo.jpg", name: "photo", extension: "jpg", size: 200, isDirectory: false)
        ]

        XCTAssertThrowsError(try ResponseParser.parseResponse(json, originalFiles: files)) { error in
            guard case ParserError.missingRequiredFields = error else {
                return XCTFail("Expected missingRequiredFields, got \(error)")
            }
        }
    }

    func testDualSchemasPreferAssignmentsThatMapFiles() throws {
        let json = """
        {
          "folder_assignments": [
            {
              "name": "2025",
              "files": ["bridge.jpg", "tulip.jpg"]
            }
          ],
          "folders": [
            {
              "name": "Landscapes & Nature",
              "files": []
            },
            {
              "name": "Bridges & Architecture",
              "files": []
            }
          ],
          "unorganized": []
        }
        """

        let files = [
            FileItem(path: "/path/bridge.jpg", name: "bridge", extension: "jpg", size: 100, isDirectory: false),
            FileItem(path: "/path/tulip.jpg", name: "tulip", extension: "jpg", size: 200, isDirectory: false)
        ]

        let plan = try ResponseParser.parseResponse(json, originalFiles: files)

        XCTAssertEqual(plan.suggestions.map(\.folderName), ["2025"])
        XCTAssertEqual(plan.suggestions.first?.files, files)
        XCTAssertTrue(plan.unorganizedFiles.isEmpty)
    }

    func testProgressCueAndJSONOnSameLineParses() throws {
        let response = #">> general: Ready to output organization structure. {"folders":[{"name":"Docs","files":["report.pdf"]}],"notes":"ok"}"#

        let files = [
            FileItem(path: "/path/report.pdf", name: "report", extension: "pdf", size: 100, isDirectory: false)
        ]

        let plan = try ResponseParser.parseResponse(response, originalFiles: files)
        XCTAssertEqual(plan.suggestions.count, 1)
        XCTAssertEqual(plan.suggestions[0].folderName, "Docs")
        XCTAssertEqual(plan.suggestions[0].files.count, 1)
    }

    func testExtractPartialResultsSupportsCompactFileIDs() {
        let response = """
        >> general: Ready to output organization structure.
        {"folder_assignments":[{"name":"Media","file_ids":[1, 3
        """

        let files = [
            FileItem(path: "/path/bridge.jpg", name: "bridge", extension: "jpg", size: 100, isDirectory: false),
            FileItem(path: "/path/audio.m4a", name: "audio", extension: "m4a", size: 200, isDirectory: false),
            FileItem(path: "/path/fountain.jpg", name: "fountain", extension: "jpg", size: 300, isDirectory: false)
        ]

        let plan = ResponseParser.extractPartialResults(response, originalFiles: files)
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.suggestions.count, 1)
        XCTAssertEqual(plan?.suggestions.first?.folderName, "Media")
        XCTAssertEqual(plan?.suggestions.first?.files.count, 2)
    }

    func testMalformedFolderDoesNotDiscardValidFolders() throws {
        let response = """
        {
          "folders": [
            {
              "description": "Missing the required folder name",
              "files": ["broken.txt"]
            },
            {
              "name": "Documents",
              "files": ["report.pdf"]
            }
          ]
        }
        """

        let files = [
            FileItem(path: "/path/broken.txt", name: "broken", extension: "txt", size: 50, isDirectory: false),
            FileItem(path: "/path/report.pdf", name: "report", extension: "pdf", size: 100, isDirectory: false)
        ]

        let plan = try ResponseParser.parseResponse(response, originalFiles: files)
        XCTAssertEqual(plan.suggestions.count, 1)
        XCTAssertEqual(plan.suggestions.first?.folderName, "Documents")
        XCTAssertEqual(plan.suggestions.first?.files, [files[1]])
        XCTAssertEqual(plan.unorganizedFiles, [files[0]])
    }

    func testEmptyFolderDecodeThrowsSoFallbackCanRun() {
        let response = #"{"folders":[],"notes":"No usable folder assignments"}"#

        XCTAssertThrowsError(
            try ResponseParser.parseResponse(response, originalFiles: [])
        ) { error in
            guard case ParserError.missingRequiredFields = error else {
                return XCTFail("Expected missingRequiredFields, got \(error)")
            }
        }
    }

    func testPartialExtractionKeepsFilesAfterNestedTagArrays() {
        let response = """
        {"folders":[{"name":"Tagged Documents","files":[
          {"filename":"invoice.pdf","tags":["Finance","2026"]},
          {"filename":"report.pdf","tags":["Work","Review"]}
        ]}]
        """

        let files = [
            FileItem(path: "/path/invoice.pdf", name: "invoice", extension: "pdf", size: 100, isDirectory: false),
            FileItem(path: "/path/report.pdf", name: "report", extension: "pdf", size: 200, isDirectory: false)
        ]

        let plan = ResponseParser.extractPartialResults(response, originalFiles: files)
        XCTAssertEqual(plan?.suggestions.count, 1)
        XCTAssertEqual(plan?.suggestions.first?.folderName, "Tagged Documents")
        XCTAssertEqual(plan?.suggestions.first?.files.count, 2)
        XCTAssertEqual(plan?.suggestions.first?.tags(for: files[0]), ["Finance", "2026"])
        XCTAssertEqual(plan?.suggestions.first?.tags(for: files[1]), ["Work", "Review"])
    }

    func testCompactFileIDsResolveWithinLargeInventory() throws {
        let files = (1...25_000).map { index in
            FileItem(
                path: "/large/file-\(index).txt",
                name: "file-\(index)",
                extension: "txt",
                size: Int64(index),
                isDirectory: false
            )
        }
        let response = """
        {
          "folder_assignments": [
            {
              "name": "Selected",
              "file_ids": [1, 12500, 25000]
            }
          ]
        }
        """

        let plan = try ResponseParser.parseResponse(response, originalFiles: files)

        XCTAssertEqual(
            plan.suggestions.first?.files.map(\.displayName),
            ["file-1.txt", "file-12500.txt", "file-25000.txt"]
        )
        XCTAssertEqual(plan.unorganizedFiles.count, 24_997)
    }

    func testLearningExclusionToolCallIsParsedWithoutChangingPlan() throws {
        let file = FileItem(path: "/path/report.pdf", name: "report", extension: "pdf")
        let response = """
        {
          "folder_assignments": [
            {"name": "Reports", "file_ids": [1], "reasoning": "The file is a report."}
          ],
          "learning_action": {
            "name": "exclude_current_run_from_learning",
            "reason": "The user asked not to learn from this run.",
            "source": "direct_instructions"
          }
        }
        """

        let plan = try ResponseParser.parseResponse(response, originalFiles: [file])

        XCTAssertEqual(plan.suggestions.first?.folderName, "Reports")
        XCTAssertEqual(plan.suggestions.first?.files, [file])
        XCTAssertTrue(plan.learningToolCall?.excludesCurrentRun == true)
        XCTAssertEqual(plan.learningToolCall?.source, "direct_instructions")
    }

    func testNullLearningActionPrefersLearning() throws {
        let file = FileItem(path: "/path/report.pdf", name: "report", extension: "pdf")
        let response = """
        {
          "folder_assignments": [
            {"name": "Reports", "file_ids": [1], "reasoning": "The file is a report."}
          ],
          "learning_action": null
        }
        """

        let plan = try ResponseParser.parseResponse(response, originalFiles: [file])

        XCTAssertNil(plan.learningToolCall)
    }
}
