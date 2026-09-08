//
//  PromptBuilderTests.swift
//  SortyTests
//
//  Tests for PromptBuilder reference-directory context generation
//

import XCTest
@testable import SortyLib

final class PromptBuilderTests: XCTestCase {
    
    private var tempDir: URL!
    
    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptBuilderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    func testSystemPromptUsesOneJSONOnlyContract() {
        let prompt = PromptBuilder.buildSystemPrompt(
            personaInfo: "",
            mode: .organizeAndRename,
            enableTagging: true
        )

        XCTAssertTrue(prompt.contains("The first non-whitespace character MUST be \"{\""))
        XCTAssertTrue(prompt.contains("Return exactly one valid JSON object"))
        XCTAssertFalse(prompt.contains(">>"))
        XCTAssertFalse(prompt.contains("```"))
        XCTAssertFalse(prompt.contains("..."), "Schema examples must themselves be valid JSON.")
    }

    func testSystemPromptAllowsApprovedAbsoluteStoragePaths() {
        let prompt = PromptBuilder.buildSystemPrompt(
            personaInfo: "",
            mode: .organize,
            enableTagging: true
        )

        XCTAssertTrue(prompt.contains("when the user prompt provides `VALID_STORAGE_PATHS`"))
        XCTAssertTrue(prompt.contains("one complete folder \"name\" value"))
        XCTAssertTrue(prompt.contains("copy their spelling and capitalization exactly"))
        XCTAssertFalse(prompt.contains("Folder \"name\" values MUST be a single folder name with no \"/\""))
    }

    func testCompactSystemPromptsDoNotRequestNarrationBeforeJSON() {
        let config = AIConfig(mode: .organize)
        let files = [FileItem(path: "/tmp/report.pdf", name: "report", extension: "pdf")]

        for level in [
            PromptBuilder.CompactionLevel.standard,
            .ultra,
            .summary,
            .micro
        ] {
            let prompt = PromptBuilder.promptPair(for: level, config: config, files: files).system
            XCTAssertTrue(prompt.contains("exactly one JSON object"))
            XCTAssertTrue(prompt.contains("exact shared subject, project, source, date pattern, or compatible file roles"))
            XCTAssertFalse(prompt.contains(">>"))
            XCTAssertFalse(prompt.contains("Before JSON"))
        }
    }

    func testEveryPromptMakesLearningExclusionRareAndExplicit() {
        let files = [FileItem(path: "/tmp/report.pdf", name: "report", extension: "pdf")]
        let fullPrompt = PromptBuilder.buildSystemPrompt(
            personaInfo: "",
            mode: .organize,
            enableTagging: true
        )

        XCTAssertTrue(fullPrompt.contains("learning_action"))
        XCTAssertTrue(fullPrompt.contains("Prefer learning from the run"))
        XCTAssertTrue(fullPrompt.contains("Do not call it because files appear private, sensitive, unusual, temporary"))
        XCTAssertTrue(fullPrompt.contains("do not rename"))

        for level in [
            PromptBuilder.CompactionLevel.standard,
            .ultra,
            .summary,
            .micro
        ] {
            let pair = PromptBuilder.promptPair(
                for: level,
                config: AIConfig(mode: .organize),
                files: files
            )
            let prompt = pair.system + "\n" + pair.user
            XCTAssertTrue(prompt.contains("learning_action"), "Missing tool contract in \(level)")
            XCTAssertTrue(prompt.localizedCaseInsensitiveContains("ambiguity means null"), "Missing conservative default in \(level)")
            XCTAssertTrue(prompt.localizedCaseInsensitiveContains("prefer learning"), "Missing learning bias in \(level)")
            XCTAssertTrue(prompt.contains("exclude_current_run_from_learning"), "Missing exact tool name in \(level)")
        }
    }

    func testEverySystemPromptDelegatesHierarchyToContextWithoutHiddenFolderCap() {
        let config = AIConfig(mode: .organize)
        let files = [FileItem(path: "/tmp/report.pdf", name: "report", extension: "pdf")]

        let fullPrompt = PromptBuilder.buildSystemPrompt(
            personaInfo: "",
            mode: .organize,
            enableTagging: true
        )
        XCTAssertTrue(fullPrompt.contains("There is no preset target or default maximum"))
        XCTAssertTrue(fullPrompt.contains("Direct instructions for the current task"))
        XCTAssertTrue(fullPrompt.contains("Relevant learned preferences"))
        XCTAssertTrue(fullPrompt.contains("Reference or example folders and the existing folder structure"))
        XCTAssertFalse(fullPrompt.localizedCaseInsensitiveContains("hard limit: you must output"))

        for level in [
            PromptBuilder.CompactionLevel.standard,
            .ultra,
            .summary,
            .micro
        ] {
            let prompt = PromptBuilder.promptPair(for: level, config: config, files: files).system
            XCTAssertTrue(prompt.localizedCaseInsensitiveContains("do not apply a preset folder-count limit"), "Missing hierarchy discretion in \(level)")
            XCTAssertTrue(prompt.localizedCaseInsensitiveContains("direct user instructions"), "Missing user priority in \(level)")
            XCTAssertTrue(prompt.localizedCaseInsensitiveContains("learnings"), "Missing learnings context in \(level)")
            XCTAssertTrue(prompt.localizedCaseInsensitiveContains("existing structure"), "Missing existing-folder context in \(level)")
        }
    }

    func testEveryOrganizationPromptTreatsUnorganizedAsLastResort() {
        let config = AIConfig(mode: .organize)
        let files = [FileItem(path: "/tmp/report.pdf", name: "report", extension: "pdf")]

        let fullPrompt = PromptBuilder.buildSystemPrompt(
            personaInfo: "",
            mode: .organize,
            enableTagging: true
        )
        XCTAssertTrue(fullPrompt.contains("a suitable existing folder, a meaningful shared folder, a broad reusable category, and a justified standalone folder"))
        XCTAssertTrue(fullPrompt.contains("Uncertainty alone is not a reason to leave a file unorganized"))
        XCTAssertTrue(fullPrompt.contains("Never create a folder named \"Unorganized\""))

        let userPrompt = PromptBuilder.buildOrganizationPrompt(files: files)
        XCTAssertTrue(userPrompt.contains("Use `unorganized` only when all four options fail"))

        for level in [
            PromptBuilder.CompactionLevel.standard,
            .ultra,
            .summary,
            .micro
        ] {
            let prompt = PromptBuilder.promptPair(for: level, config: config, files: files).system
            XCTAssertTrue(prompt.contains("a suitable existing folder, a meaningful shared folder, a broad reusable category"), "Missing destination checks in \(level)")
            XCTAssertTrue(prompt.localizedCaseInsensitiveContains("uncertainty alone is not enough"), "Missing last-resort threshold in \(level)")
            XCTAssertTrue(prompt.localizedCaseInsensitiveContains("never create an unorganized or unorganized files folder"), "Missing reserved-folder rule in \(level)")
        }
    }

    func testCustomHierarchyInstructionsArePreservedAsMandatoryRequirements() {
        let instructions = "Create exactly 24 top-level folders and keep the hierarchy flat."
        let prompt = PromptBuilder.buildOrganizationPrompt(
            files: [FileItem(path: "/tmp/report.pdf", name: "report", extension: "pdf")],
            customInstructions: instructions
        )

        XCTAssertTrue(prompt.contains("MANDATORY USER REQUIREMENTS"))
        XCTAssertTrue(prompt.contains("USER INSTRUCTIONS: \(instructions)"))
        XCTAssertTrue(prompt.contains("Follow them LITERALLY"))
    }

    func testDirectInstructionsAreDistinguishedFromSupportingOrganizationContext() {
        let directInstructions = "Use no more than four top-level folders."
        let assembledContext = """
        \(PromptBuilder.wrapDirectUserInstructions(directInstructions))

        <learnings_context>
        Prefer detailed project folders.
        </learnings_context>
        """
        let prompt = PromptBuilder.buildOrganizationPrompt(
            files: [FileItem(path: "/tmp/report.pdf", name: "report", extension: "pdf")],
            customInstructions: assembledContext
        )

        XCTAssertTrue(prompt.contains("<user_instructions>\n\(directInstructions)\n</user_instructions>"))
        XCTAssertTrue(prompt.contains("Content inside `<user_instructions>` comes directly from the user and has highest priority"))
        XCTAssertTrue(prompt.contains("MUST NOT override direct user or persona instructions"))
    }

    func testExistingFoldersContextIncludesExactPathAtDepthThirty() throws {
        let components = (1...30).map { "Level-\($0)" }
        let deepFolder = components.reduce(tempDir!) { partialPath, component in
            partialPath.appendingPathComponent(component, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: deepFolder, withIntermediateDirectories: true)

        let context = try XCTUnwrap(PromptBuilder.buildExistingFoldersContext(at: tempDir))
        let deepRelativePath = components.joined(separator: "/")

        XCTAssertTrue(context.contains("- \(deepRelativePath)"))
        XCTAssertTrue(context.contains("one complete destination relative to the watched folder"))
    }

    func testExistingFoldersContextDoesNotDescendIntoSymlinkedFolder() throws {
        let externalFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptBuilderExternal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalFolder.appendingPathComponent("Outside", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: externalFolder) }

        let link = tempDir.appendingPathComponent("Linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalFolder)

        let context = PromptBuilder.buildExistingFoldersContext(at: tempDir)

        XCTAssertFalse(context?.contains("Linked/Outside") == true)
    }

    func testEveryCompactionLevelPreservesPerFileEvidence() {
        let metadata = ContentMetadata(
            textPreview: "Vendor appears in the extracted invoice text.",
            documentTitle: "May 2026 Invoice",
            ocrText: "OCR fallback cue"
        )
        let file = FileItem(
            path: "/tmp/Clients/Acme/scan.pdf",
            relativePath: "Clients/Acme/scan.pdf",
            name: "scan",
            extension: "pdf",
            size: 4_096,
            modificationDate: Date(timeIntervalSince1970: 1_715_558_400),
            contentMetadata: metadata
        )
        let config = AIConfig(mode: .organizeAndRename)

        for level in [
            PromptBuilder.CompactionLevel.standard,
            .ultra,
            .summary,
            .micro
        ] {
            let prompt = PromptBuilder.promptPair(for: level, config: config, files: [file]).user
            XCTAssertTrue(prompt.contains("name:scan.pdf"), "Missing filename in \(level)")
            XCTAssertTrue(prompt.contains("path:Clients/Acme/scan.pdf"), "Missing relative path in \(level)")
            XCTAssertTrue(prompt.contains("ext:pdf"), "Missing extension in \(level)")
            XCTAssertTrue(prompt.contains("bytes:4096"), "Missing size in \(level)")
            XCTAssertTrue(prompt.contains("modified:"), "Missing date in \(level)")
            XCTAssertTrue(prompt.contains("title:May 2026 Invoice"), "Missing title in \(level)")
            XCTAssertTrue(prompt.contains("hint:Vendor appears in the extracted invoice text."), "Missing content hint in \(level)")
        }
    }

    func testEveryPromptPathPreservesFinderTagNamesAndVisibleColor() {
        let file = FileItem(
            path: "/tmp/Tax Return.pdf",
            name: "Tax Return",
            extension: "pdf",
            finderTags: ["Taxes", "Needs Review"],
            finderLabelNumber: FinderTagColor.red.rawValue
        )

        let fullPrompt = PromptBuilder.buildOrganizationPrompt(
            files: [file],
            mode: .renameOnly,
            customInstructions: "Rename only red-tagged files."
        )
        XCTAssertTrue(fullPrompt.contains("[finder_tags] Taxes, Needs Review"))
        XCTAssertTrue(fullPrompt.contains("[finder_color] Red"))
        XCTAssertTrue(fullPrompt.contains("Match color phrases such as \"red-tagged\" against `finder_color`"))
        XCTAssertTrue(fullPrompt.contains("Keep every nonmatching filename unchanged"))

        let config = AIConfig(mode: .renameOnly)
        for level in [
            PromptBuilder.CompactionLevel.standard,
            .ultra,
            .summary,
            .micro
        ] {
            let prompts = PromptBuilder.promptPair(for: level, config: config, files: [file])
            let combined = prompts.system + "\n" + prompts.user
            XCTAssertTrue(combined.contains("finder_tags:Taxes,Needs Review"), "Missing Finder tag names in \(level)")
            XCTAssertTrue(combined.contains("finder_color:Red"), "Missing Finder color in \(level)")
            XCTAssertTrue(combined.contains("Color instructions match finder_color"), "Missing tag-selection rule in \(level)")
        }
    }

    func testCompactionPreservesPersonaLearningsAndNamingPolicy() {
        var config = AIConfig(mode: .renameOnly)
        config.namingStyle = .datePrefix
        config.customNamingInstructions = "Put the verified vendor before the document type."
        config.renameRules = [RenameRule(pattern: "^IMG_", replacement: "Photo-")]
        let supportingContext = """
        <user_instructions>
        Never invent client names.
        </user_instructions>
        <learnings_context>
        Learned rule [rule_id: invoice-date]: Invoices use YYYY-MM-DD Vendor Invoice.ext.
        </learnings_context>
        """
        let preserved = PromptBuilder.preservedContext(
            customInstructions: supportingContext,
            personaPrompt: "Prefer client-first names when the source names a client."
        )

        XCTAssertTrue(preserved.contains("<active_persona>"))
        XCTAssertTrue(preserved.contains("Prefer client-first names"))
        XCTAssertTrue(preserved.contains("<user_instructions>"))
        XCTAssertTrue(preserved.contains("rule_id: invoice-date"))

        for level in [
            PromptBuilder.CompactionLevel.standard,
            .ultra,
            .summary,
            .micro
        ] {
            let prompt = PromptBuilder.promptPair(
                for: level,
                config: config,
                files: [FileItem(path: "/tmp/IMG_0042.jpg", name: "IMG_0042", extension: "jpg")]
            ).user
            XCTAssertTrue(prompt.contains(config.namingStyle.promptInstructions))
            XCTAssertTrue(prompt.contains("Put the verified vendor before the document type."))
            XCTAssertTrue(prompt.contains("^IMG_ -> Photo-"))
        }
    }

    func testFastModePromptIncludesFileMetadataButOmitsContent() {
        let file = FileItem(
            path: "/tmp/Reports/quarterly.pdf",
            name: "quarterly",
            extension: "pdf",
            size: 4_096,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_710_000_000),
            contentMetadata: ContentMetadata(textPreview: "Confidential revenue details"),
            finderComment: "Finance team review",
            finderTags: ["Important"]
        )

        let prompt = PromptBuilder.buildOrganizationPrompt(
            files: [file],
            includeContentMetadata: false
        )

        XCTAssertTrue(prompt.contains("quarterly.pdf"))
        XCTAssertTrue(prompt.contains("## FILE METADATA"))
        XCTAssertTrue(prompt.contains("created:"))
        XCTAssertTrue(prompt.contains("[finder_tags]"))
        XCTAssertTrue(prompt.contains("Finance team review"))
        XCTAssertFalse(prompt.contains("Confidential revenue details"))
    }
    
    // MARK: - Empty Input
    
    func testEmptyPathsReturnsEmpty() {
        let result = PromptBuilder.buildReferenceDirectoryContext(paths: [])
        XCTAssertTrue(result.isEmpty)
    }
    
    func testMissingDirectorySkipped() {
        let result = PromptBuilder.buildReferenceDirectoryContext(paths: ["/nonexistent/path/\(UUID().uuidString)"])
        XCTAssertTrue(result.isEmpty)
    }
    
    // MARK: - Single Directory
    
    func testSingleDirectoryWithSubfolders() throws {
        let sub1 = tempDir.appendingPathComponent("Photos")
        let sub2 = tempDir.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: sub1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sub2, withIntermediateDirectories: true)
        
        let result = PromptBuilder.buildReferenceDirectoryContext(paths: [tempDir.path])
        
        XCTAssertTrue(result.contains("REFERENCE MODEL DIRECTORIES"))
        XCTAssertTrue(result.contains("Documents"))
        XCTAssertTrue(result.contains("Photos"))
        XCTAssertTrue(result.contains("reference examples only"))
    }
    
    func testSingleDirectoryEmpty() throws {
        // tempDir exists but has no subdirectories
        let result = PromptBuilder.buildReferenceDirectoryContext(paths: [tempDir.path])
        XCTAssertTrue(result.isEmpty, "Empty directory should produce empty context")
    }
    
    // MARK: - Multi-Directory
    
    func testMultipleDirectories() throws {
        let dir1 = tempDir.appendingPathComponent("Reference1")
        let dir2 = tempDir.appendingPathComponent("Reference2")
        try FileManager.default.createDirectory(at: dir1.appendingPathComponent("Work"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2.appendingPathComponent("Personal"), withIntermediateDirectories: true)
        
        let result = PromptBuilder.buildReferenceDirectoryContext(paths: [dir1.path, dir2.path])
        
        XCTAssertTrue(result.contains("Reference1"))
        XCTAssertTrue(result.contains("Reference2"))
        XCTAssertTrue(result.contains("Work"))
        XCTAssertTrue(result.contains("Personal"))
    }
    
    // MARK: - Truncation
    
    func testTruncationAtMaxEntries() throws {
        // Create more subfolders than the cap
        let maxEntries = 5
        for i in 0..<10 {
            let sub = tempDir.appendingPathComponent("Folder\(String(format: "%02d", i))")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        }
        
        let result = PromptBuilder.buildReferenceDirectoryContext(
            paths: [tempDir.path],
            maxEntriesPerDirectory: maxEntries
        )
        
        XCTAssertTrue(result.contains("truncated"))
        // Count the number of "  - " entries
        let entryCount = result.components(separatedBy: "  - ").count - 1
        XCTAssertEqual(entryCount, maxEntries)
    }
    
    // MARK: - Depth Limit
    
    func testDepthLimit() throws {
        let deep = tempDir
            .appendingPathComponent("L1")
            .appendingPathComponent("L2")
            .appendingPathComponent("L3")
            .appendingPathComponent("L4")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        
        // maxDepth=2 should capture L1, L1/L2 but not L1/L2/L3 or deeper
        let result = PromptBuilder.buildReferenceDirectoryContext(
            paths: [tempDir.path],
            maxDepth: 2
        )
        
        XCTAssertTrue(result.contains("L1"))
        XCTAssertTrue(result.contains("L1/L2"))
        XCTAssertFalse(result.contains("L3"))
        XCTAssertFalse(result.contains("L4"))
    }
    
    func testMixedValidAndInvalidPaths() throws {
        let validDir = tempDir.appendingPathComponent("ValidRef")
        try FileManager.default.createDirectory(at: validDir.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        
        let result = PromptBuilder.buildReferenceDirectoryContext(
            paths: ["/nonexistent/\(UUID().uuidString)", validDir.path]
        )
        
        XCTAssertTrue(result.contains("Projects"))
        XCTAssertTrue(result.contains("REFERENCE MODEL DIRECTORIES"))
    }

    func testDirectoryManifestContextIncludesRelativePathsAndExtensionSummary() throws {
        let invoicesDir = tempDir.appendingPathComponent("Invoices")
        try FileManager.default.createDirectory(at: invoicesDir, withIntermediateDirectories: true)

        let invoiceFile = invoicesDir.appendingPathComponent("march.pdf")
        let noteFile = tempDir.appendingPathComponent("notes.txt")
        try Data("pdf".utf8).write(to: invoiceFile)
        try "hello".write(to: noteFile, atomically: true, encoding: .utf8)

        let files = [
            FileItem(path: invoiceFile.path, name: "march", extension: "pdf", size: 3),
            FileItem(path: noteFile.path, name: "notes", extension: "txt", size: 5)
        ]

        let context = PromptBuilder.buildDirectoryManifestContext(
            baseDirectoryURL: tempDir,
            files: files
        )

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("SOURCE FOLDER CONTEXT") ?? false)
        XCTAssertTrue(context?.contains("Invoices/march.pdf") ?? false)
        XCTAssertTrue(context?.contains("Directory metadata in scope (2 total)") ?? false)
        XCTAssertTrue(context?.contains("- Invoices") ?? false)
        XCTAssertTrue(context?.contains("notes.txt") ?? false)
        XCTAssertTrue(context?.contains("pdf:1") ?? false)
        XCTAssertTrue(context?.contains("txt:1") ?? false)
    }

    func testDirectoryManifestIncludesFileFinderMetadata() throws {
        let file = FileItem(
            path: tempDir.appendingPathComponent("invoice.pdf").path,
            name: "invoice",
            extension: "pdf",
            finderTags: ["Accounts"],
            finderLabelNumber: FinderTagColor.green.rawValue
        )

        let context = try XCTUnwrap(PromptBuilder.buildDirectoryManifestContext(
            baseDirectoryURL: tempDir,
            files: [file]
        ))

        XCTAssertTrue(context.contains("finder_tags Accounts"))
        XCTAssertTrue(context.contains("finder_color Green"))
    }

    func testFinderTaggedFolderContextIncludesFolderColorAndDescendantRule() throws {
        var taggedFolder = tempDir.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: taggedFolder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.labelNumber = FinderTagColor.red.rawValue
        try taggedFolder.setResourceValues(values)
        let nestedFile = taggedFolder.appendingPathComponent("scan.pdf")

        let context = try XCTUnwrap(PromptBuilder.buildFinderTaggedFolderContext(
            baseDirectoryURL: tempDir,
            files: [FileItem(path: nestedFile.path, name: "scan", extension: "pdf")]
        ))

        XCTAssertTrue(context.contains("- Incoming |"))
        XCTAssertTrue(context.contains("finder_color Red"))
        XCTAssertTrue(context.contains("inherits that folder's match"))
    }

    func testDirectoryManifestContextReturnsNilWhenNoFiles() {
        let context = PromptBuilder.buildDirectoryManifestContext(
            baseDirectoryURL: tempDir,
            files: []
        )

        XCTAssertNil(context)
    }

    func testDirectoryManifestContextTruncatesWhenExceedingMaxEntries() {
        let files = (1...5).map { index in
            FileItem(
                path: tempDir.appendingPathComponent("item\(index).txt").path,
                name: "item\(index)",
                extension: "txt",
                size: 1
            )
        }

        let context = PromptBuilder.buildDirectoryManifestContext(
            baseDirectoryURL: tempDir,
            files: files,
            maxEntries: 3
        )

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("... and 2 more files in scope") ?? false)
        XCTAssertTrue(context?.contains("item1.txt") ?? false)
        XCTAssertTrue(context?.contains("item3.txt") ?? false)
        XCTAssertFalse(context?.contains("item5.txt") ?? true)
    }

    func testDirectoryManifestContextFallsBackToFilenameOutsideBaseDirectory() {
        let externalFilePath = "/tmp/external-report.pdf"
        let context = PromptBuilder.buildDirectoryManifestContext(
            baseDirectoryURL: tempDir,
            files: [
                FileItem(path: externalFilePath, name: "external-report", extension: "pdf", size: 128)
            ]
        )

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("external-report.pdf") ?? false)
    }

    func testOrganizationPromptIncludesCollectedMetadataAndRelativeHierarchy() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = ContentMetadata(
            textPreview: "Quarterly revenue report",
            documentTitle: "Q4 Results",
            exifData: ["camera": "Example Camera", "lens": "35mm"],
            pageCount: 12,
            author: "A. Example",
            creationDate: created,
            keywords: ["finance", "quarterly"],
            ocrText: "Revenue increased",
            ocrConfidence: 0.97,
            detectedKeywords: ["revenue"],
            duration: 42,
            mediaInfo: ["codec": "example"]
        )
        let file = FileItem(
            path: "/Users/example/Work/Reports/Q4.pdf",
            relativePath: "Reports/Q4.pdf",
            name: "Q4",
            extension: "pdf",
            size: 4_096,
            creationDate: created,
            modificationDate: created,
            lastAccessDate: created,
            contentMetadata: metadata,
            sha256Hash: "abc123",
            imageWidth: 1_920,
            imageHeight: 1_080,
            cloudStatus: .synced,
            finderComment: "Ready to file",
            finderTags: ["Work"]
        )

        let prompt = PromptBuilder.buildOrganizationPrompt(
            files: [file],
            includeContentMetadata: true
        )

        XCTAssertTrue(prompt.contains("Reports/Q4.pdf"))
        XCTAssertFalse(prompt.contains("/Users/example"))
        XCTAssertTrue(prompt.contains("4096 bytes"))
        XCTAssertTrue(prompt.contains("accessed:"))
        XCTAssertTrue(prompt.contains("dimensions: 1920x1080"))
        XCTAssertTrue(prompt.contains("cloud status: synced"))
        XCTAssertTrue(prompt.contains("SHA-256: abc123"))
        XCTAssertTrue(prompt.contains("[finder_tags] Work"))
        XCTAssertTrue(prompt.contains("[Finder Comment] Ready to file"))
        XCTAssertTrue(prompt.contains("Author: A. Example"))
        XCTAssertTrue(prompt.contains("OCR confidence: 0.97"))
        XCTAssertTrue(prompt.contains("lens=35mm"))
        XCTAssertTrue(prompt.contains("codec=example"))
        XCTAssertTrue(prompt.contains("Quarterly revenue report"))
    }

    func testCompactPromptIncludesMetadataAndRelativeHierarchy() {
        let file = FileItem(
            path: "/Users/example/Work/Reports/Q4.pdf",
            relativePath: "Reports/Q4.pdf",
            name: "Q4",
            extension: "pdf",
            size: 4_096,
            finderTags: ["Work"]
        )

        let prompt = PromptBuilder.buildCompactPrompt(files: [file])

        XCTAssertTrue(prompt.contains("Reports/Q4.pdf"))
        XCTAssertTrue(prompt.contains("bytes:4096"))
        XCTAssertTrue(prompt.contains("tags:Work"))
        XCTAssertFalse(prompt.contains("/Users/example"))
    }
}
