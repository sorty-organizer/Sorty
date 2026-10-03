
import XCTest
@testable import SortyLib
@testable import SortyCore
@testable import SortyFileSystem

final class UtilityTests: XCTestCase {

    func testRenameRuleEngineAppliesRegexAndLiteralRules() {
        let rules = [
            RenameRule(pattern: "^IMG\\s+", replacement: "", isRegex: true),
            RenameRule(pattern: " ", replacement: "_", isRegex: false)
        ]

        let output = RenameRuleEngine.applyRules(to: "IMG 123 Summer Photo.jpg", rules: rules)
        XCTAssertEqual(output, "123_Summer_Photo.jpg")
    }

    func testCodexSkillInstallerCopiesMatchingSkillWithoutOverwritingConflicts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorty-skill-installer-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("skills/sorty", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: sorty\n---\n".write(
            to: source.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(CodexSkillInstaller.inspect(source: source, destination: destination), .available)
        XCTAssertTrue(CodexSkillInstaller.install(source: source, destination: destination))
        guard case .installed = CodexSkillInstaller.inspect(source: source, destination: destination) else {
            return XCTFail("Expected the copied skill to be recognized as installed")
        }

        let importedSettings = Data("{\"version\":1,\"preferences\":{\"openFolderAfterOrganization\":true}}".utf8)
        try CodexSkillInstaller.writeImportedSettings(importedSettings, destination: destination)
        guard case .installed = CodexSkillInstaller.inspect(source: source, destination: destination) else {
            return XCTFail("Importing personal settings must not mark the skill as conflicting")
        }

        try "different".write(
            to: destination.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(CodexSkillInstaller.inspect(source: source, destination: destination), .conflict)
        XCTAssertFalse(CodexSkillInstaller.install(source: source, destination: destination))
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8),
            "different"
        )

        XCTAssertTrue(CodexSkillInstaller.replace(source: source, destination: destination))
        let profileURL = destination.appendingPathComponent("references/imported-settings.json")
        XCTAssertEqual(try Data(contentsOf: profileURL), importedSettings)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: profileURL.path)[.posixPermissions] as? Int, 0o600)
        guard case .installed = CodexSkillInstaller.inspect(source: source, destination: destination) else {
            return XCTFail("Expected the conflicting skill to be replaced")
        }
        XCTAssertTrue(CodexSkillInstaller.remove(destination: destination))
        XCTAssertEqual(CodexSkillInstaller.inspect(source: source, destination: destination), .available)
    }

    func testSkillImportExportsOnlySelectedPersistentPreferences() throws {
        var config = AIConfig.default
        config.apiKey = "provider-secret"
        config.customNamingInstructions = "Use short project names"
        let folder = WatchedFolder(path: "/example/Inbox", bookmarkData: Data("private-bookmark".utf8))
        let options = try SkillImportOption.options(
            config: config, openFolder: true, exclusions: [], exceptions: [], folders: [folder], learnings: nil
        )
        let data = try SkillImportOption.profileData(options: options, selected: ["namingStyle", folder.id.uuidString])
        let profile = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let preferences = try XCTUnwrap(profile["preferences"] as? [String: Any])
        XCTAssertEqual(Set(preferences.keys), ["namingStyle"])
        let importedFolder = try XCTUnwrap((profile["watchedFolders"] as? [[String: Any]])?.first)
        XCTAssertEqual(importedFolder["path"] as? String, "/example/Inbox")
        XCTAssertNil(importedFolder["bookmarkData"])
        XCTAssertNil(importedFolder["autoOrganize"])
        XCTAssertNil(importedFolder["organizationMode"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("provider-secret"))
        XCTAssertFalse(options.contains { ["mode", "enableDeepScan", "enableSmartRename", "enableVision"].contains($0.key ?? "") })
    }
}
