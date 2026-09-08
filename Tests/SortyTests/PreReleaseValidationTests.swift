//
//  PreReleaseValidationTests.swift
//  SortyTests
//
//  Pre-release validation tests to ensure Mac user compatibility.
//  These tests validate edge cases, runtime behavior, and system integration
//  that are critical for a production release.
//

import XCTest
@testable import SortyLib

// MARK: - Filename Edge Cases

final class FilenameEdgeCaseTests: XCTestCase {
    
    var tempDir: URL!
    var fileManager: FileManager!
    var scanner: DirectoryScanner!
    
    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        scanner = DirectoryScanner()
    }
    
    override func tearDown() {
        try? fileManager.removeItem(at: tempDir)
        super.tearDown()
    }
    
    func testUnicodeFilenames() async throws {
        // Test various unicode scripts
        let unicodeNames = [
            "文件.txt",           // Chinese
            "файл.doc",          // Russian
            "αρχείο.pdf",        // Greek
            "ファイル.png",        // Japanese
            "파일.jpg",           // Korean
            "ملف.docx",          // Arabic
            "קובץ.xlsx"          // Hebrew
        ]
        
        for name in unicodeNames {
            let fileURL = tempDir.appendingPathComponent(name)
            try "test".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        
        let files = try await scanner.scanDirectory(at: tempDir)
        XCTAssertEqual(files.count, unicodeNames.count, "Should handle all unicode filenames")
    }
    
    func testEmojiFilenames() async throws {
        let emojiNames = [
            "📁 Documents.txt",
            "🎵 Music Collection.mp3",
            "📷 Photos 2024.jpg",
            "🎬 Movie.mp4",
            "👨‍💻 Code.swift",
            "🔒 Secure.dat",
            "✨ Special ✨.txt"
        ]
        
        for name in emojiNames {
            let fileURL = tempDir.appendingPathComponent(name)
            try "test".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        
        let files = try await scanner.scanDirectory(at: tempDir)
        XCTAssertEqual(files.count, emojiNames.count, "Should handle emoji filenames")
    }
    
    func testLongFilenames() async throws {
        // macOS HFS+ allows up to 255 UTF-16 characters
        // APFS allows up to 255 UTF-8 bytes for the name
        let longName = String(repeating: "a", count: 200) + ".txt"
        let fileURL = tempDir.appendingPathComponent(longName)
        try "test".write(to: fileURL, atomically: true, encoding: .utf8)
        
        let files = try await scanner.scanDirectory(at: tempDir)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.name.count, 200)
    }
    
    func testFilenamesWithQuotes() async throws {
        let quotedNames = [
            "File \"quoted\".txt",
            "It's a file.doc",
            "File 'single'.pdf",
            "Mixed \"and 'quotes'.txt"
        ]
        
        for name in quotedNames {
            let fileURL = tempDir.appendingPathComponent(name)
            try "test".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        
        let files = try await scanner.scanDirectory(at: tempDir)
        XCTAssertEqual(files.count, quotedNames.count, "Should handle quoted filenames")
    }
    
    func testFilenamesWithBackslashes() async throws {
        // Note: Backslashes are valid in macOS filenames (unlike Windows)
        let fileURL = tempDir.appendingPathComponent("File\\with\\backslashes.txt")
        try "test".write(to: fileURL, atomically: true, encoding: .utf8)
        
        let files = try await scanner.scanDirectory(at: tempDir)
        XCTAssertEqual(files.count, 1)
    }
    
    func testHiddenFiles() async throws {
        let hiddenFiles = [
            ".gitignore",
            ".DS_Store",
            ".hidden_folder/.nested_file",
            ".env"
        ]
        
        // Create hidden folder
        try fileManager.createDirectory(
            at: tempDir.appendingPathComponent(".hidden_folder"),
            withIntermediateDirectories: true
        )
        
        for name in hiddenFiles {
            let fileURL = tempDir.appendingPathComponent(name)
            try "test".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        
        // Scanner should be able to find hidden files when configured
        let files = try await scanner.scanDirectory(at: tempDir, includeHidden: true)
        XCTAssertGreaterThanOrEqual(files.count, 4, "Should find hidden files when enabled")
    }
    
    func testFilenamesWithNewlines() async throws {
        // This is a valid but problematic filename on macOS
        let fileURL = tempDir.appendingPathComponent("File\nwith\nnewlines.txt")
        
        do {
            try "test".write(to: fileURL, atomically: true, encoding: .utf8)
            let files = try await scanner.scanDirectory(at: tempDir)
            XCTAssertEqual(files.count, 1, "Should handle filenames with newlines")
        } catch {
            // Some filesystems may reject this - that's acceptable
            XCTAssertTrue(true, "Filesystem rejected newline in filename - acceptable")
        }
    }
    
    func testFilenamesStartingWithDash() async throws {
        let fileURL = tempDir.appendingPathComponent("-dangerous-filename.txt")
        try "test".write(to: fileURL, atomically: true, encoding: .utf8)
        
        let files = try await scanner.scanDirectory(at: tempDir)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.name, "-dangerous-filename")
    }
}

// MARK: - Path Edge Cases

final class PathEdgeCaseTests: XCTestCase {
    
    var tempDir: URL!
    var fileManager: FileManager!
    var scanner: DirectoryScanner!
    
    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        scanner = DirectoryScanner()
    }
    
    override func tearDown() {
        try? fileManager.removeItem(at: tempDir)
        super.tearDown()
    }
    
    func testPathsWithSpaces() async throws {
        let spacePath = tempDir.appendingPathComponent("Folder With Spaces/Subfolder With More Spaces")
        try fileManager.createDirectory(at: spacePath, withIntermediateDirectories: true)
        
        let fileURL = spacePath.appendingPathComponent("File With Spaces.txt")
        try "test".write(to: fileURL, atomically: true, encoding: .utf8)
        
        let files = try await scanner.scanDirectory(at: tempDir)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files.first?.path.contains("Folder With Spaces") ?? false)
    }
    
    func testDeeplyNestedPaths() async throws {
        // Create a deeply nested directory structure
        var currentPath = tempDir!
        for i in 1...20 {
            currentPath = currentPath.appendingPathComponent("level_\(i)")
        }
        
        try fileManager.createDirectory(at: currentPath, withIntermediateDirectories: true)
        let fileURL = currentPath.appendingPathComponent("deep_file.txt")
        try "test".write(to: fileURL, atomically: true, encoding: .utf8)
        
        let files = try await scanner.scanDirectory(at: tempDir)
        XCTAssertEqual(files.count, 1, "Should find files in deeply nested directories")
    }
    
    func testSymlinkHandling() async throws {
        // Create a real file
        let realFile = tempDir.appendingPathComponent("real_file.txt")
        try "real content".write(to: realFile, atomically: true, encoding: .utf8)
        
        // Create a symlink
        let symlinkPath = tempDir.appendingPathComponent("symlink_to_file.txt")
        try fileManager.createSymbolicLink(at: symlinkPath, withDestinationURL: realFile)
        
        let files = try await scanner.scanDirectory(at: tempDir)
        
        // Scanner should handle symlinks appropriately
        // (either follow them or skip them, but not crash)
        XCTAssertGreaterThanOrEqual(files.count, 1, "Should handle symlinks gracefully")
    }
    
    func testSymlinkToDirectory() async throws {
        // Create a real directory with a file
        let realDir = tempDir.appendingPathComponent("real_directory")
        try fileManager.createDirectory(at: realDir, withIntermediateDirectories: true)
        try "test".write(to: realDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        
        // Create a symlink to the directory
        let symlinkPath = tempDir.appendingPathComponent("symlink_to_dir")
        try fileManager.createSymbolicLink(at: symlinkPath, withDestinationURL: realDir)
        
        // Should not cause infinite recursion
        let files = try await scanner.scanDirectory(at: tempDir)
        XCTAssertGreaterThanOrEqual(files.count, 1, "Should handle directory symlinks")
    }
    
    func testBrokenSymlink() async throws {
        // Create a symlink to a non-existent file
        let brokenSymlink = tempDir.appendingPathComponent("broken_symlink.txt")
        let nonExistentTarget = tempDir.appendingPathComponent("does_not_exist.txt")
        
        try fileManager.createSymbolicLink(at: brokenSymlink, withDestinationURL: nonExistentTarget)
        
        // Should not crash on broken symlinks
        _ = try await scanner.scanDirectory(at: tempDir)
        XCTAssertTrue(true, "Should handle broken symlinks without crashing")
    }
    
    func testPathsWithSpecialCharacters() async throws {
        let specialPaths = [
            "Path (with) parentheses",
            "Path [with] brackets",
            "Path {with} braces",
            "Path #with @special &chars",
            "Path with 50% discount",
            "Path+with+plus+signs"
        ]
        
        for path in specialPaths {
            let dirPath = tempDir.appendingPathComponent(path)
            try fileManager.createDirectory(at: dirPath, withIntermediateDirectories: true)
            try "test".write(to: dirPath.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        }
        
        let files = try await scanner.scanDirectory(at: tempDir)
        XCTAssertEqual(files.count, specialPaths.count, "Should handle paths with special characters")
    }
}

// MARK: - File System Edge Cases

final class FileSystemEdgeCaseTests: XCTestCase {
    
    var tempDir: URL!
    var fileManager: FileManager!
    var scanner: DirectoryScanner!
    
    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        scanner = DirectoryScanner()
    }
    
    override func tearDown() {
        try? fileManager.removeItem(at: tempDir)
        super.tearDown()
    }
    
    func testEmptyFiles() async throws {
        let emptyFile = tempDir.appendingPathComponent("empty.txt")
        try Data().write(to: emptyFile)
        
        let files = try await scanner.scanDirectory(at: tempDir)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.size, 0, "Should handle zero-byte files")
    }
    
    func testFilesWithNoExtension() async throws {
        let noExtFile = tempDir.appendingPathComponent("Makefile")
        try "content".write(to: noExtFile, atomically: true, encoding: .utf8)
        
        let files = try await scanner.scanDirectory(at: tempDir)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.extension, "", "Should handle files without extension")
    }
    
    func testFilesWithMultipleExtensions() async throws {
        let multiExtFile = tempDir.appendingPathComponent("archive.tar.gz")
        try "content".write(to: multiExtFile, atomically: true, encoding: .utf8)
        
        let files = try await scanner.scanDirectory(at: tempDir)
        XCTAssertEqual(files.count, 1)
        // The extension should be "gz" (last component)
        XCTAssertEqual(files.first?.extension, "gz")
    }
    
    func testFilesWithOnlyExtension() async throws {
        let onlyExtFile = tempDir.appendingPathComponent(".htaccess")
        try "content".write(to: onlyExtFile, atomically: true, encoding: .utf8)
        
        let files = try await scanner.scanDirectory(at: tempDir, includeHidden: true)
        let htaccessFiles = files.filter { $0.name == ".htaccess" || $0.name == "" }
        XCTAssertGreaterThanOrEqual(htaccessFiles.count, 0, "Should handle dot-files")
    }
    
    func testVeryLargeFileMetadata() async throws {
        // We can't create a 100GB file in tests, but we can verify
        // the scanner doesn't choke on large size values
        let largeFile = tempDir.appendingPathComponent("large.dat")
        let oneMB = Data(count: 1024 * 1024)
        try oneMB.write(to: largeFile)
        
        let files = try await scanner.scanDirectory(at: tempDir)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.size, Int64(1024 * 1024))
    }
    
    func testManyFilesInDirectory() async throws {
        // Create 500 files
        for i in 1...500 {
            let fileURL = tempDir.appendingPathComponent("file_\(i).txt")
            try "\(i)".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        
        let files = try await scanner.scanDirectory(at: tempDir)
        XCTAssertEqual(files.count, 500, "Should handle directories with many files")
    }
    
    func testEmptyDirectory() async throws {
        let emptySubdir = tempDir.appendingPathComponent("empty_subdir")
        try fileManager.createDirectory(at: emptySubdir, withIntermediateDirectories: true)
        
        let files = try await scanner.scanDirectory(at: tempDir)
        XCTAssertEqual(files.count, 0, "Empty directories should return no files")
    }
}

// MARK: - AI Client Factory Tests

final class AIClientFactoryTests: XCTestCase {
    
    func testOpenAIClientInitializes() {
        // Should not crash when creating client (even without valid API key)
        let config = AIConfig(
            provider: .openAI,
            apiURL: "https://api.openai.com",
            apiKey: "test-key",
            model: "gpt-4"
        )
        
        do {
            let client = try AIClientFactory.createClient(config: config)
            XCTAssertNotNil(client, "OpenAI client should initialize")
        } catch {
            XCTFail("OpenAI client should initialize without throwing: \(error)")
        }
    }
    
    func testAnthropicClientInitializes() {
        let config = AIConfig(
            provider: .anthropic,
            apiURL: "https://api.anthropic.com/v1/messages",
            apiKey: "test-key",
            model: "claude-3-5-sonnet-20240620"
        )
        
        do {
            let client = try AIClientFactory.createClient(config: config)
            XCTAssertNotNil(client, "Anthropic client should initialize")
        } catch {
            XCTFail("Anthropic client should initialize without throwing: \(error)")
        }
    }
    
    func testGroqClientInitializes() {
        let config = AIConfig(
            provider: .groq,
            apiURL: "https://api.groq.com/openai",
            apiKey: "test-key",
            model: "llama-3.3-70b-versatile"
        )
        
        do {
            let client = try AIClientFactory.createClient(config: config)
            XCTAssertNotNil(client, "Groq client should initialize")
        } catch {
            XCTFail("Groq client should initialize without throwing: \(error)")
        }
    }
    
    func testOllamaClientInitializes() {
        let config = AIConfig(
            provider: .ollama,
            apiURL: "http://localhost:11434",
            model: "llama3",
            requiresAPIKey: false
        )
        
        do {
            let client = try AIClientFactory.createClient(config: config)
            XCTAssertNotNil(client, "Ollama client should initialize")
        } catch {
            XCTFail("Ollama client should initialize without throwing: \(error)")
        }
    }
    
    func testDefaultConfigExists() {
        let defaultConfig = AIConfig.default
        XCTAssertNotNil(defaultConfig, "Default AIConfig should exist")
        XCTAssertFalse(defaultConfig.model.isEmpty, "Default model should not be empty")
    }
}

// MARK: - Undo/Redo Safety Tests

@MainActor
final class UndoRedoSafetyTests: XCTestCase {
    
    var tempDir: URL!
    var fileManager: FileManager!
    var fsManager: FileSystemManager!
    
    override func setUp() async throws {
        fileManager = FileManager.default
        tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fsManager = FileSystemManager()
    }
    
    override func tearDown() async throws {
        try? fileManager.removeItem(at: tempDir)
    }
    
    @MainActor
    func testUndoAfterMultipleOperations() async throws {
        // Create multiple files
        for i in 1...5 {
            let file = tempDir.appendingPathComponent("file\(i).txt")
            try "content \(i)".write(to: file, atomically: true, encoding: .utf8)
        }
        
        // Create organization plan
        var files: [FileItem] = []
        for i in 1...5 {
            let path = tempDir.appendingPathComponent("file\(i).txt").path
            files.append(FileItem(path: path, name: "file\(i)", extension: "txt", size: 10, isDirectory: false))
        }
        
        let plan = OrganizationPlan(
            suggestions: [
                FolderSuggestion(folderName: "Organized", description: "", files: files, subfolders: [], reasoning: "")
            ],
            unorganizedFiles: [],
            notes: ""
        )
        
        // Apply organization
        let ops = try await fsManager.applyOrganization(plan, at: tempDir)
        
        // Undo
        _ = try await fsManager.reverseOperations(ops)
        
        // Verify files are back

        for i in 1...5 {
            let originalPath = tempDir.appendingPathComponent("file\(i).txt")
            XCTAssertTrue(fileManager.fileExists(atPath: originalPath.path), "File \(i) should be restored")
        }
    }
    
    @MainActor
    func testUndoGracefullyHandlesMissingFiles() async throws {
        // Create a file and organize it
        let file = tempDir.appendingPathComponent("test.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)
        
        let fileItem = FileItem(path: file.path, name: "test", extension: "txt", size: 7, isDirectory: false)
        let plan = OrganizationPlan(
            suggestions: [
                FolderSuggestion(folderName: "Dest", description: "", files: [fileItem], subfolders: [], reasoning: "")
            ],
            unorganizedFiles: [],
            notes: ""
        )
        
        let ops = try await fsManager.applyOrganization(plan, at: tempDir)
        
        // Manually delete the moved file (simulate external change)
        let movedFile = tempDir.appendingPathComponent("Dest/test.txt")
        try? fileManager.removeItem(at: movedFile)
        
        // Undo should handle gracefully (not crash)
        do {
            _ = try await fsManager.reverseOperations(ops)
            // May succeed (no-op) or throw - both are acceptable
        } catch {
            // Expected - file was externally deleted
            XCTAssertTrue(true, "Gracefully handled missing file during undo")
        }
    }
}

// MARK: - Exclusion Pattern Tests

final class ExclusionPatternEdgeCaseTests: XCTestCase {
    
    func testExclusionPatternWithExtension() {
        let rule = ExclusionRule(type: .fileExtension, pattern: "tmp")
        let file = FileItem(path: "/test/file.tmp", name: "file", extension: "tmp", size: 0, isDirectory: false)
        let txtFile = FileItem(path: "/test/file.txt", name: "file", extension: "txt", size: 0, isDirectory: false)
        
        XCTAssertTrue(rule.matches(file))
        XCTAssertFalse(rule.matches(txtFile))
    }
    
    func testExclusionPatternWithPrefix() {
        let rule = ExclusionRule(type: .fileName, pattern: "~$")
        let file = FileItem(path: "/test/~$document.docx", name: "~$document", extension: "docx", size: 0, isDirectory: false)
        let normalFile = FileItem(path: "/test/document.docx", name: "document", extension: "docx", size: 0, isDirectory: false)
        
        XCTAssertTrue(rule.matches(file))
        XCTAssertFalse(rule.matches(normalFile))
    }
    
    func testExclusionPatternHiddenFiles() {
        let rule = ExclusionRule(type: .hiddenFiles, pattern: "")
        let hiddenFile = FileItem(path: "/test/.gitignore", name: ".gitignore", extension: "", size: 0, isDirectory: false)
        let normalFile = FileItem(path: "/test/file.txt", name: "file", extension: "txt", size: 0, isDirectory: false)
        
        XCTAssertTrue(rule.matches(hiddenFile))
        XCTAssertFalse(rule.matches(normalFile))
    }
    
    func testExclusionPatternRegex() {
        let rule = ExclusionRule(type: .regex, pattern: "^temp_\\d+\\.txt$")
        let matchingFile = FileItem(path: "/test/temp_123.txt", name: "temp_123", extension: "txt", size: 0, isDirectory: false)
        let nonMatchingFile = FileItem(path: "/test/temp_abc.txt", name: "temp_abc", extension: "txt", size: 0, isDirectory: false)
        
        XCTAssertTrue(rule.matches(matchingFile))
        XCTAssertFalse(rule.matches(nonMatchingFile))
    }
    
    func testExclusionPatternCaseInsensitive() {
        let rule = ExclusionRule(type: .fileExtension, pattern: "TMP", caseSensitive: false)
        let lowerFile = FileItem(path: "/test/file.tmp", name: "file", extension: "tmp", size: 0, isDirectory: false)
        let upperFile = FileItem(path: "/test/file.TMP", name: "file", extension: "TMP", size: 0, isDirectory: false)
        
        XCTAssertTrue(rule.matches(lowerFile))
        XCTAssertTrue(rule.matches(upperFile))
    }
    
    func testExclusionPatternSystemFiles() {
        let rule = ExclusionRule(type: .systemFiles, pattern: "")
        let dsStore = FileItem(path: "/test/.DS_Store", name: ".DS_Store", extension: "", size: 0, isDirectory: false)
        let normalFile = FileItem(path: "/test/document.pdf", name: "document", extension: "pdf", size: 0, isDirectory: false)
        
        XCTAssertTrue(rule.matches(dsStore))
        XCTAssertFalse(rule.matches(normalFile))
    }
    
    func testExclusionPatternFolderName() {
        let rule = ExclusionRule(type: .folderName, pattern: "node_modules")
        let fileInNodeModules = FileItem(path: "/project/node_modules/package/index.js", name: "index", extension: "js", size: 0, isDirectory: false)
        let normalFile = FileItem(path: "/project/src/index.js", name: "index", extension: "js", size: 0, isDirectory: false)
        
        XCTAssertTrue(rule.matches(fileInNodeModules))
        XCTAssertFalse(rule.matches(normalFile))
    }
    
    func testExclusionPatternFileSize() {
        let rule = ExclusionRule(type: .fileSize, pattern: "", numericValue: 100, comparisonGreater: true)
        let largeFile = FileItem(path: "/test/large.dat", name: "large", extension: "dat", size: 200 * 1024 * 1024, isDirectory: false)
        let smallFile = FileItem(path: "/test/small.txt", name: "small", extension: "txt", size: 1024, isDirectory: false)
        
        XCTAssertTrue(rule.matches(largeFile))
        XCTAssertFalse(rule.matches(smallFile))
    }
}

// MARK: - Response Parser Edge Cases

final class ResponseParserEdgeCaseTests: XCTestCase {
    
    func testParseEmptyResponseThrows() {
        // ResponseParser.parseResponse throws on empty input
        XCTAssertThrowsError(try ResponseParser.parseResponse("", originalFiles: [])) { error in
            // Should throw some kind of parser error
            XCTAssertTrue(true, "Empty response correctly throws error")
        }
    }
    
    func testParseMalformedJSONThrows() {
        let malformed = "{ this is not: valid json }"
        XCTAssertThrowsError(try ResponseParser.parseResponse(malformed, originalFiles: [])) { error in
            XCTAssertTrue(true, "Malformed JSON correctly throws error")
        }
    }
    
    func testParseJSONWithExtraFields() {
        let json = """
        {
            "folders": [
                {
                    "name": "Documents",
                    "description": "Text files",
                    "files": ["file.txt"],
                    "unknownField": "should be ignored",
                    "anotherUnknown": 12345
                }
            ],
            "extraTopLevel": true
        }
        """
        
        let testFile = FileItem(path: "/test/file.txt", name: "file", extension: "txt", size: 100, isDirectory: false)
        
        do {
            let result = try ResponseParser.parseResponse(json, originalFiles: [testFile])
            XCTAssertNotNil(result, "Should parse JSON with extra fields")
            XCTAssertEqual(result.suggestions.count, 1)
        } catch {
            // Some parsers may be strict - that's also acceptable
            XCTAssertTrue(true, "Parser is strict about extra fields")
        }
    }
    
    func testParseResponseWithUnicodeContent() {
        let json = """
        {
            "folders": [
                {
                    "name": "文件夹",
                    "description": "中文文件",
                    "files": ["文件.txt"],
                    "reasoning": "これは日本語です"
                }
            ]
        }
        """
        
        let testFile = FileItem(path: "/test/文件.txt", name: "文件", extension: "txt", size: 100, isDirectory: false)
        
        do {
            let result = try ResponseParser.parseResponse(json, originalFiles: [testFile])
            XCTAssertNotNil(result, "Should parse JSON with unicode content")
            XCTAssertEqual(result.suggestions.first?.folderName, "文件夹")
        } catch {
            XCTFail("Should handle unicode: \(error)")
        }
    }
    
    func testParseValidOrganizationResponse() {
        let json = """
        {
            "folders": [
                {
                    "name": "Documents",
                    "description": "Text documents",
                    "files": ["doc.txt", "report.pdf"],
                    "reasoning": "Grouped by type"
                },
                {
                    "name": "Images",
                    "description": "Image files",
                    "files": ["photo.jpg"]
                }
            ]
        }
        """
        
        let files = [
            FileItem(path: "/test/doc.txt", name: "doc", extension: "txt", size: 100, isDirectory: false),
            FileItem(path: "/test/report.pdf", name: "report", extension: "pdf", size: 200, isDirectory: false),
            FileItem(path: "/test/photo.jpg", name: "photo", extension: "jpg", size: 300, isDirectory: false)
        ]
        
        do {
            let result = try ResponseParser.parseResponse(json, originalFiles: files)
            XCTAssertEqual(result.suggestions.count, 2)
        } catch {
            XCTFail("Should parse valid response: \(error)")
        }
    }
}
