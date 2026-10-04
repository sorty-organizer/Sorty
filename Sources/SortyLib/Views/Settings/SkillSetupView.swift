import AppKit
@preconcurrency import AVFoundation
import SwiftUI

/// Presents the existing skill importer before the original app onboarding.
struct SkillOnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var installer = CodexSkillInstaller()
    @State private var isCheckingSkill = false
    @State private var errorMessage: String?
    @State private var audioPlayer: AVAudioPlayer?

    var body: some View {
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
        .task {
            await playIntroSound()
        }
        .onDisappear {
            audioPlayer?.stop()
            audioPlayer = nil
        }
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

    /// Loads the bundled soundtrack after mounting and plays it across the skill steps.
    private func playIntroSound() async {
        guard audioPlayer == nil,
              let soundURL = Bundle.main.url(forResource: "SkillOnboardingSound", withExtension: "m4a")
                ?? SortyResources.urlForCopiedResource(named: "SkillOnboardingSound.m4a")
        else { return }

        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: soundURL, options: .mappedIfSafe)
        }.value
        guard !Task.isCancelled, audioPlayer == nil, let data,
              let player = try? AVAudioPlayer(data: data) else { return }
        player.numberOfLoops = 0
        player.volume = 0.6
        player.prepareToPlay()
        audioPlayer = player
        player.play()
    }

    private func useSkill() {
        guard !isCheckingSkill else { return }
        HapticFeedbackManager.shared.tap()
        isCheckingSkill = true
    }
}

struct SkillSetupView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var exclusions: ExclusionRulesManager
    @EnvironmentObject private var watchedFolders: WatchedFoldersManager
    @EnvironmentObject private var learnings: LearningsManager
    @EnvironmentObject private var automation: AutomationManager
    @ObservedObject var installer: CodexSkillInstaller
    let onClose: () -> Void
    let onSavingChanged: (Bool) -> Void
    let isOnboarding: Bool
    let onUseSkill: () -> Void

    @State private var introductionStage = 0
    @State private var hasRevealedSkillUnderline = false
    @State private var step: Step = .welcome
    @State private var activeSection: SkillImportOption.Section = .preferences
    @State private var expandedSections: Set<SkillImportOption.Section> = []
    @State private var optionSearch = ""
    @State private var isImportDisclosureHovered = false
    @State private var options: [SkillImportOption] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var hasReachedReviewBottom = false
    @State private var errorMessage: String?
    @State private var isConfirmingReplacement = false
    @State private var isGetStartedHovered = false
    @State private var hoveredAgentLocation: String?
    @State private var customFolderIcon: NSImage?
    @State private var skillIcon: NSImage?
    @ScaledMetric(relativeTo: .largeTitle) private var agentIconSize: CGFloat = 36
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 32
    @ScaledMetric(relativeTo: .headline) private var headingSize: CGFloat = 18
    @ScaledMetric(relativeTo: .body) private var readingSize: CGFloat = 16
    @ScaledMetric(relativeTo: .callout) private var supportingSize: CGFloat = 14
    @AccessibilityFocusState private var isHeadingFocused: Bool

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

    private var readingFont: Font { .system(size: readingSize, design: .default) }
    private var supportingFont: Font { .system(size: supportingSize, design: .default) }
    private var headingFont: Font { .system(size: headingSize, weight: .semibold, design: .default) }

    private enum Step: Int, CaseIterable {
        case rethink, about, welcome, location, preferences, review, complete

        var title: String {
            switch self {
            case .rethink: "Sorty can be a skill"
            case .about: "Meet the Sorty skill"
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
            case .about: "The same file organization tools, ready for a conversation with your agent."
            case .welcome: "The Sorty skill lets your agent organize files using your saved preferences."
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

    private var setupSteps: [Step] {
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
                    if isSaving {
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
                .disabled(isLoading || isSaving)

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
            await loadOptions()
            if !isIntroduction { isHeadingFocused = true }
        }
        .task(id: [step.rawValue, reduceMotion ? 1 : 0]) {
            await revealIntroduction()
        }
        .onChange(of: introductionStage) { _, stage in
            if step == .rethink && stage >= 2 {
                hasRevealedSkillUnderline = true
            }
        }
        .onChange(of: step) { _, _ in
            if !isIntroduction { isHeadingFocused = true }
            isGetStartedHovered = false
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

    private var isIntroduction: Bool {
        step == .rethink || step == .about || step == .welcome
    }

    private var underlinedSkillPhrase: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Sorty can be a skill")
                .overlay(alignment: .bottom) {
                    GeometryReader { geometry in
                        Path { path in
                            let width = geometry.size.width
                            path.move(to: CGPoint(x: 0, y: 5))
                            path.addCurve(
                                to: CGPoint(x: width, y: 3),
                                control1: CGPoint(x: width * 0.3, y: 0),
                                control2: CGPoint(x: width * 0.65, y: 10)
                            )
                        }
                        .trim(from: 0, to: introductionStage >= 2 ? 1 : 0)
                        .stroke(.tint, style: StrokeStyle(lineWidth: titleSize * 0.09, lineCap: .round))
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.55).delay(0.25),
                            value: introductionStage >= 2
                        )
                    }
                    .frame(height: 10)
                    .offset(y: 7)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            Text(".")
        }
    }

    private func introductionReveal(at stage: Int) -> SkillIntroductionReveal {
        SkillIntroductionReveal(
            isVisible: !isIntroduction || introductionStage >= stage,
            reduceMotion: reduceMotion
        )
    }

    /// Reveal in place so each line stays visible and the layout never shifts.
    private func revealIntroduction() async {
        guard isIntroduction else { return }
        if step == .rethink, skillIcon == nil {
            let image = await SortyResources.imageAsync(named: "SortySkillIcon")
            guard !Task.isCancelled else { return }
            skillIcon = image
        }
        if reduceMotion {
            introductionStage = 5
            isHeadingFocused = true
            return
        }
        do {
            introductionStage = 1
            try await Task.sleep(for: .seconds(step == .rethink ? 2 : 0.7))
            introductionStage = 2
            isHeadingFocused = true
            try await Task.sleep(for: .seconds(step == .rethink ? 1.5 : 0.7))
            introductionStage = 3
            try await Task.sleep(for: .seconds(0.6))
            introductionStage = 4
            try await Task.sleep(for: .seconds(0.6))
            introductionStage = 5
        } catch {
            // SwiftUI cancels the sequence when the user leaves this page.
        }
    }

    private var skillIconTransition: some View {
        ZStack {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
                .blur(radius: introductionStage >= 4 && !reduceMotion && !reduceTransparency ? 4 : 0)
                .opacity(introductionStage >= 4 ? 0.55 : 1)
                .offset(x: introductionStage >= 4 ? -120 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: introductionStage >= 4)

            Image(systemName: "arrow.right")
                .font(.largeTitle.weight(.medium))
                .foregroundStyle(.secondary)
                .opacity(introductionStage >= 5 ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: introductionStage >= 5)

            if let skillIcon {
                Image(nsImage: skillIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160, height: 160)
                    .offset(x: 120)
                    .opacity(introductionStage >= 5 ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35).delay(0.15), value: introductionStage >= 5)
            }
        }
        .frame(width: 400, height: 180)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("From the Sorty app to the Sorty skill")
        .accessibilityIdentifier("skill-import.icon-transition")
    }

    private var importProgress: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Importing preferences")
                    .font(headingFont)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($isHeadingFocused)
                Text("Saving your selection to the Sorty skill.")
                    .font(readingFont)
                    .foregroundStyle(.secondary)
            }
            if reduceMotion {
                Label("Import in progress", systemImage: "arrow.down.doc")
                    .font(supportingFont)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                    .accessibilityLabel("Import in progress")
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("skill-import.progress")
        .onAppear {
            isHeadingFocused = true
            AccessibilityNotification.Announcement("Importing preferences").post()
        }
    }

    private var progressRail: some View {
        HStack(spacing: 16) {
            ForEach(Array(setupSteps.enumerated()), id: \.element) { index, item in
                HStack(spacing: 8) {
                    Image(systemName: step.rawValue > item.rawValue ? "checkmark.circle.fill" : "\(index + 1).circle\(step == item ? ".fill" : "")")
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .accessibilityHidden(true)
                    Text(item.railTitle)
                        .font(supportingFont.weight(step == item ? .semibold : .regular))
                }
                .foregroundStyle(step.rawValue >= item.rawValue ? Color.primary : Color.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(index + 1), \(item.railTitle)")
                .accessibilityValue(step.rawValue > item.rawValue ? "Completed" : step == item ? "Current" : "Upcoming")
                if item != .review {
                    Rectangle().fill(.secondary.opacity(0.25)).frame(width: 24, height: 1)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .rethink:
            VStack(spacing: 28) {
                skillIconTransition
                    .modifier(introductionReveal(at: 3))
            }
            .frame(maxWidth: 680)
        case .about:
            VStack(alignment: .leading, spacing: 20) {
                explanation("The same files, your agent", icon: "folder.badge.gearshape", detail: "Organize folders, rename files, find exact duplicates, and review changes in a conversation.")
                    .modifier(introductionReveal(at: 3))
                explanation("Bring your preferences", icon: "checklist", detail: "Copy your naming rules, exclusions, saved folders, and Learnings into the skill. You choose what to share.")
                    .modifier(introductionReveal(at: 4))
                explanation("Choose how to continue", icon: "arrow.triangle.branch", detail: "We'll help you set up the skill. Then you can delete Sorty or continue with the app.")
                    .modifier(introductionReveal(at: 5))
            }
            .frame(maxWidth: 680)
        case .welcome:
            VStack(spacing: 24) {
                ZStack {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 40, weight: .regular))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                        .opacity(isGetStartedHovered ? 0 : 1)
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .opacity(isGetStartedHovered ? 1 : 0)
                }
                .frame(width: 80, height: 80, alignment: .center)
                .systemLiquidGlassBackground(cornerRadius: 24, interactive: false)
                .frame(maxWidth: .infinity, alignment: .center)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isGetStartedHovered)
                .accessibilityHidden(true)
                .modifier(introductionReveal(at: 3))
                VStack(alignment: .leading, spacing: 24) {
                    explanation("Your preferences", icon: "textformat", detail: "Naming style, exclusions, saved folders, and Learnings you select.")
                    explanation("Preview first", icon: "list.bullet.rectangle", detail: "Ask for a preview before moving files. Every move can be restored.")
                    explanation("You stay in control", icon: "text.bubble", detail: "Name the folder and rules each time. Saved folders never auto-organize.")
                    if isOnboarding {
                        explanation("Your agent runs the skill", icon: "terminal", detail: "The skill uses your agent's model and file access. Finder integration, automatic watching, and widgets remain in the app.")
                    }
                }
                .frame(maxWidth: 680)
                .modifier(introductionReveal(at: 4))
            }
        case .location:
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(SkillAgent.allCases, id: \.self) { agent in
                        agentLocationButton(agent)
                    }
                    agentLocationButton(nil)
                }
                .accessibilityIdentifier("skill-import.agent")
                .disabled(isCheckingLocation)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 16) {
                        PrivacySensitivePathText(path: installer.destinationURL.path)
                            .font(readingFont.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Change Folder…", action: chooseLocation)
                            .buttonStyle(.sortyBordered(size: .large))
                            .accessibilityIdentifier("skill-import.choose-location")
                            .disabled(isCheckingLocation)
                            .fixedSize()
                    }
                    locationStatus
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .systemLiquidGlassBackground(cornerRadius: 20, interactive: false)
                Text("Nothing installs until you confirm.")
                    .font(supportingFont)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 640)
            .padding(.vertical, 20)
        case .preferences:
            // Bound the checklist to the space between the heading and navigation.
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(SkillImportOption.Section.allCases, id: \.self) { section in
                            Button {
                                HapticFeedbackManager.shared.selection()
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                                    activeSection = section
                                    optionSearch = ""
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: section.icon).accessibilityHidden(true)
                                    Text(section.rawValue)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    if activeSection == section {
                                        Image(systemName: "chevron.right").font(supportingFont).accessibilityHidden(true)
                                    }
                                }
                                .font(readingFont.weight(activeSection == section ? .semibold : .regular))
                                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.sortyBordered())
                            .accessibilityAddTraits(activeSection == section ? .isSelected : [])
                            .accessibilityIdentifier("skill-import.section.\(section.rawValue)")
                        }
                        Button(allSelected ? "Deselect All" : "Select All", action: toggleAll)
                            .contentTransition(reduceMotion ? .identity : .numericText())
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: allSelected)
                            .buttonStyle(.sortyBordered())
                            .padding(.top, 12)
                            .accessibilityIdentifier("skill-import.select-all")
                    }
                    .frame(width: 210)
                    importSection(activeSection)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }
        case .review:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Install location", systemImage: "folder").font(headingFont)
                        PrivacySensitivePathText(path: installer.destinationURL.path)
                            .font(supportingFont.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider()
                        ForEach(SkillImportOption.Section.allCases, id: \.self) { section in
                            let rows = selectedOptions.filter { $0.section == section }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Label(section.rawValue, systemImage: section.icon).font(headingFont)
                                    Spacer()
                                    Text(rows.isEmpty ? "None selected" : "\(rows.count) selected")
                                        .contentTransition(reduceMotion ? .identity : .numericText(value: Double(rows.count)))
                                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: rows.count)
                                        .font(supportingFont).foregroundStyle(.secondary)
                                }
                                if !rows.isEmpty {
                                    Text(rows.map(\.title).joined(separator: ", "))
                                        .font(supportingFont).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .systemLiquidGlassBackground(cornerRadius: 20, interactive: false)
                    Text(installer.state == .conflict
                         ? "A different Sorty skill is already here. You'll be asked to confirm its replacement."
                         : selected.isEmpty
                            ? "No app settings will be imported. Any settings already saved in the skill stay in place."
                            : "This import replaces the skill's saved preferences. Sorty keeps a private backup of the previous import.")
                        .font(supportingFont).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Selected Learnings become readable files your agent can use. Credentials, app permissions, and session history stay in Sorty.")
                        .font(supportingFont).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Include the final disclosure and bottom inset, not just the summary card.
                geometry.containerSize.height > 0
                    && geometry.contentSize.height > 0
                    && geometry.contentOffset.y + geometry.containerSize.height
                        >= geometry.contentSize.height + geometry.contentInsets.bottom - 1
            } action: { _, isAtBottom in
                if step == .review && isAtBottom {
                    hasReachedReviewBottom = true
                }
            }
            .frame(maxWidth: 650)
        case .complete:
            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .foregroundStyle(.green)
                    .milestoneEmptyStateSliver(trigger: 1, tint: .green)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Try a first request").font(headingFont)
                    Text(exampleRequest)
                        .font(readingFont)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    CopyButtonWithAnimation(content: exampleRequest, label: "Copy Request", labelFont: readingFont, tint: .primary)
                    .buttonStyle(.sortyBordered(size: .large))
                    .accessibilityIdentifier("skill-import.copy-request")
                }
                .padding(20)
                .systemLiquidGlassBackground(cornerRadius: 20, interactive: false)
                Text(isOnboarding
                     ? "Your skill and imported preferences work without the app. Ask your agent to update them whenever your preferences change."
                     : "Return here to update the skill when preferences change, or tell your agent to update the Sorty skill with your new preferences.")
                    .font(supportingFont).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 600)
            .padding(.vertical, 8)
        }
    }

    private func agentLocationButton(_ agent: SkillAgent?) -> some View {
        let name = agent?.rawValue ?? "Other"
        let isSelected = installer.selectedAgent == agent
        let isDetected = agent.map { installer.detectedAgents.contains($0) } ?? false
        return Button {
            HapticFeedbackManager.shared.tap()
            guard let agent else { chooseLocation(); return }
            guard installer.selectedAgent != agent else { return }
            installer.selectedSkillsDirectory = installer.skillsDirectory(for: agent)
            errorMessage = nil
            Task { await installer.refresh(trackUsage: false, showsCheckingState: false) }
        } label: {
            VStack(spacing: 8) {
                agentLocationIcon(agent)
                    .frame(width: agentIconSize, height: agentIconSize, alignment: .center)
                    .frame(width: 72, height: 72)
                    .systemLiquidGlassBackground(cornerRadius: 18, interactive: true)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(SortyDesignSystem.Colors.resolvedAccent, lineWidth: 2)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(supportingFont)
                                .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                                .padding(6)
                        }
                    }
                    .scaleEffect(!reduceMotion && hoveredAgentLocation == name ? 1.04 : 1)
                    .accessibilityHidden(true)
                Text(name)
                    .font(readingFont.weight(isSelected ? .semibold : .regular))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(agent == nil ? "Choose folder" : isDetected ? "Settings found" : "Standard folder")
                    .font(supportingFont)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredAgentLocation = $0 ? name : nil }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: hoveredAgentLocation)
        .accessibilityLabel(name)
        .accessibilityHint(agent == nil ? "Choose a custom skills folder" : isDetected ? "Settings folder found. Use this agent's skills folder." : "Use this agent's standard skills folder.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("skill-import.agent.\(agent?.rawValue ?? "other")")
    }

    @ViewBuilder
    private func agentLocationIcon(_ agent: SkillAgent?) -> some View {
        if let agent {
            let resource = switch agent {
            case .codex: "SkillAgentCodex"
            case .claudeCode: "SkillAgentClaudeCode"
            case .openCode: colorScheme == .dark ? "SkillAgentOpenCodeDark" : "SkillAgentOpenCodeLight"
            case .pi: "SkillAgentPi"
            }
            // Vector PDFs preserve the SVG paths without AppKit's SVG sizing differences.
            if let image = SortyResources.image(named: "AgentIcons/\(resource)", withExtension: "pdf") {
                Image(nsImage: image)
                    .renderingMode(agent == .codex || agent == .pi ? .template : .original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: agentIconSize, height: agentIconSize)
                    .foregroundStyle(.primary)
            }
        } else if let customFolderIcon {
            Image(nsImage: customFolderIcon)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: agentIconSize, height: agentIconSize)
        } else {
            Image(systemName: "folder")
                .resizable()
                .scaledToFit()
                .frame(width: agentIconSize, height: agentIconSize)
                .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
        }
    }

    private func explanation(_ title: String, icon: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(headingFont)
                Text(detail).font(readingFont).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var locationStatus: some View {
        switch installer.state {
        case .checking, .installing, .replacing, .removing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking location…")
            }
            .accessibilityElement(children: .combine)
        case .installed:
            Label("Skill already installed", systemImage: "checkmark.circle")
        case .conflict:
            Label("Existing skill to review", systemImage: "exclamationmark.triangle")
        case .unavailable:
            VStack(alignment: .leading, spacing: 8) {
                Label("Skill unavailable in this build", systemImage: "exclamationmark.triangle")
                Button("Check Again") { Task { await installer.refresh(trackUsage: false) } }
                    .buttonStyle(.sortyBordered())
            }
        case .available, .failed:
            EmptyView()
        }
    }

    private func importSection(_ section: SkillImportOption.Section) -> some View {
        let rows = options.filter { $0.section == section }
        let identifiers = Set(rows.map(\.selectionID))
        let sectionSelected = !identifiers.isEmpty && identifiers.isSubset(of: selected)
        let selectedCount = identifiers.intersection(selected).count
        let query = optionSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleRows = query.isEmpty ? rows : rows.filter {
            $0.title.localizedStandardContains(query) || $0.detail.localizedStandardContains(query)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(section.rawValue).font(headingFont)
                .contentTransition(reduceMotion ? .identity : .numericText())
                .accessibilityAddTraits(.isHeader)
            Text(sectionExplanation(section))
                .contentTransition(reduceMotion ? .identity : .numericText())
                .font(supportingFont).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if rows.isEmpty {
                if section == .learnings && (learnings.isLocked || learnings.currentProfile == nil) {
                    Button("Unlock Learnings") { Task { await unlockLearnings() } }
                        .buttonStyle(.sortyBordered(size: .large))
                        .accessibilityIdentifier("skill-import.unlock-learnings")
                    Text("Authenticate to choose which Learnings to share.")
                        .font(supportingFont).foregroundStyle(.secondary)
                } else {
                    Text("Nothing saved here yet. You can continue without this section.")
                        .font(supportingFont).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text("\(selectedCount) of \(identifiers.count) selected")
                        .font(supportingFont)
                        .foregroundStyle(.secondary)
                        .contentTransition(reduceMotion ? .identity : .numericText(value: Double(selectedCount)))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedCount)
                    Spacer()
                    Button(sectionSelected ? "Deselect all" : "Select all") {
                        if sectionSelected { selected.subtract(identifiers) }
                        else { selected.formUnion(identifiers) }
                        HapticFeedbackManager.shared.selection()
                    }
                    .buttonStyle(.sortyBordered())
                    .accessibilityHint("Applies to all settings in \(section.rawValue), including hidden search results.")
                    .accessibilityIdentifier("skill-import.select-all.\(section.rawValue)")
                }
                Divider()
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        if expandedSections.contains(section) { expandedSections.remove(section) }
                        else { expandedSections.insert(section) }
                    }
                    HapticFeedbackManager.shared.selection()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expandedSections.contains(section) ? "chevron.down" : "chevron.right")
                            .font(supportingFont.weight(.semibold))
                            .accessibilityHidden(true)
                        Text("Choose individual settings")
                            .font(supportingFont.weight(.medium))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(Color.primary.opacity(isImportDisclosureHovered ? 0.04 : 0))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, -18)
                .onHover { isImportDisclosureHovered = $0 }
                .accessibilityValue(expandedSections.contains(section) ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("skill-import.expand.\(section.rawValue)")
                if expandedSections.contains(section) {
                    VStack(alignment: .leading, spacing: 8) {
                        if rows.count > 8 {
                            TextField("Search settings", text: $optionSearch)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("skill-import.search.\(section.rawValue)")
                        }
                        SkillImportChecklist {
                            VStack(alignment: .leading, spacing: 6) {
                                if visibleRows.isEmpty {
                                    Text("No matching settings")
                                        .font(supportingFont)
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, 8)
                                }
                                ForEach(visibleRows) { option in
                                    importOption(option)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(section)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .systemLiquidGlassBackground(cornerRadius: 20, interactive: false)
    }

    private func importOption(_ option: SkillImportOption) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(option.selectionID) },
            set: { value in
                if value { selected.insert(option.selectionID) }
                else { selected.remove(option.selectionID) }
                HapticFeedbackManager.shared.selection()
            }
        )) {
            VStack(alignment: .leading, spacing: 6) {
                Text(option.title).font(readingFont)
                    .fixedSize(horizontal: false, vertical: true)
                Text(option.detail).font(supportingFont).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 6)
        .accessibilityIdentifier("skill-import.option.\(option.id)")
    }

    private func sectionExplanation(_ section: SkillImportOption.Section) -> String {
        switch section {
        case .preferences: "Naming style, formatting, and rename rules."
        case .exclusions: "Files to leave alone, plus your exceptions."
        case .watchedFolders: "Saved folder paths and instructions. No automatic organizing."
        case .learnings: "Learned rules and corrections, saved as readable files."
        }
    }

    @ViewBuilder
    private var navigation: some View {
        if isOnboarding && step == .complete {
            VStack(spacing: 12) {
                Button("Delete App and Continue with Skill", action: onUseSkill)
                    .buttonStyle(.sortyProminent(size: .large))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Opens a confirmation before uninstalling Sorty. Your installed skill stays in place.")
                    .accessibilityIdentifier("skill-onboarding.use-skill")
                Button("Continue with App", action: onClose)
                    .buttonStyle(.sortyBordered(size: .large))
                    .accessibilityIdentifier("skill-onboarding.continue-app")
                Text("Deleting Sorty removes its app data. You'll review the details before confirming.")
                    .font(supportingFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            setupNavigation
        }
    }

    private var setupNavigation: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                if step != .complete {
                    Button(isOnboarding ? "Continue with App" : "Cancel", action: onClose)
                        .buttonStyle(.sortyBordered(size: .large))
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSaving)
                        .accessibilityIdentifier(isOnboarding ? "skill-onboarding.continue-app" : "skill-import.cancel")
                }
                Spacer()
                if step != setupSteps.first && step != .complete {
                    Button("Back") { changeStep(Step(rawValue: step.rawValue - 1) ?? .welcome) }
                        .buttonStyle(.sortyBordered(size: .large))
                        .disabled(isLoading || isSaving)
                        .accessibilityIdentifier("skill-import.back")
                }
                Button(primaryTitle, action: advance)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: primaryTitle)
                    .buttonStyle(.sortyProminent(size: .large))
                    .modifier(introductionReveal(at: step == .rethink ? 3 : 5))
                    .onHover { isGetStartedHovered = step == .welcome && $0 }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        isLoading || isSaving
                            || ([Step.location, .preferences, .review].contains(step) && !canUseLocation)
                            || (step == .review && !hasReachedReviewBottom)
                    )
                    .accessibilityIdentifier(step == .review ? "skill-import.confirm" : "skill-import.continue")
            }
            .overlay(alignment: .center) {
                if isLoading || isSaving {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(isSaving ? "Importing…" : "Loading settings…")
                    }
                    .accessibilityElement(children: .combine)
                    .allowsHitTesting(false)
                } else if step == .review && !hasReachedReviewBottom {
                    Text("Scroll to the bottom to enable import")
                        .font(supportingFont)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 220)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("skill-import.scroll-hint")
                        .allowsHitTesting(false)
                } else if step == .preferences && !selected.isEmpty {
                    Text("\(selectedOptions.count) selected")
                        .contentTransition(reduceMotion ? .identity : .numericText(value: Double(selectedOptions.count)))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedOptions.count)
                        .font(supportingFont)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var primaryTitle: String {
        switch step {
        case .rethink: "Meet the Skill"
        case .about: "Continue"
        case .welcome: "Get Started"
        case .location, .preferences: "Continue"
        case .review:
            if selected.isEmpty {
                if case .installed = installer.state { "Finish Setup" }
                else { "Install Skill" }
            } else if case .installed = installer.state { "Import Settings" }
            else { "Install and Import" }
        case .complete: "Done"
        }
    }

    private var selectedOptions: [SkillImportOption] {
        options.filter { selected.contains($0.selectionID) }
    }

    private var allSelected: Bool {
        !options.isEmpty && options.allSatisfy { selected.contains($0.selectionID) }
    }

    private var isCheckingLocation: Bool {
        switch installer.state {
        case .checking, .installing, .replacing, .removing: true
        default: false
        }
    }

    private var canUseLocation: Bool {
        !isCheckingLocation && installer.state != .unavailable
    }

    private var exampleRequest: String {
        "Use the Sorty skill to preview how you'd organize my Downloads folder with my preferences."
    }

    private func changeStep(_ next: Step) {
        HapticFeedbackManager.shared.selection()
        if next == .review { hasReachedReviewBottom = false }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            introductionStage = 0
            step = next
        }
    }

    private func advance() {
        switch step {
        case .rethink: changeStep(.about)
        case .about: changeStep(.welcome)
        case .welcome: changeStep(.location)
        case .location: changeStep(.preferences)
        case .preferences: changeStep(.review)
        case .review:
            guard hasReachedReviewBottom else { return }
            if installer.state == .conflict { isConfirmingReplacement = true }
            else { importSelected() }
        case .complete: onClose()
        }
    }

    private func loadOptions() async {
        await settings.loadPersistedState()
        await exclusions.loadPersistedState()
        await watchedFolders.loadPersistedState()
        refreshOptions()
        isLoading = false
    }

    private func refreshOptions() {
        do {
            options = try SkillImportOption.options(
                config: settings.config, openFolder: automation.autoSelectOrganizedFolders,
                exclusions: exclusions.rules, exceptions: exclusions.naturalLanguageExceptions,
                folders: watchedFolders.folders, learnings: learnings.isLocked ? nil : learnings.currentProfile
            )
        } catch { errorMessage = error.localizedDescription }
    }

    private func toggleAll() {
        Task {
            if allSelected { selected.removeAll() }
            else {
                if learnings.isLocked || learnings.currentProfile == nil { await unlockLearnings() }
                selected = Set(options.map(\.selectionID))
            }
            HapticFeedbackManager.shared.selection()
        }
    }

    private func unlockLearnings() async {
        isLoading = true
        defer { isLoading = false }
        guard await SecurityManager.shared.authenticateForSensitiveAction(reason: "Authenticate to import your Learnings into the skill.") else { return }
        await learnings.unlock()
        refreshOptions()
        if let error = learnings.error { errorMessage = error }
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = installer.destinationURL.deletingLastPathComponent()
        panel.message = "Choose the folder where your agent loads skills. Sorty creates a sorty folder inside it."
        panel.prompt = "Choose Skills Folder"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        installer.selectedSkillsDirectory = directory
        customFolderIcon = NSWorkspace.shared.icon(forFile: directory.path)
        errorMessage = nil
        Task { await installer.refresh(trackUsage: false, showsCheckingState: false) }
    }

    private func importSelected() {
        guard step == .review, hasReachedReviewBottom, !isLoading, !isSaving,
              canUseLocation else { return }
        isSaving = true
        onSavingChanged(true)
        errorMessage = nil
        Task {
            defer {
                if isSaving {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { isSaving = false }
                }
                onSavingChanged(false)
            }
            // Keep the setup shell visible while the content shows import progress.
            await Task.yield()
            if selectedOptions.contains(where: { $0.section == .learnings }) {
                guard await SecurityManager.shared.authenticateForSensitiveAction(reason: "Authenticate to import your Learnings into the skill.") else { return }
            }
            if installer.state == .conflict {
                await installer.replace()
            } else if installer.state == .available || installer.state == .failed {
                await installer.install()
            }
            guard case .installed = installer.state else {
                errorMessage = "The skill couldn't be installed here. Go back to check the location, then try again."
                HapticFeedbackManager.shared.error()
                return
            }
            do {
                if !selected.isEmpty {
                    try await installer.importSettings(options: options, selected: selected)
                } else {
                    HapticFeedbackManager.shared.success()
                }
                AccessibilityNotification.Announcement("Your Sorty skill is ready").post()
                if !isOnboarding, let sound = NSSound(named: "Glass") {
                    sound.volume = 0.20
                    sound.play()
                }
                // Reveal the ready page and dismiss progress in one animated update.
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    step = .complete
                    isSaving = false
                }
            } catch {
                errorMessage = error.localizedDescription
                HapticFeedbackManager.shared.error()
            }
        }
    }
}

/// Uses intrinsic layout for short lists and a bounded viewport for overflow.
private struct SkillImportChecklist<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var hasMoreBelow = false

    var body: some View {
        ViewThatFits(in: .vertical) {
            content()
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 4) {
                ScrollView {
                    content()
                }
                .scrollIndicators(.visible)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.containerSize.height > 0
                        && geometry.contentSize.height + geometry.contentInsets.bottom
                            > geometry.contentOffset.y + geometry.containerSize.height + 1
                } action: { _, hasMore in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        hasMoreBelow = hasMore
                    }
                }
                // Keep the viewport height stable as the hint appears and disappears.
                Label("Scroll for more", systemImage: "chevron.down")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .opacity(hasMoreBelow ? 1 : 0)
                    .accessibilityHidden(!hasMoreBelow)
                    .accessibilityIdentifier("skill-import.scroll-hint")
            }
        }
    }
}

private struct SkillIntroductionReveal: ViewModifier {
    let isVisible: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: isVisible)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}
