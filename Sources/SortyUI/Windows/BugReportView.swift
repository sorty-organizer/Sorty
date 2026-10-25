import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

/// Collects one bug description for a GitHub draft and optional Sentry feedback.
public struct BugReportView: View {
    private let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var analytics = AnalyticsManager.shared
    @AppStorage(NetworkPrivacyPolicy.internetPrivacyModeKey) private var internetPrivacyModeEnabled = false
    @State private var description = ""
    @FocusState private var isDescriptionFocused: Bool
    @State private var area: BugReportArea = .organize
    /// The user's choice; kept while internet is blocked so it returns when unblocked.
    @State private var wantsSentry = false
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

    private var sendToSentry: Bool {
        wantsSentry && canSubmitBugFeedback
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
                Toggle("Also send this description to Sentry (anonymous)", isOn: Binding(
                    get: { sendToSentry },
                    set: { wantsSentry = $0 }
                ))
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
                                    sentryListRow("A linked \"User bug report\" event")
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
            wantsSentry = false // Retrying GitHub must not send a duplicate report.
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
