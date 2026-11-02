import AppKit
import Foundation
import SwiftUI
import Beam
import SortyUI

// Empty state for the duplicates pane. Lays out through SortyEmptyState and
// keeps the primary action's identifier, default-action shortcut, and beam.
struct DuplicatesEmptyStateView: View {
    @SortyHotReload private var hotReload
    let title: String
    let description: String
    let icon: String
    var heroTint: Color?
    let actionTitle: String
    var actionAccessibilityIdentifier: String?
    var isDefaultAction = false
    let action: () -> Void
    @State private var beamHasAppeared = false

    var body: some View {
        SortyEmptyState(
            LocalizedStringKey(title),
            systemImage: icon,
            message: LocalizedStringKey(description),
            tint: heroTint,
            size: .page
        ) {
            Button(action: action) {
                Text(actionTitle)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.sortyProminent)
            .onboardingBeamBorder(variant: .featured, active: beamHasAppeared)
            .controlSize(.large)
            .modifier(DefaultActionShortcut(isEnabled: isDefaultAction))
            .accessibilityLabel(actionTitle)
            .accessibilityHint(
                isDefaultAction
                    ? "Press Enter to \(actionTitle.lowercased())"
                    : "Activate to \(actionTitle.lowercased())"
            )
            .accessibilityIdentifier(
                actionAccessibilityIdentifier
                    ?? "\(title.replacingOccurrences(of: " ", with: ""))Action"
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            beamHasAppeared = true
        }
    }
}

struct DefaultActionShortcut: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}
