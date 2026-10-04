import AppKit
import SwiftUI

struct SkillSetupView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var exclusions: ExclusionRulesManager
    @EnvironmentObject private var watchedFolders: WatchedFoldersManager
    @EnvironmentObject private var learnings: LearningsManager
    @EnvironmentObject private var automation: AutomationManager
    @ObservedObject var installer: CodexSkillInstaller
    let onClose: () -> Void
    let onSavingChanged: (Bool) -> Void

    @State private var step: Step = .welcome
    @State private var activeSection: SkillImportOption.Section = .preferences
    @State private var options: [SkillImportOption] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isConfirmingReplacement = false
    @State private var isGetStartedHovered = false
    @AccessibilityFocusState private var isHeadingFocused: Bool

    private enum Step: Int, CaseIterable {
        case welcome, location, preferences, review, complete

        var title: String {
            switch self {
            case .welcome: "Your Sorty preferences. In your agent."
            case .location: "Choose a skills folder"
            case .preferences: "Choose what your agent should know"
            case .review: "Ready to bring it together?"
            case .complete: "Your skill is ready"
            }
        }

        var explanation: String {
            switch self {
            case .welcome: "The Sorty skill teaches your agent to organize and rename files using the preferences you've saved here."
            case .location: "The default works with Codex. For another agent, choose the folder it uses to load skills."
            case .preferences: "Share the settings that matter to you. Your instructions for each task always take priority."
            case .review: "Check the location and your selection. Importing copies these preferences into the skill and leaves your app settings unchanged."
            case .complete: "Open a new chat in your agent and ask it to use Sorty. Tell it which folder to organize and what you want changed."
            }
        }
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
                    progress: Double(step.rawValue) / Double(Step.complete.rawValue),
                    showsBaseColor: false
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            VStack(spacing: 0) {
                progressRail
                    .padding(.top, 48)
                    .padding(.bottom, step == .preferences ? 16 : 28)
                VStack(spacing: 8) {
                    Text(step.title)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .font(step == .preferences ? .title2.weight(.semibold) : .largeTitle.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($isHeadingFocused)
                    Text(step.explanation)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 590)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, step == .preferences ? 16 : 24)

                Group {
                    if step == .preferences {
                        stepContent
                    } else {
                        ScrollView { stepContent }
                    }
                }
                        .padding(.horizontal, 40)
                        .padding(.vertical, 8)
                        .frame(maxWidth: 880)
                        .frame(maxWidth: .infinity)
                        .id(step)
                        .transition(.opacity)
                .frame(maxHeight: .infinity)
                .disabled(isLoading || isSaving)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
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
        .background {
            OnboardingScreenBackdropBlurPresenter(
                isVisible: !reduceTransparency && controlActiveState != .inactive
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .overlay(alignment: .topLeading) {
            OnboardingScreenEdgeGlowPresenter(
                isVisible: !reduceTransparency && controlActiveState != .inactive
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .accessibilityIdentifier("skill-import.window")
        .task { await loadOptions() }
        .onChange(of: step) { _, _ in
            isHeadingFocused = true
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

    private var progressRail: some View {
        HStack(spacing: 16) {
            ForEach(Array(Step.allCases.prefix(4)), id: \.rawValue) { item in
                HStack(spacing: 8) {
                    Image(systemName: step.rawValue > item.rawValue ? "checkmark.circle.fill" : "\(item.rawValue + 1).circle\(step == item ? ".fill" : "")")
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .accessibilityHidden(true)
                    Text(["About", "Location", "Preferences", "Review"][item.rawValue])
                        .font(.callout.weight(step == item ? .semibold : .regular))
                }
                .foregroundStyle(step.rawValue >= item.rawValue ? Color.primary : Color.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(item.rawValue + 1), \(["About", "Location", "Preferences", "Review"][item.rawValue])")
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
        case .welcome:
            VStack(spacing: 28) {
                ZStack {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.largeTitle)
                        .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                        .opacity(isGetStartedHovered ? 0 : 1)
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .opacity(isGetStartedHovered ? 1 : 0)
                }
                .frame(width: 82, height: 82)
                .systemLiquidGlassBackground(cornerRadius: 24, interactive: false)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isGetStartedHovered)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 22) {
                    explanation("Make it familiar", icon: "textformat", detail: "Bring over your naming style, exclusions, saved folders, and Learnings. You choose exactly what to share.")
                    explanation("Work from a clear plan", icon: "list.bullet.rectangle", detail: "Ask for a preview, organize files, or review exact duplicates. The skill records its moves so it can restore them.")
                    explanation("Keep control of each task", icon: "text.bubble", detail: "Tell your agent which folder to use, whether to rename, and how to organize it. Saved folders don't start background automation.")
                }
                .frame(maxWidth: 570)
            }
            .padding(.vertical, 12)
        case .location:
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(installer.destinationURL.path)
                        .font(.body.monospaced())
                        .accessibilityLabel("Installation path: \(installer.destinationURL.path)")
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        locationStatus
                        Spacer()
                        Button("Choose Folder…", action: chooseLocation)
                            .buttonStyle(.sortyBordered())
                            .accessibilityIdentifier("skill-import.choose-location")
                            .disabled(isCheckingLocation)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .systemLiquidGlassBackground(cornerRadius: 20, interactive: false)
                Text("Nothing is installed until you confirm on the review step.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 640)
            .padding(.vertical, 20)
        case .preferences:
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(SkillImportOption.Section.allCases, id: \.self) { section in
                        Button {
                            HapticFeedbackManager.shared.selection()
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                                activeSection = section
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: section.icon).accessibilityHidden(true)
                                Text(section.rawValue)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                if activeSection == section {
                                    Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
                                }
                            }
                            .font(.callout.weight(activeSection == section ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.sortyBordered(size: .small))
                        .accessibilityAddTraits(activeSection == section ? .isSelected : [])
                        .accessibilityIdentifier("skill-import.section.\(section.rawValue)")
                    }
                    Button(allSelected ? "Deselect All" : "Select All", action: toggleAll)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: allSelected)
                        .buttonStyle(.sortyBordered(size: .small))
                        .padding(.top, 12)
                        .accessibilityIdentifier("skill-import.select-all")
                }
                .frame(width: 190)
                ScrollView {
                    importSection(activeSection)
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .review:
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Install location", systemImage: "folder").font(.headline)
                    Text(installer.destinationURL.path)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    ForEach(SkillImportOption.Section.allCases, id: \.self) { section in
                        let rows = selectedOptions.filter { $0.section == section }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label(section.rawValue, systemImage: section.icon).font(.headline)
                                Spacer()
                                Text(rows.isEmpty ? "None selected" : "\(rows.count) selected")
                                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(rows.count)))
                                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: rows.count)
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            if !rows.isEmpty {
                                Text(rows.map(\.title).joined(separator: ", "))
                                    .font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(24)
                .systemLiquidGlassBackground(cornerRadius: 20, interactive: false)
                Text(installer.state == .conflict
                     ? "A different Sorty skill is already here. You'll be asked to confirm its replacement."
                     : "This import replaces the skill's saved preferences. Sorty keeps a private backup of the previous import.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Selected Learnings become readable files your agent can use. Credentials, app permissions, and session history stay in Sorty.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 650)
        case .complete:
            VStack(spacing: 28) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Try a first request").font(.headline)
                    Text(exampleRequest)
                        .font(.title3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copy Request") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(exampleRequest, forType: .string)
                        HapticFeedbackManager.shared.tap()
                        AccessibilityNotification.Announcement("Request copied").post()
                    }
                    .buttonStyle(.sortyBordered())
                    .accessibilityIdentifier("skill-import.copy-request")
                }
                .padding(28)
                .systemLiquidGlassBackground(cornerRadius: 20, interactive: false)
                Text("You can return here to import updated settings whenever your preferences change.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 600)
            .padding(.vertical, 24)
        }
    }

    private func explanation(_ title: String, icon: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var locationStatus: some View {
        switch installer.state {
        case .checking, .installing, .replacing, .removing:
            ProgressView("Checking location…").controlSize(.small)
        case .installed:
            Label("Skill already installed", systemImage: "checkmark.circle")
        case .conflict:
            Label("Existing skill to review", systemImage: "exclamationmark.triangle")
        case .unavailable:
            VStack(alignment: .leading, spacing: 8) {
                Label("Skill unavailable in this build", systemImage: "exclamationmark.triangle")
                Button("Check Again") { Task { await installer.refresh(trackUsage: false) } }
                    .buttonStyle(.sortyBordered(size: .small))
            }
        case .available, .failed:
            Label("Ready to install", systemImage: "checkmark.circle")
        }
    }

    private func importSection(_ section: SkillImportOption.Section) -> some View {
        let rows = options.filter { $0.section == section }
        let identifiers = Set(rows.map(\.selectionID))
        let sectionSelected = !identifiers.isEmpty && identifiers.isSubset(of: selected)
        return VStack(alignment: .leading, spacing: 12) {
            Text(section.rawValue).font(.headline)
                .contentTransition(reduceMotion ? .identity : .numericText())
                .accessibilityAddTraits(.isHeader)
            Text(sectionExplanation(section))
                .contentTransition(reduceMotion ? .identity : .numericText())
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if rows.isEmpty {
                if section == .learnings && (learnings.isLocked || learnings.currentProfile == nil) {
                    Button("Unlock Learnings") { Task { await unlockLearnings() } }
                        .buttonStyle(.sortyBordered())
                        .accessibilityIdentifier("skill-import.unlock-learnings")
                    Text("Authenticate to choose which Learnings to share.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Nothing saved here yet. You can continue without this section.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Button(sectionSelected ? "Deselect Section" : "Select Section") {
                    if sectionSelected { selected.subtract(identifiers) }
                    else { selected.formUnion(identifiers) }
                    HapticFeedbackManager.shared.selection()
                }
                .buttonStyle(.sortyBordered(size: .small))
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: sectionSelected)
                .accessibilityIdentifier("skill-import.select-all.\(section.rawValue)")
                ForEach(rows) { option in
                    Toggle(isOn: Binding(
                        get: { selected.contains(option.selectionID) },
                        set: { value in
                            if value { selected.insert(option.selectionID) }
                            else { selected.remove(option.selectionID) }
                            HapticFeedbackManager.shared.selection()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(option.title).font(.body)
                            Text(option.detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("skill-import.option.\(option.id)")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .systemLiquidGlassBackground(cornerRadius: 20, interactive: false)
    }

    private func sectionExplanation(_ section: SkillImportOption.Section) -> String {
        switch section {
        case .preferences: "Use your saved naming style, formatting, and rename rules when your agent works on files."
        case .exclusions: "Tell your agent which files to leave alone and which exceptions you've saved."
        case .watchedFolders: "Share saved folder paths and their instructions. Importing these doesn't start automatic organization."
        case .learnings: "Bring over learned rules, corrections, and examples. Selected Learnings are saved as readable files in the skill."
        }
    }

    private var navigation: some View {
        HStack(spacing: 16) {
            if step != .complete {
                Button("Cancel", action: onClose)
                    .buttonStyle(.sortyBordered())
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                    .accessibilityIdentifier("skill-import.cancel")
            }
            if isLoading || isSaving {
                ProgressView(isSaving ? "Importing…" : "Loading settings…").controlSize(.small)
            } else if step == .preferences {
                Text(selected.isEmpty ? "Choose at least one setting" : "\(selectedOptions.count) selected")
                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(selectedOptions.count)))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedOptions.count)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if step != .welcome && step != .complete {
                Button("Back") { changeStep(Step(rawValue: step.rawValue - 1) ?? .welcome) }
                    .buttonStyle(.sortyBordered())
                    .disabled(isLoading || isSaving)
                    .accessibilityIdentifier("skill-import.back")
            }
            Button(primaryTitle, action: advance)
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: primaryTitle)
                .buttonStyle(.sortyProminent())
                .onHover { isGetStartedHovered = step == .welcome && $0 }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isLoading || isSaving
                        || (step != .welcome && step != .complete && !canUseLocation)
                        || ((step == .preferences || step == .review) && selected.isEmpty)
                )
                .accessibilityIdentifier(step == .review ? "skill-import.confirm" : "skill-import.continue")
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .location, .preferences: "Continue"
        case .review:
            if case .installed = installer.state { "Import Settings" }
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
        "Use Sorty to preview how you'd organize my Downloads folder with my imported preferences."
    }

    private func changeStep(_ next: Step) {
        HapticFeedbackManager.shared.selection()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { step = next }
    }

    private func advance() {
        switch step {
        case .welcome: changeStep(.location)
        case .location: changeStep(.preferences)
        case .preferences: changeStep(.review)
        case .review:
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
        errorMessage = nil
        Task { await installer.refresh(trackUsage: false) }
    }

    private func importSelected() {
        isSaving = true
        onSavingChanged(true)
        errorMessage = nil
        Task {
            defer {
                isSaving = false
                onSavingChanged(false)
            }
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
                try await installer.importSettings(options: options, selected: selected)
                AccessibilityNotification.Announcement("Your Sorty skill is ready").post()
                if let sound = NSSound(named: "Glass") {
                    sound.volume = 0.20
                    sound.play()
                }
                changeStep(.complete)
            } catch {
                errorMessage = error.localizedDescription
                HapticFeedbackManager.shared.error()
            }
        }
    }
}
