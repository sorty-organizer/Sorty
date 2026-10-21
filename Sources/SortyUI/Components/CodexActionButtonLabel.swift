//
//  CodexActionButtonLabel.swift
//  Sorty
//
//  Custom visual treatment for Codex action buttons.
//

import SwiftUI

package enum CodexActionVisualState {
    case idle
    case activating
    case success
    case failure
}

package struct CodexActionButtonLabel: View {
    @SortyHotReload private var hotReload
    let idleTitle: String
    let activatingTitle: String
    let successTitle: String
    let failureTitle: String
    let idleSymbol: String
    let state: CodexActionVisualState
    let isHovered: Bool

    package init(
        idleTitle: String,
        activatingTitle: String,
        successTitle: String,
        failureTitle: String,
        idleSymbol: String,
        state: CodexActionVisualState,
        isHovered: Bool
    ) {
        self.idleTitle = idleTitle
        self.activatingTitle = activatingTitle
        self.successTitle = successTitle
        self.failureTitle = failureTitle
        self.idleSymbol = idleSymbol
        self.state = state
        self.isHovered = isHovered
    }

    private var resolvedTitle: String {
        switch state {
        case .idle:
            return idleTitle
        case .activating:
            return activatingTitle
        case .success:
            return successTitle
        case .failure:
            return failureTitle
        }
    }

    private var resolvedSymbol: String {
        switch state {
        case .idle:
            return idleSymbol
        case .activating:
            return "arrow.triangle.2.circlepath"
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "xmark.circle.fill"
        }
    }

    private var backgroundColors: [Color] {
        switch state {
        case .idle:
            return [Color.cyan.opacity(isHovered ? 0.95 : 0.82), Color.blue.opacity(isHovered ? 0.92 : 0.78)]
        case .activating:
            return [Color.orange.opacity(0.95), Color.red.opacity(0.85)]
        case .success:
            return [Color.green.opacity(0.95), Color.teal.opacity(0.86)]
        case .failure:
            return [Color.red.opacity(0.92), Color.pink.opacity(0.84)]
        }
    }

    private var borderColor: Color {
        switch state {
        case .idle:
            return .white.opacity(0.32)
        case .activating:
            return .white.opacity(0.4)
        case .success:
            return .white.opacity(0.45)
        case .failure:
            return .white.opacity(0.38)
        }
    }

    private var isAnimating: Bool {
        state == .activating
    }

    private var accessibilityID: String {
        let normalizedTitle = idleTitle
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        return "codexActionLabel_\(normalizedTitle)"
    }

    package var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 20, height: 20)

                if isAnimating {
                    BouncingSpinner(size: 10, color: .white)
                } else {
                    Image(systemName: resolvedSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolReplaceTransition(animationValue: resolvedSymbol)
                }
            }

            Text(resolvedTitle)
                .font(.system(.caption, design: .rounded))
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .numericTextTransition(animationValue: resolvedTitle)

            Spacer(minLength: 6)

            if state == .success {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.92))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: backgroundColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isHovered ? 0.2 : 0.12), radius: isHovered ? 6 : 4, x: 0, y: 2)
        .scaleEffect(isAnimating ? 0.985 : (isHovered ? 1.01 : 1.0))
        .accessibilityIdentifier(accessibilityID)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: state)
        .animation(.spring(response: 0.2, dampingFraction: 0.85), value: isHovered)
    }
}
