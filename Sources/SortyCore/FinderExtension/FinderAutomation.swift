//
//  FinderAutomation.swift
//  Sorty
//
//  Service for advanced Finder automation using AppleScript
//  Requires Automation permission for Finder control
//

import Foundation
import AppKit
import ApplicationServices
import Permiso

/// AppleScript-side deadline for Finder calls. A wedged Finder returns an
/// Apple event timeout instead of holding the caller indefinitely.
private let finderAutomationScriptTimeoutSeconds = 5

private func appleScriptStringLiteral(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: "\\t")
    return "\"\(escaped)\""
}

/// Service for automating Finder interactions
/// Uses AppleScript which requires Automation permission
@MainActor
public final class FinderAutomation {
    
    private static var checksEnabled = false
    nonisolated static let permissionEventClass = AEEventClass(kAECoreSuite)
    nonisolated static let permissionEventID = AEEventID(kAEGetData)

    /// NUL delimiters preserve commas and newlines in Finder filenames.
    private static let selectionQueryScript = """
        with timeout of \(finderAutomationScriptTimeoutSeconds) seconds
            tell application "Finder"
                set selectedItems to selection
                set filePaths to {}
                repeat with anItem in selectedItems
                    set end of filePaths to POSIX path of (anItem as alias)
                end repeat
                set AppleScript's text item delimiters to ASCII character 0
                return filePaths as text
            end tell
        end timeout
        """
    
    public static func enableAutomationChecks() {
        checksEnabled = true
    }

    private struct ScriptResult: Sendable {
        let status: Int32
        let output: String
        let error: String
    }

    /// Run AppleScript outside Sorty's process. The process deadline also
    /// covers a script engine that ignores AppleScript's own timeout.
    private nonisolated static func execute(
        source: String,
        description: String,
        timeout: TimeInterval? = 7
    ) async -> ScriptResult? {
        await Task.detached(priority: .utility) {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("sorty-finder-\(UUID().uuidString).log")
            let errorURL = outputURL.appendingPathExtension("err")
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
                  FileManager.default.createFile(atPath: errorURL.path, contents: nil),
                  let outputHandle = try? FileHandle(forWritingTo: outputURL),
                  let errorHandle = try? FileHandle(forWritingTo: errorURL) else { return nil }
            defer {
                try? outputHandle.close()
                try? errorHandle.close()
                try? FileManager.default.removeItem(at: outputURL)
                try? FileManager.default.removeItem(at: errorURL)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            process.standardOutput = outputHandle
            process.standardError = errorHandle
            do {
                try process.run()
                let deadline = timeout.map { Date().addingTimeInterval($0) }
                while process.isRunning {
                    if Task.isCancelled || (deadline.map { Date() >= $0 } ?? false) {
                        process.terminate()
                        let grace = Date().addingTimeInterval(1)
                        while process.isRunning, Date() < grace {
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        DebugLogger.log("AppleScript \(description) timed out")
                        return nil
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                let errorOutput = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
                if process.terminationStatus != 0 {
                    DebugLogger.log("AppleScript \(description) failed: \(errorOutput)")
                }
                return ScriptResult(status: process.terminationStatus, output: output, error: errorOutput)
            } catch {
                DebugLogger.log("AppleScript \(description) failed: \(error)")
                return nil
            }
        }.value
    }
    
    // MARK: - Permission Status
    
    /// Check if the app has Automation permission (can control Finder via AppleScript)
    public static func checkAutomationPermission() -> PermissionStatus {
        guard canCheckPermission(checksEnabled: checksEnabled) else { return .unknown }

        return determineAutomationPermission(prompt: false)
    }

    /// Requests Finder Automation with macOS's native Allow / Don't Allow alert.
    public static func requestAutomationPermission() async -> PermissionStatus {
        guard canCheckPermission(checksEnabled: checksEnabled) else { return .unknown }

        // No `with timeout` here: this script intentionally waits on the TCC
        // Allow / Don't Allow prompt, which the user may take a while to answer.
        let scriptSource = """
        tell application "Finder"
            return name of startup disk
        end tell
        """

        guard let result = await execute(
            source: scriptSource,
            description: "permission request",
            timeout: nil
        ) else { return determineAutomationPermission(prompt: false) }
        guard result.status != 0 else { return .granted }
        if result.error.contains("(-1743)") {
            return .denied
        }
        if result.error.contains("(-600)") {
            return .unknown
        }
        return determineAutomationPermission(prompt: false)
    }

    nonisolated fileprivate static func determineAutomationPermission(
        prompt: Bool
    ) -> PermissionStatus {
        let targetDesc = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        
        let status = AEDeterminePermissionToAutomateTarget(
            targetDesc.aeDesc,
            permissionEventClass,
            permissionEventID,
            prompt
        )
        
        switch status {
        case noErr:
            return .granted
        case -1743:
            // errAEEventNotPermitted: Not authorized to send Apple events to Finder
            return .denied
        case -1744:
            // Would require user consent (no decision yet)
            return .unknown
        case -600:
            // procNotFound: Finder not running
            return .unknown
        default:
            DebugLogger.log("Unexpected automation permission status: \(status)")
            return .unknown
        }
    }

    nonisolated static func canCheckPermission(
        checksEnabled: Bool
    ) -> Bool {
        checksEnabled
    }
    
    /// Open System Settings to the Automation permission pane
    public static func openAutomationSettings(
        sourceFrameInScreen: CGRect? = nil,
        onMissingApp: @escaping () -> Void = {}
    ) {
        Task { @MainActor in
            PermisoAssistant.shared.present(
                panel: .automation,
                sourceFrameInScreen: sourceFrameInScreen,
                onMissingApp: onMissingApp
            )
        }
    }
    
    // MARK: - Finder Selection
    
    /// Get the currently selected files in the frontmost Finder window
    /// Returns nil if no Finder window is open or no selection
    public static func getSelectedFiles() async -> [URL]? {
        guard checksEnabled,
              determineAutomationPermission(prompt: false) == .granted,
              let result = await execute(source: selectionQueryScript, description: "selection query"),
              result.status == 0 else {
            return nil
        }

        let paths = String(result.output.dropLast(result.output.hasSuffix("\n") ? 1 : 0))
            .split(separator: "\0")
            .map(String.init)
        guard !paths.isEmpty else { return nil }
        return paths.map { URL(fileURLWithPath: $0) }
    }
    
    /// Get the path of the frontmost Finder window
    /// Returns nil if no Finder window is open
    public static func getFrontmostFinderWindowPath() async -> URL? {
        guard checksEnabled else { return nil }
        guard checkAutomationPermission() == .granted else {
            return nil
        }
        
        let scriptSource = """
        with timeout of \(finderAutomationScriptTimeoutSeconds) seconds
            tell application "Finder"
                set targetFolder to target of front window as alias
                return POSIX path of targetFolder
            end tell
        end timeout
        """
        
        guard let result = await execute(source: scriptSource, description: "front window query"),
              result.status == 0 else {
            return nil
        }
        let path = String(result.output.dropLast(result.output.hasSuffix("\n") ? 1 : 0))
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    // MARK: - Finder Selection Control
    
    /// Select items in the frontmost Finder window
    /// - Parameters:
    ///   - urls: URLs of items to select
    ///   - reveal: Whether to reveal the items (scroll to them)
    public static func selectInFinder(urls: [URL], reveal: Bool = true) {
        guard checksEnabled else { return }
        guard !urls.isEmpty else { return }
        guard checkAutomationPermission() == .granted else { return }
        
        let pathsList = urls.map { appleScriptStringLiteral($0.path) }.joined(separator: ", ")
        
        let scriptSource = """
        with timeout of \(finderAutomationScriptTimeoutSeconds) seconds
            tell application "Finder"
                set filePaths to {\(pathsList)}
                set itemsToSelect to {}
                
                repeat with filePath in filePaths
                    if filePath is not "" then
                        try
                            set theItem to POSIX file filePath as alias
                            set end of itemsToSelect to theItem
                        end try
                    end if
                end repeat
                
                if length of itemsToSelect > 0 then
                    select itemsToSelect
                    \(reveal ? "reveal itemsToSelect" : "")
                end if
            end tell
        end timeout
        """
        
        Task { _ = await execute(source: scriptSource, description: "select in Finder") }
    }
    
    /// Reveal a single file or folder in Finder
    public static func revealInFinder(url: URL) {
        selectInFinder(urls: [url], reveal: true)
    }
    
    /// Open a folder in a new Finder window
    public static func openInNewFinderWindow(url: URL) {
        guard checksEnabled else { return }
        guard checkAutomationPermission() == .granted else { return }
        
        let scriptSource = """
        with timeout of \(finderAutomationScriptTimeoutSeconds) seconds
            tell application "Finder"
                set targetFolder to POSIX file \(appleScriptStringLiteral(url.path)) as alias
                make new Finder window to targetFolder
                activate
            end tell
        end timeout
        """
        
        Task { _ = await execute(source: scriptSource, description: "open Finder window") }
    }

    // MARK: - Finder Refresh
    
    /// Refresh all Finder windows showing the specified path
    public static func refreshFinder(at url: URL) {
        guard checksEnabled, checkAutomationPermission() == .granted else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        
        let scriptSource = """
        with timeout of \(finderAutomationScriptTimeoutSeconds) seconds
            tell application "Finder"
                set theFolder to POSIX file \(appleScriptStringLiteral(url.path)) as alias
                repeat with theWindow in (every window)
                    try
                        if (target of theWindow as alias) is theFolder then
                            update theWindow
                        end if
                    end try
                end repeat
            end tell
        end timeout
        """
        
        Task { _ = await execute(source: scriptSource, description: "refresh Finder window") }
    }

}

// MARK: - Supporting Types

public enum PermissionStatus: Sendable {
    case granted
    case denied
    case unknown
    
    public var isGranted: Bool {
        return self == .granted
    }
}

// MARK: - String Extension for FourCharCode

extension String {
    var fourCharCode: FourCharCode {
        var result: FourCharCode = 0
        let chars = Array(self.utf8)
        if chars.count >= 4 {
            result = FourCharCode(chars[0]) << 24 |
                     FourCharCode(chars[1]) << 16 |
                     FourCharCode(chars[2]) << 8 |
                     FourCharCode(chars[3])
        }
        return result
    }
}
