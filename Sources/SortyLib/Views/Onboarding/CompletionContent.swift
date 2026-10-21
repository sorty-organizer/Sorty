import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI

struct CompletionCopy: View {
    @SortyHotReload private var hotReload
    let hasAppeared: Bool
    let contentDismissed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            Text("Ready to Organize")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 20)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.85).delay(0.2),
                    value: hasAppeared
                )

            Text("Drop in a folder, preview the plan, and undo anything you change.")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 15)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.85).delay(0.4),
                    value: hasAppeared
                )
        }
        .opacity(contentDismissed ? 0 : 1)
        .offset(y: contentDismissed ? 30 : 0)
    }
}

struct CompletionTipsGrid: View {
    @SortyHotReload private var hotReload
    let tipsAppeared: Bool
    let contentDismissed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            VStack(alignment: .leading, spacing: 14) {
                quickTip(icon: "folder.badge.plus", text: "Organize from Finder", delay: 0)
                quickTip(icon: "arrow.uturn.backward", text: "Undo from History", delay: 0.08)
            }
            VStack(alignment: .leading, spacing: 14) {
                quickTip(icon: "keyboard", text: "⌘O opens a folder", delay: 0.04)
                quickTip(icon: "gearshape", text: "Swap models in Settings", delay: 0.12)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(contentDismissed ? 0 : 1)
        .offset(y: contentDismissed ? 40 : 0)
    }

    private func quickTip(icon: String, text: String, delay: Double) -> some View {
        QuickTipRow(icon: icon, text: text)
            .opacity(tipsAppeared ? 1 : 0)
            .offset(y: tipsAppeared ? 0 : 12)
            .animation(
                reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.85).delay(delay),
                value: tipsAppeared
            )
    }
}

struct CompletionPrimaryAction: View {
    @SortyHotReload private var hotReload
    let tipsAppeared: Bool
    let contentDismissed: Bool
    let isChecking: Bool
    let action: () -> Void
    let onHoverChanged: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("Start Using Sorty")
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .buttonStyle(.sortyPrimary(size: .large))
        .keyboardShortcut(.defaultAction)
        .disabled(isChecking)
        .onHover { hovering in
            onHoverChanged(hovering)
        }
        .opacity(tipsAppeared && !contentDismissed ? 1 : 0)
        .offset(y: tipsAppeared ? (contentDismissed ? 50 : 0) : 16)
        .animation(
            reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.85).delay(0.2),
            value: tipsAppeared
        )
        .padding(.top, 6)
        .accessibilityIdentifier("OnboardingCompleteButton")
    }
}

struct CompletionAnalyticsPreference: View {
    @Environment(\.colorScheme) private var colorScheme
    @SortyHotReload private var hotReload
    @Binding var isEnabled: Bool
    @State private var isShowingDetails = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $isEnabled) {
                Text("Share anonymous analytics")
                    .font(.system(size: 13.5, weight: .medium, design: .rounded))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier("OnboardingAnalyticsToggle")
            .onChange(of: isEnabled) { _, _ in
                HapticFeedbackManager.shared.selection()
            }

            Button {
                HapticFeedbackManager.shared.tap()
                isShowingDetails.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    HapticFeedbackManager.shared.selection()
                }
            }
            .help("What anonymous analytics includes")
            .accessibilityLabel("About anonymous analytics")
            .accessibilityIdentifier("OnboardingAnalyticsInfoButton")
            .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
                analyticsDetails
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            if colorScheme == .light {
                Capsule()
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.72))
                    .padding(-8)
                    .blur(radius: 12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            Capsule()
                .fill(
                    colorScheme == .dark
                        ? CompletionPalette.shadowRose.opacity(0.18)
                        : Color(NSColor.controlBackgroundColor)
                )
        }
    }

    private var analyticsDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Anonymous analytics")
                .font(.headline)

            Text("When this is on, Sorty sends limited product and reliability events so we can see which parts of the app are useful and where failures occur.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            detailSection(
                title: "What is included",
                systemImage: "checkmark.circle.fill",
                color: .green,
                text: "Screens and features used; broad actions, outcomes, counts, and timings; app and macOS versions and device category; sanitized errors and crashes with messages and sensitive values redacted."
            )

            detailSection(
                title: "What is never included",
                systemImage: "xmark.circle.fill",
                color: .red,
                text: "Your identity, folder or file names, paths, file contents, prompts, custom instructions, AI responses, API keys, or other credentials. Sorty does not record your screen or keystrokes."
            )

            Text("You can change this at any time in Settings → Advanced. Turning it off stops analytics and clears locally stored analytics data.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 390, alignment: .leading)
        .systemLiquidGlassPopover(cornerRadius: 12)
    }

    private func detailSection(
        title: String,
        systemImage: String,
        color: Color,
        text: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
