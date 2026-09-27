import Foundation
import Combine
import Darwin

// MARK: - Errors

enum FileSystemError: LocalizedError {
    case fileNotFound(path: String? = nil, underlyingErrno: Int32? = nil)
    case permissionDenied(path: String? = nil, underlyingErrno: Int32? = nil)
    case diskFull(path: String?, underlyingErrno: Int32?)
    case readOnlyFileSystem(path: String?, underlyingErrno: Int32?)
    case quotaExceeded(path: String?, underlyingErrno: Int32?)
    case uniqueNameExhausted(String)
    case partialFailure(successCount: Int, failures: [OperationFailure])
    case partialApplyFailure(operations: [FileSystemManager.FileOperation], underlyingDescription: String)
    case preValidationFailed([String])
    case crossVolumeCopyVerificationFailed(String)
    case destinationEscapesBaseDirectory(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path, let errnoValue):
            var message = path.map { "File not found: \($0)" } ?? "File not found"
            if let errnoValue { message += " (errno \(errnoValue))" }
            return message
        case .permissionDenied(let path, let errnoValue):
            var message = path.map { "Permission denied: \($0)" } ?? "Permission denied"
            if let errnoValue { message += " (errno \(errnoValue))" }
            return message
        case .diskFull(let path, _):
            return path.map { "Disk is full while writing: \($0)" } ?? "Disk is full"
        case .readOnlyFileSystem(let path, _):
            return path.map { "Destination is on a read-only volume: \($0)" } ?? "Destination is on a read-only volume"
        case .quotaExceeded(let path, _):
            return path.map { "Storage quota exceeded while writing: \($0)" } ?? "Storage quota exceeded"
        case .uniqueNameExhausted(let name):
            return "Could not find an available name for \(name) after \(FileSystemManager.maximumUniqueNameAttempts) attempts"
        case .partialFailure(let successCount, let failures):
            return "Partial failure: \(successCount) succeeded, \(failures.count) failed"
        case .partialApplyFailure(let operations, let underlyingDescription):
            return "Organization stopped after \(operations.count) completed operation(s): \(underlyingDescription)"
        case .preValidationFailed(let issues):
            return "Pre-validation failed: \(issues.joined(separator: ", "))"
        case .crossVolumeCopyVerificationFailed(let path):
            return "Cross-volume copy verification failed for: \(path)"
        case .destinationEscapesBaseDirectory(let path):
            return "Destination folder resolves outside the selected directory: \(path)"
        }
    }
}

public struct OperationFailure: Sendable {
    public let sourcePath: String
    public let destinationPath: String?
    public let error: String
    public let isRetryable: Bool
}
