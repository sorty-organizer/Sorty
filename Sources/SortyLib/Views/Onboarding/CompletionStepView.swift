//
//  CompletionStepView.swift
//  Sorty
//
//  Completion step of the onboarding flow
//

import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI





@MainActor
final class CompletionRuntimeController {
    var animationTask: Task<Void, Never>?
}

public struct CompletionStepView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var runtimeController = CompletionRuntimeController()

    let providerSetupStatus: ProviderSetupStatus
    let onFinish: () -> Void

    // Entry animation states
    @State private var celebrationPhase: CompletionCelebrationPhase = .hidden
    @State private var hasAppeared = false
    @State private var showGlowRing = false
    @State private var showParticles = false
    @State private var tipsAppeared = false
    @State private var isCompletionButtonHovered = false
    @State private var completionHoverTask: Task<Void, Never>?
    @State private var lockedHoverForExit: Bool?

    private let audioController = CompletionAudioController.shared
    @State private var readinessState: ReadinessState = .idle
    @State private var isAnalyticsEnabled = true

    // Exit animation states
    @State private var exitTriggered = false
    @State private var finishTask: Task<Void, Never>?
    @State private var contentDismissed = false

    private enum ReadinessState: Equatable {
        case idle
        case checking
        case failed(String)
    }

    public init(
        providerSetupStatus: ProviderSetupStatus,
        onFinish: @escaping () -> Void
    ) {
        self.providerSetupStatus = providerSetupStatus
        self.onFinish = onFinish
        _isAnalyticsEnabled = State(
            initialValue: AnalyticsManager.shared.consent != .denied
        )
    }

    public var body: some View {
        ZStack {
            CompletionContrastBackdrop()
                .allowsHitTesting(false)

            CompletionParticleBackdrop(
                showParticles: showParticles,
                exitTriggered: exitTriggered
            )

            VStack(spacing: 16) {
                CompletionHero(
                    hasAppeared: hasAppeared,
                    showGlowRing: showGlowRing,
                    celebrationPhase: celebrationPhase,
                    exitTriggered: exitTriggered,
                    contentDismissed: contentDismissed,
                    isButtonHovered: lockedHoverForExit ?? isCompletionButtonHovered
                )
                CompletionCopy(hasAppeared: hasAppeared, contentDismissed: contentDismissed)
                CompletionTipsGrid(tipsAppeared: tipsAppeared, contentDismissed: contentDismissed)
                CompletionAnalyticsPreference(isEnabled: $isAnalyticsEnabled)
                    .opacity(tipsAppeared && !contentDismissed ? 1 : 0)
                    .offset(y: tipsAppeared ? (contentDismissed ? 40 : 0) : 12)
                    .animation(
                        reduceMotion
                            ? nil
                            : .spring(response: 0.65, dampingFraction: 0.85).delay(0.16),
                        value: tipsAppeared
                    )
                CompletionPrimaryAction(
                    tipsAppeared: tipsAppeared,
                    contentDismissed: contentDismissed,
                    isChecking: readinessState == .checking,
                    action: verifyAndFinish,
                    onHoverChanged: { isHovered in
                        guard lockedHoverForExit == nil else { return }
                        completionHoverTask?.cancel()
                        // Small enter delay filters a sub-40ms swipe that would
                        // otherwise flash the app icon; leave delay keeps the
                        // exit from jittering when the cursor brushes the edge.
                        let delayMs: Int = isHovered ? 40 : 90
                        completionHoverTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(delayMs))
                            guard !Task.isCancelled else { return }
                            if reduceMotion {
                                isCompletionButtonHovered = isHovered
                            } else {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    isCompletionButtonHovered = isHovered
                                }
                            }
                        }
                    }
                )

                if case .failed(let message) = readinessState {
                    completionFailureCard(message: message)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .accessibilityIdentifier("OnboardingCompletionHealthError")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 48)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .onAppear(perform: startRevealSequence)
        .onDisappear {
            completionHoverTask?.cancel()
            completionHoverTask = nil
            finishTask?.cancel()
            finishTask = nil
            runtimeController.animationTask?.cancel()
            runtimeController.animationTask = nil
            fadeOutAndStopAudio(duration: 0.25)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Completion Step")
    }

    // MARK: - Reveal Sequence

    private func startRevealSequence() {
        runtimeController.animationTask?.cancel()

        if reduceMotion {
            audioController.play()
            celebrationPhase = .ambient
            hasAppeared = true
            showGlowRing = true
            tipsAppeared = true
            return
        }

        // Keep the appear frame free of heavy work: first paint lands the
        // static backdrop, then the bloom (audio + blob + hero) starts on the
        // next frame so blur rasterization and audio startup can't hitch it.
        // Choreography from there: glow ring at +220 ms, blob settles to
        // ambient at +540 ms, tips plus particles land together at +720 ms.
        runtimeController.animationTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            audioController.play()
            celebrationPhase = .reveal
            hasAppeared = true

            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            showGlowRing = true
            audioController.playRevealAccent()

            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            celebrationPhase = .ambient

            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            tipsAppeared = true
            showParticles = true
            if NSApp.isActive {
                HapticFeedbackManager.shared.light()
            }
        }
    }

    private func fadeOutAndStopAudio(duration: TimeInterval) {
        audioController.fadeOutAndStop(duration: duration)
    }

    // MARK: - Exit Transition

    @ViewBuilder
    private func completionFailureCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Provider check failed")
                        .font(.headline)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            Text("Retry now, or skip verification and land in provider setup repair before your first organization.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Retry") {
                    verifyAndFinish()
                }
                .buttonStyle(.sortyPrimary(size: .small))
                .accessibilityIdentifier("OnboardingCompletionRetryButton")

                Button("Skip for Now") {
                    skipVerificationAndFinish()
                }
                .buttonStyle(.sortySecondary(size: .small))
                .accessibilityIdentifier("OnboardingCompletionSkipButton")
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.orange.opacity(0.035))
        )
        .systemLiquidGlassBackground(cornerRadius: 16, interactive: false)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.orange.opacity(0.15), lineWidth: 1)
        )
    }

    private func verifyAndFinish() {
        let configurationStatus = providerSetupStatus
        guard configurationStatus.isReady else {
            readinessState = .failed(configurationStatus.message)
            HapticFeedbackManager.shared.error()
            return
        }

        readinessState = .idle
        startTransition(verifyProvider: true)
    }

    private func skipVerificationAndFinish() {
        appState.startSetupRepair(
            message: "Sorty could not verify \(settingsViewModel.config.provider.displayName) during onboarding. Finish provider setup in Settings before organizing files.",
            navigateToSettings: true
        )
        readinessState = .idle
        startTransition()
    }

    private func startTransition(verifyProvider: Bool = false) {
        guard !exitTriggered else { return }
        runtimeController.animationTask?.cancel()
        runtimeController.animationTask = nil
        // Lock the hero icon to its current hover state so a click while
        // showing the Sorty app icon doesn't flick back to the checkmark
        // during the exit animation.
        lockedHoverForExit = isCompletionButtonHovered
        if lockedHoverForExit == false, completionHoverTask != nil {
            // Hover-enter was still in its 40ms debounce (raw hover true but
            // delayed state not yet flipped). Treat as hovered so Sorty stays.
            lockedHoverForExit = true
            completionHoverTask?.cancel()
            completionHoverTask = nil
        }
        let exitDuration = reduceMotion ? 0 : 0.52
        HapticFeedbackManager.shared.success()
        fadeOutAndStopAudio(duration: exitDuration)

        // Let the completed onboarding settle away before the main window
        // appears, rather than replacing the whole experience in one frame.
        withAnimation(reduceMotion ? nil : .easeInOut(duration: exitDuration)) {
            exitTriggered = true
            contentDismissed = true
            showParticles = false
            showGlowRing = false
        }

        finishTask?.cancel()
        finishTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(exitDuration))
            guard !Task.isCancelled, exitTriggered else { return }
            AnalyticsManager.shared.setConsent(isAnalyticsEnabled ? .granted : .denied)
            onFinish()

            if verifyProvider {
                // Outlive this view, but let the main app's 220 ms dissolve
                // settle before provider setup can publish repair state.
                let viewModel = settingsViewModel
                let state = appState
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    do {
                        try await viewModel.testConnection()
                        state.clearSetupRepairState()
                    } catch {
                        state.startSetupRepair(
                            message: "Sorty could not verify \(viewModel.config.provider.displayName). "
                                + error.localizedDescription,
                            navigateToSettings: false
                        )
                    }
                }
            }
        }
    }
}


// MARK: - Preview

#Preview {
    let codexAuthManager = CodexCLIAuthManager()

    CompletionStepView(
        providerSetupStatus: ProviderSetupStatus(
            isReady: true,
            title: "Setup complete",
            message: "Provider is ready."
        ),
        onFinish: {}
    )
        .environmentObject(SettingsViewModel())
        .environmentObject(AppState())
        .environmentObject(codexAuthManager)
}
