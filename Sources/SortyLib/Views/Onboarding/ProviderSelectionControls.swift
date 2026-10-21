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

/// Hover state with CompletionStepView's 40/90ms debounce: a short enter
/// delay filters sub-40ms swipes that would otherwise flash hover visuals,
/// and a longer leave delay keeps the exit from jittering on edge brushes.
/// Haptics never fire from hover — only from clicks.
struct DebouncedHoverModifier: ViewModifier {
    @Binding var isHovering: Bool
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()
                let delayMs = hovering ? 40 : 90
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(delayMs))
                    guard !Task.isCancelled else { return }
                    if reduceMotion {
                        isHovering = hovering
                    } else {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isHovering = hovering
                        }
                    }
                }
            }
            .onDisappear {
                hoverTask?.cancel()
            }
    }
}

extension View {
    /// Debounced hover shared across onboarding surfaces (40ms enter to
    /// filter swipe-throughs, 90ms leave to settle edge brushes).
    func debouncedHover(_ isHovering: Binding<Bool>) -> some View {
        modifier(DebouncedHoverModifier(isHovering: isHovering))
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
