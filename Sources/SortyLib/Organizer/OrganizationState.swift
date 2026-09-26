import Foundation

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

    /// Returns true if a transition from `from` state to `to` state is valid
    public static func canTransition(from: OrganizationState, to: OrganizationState) -> Bool {
        // Re-entrant apply is never a valid transition; callers must no-op via
        // the apply() guard instead of restarting file moves. Checked before the
        // same-state fast path so applying->applying reports false.
        if from == .applying, to == .applying {
            return false
        }
        // Same state is always valid (no-op)
        if from == to {
            return true
        }

        // From idle: can go to scanning or error
        if from == .idle {
            switch to {
            case .idle, .scanning, .error:
                return true
            default:
                return false
            }
        }

        // From scanning: can go to organizing, idle (cancel), or error
        if from == .scanning {
            switch to {
            case .scanning, .organizing, .idle, .error:
                return true
            default:
                return false
            }
        }

        // From organizing: can go to ready, idle (cancel), restart scanning, or error
        if from == .organizing {
            switch to {
            case .organizing, .scanning, .ready, .idle, .error:
                return true
            default:
                return false
            }
        }

        // From ready: can re-scan, regenerate, apply, cancel, or error.
        // Ready is idle w.r.t. work (see isOperationInProgress), so re-organize
        // must be able to leave ready via scanning.
        if from == .ready {
            switch to {
            case .ready, .scanning, .applying, .idle, .organizing, .error:
                return true
            default:
                return false
            }
        }

        // From applying: can go to completed, idle (cancel), or error.
        // Re-entrant applying->applying is a no-op handled by the apply()
        // guard; it is intentionally not a valid transition so a second apply
        // cannot restart file moves (same-state equality still no-ops).
        if from == .applying {
            switch to {
            case .completed, .idle, .error:
                return true
            default:
                return false
            }
        }

        // From completed: a finished run can start a new organize (scanning),
        // regenerate (organizing), restore a preview (ready), re-apply/undo/
        // redo/restore (applying), reset (idle), or surface an error.
        if from == .completed {
            switch to {
            case .completed, .idle, .scanning, .organizing, .ready, .applying, .error:
                return true
            }
        }

        // From error: can go to idle (retry/reset), retry the previous operation,
        // or run undo/redo/restore (applying).
        if case .error = from {
            switch to {
            case .error, .idle, .scanning, .organizing, .applying:
                return true
            default:
                return false
            }
        }

        return false
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
        case .fileMoveFailed(let details):
            return "Failed to move file: \(details)"
        case .cancelled:
            return "Operation was cancelled."
        case .revertAlreadyInProgress(let path):
            return "A revert is already in progress for \(path)."
        }
    }
}
