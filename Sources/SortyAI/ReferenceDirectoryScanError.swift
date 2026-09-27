//
//  ReferenceDirectoryScanError.swift
//  SortyAI
//
//  Error thrown when a reference model directory cannot be scanned. Lives
//  here (rather than next to ReferenceDirectoryScanner) so AI clients that
//  scan reference directories do not depend on SortyCore.
//

import Foundation

public enum ReferenceDirectoryScanError: LocalizedError, Sendable {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let path):
            return "The reference directory is unavailable: \(path)"
        }
    }
}
