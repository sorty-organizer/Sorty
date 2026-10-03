//
//  FileOrganizationValidator.swift
//  Sorty
//
//  Validates organization plan before execution
//

import Foundation
import SortyFileSystem
import SortyModels
import SortyAI
import SortyLearnings
import SortyFS

struct FileOrganizationValidator {
    static func validateOffMain(
        _ plan: OrganizationPlan,
        at baseURL: URL,
        allowedStorageLocations: [StorageLocation] = [],
        mode: OrganizationMode = .organize
    ) async throws {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try validate(
                plan,
                at: baseURL,
                allowedStorageLocations: allowedStorageLocations,
                mode: mode
            )
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            task.cancel()
        }
    }

    static func validate(
        _ plan: OrganizationPlan,
        at baseURL: URL,
        allowedStorageLocations: [StorageLocation] = [],
        mode: OrganizationMode = .organize
    ) throws {
        let fileManager = FileManager.default
        
        // Check if base directory exists
        guard fileManager.fileExists(atPath: baseURL.path) else {
            throw ValidationError.baseDirectoryNotFound
        }
        
        if mode != .renameOnly {
            // These checks protect AI-created destinations. Rename-only destinations
            // are derived from existing source folders by OrganizationModePlanEnforcer.
            try validateDestinations(plan, at: baseURL, allowedLocations: allowedStorageLocations)
            try checkConflicts(plan, at: baseURL)
        }
        
        // Validate file existence
        try validateFileExistence(plan)
        
        // Large operations are allowed. We keep validation focused on correctness
        // constraints (conflicts, missing files, and storage safety).
    }

    private static func validateDestinations(_ plan: OrganizationPlan, at baseURL: URL, allowedLocations: [StorageLocation]) throws {
        let allowedPaths = Set(allowedLocations.map { StorageLocationPathResolver.resolvedPath($0.path) })

        let basePath = StorageLocationPathResolver.resolvedPath(baseURL.path)

        func checkSuggestion(
            _ suggestion: FolderSuggestion,
            parentURL: URL,
            confinementRootPath: String
        ) throws {
            let childParentURL: URL
            let childConfinementRootPath: String
            if let absolutePath = StorageLocationPathResolver.normalizedAbsolutePath(from: suggestion.folderName) {
                let resolvedPath = StorageLocationPathResolver.resolvedPath(absolutePath)
                guard !allowedPaths.isEmpty,
                      isAllowedStorageDestination(resolvedPath, allowedRoots: allowedPaths) else {
                    throw ValidationError.invalidStorageLocation(absolutePath)
                }
                childParentURL = URL(fileURLWithPath: resolvedPath, isDirectory: true)
                childConfinementRootPath = allowedPaths.first {
                    StorageLocationPathResolver.isPath(resolvedPath, within: $0)
                } ?? resolvedPath
            } else {
                let components = suggestion.folderName
                    .replacingOccurrences(of: "\\", with: "/")
                    .split(separator: "/", omittingEmptySubsequences: true)
                guard !components.contains("..") else {
                    throw ValidationError.destinationEscapesBaseDirectory(suggestion.folderName)
                }

                childParentURL = parentURL.appendingPathComponent(suggestion.folderName, isDirectory: true)
                let resolvedPath = StorageLocationPathResolver.resolvedPath(childParentURL.path)
                guard StorageLocationPathResolver.isPath(resolvedPath, within: confinementRootPath) else {
                    throw ValidationError.destinationEscapesBaseDirectory(suggestion.folderName)
                }
                childConfinementRootPath = confinementRootPath
            }

            for subfolder in suggestion.subfolders {
                try checkSuggestion(
                    subfolder,
                    parentURL: childParentURL,
                    confinementRootPath: childConfinementRootPath
                )
            }
        }

        for suggestion in plan.suggestions {
            try checkSuggestion(suggestion, parentURL: baseURL, confinementRootPath: basePath)
        }
    }
    
    static func checkConflicts(_ plan: OrganizationPlan, at baseURL: URL) throws {
        var existingPaths: Set<String> = []
        let fileManager = FileManager.default
        var checkedCount = 0
        
        func checkSuggestion(_ suggestion: FolderSuggestion, parentURL: URL) throws {
            let folderURL: URL
            if let absoluteURL = StorageLocationPathResolver.absoluteURL(from: suggestion.folderName) {
                folderURL = absoluteURL
            } else {
                folderURL = parentURL.appendingPathComponent(suggestion.folderName, isDirectory: true)
            }
            let folderPath = folderURL.path
            
            if existingPaths.contains(folderPath) {
                throw ValidationError.pathConflict(folderPath)
            }

            checkedCount += 1
            if checkedCount.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            
            // Allow organizing into existing directories - only reject paths that exist as files
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: folderPath, isDirectory: &isDirectory) {
                if !isDirectory.boolValue {
                    // Path exists but is a file, not a directory - this is a conflict
                    throw ValidationError.pathExists(folderPath)
                }
                // If it's already a directory, that's fine - we can organize into it
            }
            
            existingPaths.insert(folderPath)
            
            // Check subfolders
            for subfolder in suggestion.subfolders {
                try checkSuggestion(subfolder, parentURL: folderURL)
            }
        }
        
        for suggestion in plan.suggestions {
            try checkSuggestion(suggestion, parentURL: baseURL)
        }
    }
    
    static func validateFileExistence(_ plan: OrganizationPlan) throws {
        let fileManager = FileManager.default
        // Validated incrementally in strides so a large plan stays abortable
        // instead of blocking the off-main validation task in one pass.
        var checkedCount = 0
        func checkExists(url: URL, displayPath: String) throws {
            checkedCount += 1
            if checkedCount.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            guard fileManager.fileExists(atPath: url.path) else {
                throw ValidationError.fileNotFound(displayPath)
            }
        }

        func validateFiles(_ suggestion: FolderSuggestion) throws {
            for file in suggestion.files {
                guard let url = file.url else {
                    throw ValidationError.fileNotFound(file.path)
                }

                try checkExists(url: url, displayPath: file.path)
            }

            for subfolder in suggestion.subfolders {
                try validateFiles(subfolder)
            }
        }

        for suggestion in plan.suggestions {
            try validateFiles(suggestion)
        }

        for file in plan.unorganizedFiles {
            guard let url = file.url else {
                throw ValidationError.fileNotFound(file.path)
            }

            try checkExists(url: url, displayPath: file.path)
        }
    }
    
    private static func isAllowedStorageDestination(_ absolutePath: String, allowedRoots: Set<String>) -> Bool {
        for rootPath in allowedRoots where StorageLocationPathResolver.isPath(absolutePath, within: rootPath) {
            return true
        }
        return false
    }
}

package enum ValidationError: LocalizedError {
    case baseDirectoryNotFound
    case pathConflict(String)
    case pathExists(String)
    case fileNotFound(String)
    case largeOperation(Int)
    case invalidStorageLocation(String)
    case destinationEscapesBaseDirectory(String)
    
    package var errorDescription: String? {
        switch self {
        case .baseDirectoryNotFound:
            return "Base directory not found"
        case .pathConflict(let path):
            return "Path conflict: \(path)"
        case .pathExists(let path):
            return "Cannot create folder: A file already exists at '\(path)'. Sorty suggested a folder name that conflicts with an existing file."
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .largeOperation(let count):
            return "Large operation detected (\(count) files). Please review carefully."
        case .invalidStorageLocation(let path):
            return "Invalid storage location: \(path). Sorty suggested a path that is not in your approved storage locations list."
        case .destinationEscapesBaseDirectory(let path):
            return "Destination folder resolves outside the selected directory: \(path)"
        }
    }
}
