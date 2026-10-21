//
//  OnboardingView.swift
//  Sorty
//
//  Interactive onboarding flow for first-time users
//  Steps: Provider Selection → Permissions → Workflow → Demo → Completion
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import os

let onboardingPerformanceLog = OSLog(
    subsystem: "com.sorty.app",
    category: .pointsOfInterest
)

// MARK: - Main Onboarding View

enum OnboardingIntroRevealPhase: Int {
    case icon
    case screenGlow
    case window
    case files
}

public struct OnboardingView: View {
    @SortyHotReload private var hotReload
    @Binding var hasCompletedOnboarding: Bool
    private let isRestart: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentStep: OnboardingStep = .provider
    @State private var providerSetupStatus = ProviderSetupStatus(
        isReady: false,
        title: "Setup required",
        message: "Choose and configure an AI provider before continuing."
    )
    @State private var hasFilesAndFoldersPermission = false
    @State private var advanceValidationMessage: String?
    @State private var isShowingProviderSkipConfirmation = false
    @State private var isAdvancing = false
    @State private var swipeController = OnboardingSwipeController()
    @State private var hasConfiguredWindowChrome = false
    @State private var isIntroVisible = true
    @State private var introRevealPhase = OnboardingIntroRevealPhase.icon
    @State private var isFlowPrepared = false
    @State private var isDismissingIntro = false
    @AccessibilityFocusState private var isProviderStepAccessibilityFocused: Bool

    private let swipeThreshold: CGFloat = 42

    public init(hasCompletedOnboarding: Binding<Bool>, isRestart: Bool = false) {
        self._hasCompletedOnboarding = hasCompletedOnboarding
        self.isRestart = isRestart
    }

    public var body: some View {
        let validation = currentStepValidation

        ZStack {
            if isFlowPrepared {
                ZStack {
                    Color(NSColor.windowBackgroundColor)
                        .ignoresSafeArea()

                    OnboardingBottomGradient(progress: gradientProgress)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)

                    VStack(spacing: 0) {
                        // Pinned with a fixed top padding so it doesn't shift between steps.
                        // A soft top scrim (instead of a hard opaque strip) prevents scrolled
                        // step content from bleeding behind it while blending seamlessly into
                        // the unified background gradient so there is no visible color seam.
                        OnboardingProgressBar(currentStep: currentStep)
                            .padding(.top, 54)
                            .padding(.bottom, 24)
                            .padding(.horizontal, 48)
                            .background(
                                // Keep the title/progress rail legible without
                                // stamping a separate color band across the
                                // window.
                                LinearGradient(
                                    stops: [
                                        .init(color: Color(NSColor.windowBackgroundColor).opacity(0.24), location: 0.00),
                                        .init(color: Color(NSColor.windowBackgroundColor).opacity(0.14), location: 0.38),
                                        .init(color: Color(NSColor.windowBackgroundColor).opacity(0.04), location: 0.74),
                                        .init(color: Color.clear, location: 1.00)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: 220)
                                .offset(y: -34)
                            )
                            .opacity(hasConfiguredWindowChrome ? 1 : 0)
                            .animation(nil, value: hasConfiguredWindowChrome)

                        // Main content
                        if currentStep == .completion {
                            stepContent
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            // Step roots use spacers and flexible height. Give
                            // them this VStack's finite remaining allocation;
                            // measuring them in an unbounded vertical scroll
                            // proposal creates a recursive ideal-height cycle.
                            stepContent
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: 0,
                                    maxHeight: .infinity
                                )
                                .clipped()
                        }

                        if currentStep != .completion {
                            navigationControls(validation: validation)
                                .padding(.horizontal, 40)
                                .padding(.top, 12)
                                .padding(.bottom, 12)
                                .frame(height: 92, alignment: .top)
                                .frame(maxWidth: .infinity)
                                .background(
                                    OnboardingNavigationBackdrop()
                                        .allowsHitTesting(false)
                                )
                                .transition(.opacity)
                        }
                    }
                    .ignoresSafeArea(.container, edges: .top)
                    .transition(.opacity)
                }
                .opacity(isIntroVisible ? 0 : 1)
                .allowsHitTesting(!isIntroVisible && !isDismissingIntro)
                .accessibilityHidden(isIntroVisible)
            }

            if isIntroVisible {
                OnboardingIntroView(
                    onRevealPhaseChanged: { phase in
                        introRevealPhase = phase
                    },
                    onGetStarted: dismissIntro
                )
                .transition(.opacity)
                .allowsHitTesting(!isDismissingIntro)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Pin the ideal size so taller steps never reframe the window. The
        // navigation footer is bottom-pinned, so any content-driven reframe
        // moves the Continue/Next button on screen between steps.
        .frame(
            minWidth: SortyDesignSystem.Sizing.windowOnboardingWidth,
            idealWidth: SortyDesignSystem.Sizing.windowOnboardingWidth,
            maxWidth: .infinity,
            minHeight: SortyDesignSystem.Sizing.windowOnboardingHeight,
            idealHeight: SortyDesignSystem.Sizing.windowOnboardingHeight,
            maxHeight: .infinity
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Onboarding")
        .accessibilityIdentifier("OnboardingView")
        .confirmationDialog(
            "Set up an AI provider now?",
            isPresented: $isShowingProviderSkipConfirmation,
            titleVisibility: .visible
        ) {
            Button("Go Back", role: .cancel) {}
            Button("Continue without AI") {
                advancePastProviderSetup()
            }
        } message: {
            Text("Sorty needs a working AI provider to organize files. We strongly recommend setting one up now, but you can finish onboarding and configure it later in Settings.")
        }
        .onChange(of: currentStep) { _, _ in
            advanceValidationMessage = nil
        }
        .onChange(of: validation.canAdvance) { _, canAdvance in
            if canAdvance {
                advanceValidationMessage = nil
            }
        }
        .background(
            ZStack {
                OnboardingWindowTitleConfigurator(preserveWindowPosition: isRestart) {
                    hasConfiguredWindowChrome = true
                }
                OnboardingScreenBackdropBlurPresenter(
                    isVisible: isIntroVisible
                        && introRevealPhase.rawValue >= OnboardingIntroRevealPhase.window.rawValue
                )
            }
            .frame(width: 0, height: 0)
        )
        .overlay(alignment: .topLeading) {
            OnboardingScreenEdgeGlowPresenter(
                isVisible: isIntroVisible
                    && introRevealPhase.rawValue >= OnboardingIntroRevealPhase.screenGlow.rawValue
            )
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear {
            installSwipeMonitorIfNeeded()
        }
        .task(id: isIntroVisible) {
            // Keep completion-audio construction out of the intro's final
            // reveal frames. It is still prepared long before completion once
            // the provider step has settled.
            guard !isIntroVisible else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await OnboardingCompletionAudio.prewarm()
        }
        .onDisappear {
            swipeController.introTransitionTask?.cancel()
            removeSwipeMonitor()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .provider:
            ProviderSelectionStepView { status in
                if providerSetupStatus != status {
                    providerSetupStatus = status
                }
            }
                .accessibilityFocused($isProviderStepAccessibilityFocused)
                .transition(TransitionStyles.slideFromRight)
        case .permissions:
            PermissionsStepView(hasRequiredPermissions: $hasFilesAndFoldersPermission)
                .transition(TransitionStyles.slideFromRight)
        case .workflow:
            WorkflowSelectionStepView()
                .transition(TransitionStyles.slideFromRight)
        case .completion:
            OnboardingCompletionDestination(
                hasCompletedOnboarding: $hasCompletedOnboarding,
                providerSetupStatus: providerSetupStatus
            )
            .transition(TransitionStyles.scaleAndFade)
        }
    }

    private func navigationControls(
        validation: OnboardingStepValidationResult
    ) -> some View {
        let sideControlWidth: CGFloat = 180
        let backHidden = (currentStep == OnboardingStep.allCases.first || currentStep == .completion)

        return ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 16) {
                    // Back button - kept in layout on all steps to prevent layout shift.
                    Button {
                        navigateToPreviousStep()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Back")
                        }
                        .frame(minWidth: 80)
                    }
                    .buttonStyle(.sortySecondary)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .accessibilityIdentifier("OnboardingBackButton")
                    .opacity(backHidden ? 0 : 1)
                    .disabled(backHidden)
                    .allowsHitTesting(!backHidden)
                    .frame(width: sideControlWidth, alignment: .leading)

                    Spacer(minLength: 0)

                    // Next button
                    Group {
                        if currentStep != .completion {
                            Button {
                                navigateForwardFromControls()
                            } label: {
                                HStack(spacing: 6) {
                                    if isAdvancing {
                                        BouncingSpinner(size: 10, color: .white)
                                    }
                                    Text(currentStep == .permissions ? "Continue" : "Next")
                                        .numericTextTransition(animationValue: currentStep)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                            }
                            .buttonStyle(.sortyPrimary)
                            .keyboardShortcut(.rightArrow, modifiers: [])
                            .disabled(!canUseAdvanceButton(validation: validation) || isAdvancing)
                            .opacity(
                                canUseAdvanceButton(validation: validation) && !isAdvancing ? 1.0 : 0.5
                            )
                            .accessibilityIdentifier("OnboardingAdvanceButton")
                        }
                    }
                    .frame(width: sideControlWidth, alignment: .trailing)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
            .onHover { isHovering in
                swipeController.isHoveringStepIndicator = isHovering
                if !isHovering {
                    resetSwipeTracking()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            }

            if let advanceValidationMessage, !advanceValidationMessage.isEmpty,
                currentStep != .provider
            {
                Text(advanceValidationMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("OnboardingValidationMessage")
                    .padding(.bottom, 2)
            }
        }
    }

    /// Normalized progress (0...1) through the active onboarding steps. Drives
    /// the background gradient so it climbs higher as the user advances.
    private var gradientProgress: Double {
        let active = OnboardingStep.allCases
        guard active.count > 1, let index = active.firstIndex(of: currentStep) else {
            return 0
        }
        return Double(index) / Double(active.count - 1)
    }

    private var currentStepValidation: OnboardingStepValidationResult {
        currentStep.synchronousValidation(
            in: OnboardingStepValidationContext(
                providerSetupStatus: providerSetupStatus,
                hasRequiredPermissions: hasFilesAndFoldersPermission
            )
        )
    }

    private func dismissIntro() {
        guard isIntroVisible, !isDismissingIntro else { return }
        HapticFeedbackManager.shared.selection()

        isDismissingIntro = true
        swipeController.introTransitionTask?.cancel()

        var preparation = Transaction(animation: nil)
        preparation.disablesAnimations = true
        withTransaction(preparation) {
            isFlowPrepared = true
        }

        swipeController.introTransitionTask = Task { @MainActor in
            // Resolve the provider step's finite layout before animating only
            // presentation properties. This keeps layout insertion out of the
            // AttributeGraph animation transaction.
            await Task.yield()
            guard !Task.isCancelled else { return }

            if reduceMotion {
                withTransaction(preparation) {
                    isIntroVisible = false
                    isDismissingIntro = false
                }
                await Task.yield()
                guard !Task.isCancelled else { return }
                isProviderStepAccessibilityFocused = true
                return
            }

            withAnimation(.easeInOut(duration: 0.55)) {
                isIntroVisible = false
            }

            await Task.yield()
            guard !Task.isCancelled else { return }
            isProviderStepAccessibilityFocused = true

            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            withTransaction(preparation) {
                isDismissingIntro = false
            }
        }
    }

    private func navigateToPreviousStep() {
        guard currentStep != OnboardingStep.allCases.first && currentStep != .completion else { return }
        HapticFeedbackManager.shared.selection()
        withAnimation(reduceMotion ? nil : .pageTransition) {
            currentStep = currentStep.previous
        }
    }

    private func navigateForwardFromControls() {
        guard currentStep != .completion else { return }

        switch currentStep {
        case .provider, .permissions, .workflow:
            attemptAdvance()
        case .completion:
            break
        }
    }

    private func attemptAdvance() {
        guard !isAdvancing else { return }

        if currentStep == .provider, !providerSetupStatus.isReady {
            isShowingProviderSkipConfirmation = true
            return
        }

        let validationContext = OnboardingStepValidationContext(
            providerSetupStatus: providerSetupStatus,
            hasRequiredPermissions: hasFilesAndFoldersPermission
        )

        Task { @MainActor in
            isAdvancing = true
            let validation = await currentStep.validateAdvance(in: validationContext)
            isAdvancing = false

            guard validation.canAdvance else {
                advanceValidationMessage = validation.message
                HapticFeedbackManager.shared.error()
                return
            }

            advanceValidationMessage = nil
            HapticFeedbackManager.shared.selection()
            withAnimation(reduceMotion ? nil : .pageTransition) {
                currentStep = currentStep.next
            }
        }
    }

    private func canUseAdvanceButton(
        validation: OnboardingStepValidationResult
    ) -> Bool {
        currentStep == .provider || validation.canAdvance
    }

    private func advancePastProviderSetup() {
        advanceValidationMessage = nil
        HapticFeedbackManager.shared.selection()
        withAnimation(reduceMotion ? nil : .pageTransition) {
            currentStep = currentStep.next
        }
    }

    private func installSwipeMonitorIfNeeded() {
        guard swipeController.monitor == nil else { return }

        swipeController.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handleSwipeEvent(event)
        }
    }

    private func removeSwipeMonitor() {
        if let monitor = swipeController.monitor {
            NSEvent.removeMonitor(monitor)
            swipeController.monitor = nil
        }
        resetSwipeTracking()
        swipeController.isHoveringStepIndicator = false
    }

    private func resetSwipeTracking() {
        swipeController.accumulatedTranslation = 0
        swipeController.hasTriggeredGesture = false
    }

    private func handleSwipeEvent(_ event: NSEvent) -> NSEvent? {
        guard swipeController.isHoveringStepIndicator else { return event }

        let deltaX =
            event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 8
        let deltaY =
            event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8

        guard abs(deltaX) > abs(deltaY) else { return event }

        if event.phase == .began {
            resetSwipeTracking()
        }

        if event.momentumPhase != [] {
            if event.momentumPhase == .ended {
                resetSwipeTracking()
            }
            return nil
        }

        guard !swipeController.hasTriggeredGesture else {
            if event.phase == .ended || event.phase == .cancelled {
                resetSwipeTracking()
            }
            return nil
        }

        let physicalDeltaX = event.isDirectionInvertedFromDevice ? deltaX : -deltaX
        swipeController.accumulatedTranslation += physicalDeltaX

        if swipeController.accumulatedTranslation <= -swipeThreshold {
            swipeController.hasTriggeredGesture = true
            navigateForwardFromControls()
            return nil
        }

        if swipeController.accumulatedTranslation >= swipeThreshold {
            swipeController.hasTriggeredGesture = true
            navigateToPreviousStep()
            return nil
        }

        if event.phase == .ended || event.phase == .cancelled {
            resetSwipeTracking()
        }

        return nil
    }
}

/// Holds event-monitor bookkeeping that has no visual representation. Keeping
/// gesture deltas outside SwiftUI state prevents every trackpad event from
/// invalidating the onboarding root and its active step hierarchy.
@MainActor
private final class OnboardingSwipeController {
    var monitor: Any?
    var introTransitionTask: Task<Void, Never>?
    var isHoveringStepIndicator = false
    var accumulatedTranslation: CGFloat = 0
    var hasTriggeredGesture = false
}

/// Keeps AppState publications scoped to the completion destination instead
/// of invalidating the entire onboarding root throughout every step.
private struct OnboardingCompletionDestination: View {
    @SortyHotReload private var hotReload
    @Binding var hasCompletedOnboarding: Bool
    @EnvironmentObject private var appState: AppState
    let providerSetupStatus: ProviderSetupStatus

    var body: some View {
        CompletionStepView(providerSetupStatus: providerSetupStatus) {
            HapticFeedbackManager.shared.success()
            // The user just saw a long completion reveal. Skip the extra
            // ReadyToOrganizeView entrance cascade on the first main screen.
            appState.hasPresentedReadyToOrganize = true
            hasCompletedOnboarding = true
        }
    }
}











// MARK: - Preview

#Preview {
    let codexAuthManager = CodexCLIAuthManager()

    OnboardingView(hasCompletedOnboarding: .constant(false))
        .environmentObject(SettingsViewModel())
        .environmentObject(PersonaManager())
        .environmentObject(FolderOrganizer())
        .environmentObject(AppState())
        .environmentObject(codexAuthManager)
}
