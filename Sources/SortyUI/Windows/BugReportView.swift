import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

/// Collects one piece of feedback (bug, idea, praise, other) for a GitHub
/// draft and, when analytics are allowed, an optional Sentry report.
public struct BugReportView: View {
    private let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var analytics = AnalyticsManager.shared
    @AppStorage(NetworkPrivacyPolicy.internetPrivacyModeKey) private var internetPrivacyModeEnabled = false
    @State private var description = ""
    @FocusState private var isDescriptionFocused: Bool
    @State private var area: BugReportArea = .organize
    @State private var kind: FeedbackKind = .bug
    @State private var email = ""
    @State private var attachments: [URL] = []
    @AppStorage("bugReportIncludeDiagnostics") private var includeDiagnostics = true
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

    private static let maxAttachments = 5
    private static let maxAttachmentBytes = 20 * 1_024 * 1_024

    private var placeholder: String {
        switch kind {
        case .bug: "What happened, and what did you expect?"
        case .idea: "What would make Sorty better for you?"
        case .praise: "What do you love? We read every one."
        case .other: "What's on your mind?"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send feedback")
                .font(.system(size: 22, weight: .semibold, design: .rounded))

            HStack(spacing: 8) {
                ForEach(FeedbackKind.allCases, id: \.self) { option in
                    FeedbackKindChip(title: option.displayName, isSelected: kind == option) {
                        guard kind != option else { return }
                        kind = option
                        HapticFeedbackManager.shared.selection()
                    }
                    .accessibilityIdentifier("FeedbackKind_\(option.rawValue)")
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $description)
                        .focused($isDescriptionFocused)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .accessibilityIdentifier("BugReportDescription")
                        .onChange(of: description) { _, newValue in
                            if newValue.count > 2_000 {
                                description = String(newValue.prefix(2_000))
                            }
                        }
                    if description.isEmpty {
                        Text(placeholder)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }

                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(attachments, id: \.self) { url in
                                AttachmentChip(name: url.lastPathComponent) {
                                    attachments.removeAll { $0 == url }
                                    HapticFeedbackManager.shared.light()
                                }
                            }
                        }
                    }
                    .padding(.bottom, 6)
                    .transition(.opacity)
                }

                HStack {
                    Button {
                        pickAttachments()
                    } label: {
                        Label("Attach files", systemImage: "paperclip")
                    }
                    .buttonStyle(.borderless)
                    .disabled(attachments.count >= Self.maxAttachments)
                    .help(sendToSentry
                        ? "Files are sent with your report."
                        : "Files are revealed in Finder so you can drag them into the GitHub issue.")
                    .accessibilityIdentifier("BugReportAttachFilesButton")
                    Spacer()
                    Text("\(description.count)/2,000")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .numericTextTransition(animationValue: description.count)
                }
            }
            .padding(10)
            .frame(maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
            }

            if showsSentryOption {
                Toggle("Also send to Sorty's developers via Sentry", isOn: Binding(
                    get: { sendToSentry },
                    set: { wantsSentry = $0 }
                ))
                .disabled(!canSubmitBugFeedback)
                .accessibilityIdentifier("SendBugReportToSentryToggle")

                if sendToSentry {
                    VStack(alignment: .leading, spacing: 10) {
                        if kind == .bug {
                            Picker("Area", selection: $area) {
                                ForEach(BugReportArea.allCases, id: \.self) { area in
                                    Text(area.displayName).tag(area)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .accessibilityIdentifier("BugReportAreaPicker")
                        }
                        TextField("Email, if you'd like a reply", text: $email)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.emailAddress)
                            .accessibilityIdentifier("BugReportEmailField")
                        Text("Your text, attachments, and email (if given) go to Sentry. Nothing else is identified; IP addresses are discarded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    .accessibilityIdentifier("BugReportSentryTransparency")
                }

                if !canSubmitBugFeedback {
                    Text("Sentry sharing stays off while Block Internet Connections is on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Include diagnostics", isOn: $includeDiagnostics)
                    .accessibilityIdentifier("BugReportIncludeDiagnosticsToggle")
                Text("Sorty version, macOS version, and chip type. No file names, paths, or contents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityAddTraits(.isStaticText)
            }

            HStack {
                Text(ReliabilityManager.diagnosticsSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(.sortyBordered)
                    .keyboardShortcut(.cancelAction)
                Button(sendToSentry ? "Send" : "Open GitHub Issue") { openIssue() }
                    .buttonStyle(.sortyProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("OpenGitHubBugIssueButton")
            }
        }
        .padding(24)
        .frame(width: 560, height: showsSentryOption ? 620 : 520, alignment: .top)
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.86),
            value: sendToSentry
        )
        .animation(.easeInOut(duration: 0.15), value: attachments)
        .modifier(WindowGlassBackground())
        .onAppear { isDescriptionFocused = true }
        .accessibilityIdentifier("BugReportView")
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose screenshots or files to attach."
        guard panel.runModal() == .OK else { return }
        addAttachments(panel.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in addAttachments([url]) }
            }
        }
        return accepted
    }

    /// Adds files while keeping the count and total size within Sentry's limits.
    private func addAttachments(_ urls: [URL]) {
        var total = attachments.reduce(0) { $0 + Self.fileSize($1) }
        for url in urls where !attachments.contains(url) {
            guard !url.hasDirectoryPath else { continue }
            guard attachments.count < Self.maxAttachments else {
                errorMessage = "You can attach up to \(Self.maxAttachments) files."
                break
            }
            let size = Self.fileSize(url)
            guard total + size <= Self.maxAttachmentBytes else {
                errorMessage = "Attachments are limited to 20 MB in total."
                continue
            }
            total += size
            attachments.append(url)
        }
        HapticFeedbackManager.shared.light()
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func openIssue() {
        let comment = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var didSubmitToSentry = false
        // An empty description opens the bare GitHub template below. There
        // is no text to send, so Sentry is skipped instead of failing.
        if sendToSentry, showsSentryOption, !comment.isEmpty {
            guard let eventID = ReliabilityManager.shared.submitBugFeedback(
                comment,
                area: area,
                kind: kind,
                email: email,
                attachmentURLs: attachments,
                includeDiagnostics: includeDiagnostics
            ) else {
                errorMessage = "Sentry is unavailable. Turn off Sentry sharing to continue with GitHub."
                return
            }
            sentryEventID = eventID
            wantsSentry = false // Retrying GitHub must not send a duplicate report.
            NotificationManager.shared.showHUDInfo(
                title: "Feedback sent",
                message: "Thanks. Your report reached Sorty's developers.",
                icon: "checkmark.seal.fill",
                iconColor: .mint,
                identifier: "bug-report-sentry-success"
            )
            HapticFeedbackManager.shared.success()
            didSubmitToSentry = true
        }

        var components = URLComponents(string: "https://github.com/sorty-organizer/Sorty/issues/new")!
        if comment.isEmpty && kind == .bug && !includeDiagnostics {
            components.queryItems = [URLQueryItem(name: "template", value: "bug_report.md")]
        } else {
            var body: String
            switch kind {
            case .bug:
                body = "## Bug description\n\n\(comment)\n\n## Steps to reproduce\n\n## Expected behavior\n\n## Actual behavior\n"
            case .idea:
                body = "## Idea\n\n\(comment)\n\n## Why it would help\n"
            case .praise, .other:
                body = "\(comment)\n"
            }
            if !attachments.isEmpty {
                body += "\n## Attachments\n\n<!-- Drag the files revealed in Finder here. -->\n"
            }
            if includeDiagnostics {
                body += "\n## Environment\n\n\(ReliabilityManager.diagnosticsSummary)\n"
            }
            if let sentryEventID {
                body += "\nSentry event ID: `\(sentryEventID)`\n"
            }
            let prefix: String = switch kind {
            case .bug: "[BUG] "
            case .idea: "[IDEA] "
            case .praise, .other: "[FEEDBACK] "
            }
            let label: String = switch kind {
            case .bug: "bug"
            case .idea: "enhancement"
            case .praise, .other: "feedback"
            }
            components.queryItems = [
                URLQueryItem(name: "title", value: prefix),
                URLQueryItem(name: "body", value: body),
                URLQueryItem(name: "labels", value: label),
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
        if !attachments.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(attachments)
        }
        HapticFeedbackManager.shared.tap()
        onClose()
    }
}

private struct FeedbackKindChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    Capsule().fill(isSelected
                        ? SortyDesignSystem.Colors.resolvedAccent
                        : Color.secondary.opacity(isHovered ? 0.18 : 0.1))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AttachmentChip: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc")
                .accessibilityHidden(true)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(name)")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
}
