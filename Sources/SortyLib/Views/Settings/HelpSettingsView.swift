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
    @EnvironmentObject private var appState: AppState

    private let docsURL = URL(string: "https://github.com/sorty-organizer/Sorty/blob/main/HELP.md")!
    private let changelogURL = URL(string: "https://sorty-organizer.github.io/Sorty/changelog")!
    private let privacyPolicyURL = URL(string: "https://sorty-organizer.github.io/Sorty/privacy-policy")!
    private let termsOfServiceURL = URL(string: "https://sorty-organizer.github.io/Sorty/terms")!
    private let developerURL = URL(string: "https://github.com/shirishpothi")!

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
                            title: "Report Bug",
                            icon: "exclamationmark.bubble",
                            color: .red,
                            focusTarget: .helpReportIssue,
                            action: { appState.showBugReport() }
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


        }
    }

    private func open(_ url: URL) {
        HapticFeedbackManager.shared.tap()
        NSWorkspace.shared.open(url)
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

/// Copyable `sorty://` links grouped by what they open. Example paths use the
/// current user's real folders so a copied link works without editing.
struct DeeplinkSettingsView: View {
    @SortyHotReload private var hotReload
    @Environment(\.settingsFocusTarget) private var focusTarget
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingEncodingInfo = false
    @State private var selectedGroupID = "Open Sorty"
    @State private var expandedEntryID: String?

    private var groups: [DeeplinkGroup] {
        typealias Link = DeeplinkExample
        return [
            DeeplinkGroup(
                title: "Open Sorty",
                icon: "macwindow",
                color: .blue,
                entries: [
                    DeeplinkEntry(title: "Open App", url: Link.url("open", ["path": Link.path("Downloads")]), summary: "Bring Sorty to the front, optionally with a folder selected.", focusTarget: .deeplinksOpenApp),
                    DeeplinkEntry(title: "Settings", url: Link.url("settings", ["section": "notifications"]), summary: "Open Settings, optionally at a section such as general, provider, or privacy.", focusTarget: .deeplinksSettings),
                    DeeplinkEntry(title: "Provider Settings", url: Link.url("settings", ["section": "provider"]), summary: "Jump straight to AI provider setup.", focusTarget: .deeplinksProviderSettings),
                    DeeplinkEntry(title: "Finder Settings", url: Link.url("settings", ["section": "finder"]), summary: "Jump straight to Finder integration.", focusTarget: .deeplinksFinderSettings),
                    DeeplinkEntry(title: "Help", url: Link.url("help", ["section": "personas"]), summary: "Open help, optionally at a topic.", focusTarget: .deeplinksHelp),
                    DeeplinkEntry(title: "History", url: Link.url("history"), summary: "Open organization history.", focusTarget: .deeplinksHistory)
                ]
            ),
            DeeplinkGroup(
                title: "Organize",
                icon: "wand.and.stars",
                color: .green,
                entries: [
                    DeeplinkEntry(title: "Organize Folder", url: Link.url("organize", ["path": Link.path("Downloads"), "autostart": "true"]), summary: "Organize a folder. Also accepts persona and mode.", focusTarget: .deeplinksOrganizeFolder),
                    DeeplinkEntry(title: "Duplicates", url: Link.url("duplicates", ["path": Link.path("Downloads"), "autostart": "true"]), summary: "Scan a folder for duplicate files.", focusTarget: .deeplinksDuplicates),
                    DeeplinkEntry(title: "Persona", url: Link.url("persona", ["action": "create", "generate": "true", "prompt": "Design files"]), summary: "Create or select a persona, optionally generating one from a prompt.", focusTarget: .deeplinksPersona),
                    DeeplinkEntry(title: "Learnings", url: Link.url("learnings", ["action": "stats"]), summary: "Open Learnings. Actions: stats, withdraw, export, import, or clear.", focusTarget: .deeplinksLearnings)
                ]
            ),
            DeeplinkGroup(
                title: "Folders & Rules",
                icon: "folder.badge.gearshape",
                color: .orange,
                entries: [
                    DeeplinkEntry(title: "Watched Folders", url: Link.url("watched", ["action": "add", "path": Link.path("Downloads")]), summary: "Open watched folders, optionally adding a folder.", focusTarget: .deeplinksWatchedFolders),
                    DeeplinkEntry(title: "Storage", url: Link.url("storage", ["action": "add", "path": "/Volumes/Archive"]), summary: "Open storage locations, optionally adding a path.", focusTarget: .deeplinksStorage),
                    DeeplinkEntry(title: "Exclude from Sorty", url: Link.url("exclude", ["path": Link.path("Downloads/Archive")]), summary: "Exclude a specific file or folder from future plans.", focusTarget: .deeplinksFinderExclude),
                    DeeplinkEntry(title: "Exclusions", url: Link.url("exclusions", ["action": "add", "pattern": "node_modules"]), summary: "Open exclusions, optionally adding a name pattern.", focusTarget: .deeplinksExclusions),
                    DeeplinkEntry(title: "Rules", url: Link.url("rules", ["action": "add", "type": "pathContains", "pattern": ".cache"]), summary: "Open exclusion rules, optionally adding a typed rule.", focusTarget: .deeplinksRules)
                ]
            )
        ]
    }

    var body: some View {
        let groups = groups
        let activeGroup = groups.first { $0.id == selectedGroupID } ?? groups[0]

        SettingsCard(title: "Deeplink Library", icon: "link", color: .indigo) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Use these links in Shortcuts, Raycast, AppleScript, or shell scripts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                        Text("Paths must be absolute. Copied links are already URL-encoded; if you build one yourself, encode paths and prompts so spaces and special characters work.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                            .frame(width: 280, alignment: .leading)
                            .systemLiquidGlassPopover(cornerRadius: 12)
                    }
                    .help("About building deeplinks")
                    .accessibilityLabel("Deeplink encoding information")
                }

                Picker("Deeplink group", selection: groupSelection) {
                    ForEach(groups) { group in
                        Text("\(group.title) (\(group.entries.count))").tag(group.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("DeeplinkGroupPicker")

                VStack(spacing: 2) {
                    ForEach(activeGroup.entries) { entry in
                        DeeplinkEntryRow(
                            entry: entry,
                            color: activeGroup.color,
                            isExpanded: expandedEntryID == entry.id
                        ) {
                            toggleExpansion(of: entry)
                        }
                        .settingsFocusable(
                            entry.focusTarget,
                            shape: RoundedRectangle(cornerRadius: 8, style: .continuous),
                            horizontalRingPadding: 2,
                            verticalRingPadding: 2
                        )
                    }
                }
                .id(activeGroup.id)
                .transition(.opacity)
            }
        }
        .onAppear { reveal(focusTarget) }
        .onChange(of: focusTarget) { _, target in reveal(target) }
    }

    private var groupSelection: Binding<String> {
        Binding(
            get: { selectedGroupID },
            set: { newValue in
                guard newValue != selectedGroupID else { return }
                HapticFeedbackManager.shared.selection()
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    selectedGroupID = newValue
                    expandedEntryID = nil
                }
            }
        )
    }

    private func toggleExpansion(of entry: DeeplinkEntry) {
        HapticFeedbackManager.shared.tap()
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88)) {
            expandedEntryID = expandedEntryID == entry.id ? nil : entry.id
        }
    }

    /// Search results land on a specific link: switch to its group and open it.
    private func reveal(_ target: SettingsFocusTarget?) {
        guard let target else { return }
        for group in groups {
            if let entry = group.entries.first(where: { $0.focusTarget == target }) {
                selectedGroupID = group.id
                expandedEntryID = entry.id
                return
            }
        }
    }
}

/// Builds example links with real, correctly encoded values.
private enum DeeplinkExample {
    static let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    static func path(_ relativeToHome: String) -> String {
        (homePath as NSString).appendingPathComponent(relativeToHome)
    }

    /// Query items keep the order they are written in.
    static func url(_ host: String, _ query: KeyValuePairs<String, String> = [:]) -> String {
        var components = URLComponents()
        components.scheme = "sorty"
        components.host = host
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.string ?? "sorty://\(host)"
    }
}

private struct HelpIconLink: View {
    @SortyHotReload private var hotReload
    let title: String
    let icon: String
    let color: Color
    var url: URL? = nil
    let focusTarget: SettingsFocusTarget
    var action: (() -> Void)? = nil

    @State private var isHovered = false

    @ViewBuilder
    var body: some View {
        if let url {
            button.trackHoveredURL(url)
        } else {
            button
        }
    }

    private var button: some View {
        Button {
            HapticFeedbackManager.shared.tap()
            if let action {
                action()
            } else if let url {
                NSWorkspace.shared.open(url)
            }
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

    var id: String { title }
}

/// One line per link; clicking expands it in place to show what it does and
/// the full URL.
private struct DeeplinkEntryRow: View {
    @SortyHotReload private var hotReload
    let entry: DeeplinkEntry
    let color: Color
    let isExpanded: Bool
    let toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var copyFeedback = CopyFeedback()
    @State private var isHovered = false
    private var copied: Bool { copyFeedback.isCopied }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: toggle) {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)

                        Text(LocalizedStringKey(entry.title))
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .frame(width: 140, alignment: .leading)

                        Text(isExpanded ? AttributedString(entry.summary) : styledURL)
                            .font(isExpanded ? .caption : .system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.title)
                .accessibilityHint(isExpanded ? "Hide link details" : "Show link details")

                copyButton
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            if isExpanded {
                Text(styledURL)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.leading, 28)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .background(
            Color.primary.opacity(isExpanded ? 0.05 : (isHovered ? 0.035 : 0)),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    /// Shows the home folder as `~` and colors the destination so the part
    /// that differs between links is easy to scan. Copying uses the full URL.
    private var styledURL: AttributedString {
        let display = entry.url.replacingOccurrences(of: DeeplinkExample.homePath, with: "~")
        var result = AttributedString()

        var scheme = AttributedString("sorty://")
        scheme.foregroundColor = .secondary
        result += scheme

        let remainder = display.dropFirst("sorty://".count)
        let host = remainder.prefix { $0 != "?" }
        var hostText = AttributedString(String(host))
        hostText.foregroundColor = color
        hostText.inlinePresentationIntent = .stronglyEmphasized
        result += hostText

        let query = remainder.dropFirst(host.count)
        if !query.isEmpty {
            var queryText = AttributedString(String(query))
            queryText.foregroundColor = .primary
            result += queryText
        }
        return result
    }

    private var copyButton: some View {
        Button {
            copyFeedback.copy(entry.url, duration: .milliseconds(1250))
            HapticFeedbackManager.shared.success()
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.semibold))
                .foregroundStyle(copied ? .green : color)
                .frame(width: 26, height: 26)
                .background(Circle().fill((copied ? Color.green : color).opacity(isHovered || copied ? 0.16 : 0.08)))
                .symbolReplaceTransition(animationValue: copied)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Copy \(entry.title) deeplink")
        .accessibilityLabel("Copy \(entry.title) deeplink")
        .accessibilityValue(copied ? "Copied" : "")
    }
}

#Preview("Help & About") {
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
