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

private func appleScriptStringLiteral(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: "\\t")
    return "\"\(escaped)\""
}

private actor FinderSelectionQuery {
    static let shared = FinderSelectionQuery()

    private let script = NSAppleScript(source: """
        tell application "Finder"
            try
                set selectedItems to selection
                set filePaths to {}
                repeat with anItem in selectedItems
                    set end of filePaths to POSIX path of (anItem as alias)
                end repeat
                return filePaths
            on error
                return ""
            end try
        end tell
        """)

    func selectedFiles(checksEnabled: Bool) -> [URL]? {
        guard checksEnabled,
              FinderAutomation.determineAutomationPermission(prompt: false) == .granted,
              let script else { return nil }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            DebugLogger.log("AppleScript error getting selection: \(errorInfo)")
            return nil
        }

        guard result.descriptorType == typeAEList, result.numberOfItems > 0 else {
            return nil
        }
        let paths = (1...result.numberOfItems).compactMap { index in
            result.atIndex(index)?.stringValue
        }
        guard !paths.isEmpty else { return nil }
        return paths.map { URL(fileURLWithPath: $0) }
    }
}

/// Service for automating Finder interactions
/// Uses AppleScript which requires Automation permission
@MainActor
public final class FinderAutomation {
    
    private static var checksEnabled = false
    nonisolated static let permissionEventClass = AEEventClass(kAECoreSuite)
    nonisolated static let permissionEventID = AEEventID(kAEGetData)
    
    public static func enableAutomationChecks() {
        checksEnabled = true
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

        let scriptSource = """
        tell application "Finder"
            return name of startup disk
        end tell
        """

        guard let script = NSAppleScript(source: scriptSource) else {
            return determineAutomationPermission(prompt: true)
        }

        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)

        guard let errorInfo else { return .granted }
        let errorCode = errorInfo[NSAppleScript.errorNumber] as? Int
        switch errorCode {
        case -1743:
            return .denied
        case -600:
            return .unknown
        default:
            DebugLogger.log("Unexpected Finder automation request error: \(errorInfo)")
            return determineAutomationPermission(prompt: false)
        }
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
        await FinderSelectionQuery.shared.selectedFiles(checksEnabled: checksEnabled)
    }
    
    /// Get the path of the frontmost Finder window
    /// Returns nil if no Finder window is open
    public static func getFrontmostFinderWindowPath() -> URL? {
        guard checksEnabled else { return nil }
        guard checkAutomationPermission() == .granted else {
            return nil
        }
        
        let scriptSource = """
        tell application "Finder"
            try
                set targetFolder to target of front window as alias
                return POSIX path of targetFolder
            on error
                return ""
            end try
        end tell
        """
        
        guard let script = NSAppleScript(source: scriptSource) else {
            return nil
        }
        
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        
        if let error = errorInfo {
            DebugLogger.log("AppleScript error getting front window: \(error)")
            return nil
        }
        
        guard let path = result.stringValue, !path.isEmpty else {
            return nil
        }
        
        return URL(fileURLWithPath: path)
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
        tell application "Finder"
            try
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
            on error errMsg
                return "Error: " & errMsg
            end try
        end tell
        """
        
        guard let script = NSAppleScript(source: scriptSource) else {
            return
        }
        
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        
        if let error = errorInfo {
            DebugLogger.log("AppleScript error selecting in Finder: \(error)")
        }
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
        tell application "Finder"
            try
                set targetFolder to POSIX file \(appleScriptStringLiteral(url.path)) as alias
                make new Finder window to targetFolder
                activate
            on error errMsg
                return "Error: " & errMsg
            end try
        end tell
        """
        
        guard let script = NSAppleScript(source: scriptSource) else {
            return
        }
        
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        
        if let error = errorInfo {
            DebugLogger.log("AppleScript error opening Finder window: \(error)")
        }
    }

    // MARK: - Finder Refresh
    
    /// Refresh all Finder windows showing the specified path
    public static func refreshFinder(at url: URL) {
        guard checksEnabled, checkAutomationPermission() == .granted else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        
        let scriptSource = """
        tell application "Finder"
            try
                set theFolder to POSIX file \(appleScriptStringLiteral(url.path)) as alias
                repeat with theWindow in (every window)
                    try
                        if (target of theWindow as alias) is theFolder then
                            update theWindow
                        end if
                    end try
                end repeat
            on error
                -- Ignore errors
            end try
        end tell
        """
        
        guard let script = NSAppleScript(source: scriptSource) else {
            return
        }
        
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        
        if let error = errorInfo {
            DebugLogger.log("AppleScript error refreshing Finder: \(error)")
        }
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
