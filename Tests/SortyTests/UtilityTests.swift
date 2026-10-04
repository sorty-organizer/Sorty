
import XCTest
@testable import SortyLib
@testable import SortyCore
@testable import SortyFileSystem

final class UtilityTests: XCTestCase {

    func testSkillAgentLocationsMatchUserSkillDiscoveryContracts() {
        let home = URL(fileURLWithPath: "/example/home", isDirectory: true)
        let locations: [(SkillAgent, String, String, String)] = [
            (.codex, ".codex/skills", "CODEX_HOME", "~/custom-codex"),
            (.claudeCode, ".claude/skills", "CLAUDE_CONFIG_DIR", "~/custom-claude"),
            (.openCode, ".config/opencode/skills", "XDG_CONFIG_HOME", "~/custom-config"),
            (.pi, ".pi/agent/skills", "PI_CODING_AGENT_DIR", "~/custom-pi")
        ]
        for (agent, path, key, override) in locations {
            XCTAssertEqual(agent.skillsDirectory(home: home, environment: [:]).path, "/example/home/\(path)")
            let suffix = agent == .openCode ? "/opencode/skills" : "/skills"
            XCTAssertEqual(agent.skillsDirectory(home: home, environment: [key: override]).path,
                           "/example/home/\(override.dropFirst(2))\(suffix)")
            XCTAssertEqual(agent.skillsDirectory(home: home, environment: [key: " "]).path, "/example/home/\(path)")
        }
        XCTAssertEqual(SkillAgent.openCode.skillsDirectory(home: home, environment: [
            "OPENCODE_CONFIG_DIR": "/custom/opencode", "XDG_CONFIG_HOME": "/other/config"
        ]).path, "/custom/opencode/skills")
    }

    @MainActor
    func testSkillInstallerDetectsExistingAgentFoldersAndKeepsCustomSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sorty-agent-locations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "CODEX_HOME": root.appendingPathComponent("codex").path,
            "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "PI_CODING_AGENT_DIR": root.appendingPathComponent("pi").path
        ]
        try FileManager.default.createDirectory(at: root.appendingPathComponent("claude"), withIntermediateDirectories: true)
        // A file at a config path must not be reported as an agent settings folder.
        try Data().write(to: root.appendingPathComponent("pi"))
        let installer = CodexSkillInstaller(environment: environment)
        await installer.refresh(trackUsage: false)
        XCTAssertEqual(installer.detectedAgents, [.claudeCode])
        XCTAssertEqual(installer.selectedAgent, .codex)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("codex").path))

        installer.selectedSkillsDirectory = installer.skillsDirectory(for: .claudeCode)
        XCTAssertEqual(installer.selectedAgent, .claudeCode)
        XCTAssertEqual(installer.destinationURL.path, root.appendingPathComponent("claude/skills/sorty").path)
        let custom = root.appendingPathComponent("project/.agents/skills")
        installer.selectedSkillsDirectory = custom
        await installer.refresh(trackUsage: false)
        XCTAssertNil(installer.selectedAgent)
        XCTAssertEqual(installer.destinationURL.path, custom.appendingPathComponent("sorty").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: custom.path))
    }

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
