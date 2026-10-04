import AppKit
import SwiftUI

struct SkillSetupView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorScheme) private var colorScheme
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
    @ScaledMetric(relativeTo: .largeTitle) private var agentIconSize: CGFloat = 32
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
            case .location: "Choose Codex, Claude Code, OpenCode, or Pi. You can also choose a custom skills folder."
            case .preferences: "Choose settings to copy into the skill, or import nothing."
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
                    .padding(.top, step == .welcome ? 28 : step == .complete ? 36 : 48)
                    .padding(.bottom, step == .welcome || step == .preferences || step == .complete ? 16 : 28)
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
                .padding(.bottom, step == .welcome || step == .preferences || step == .complete ? 16 : 24)

                Group {
                    if step == .location {
                        ScrollView { stepContent }
                    } else {
                        stepContent
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
            .opacity(isSaving ? 0 : 1)
            .allowsHitTesting(!isSaving)
            .accessibilityHidden(isSaving)

            if isSaving {
                importProgress
                    .zIndex(1)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isSaving)
        .background {
            OnboardingScreenBackdropBlurPresenter(
                isVisible: !isSaving && !reduceTransparency && controlActiveState != .inactive
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

    private var importProgress: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Importing preferences")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($isHeadingFocused)
                Text("Saving your selection to the Sorty skill.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            if reduceMotion {
                Label("Import in progress", systemImage: "arrow.down.doc")
                    .font(.callout)
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
            VStack(spacing: 16) {
                ZStack {
                    Image(systemName: "folder.badge.gearshape")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        // Compensate for the folder badge symbol's uneven optical margins.
                        .offset(x: 2, y: -1)
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
                VStack(alignment: .leading, spacing: 16) {
                    explanation("Make it familiar", icon: "textformat", detail: "Bring over your naming style, exclusions, saved folders, and Learnings. You choose exactly what to share.")
                    explanation("Work from a clear plan", icon: "list.bullet.rectangle", detail: "Ask for a preview, organize files, or review exact duplicates. The skill records its moves so it can restore them.")
                    explanation("Keep control of each task", icon: "text.bubble", detail: "Tell your agent which folder to use, whether to rename, and how to organize it. Saved folders don't start background automation.")
                }
                .frame(maxWidth: 620)
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
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Change Folder…", action: chooseLocation)
                            .buttonStyle(.sortyBordered())
                            .accessibilityIdentifier("skill-import.choose-location")
                            .disabled(isCheckingLocation)
                            .fixedSize()
                    }
                    locationStatus
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
                        Button("Import nothing") {
                            selected.removeAll()
                            HapticFeedbackManager.shared.selection()
                        }
                        .buttonStyle(.sortyBordered(size: .small))
                        .accessibilityHint("Clears all selected settings. Continue to review without importing app settings.")
                        .accessibilityIdentifier("skill-import.import-nothing")
                    }
                    .frame(width: 190)
                    importSection(activeSection)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }
        case .review:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Install location", systemImage: "folder").font(.headline)
                        PrivacySensitivePathText(path: installer.destinationURL.path)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .systemLiquidGlassBackground(cornerRadius: 20, interactive: false)
                    Text(installer.state == .conflict
                         ? "A different Sorty skill is already here. You'll be asked to confirm its replacement."
                         : selected.isEmpty
                            ? "No app settings will be imported. Any settings already saved in the skill stay in place."
                            : "This import replaces the skill's saved preferences. Sorty keeps a private backup of the previous import.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Selected Learnings become readable files your agent can use. Credentials, app permissions, and session history stay in Sorty.")
                        .font(.callout).foregroundStyle(.secondary)
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Try a first request").font(.headline)
                    Text(exampleRequest)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    CopyButtonWithAnimation(content: exampleRequest, label: "Copy Request", labelFont: .body, tint: .primary)
                    .buttonStyle(.sortyBordered())
                    .accessibilityIdentifier("skill-import.copy-request")
                }
                .padding(20)
                .systemLiquidGlassBackground(cornerRadius: 20, interactive: false)
                Text("You can return here to import updated settings whenever your preferences change.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 600, maxHeight: .infinity)
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
                    .frame(width: 64, height: 64)
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
                                .font(.caption)
                                .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                                .padding(6)
                        }
                    }
                    .scaleEffect(!reduceMotion && hoveredAgentLocation == name ? 1.04 : 1)
                    .accessibilityHidden(true)
                Text(name)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                Text(agent == nil ? "Choose folder" : isDetected ? "Settings found" : "Standard folder")
                    .font(.caption2)
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
                    .buttonStyle(.sortyBordered(size: .small))
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
                HStack {
                    Text("\(selectedCount) of \(identifiers.count) selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentTransition(reduceMotion ? .identity : .numericText(value: Double(selectedCount)))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedCount)
                    Spacer()
                    Button(sectionSelected ? "Deselect all" : "Select all") {
                        if sectionSelected { selected.subtract(identifiers) }
                        else { selected.formUnion(identifiers) }
                        HapticFeedbackManager.shared.selection()
                    }
                    .buttonStyle(.sortyBordered(size: .small))
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
                            .font(.caption.weight(.semibold))
                            .accessibilityHidden(true)
                        Text("Choose individual settings")
                            .font(.callout.weight(.medium))
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
                                        .font(.callout)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title).font(.callout)
                Text(option.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 2)
        .accessibilityIdentifier("skill-import.option.\(option.id)")
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
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(isSaving ? "Importing…" : "Loading settings…")
                }
                .accessibilityElement(children: .combine)
            } else if step == .preferences {
                Text(selected.isEmpty ? "No settings will be imported" : "\(selectedOptions.count) selected")
                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(selectedOptions.count)))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedOptions.count)
                    .font(.callout).foregroundStyle(.secondary)
            }
            if step == .review && !hasReachedReviewBottom {
                Text("Scroll to the bottom to enable import")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("skill-import.scroll-hint")
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
                        || (step == .review && !hasReachedReviewBottom)
                )
                .accessibilityIdentifier(step == .review ? "skill-import.confirm" : "skill-import.continue")
        }
    }

    private var primaryTitle: String {
        switch step {
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
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { step = next }
    }

    private func advance() {
        switch step {
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
                isSaving = false
                onSavingChanged(false)
            }
            // Let the progress overlay mount before authentication or import work.
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .opacity(hasMoreBelow ? 1 : 0)
                    .accessibilityHidden(!hasMoreBelow)
                    .accessibilityIdentifier("skill-import.scroll-hint")
            }
        }
    }
}
