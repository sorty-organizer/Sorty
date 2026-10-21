import AppKit
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI

// MARK: - Steps
extension SkillSetupView {
    @ViewBuilder
    var stepContent: some View {
        switch step {
        case .rethink:
            rethinkStep
        case .about:
            aboutStep
        case .welcome:
            welcomeStep
        case .location:
            locationStep
        case .preferences:
            preferencesStep
        case .review:
            reviewStep
        case .complete:
            completeStep
        }
    }

    private var rethinkStep: some View {
        VStack(spacing: 28) {
            skillIconTransition
                .modifier(introductionReveal(at: 4))
        }
        .frame(maxWidth: 680)
    }

    private var aboutStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            explanation("A simpler interface", icon: "folder.badge.gearshape", detail: "Organize, rename, find exact duplicates, and undo moves in chat. Explain what you want and refine the plan before applying it.")
                .modifier(introductionReveal(at: 3))
            explanation("Bring your preferences", icon: "checklist", detail: "Copy your naming rules, exclusions, saved folders, and Learnings into the skill. You choose what to share.")
                .modifier(introductionReveal(at: 4))
            explanation("Move to the skill", icon: "arrow.triangle.branch", detail: "Once set up, the skill works without Sorty. Keep the app if you use native features like Finder integration or background watching.")
                .modifier(introductionReveal(at: 5))
        }
        .frame(maxWidth: 680)
    }

    private var welcomeStep: some View {
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
    }

    private var locationStep: some View {
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
            Text("Nothing installs until you confirm.")
                .font(supportingFont)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 640)
        .padding(.vertical, 20)
    }

    private var preferencesStep: some View {
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
    }

    private var reviewStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                reviewSummary
                Text(installer.state == .conflict
                     ? "A different Sorty skill is already here. You'll be asked to confirm its replacement."
                     : selected.isEmpty
                        ? "No app settings will be imported. Any settings already saved in the skill stay in place."
                        : "This import replaces the skill's saved preferences. Sorty keeps a backup of the previous import.")
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
    }

    private var completeStep: some View {
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
                .buttonStyle(.sortyBordered())
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

    private var reviewSummary: some View {
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
    }
}
