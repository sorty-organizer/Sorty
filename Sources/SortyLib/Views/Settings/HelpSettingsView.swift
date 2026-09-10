//
//  HelpSettingsView.swift
//  Sorty
//
//  Help, support, and deeplink settings pages
//

import AppKit
import SwiftUI

struct HelpSettingsView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var viewModel: SettingsViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let docsURL = URL(string: "https://github.com/sorty-organizer/Sorty/blob/main/HELP.md")!
    private let issuesURL = URL(string: "https://github.com/sorty-organizer/Sorty/issues")!
    private let changelogURL = URL(string: "https://sorty-organizer.github.io/Sorty/changelog")!
    private let privacyPolicyURL = URL(string: "https://sorty-organizer.github.io/Sorty/privacy-policy")!
    private let termsOfServiceURL = URL(string: "https://sorty-organizer.github.io/Sorty/terms")!
    private let developerURL = URL(string: "https://github.com/shirishpothi")!

    @State private var copiedIssueDetails = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 20) {
            SettingsCard(title: "Support", icon: "questionmark.circle.fill", color: .teal) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        HelpIconLink(
                            title: "Documentation",
                            icon: "doc.text",
                            color: .blue,
                            url: docsURL,
                            focusTarget: .helpDocumentation
                        )

                        HelpIconLink(
                            title: "Report Issue",
                            icon: "exclamationmark.bubble",
                            color: .red,
                            url: issuesURL,
                            focusTarget: .helpReportIssue
                        )

                        HelpIconLink(
                            title: "View Changelog",
                            icon: "clock.arrow.circlepath",
                            color: .purple,
                            url: changelogURL,
                            focusTarget: .helpChangelog
                        )
                    }

                    Divider()

                    HStack(spacing: 10) {
                        HelpIconLink(
                            title: "Privacy Policy",
                            icon: "hand.raised",
                            color: .green,
                            url: privacyPolicyURL,
                            focusTarget: .helpPrivacy
                        )

                        HelpIconLink(
                            title: "Terms of Service",
                            icon: "doc.text",
                            color: .indigo,
                            url: termsOfServiceURL,
                            focusTarget: .helpTerms
                        )
                    }
                    .settingsFocusable(.helpLegal)

                    Divider()

                    HStack(alignment: .center, spacing: 12) {
                        Text("Sorty \(BuildInfo.version) (\(BuildInfo.build))")
                            .font(.subheadline.weight(.medium))

                        Spacer()

                        HStack(spacing: 8) {
                            Text("Built by")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button {
                                open(developerURL)
                            } label: {
                                HStack(spacing: 6) {
                                    GitHubMarkIcon()
                                    Text("Shirish Pothi")
                                }
                            }
                            .buttonStyle(.sortyBordered(intent: .info, size: .small))
                            .trackHoveredURL(developerURL)
                        }
                    }
                }
            }
            .settingsFocusable(.helpSupport)
            .animatedAppearance(delay: 0.1)

            SettingsCard(title: "Support Report", icon: "clipboard", color: .blue) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Copy a privacy-safe report containing app and configuration details. It never includes file names, folder paths, prompts, credentials, or AI responses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        SupportDetailChip(label: "App", value: BuildInfo.fullVersion)
                        SupportDetailChip(label: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                        SupportDetailChip(label: "Arch", value: systemArchitecture)
                    }

                    Button {
                        copyIssueDetails()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: copiedIssueDetails ? "checkmark" : "doc.on.doc")
                                .symbolReplaceTransition(animationValue: copiedIssueDetails)

                            Text(copiedIssueDetails ? "Copied Support Report" : "Copy Support Report")
                                .numericTextTransition(animationValue: copiedIssueDetails)
                        }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.sortyProminent(intent: .secondary))
                    .accessibilityIdentifier("CopyIssueDetailsButton")
                    .accessibilityValue(copiedIssueDetails ? "Copied" : "")
                    .onHover { hovering in
                        if hovering {
                            HapticFeedbackManager.shared.selection()
                        }
                    }
                }
            }
            .settingsFocusable(.helpIssueDetails)
            .animatedAppearance(delay: 0.16)

        }
        .onDisappear {
            copyResetTask?.cancel()
        }
    }

    private func copyIssueDetails() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(issueDetailsText, forType: .string)
        HapticFeedbackManager.shared.success()
        AnalyticsManager.shared.captureFeature(
            feature: "support",
            subfeature: "support_report",
            action: "copied",
            outcome: "success"
        )

        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7)) {
            copiedIssueDetails = true
        }

        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7)) {
                copiedIssueDetails = false
            }
        }
    }

    private func open(_ url: URL) {
        HapticFeedbackManager.shared.tap()
        NSWorkspace.shared.open(url)
    }

    private var issueDetailsText: String {
        let processInfo = ProcessInfo.processInfo
        let config = viewModel.config
        let defaults = UserDefaults.standard
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let memory = ByteCountFormatter.string(fromByteCount: Int64(processInfo.physicalMemory), countStyle: .memory)
        return """
        ### What happened
        <!-- Describe what you expected and what Sorty did instead. -->

        ### Environment
        - Sorty: \(BuildInfo.fullVersion)
        - Commit: \(BuildInfo.shortCommit)
        - Bundle ID: \(bundleID)

        ### System
        - macOS: \(processInfo.operatingSystemVersionString)
        - Architecture: \(systemArchitecture)
        - CPU cores: \(processInfo.activeProcessorCount)
        - Memory: \(memory)
        - Locale: \(Locale.current.identifier)

        ### AI Configuration
        - Provider: \(config.provider.displayName)
        - Model: \(config.model.isEmpty ? config.provider.defaultModel : config.model)
        - Auth method: \(config.authMethod(for: config.provider).displayName)
        - API URL configured: \(yesNo(config.apiURL?.isEmpty == false))
        - Requires API key: \(yesNo(config.requiresAPIKey))
        - Mode: \(config.mode.displayName)
        - Deep scan: \(yesNo(config.enableDeepScan))
        - Vision: \(yesNo(config.enableVision))
        - Vision detail: \(config.effectiveVisionDetailLevel.displayName)
        - Images selected for vision: \(config.limitVisionImages ? "\(config.visionBatchStrategy.displayName), max \(config.visionBatchSize)" : "All images")
        - Smart rename: \(yesNo(config.enableSmartRename))
        - Duplicate detection: \(yesNo(config.detectDuplicates))
        - File tagging: \(yesNo(config.enableFileTagging))
        - Strict exclusions: \(yesNo(config.strictExclusions))
        - Streaming: \(yesNo(config.enableStreaming))
        - Decision explanations: \(yesNo(config.enableReasoning))
        - Reasoning effort: \(config.reasoningEffort.displayName)
        - Request timeout: \(Int(config.requestTimeout))s
        - Resource timeout: \(Int(config.resourceTimeout))s

        ### App Settings
        - Privacy mode: \(yesNo(defaults.bool(forKey: "privacyModeEnabled")))
        - Internet privacy mode: \(yesNo(FeatureFlags.internetPrivacyModeEnabled))
        - Menu bar extra: \(yesNo(defaults.object(forKey: "showMenuBarExtra") as? Bool ?? true))
        - Completed onboarding: \(yesNo(defaults.bool(forKey: "hasCompletedOnboarding")))

        """
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private var systemArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

private struct GitHubMarkIcon: View {
    @SortyHotReload private var hotReload
    var body: some View {
        if let image = NSImage(named: NSImage.Name("GitHub")) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        }
    }
}

struct DeeplinkSettingsView: View {
    @SortyHotReload private var hotReload
    @State private var isShowingEncodingInfo = false

    /// Lets each disclosure own its expanded spacing without adding gaps between collapsed headers.
    private let groupSpacing: CGFloat = 0

    private var groups: [DeeplinkGroup] {
        var organizationEntries = [
            DeeplinkEntry(title: "Organize Folder", url: "sorty://organize?path=/Users/me/Downloads&autostart=true", summary: "Open Organize with an optional path, persona, mode, and autostart.", focusTarget: .deeplinksOrganizeFolder),
            DeeplinkEntry(title: "Duplicates", url: "sorty://duplicates?path=/Users/me/Downloads&autostart=true", summary: "Open Duplicate Files with an optional path and autostart.", focusTarget: .deeplinksDuplicates),
            DeeplinkEntry(title: "Storage", url: "sorty://storage?action=add&path=/Volumes/Archive", summary: "Open storage locations and optionally add a path.", focusTarget: .deeplinksStorage)
        ]

        return [
            DeeplinkGroup(
                title: "Core",
                icon: "app.badge",
                color: .blue,
                entries: [
                    DeeplinkEntry(title: "Open App", url: "sorty://open?path=/Users/me/Downloads", summary: "Bring Sorty to front and optionally preload a directory.", focusTarget: .deeplinksOpenApp),
                    DeeplinkEntry(title: "Settings", url: "sorty://settings?section=notifications", summary: "Open Settings and optionally jump to a section.", focusTarget: .deeplinksSettings),
                    DeeplinkEntry(title: "Help", url: "sorty://help?section=personas", summary: "Open help/support with an optional section.", focusTarget: .deeplinksHelp),
                    DeeplinkEntry(title: "History", url: "sorty://history", summary: "Open organization history.", focusTarget: .deeplinksHistory)
                ]
            ),
            DeeplinkGroup(
                title: "Organization",
                icon: "folder.badge.gearshape",
                color: .green,
                entries: organizationEntries
            ),
            DeeplinkGroup(
                title: "Automation",
                icon: "bolt.circle",
                color: .orange,
                entries: [
                    DeeplinkEntry(title: "Watched Folders", url: "sorty://watched?action=add&path=/Users/me/Projects", summary: "Open watched folders and optionally add a path.", focusTarget: .deeplinksWatchedFolders),
                    DeeplinkEntry(title: "Rules", url: "sorty://rules?action=add&type=pathContains&pattern=.cache", summary: "Open rules/exclusions and optionally add a rule.", focusTarget: .deeplinksRules),
                    DeeplinkEntry(title: "Exclusions", url: "sorty://exclusions?action=add&pattern=node_modules", summary: "Open exclusions and optionally add a pattern.", focusTarget: .deeplinksExclusions),
                    DeeplinkEntry(title: "Persona", url: "sorty://persona?action=create&generate=true&prompt=Design%20files", summary: "Open persona create/select flows with optional generation.", focusTarget: .deeplinksPersona),
                    DeeplinkEntry(title: "Learnings", url: "sorty://learnings?action=stats", summary: "Open Learnings with action: stats, withdraw, export, import, or clear.", focusTarget: .deeplinksLearnings),
                    DeeplinkEntry(title: "Provider Settings", url: "sorty://settings?section=provider", summary: "Jump straight to provider setup.", focusTarget: .deeplinksProviderSettings)
                ]
            ),
            DeeplinkGroup(
                title: "Finder",
                icon: "folder.badge.plus",
                color: .cyan,
                entries: [
                    DeeplinkEntry(title: "Organize with Sorty", url: "sorty://organize?path=/Users/me/Downloads&autostart=true", summary: "Finder service target for organizing a selected folder.", focusTarget: .deeplinksFinderOrganize),
                    DeeplinkEntry(title: "Watch with Sorty", url: "sorty://watched?action=add&path=/Users/me/Projects", summary: "Finder service target for adding a selected folder to watched folders.", focusTarget: .deeplinksFinderWatch),
                    DeeplinkEntry(title: "Exclude from Sorty", url: "sorty://exclude?path=/Users/me/Downloads/Archive", summary: "Finder service target for adding a selected file or folder to exclusions.", focusTarget: .deeplinksFinderExclude),
                    DeeplinkEntry(title: "Finder Settings", url: "sorty://settings?section=finder", summary: "Jump straight to Finder and Services integration.", focusTarget: .deeplinksFinderSettings)
                ]
            )
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Label("Deeplink Library", systemImage: "link.badge.plus")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Button {
                        HapticFeedbackManager.shared.tap()
                        isShowingEncodingInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            HapticFeedbackManager.shared.selection()
                        }
                    }
                    .popover(isPresented: $isShowingEncodingInfo, arrowEdge: .bottom) {
                        Text("If you build a link yourself, URL-encode the folder path and prompt so spaces and special characters work correctly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                            .frame(width: 280, alignment: .leading)
                            .systemLiquidGlassPopover(cornerRadius: 12)
                    }
                    .help("About generating deeplinks")
                    .accessibilityLabel("Deeplink encoding information")
                }

                Text("Copy `sorty://` URLs for Shortcuts, Raycast, AppleScript, shell scripts, and other launchers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: groupSpacing) {
                ForEach(groups) { group in
                    DeeplinkGroupSection(group: group)
                }
            }
        }
    }
}

private struct HelpIconLink: View {
    @SortyHotReload private var hotReload
    let title: String
    let icon: String
    let color: Color
    let url: URL
    let focusTarget: SettingsFocusTarget

    @State private var isHovered = false

    var body: some View {
        Button {
            HapticFeedbackManager.shared.tap()
            NSWorkspace.shared.open(url)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isHovered ? color : .secondary)
                Text(LocalizedStringKey(title))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .padding(.vertical, 8)
            .background(isHovered ? color.opacity(0.14) : Color.secondary.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isHovered ? color.opacity(0.32) : Color.secondary.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .settingsFocusable(
            focusTarget,
            shape: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .trackHoveredURL(url)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering {
                HapticFeedbackManager.shared.selection()
            }
        }
    }
}

private struct SupportDetailChip: View {
    @SortyHotReload private var hotReload
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DeeplinkGroup: Identifiable {
    let title: String
    let icon: String
    let color: Color
    let entries: [DeeplinkEntry]

    var id: String { title }
}

private struct DeeplinkEntry: Identifiable {
    let title: String
    let url: String
    let summary: String
    let focusTarget: SettingsFocusTarget

    var id: String { url }
}

private struct DeeplinkGroupSection: View {
    @SortyHotReload private var hotReload
    let group: DeeplinkGroup

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            Button {
                HapticFeedbackManager.shared.tap()
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Label {
                        Text(LocalizedStringKey(group.title))
                    } icon: {
                        Image(systemName: group.icon)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(group.color)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.entries) { entry in
                        DeeplinkEntryRow(entry: entry, color: group.color)
                            // Rows sit flush in the glass card, so inset the
                            // ring instead of the default outset that suits
                            // padded cards.
                            .settingsFocusable(
                                entry.focusTarget,
                                shape: RoundedRectangle(cornerRadius: 10, style: .continuous),
                                horizontalRingPadding: -6,
                                verticalRingPadding: -4
                            )

                        if entry.id != group.entries.last?.id {
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                }
                .systemLiquidGlassBackground(cornerRadius: 14, interactive: false)
                .transition(.opacity)
            }
        }
    }
}

private struct DeeplinkEntryRow: View {
    @SortyHotReload private var hotReload
    let entry: DeeplinkEntry
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(entry.title))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(LocalizedStringKey(entry.summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 150, maxWidth: 220, alignment: .leading)

            Text(entry.url)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            copyButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var copyButton: some View {
        Button {
            copy(entry.url)
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.semibold))
                .foregroundStyle(copied ? .green : color)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(copied ? .green.opacity(0.14) : color.opacity(0.08))
                )
                .symbolReplaceTransition(animationValue: copied)
        }
        .buttonStyle(.plain)
        .help("Copy \(entry.title) deeplink")
        .accessibilityLabel("Copy \(entry.title) deeplink")
        .accessibilityValue(copied ? "Copied" : "")
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        HapticFeedbackManager.shared.tap()

        copied = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            copied = false
        }
    }
}

#Preview("Help & Support") {
    ScrollView {
        HelpSettingsView()
            .padding()
            .environmentObject(SettingsViewModel())
            .environmentObject(AppState())
    }
    .frame(width: 560)
}

#Preview("Deeplinks") {
    ScrollView {
        DeeplinkSettingsView()
            .padding()
    }
    .frame(width: 620)
}
