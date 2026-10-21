import AppKit
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI

// MARK: - Import
extension SkillSetupView {
    func agentLocationButton(_ agent: SkillAgent?) -> some View {
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
    func agentLocationIcon(_ agent: SkillAgent?) -> some View {
        if let agent {
            let resource = switch agent {
            case .codex: "SkillAgentCodex"
            case .claudeCode: "SkillAgentClaudeCode"
            case .openCode: colorScheme == .dark ? "SkillAgentOpenCodeDark" : "SkillAgentOpenCodeLight"
            case .pi: "SkillAgentPi"
            }
            // Vector PDFs preserve the SVG paths without AppKit's SVG sizing differences.
            if let image = agentIcons[resource] {
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

    func explanation(_ title: String, icon: String, detail: String) -> some View {
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
    var locationStatus: some View {
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
                Button("Check Again") {
                    HapticFeedbackManager.shared.tap()
                    Task { await installer.refresh(trackUsage: false) }
                }
                    .buttonStyle(.sortyBordered())
            }
        case .available, .failed:
            EmptyView()
        }
    }

    func importSection(_ section: SkillImportOption.Section) -> some View {
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
                    Button("Unlock Learnings") {
                        HapticFeedbackManager.shared.tap()
                        Task { await unlockLearnings() }
                    }
                        .buttonStyle(.sortyBordered())
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

    func importOption(_ option: SkillImportOption) -> some View {
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

    func sectionExplanation(_ section: SkillImportOption.Section) -> String {
        switch section {
        case .preferences: "Naming style, formatting, and rename rules."
        case .exclusions: "Files to leave alone, plus your exceptions."
        case .watchedFolders: "Saved folder paths and instructions. No automatic organizing."
        case .learnings: "Learned rules and corrections, saved as readable files."
        }
    }

    @ViewBuilder
    var navigation: some View {
        if isOnboarding && step == .complete {
            VStack(spacing: 12) {
                Button("Delete App and Continue with Skill", action: onUseSkill)
                    .buttonStyle(.sortyPrimary(size: .large))
                    .onboardingBeamBorder(active: isPrimaryActionHovered && !reduceMotion)
                    .onHover { isPrimaryActionHovered = $0 }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Opens a confirmation before uninstalling Sorty. Your installed skill stays in place.")
                    .accessibilityIdentifier("skill-onboarding.use-skill")
                Button("Continue with App", action: closeWithFeedback)
                    .buttonStyle(.sortyPrimary(isSecondary: true))
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

    var finalIntroductionStage: Int { step == .rethink ? 8 : 5 }

    var canAdvanceFromNavigation: Bool {
        !isWaitingForOptions && !isSaving
            && (!isIntroduction || introductionStage >= finalIntroductionStage)
            && (![Step.location, .preferences, .review].contains(step) || canUseLocation)
            && (step != .review || hasReachedReviewBottom)
    }

    var setupNavigation: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                if step != .complete {
                    Button(isOnboarding ? "Continue with App" : "Cancel", action: closeWithFeedback)
                        .buttonStyle(.sortyPrimary(isSecondary: true))
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSaving)
                        .accessibilityIdentifier(isOnboarding ? "skill-onboarding.continue-app" : "skill-import.cancel")
                }
                Spacer()
                if step != setupSteps.first && step != .complete {
                    Button("Back") { changeStep(Step(rawValue: step.rawValue - 1) ?? .welcome) }
                        .buttonStyle(.sortyPrimary(isSecondary: true))
                        .disabled(isWaitingForOptions || isSaving)
                        .accessibilityIdentifier("skill-import.back")
                }
                Button(primaryTitle, action: advance)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: primaryTitle)
                    .buttonStyle(.sortyPrimary(isSecondary: !canAdvanceFromNavigation, size: .large))
                    .opacity(canAdvanceFromNavigation ? 1 : 0.6)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: canAdvanceFromNavigation)
                    .onboardingBeamBorder(
                        active: !reduceMotion && canAdvanceFromNavigation
                            && (step == .welcome || step == .rethink || isPrimaryActionHovered)
                    )
                    .onHover {
                        isPrimaryActionHovered = $0
                        isGetStartedHovered = step == .welcome && $0
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdvanceFromNavigation)
                    .accessibilityIdentifier(step == .review ? "skill-import.confirm" : "skill-import.continue")
            }
            .overlay(alignment: .center) {
                if isWaitingForOptions || importProgressDeadline != nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(isSaving ? "Importing…" : "Loading settings…")
                    }
                    .accessibilityElement(children: .combine)
                    .allowsHitTesting(false)
                } else if !isSaving && step == .review && !hasReachedReviewBottom {
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
}
