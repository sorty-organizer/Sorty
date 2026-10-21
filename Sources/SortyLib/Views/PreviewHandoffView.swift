import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Preview handoff

struct PreviewHandoffView: View {
    @SortyHotReload private var hotReload
    let mode: OrganizationMode
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 48, height: 48)

                Image(systemName: mode == .renameOnly ? "text.badge.checkmark" : "checkmark.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .symbolReplaceTransition(animationValue: mode)
                    .scaleEffect(appeared ? 1 : 0.88)
            }

            Text(mode == .renameOnly ? "Preparing name preview" : "Preparing preview")
                .font(.subheadline.weight(.semibold))
                .numericTextTransition(animationValue: mode)

            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary.opacity(0.32))
                        .frame(width: 5, height: 5)
                        .modifier(PreviewHandoffDot(delay: Double(index) * 0.14))
                }
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(appeared ? 1 : 0)
        .animation(.smooth(duration: 0.28), value: appeared)
        .onAppear { appeared = true }
    }
}

struct PreviewHandoffDot: ViewModifier {
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var isWindowVisible = true

    private var dotPaused: Bool {
        reduceMotion || !isWindowVisible || controlActiveState == .inactive
            || scenePhase != .active
    }

    func body(content: Content) -> some View {
        Group {
            if reduceMotion {
                content
                    .scaleEffect(1)
                    .opacity(0.6)
            } else {
                SwiftUI.TimelineView(
                    .animation(minimumInterval: 1.0 / 15.0, paused: dotPaused)
                ) { timeline in
                    // Shared clock: each dot offsets the same 1.16s pulse
                    // cycle instead of owning a repeatForever transaction.
                    let cycle = 1.16
                    let elapsed = timeline.date.timeIntervalSinceReferenceDate + delay
                    let progress = dotPaused ? 0.5 : CGFloat((elapsed / cycle).truncatingRemainder(dividingBy: 1))
                    let eased = progress * progress * (3 - 2 * progress)
                    content
                        .scaleEffect(0.78 + eased * 0.44)
                        .opacity(0.35 + eased * 0.53)
                }
            }
        }
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
    }
}
