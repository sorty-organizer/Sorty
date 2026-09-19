//
//  DeeplinkHandler.swift
//  Sorty
//
//  Handles URL scheme deeplinks for app-wide navigation
//

import Foundation
import Combine
import SwiftUI

// MARK: - Deeplink Types

public enum DeeplinkDestination: Equatable {
    case organize(path: String?, persona: String?, mode: OrganizationMode?, autostart: Bool)
    case duplicates(path: String?, autostart: Bool)
    case learnings(action: LearningsAction?, project: String?)
    case settings(section: String?)
    case help(section: String?)
    case open(path: String?)
    case history(entryID: UUID? = nil)
    case persona(action: String?, prompt: String?, generate: Bool)
    case watched(action: String?, path: String?)
    case rules(action: String?, type: String?, pattern: String?)
    case exclusions(action: String?, pattern: String?)
    case exclude(path: String?)
    case storage(action: String?, path: String?)
    
    /// Actions specific to Learnings feature
    public enum LearningsAction: String, Equatable {
        case stats        // Show detailed statistics
        case withdraw     // Withdraw consent (pause learning)
        case export       // Export profile data
        case importProfile = "import"
        case clear        // Clear all data
    }
}

// MARK: - Deeplink Handler

@MainActor
public class DeeplinkHandler: ObservableObject {
    public static let shared = DeeplinkHandler()
    
    @Published public var pendingDestination: DeeplinkDestination?
    
    private init() {}
    
    /// Parse a URL into a deeplink destination
    /// URL scheme: sorty://
    /// Examples:
    ///   sorty://organize?path=/Users/foo/Downloads
    ///   sorty://duplicates
    ///   sorty://learnings?project=Photos
    ///   sorty://settings
    ///   sorty://help?section=personas
    ///   sorty://open
    ///   sorty:///Users/foo/Downloads
    public func handle(url: URL) {
        pendingDestination = nil
        guard url.scheme?.lowercased() == "sorty" else { return }
        
        let host = url.host ?? ""
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        
        func queryValue(for name: String) -> String? {
            // URLComponents query values are already percent-decoded once.
            // Do not call removingPercentEncoding on the result.
            queryItems.first { $0.name == name }?.value
        }
        
        let normalizedHost = host.lowercased()
        
        if normalizedHost.isEmpty {
            // URL.path is already percent-decoded exactly once. Do not call
            // removingPercentEncoding again: "%252e" would decode twice to "."
            let legacyPath = url.path
            if !legacyPath.isEmpty && legacyPath != "/" {
                pendingDestination = .organize(path: legacyPath, persona: nil, mode: nil, autostart: false)
                return
            }
        }
        
        switch normalizedHost {
        case "organize", "scan":
            let path = queryValue(for: "path")
            let persona = queryValue(for: "persona")
            let mode = queryValue(for: "mode").flatMap { OrganizationMode(rawValue: $0) }
            let autostart = normalizedHost == "scan" || queryValue(for: "autostart") == "true"
            pendingDestination = .organize(path: path, persona: persona, mode: mode, autostart: autostart)
            
        case "duplicates":
            let path = queryValue(for: "path")
            let autostart = queryValue(for: "autostart") == "true"
            pendingDestination = .duplicates(path: path, autostart: autostart)
            
        case "learnings":
            let actionStr = queryValue(for: "action")
            let action = actionStr.flatMap { DeeplinkDestination.LearningsAction(rawValue: $0) }
            pendingDestination = .learnings(action: action, project: queryValue(for: "project"))
            
        case "settings":
            pendingDestination = .settings(section: queryValue(for: "section"))
            
        case "help":
            pendingDestination = .help(section: queryValue(for: "section"))
            
        case "open":
            pendingDestination = .open(path: queryValue(for: "path"))
            
        case "history":
            pendingDestination = .history(entryID: queryValue(for: "entry").flatMap(UUID.init(uuidString:)))
            
        case "persona":
            let action = queryValue(for: "action")
            let prompt = queryValue(for: "prompt")
            let generate = queryValue(for: "generate") == "true"
            pendingDestination = .persona(action: action, prompt: prompt, generate: generate)
            
        case "watched":
            let action = queryValue(for: "action")
            let path = queryValue(for: "path")
            pendingDestination = .watched(action: action, path: path)
            
        case "rules":
            let action = queryValue(for: "action")
            let type = queryValue(for: "type")
            let pattern = queryValue(for: "pattern")
            pendingDestination = .rules(action: action, type: type, pattern: pattern)
            
        case "exclusions":
            let action = queryValue(for: "action")
            let pattern = queryValue(for: "pattern")
            pendingDestination = .exclusions(action: action, pattern: pattern)

        case "exclude":
            pendingDestination = .exclude(path: queryValue(for: "path") ?? queryValue(for: "pattern"))
            
        case "storage":
            let action = queryValue(for: "action")
            let path = queryValue(for: "path")
            pendingDestination = .storage(action: action, path: path)
            
        default:
            DebugLogger.log("Unknown deeplink: \(url)")
        }
    }
    
    /// Clear pending destination after navigation
    public func clearPending() {
        pendingDestination = nil
    }
    
    /// Generate a deeplink URL
    public static func url(for destination: DeeplinkDestination) -> URL? {
        var components = URLComponents()
        components.scheme = "sorty"
        
        switch destination {
        case .organize(let path, let persona, let mode, let autostart):
            components.host = "organize"
            var items: [URLQueryItem] = []
            if let path = path {
                items.append(URLQueryItem(name: "path", value: path))
            }
            if let persona = persona {
                items.append(URLQueryItem(name: "persona", value: persona))
            }
            if let mode {
                items.append(URLQueryItem(name: "mode", value: mode.rawValue))
            }
            if autostart {
                items.append(URLQueryItem(name: "autostart", value: "true"))
            }
            if !items.isEmpty { components.queryItems = items }
            
        case .duplicates(let path, let autostart):
            components.host = "duplicates"
            var items: [URLQueryItem] = []
            if let path = path {
                items.append(URLQueryItem(name: "path", value: path))
            }
            if autostart {
                items.append(URLQueryItem(name: "autostart", value: "true"))
            }
            if !items.isEmpty { components.queryItems = items }
            
        case .learnings(let action, let project):
            components.host = "learnings"
            var items: [URLQueryItem] = []
            if let action = action {
                items.append(URLQueryItem(name: "action", value: action.rawValue))
            }
            if let project = project {
                items.append(URLQueryItem(name: "project", value: project))
            }
            if !items.isEmpty { components.queryItems = items }
            
        case .settings(let section):
            components.host = "settings"
            if let section = section {
                components.queryItems = [URLQueryItem(name: "section", value: section)]
            }
            
        case .help(let section):
            components.host = "help"
            if let section = section {
                components.queryItems = [URLQueryItem(name: "section", value: section)]
            }
            
        case .open(let path):
            components.host = "open"
            if let path = path {
                components.queryItems = [URLQueryItem(name: "path", value: path)]
            }
            
        case .history(let entryID):
            components.host = "history"
            if let entryID {
                components.queryItems = [URLQueryItem(name: "entry", value: entryID.uuidString)]
            }
            
        case .persona(let action, let prompt, let generate):
            components.host = "persona"
            var items: [URLQueryItem] = []
            if let action = action {
                items.append(URLQueryItem(name: "action", value: action))
            }
            if let prompt = prompt {
                items.append(URLQueryItem(name: "prompt", value: prompt))
            }
            if generate {
                items.append(URLQueryItem(name: "generate", value: "true"))
            }
            if !items.isEmpty { components.queryItems = items }
            
        case .watched(let action, let path):
            components.host = "watched"
            var items: [URLQueryItem] = []
            if let action = action {
                items.append(URLQueryItem(name: "action", value: action))
            }
            if let path = path {
                items.append(URLQueryItem(name: "path", value: path))
            }
            if !items.isEmpty { components.queryItems = items }
            
        case .rules(let action, let type, let pattern):
            components.host = "rules"
            var items: [URLQueryItem] = []
            if let action = action {
                items.append(URLQueryItem(name: "action", value: action))
            }
            if let type = type {
                items.append(URLQueryItem(name: "type", value: type))
            }
            if let pattern = pattern {
                items.append(URLQueryItem(name: "pattern", value: pattern))
            }
            if !items.isEmpty { components.queryItems = items }
            
        case .exclusions(let action, let pattern):
            components.host = "exclusions"
            var items: [URLQueryItem] = []
            if let action = action {
                items.append(URLQueryItem(name: "action", value: action))
            }
            if let pattern = pattern {
                items.append(URLQueryItem(name: "pattern", value: pattern))
            }
            if !items.isEmpty { components.queryItems = items }

        case .exclude(let path):
            components.host = "exclude"
            if let path {
                components.queryItems = [URLQueryItem(name: "path", value: path)]
            }
            
        case .storage(let action, let path):
            components.host = "storage"
            var items: [URLQueryItem] = []
            if let action = action {
                items.append(URLQueryItem(name: "action", value: action))
            }
            if let path = path {
                items.append(URLQueryItem(name: "path", value: path))
            }
            if !items.isEmpty { components.queryItems = items }
        }
        
        return components.url
    }
}
