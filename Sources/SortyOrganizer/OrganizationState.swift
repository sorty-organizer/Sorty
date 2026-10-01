import Foundation
import SortyFileSystem
import SortyModels
import SortyAI
import SortyLearnings
import SortyFS

public enum OrganizationState: Equatable, Sendable {
    case idle
    case scanning
    case organizing
    case ready
    case applying
    case completed
    case error(Error)

    /// Whether the organizer is actively performing work and should not be interrupted.
    /// Ready means a plan is waiting for user review (no active work), so it is
    /// not in-progress. Kept in sync with `isTrackedRunningState`, the private
    /// `isOperationInProgress()`, and `AppState.isOperationInProgress`.
    public var isOperationInProgress: Bool {
        switch self {
        case .scanning, .organizing, .applying:
            return true
        case .idle, .ready, .completed, .error:
            return false
        }
    }

    public static func == (lhs: OrganizationState, rhs: OrganizationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.scanning, .scanning),
             (.organizing, .organizing),
             (.ready, .ready),
             (.applying, .applying),
             (.completed, .completed):
            return true
        case (.error(let lhsError), .error(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }

    /// Valid workflow transitions, including cancellation, retry, and incremental apply.
    public static func canTransition(from: OrganizationState, to: OrganizationState) -> Bool {
        switch (from, to) {
        // Re-entrant apply must not restart file moves.
        case (.applying, .applying):
            return false
        case (_, .idle), (_, .error):
            return true
        // Incremental auto-apply can finish while organizing. Completed runs
        // can regenerate, restore a preview, or apply undo/redo operations.
        case (.organizing, _), (.completed, _):
            return true
        case (.idle, .scanning),
             (.scanning, .scanning), (.scanning, .organizing), (.scanning, .ready),
             (.ready, .ready), (.ready, .scanning), (.ready, .organizing), (.ready, .applying),
             (.applying, .completed),
             (.error, .scanning), (.error, .organizing), (.error, .applying):
            return true
        default:
            return false
        }
    }

    /// Human-readable description of the state
    public var description: String {
        switch self {
        case .idle:
            return "Idle"
        case .scanning:
            return "Scanning"
        case .organizing:
            return "Organizing"
        case .ready:
            return "Ready"
        case .applying:
            return "Applying"
        case .completed:
            return "Completed"
        case .error(let error):
            return "Error: \(error.localizedDescription)"
        }
    }
}

public enum OrganizationError: LocalizedError, Equatable {
    case clientNotConfigured
    case automationNotConfigured
    case noCurrentPlan
    case planDirectoryMismatch(expected: String, actual: String)
    case fileMoveFailed(String)
    case cancelled
    case revertAlreadyInProgress(String)

    public var errorDescription: String? {
        switch self {
        case .clientNotConfigured:
            return "AI Client not configured. Please check your settings."
        case .automationNotConfigured:
            return "Automation permission not granted. Please enable it in System Settings > Privacy & Security > Automation."
        case .noCurrentPlan:
            return "No organization plan available to apply."
        case .planDirectoryMismatch(let expected, let actual):
            return "This plan belongs to \(expected), not \(actual). Select the plan's original folder to apply it."
        case .fileMoveFailed(let details):
            return "Failed to move file: \(details)"
        case .cancelled:
            return "Operation was cancelled."
        case .revertAlreadyInProgress(let path):
            return "A revert is already in progress for \(path)."
        }
    }
}
