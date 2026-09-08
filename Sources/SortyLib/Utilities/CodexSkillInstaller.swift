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

@MainActor
final class CodexSkillInstaller: ObservableObject {
    @Published private(set) var state: CodexSkillInstallState = .checking

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
        let codexHome: URL
        if let configuredHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredHome.isEmpty {
            codexHome = URL(fileURLWithPath: configuredHome, isDirectory: true)
        } else {
            codexHome = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return codexHome
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("sorty", isDirectory: true)
    }

    func refresh(trackUsage: Bool = true) async {
        state = .checking
        let source = Self.bundledSkillURL()
        let destination = destinationURL
        let nextState = await Task.detached(priority: .utility) {
            Self.inspect(source: source, destination: destination)
        }.value
        state = nextState
        if trackUsage {
            captureStatus(nextState)
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
            try fileManager.copyItem(at: source, to: temporary)
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
            try fileManager.copyItem(at: source, to: temporary)
            guard isValidSkill(at: temporary) else {
                try? fileManager.removeItem(at: temporary)
                return false
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
