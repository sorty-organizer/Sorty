import AppKit
import Foundation
import SwiftUI
import Beam

// Reused components
struct DuplicatesEmptyStateView: View {
    @SortyHotReload private var hotReload
    let title: String
    let description: String
    let icon: String
    var iconColor: Color = .secondary
    var heroTint: Color?
    let actionTitle: String
    var actionAccessibilityIdentifier: String?
    var animatesIcon = false
    var celebratesAppearance = false
    var isDefaultAction = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @State private var beamHasAppeared = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                if celebratesAppearance {
                    Circle()
                        .stroke(heroTint ?? .green, lineWidth: 2)
                        .frame(width: 100, height: 100)
                        .scaleEffect(reduceMotion ? 1 : (hasAppeared ? 1.28 : 0.78))
                        .opacity(hasAppeared ? 0 : 0.42)
                }

                if animatesIcon {
                    ScanningPulseIcon(systemName: icon, color: iconColor)
                } else {
                    EmptyStateHeroIcon(
                        systemName: icon,
                        tint: heroTint,
                        symbolBounceTrigger: celebratesAppearance && hasAppeared && !reduceMotion
                    )
                }
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.82)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.18)
                    : .spring(response: 0.48, dampingFraction: 0.64).delay(0.06),
                value: hasAppeared
            )
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(LocalizedStringKey(title))
                    .font(.title2.bold())

                Text(LocalizedStringKey(description))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 350)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title). \(description)")
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: reduceMotion || hasAppeared ? 0 : 10)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.18).delay(0.04)
                    : .spring(response: 0.5, dampingFraction: 0.82).delay(0.16),
                value: hasAppeared
            )

            Button(action: action) {
                Text(actionTitle)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.sortyPrimary)
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
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: reduceMotion || hasAppeared ? 0 : 14)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.18).delay(0.08)
                    : .spring(response: 0.52, dampingFraction: 0.82).delay(0.24),
                value: hasAppeared
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            hasAppeared = true

            try? await Task.sleep(for: .milliseconds(reduceMotion ? 80 : 420))
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
