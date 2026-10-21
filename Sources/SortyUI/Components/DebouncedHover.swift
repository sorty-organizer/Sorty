import SwiftUI

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
    package func debouncedHover(_ isHovering: Binding<Bool>) -> some View {
        modifier(DebouncedHoverModifier(isHovering: isHovering))
    }
}
