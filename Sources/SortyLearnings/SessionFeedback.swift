import Foundation

// Draft + policy helpers for the post-apply feedback loop.
// Pure value types so feedback validation and moment presentation stay
// testable without launching the app.
public struct SessionFeedbackDraft: Sendable, Equatable {
    public var outcome: LearningsManager.SessionOutcome?
    public var selectedChip: String?
    public var freeText: String

    public init(
        outcome: LearningsManager.SessionOutcome? = nil,
        selectedChip: String? = nil,
        freeText: String = ""
    ) {
        self.outcome = outcome
        self.selectedChip = selectedChip
        self.freeText = freeText
    }

    /// Free text wins; otherwise the selected preset chip.
    public var resolvedReason: String? {
        let trimmed = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.prefix(500)) }
        guard let chip = selectedChip?.trimmingCharacters(in: .whitespacesAndNewlines),
              !chip.isEmpty else { return nil }
        return String(chip.prefix(500))
    }

    /// notUseful must carry a reason so it can link to corrections.
    public var requiresReason: Bool { outcome == .notUseful }

    public var canSubmit: Bool {
        guard outcome != nil else { return false }
        if requiresReason { return resolvedReason != nil }
        return true
    }
}

public enum InlineLearningMomentPolicy {
    /// Max once per session; never present without a moment or while one is shown.
    public static func shouldPresent(
        moment: InlineLearningMoment?,
        presentedSessionIDs: Set<String>,
        alreadyPresenting: Bool
    ) -> Bool {
        guard !alreadyPresenting, let moment else { return false }
        guard let sessionId = moment.sessionId, !sessionId.isEmpty else { return true }
        return !presentedSessionIDs.contains(sessionId)
    }
}
