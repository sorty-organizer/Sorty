//
//  AppCommands.swift
//  Sorty
//
//  Comprehensive menu bar commands with keyboard shortcuts
//

import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

// MARK: - App Commands

public struct AppStateFocusedKey: FocusedValueKey {
    public typealias Value = AppState
}

/// Collects one bug description for a GitHub draft and optional Sentry feedback.
public struct BugReportView: View {
    private let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var analytics = AnalyticsManager.shared
    @AppStorage(NetworkPrivacyPolicy.internetPrivacyModeKey) private var internetPrivacyModeEnabled = false
    @State private var description = ""
    @FocusState private var isDescriptionFocused: Bool
    @State private var area: BugReportArea = .organize
    @State private var sendToSentry = false
    @State private var sentryEventID: String?
    @State private var errorMessage: String?

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    /// The Sentry option is hidden entirely unless anonymous analytics are
    /// allowed. A disabled toggle would still advertise a path that cannot be
    /// used; hiding it keeps the window honest about what is available.
    private var showsSentryOption: Bool {
        analytics.consent == .granted
    }

    private var canSubmitBugFeedback: Bool {
        // Read the stored flag so the toggle refreshes live when Block
        // Internet Connections changes while the window is open.
        _ = internetPrivacyModeEnabled
        return ReliabilityManager.shared.canSubmitBugFeedback
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                    .frame(width: 32)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Report a bug")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("Describe the problem, then review your GitHub issue draft.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text("What happened?")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(description.count)/2,000")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .numericTextTransition(animationValue: description.count)
            }
            TextEditor(text: $description)
                .focused($isDescriptionFocused)
                .font(.body)
                .frame(height: showsSentryOption ? (sendToSentry ? 100 : 340) : 180)
                .padding(4)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                    FocusedInstructionBeamBorder(
                        active: !isDescriptionFocused,
                        cornerRadius: 8,
                        duration: 6
                    )
                }
                .accessibilityIdentifier("BugReportDescription")
                .onChange(of: description) { _, newValue in
                    if newValue.count > 2_000 {
                        description = String(newValue.prefix(2_000))
                    }
                }

            if showsSentryOption {
                Toggle("Also send this description to Sentry (anonymous)", isOn: $sendToSentry)
                    .disabled(!canSubmitBugFeedback)
                    .accessibilityIdentifier("SendBugReportToSentryToggle")

                if sendToSentry {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Area")
                            .font(.subheadline.weight(.semibold))

                        BugReportAreaControl(selection: $area)
                            .frame(maxWidth: .infinity, minHeight: 40)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Anonymous. No account, name, or email. Sentry discards IP addresses and builds no profile.")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            // One grid, not two stacks, so each row stays level even
                            // when a label wraps to a second line.
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                                GridRow {
                                    Text("Sent to Sentry")
                                        .font(.caption.weight(.semibold))
                                    Text("Never sent")
                                        .font(.caption.weight(.semibold))
                                }
                                GridRow {
                                    sentryListRow("The description text you typed")
                                    sentryExcludedRow("Name, email, or attachments")
                                }
                                GridRow {
                                    sentryListRow("Linked event sorty.user_bug_report")
                                    sentryExcludedRow("File names, paths, or contents")
                                }
                                GridRow {
                                    sentryListRow("Sorty version, build, release channel")
                                    sentryExcludedRow("Prompts, AI responses, or API keys")
                                }
                                GridRow {
                                    sentryListRow("macOS version and chip type")
                                    sentryExcludedRow("Screenshots, logs, or raw error text")
                                }
                                GridRow {
                                    Text("Chosen area: \(area.displayName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .gridCellColumns(2)
                                }
                            }
                            .accessibilityIdentifier("BugReportSentryDetails")

                            Text("Check your text for private details before you send it. GitHub opens in your browser as a separate public issue.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                        }
                        .accessibilityIdentifier("BugReportSentryTransparency")
                    }
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                                removal: .opacity
                            )
                    )
                }

                if !canSubmitBugFeedback {
                    Text("Sentry sharing stays off while Block Internet Connections is on. Turn it off in Settings, Privacy & Permissions to share with Sentry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityAddTraits(.isStaticText)
            }

            if !sendToSentry {
                Spacer(minLength: 0)
            }

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(.sortyBordered)
                    .keyboardShortcut(.cancelAction)
                Button("Open GitHub Issue") { openIssue() }
                    .buttonStyle(.sortyProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("OpenGitHubBugIssueButton")
            }
        }
        .padding(24)
        .frame(width: 520, height: showsSentryOption ? 660 : 440, alignment: .top)
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.86),
            value: sendToSentry
        )
        .modifier(WindowGlassBackground())
        .accessibilityIdentifier("BugReportView")
    }

    private func sentryListRow(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        }
    }

    private func sentryExcludedRow(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        }
    }

    private func openIssue() {
        let comment = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var didSubmitToSentry = false
        // An empty description opens the bare GitHub template below. There
        // is no text to send, so Sentry is skipped instead of failing.
        if sendToSentry, showsSentryOption, !comment.isEmpty {
            guard let eventID = ReliabilityManager.shared.submitBugFeedback(
                comment,
                area: area
            ) else {
                errorMessage = "Sentry is unavailable. Turn off Sentry sharing to continue with GitHub."
                return
            }
            sentryEventID = eventID
            sendToSentry = false // Retrying GitHub must not send a duplicate report.
            NotificationManager.shared.showHUDInfo(
                title: "Report queued for Sentry",
                message: "Your bug description is linked to this report.",
                icon: "checkmark.seal.fill",
                iconColor: .mint,
                identifier: "bug-report-sentry-success"
            )
            HapticFeedbackManager.shared.success()
            didSubmitToSentry = true
        }

        var components = URLComponents(string: "https://github.com/sorty-organizer/Sorty/issues/new")!
        if comment.isEmpty {
            components.queryItems = [URLQueryItem(name: "template", value: "bug_report.md")]
        } else {
            var body = "## Bug description\n\n\(comment)\n\n## Steps to reproduce\n\n## Expected behavior\n\n## Actual behavior\n"
            if let sentryEventID {
                body += "\nSentry event ID: `\(sentryEventID)`\n"
            }
            components.queryItems = [
                URLQueryItem(name: "title", value: "[BUG] "),
                URLQueryItem(name: "body", value: body),
            ]
        }

        guard let url = components.url else {
            errorMessage = "GitHub could not open. Try again."
            return
        }
        if didSubmitToSentry {
            onClose()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if !NSWorkspace.shared.open(url) {
                    NotificationManager.shared.showHUDInfo(
                        title: "GitHub could not open",
                        message: "Try opening the bug report again.",
                        icon: "xmark.circle.fill",
                        iconColor: .red
                    )
                }
            }
            return
        }
        guard NSWorkspace.shared.open(url) else {
            errorMessage = "GitHub could not open. Try again."
            return
        }
        HapticFeedbackManager.shared.tap()
        onClose()
    }
}

private struct BugReportAreaControl: NSViewRepresentable {
    @Binding var selection: BugReportArea

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let areas = BugReportArea.allCases
        let symbols = ["folder", "square.on.square", "sparkles", "gearshape"]
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let images = symbols.map { symbol in
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
            let configured = image.withSymbolConfiguration(configuration) ?? image
            configured.isTemplate = true
            return configured
        }
        let control = NSSegmentedControl(
            images: images,
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.areaChanged(_:))
        )
        control.font = .systemFont(ofSize: 11, weight: .medium)
        control.setAccessibilityLabel("Bug report area")
        control.setAccessibilityIdentifier("BugReportAreaPicker")
        control.segmentDistribution = .fillEqually

        if #available(macOS 26.0, *) {
            control.controlSize = .extraLarge
            control.borderShape = .capsule
        } else {
            control.controlSize = .large
        }
        if control.responds(to: NSSelectorFromString("setRole:")) {
            control.setValue(1, forKey: "role") // NSSegmentedControlRoleTabs
        }

        for (index, area) in areas.enumerated() {
            control.setLabel(area.displayName, forSegment: index)
            control.setImageScaling(.scaleNone, forSegment: index)
            control.setToolTip(area.displayName, forSegment: index)
        }
        return control
    }

    func updateNSView(_ nsView: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        nsView.selectedSegment = BugReportArea.allCases.firstIndex(of: selection) ?? 0
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<BugReportArea>

        init(selection: Binding<BugReportArea>) {
            self.selection = selection
        }

        @objc
        func areaChanged(_ sender: NSSegmentedControl) {
            let areas = BugReportArea.allCases
            guard areas.indices.contains(sender.selectedSegment) else { return }
            let area = areas[sender.selectedSegment]
            guard area != selection.wrappedValue else { return }
            selection.wrappedValue = area
            HapticFeedbackManager.shared.selection()
        }
    }
}

public struct OrganizerFocusedKey: FocusedValueKey {
    public typealias Value = FolderOrganizer
}

public extension FocusedValues {
    var appState: AppState? {
        get { self[AppStateFocusedKey.self] }
        set { self[AppStateFocusedKey.self] = newValue }
    }

    var organizer: FolderOrganizer? {
        get { self[OrganizerFocusedKey.self] }
        set { self[OrganizerFocusedKey.self] = newValue }
    }
}

public struct SortyCommands: Commands {
    @FocusedValue(\.appState) private var appState

    private var sidebarItems: [SidebarNavigationItem] {
        SidebarNavigationItem.mainItems
    }

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Sorty", systemImage: "info.circle") {
                appState?.showAbout()
            }
            .disabled(appState == nil)
            
            Button("Check for Updates...", systemImage: "arrow.triangle.2.circlepath") {
                appState?.checkForUpdatesInteractive()
            }
            .disabled(appState == nil)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings...", systemImage: "gearshape") {
                appState?.openSettingsWindow()
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(appState == nil)
        }

        // Replace default New/Open with custom commands
        CommandGroup(replacing: .newItem) {
            Button("New Session", systemImage: "plus.square") {
                appState?.resetSession()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(appState == nil)

            Button("Open Directory...", systemImage: "folder") {
                appState?.requestDirectoryPicker()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(appState == nil)

            Divider()

            Button("Export Results...", systemImage: "square.and.arrow.up") {
                appState?.exportResults()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!(appState?.hasResults ?? false))
        }

        // Edit menu additions
        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Select All Files", systemImage: "checkmark.circle") {
                appState?.selectAllFiles()
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(!(appState?.hasFiles ?? false))
        }

        // View menu - use CommandGroup to add to existing View menu, not create a new one
        CommandGroup(replacing: .sidebar) {
            Button((appState?.showingSidebar ?? true) ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left") {
                appState?.showingSidebar.toggle()
            }
            .keyboardShortcut("\\", modifiers: .command)
            .disabled(appState == nil)
        }
        
        // Navigation commands added to View menu
        CommandGroup(after: .sidebar) {
            Divider()
            
            // Main Views section
            Text("Navigation")
                .font(.caption)

            ForEach(Array(sidebarItems.prefix(9).enumerated()), id: \.element.id) { index, item in
                Button(item.title, systemImage: item.systemImage) {
                    appState?.currentView = item.view
                }
                .keyboardShortcut(Self.commandKeyEquivalent(for: index), modifiers: .command)
                .disabled(appState == nil)
            }
        }

        // Organize menu
        organizationCommands
        // Learnings menu
        CommandMenu("Learnings") {
            Button("Open Dashboard", systemImage: "chart.bar") {
                appState?.currentView = .learnings
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(appState == nil)
            
            Divider()
            
            Button(
                (appState?.isLearningPaused ?? false) ? "Resume Learning" : "Pause Learning",
                systemImage: (appState?.isLearningPaused ?? false) ? "play.circle" : "pause.circle"
            ) {
                appState?.toggleLearning()
            }
            .disabled(appState == nil)
            
            Button("Export Learning Profile...", systemImage: "square.and.arrow.up") {
                appState?.exportLearningsProfile()
            }
            .disabled(appState == nil)
            
            Button("Import Learning Profile...", systemImage: "square.and.arrow.down") {
                appState?.importLearningsProfile()
            }
            .disabled(appState == nil)
        }

        // History menu
        historyCommands
        CommandGroup(replacing: .help) {
            Button("Accreditations", systemImage: "rosette") {
                appState?.showAccreditations(entryPoint: .help)
            }
                .keyboardShortcut("©", modifiers: .command)
                .disabled(appState == nil)

            Button("Internet Access Policy", systemImage: "network") {
                appState?.showInternetAccessPolicy()
            }
            .keyboardShortcut("🌐", modifiers: .command)
            .disabled(appState == nil)

            Divider()

            Button("Sorty Help", systemImage: "questionmark.circle") {
                appState?.showHelp()
            }
            .keyboardShortcut("?", modifiers: .command)
            .disabled(appState == nil)
            
            Link(destination: URL(string: "https://github.com/shirishpothi/Sorty/blob/main/HELP.md")!) { Label("Documentation", systemImage: "book") }
            
            Button("Report Bug", systemImage: "ladybug") {
                appState?.showBugReport()
            }
            .disabled(appState == nil)

            if FeatureFlags.supportDeveloperEnabled {
                Link(destination: URL(string: "https://github.com/sponsors/shirishpothi")!) { Label("Support the Developer", systemImage: "heart") }
            }
            
            Divider()
            
            Button("Restart Onboarding...", systemImage: "sparkles") {
                appState?.showOnboarding()
            }
            .disabled(appState == nil)
            
            Button("Delete All Usage Data...", systemImage: "trash") {
                appState?.requestDeleteUsageDataConfirmation()
            }
            .disabled(appState == nil)
            
            Divider()
            
            Link(destination: URL(string: "https://github.com/shirishpothi/Sorty")!) { Label("GitHub Repository", systemImage: "chevron.left.forwardslash.chevron.right") }

            Button("Uninstall Sorty...", systemImage: "trash") {
                appState?.requestUninstallConfirmation()
            }
            .disabled(appState == nil)

            Divider()

            Button("Thank you for using Sorty", systemImage: "heart.fill") {
                appState?.showThanksForUsingSorty()
            }
            .keyboardShortcut("♥", modifiers: .command)
            .disabled(appState == nil)
        }
    }

    private static func commandKeyEquivalent(for index: Int) -> KeyEquivalent {
        KeyEquivalent(Character("\(index + 1)"))
    }

    private var organizationCommands: some Commands {
        CommandMenu("Organize") {
            Button("Start Organization", systemImage: "play.circle") {
                appState?.startOrganization()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!(appState?.canStartOrganization ?? false))

            Button("Regenerate Organization", systemImage: "arrow.clockwise") {
                appState?.regenerateOrganization()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!(appState?.canRegenerateOrganization ?? false))

            Divider()

            Button("Apply Changes", systemImage: "checkmark.circle.fill") {
                appState?.applyChanges()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!(appState?.canApply ?? false))

            Button("Preview Changes", systemImage: "eye") {
                appState?.previewChanges()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!(appState?.hasCurrentPlan ?? false))

            Divider()

            Button("Cancel", systemImage: "xmark.circle") {
                appState?.cancelOperation()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(!(appState?.isOperationInProgress ?? false))
        }
    }

    private var historyCommands: some Commands {
        CommandMenu("History") {
            Button("Open History", systemImage: "clock") {
                appState?.currentView = .history
            }
            .disabled(appState == nil)

            Divider()

            Menu("Export History", systemImage: "square.and.arrow.up") {
                Button("As CSV") {
                    appState?.exportHistory(format: .csv)
                }

                Button("As JSON") {
                    appState?.exportHistory(format: .json)
                }
            }
            .disabled(appState == nil)

            Button("Import History", systemImage: "square.and.arrow.down") {
                appState?.importHistory()
            }
            .disabled(appState == nil)

            Divider()

            Button("Clear History", systemImage: "trash") {
                appState?.clearHistoryWithConfirmation()
            }
            .disabled(appState == nil)
        }
    }
}

