import AppKit
import Combine
import Foundation

enum CodexSkillInstallState: Equatable, Sendable {
    case checking
    case available
    case installing
    case replacing
    case removing
    case installed(installedAt: Date?)
    case conflict
    case unavailable
    case failed
}

enum SkillAgent: String, CaseIterable, Sendable {
    case codex = "Codex"
    case claudeCode = "Claude Code"
    case openCode = "OpenCode"
    case pi = "Pi"

    func skillsDirectory(home: URL, environment: [String: String]) -> URL {
        func configuredDirectory(_ key: String, fallback: URL) -> URL {
            guard let path = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else { return fallback }
            if path == "~" { return home }
            if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true) }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let root: URL
        switch self {
        case .codex:
            root = configuredDirectory("CODEX_HOME", fallback: home.appendingPathComponent(".codex", isDirectory: true))
        case .claudeCode:
            root = configuredDirectory("CLAUDE_CONFIG_DIR", fallback: home.appendingPathComponent(".claude", isDirectory: true))
        case .openCode:
            let config = configuredDirectory("XDG_CONFIG_HOME", fallback: home.appendingPathComponent(".config", isDirectory: true))
                .appendingPathComponent("opencode", isDirectory: true)
            root = configuredDirectory("OPENCODE_CONFIG_DIR", fallback: config)
        case .pi:
            root = configuredDirectory("PI_CODING_AGENT_DIR", fallback: home.appendingPathComponent(".pi/agent", isDirectory: true))
        }
        return root.appendingPathComponent("skills", isDirectory: true)
    }
}

struct SkillImportOption: Identifiable, Sendable {
    enum Section: String, CaseIterable, Sendable {
        case preferences = "Preferences"
        case exclusions = "Exclusions"
        case watchedFolders = "Watched folders"
        case learnings = "Learnings"

        var icon: String {
            switch self {
            case .preferences: "textformat"
            case .exclusions: "line.3.horizontal.decrease.circle"
            case .watchedFolders: "folder"
            case .learnings: "brain"
            }
        }
    }

    let id: String
    let selectionID: String
    let section: Section
    let title: String
    let detail: String
    let category: String
    let key: String?
    let value: Data

    static func options(
        config: AIConfig, openFolder: Bool, exclusions: [ExclusionRule],
        exceptions: [NaturalLanguageException], folders: [WatchedFolder],
        learnings: LearningsProfile?
    ) throws -> [Self] {
        var options: [Self] = []
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        func add<Value: Encodable>(
            _ value: Value, section: Section, title: String, detail: String,
            category: String, key: String? = nil, id: String, selectionID: String? = nil
        ) throws {
            options.append(Self(id: id, selectionID: selectionID ?? id, section: section,
                                title: title, detail: detail, category: category, key: key,
                                value: try encoder.encode(value)))
        }
        try add(openFolder, section: .preferences, title: "Open folder after organization",
                detail: openFolder ? "On" : "Off", category: "preferences", key: "openFolderAfterOrganization", id: "openFolder")
        try add(config.namingStyle, section: .preferences, title: "Naming style",
                detail: config.namingStyle.displayName, category: "preferences", key: "namingStyle", id: "namingStyle")
        try add(config.renameNamingOptions, section: .preferences, title: "Filename formatting",
                detail: "\(config.renameNamingOptions.separator.displayName) · \(config.renameNamingOptions.caseStyle.displayName) · \(config.renameNamingOptions.outputLanguage)",
                category: "preferences", key: "renameNamingOptions", id: "namingOptions")
        if let instructions = config.customNamingInstructions, !instructions.isEmpty {
            try add(instructions, section: .preferences, title: "Naming instructions", detail: instructions,
                    category: "preferences", key: "customNamingInstructions", id: "namingInstructions")
        }
        if !config.renameRules.isEmpty {
            try add(config.renameRules, section: .preferences, title: "Rename rules",
                    detail: "\(config.renameRules.count) saved rules", category: "preferences", key: "renameRules", id: "renameRules")
        }
        for rule in exclusions {
            try add(rule, section: .exclusions, title: rule.description ?? rule.type.friendlyName,
                    detail: rule.interpretedMatchDescription + (rule.isEnabled ? "" : " · Disabled"),
                    category: "exclusions", id: rule.id.uuidString,
                    selectionID: rule.conditionGroupID.map { "group-\($0.uuidString)" })
        }
        for exception in exceptions {
            try add(exception, section: .exclusions, title: exception.text,
                    detail: exception.isEnabled ? "Exception" : "Disabled exception",
                    category: "naturalLanguageExceptions", id: exception.id.uuidString)
        }
        for folder in folders {
            // Paths and prompts are portable. Bookmarks and automatic-apply grants are not.
            var value = ["id": folder.id.uuidString, "name": folder.name, "path": folder.path]
            if let prompt = folder.customPrompt { value["customPrompt"] = prompt }
            try add(value, section: .watchedFolders, title: folder.name, detail: folder.path,
                    category: "watchedFolders", id: folder.id.uuidString)
        }
        if let learnings {
            func addLearning<Value: Encodable>(_ value: [Value], key: String, title: String) throws {
                guard !value.isEmpty else { return }
                try add(value, section: .learnings, title: title, detail: "\(value.count) saved items",
                        category: "learnings", key: key, id: key)
            }
            try addLearning(learnings.inferredRules, key: "inferredRules", title: "Learned rules")
            try addLearning(learnings.guidingInstructionsHistory, key: "guidingInstructionsHistory", title: "Guiding instructions")
            try addLearning(learnings.additionalInstructionsHistory, key: "additionalInstructionsHistory", title: "Your instructions")
            try addLearning(learnings.corrections, key: "corrections", title: "Corrections")
            try addLearning(learnings.rejections, key: "rejections", title: "Rejected changes")
            try addLearning(learnings.positiveExamples, key: "positiveExamples", title: "Preferred examples")
            try addLearning(learnings.learningExclusionPatterns, key: "learningExclusionPatterns", title: "Learning exclusions")
        }
        return options
    }

    static func profileData(options: [Self], selected: Set<String>) throws -> Data {
        var preferences: [String: Any] = [:]
        var learnings: [String: Any] = [:]
        var lists: [String: [Any]] = ["exclusions": [], "naturalLanguageExceptions": [], "watchedFolders": []]
        for option in options where selected.contains(option.selectionID) {
            let value = try JSONSerialization.jsonObject(with: option.value, options: .fragmentsAllowed)
            if let key = option.key {
                if option.category == "preferences" { preferences[key] = value }
                else { learnings[key] = value }
            } else {
                lists[option.category, default: []].append(value)
            }
        }
        return try JSONSerialization.data(withJSONObject: [
            "version": 1, "preferences": preferences, "learnings": learnings,
            "exclusions": lists["exclusions"] ?? [],
            "naturalLanguageExceptions": lists["naturalLanguageExceptions"] ?? [],
            "watchedFolders": lists["watchedFolders"] ?? []
        ], options: [.prettyPrinted, .sortedKeys])
    }
}

@MainActor
final class CodexSkillInstaller: ObservableObject {
    @Published private(set) var state: CodexSkillInstallState = .checking
    @Published var selectedSkillsDirectory: URL?
    @Published private(set) var detectedAgents: Set<SkillAgent> = []

    private let fileManager: FileManager
    private let environment: [String: String]

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
    }

    var destinationURL: URL {
        (selectedSkillsDirectory ?? skillsDirectory(for: .codex))
            .appendingPathComponent("sorty", isDirectory: true)
    }

    var selectedAgent: SkillAgent? {
        let directory = destinationURL.deletingLastPathComponent().standardizedFileURL
        return SkillAgent.allCases.first { skillsDirectory(for: $0).standardizedFileURL == directory }
    }

    func skillsDirectory(for agent: SkillAgent) -> URL {
        agent.skillsDirectory(home: fileManager.homeDirectoryForCurrentUser, environment: environment)
    }

    func refresh(trackUsage: Bool = true, showsCheckingState: Bool = true) async {
        if showsCheckingState { state = .checking }
        let source = Self.bundledSkillURL()
        let destination = destinationURL
        let directories = SkillAgent.allCases.map { ($0, skillsDirectory(for: $0).deletingLastPathComponent()) }
        let result = await Task.detached(priority: .utility) {
            let detected = Set(directories.compactMap { agent, directory -> SkillAgent? in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue ? agent : nil
            })
            return (Self.inspect(source: source, destination: destination), detected)
        }.value
        guard destinationURL == destination else { return }
        if detectedAgents != result.1 { detectedAgents = result.1 }
        if state != result.0 { state = result.0 }
        if trackUsage {
            captureStatus(result.0)
        }
    }

    func install() async {
        guard let source = Self.bundledSkillURL() else {
            state = .unavailable
            captureInstall(outcome: "unavailable")
            return
        }

        state = .installing
        let destination = destinationURL
        let installed = await Task.detached(priority: .userInitiated) {
            Self.install(source: source, destination: destination)
        }.value

        if installed {
            state = .installed(installedAt: Date())
            HapticFeedbackManager.shared.success()
            captureInstall(outcome: "success")
        } else {
            let inspectedState = Self.inspect(source: source, destination: destination)
            state = inspectedState == .available ? .failed : inspectedState
            HapticFeedbackManager.shared.error()
            captureInstall(outcome: "failed")
        }
    }

    func replace() async {
        guard let source = Self.bundledSkillURL() else {
            state = .unavailable
            captureAction("replace", outcome: "unavailable")
            return
        }

        state = .replacing
        let destination = destinationURL
        let replaced = await Task.detached(priority: .userInitiated) {
            Self.replace(source: source, destination: destination)
        }.value

        if replaced {
            state = .installed(installedAt: Date())
            HapticFeedbackManager.shared.success()
            captureAction("replace", outcome: "success")
        } else {
            state = Self.inspect(source: source, destination: destination)
            HapticFeedbackManager.shared.error()
            captureAction("replace", outcome: "failed")
        }
    }

    func remove() async {
        state = .removing
        let destination = destinationURL
        let removed = await Task.detached(priority: .userInitiated) {
            Self.remove(destination: destination)
        }.value

        if removed {
            state = Self.bundledSkillURL() == nil ? .unavailable : .available
            HapticFeedbackManager.shared.success()
            captureAction("uninstall", outcome: "success")
        } else {
            state = Self.inspect(source: Self.bundledSkillURL(), destination: destination)
            HapticFeedbackManager.shared.error()
            captureAction("uninstall", outcome: "failed")
        }
    }

    func revealExistingSkill() {
        if fileManager.fileExists(atPath: destinationURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
            return
        }
        let skillsURL = destinationURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: skillsURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(skillsURL)
    }

    func importSettings(options: [SkillImportOption], selected: Set<String>) async throws {
        let data = try SkillImportOption.profileData(options: options, selected: selected)
        let destination = destinationURL
        try await Task.detached(priority: .userInitiated) {
            try Self.writeImportedSettings(data, destination: destination)
        }.value
        HapticFeedbackManager.shared.success()
    }

    nonisolated static func writeImportedSettings(_ data: Data, destination: URL) throws {
        let fileManager = FileManager.default
        guard isValidSkill(at: destination) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let references = destination.appendingPathComponent("references", isDirectory: true)
        try fileManager.createDirectory(at: references, withIntermediateDirectories: true)
        let profile = references.appendingPathComponent("imported-settings.json")
        let backup = references.appendingPathComponent(".imported-settings-backup.json")
        if fileManager.fileExists(atPath: profile.path) {
            try Data(contentsOf: profile).write(to: backup, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        let temporary = references.appendingPathComponent(".imported-settings-\(UUID().uuidString).json")
        defer { try? fileManager.removeItem(at: temporary) }
        guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if fileManager.fileExists(atPath: profile.path) {
            _ = try fileManager.replaceItemAt(profile, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: profile)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profile.path)
    }

    nonisolated static func inspect(source: URL?, destination: URL) -> CodexSkillInstallState {
        guard let source, isValidSkill(at: source) else { return .unavailable }
        guard FileManager.default.fileExists(atPath: destination.path) else { return .available }
        guard isValidSkill(at: destination) else { return .conflict }
        guard directoriesMatch(source, destination) else { return .conflict }
        let values = try? destination.resourceValues(forKeys: [.creationDateKey])
        return .installed(installedAt: values?.creationDate)
    }

    nonisolated static func install(source: URL, destination: URL) -> Bool {
        let fileManager = FileManager.default
        guard isValidSkill(at: source), !fileManager.fileExists(atPath: destination.path) else {
            return false
        }

        let skillsURL = destination.deletingLastPathComponent()
        let temporary = skillsURL.appendingPathComponent(".sorty-install-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: skillsURL, withIntermediateDirectories: true)
            try copySkill(source: source, destination: temporary)
            guard isValidSkill(at: temporary) else {
                try? fileManager.removeItem(at: temporary)
                return false
            }
            try fileManager.moveItem(at: temporary, to: destination)
            return true
        } catch {
            DebugLogger.log("Codex skill install failed: \(error.localizedDescription)")
            try? fileManager.removeItem(at: temporary)
            return false
        }
    }

    nonisolated static func replace(source: URL, destination: URL) -> Bool {
        let fileManager = FileManager.default
        guard isValidSkill(at: source), fileManager.fileExists(atPath: destination.path) else {
            return false
        }

        let skillsURL = destination.deletingLastPathComponent()
        let operationID = UUID().uuidString
        let temporary = skillsURL.appendingPathComponent(".sorty-install-\(operationID)", isDirectory: true)
        let backup = skillsURL.appendingPathComponent(".sorty-backup-\(operationID)", isDirectory: true)
        do {
            try copySkill(source: source, destination: temporary)
            guard isValidSkill(at: temporary) else {
                try? fileManager.removeItem(at: temporary)
                return false
            }
            for importedSettings in ["references/imported-settings.json", "references/agent-preferences.json"] {
                let existingProfile = destination.appendingPathComponent(importedSettings)
                if fileManager.fileExists(atPath: existingProfile.path) {
                    let newProfile = temporary.appendingPathComponent(importedSettings)
                    try fileManager.createDirectory(at: newProfile.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.copyItem(at: existingProfile, to: newProfile)
                }
            }
            try fileManager.moveItem(at: destination, to: backup)
            do {
                try fileManager.moveItem(at: temporary, to: destination)
                try? fileManager.removeItem(at: backup)
                return true
            } catch {
                try? fileManager.moveItem(at: backup, to: destination)
                throw error
            }
        } catch {
            DebugLogger.log("Codex skill replacement failed: \(error.localizedDescription)")
            try? fileManager.removeItem(at: temporary)
            return false
        }
    }

    nonisolated static func remove(destination: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path) else { return false }
        do {
            try FileManager.default.removeItem(at: destination)
            return true
        } catch {
            DebugLogger.log("Codex skill removal failed: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated static func bundledSkillURL() -> URL? {
        let bundles = [Bundle.main, SortyResources.bundle]
        for bundle in bundles {
            if let candidate = bundle.resourceURL?.appendingPathComponent("sorty", isDirectory: true),
               isValidSkill(at: candidate) {
                return candidate
            }
        }

        let developmentCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".agents/skills/sorty", isDirectory: true)
        return isValidSkill(at: developmentCandidate) ? developmentCandidate : nil
    }

    private nonisolated static func isValidSkill(at url: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: url.appendingPathComponent("SKILL.md", isDirectory: false).path
        )
    }

    private nonisolated static func copySkill(source: URL, destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.copyItem(at: source, to: destination)
        let references = destination.appendingPathComponent("references", isDirectory: true)
        guard fileManager.fileExists(atPath: references.path) else { return }
        for file in try fileManager.contentsOfDirectory(at: references, includingPropertiesForKeys: nil)
        where ["imported-settings.json", "agent-preferences.json"].contains(file.lastPathComponent) || file.lastPathComponent.hasPrefix(".agent-preferences") || file.lastPathComponent.hasPrefix(".imported-settings") {
            try fileManager.removeItem(at: file)
        }
    }

    private nonisolated static func directoriesMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let leftFiles = relativeFiles(in: lhs), let rightFiles = relativeFiles(in: rhs), leftFiles == rightFiles else {
            return false
        }
        return leftFiles.allSatisfy { relativePath in
            guard let leftData = try? Data(
                contentsOf: lhs.appendingPathComponent(relativePath),
                options: .mappedIfSafe
            ), let rightData = try? Data(
                contentsOf: rhs.appendingPathComponent(relativePath),
                options: .mappedIfSafe
            ) else {
                return false
            }
            return leftData == rightData
        }
    }

    private nonisolated static func relativeFiles(in root: URL) -> Set<String>? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: Set<String> = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relativePath = url.pathComponents
                .suffix(enumerator.level)
                .joined(separator: "/")
            if ["references/imported-settings.json", "references/agent-preferences.json"].contains(relativePath) { continue }
            files.insert(relativePath)
        }
        return files
    }

    private func captureStatus(_ state: CodexSkillInstallState) {
        let outcome: String
        var properties: [String: Any] = [:]
        switch state {
        case .available: outcome = "available"
        case .installed(let installedAt):
            outcome = "installed"
            if let installedAt {
                properties = AnalyticsManager.durationProperties(Date().timeIntervalSince(installedAt))
            }
        case .conflict: outcome = "conflict"
        case .unavailable: outcome = "unavailable"
        default: return
        }
        AnalyticsManager.shared.captureFeature(
            feature: "experimental",
            subfeature: "codex_skill_installer",
            action: "card_viewed",
            outcome: outcome,
            properties: properties
        )
    }

    private func captureInstall(outcome: String) {
        captureAction("install", outcome: outcome)
    }

    private func captureAction(_ action: String, outcome: String) {
        AnalyticsManager.shared.captureFeature(
            feature: "experimental",
            subfeature: "codex_skill_installer",
            action: action,
            outcome: outcome
        )
    }
}
