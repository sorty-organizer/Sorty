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

private let onboardingPerformanceLog = OSLog(
    subsystem: "com.sorty.app",
    category: .pointsOfInterest
)

// MARK: - Main Onboarding View

private enum OnboardingIntroRevealPhase: Int {
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
        self._introRevealPhase = State(initialValue: isRestart ? .files : .icon)
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
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    isRestart: isRestart,
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
                    isVisible: introRevealPhase.rawValue
                        >= OnboardingIntroRevealPhase.window.rawValue
                )
            }
            .frame(width: 0, height: 0)
        )
        .overlay(alignment: .topLeading) {
            OnboardingScreenEdgeGlowPresenter(
                isVisible: introRevealPhase.rawValue
                    >= OnboardingIntroRevealPhase.screenGlow.rawValue
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
                    .buttonStyle(.bordered)
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
                            .onboardingBeamBorder(
                                active: canUseAdvanceButton(validation: validation) && !isAdvancing
                            )
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

// MARK: - Onboarding Step Enum

public struct OnboardingStepValidationResult: Equatable, Sendable {
    public let canAdvance: Bool
    public let message: String?

    public init(canAdvance: Bool, message: String? = nil) {
        self.canAdvance = canAdvance
        self.message = message
    }

    public static let valid = OnboardingStepValidationResult(canAdvance: true)

    public static func blocked(_ message: String) -> OnboardingStepValidationResult {
        OnboardingStepValidationResult(canAdvance: false, message: message)
    }
}

public struct OnboardingStepValidationContext: Equatable, Sendable {
    public let providerSetupStatus: ProviderSetupStatus
    public let hasRequiredPermissions: Bool

    public init(
        providerSetupStatus: ProviderSetupStatus,
        hasRequiredPermissions: Bool
    ) {
        self.providerSetupStatus = providerSetupStatus
        self.hasRequiredPermissions = hasRequiredPermissions
    }
}

enum OnboardingStep: Int, CaseIterable {
    case provider = 0
    case permissions = 1
    case workflow = 2
    case completion = 3

    var title: String {
        switch self {
        case .provider: return "AI Provider"
        case .permissions: return "Permissions"
        case .workflow: return "Workflow"
        case .completion: return "Ready!"
        }
    }

    @MainActor
    var next: OnboardingStep {
        let active = OnboardingStep.allCases
        guard let currentIndex = active.firstIndex(of: self) else { return self }
        let nextIndex = min(currentIndex + 1, active.count - 1)
        return active[nextIndex]
    }

    @MainActor
    var previous: OnboardingStep {
        let active = OnboardingStep.allCases
        guard let currentIndex = active.firstIndex(of: self) else { return self }
        let prevIndex = max(currentIndex - 1, 0)
        return active[prevIndex]
    }
}

extension OnboardingStep {
    func synchronousValidation(in context: OnboardingStepValidationContext)
        -> OnboardingStepValidationResult
    {
        switch self {
        case .provider:
            if context.providerSetupStatus.isReady {
                return .valid
            }
            return .blocked(context.providerSetupStatus.message)
        case .permissions:
            if context.hasRequiredPermissions {
                return .valid
            }
            return .blocked("Grant Files & Folders access before continuing.")
        case .workflow, .completion:
            return .valid
        }
    }

    func validateAdvance(in context: OnboardingStepValidationContext) async
        -> OnboardingStepValidationResult
    {
        synchronousValidation(in: context)
    }
}

// MARK: - Onboarding Title Bar

@MainActor
private final class OnboardingIntroTaskController {
    var iconPreparationTask: Task<Void, Never>?
    var revealGeneration = 0
}

private struct OnboardingIntroView: View {
    @SortyHotReload private var hotReload
    let isRestart: Bool
    let onRevealPhaseChanged: (OnboardingIntroRevealPhase) -> Void
    let onGetStarted: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var iconScale: CGFloat = 0.86
    @State private var iconOpacity: Double = 0
    @State private var glowVisible = false
    @State private var chromeRevealed = false
    @State private var textOpacity: Double = 0
    @State private var textOffset: CGFloat = 14
    @State private var filesAppeared = false
    @State private var fileIcons: [String: NSImage] = [:]
    @State private var taskController = OnboardingIntroTaskController()
    @StateObject private var audio = OnboardingAudioManager()

    init(
        isRestart: Bool,
        onRevealPhaseChanged: @escaping (OnboardingIntroRevealPhase) -> Void,
        onGetStarted: @escaping () -> Void
    ) {
        self.isRestart = isRestart
        self.onRevealPhaseChanged = onRevealPhaseChanged
        self.onGetStarted = onGetStarted
        _iconScale = State(initialValue: isRestart ? 1 : 0.86)
        _iconOpacity = State(initialValue: isRestart ? 1 : 0)
        _glowVisible = State(initialValue: isRestart)
        _chromeRevealed = State(initialValue: isRestart)
        _textOpacity = State(initialValue: isRestart ? 1 : 0)
        _textOffset = State(initialValue: isRestart ? 0 : 14)
    }

    var body: some View {
        ZStack {
            // Phase 1 of the reveal shows only the icon and its rose glow on a
            // fully transparent window — no backdrop, no "app window" feel.
            // The gradient fades in later together with the title and button.
            OnboardingBottomGradient()
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .opacity(chromeRevealed ? 0.92 : 0)

            OnboardingIntroContentLayer(
                icons: fileIcons,
                filesVisible: filesAppeared,
                iconScale: iconScale,
                iconOpacity: iconOpacity,
                glowVisible: glowVisible,
                textOpacity: textOpacity,
                textOffset: textOffset
            ) {
                HapticFeedbackManager.shared.success()
                taskController.revealGeneration += 1
                taskController.iconPreparationTask?.cancel()
                audio.stopAll()
                onGetStarted()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to Sorty")
        .onAppear {
            runIntroReveal()
        }
        .onDisappear {
            taskController.revealGeneration += 1
            taskController.iconPreparationTask?.cancel()
            audio.stopAll()
        }
    }

    /// Orchestrates the first-screen reveal in three deliberate phases:
    /// 1. Only the icon and its rose glow, floating on a transparent window.
    /// 2. After the icon has had the stage to itself, the gradient backdrop,
    ///    title, and button fade in together.
    /// 3. The orbiting file chips drift in last.
    /// The audio engine is deferred so its AVAudioEngine + AVAudioSourceNode
    /// setup does not block the first paint of the icon, and the
    /// `revealGeneration` counter cancels any in-flight reveal if the view
    /// disappears before the sequence finishes.
    private func runIntroReveal() {
        taskController.revealGeneration += 1
        let generation = taskController.revealGeneration
        taskController.iconPreparationTask?.cancel()

        taskController.iconPreparationTask = Task { @MainActor in
            // Let the window commit its empty first frame before NSWorkspace
            // resolves cold file icons. Core Graphics rasterization runs on the
            // concurrent pool; only immutable NSImages return to the view.
            await Task.yield()
            let icons = await measuredIntroIcons()
            guard generation == taskController.revealGeneration, !Task.isCancelled else { return }
            fileIcons = icons

            if isRestart {
                filesAppeared = true
                await audio.prepareBackgroundMelody()
                guard generation == taskController.revealGeneration, !Task.isCancelled else { return }
                audio.startBackgroundMelody()
                return
            }

            if reduceMotion {
                iconScale = 1
                iconOpacity = 1
                glowVisible = true
                chromeRevealed = true
                textOpacity = 1
                textOffset = 0
                filesAppeared = true
                onRevealPhaseChanged(.files)
                audio.startBackgroundMelody()
                return
            }

            onRevealPhaseChanged(.icon)
            // Construct and prepare the player before the icon's first visible
            // frame, then schedule its cue on the audio clock so no main-actor
            // audio work lands during the icon spring.
            os_signpost(.begin, log: onboardingPerformanceLog, name: "Onboarding audio preparation")
            await audio.prepareBackgroundMelody()
            os_signpost(.end, log: onboardingPerformanceLog, name: "Onboarding audio preparation")
            audio.startBackgroundMelody(after: 0.45)
            await Task.yield()
            guard generation == taskController.revealGeneration, !Task.isCancelled else { return }
            beginAnimatedReveal(generation: generation)
        }
    }

    private func measuredIntroIcons() async -> [String: NSImage] {
        os_signpost(.begin, log: onboardingPerformanceLog, name: "Onboarding icon rasterization")
        defer {
            os_signpost(.end, log: onboardingPerformanceLog, name: "Onboarding icon rasterization")
        }
        return await OnboardingFileIconProvider.icons(for: OnboardingOrbitFile.files)
    }

    private func beginAnimatedReveal(generation: Int) {
        // Phase 1 — the icon materializes with a clean fade + settle (no
        // blur-in) while the glow blooms around it.
        withAnimation(.easeOut(duration: 1.0)) {
            iconOpacity = 1
        }
        withAnimation(.spring(response: 0.9, dampingFraction: 0.88)) {
            iconScale = 1
        }
        glowVisible = true

        Task { @MainActor in
            // Let the icon establish the first frame before bringing the
            // screen-edge glow forward in its own fade.
            try? await Task.sleep(for: .milliseconds(600))
            guard generation == taskController.revealGeneration else { return }
            onRevealPhaseChanged(.screenGlow)

            // Phase 2 — backdrop, title, and button.
            try? await Task.sleep(for: .milliseconds(1100))
            guard generation == taskController.revealGeneration else { return }
            onRevealPhaseChanged(.window)
            withAnimation(.easeInOut(duration: 0.9)) {
                chromeRevealed = true
            }
            withAnimation(.easeOut(duration: 0.7).delay(0.15)) {
                textOpacity = 1
                textOffset = 0
            }

            // Phase 3 — file chips drift in once everything has settled.
            try? await Task.sleep(for: .milliseconds(650))
            guard generation == taskController.revealGeneration else { return }
            filesAppeared = true
            onRevealPhaseChanged(.files)
        }
    }

}

/// Keeps pointer-driven intro state isolated from the reveal and audio state
/// owned by the surrounding onboarding step.
private struct OnboardingIntroContentLayer: View {
    @SortyHotReload private var hotReload
    let icons: [String: NSImage]
    let filesVisible: Bool
    let iconScale: CGFloat
    let iconOpacity: Double
    let glowVisible: Bool
    let textOpacity: Double
    let textOffset: CGFloat
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var introSize: CGSize = .zero
    @State private var buttonCenter: CGPoint = .zero
    @State private var isHoveringButton = false
    @State private var hoverExitTask: Task<Void, Never>?

    private static let coordinateSpace = "OnboardingIntroContentLayer"

    var body: some View {
        ZStack {
            OnboardingOrbitField(
                icons: icons,
                filesVisible: filesVisible,
                isCollapsed: isHoveringButton,
                collapseOrigin: CGSize(
                    width: buttonCenter.x - introSize.width / 2,
                    height: buttonCenter.y - introSize.height / 2
                ),
                reduceMotion: reduceMotion,
                isActive: controlActiveState != .inactive
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            VStack(spacing: 26) {
                VStack(spacing: 20) {
                    ZStack {
                        RetainedIntroGlow(
                            isVisible: glowVisible,
                            reduceMotion: reduceMotion,
                            isActive: controlActiveState != .inactive
                        )
                        .frame(width: 220, height: 220)
                        .accessibilityHidden(true)

                        SortyEnergyScanIcon(
                            image: NSApp.applicationIconImage,
                            size: 156,
                            cornerRadius: 34
                        )
                        .shadow(
                            color: SortyDesignSystem.Colors.resolvedAccent.opacity(0.22),
                            radius: 34
                        )
                        .shadow(color: .black.opacity(0.28), radius: 26, x: 0, y: 16)
                        .accessibilityHidden(true)
                    }
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)

                    Text("Welcome to Sorty")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.88))
                        .opacity(textOpacity)
                        .offset(y: textOffset)
                }

                Button(action: action) {
                    HStack(spacing: 8) {
                        Text("Get Started")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .buttonStyle(
                    .sortyPrimary(
                        size: .large,
                        isGlassInteractive: false
                    )
                )
                .onboardingBeamBorder()
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("OnboardingAdvanceButton")
                .background {
                    Color.clear
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named(Self.coordinateSpace))
                        } action: { frame in
                            let center = CGPoint(x: frame.midX, y: frame.midY)
                            if buttonCenter != center {
                                buttonCenter = center
                            }
                        }
                }
                .onHover { hovering in
                    hoverExitTask?.cancel()

                    if hovering {
                        hoverExitTask = nil
                        isHoveringButton = true
                    } else {
                        hoverExitTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(90))
                            guard !Task.isCancelled else { return }
                            isHoveringButton = false
                        }
                    }
                }
                .opacity(textOpacity)
                .offset(y: textOffset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: Self.coordinateSpace)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            if introSize != size {
                introSize = size
            }
        }
        .onDisappear {
            hoverExitTask?.cancel()
            hoverExitTask = nil
        }
    }
}

private struct RetainedIntroGlow: NSViewRepresentable {
    @SortyHotReload private var hotReload
    let isVisible: Bool
    let reduceMotion: Bool
    let isActive: Bool

    func makeNSView(context: Context) -> RetainedIntroGlowView {
        RetainedIntroGlowView()
    }

    func updateNSView(_ nsView: RetainedIntroGlowView, context: Context) {
        nsView.update(
            isVisible: isVisible,
            reduceMotion: reduceMotion,
            isActive: isActive
        )
    }
}

/// Preserves the intro's 28-to-38 point Gaussian bloom on one retained layer.
/// SwiftUI no longer rerenders the blurred 220-point shape during the reveal.
@MainActor
private final class RetainedIntroGlowView: NSView {
    private let glowLayer = CALayer()
    private let glowShapeLayer = CALayer()
    private let blurFilter = CIFilter.gaussianBlur()
    private var hasStartedReveal = false
    private var isPaused = false
    private var lastIsVisible: Bool?
    private var lastReduceMotion: Bool?
    private var lastIsActive: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)

        blurFilter.name = "introGlowBlur"
        blurFilter.radius = 28
        glowShapeLayer.backgroundColor = NSColor(SortyDesignSystem.Colors.resolvedAccent)
            .withAlphaComponent(0.30)
            .cgColor
        glowShapeLayer.cornerRadius = 44
        glowLayer.opacity = 0
        glowLayer.filters = [blurFilter]
        glowLayer.addSublayer(glowShapeLayer)
        layer?.addSublayer(glowLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let blurOutset: CGFloat = 60
        glowLayer.frame = bounds.insetBy(dx: -blurOutset, dy: -blurOutset)
        glowShapeLayer.frame = CGRect(
            x: blurOutset,
            y: blurOutset,
            width: bounds.width,
            height: bounds.height
        )
        CATransaction.commit()
    }

    func update(isVisible: Bool, reduceMotion: Bool, isActive: Bool) {
        guard lastIsVisible != isVisible
                || lastReduceMotion != reduceMotion
                || lastIsActive != isActive else { return }
        lastIsVisible = isVisible
        lastReduceMotion = reduceMotion
        lastIsActive = isActive

        glowShapeLayer.backgroundColor = NSColor(SortyDesignSystem.Colors.resolvedAccent)
            .withAlphaComponent(0.30)
            .cgColor

        if reduceMotion {
            finishImmediately(isVisible: isVisible)
        } else if isVisible, !hasStartedReveal {
            startReveal()
        } else if !isVisible {
            resetReveal()
        }

        if isActive {
            resumeIfNeeded()
        } else {
            pauseIfNeeded()
        }
    }

    private func startReveal() {
        hasStartedReveal = true
        let now = glowLayer.convertTime(CACurrentMediaTime(), from: nil)

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.beginTime = now + 0.2
        opacity.duration = 1.2
        opacity.fillMode = .backwards
        opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)
        glowLayer.add(opacity, forKey: "introGlowOpacity")

        let blur = CABasicAnimation(keyPath: "filters.introGlowBlur.inputRadius")
        blur.fromValue = 28
        blur.toValue = 38
        blur.beginTime = now + 0.4
        blur.duration = 1.5
        blur.fillMode = .backwards
        blur.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(blur, forKey: "introGlowRadius")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.opacity = 1
        blurFilter.radius = 38
        CATransaction.commit()
    }

    private func finishImmediately(isVisible: Bool) {
        hasStartedReveal = isVisible
        glowLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.opacity = isVisible ? 1 : 0
        blurFilter.radius = 38
        CATransaction.commit()
    }

    private func resetReveal() {
        hasStartedReveal = false
        glowLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.opacity = 0
        blurFilter.radius = 28
        CATransaction.commit()
    }

    private func pauseIfNeeded() {
        guard !isPaused, let layer else { return }
        let pausedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = pausedTime
        isPaused = true
    }

    private func resumeIfNeeded() {
        guard isPaused, let layer else { return }
        let pausedTime = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        isPaused = false
    }
}

struct SortyEnergyScanIcon: View {
    @SortyHotReload private var hotReload
    let image: NSImage
    let size: CGFloat
    let cornerRadius: CGFloat
    var startDelay: TimeInterval = 0.8
    var sweepDuration: TimeInterval = 2.8
    var repeats = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        RetainedEnergyScanIcon(
            image: image,
            size: size,
            cornerRadius: cornerRadius,
            startDelay: startDelay,
            sweepDuration: sweepDuration,
            repeats: repeats,
            reduceMotion: reduceMotion,
            isActive: controlActiveState != .inactive
        )
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct RetainedEnergyScanIcon: NSViewRepresentable {
    @SortyHotReload private var hotReload
    let image: NSImage
    let size: CGFloat
    let cornerRadius: CGFloat
    let startDelay: TimeInterval
    let sweepDuration: TimeInterval
    let repeats: Bool
    let reduceMotion: Bool
    let isActive: Bool

    func makeNSView(context: Context) -> RetainedEnergyScanIconView {
        RetainedEnergyScanIconView()
    }

    func updateNSView(_ nsView: RetainedEnergyScanIconView, context: Context) {
        nsView.update(
            image: image,
            size: size,
            cornerRadius: cornerRadius,
            delay: startDelay,
            duration: sweepDuration,
            repeats: repeats,
            reduceMotion: reduceMotion,
            isActive: isActive
        )
    }
}

/// Renders the icon once and moves retained gradient layers for the scan.
/// This replaces a 60 Hz SwiftUI rebuild of the image, mask, blur, and blend.
@MainActor
private final class RetainedEnergyScanIconView: NSView, @preconcurrency CAAnimationDelegate {
    private let imageLayer = CALayer()
    private let scanContainer = CALayer()
    private let imageMask = CALayer()
    private let movingBand = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let scanLine = CAShapeLayer()
    private var configuredImage: NSImage?
    private var configuredSize: CGFloat = 0
    private var isAnimating = false
    private var isPaused = false
    private var hasCompletedSingleSweep = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)

        imageLayer.contentsGravity = .resizeAspect
        imageMask.contentsGravity = .resizeAspect
        scanContainer.mask = imageMask
        scanContainer.compositingFilter = "plusL"
        movingBand.opacity = 0
        gradientLayer.colors = [
            NSColor.clear.cgColor,
            NSColor(srgbRed: 0.84, green: 0.18, blue: 1, alpha: 0.36).cgColor,
            NSColor.white.withAlphaComponent(0.90).cgColor,
            NSColor(srgbRed: 1, green: 0.16, blue: 0.42, alpha: 0.82).cgColor,
            NSColor(srgbRed: 1, green: 0.48, blue: 0.14, alpha: 0.32).cgColor,
            NSColor.clear.cgColor
        ]
        gradientLayer.locations = [0, 0.20, 0.48, 0.60, 0.78, 1]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        scanLine.fillColor = NSColor.white.withAlphaComponent(0.86).cgColor
        scanLine.opacity = 0.72
        movingBand.addSublayer(gradientLayer)
        movingBand.addSublayer(scanLine)
        scanContainer.addSublayer(movingBand)
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(scanContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let lineHeight = max(1.5, bounds.width * 0.012)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        scanContainer.frame = bounds
        imageMask.frame = scanContainer.bounds
        movingBand.bounds = CGRect(x: 0, y: 0, width: bounds.width * 1.7, height: bounds.height * 0.42)
        movingBand.position = CGPoint(x: bounds.midX, y: bounds.midY)
        movingBand.setAffineTransform(CGAffineTransform(rotationAngle: -11 * .pi / 180))
        gradientLayer.frame = movingBand.bounds
        scanLine.frame = CGRect(
            x: movingBand.bounds.midX - bounds.width * 1.45 / 2,
            y: movingBand.bounds.midY - lineHeight / 2,
            width: bounds.width * 1.45,
            height: lineHeight
        )
        scanLine.path = CGPath(
            roundedRect: scanLine.bounds,
            cornerWidth: lineHeight / 2,
            cornerHeight: lineHeight / 2,
            transform: nil
        )
        CATransaction.commit()
    }

    func update(
        image: NSImage,
        size: CGFloat,
        cornerRadius: CGFloat,
        delay: TimeInterval,
        duration: TimeInterval,
        repeats: Bool,
        reduceMotion: Bool,
        isActive: Bool
    ) {
        if configuredImage !== image || configuredSize != size {
            configuredImage = image
            configuredSize = size
            var proposedRect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            let contents = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
            imageLayer.contents = contents
            imageMask.contents = contents
            layer?.cornerRadius = cornerRadius
            needsLayout = true
        }

        if reduceMotion || hasCompletedSingleSweep {
            stopAnimating()
            return
        }

        startAnimatingIfNeeded(delay: delay, duration: duration, repeats: repeats)
        if isActive {
            resumeIfNeeded()
        } else {
            pauseIfNeeded()
        }
    }

    private func startAnimatingIfNeeded(delay: TimeInterval, duration: TimeInterval, repeats: Bool) {
        guard !isAnimating else { return }
        isAnimating = true
        let samples = (0...64).map { Double($0) / 64 }
        let eased = samples.map { $0 * $0 * (3 - 2 * $0) }

        let translation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        translation.values = eased.map { NSNumber(value: (-0.74 + $0 * 1.48) * configuredSize) }
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = samples.map { NSNumber(value: sin($0 * .pi) * 0.88) }

        let group = CAAnimationGroup()
        group.animations = [translation, opacity]
        group.duration = duration
        group.beginTime = movingBand.convertTime(CACurrentMediaTime(), from: nil) + delay
        group.fillMode = .backwards
        group.repeatCount = repeats ? .infinity : 0
        group.delegate = self
        group.setValue(!repeats, forKey: "isSingleEnergyScanSweep")
        movingBand.add(group, forKey: "energyScanSweep")
    }

    private func stopAnimating() {
        guard isAnimating || isPaused
                || movingBand.animation(forKey: "energyScanSweep") != nil else { return }
        resumeIfNeeded()
        isAnimating = false
        movingBand.removeAnimation(forKey: "energyScanSweep")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        movingBand.opacity = 0
        CATransaction.commit()
    }

    private func pauseIfNeeded() {
        guard isAnimating, !isPaused else { return }
        let pausedTime = movingBand.convertTime(CACurrentMediaTime(), from: nil)
        movingBand.speed = 0
        movingBand.timeOffset = pausedTime
        isPaused = true
    }

    private func resumeIfNeeded() {
        guard isPaused else { return }
        let pausedTime = movingBand.timeOffset
        movingBand.speed = 1
        movingBand.timeOffset = 0
        movingBand.beginTime = 0
        movingBand.beginTime = movingBand.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        isPaused = false
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag,
              anim.value(forKey: "isSingleEnergyScanSweep") as? Bool == true else { return }
        hasCompletedSingleSweep = true
        stopAnimating()
    }
}

private struct OnboardingOrbitFile: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let ext: String
    // Scattered resting position (offset from center).
    let baseX: CGFloat
    let baseY: CGFloat
    // Lazy floating motion.
    let driftPhase: Double
    let driftSpeed: Double
    let driftRadius: CGFloat
    let orbitWidth: CGFloat
    let orbitHeight: CGFloat
    // Messy presentation.
    let rotation: Double
    let scale: CGFloat
    let appearDelay: Double
    // Relative placement within the Get Started button when the pile collapses.
    let collapseX: CGFloat
    let collapseY: CGFloat

    // Stagger phases and speeds to keep neighboring files from moving together.
    static let files: [OnboardingOrbitFile] = [
        OnboardingOrbitFile(name: "Q3 Report", ext: "pdf", baseX: -292, baseY: -118, driftPhase: 0.0, driftSpeed: 0.62, driftRadius: 22, orbitWidth: 84, orbitHeight: 46, rotation: -13, scale: 1.04, appearDelay: 0.05, collapseX: -30, collapseY: -18),
        OnboardingOrbitFile(name: "Budget 2024", ext: "xlsx", baseX: 286, baseY: -104, driftPhase: 1.3, driftSpeed: 0.74, driftRadius: 20, orbitWidth: 72, orbitHeight: 52, rotation: 11, scale: 0.96, appearDelay: 0.12, collapseX: 26, collapseY: -22),
        OnboardingOrbitFile(name: "vacation", ext: "jpg", baseX: -244, baseY: 118, driftPhase: 2.1, driftSpeed: 0.68, driftRadius: 24, orbitWidth: 78, orbitHeight: 56, rotation: 8, scale: 1.1, appearDelay: 0.18, collapseX: -34, collapseY: 14),
        OnboardingOrbitFile(name: "Resume", ext: "docx", baseX: 242, baseY: 132, driftPhase: 3.4, driftSpeed: 0.58, driftRadius: 22, orbitWidth: 90, orbitHeight: 48, rotation: -9, scale: 1.0, appearDelay: 0.24, collapseX: 30, collapseY: 20),
        OnboardingOrbitFile(name: "demo", ext: "mp4", baseX: -344, baseY: 8, driftPhase: 0.7, driftSpeed: 0.80, driftRadius: 20, orbitWidth: 68, orbitHeight: 42, rotation: 6, scale: 0.92, appearDelay: 0.3, collapseX: -44, collapseY: 0),
        OnboardingOrbitFile(name: "Keynote", ext: "key", baseX: 350, baseY: 24, driftPhase: 4.2, driftSpeed: 0.66, driftRadius: 24, orbitWidth: 80, orbitHeight: 52, rotation: -7, scale: 0.94, appearDelay: 0.36, collapseX: 44, collapseY: 4),
        OnboardingOrbitFile(name: "logo", ext: "png", baseX: -142, baseY: -194, driftPhase: 5.0, driftSpeed: 0.72, driftRadius: 22, orbitWidth: 68, orbitHeight: 42, rotation: 14, scale: 0.88, appearDelay: 0.1, collapseX: -16, collapseY: -28),
        OnboardingOrbitFile(name: "playlist", ext: "mp3", baseX: 152, baseY: -198, driftPhase: 2.7, driftSpeed: 0.78, driftRadius: 22, orbitWidth: 70, orbitHeight: 48, rotation: -12, scale: 0.9, appearDelay: 0.16, collapseX: 18, collapseY: -30),
        OnboardingOrbitFile(name: "data", ext: "csv", baseX: -126, baseY: 194, driftPhase: 1.8, driftSpeed: 0.64, driftRadius: 20, orbitWidth: 64, orbitHeight: 42, rotation: -5, scale: 0.86, appearDelay: 0.22, collapseX: -14, collapseY: 26),
        OnboardingOrbitFile(name: "archive", ext: "zip", baseX: 128, baseY: 204, driftPhase: 3.9, driftSpeed: 0.76, driftRadius: 24, orbitWidth: 70, orbitHeight: 48, rotation: 10, scale: 0.9, appearDelay: 0.28, collapseX: 16, collapseY: 28)
    ]
}

private struct OnboardingSourceIcon: @unchecked Sendable {
    let fileExtension: String
    let image: CGImage
}

private struct OnboardingRasterizedIcon: @unchecked Sendable {
    let fileExtension: String
    let image: CGImage
}

/// Provides (and caches) the real macOS file-type icon for a given extension.
@MainActor
private enum OnboardingFileIconProvider {
    private static var cache: [String: NSImage] = [:]
    private static let iconPointSize = NSSize(width: 46, height: 46)

    static func icons(for files: [OnboardingOrbitFile]) async -> [String: NSImage] {
        let extensions = Set(files.map(\.ext))
        var resolved = cache.filter { extensions.contains($0.key) }
        let missing = extensions.subtracting(resolved.keys)
        let sources = missing.compactMap(sourceIcon(for:))
        let rasterized = await Task.detached(priority: .userInitiated) {
            sources.compactMap(rasterizedIcon)
        }.value
        for item in rasterized {
            let bitmap = NSBitmapImageRep(cgImage: item.image)
            bitmap.size = iconPointSize
            let image = NSImage(size: iconPointSize)
            image.addRepresentation(bitmap)
            cache[item.fileExtension] = image
            resolved[item.fileExtension] = image
        }
        return resolved
    }

    private static func sourceIcon(for ext: String) -> OnboardingSourceIcon? {
        let workspaceImage: NSImage
        if let type = UTType(filenameExtension: ext) {
            workspaceImage = NSWorkspace.shared.icon(for: type)
        } else {
            workspaceImage = NSWorkspace.shared.icon(forFileType: ext)
        }
        var proposedRect = NSRect(origin: .zero, size: iconPointSize)
        guard let image = workspaceImage.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        return OnboardingSourceIcon(fileExtension: ext, image: image)
    }

    /// `NSWorkspace` returns shared, multi-representation images whose best
    /// representation may be decoded or replaced on a later draw. Resolve one
    /// immutable Retina bitmap before the reveal so moving cards never trigger
    /// icon decoding or representation changes mid-animation.
    nonisolated private static func rasterizedIcon(
        _ source: OnboardingSourceIcon
    ) -> OnboardingRasterizedIcon? {
        let pixelsWide = 92
        let pixelsHigh = 92
        guard let context = CGContext(
            data: nil,
            width: pixelsWide,
            height: pixelsHigh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(source.image, in: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        guard let image = context.makeImage() else { return nil }
        return OnboardingRasterizedIcon(fileExtension: source.fileExtension, image: image)
    }
}

private struct OnboardingOrbitFileChip: View, @MainActor Equatable {
    @SortyHotReload private var hotReload
    let file: OnboardingOrbitFile
    let icon: NSImage
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.file.id == rhs.file.id && lhs.icon === rhs.icon
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 46, height: 46)

            Text("\(file.name).\(file.ext)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardFill)
        )
        .systemLiquidGlassBackground(
            cornerRadius: 16,
            clear: colorScheme == .light,
            interactive: false
        )
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.30 : 0.06),
            radius: colorScheme == .dark ? 16 : 10,
            x: 0,
            y: colorScheme == .dark ? 12 : 6
        )
        .accessibilityHidden(true)
    }

    private var cardFill: Color {
        colorScheme == .dark
            ? Color.primary.opacity(0.025)
            : Color(nsColor: .controlBackgroundColor).opacity(0.58)
    }
}

private struct OnboardingOrbitField: NSViewRepresentable {
    @SortyHotReload private var hotReload
    let icons: [String: NSImage]
    let filesVisible: Bool
    let isCollapsed: Bool
    let collapseOrigin: CGSize
    let reduceMotion: Bool
    let isActive: Bool

    func makeNSView(context: Context) -> OnboardingOrbitFieldView {
        OnboardingOrbitFieldView()
    }

    func updateNSView(_ nsView: OnboardingOrbitFieldView, context: Context) {
        nsView.update(
            icons: icons,
            filesVisible: filesVisible,
            isCollapsed: isCollapsed,
            collapseOrigin: collapseOrigin,
            reduceMotion: reduceMotion,
            isActive: isActive
        )
    }
}

/// Keeps every material-backed file chip mounted and updates only layer
/// compositor keyframes. The display link runs only during hover transitions.
@MainActor
private final class OnboardingOrbitFieldView: NSView {
    private static let interactionFrameRate: Float = 120
    nonisolated private static let idleSampleRate = 120.0
    private static let springResponse = 0.48
    private static let springDamping = 0.90

    private var hosts: [UUID: NSHostingView<OnboardingOrbitFileChip>] = [:]
    private var hostedIcons: [UUID: NSImage] = [:]
    private var hostSizes: [UUID: CGSize] = [:]
    private var revealWorkItems: [DispatchWorkItem] = []
    private var revealedFileIDs: Set<UUID> = []
    private var orbitDisplayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var orbitPhase: CFTimeInterval = 0
    private var idleAnimationStartedAt: CFTimeInterval?
    private var idleAnimationBasePhase: CFTimeInterval = 0
    private var collapseProgress: CGFloat = 0
    private var collapseVelocity: CGFloat = 0
    private var collapseTarget: CGFloat = 0
    private var collapseOrigin: CGSize = .zero
    private var filesVisible = false
    private var reduceMotion = false
    private var isActive = true
    private var configuredIcons: [String: NSImage] = [:]
    private struct IdleSamples: Sendable {
        let fileID: UUID
        let positions: [CGPoint]
        let rotations: [Double]
    }

    private var animationBounds: CGRect = .zero
    private var idlePreparationTask: Task<Void, Never>?
    private var idlePaths: [UUID: CGPath] = [:]
    private var positionAnimations: [UUID: CAKeyframeAnimation] = [:]
    private var rotationAnimations: [UUID: CAKeyframeAnimation] = [:]

    override var isFlipped: Bool { true }

    /// The orbit spans the full intro window but is entirely decorative. Keep
    /// AppKit from traversing its material-backed hosting views for every mouse
    /// event; SwiftUI's `allowsHitTesting(false)` does not prevent that native
    /// subtree walk inside an `NSViewRepresentable`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
        installHosts(icons: [:])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            prepareIdleAnimationsIfNeeded()
            updateHostRasterizationScale()
            installDisplayLinkIfNeeded()
        } else {
            idlePreparationTask?.cancel()
            idlePreparationTask = nil
            stopIdleAnimations(preservingPhase: false)
            revealWorkItems.forEach { $0.cancel() }
            revealWorkItems.removeAll()
            orbitDisplayLink?.invalidate()
            orbitDisplayLink = nil
            lastTimestamp = nil
        }
    }

    override func layout() {
        super.layout()
        if idleAnimationStartedAt != nil, animationBounds != bounds {
            stopIdleAnimations(preservingPhase: true)
            updateMotionState()
        } else if idleAnimationStartedAt == nil {
            renderFrame()
        }
    }

    func update(
        icons: [String: NSImage],
        filesVisible: Bool,
        isCollapsed: Bool,
        collapseOrigin: CGSize,
        reduceMotion: Bool,
        isActive: Bool
    ) {
        let iconsChanged = !iconsMatchConfiguredImages(icons)
        let stateChanged = self.filesVisible != filesVisible
            || collapseTarget != (isCollapsed ? 1 : 0)
            || self.collapseOrigin != collapseOrigin
            || self.reduceMotion != reduceMotion
            || self.isActive != isActive

        guard iconsChanged || stateChanged else { return }

        if iconsChanged {
            installHosts(icons: icons)
            updateHostedIcons(icons)
            configuredIcons = icons
        }

        if self.filesVisible != filesVisible {
            self.filesVisible = filesVisible
            updateReveal(visible: filesVisible)
        }

        if collapseTarget != (isCollapsed ? 1 : 0), idleAnimationStartedAt != nil {
            stopIdleAnimations(preservingPhase: true)
        }

        self.collapseOrigin = collapseOrigin
        self.reduceMotion = reduceMotion
        self.isActive = isActive
        collapseTarget = isCollapsed ? 1 : 0

        if reduceMotion {
            collapseProgress = collapseTarget
            collapseVelocity = 0
        }

        updateMotionState()
        if idleAnimationStartedAt == nil {
            renderFrame()
        }
    }

    private func iconsMatchConfiguredImages(_ icons: [String: NSImage]) -> Bool {
        guard icons.count == configuredIcons.count else { return false }
        return icons.allSatisfy { key, image in
            configuredIcons[key] === image
        }
    }

    private func installHosts(icons: [String: NSImage]) {
        for file in OnboardingOrbitFile.files where hosts[file.id] == nil {
            guard let icon = icons[file.ext] else { continue }
            let host = NSHostingView(rootView: OnboardingOrbitFileChip(file: file, icon: icon))
            host.wantsLayer = true
            host.layer?.masksToBounds = false
            host.layer?.shouldRasterize = true
            host.layer?.rasterizationScale = window?.backingScaleFactor ?? 2
            host.alphaValue = 0
            addSubview(host)
            hosts[file.id] = host
            hostedIcons[file.id] = icon
            hostSizes[file.id] = host.fittingSize
        }
    }

    /// Cache each finished material card as one compositor surface. The cards'
    /// contents change only when their resolved file icons change, while their
    /// position and transform animate continuously.
    private func updateHostRasterizationScale() {
        let scale = window?.backingScaleFactor ?? 2
        for host in hosts.values {
            host.layer?.rasterizationScale = scale
        }
    }

    private func updateHostedIcons(_ icons: [String: NSImage]) {
        for file in OnboardingOrbitFile.files {
            guard let icon = icons[file.ext] else { continue }
            guard hostedIcons[file.id] !== icon, let host = hosts[file.id] else { continue }
            hostedIcons[file.id] = icon
            host.rootView = OnboardingOrbitFileChip(file: file, icon: icon)
            hostSizes[file.id] = host.fittingSize
        }
    }

    private func updateReveal(visible: Bool) {
        revealWorkItems.forEach { $0.cancel() }
        revealWorkItems.removeAll()

        guard visible else {
            revealedFileIDs.removeAll()
            hosts.values.forEach { $0.alphaValue = 0 }
            return
        }

        for file in OnboardingOrbitFile.files {
            let workItem = DispatchWorkItem { [weak self] in
                self?.reveal(file: file)
            }
            revealWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + file.appearDelay, execute: workItem)
        }
    }

    private func reveal(file: OnboardingOrbitFile) {
        guard let chipLayer = hosts[file.id]?.layer else { return }
        revealedFileIDs.insert(file.id)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chipLayer.opacity = 1
        CATransaction.commit()

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.duration = 0.7
        opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)
        chipLayer.add(opacity, forKey: "revealOpacity")
    }

    private func installDisplayLinkIfNeeded() {
        guard orbitDisplayLink == nil else { return }
        let displayLink = self.displayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:))
        )
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60,
            maximum: Self.interactionFrameRate,
            preferred: Self.interactionFrameRate
        )
        displayLink.add(to: .main, forMode: .common)
        orbitDisplayLink = displayLink
        updateMotionState()
    }

    private func updateMotionState() {
        let springIsMoving = abs(collapseProgress - collapseTarget) > 0.0005
            || abs(collapseVelocity) > 0.0005
        let shouldRunIdleAnimations = filesVisible
            && isActive
            && !reduceMotion
            && collapseTarget == 0
            && !springIsMoving

        if shouldRunIdleAnimations {
            if idleAnimationStartedAt == nil {
                startIdleAnimationsIfNeeded()
            } else {
                configureIdleBaseLayers()
            }
            orbitDisplayLink?.isPaused = true
            lastTimestamp = nil
            return
        }

        if idleAnimationStartedAt != nil {
            stopIdleAnimations(preservingPhase: !reduceMotion)
        }

        let shouldDriveSpring = filesVisible && isActive && !reduceMotion && springIsMoving
        orbitDisplayLink?.isPaused = !shouldDriveSpring
        if !shouldDriveSpring {
            lastTimestamp = nil
        }
    }

    @objc private func displayLinkDidFire(_ sender: CADisplayLink) {
        let timestamp = sender.timestamp
        let delta = min(max(timestamp - (lastTimestamp ?? timestamp), 0), 1.0 / 15.0)
        lastTimestamp = timestamp
        orbitPhase += delta
        advanceCollapseSpring(delta: delta)
        renderFrame()
        updateMotionState()
    }

    private func prepareIdleAnimationsIfNeeded() {
        guard idlePaths.isEmpty, idlePreparationTask == nil else { return }
        let files = OnboardingOrbitFile.files
        idlePreparationTask = Task { [weak self] in
            let preparation = Task.detached(priority: .userInitiated) {
                Self.makeIdleSamples(files: files)
            }
            let samples = await withTaskCancellationHandler {
                await preparation.value
            } onCancel: {
                preparation.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            idlePreparationTask = nil
            for sample in samples {
                let path = CGMutablePath()
                path.addLines(between: sample.positions)
                idlePaths[sample.fileID] = path.copy()

                let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                rotation.values = sample.rotations.map { NSNumber(value: $0) }
                rotation.duration = 2 * .pi / 0.7
                rotation.repeatCount = .infinity
                rotation.calculationMode = .linear
                rotationAnimations[sample.fileID] = rotation
            }
            updateMotionState()
        }
    }

    nonisolated private static func makeIdleSamples(files: [OnboardingOrbitFile]) -> [IdleSamples] {
        files.compactMap { file in
            guard !Task.isCancelled else { return nil }
            let duration = 2 * Double.pi / file.driftSpeed
            let count = max(120, Int(ceil(duration * idleSampleRate)))
            let positions = (0...count).map { index in
                let phase = duration * Double(index) / Double(count)
                let offset = orbitOffset(for: file, phase: phase)
                return CGPoint(x: offset.width, y: offset.height)
            }
            let rotationCount = max(120, Int(ceil(2 * .pi / 0.7 * idleSampleRate)))
            let rotations = (0...rotationCount).map { index in
                let phase = file.driftPhase + 2 * .pi * Double(index) / Double(rotationCount)
                return (file.rotation + sin(phase) * 3) * .pi / 180
            }
            return IdleSamples(fileID: file.id, positions: positions, rotations: rotations)
        }
    }

    private func startIdleAnimationsIfNeeded() {
        guard idleAnimationStartedAt == nil, !bounds.isEmpty, !idlePaths.isEmpty else { return }
        if animationBounds != bounds || positionAnimations.isEmpty {
            animationBounds = bounds
            for file in OnboardingOrbitFile.files {
                var translation = CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
                let animation = CAKeyframeAnimation(keyPath: "position")
                animation.path = idlePaths[file.id]?.copy(using: &translation)
                animation.duration = 2 * .pi / file.driftSpeed
                animation.repeatCount = .infinity
                animation.calculationMode = .linear
                positionAnimations[file.id] = animation
            }
        }
        let startedAt = CACurrentMediaTime()
        idleAnimationStartedAt = startedAt
        idleAnimationBasePhase = orbitPhase

        // Install model positions and animations together to avoid a handoff snap.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        configureIdleBaseLayers()
        for file in OnboardingOrbitFile.files {
            guard let chipLayer = hosts[file.id]?.layer,
                  let position = positionAnimations[file.id],
                  let rotation = rotationAnimations[file.id] else { continue }
            let localStartTime = chipLayer.convertTime(startedAt, from: nil)
            for animation in [position, rotation] {
                animation.beginTime = localStartTime
                animation.timeOffset = orbitPhase.truncatingRemainder(dividingBy: animation.duration)
            }
            chipLayer.add(position, forKey: "idlePosition")
            chipLayer.add(rotation, forKey: "idleRotation")
        }
        CATransaction.commit()
    }

    private func stopIdleAnimations(preservingPhase: Bool) {
        guard let startedAt = idleAnimationStartedAt else { return }
        if preservingPhase {
            orbitPhase += max(0, CACurrentMediaTime() - startedAt)
        }
        idleAnimationStartedAt = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for host in hosts.values {
            Self.idleAnimationKeys.forEach { host.layer?.removeAnimation(forKey: $0) }
        }
        renderFrame()
        CATransaction.commit()
    }

    private func configureIdleBaseLayers() {
        guard !bounds.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for file in OnboardingOrbitFile.files {
            guard let host = hosts[file.id], let chipLayer = host.layer else { continue }
            let fittingSize = hostSizes[file.id] ?? host.fittingSize
            let orbit = Self.orbitOffset(for: file, phase: idleAnimationBasePhase)
            if host.bounds.size != fittingSize {
                host.frame = CGRect(origin: .zero, size: fittingSize)
            }
            chipLayer.position = CGPoint(
                x: bounds.midX + orbit.width,
                y: bounds.midY + orbit.height
            )
            let rotation = file.rotation
                + sin(idleAnimationBasePhase * 0.7 + file.driftPhase) * 3
            chipLayer.setAffineTransform(
                CGAffineTransform(rotationAngle: rotation * .pi / 180)
                    .scaledBy(x: file.scale, y: file.scale)
            )
        }
        CATransaction.commit()
    }

    private static let idleAnimationKeys = ["idlePosition", "idleRotation"]

    private func advanceCollapseSpring(delta: CFTimeInterval) {
        let displacement = collapseProgress - collapseTarget
        guard abs(displacement) > 0.0005 || abs(collapseVelocity) > 0.0005 else {
            collapseProgress = collapseTarget
            collapseVelocity = 0
            return
        }
        let omega = 2 * Double.pi / Self.springResponse
        let acceleration = -omega * omega * Double(displacement)
            - 2 * Self.springDamping * omega * Double(collapseVelocity)
        collapseVelocity += CGFloat(acceleration * delta)
        collapseProgress += collapseVelocity * CGFloat(delta)
    }

    private func renderFrame() {
        guard !bounds.isEmpty else { return }
        let phase = reduceMotion ? 0 : orbitPhase
        let t = min(max(collapseProgress, 0), 1)
        let fadeProgress = min(max((t - 0.70) / 0.30, 0), 1)
        let collapseOpacity = 1 - fadeProgress * fadeProgress * (3 - 2 * fadeProgress)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for file in OnboardingOrbitFile.files {
            guard let host = hosts[file.id], let chipLayer = host.layer else { continue }
            let fittingSize = hostSizes[file.id] ?? host.fittingSize
            let orbit = Self.orbitOffset(for: file, phase: phase)
            let collapse = CGSize(
                width: collapseOrigin.width + file.collapseX * 0.65,
                height: collapseOrigin.height + file.collapseY * 0.18
            )
            let travelX = collapse.width - orbit.width
            let travelY = collapse.height - orbit.height
            let travelLength = max(hypot(travelX, travelY), 1)
            let arc = sin(t * .pi) * (10 + abs(file.rotation) * 0.45)
            let offset = CGSize(
                width: orbit.width + travelX * t - travelY / travelLength * arc,
                height: orbit.height + travelY * t + travelX / travelLength * arc
            )
            let center = CGPoint(x: bounds.midX + offset.width, y: bounds.midY + offset.height)
            if host.bounds.size != fittingSize {
                host.frame = CGRect(origin: .zero, size: fittingSize)
            }
            chipLayer.position = center

            let rotation = (file.rotation + sin(phase * 0.7 + file.driftPhase) * 3)
                * Double(1 - t)
            let scale = file.scale + (0.08 - file.scale) * t
            chipLayer.setAffineTransform(
                CGAffineTransform(rotationAngle: rotation * .pi / 180)
                    .scaledBy(x: scale, y: scale)
            )
            chipLayer.opacity = revealedFileIDs.contains(file.id)
                ? Float(collapseOpacity)
                : 0
        }
        CATransaction.commit()
    }

    nonisolated private static func orbitOffset(for file: OnboardingOrbitFile, phase: Double) -> CGSize {
        let orbitalAngle = phase * file.driftSpeed + file.driftPhase
        let orbitalX = cos(orbitalAngle) * file.orbitWidth * 1.18
        let orbitalY = sin(orbitalAngle) * file.orbitHeight * 1.22
        // Harmonics share the orbit period so the compositor loop has no seam.
        let driftX = cos(orbitalAngle * 2) * file.driftRadius
        let driftY = sin(orbitalAngle * 2) * file.driftRadius
        return CGSize(
            width: file.baseX * 1.18 + orbitalX + driftX,
            height: file.baseY * 1.18 + orbitalY + driftY
        )
    }

}
private struct OnboardingScreenEdgeGlow: View {
    @SortyHotReload private var hotReload
    var body: some View {
        ZStack {
            edgeGradient(startPoint: .top, endPoint: .bottom)
            edgeGradient(startPoint: .bottom, endPoint: .top)
            edgeGradient(startPoint: .leading, endPoint: .trailing)
            edgeGradient(startPoint: .trailing, endPoint: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .compositingGroup()
        .blur(radius: 22)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func edgeGradient(
        startPoint: UnitPoint,
        endPoint: UnitPoint
    ) -> some View {
        let strength = 0.55
        return LinearGradient(
            stops: [
                .init(
                    color: SortyDesignSystem.Colors.resolvedAccent.opacity(strength),
                    location: 0
                ),
                .init(
                    color: SortyDesignSystem.Colors.resolvedAccent.opacity(strength * 0.34),
                    location: 0.035
                ),
                .init(color: .clear, location: 0.13)
            ],
            startPoint: startPoint,
            endPoint: endPoint
        )
    }
}

/// Places a visual-effect surface behind the onboarding window, leaving the
/// Sorty window clear while softening the rest of the current screen.
private struct OnboardingScreenBackdropBlurPresenter: NSViewRepresentable {
    @SortyHotReload private var hotReload
    let isVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = ScreenTrackingView()
        view.onWindowChanged = { window in
            context.coordinator.attach(to: window)
        }
        context.coordinator.setVisible(isVisible)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.setVisible(isVisible)
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    @MainActor
    final class Coordinator {
        private weak var hostWindow: NSWindow?
        private var backdropPanel: NSPanel?
        private var observers: [NSObjectProtocol] = []
        private var pendingDismissal: DispatchWorkItem?
        private var isHostClosing = false
        private var isVisible = false

        func setVisible(_ isVisible: Bool) {
            guard self.isVisible != isVisible else { return }
            self.isVisible = isVisible
            updatePanelFrame()
        }

        func attach(to window: NSWindow?) {
            guard hostWindow !== window else {
                updatePanelFrame()
                return
            }

            removeObservers()
            pendingDismissal?.cancel()
            pendingDismissal = nil
            isHostClosing = false
            hostWindow = window

            guard let window else {
                dismissPanel()
                return
            }

            if backdropPanel == nil {
                backdropPanel = makeBackdropPanel()
            }

            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.updatePanelFrame() }
                },
                center.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.updatePanelFrame() }
                },
                center.addObserver(
                    forName: NSWindow.didChangeScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.updatePanelFrame() }
                },
                center.addObserver(
                    forName: NSWindow.willEnterFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.hidePanelImmediately() }
                },
                center.addObserver(
                    forName: NSWindow.didExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.updatePanelFrame() }
                },
                center.addObserver(
                    forName: NSWindow.didMiniaturizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.hidePanelImmediately() }
                },
                center.addObserver(
                    forName: NSWindow.didDeminiaturizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.updatePanelFrame() }
                },
                center.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.hostWillClose() }
                }
            ]

            updatePanelFrame()
        }

        func dismiss() {
            dismiss(immediately: isHostClosing)
        }

        private func hostWillClose() {
            isHostClosing = true
            dismiss(immediately: true)
        }

        private func dismiss(immediately: Bool) {
            removeObservers()
            dismissPanel(immediately: immediately)
            hostWindow = nil
        }

        private func makeBackdropPanel() -> NSPanel {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .normal
            panel.alphaValue = 0
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .ignoresCycle,
                .stationary
            ]

            let backdrop = NSVisualEffectView()
            backdrop.material = .fullScreenUI
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            panel.contentView = backdrop
            return panel
        }

        private func updatePanelFrame() {
            guard let window = hostWindow,
                  isVisible,
                  window.isVisible,
                  !window.isMiniaturized,
                  !window.styleMask.contains(.fullScreen),
                  let screen = window.screen ?? NSScreen.main else {
                hidePanelImmediately()
                return
            }

            backdropPanel?.setFrame(screen.frame, display: true)
            backdropPanel?.order(.below, relativeTo: window.windowNumber)
            fadeInPanelIfNeeded()
        }

        private func dismissPanel(immediately: Bool = false) {
            guard let backdropPanel else { return }
            pendingDismissal?.cancel()
            let duration = immediately || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.8

            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                backdropPanel.animator().alphaValue = 0
            }

            let dismissal = DispatchWorkItem { [weak self, weak backdropPanel] in
                guard let self, self.backdropPanel === backdropPanel else { return }
                backdropPanel?.orderOut(nil)
                backdropPanel?.close()
                self.backdropPanel = nil
                self.pendingDismissal = nil
            }
            pendingDismissal = dismissal
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismissal)
        }

        private func hidePanelImmediately() {
            backdropPanel?.orderOut(nil)
            backdropPanel?.alphaValue = 0
        }

        private func fadeInPanelIfNeeded() {
            guard let backdropPanel, backdropPanel.alphaValue == 0 else { return }
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.9

            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                backdropPanel.animator().alphaValue = 0.86
            }
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
        }
    }

    private final class ScreenTrackingView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }
}

private struct OnboardingScreenEdgeGlowPresenter: NSViewRepresentable {
    @SortyHotReload private var hotReload
    let isVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = ScreenTrackingView()
        view.onWindowChanged = { window in
            context.coordinator.attach(to: window)
        }
        context.coordinator.setVisible(isVisible)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.setVisible(isVisible)
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    @MainActor
    final class Coordinator {
        private weak var hostWindow: NSWindow?
        private var glowPanel: NSPanel?
        private var observers: [NSObjectProtocol] = []
        private var pendingDismissal: DispatchWorkItem?
        private var isHostClosing = false
        private var isVisible = false

        func setVisible(_ isVisible: Bool) {
            guard self.isVisible != isVisible else { return }
            self.isVisible = isVisible
            showPanelIfPossible()
        }

        func attach(to window: NSWindow?) {
            guard hostWindow !== window else {
                showPanelIfPossible()
                return
            }

            removeObservers()
            pendingDismissal?.cancel()
            pendingDismissal = nil
            isHostClosing = false
            hostWindow = window

            guard let window else {
                dismissPanel()
                return
            }

            if glowPanel == nil {
                glowPanel = makeGlowPanel()
            }

            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.updatePanelFrame() }
                },
                center.addObserver(
                    forName: NSWindow.didChangeScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.updatePanelFrame() }
                },
                center.addObserver(
                    forName: NSWindow.willEnterFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.hidePanelImmediately() }
                },
                center.addObserver(
                    forName: NSWindow.didExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.showPanelIfPossible() }
                },
                center.addObserver(
                    forName: NSWindow.didMiniaturizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.hidePanelImmediately() }
                },
                center.addObserver(
                    forName: NSWindow.didDeminiaturizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.showPanelIfPossible() }
                },
                center.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.hostWillClose() }
                }
            ]

            showPanelIfPossible()
        }

        func dismiss() {
            dismiss(immediately: isHostClosing)
        }

        private func hostWillClose() {
            isHostClosing = true
            dismiss(immediately: true)
        }

        private func dismiss(immediately: Bool) {
            removeObservers()
            dismissPanel(immediately: immediately)
            hostWindow = nil
        }

        private func makeGlowPanel() -> NSPanel {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            panel.alphaValue = 0
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .ignoresCycle,
                .stationary
            ]
            let glowView = NSHostingView(rootView: OnboardingScreenEdgeGlow())
            glowView.sizingOptions = []
            glowView.autoresizingMask = [.width, .height]
            panel.contentView = glowView
            return panel
        }

        private func updatePanelFrame() {
            guard let window = hostWindow,
                  window.isVisible,
                  !window.isMiniaturized,
                  !window.styleMask.contains(.fullScreen),
                  let screen = window.screen ?? NSScreen.main else {
                hidePanelImmediately()
                return
            }
            glowPanel?.setFrame(screen.frame, display: true)
        }

        private func showPanelIfPossible() {
            guard isVisible,
                  let window = hostWindow,
                  window.isVisible,
                  !window.isMiniaturized,
                  !window.styleMask.contains(.fullScreen) else {
                hidePanelImmediately()
                return
            }
            updatePanelFrame()
            fadeInPanelIfNeeded()
        }

        private func fadeInPanelIfNeeded() {
            guard let glowPanel, glowPanel.alphaValue == 0 else { return }
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.8
            glowPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                glowPanel.animator().alphaValue = 1
            }
        }

        private func dismissPanel(immediately: Bool = false) {
            guard let glowPanel else { return }
            pendingDismissal?.cancel()
            let duration = immediately || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.8

            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                glowPanel.animator().alphaValue = 0
            }

            let dismissal = DispatchWorkItem { [weak self, weak glowPanel] in
                guard let self, self.glowPanel === glowPanel else { return }
                glowPanel?.orderOut(nil)
                glowPanel?.close()
                self.glowPanel = nil
                self.pendingDismissal = nil
            }
            pendingDismissal = dismissal
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismissal)
        }

        private func hidePanelImmediately() {
            glowPanel?.orderOut(nil)
            glowPanel?.alphaValue = 0
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
        }
    }

    private final class ScreenTrackingView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }
}

struct OnboardingBottomGradient: NSViewRepresentable {
    @SortyHotReload private var hotReload
    /// 0 = gradient hugs the bottom edge, 1 = gradient reaches near the top.
    var progress: Double = 0
    var showsBaseColor = true

    func makeNSView(context: Context) -> RetainedOnboardingBottomGradientView {
        RetainedOnboardingBottomGradientView()
    }

    func updateNSView(_ nsView: RetainedOnboardingBottomGradientView, context: Context) {
        nsView.update(
            progress: progress,
            showsBaseColor: showsBaseColor,
            isDark: context.environment.colorScheme == .dark,
            reduceMotion: context.environment.accessibilityReduceMotion
        )
    }
}

/// Retains the full-window color field as three gradient layers. Step changes
/// animate only layer colors and geometry instead of asking a SwiftUI Canvas to
/// redraw the entire window throughout every transition.
final class RetainedOnboardingBottomGradientView: NSView {
    private static let transitionDuration: CFTimeInterval = 0.65

    private let accentGradient = CAGradientLayer()
    private let topShadeGradient = CAGradientLayer()
    private let radialGlowGradient = CAGradientLayer()
    private var currentProgress: Double?
    private var currentShowsBaseColor: Bool?
    private var currentIsDark: Bool?
    private var reduceMotion = false
    private var lastLayoutBounds = CGRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(accentGradient)
        layer?.addSublayer(topShadeGradient)
        layer?.addSublayer(radialGlowGradient)

        accentGradient.startPoint = CGPoint(x: 0.5, y: 1)
        accentGradient.locations = [0, 0.42, 1]
        topShadeGradient.startPoint = CGPoint(x: 0.5, y: 0)
        topShadeGradient.endPoint = CGPoint(x: 0.5, y: 1)
        topShadeGradient.locations = [0, 0.32, 0.64]
        radialGlowGradient.type = .radial
        radialGlowGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        radialGlowGradient.endPoint = CGPoint(x: 1, y: 0.5)
        radialGlowGradient.locations = [0, 0.42, 1]
        radialGlowGradient.compositingFilter = CIFilter(name: "CIAdditionCompositing")
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard bounds != lastLayoutBounds else { return }
        lastLayoutBounds = bounds
        applyPresentation(animated: false)
    }

    func update(
        progress: Double,
        showsBaseColor: Bool,
        isDark: Bool,
        reduceMotion: Bool
    ) {
        let clampedProgress = max(0, min(1, progress))
        let progressChanged = currentProgress != clampedProgress
        let appearanceChanged = currentIsDark != isDark
        let baseChanged = currentShowsBaseColor != showsBaseColor
        let motionChanged = self.reduceMotion != reduceMotion
        guard progressChanged || appearanceChanged || baseChanged || motionChanged else { return }

        let hasPresentedBefore = currentProgress != nil
        currentProgress = clampedProgress
        currentShowsBaseColor = showsBaseColor
        currentIsDark = isDark
        self.reduceMotion = reduceMotion
        applyPresentation(animated: hasPresentedBefore && progressChanged && !reduceMotion)
    }

    private func applyPresentation(animated: Bool) {
        guard let progress = currentProgress,
              let showsBaseColor = currentShowsBaseColor,
              let isDark = currentIsDark,
              !bounds.isEmpty else { return }

        let completion = progress * progress
        let intensity = 0.98 + completion * 0.28
        let bottomOpacity = isDark ? 0.42 : 0.20
        let midOpacity = isDark ? 0.22 : 0.10
        let glowOpacity = isDark ? 0.28 : 0.12
        let accent = NSColor(SortyDesignSystem.Colors.resolvedAccent)

        layer?.backgroundColor = showsBaseColor
            ? NSColor.windowBackgroundColor.cgColor
            : NSColor.clear.cgColor

        let accentColors = [
            accent.withAlphaComponent(bottomOpacity * intensity).cgColor,
            accent.withAlphaComponent(midOpacity * intensity).cgColor,
            accent.withAlphaComponent(0).cgColor
        ]
        let accentEndPoint = CGPoint(x: 0.5, y: 0.68 - progress * 0.56)
        let shadeColors = [
            NSColor.black.withAlphaComponent(isDark ? 0.18 : 0).cgColor,
            NSColor.black.withAlphaComponent(isDark ? 0.04 : 0).cgColor,
            NSColor.clear.cgColor
        ]
        let radialColors = [
            accent.withAlphaComponent(glowOpacity * intensity).cgColor,
            accent.withAlphaComponent((isDark ? 0.16 : 0.06) * intensity).cgColor,
            accent.withAlphaComponent(0).cgColor
        ]
        let radialRadius = 680 + completion * 560
        let radialCenter = CGPoint(
            x: bounds.midX,
            y: bounds.height * (1.02 - progress * 0.18)
        )
        let radialFrame = CGRect(
            x: radialCenter.x - radialRadius,
            y: radialCenter.y - radialRadius,
            width: radialRadius * 2,
            height: radialRadius * 2
        )

        let duration = animated ? Self.transitionDuration : 0
        update(
            accentGradient,
            frame: bounds,
            colors: accentColors,
            endPoint: accentEndPoint,
            duration: duration
        )
        update(
            topShadeGradient,
            frame: bounds,
            colors: shadeColors,
            endPoint: CGPoint(x: 0.5, y: 1),
            duration: 0
        )
        update(
            radialGlowGradient,
            frame: radialFrame,
            colors: radialColors,
            endPoint: CGPoint(x: 1, y: 0.5),
            duration: duration
        )
    }

    private func update(
        _ gradient: CAGradientLayer,
        frame: CGRect,
        colors: [CGColor],
        endPoint: CGPoint,
        duration: CFTimeInterval
    ) {
        if duration > 0 {
            addAnimation(
                to: gradient,
                keyPath: "colors",
                from: gradient.presentation()?.colors ?? gradient.colors,
                to: colors,
                duration: duration
            )
            addAnimation(
                to: gradient,
                keyPath: "endPoint",
                from: gradient.presentation()?.endPoint ?? gradient.endPoint,
                to: endPoint,
                duration: duration
            )
            addAnimation(
                to: gradient,
                keyPath: "position",
                from: gradient.presentation()?.position ?? gradient.position,
                to: CGPoint(x: frame.midX, y: frame.midY),
                duration: duration
            )
            addAnimation(
                to: gradient,
                keyPath: "bounds",
                from: gradient.presentation()?.bounds ?? gradient.bounds,
                to: CGRect(origin: .zero, size: frame.size),
                duration: duration
            )
        } else {
            gradient.removeAllAnimations()
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = frame
        gradient.colors = colors
        gradient.endPoint = endPoint
        CATransaction.commit()
    }

    private func addAnimation(
        to layer: CALayer,
        keyPath: String,
        from: Any?,
        to: Any,
        duration: CFTimeInterval
    ) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "onboardingGradient.\(keyPath)")
    }
}

private struct OnboardingNavigationBackdrop: View {
    @SortyHotReload private var hotReload
    var body: some View {
        LinearGradient(
            colors: [
                Color(NSColor.windowBackgroundColor).opacity(0),
                Color(NSColor.windowBackgroundColor).opacity(0.20),
                Color(NSColor.windowBackgroundColor).opacity(0.34)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea(edges: .bottom)
    }
}

private struct OnboardingWindowTitleConfigurator: NSViewRepresentable {
    @SortyHotReload private var hotReload
    let preserveWindowPosition: Bool
    let onConfigured: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowAttachedView()
        view.onWindowAttached = { window in
            context.coordinator.configure(window: window, preserveWindowPosition: preserveWindowPosition)
            notifyAfterWindowLayoutSettles()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Window attachment is handled once by WindowAttachedView. Ordinary
        // SwiftUI updates must not enqueue window work or configuration state.
    }

    private func notifyAfterWindowLayoutSettles() {
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                onConfigured()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private weak var configuredWindow: NSWindow?
        private var originalTitleVisibility: NSWindow.TitleVisibility?
        private var originalTitlebarAppearsTransparent: Bool?
        private var originalTitlebarSeparatorStyle: NSTitlebarSeparatorStyle?
        private var originalStyleMask: NSWindow.StyleMask?
        private var originalBackgroundColor: NSColor?
        private var originalIsOpaque: Bool?
        private var originalHasShadow: Bool?
        private var originalAlphaValue: CGFloat?
        private var originalContentMinSize: NSSize?

        func configure(window: NSWindow, preserveWindowPosition: Bool) {
            guard configuredWindow !== window else { return }
            restore()

            configuredWindow = window
            originalTitleVisibility = window.titleVisibility
            originalTitlebarAppearsTransparent = window.titlebarAppearsTransparent
            originalTitlebarSeparatorStyle = window.titlebarSeparatorStyle
            originalStyleMask = window.styleMask
            originalBackgroundColor = window.backgroundColor
            originalIsOpaque = window.isOpaque
            originalHasShadow = window.hasShadow
            originalAlphaValue = window.alphaValue
            originalContentMinSize = window.contentMinSize

            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.isMovableByWindowBackground = true

            // Pin the window to the onboarding minimum content size before the
            // first paint so it never visibly resizes/reframes after appearing.
            let targetSize = NSSize(
                width: SortyDesignSystem.Sizing.windowOnboardingWidth,
                height: SortyDesignSystem.Sizing.windowOnboardingHeight
            )
            window.contentMinSize = targetSize
            if window.contentLayoutRect.width < targetSize.width
                || window.contentLayoutRect.height < targetSize.height
            {
                window.setContentSize(targetSize)
            }
            if !preserveWindowPosition, !window.styleMask.contains(.fullScreen) {
                window.center()
            }
            if !preserveWindowPosition, !window.styleMask.contains(.fullScreen),
               let screen = window.screen ?? NSScreen.main {
                let centeredOrigin = window.frame.origin
                let loweredY = max(screen.visibleFrame.minY + 24, centeredOrigin.y - 32)
                window.setFrameOrigin(NSPoint(x: centeredOrigin.x, y: loweredY))
            }

            // The intro's retained icon and phase-driven panels own the reveal.
            // A second whole-window fade completes out of sync with those
            // surfaces and produces a visible flash at the phase boundary.
            window.alphaValue = 1
            window.makeKey()
        }

        private func restore() {
            guard let window = configuredWindow else { return }
            if let originalStyleMask {
                window.styleMask = originalStyleMask
            }
            if let originalTitlebarAppearsTransparent {
                window.titlebarAppearsTransparent = originalTitlebarAppearsTransparent
            }
            if let originalTitlebarSeparatorStyle {
                window.titlebarSeparatorStyle = originalTitlebarSeparatorStyle
            }
            if let originalTitleVisibility {
                window.titleVisibility = originalTitleVisibility
            }
            if let originalBackgroundColor {
                window.backgroundColor = originalBackgroundColor
            }
            if let originalIsOpaque {
                window.isOpaque = originalIsOpaque
            }
            if let originalHasShadow {
                window.hasShadow = originalHasShadow
            }
            if let originalAlphaValue {
                window.alphaValue = originalAlphaValue
            } else {
                window.alphaValue = 1
            }
            if let originalContentMinSize {
                window.contentMinSize = originalContentMinSize
            }
        }

        deinit {
            restore()
        }
    }

    final class WindowAttachedView: NSView {
        var onWindowAttached: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            onWindowAttached?(window)
        }
    }
}

// MARK: - Progress Bar

struct OnboardingIconSliver: View {
    @SortyHotReload private var hotReload
    let systemName: String
    let color: Color
    let fontSize: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweepProgress: CGFloat = 0
    private let sliverDuration: TimeInterval = 1.25

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: fontSize))
            .foregroundStyle(color)
            .modifier(
                OnboardingIconSweep(
                    progress: reduceMotion ? 0.5 : sweepProgress,
                    reduceMotion: reduceMotion,
                    tint: color
                )
            )
            .onAppear {
                guard !reduceMotion else { return }
                sweepProgress = 0
                HapticSequenceManager.shared.playShimmerWave(duration: sliverDuration)
                withAnimation(.easeInOut(duration: sliverDuration)) {
                    sweepProgress = 1
                }
            }
            .accessibilityHidden(false)
    }
}

private struct OnboardingIconSweep: ViewModifier, Animatable {
    var progress: CGFloat
    let reduceMotion: Bool
    let tint: Color

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let sweep = min(max(progress, 0), 1)
        let envelope = sin(sweep * .pi)
        let glow = reduceMotion ? 0 : envelope * envelope
        let overlayOpacity = Double(glow)

        return content
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: tint.opacity(0.25), location: 0),
                        .init(color: tint, location: max(0, sweep - 0.16)),
                        .init(color: .white, location: sweep),
                        .init(color: tint, location: min(1, sweep + 0.16)),
                        .init(color: tint.opacity(0.25), location: 1)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .mask { content }
                .opacity(overlayOpacity)
                .shadow(color: tint.opacity(glow * 0.8), radius: glow * 13)
            }
            .shadow(color: tint.opacity(glow * 0.52), radius: glow * 11)
    }
}

struct OnboardingProgressBar: View {
    @SortyHotReload private var hotReload
    let currentStep: OnboardingStep

    @MainActor
    private var activeSteps: [OnboardingStep] {
        OnboardingStep.allCases
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<activeSteps.count, id: \.self) { index in
                let step = activeSteps[index]

                if index > 0 {
                    Capsule(style: .continuous)
                        .fill(
                            step.rawValue <= currentStep.rawValue
                                ? SortyDesignSystem.Colors.resolvedAccent : Color.secondary.opacity(0.2)
                        )
                        .frame(width: 56, height: 2)
                        .padding(.top, 11)
                }

                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(
                                step.rawValue <= currentStep.rawValue
                                    ? SortyDesignSystem.Colors.resolvedAccent : Color.secondary.opacity(0.2)
                            )
                            .frame(width: 24, height: 24)

                        let isComplete = step.rawValue < currentStep.rawValue

                        if isComplete {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(
                                    step.rawValue <= currentStep.rawValue ? .white : .secondary)
                        }
                    }

                    Text(LocalizedStringKey(step.title))
                        .font(.caption2)
                        .foregroundStyle(step == currentStep ? .primary : .secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 20)
                }
                .frame(width: 82)
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
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
