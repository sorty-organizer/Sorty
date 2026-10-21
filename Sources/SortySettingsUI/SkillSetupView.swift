import AppKit
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI

/// Presents the existing skill importer before the original app onboarding.
package struct SkillOnboardingView: View {
    @EnvironmentObject var appState: AppState
    @StateObject var installer = CodexSkillInstaller()
    @State var isCheckingSkill = false
    @State var errorMessage: String?

    package init() {}

    package var body: some View {
        SkillSetupView(
            installer: installer,
            onClose: appState.continueWithAppAfterSkillIntroduction,
            onSavingChanged: { _ in },
            isOnboarding: true,
            onUseSkill: useSkill
        )
        .disabled(isCheckingSkill)
        .overlay {
            if isCheckingSkill {
                ProgressView("Checking installed skill…")
                    .padding(20)
                    .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
            }
        }
        .frame(
            minWidth: SortyDesignSystem.Sizing.windowOnboardingWidth,
            minHeight: SortyDesignSystem.Sizing.windowOnboardingHeight
        )
        .background {
            OnboardingWindowTitleConfigurator(preserveWindowPosition: appState.isRestartingOnboarding, onConfigured: {})
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .accessibilityIdentifier("SkillOnboardingView")
        .alert("Your Skill Needs Attention", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task(id: isCheckingSkill) {
            guard isCheckingSkill else { return }
            defer { isCheckingSkill = false }
            await installer.refresh(trackUsage: false)
            guard !Task.isCancelled else { return }
            guard case .installed = installer.state else {
                errorMessage = "The installed skill is no longer available at the chosen location. Continue with the app and set up the skill again in Settings before deleting Sorty."
                HapticFeedbackManager.shared.error()
                return
            }
            appState.requestUninstallConfirmation(preservingSkillAt: installer.destinationURL)
        }
    }

    func useSkill() {
        guard !isCheckingSkill else { return }
        HapticFeedbackManager.shared.tap()
        isCheckingSkill = true
    }
}

struct SkillSetupView: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var exclusions: ExclusionRulesManager
    @EnvironmentObject var watchedFolders: WatchedFoldersManager
    @EnvironmentObject var learnings: LearningsManager
    @EnvironmentObject var automation: AutomationManager
    @ObservedObject var installer: CodexSkillInstaller
    let onClose: () -> Void
    let onSavingChanged: (Bool) -> Void
    let isOnboarding: Bool
    let onUseSkill: () -> Void

    @State var introAudioPlayer: AVAudioPlayer?
    @State var introductionStage = 0
    @State var hasRevealedSkillUnderline = false
    @State var step: Step = .welcome
    @State var activeSection: SkillImportOption.Section = .preferences
    @State var expandedSections: Set<SkillImportOption.Section> = []
    @State var optionSearch = ""
    @State var isImportDisclosureHovered = false
    @State var options: [SkillImportOption] = []
    @State var selected: Set<String> = []
    @State var isLoading = true
    @State var hasLoadedOptions = false
    @State var isSaving = false
    @State var importProgressDeadline: ContinuousClock.Instant?
    @State var hasReachedReviewBottom = false
    @State var errorMessage: String?
    @State var isConfirmingReplacement = false
    @State var isGetStartedHovered = false
    @State var isPrimaryActionHovered = false
    @State var hoveredAgentLocation: String?
    @State var customFolderIcon: NSImage?
    @State var skillIcon: NSImage?
    @State var agentIcons: [String: NSImage] = [:]
    @ScaledMetric(relativeTo: .largeTitle) var agentIconSize: CGFloat = 36
    @ScaledMetric(relativeTo: .largeTitle) var titleSize: CGFloat = 32
    @ScaledMetric(relativeTo: .headline) var headingSize: CGFloat = 18
    @ScaledMetric(relativeTo: .body) var readingSize: CGFloat = 16
    @ScaledMetric(relativeTo: .callout) var supportingSize: CGFloat = 14
    @AccessibilityFocusState var isHeadingFocused: Bool

    init(
        installer: CodexSkillInstaller,
        onClose: @escaping () -> Void,
        onSavingChanged: @escaping (Bool) -> Void,
        isOnboarding: Bool = false,
        onUseSkill: @escaping () -> Void = {}
    ) {
        self.installer = installer
        self.onClose = onClose
        self.onSavingChanged = onSavingChanged
        self.isOnboarding = isOnboarding
        self.onUseSkill = onUseSkill
        self._step = State(initialValue: isOnboarding ? .rethink : .welcome)
    }

    var readingFont: Font { .system(size: readingSize, design: .default) }
    var supportingFont: Font { .system(size: supportingSize, design: .default) }
    var headingFont: Font { .system(size: headingSize, weight: .semibold, design: .default) }

    enum Step: Int, CaseIterable {
        case rethink, about, welcome, location, preferences, review, complete

        var title: String {
            switch self {
            case .rethink: "Sorty can be a skill"
            case .about: "Sorty, through conversation"
            case .welcome: "Use Sorty in your agent"
            case .location: "Choose a skills folder"
            case .preferences: "Choose what to share"
            case .review: "Review and import"
            case .complete: "Your skill is ready"
            }
        }

        var explanation: String {
            switch self {
            case .rethink: "Since the last update, we've thought a lot about how Sorty works."
            case .about: "The skill is our next step for Sorty: replacing the app's core workflow with a conversation."
            case .welcome: "Set up the skill to organize files directly in your agent, with the preferences you already use."
            case .location: "Pick where your agent loads skills, or choose a custom folder."
            case .preferences: "Choose settings to copy into the skill, or import nothing."
            case .review: "Confirm the location and selection. Nothing installs until you import."
            case .complete: "Start a new chat, tell it to use Sorty, and name the folder to organize."
            }
        }

        var railTitle: String {
            switch self {
            case .rethink: "Update"
            case .about: "Skill"
            case .welcome: "About"
            case .location: "Location"
            case .preferences: "Preferences"
            case .review: "Review"
            case .complete: "Ready"
            }
        }
    }

    var setupSteps: [Step] {
        isOnboarding ? [.rethink, .about, .welcome, .location, .preferences, .review]
            : [.welcome, .location, .preferences, .review]
    }

    var body: some View {
        ZStack {
            Color.clear
                .systemLiquidGlassBackground(cornerRadius: 0, interactive: false)
                .ignoresSafeArea()
            if reduceTransparency {
                Color(NSColor.windowBackgroundColor).ignoresSafeArea()
            } else {
                OnboardingBottomGradient(
                    progress: Double(step.rawValue - (isOnboarding ? 0 : 2)) / Double(isOnboarding ? 6 : 4),
                    showsBaseColor: false
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            VStack(spacing: 0) {
                progressRail
                    .modifier(SkillIntroductionReveal(
                        isVisible: step != .rethink || introductionStage >= 1,
                        reduceMotion: reduceMotion,
                        duration: 0.22
                    ))
                    .padding(.top, 48)
                    .padding(.bottom, 24)
                VStack(spacing: 12) {
                    if step == .rethink {
                        Text(step.explanation)
                            .font(readingFont)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .modifier(introductionReveal(at: 1))
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text("We realized ")
                                underlinedSkillPhrase
                            }
                            .fixedSize(horizontal: true, vertical: true)
                            VStack(spacing: 0) {
                                Text("We realized")
                                underlinedSkillPhrase
                            }
                        }
                            .font(.system(size: titleSize, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("We realized Sorty can be a skill.")
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($isHeadingFocused)
                            .modifier(introductionReveal(at: 2))
                    } else {
                        Text(step.title)
                            .contentTransition(reduceMotion ? .identity : .numericText())
                            .font(.system(size: titleSize, weight: .semibold, design: .default))
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($isHeadingFocused)
                            .modifier(introductionReveal(at: 1))
                        Text(step.explanation)
                            .contentTransition(reduceMotion ? .identity : .numericText())
                            .font(readingFont)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 680)
                            .modifier(introductionReveal(at: 2))
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 20)

                Group {
                    if importProgressDeadline != nil {
                        importProgress
                    } else if step == .location {
                        ScrollView { stepContent }
                    } else if step == .rethink || step == .about || step == .welcome || step == .complete {
                        SkillImportChecklist { stepContent }
                    } else {
                        stepContent
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 8)
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
                .disabled(isWaitingForOptions || isSaving)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(supportingFont)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 40)
                        .padding(.top, 12)
                        .accessibilityIdentifier("skill-import.error")
                }
                navigation
                    .padding(.horizontal, 40)
                    .padding(.vertical, 24)
            }
        }
        .overlay(alignment: .topLeading) {
            if isOnboarding {
                OnboardingScreenEdgeGlowPresenter(
                    isVisible: true,
                    strength: hasRevealedSkillUnderline ? 0.68 : 0.55
                )
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .font(readingFont)
        .accessibilityIdentifier("skill-import.window")
        .task {
            if isOnboarding { await installer.refresh(trackUsage: false) }
            if !isIntroduction { isHeadingFocused = true }
        }
        .task(id: needsImportOptions) {
            guard needsImportOptions, !hasLoadedOptions else { return }
            await loadOptions()
        }
        .task(id: isSaving) {
            guard isSaving else { return }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch { return }
            guard !Task.isCancelled, isSaving else { return }
            // Skip progress for fast imports; give it time to read once it appears.
            importProgressDeadline = ContinuousClock.now.advanced(by: .milliseconds(1500))
        }
        .task {
            for resource in ["SkillAgentCodex", "SkillAgentClaudeCode", "SkillAgentOpenCodeDark", "SkillAgentOpenCodeLight", "SkillAgentPi"] {
                let image = await SortyResources.imageAsync(named: "AgentIcons/\(resource)", withExtension: "pdf")
                guard !Task.isCancelled else { return }
                agentIcons[resource] = image
            }
        }
        .task(id: [step.rawValue, reduceMotion ? 1 : 0]) {
            await revealIntroduction()
        }
        .onChange(of: introductionStage) { previousStage, stage in
            if isOnboarding, !reduceMotion, NSApp.isActive, stage > previousStage, stage >= 2 {
                HapticFeedbackManager.shared.light()
            }
            if step == .rethink && stage >= 3 {
                hasRevealedSkillUnderline = true
            }
        }
        .onDisappear {
            introAudioPlayer?.stop()
        }
        .onChange(of: step) { previousStep, _ in
            if previousStep == .rethink { introAudioPlayer?.stop() }
            if !isIntroduction { isHeadingFocused = true }
            isGetStartedHovered = false
            isPrimaryActionHovered = false
        }
        .onChange(of: errorMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .confirmationDialog("Replace the existing Sorty skill?", isPresented: $isConfirmingReplacement) {
            Button("Replace and Import", role: .destructive, action: importSelected)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the skill at the chosen location, then imports your selection. Existing imported settings are backed up before the new import.")
        }
    }


}

