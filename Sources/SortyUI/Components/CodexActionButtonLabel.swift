//
//  CodexActionButtonLabel.swift
//  Sorty
//
//  Label content for Codex action buttons. The surface comes from
//  `SortyButtonStyle`; use `buttonStyle(prominent:)` to get it.
//

import SwiftUI

package enum CodexActionVisualState {
    case idle
    case activating
    case success
    case failure

    /// The shared button style for this state. Success and failure take over
    /// the button's color so the result reads at a glance.
    package func buttonStyle(prominent: Bool) -> SortyButtonStyle {
        switch self {
        case .idle, .activating:
            return SortyButtonStyle(intent: prominent ? .primary : .secondary, isProminent: prominent)
        case .success:
            return SortyButtonStyle(intent: .success, isProminent: true)
        case .failure:
            return SortyButtonStyle(intent: .destructive, isProminent: true)
        }
    }
}

package struct CodexActionButtonLabel: View {
    @SortyHotReload private var hotReload
    let idleTitle: String
    let activatingTitle: String
    let successTitle: String
    let failureTitle: String
    let idleSymbol: String
    let state: CodexActionVisualState
    let isProminent: Bool

    package init(
        idleTitle: String,
        activatingTitle: String,
        successTitle: String,
        failureTitle: String,
        idleSymbol: String,
        state: CodexActionVisualState,
        isProminent: Bool
    ) {
        self.idleTitle = idleTitle
        self.activatingTitle = activatingTitle
        self.successTitle = successTitle
        self.failureTitle = failureTitle
        self.idleSymbol = idleSymbol
        self.state = state
        self.isProminent = isProminent
    }

    private var resolvedTitle: String {
        switch state {
        case .idle: return idleTitle
        case .activating: return activatingTitle
        case .success: return successTitle
        case .failure: return failureTitle
        }
    }

    private var resolvedSymbol: String {
        switch state {
        case .idle: return idleSymbol
        case .activating: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        }
    }

    /// Matches the label color the button style uses for this state.
    private var spinnerColor: Color {
        isProminent || state == .success || state == .failure ? .white : .primary
    }

    private var accessibilityID: String {
        let normalizedTitle = idleTitle
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        return "codexActionLabel_\(normalizedTitle)"
    }

    package var body: some View {
        HStack(spacing: 6) {
            if state == .activating {
                BouncingSpinner(size: 10, color: spinnerColor)
            } else {
                Image(systemName: resolvedSymbol)
                    .symbolReplaceTransition(animationValue: resolvedSymbol)
            }

            Text(resolvedTitle)
                .numericTextTransition(animationValue: resolvedTitle)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(accessibilityID)
        .animation(.sortySnappy, value: state)
    }
}
