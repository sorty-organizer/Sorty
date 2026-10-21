import SwiftUI

struct ProviderTestConnectionButton: View {
    @SortyHotReload var hotReload
    let canTest: Bool
    let action: () -> Void

    var body: some View {
        Button {
            HapticFeedbackManager.shared.tap()
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle.fill")
                Text("Test Connection")
            }
        }
        .buttonStyle(.sortyPrimary)
        .disabled(!canTest)
        .opacity(canTest ? 1 : 0.5)
    }
}

struct CodexEmailRevealText: View {
    @SortyHotReload var hotReload
    let value: String

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var isHovering = false

    var body: some View {
        Text(value)
            .font(.caption)
            .foregroundStyle(.secondary)
            .blur(radius: FeatureFlags.privacyModeEnabled && !isHovering ? 4 : 0)
            .animation(reduceMotion ? nil : .spring(), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

struct OnboardingCodexActionButton: View {
    @SortyHotReload var hotReload
    let idleTitle: String
    let activatingTitle: String
    let successTitle: String
    let failureTitle: String
    let idleSymbol: String
    let state: CodexActionVisualState
    let accessibilityIdentifier: String
    let action: () -> Void

    @State var isHovering = false

    var body: some View {
        Button(action: action) {
            CodexActionButtonLabel(
                idleTitle: idleTitle,
                activatingTitle: activatingTitle,
                successTitle: successTitle,
                failureTitle: failureTitle,
                idleSymbol: idleSymbol,
                state: state,
                isHovered: isHovering
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .debouncedHover($isHovering)
    }
}
