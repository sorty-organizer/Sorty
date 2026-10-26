import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit
import QuickLookThumbnailing

/// Collects one piece of feedback (bug, idea, praise, other) for a GitHub
/// draft and, when analytics are allowed, an optional Sentry report.
public struct BugReportView: View {
    private let diagnosticConfig: () -> AIConfig?
    private let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var analytics = AnalyticsManager.shared
    @AppStorage(NetworkPrivacyPolicy.internetPrivacyModeKey) private var internetPrivacyModeEnabled = false
    @State private var description = ""
    @State private var area: BugReportArea = .organize
    @State private var kind: FeedbackKind = .bug
    @State private var email = ""
    @State private var attachments: [URL] = []
    @State private var isDropTargeted = false
    @State private var revealedForGitHub = false
    @State private var isTextDropTargeted = false
    @State private var textHeight: CGFloat = 88

    private var showsDropZone: Bool { isDropTargeted || isTextDropTargeted }
    /// On for every new report; a one-off opt-out shouldn't stick for later reports.
    @State private var includeDiagnostics = true
    /// The user's choice; kept while internet is blocked so it returns when unblocked.
    @State private var wantsGitHub = false
    /// Set after Sentry succeeds (no duplicate on a GitHub retry) or fails (fall back to GitHub).
    @State private var skipsSentry = false
    @State private var sentryEventID: String?
    @State private var errorMessage: String?
    @State private var isSending = false
    @State private var recentIssuesPreview: String?

    /// `diagnosticConfig` supplies the live AI settings for the diagnostic ZIP
    /// attached to Sentry reports; return nil when no main window is open.
    public init(diagnosticConfig: @escaping () -> AIConfig? = { nil }, onClose: @escaping () -> Void) {
        self.diagnosticConfig = diagnosticConfig
        self.onClose = onClose
    }

    /// The Sentry option is hidden entirely unless anonymous analytics are
    /// allowed. A disabled toggle would still advertise a path that cannot be
    /// used; hiding it keeps the window honest about what is available.
    private var showsSentryOption: Bool {
        analytics.consent == .granted
    }

    private var sendToSentry: Bool {
        canSubmitBugFeedback && !skipsSentry
    }

    /// GitHub is opt-in, but becomes the only route when Sentry can't be used.
    private var opensGitHub: Bool {
        wantsGitHub || !sendToSentry
    }

    /// Diagnostics help with bugs and open-ended reports; ideas and praise
    /// don't need them, so those kinds never collect or send any.
    private var offersDiagnostics: Bool {
        kind == .bug || kind == .other
    }

    private var collectsDiagnostics: Bool {
        offersDiagnostics && includeDiagnostics
    }

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmitBugFeedback: Bool {
        // Read the stored flag so the toggle refreshes live when Block
        // Internet Connections changes while the window is open.
        _ = internetPrivacyModeEnabled
        return ReliabilityManager.shared.canSubmitBugFeedback
    }

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
                    FeedbackTextView(
                        text: $description,
                        contentHeight: $textHeight,
                        isDropTargeted: $isTextDropTargeted,
                        onDropFiles: { addAttachments($0) },
                        onDropImage: { data, ext in
                            if let url = Self.saveDroppedImage(data, ext: ext, name: "Image") {
                                addAttachments([url])
                            }
                        }
                    )
                    .frame(height: min(max(textHeight, 88), 200))
                    .accessibilityIdentifier("BugReportDescription")
                    .onChange(of: description) { _, newValue in
                        if newValue.count > 2_000 {
                            description = String(newValue.prefix(2_000))
                            HapticFeedbackManager.shared.error()
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
                                AttachmentChip(url: url) {
                                    attachments.removeAll { $0 == url }
                                    Self.discardStaged(url)
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
            .feedbackCard()
            .overlay {
                if showsDropZone {
                    FeedbackDropZone(
                        isFull: remainingAttachmentBytes <= 0,
                        remainingBytes: remainingAttachmentBytes
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: showsDropZone)
            .animation(.easeInOut(duration: 0.15), value: textHeight)
            .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }

            if showsSentryOption {
                if sendToSentry {
                    HStack(spacing: 12) {
                        // Shown for every kind so switching kinds never changes the layout.
                        Picker("Feature", selection: $area) {
                            ForEach(BugReportArea.allCases, id: \.self) { area in
                                Text(area.displayName).tag(area)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .accessibilityIdentifier("BugReportAreaPicker")
                        // Appears once there's something to reply to.
                        if !trimmedDescription.isEmpty {
                            TextField("Email, if you'd like a reply", text: $email)
                                .textFieldStyle(.roundedBorder)
                                .textContentType(.emailAddress)
                                .accessibilityIdentifier("BugReportEmailField")
                                .transition(.opacity)
                        }
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }

                if !canSubmitBugFeedback {
                    Text("Block Internet Connections is on, so feedback can only go to GitHub.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                // Disabled rather than hidden for ideas and praise: removing the
                // row resizes the window mid-animation when switching kinds.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    FeedbackOptionToggle(
                        title: "Include diagnostics",
                        caption: "Includes app and macOS versions, AI settings, and recent errors with private details removed. We never see your file names, file contents, prompts, or API keys.",
                        isOn: offersDiagnostics ? $includeDiagnostics : .constant(false)
                    )
                    Button("Preview") {
                        HapticFeedbackManager.shared.tap()
                        Task { recentIssuesPreview = await LogManager.shared.recentIssuesPreview() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(!collectsDiagnostics)
                    .help("Show the recent errors this report will include")
                    .accessibilityIdentifier("BugReportPreviewDiagnosticsButton")
                    .popover(isPresented: Binding(
                        get: { recentIssuesPreview != nil },
                        set: { if !$0 { recentIssuesPreview = nil } }
                    ), arrowEdge: .trailing) {
                        ScrollView {
                            Text(recentIssuesPreview ?? "")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .frame(width: 520, height: 280)
                        .systemLiquidGlassPopover(cornerRadius: 12)
                    }
                }
                .disabled(!offersDiagnostics)
                .help(offersDiagnostics
                    ? "Helps reproduce the problem. Sends Sorty and macOS versions, display and power state, AI provider settings, and a log of recent app activity with private details removed. Never file names, paths, file contents, prompts, or API keys."
                    : "Not needed for ideas or praise.")
                .accessibilityIdentifier("BugReportIncludeDiagnosticsToggle")
                if sendToSentry {
                    Divider()
                    FeedbackOptionToggle(
                        title: "Also post on GitHub",
                        caption: "Opens a public, prefilled issue in your browser so others can follow along.",
                        isOn: $wantsGitHub
                    )
                    .accessibilityIdentifier("BugReportAlsoGitHubToggle")
                }
            }
            .padding(12)
            .feedbackCard()

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityAddTraits(.isStaticText)
            }

            HStack(alignment: .center, spacing: 8) {
                if sendToSentry {
                    Label {
                        Text("Sent privately to Sorty's developers through Sentry. Reports are anonymous unless you include your email, and we never store your IP address.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lock.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("BugReportSentryTransparency")
                    .transition(.opacity)
                }
                Spacer(minLength: 12)
                Button("Cancel") { onClose() }
                    .buttonStyle(.sortyBordered)
                    .keyboardShortcut(.cancelAction)
                Button(isSending ? "Sending…" : (sendToSentry ? "Send" : "Open GitHub Issue")) {
                    Task { await openIssue() }
                }
                    .buttonStyle(.sortyProminent)
                    .disabled(isSending || (sendToSentry && !wantsGitHub && trimmedDescription.isEmpty))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("OpenGitHubBugIssueButton")
            }
        }
        .padding(24)
        .frame(width: 560, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.86),
            value: sendToSentry
        )
        .animation(.easeInOut(duration: 0.15), value: wantsGitHub)
        .animation(.easeInOut(duration: 0.18), value: trimmedDescription.isEmpty)
        .animation(.easeInOut(duration: 0.15), value: attachments)
        .onChange(of: area) { _, _ in HapticFeedbackManager.shared.selection() }
        .onChange(of: errorMessage) { _, newValue in
            if newValue != nil { HapticFeedbackManager.shared.error() }
        }
        .modifier(WindowGlassBackground())
        .onAppear { Self.sweepStaleStaging() }
        .onDisappear {
            // Sentry already holds the bytes; only a GitHub drag still needs the files.
            if !revealedForGitHub { attachments.forEach(Self.discardStaged) }
        }
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

    /// Accepts Finder files directly and saves raw image drags (browsers,
    /// Photos, screenshots thumbnails) to a temp file so they attach the same way.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in addAttachments([url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                let typeID = provider.registeredTypeIdentifiers
                    .first { UTType($0)?.conforms(to: .image) == true } ?? UTType.png.identifier
                let ext = UTType(typeID)?.preferredFilenameExtension ?? "png"
                let name = provider.suggestedName ?? "Image"
                provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        if let url = Self.saveDroppedImage(data, ext: ext, name: name) {
                            addAttachments([url])
                        }
                    }
                }
            }
        }
        return accepted
    }

    /// Writes dragged image data (no backing file) to a unique temp file.
    private static func saveDroppedImage(_ data: Data, ext: String, name: String) -> URL? {
        let dir = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent(name).appendingPathExtension(ext)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Adds files while keeping the count and total size within Sentry's limits.
    private func addAttachments(_ urls: [URL]) {
        var total = attachments.reduce(0) { $0 + Self.fileSize($1) }
        var skippedDuplicate = false
        errorMessage = nil
        for url in urls where !url.hasDirectoryPath {
            // Same path, or same bytes under another name (an image dropped twice
            // gets a fresh temp file each time), is the same attachment.
            if attachments.contains(where: { $0 == url || Self.sameContents($0, url) }) {
                skippedDuplicate = true
                if !attachments.contains(url) { Self.discardStaged(url) }
                continue
            }
            let size = Self.fileSize(url)
            guard total + size <= Self.maxAttachmentBytes else {
                errorMessage = "\(url.lastPathComponent) doesn't fit. Attachments are limited to 20 MB in total."
                continue
            }
            guard let copy = Self.stagedCopy(of: url) else {
                errorMessage = "\(url.lastPathComponent) couldn't be read."
                continue
            }
            total += size
            attachments.append(copy)
        }
        if skippedDuplicate, errorMessage == nil {
            errorMessage = "That file is already attached."
        }
        // Errors get their own haptic from the errorMessage observer.
        if errorMessage == nil { HapticFeedbackManager.shared.light() }
    }

    /// Every staged copy lives in its own folder under here, so cleanup is a folder delete.
    private static let stagingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("SortyFeedback", isDirectory: true)

    private static func isStaged(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(stagingRoot.standardizedFileURL.path + "/")
    }

    /// Deletes a staged copy's folder; originals the user picked are never touched.
    private static func discardStaged(_ url: URL) {
        guard isStaged(url) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Removes staging folders left by earlier windows. Copies revealed for a
    /// GitHub drag are kept for an hour so the drag can still finish.
    private static func sweepStaleStaging() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3_600)
        let folders = (try? fm.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: folder) }
        }
    }

    /// Copies an added file into Sorty's temp folder while the sandbox grant
    /// from the drop or open panel is still valid, so sending later can read it.
    private static func stagedCopy(of url: URL) -> URL? {
        if isStaged(url) { return url }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil
        }
    }

    private var remainingAttachmentBytes: Int {
        Self.maxAttachmentBytes - attachments.reduce(0) { $0 + Self.fileSize($1) }
    }

    private static func sameContents(_ lhs: URL, _ rhs: URL) -> Bool {
        fileSize(lhs) == fileSize(rhs)
            && FileManager.default.contentsEqual(atPath: lhs.path, andPath: rhs.path)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Builds the same scrubbed ZIP as Settings › Troubleshooting in a temp
    /// folder; the caller deletes the folder once Sentry has read the bytes.
    /// Returns nil when no AI settings are available, generation fails, or the
    /// ZIP doesn't fit beside the user's files (theirs win), so the report
    /// still sends without it.
    private func makeDiagnosticsZIP() async -> URL? {
        guard let config = diagnosticConfig() else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sorty-BugReport-\(UUID().uuidString)", isDirectory: true)
        let zip = directory.appendingPathComponent("Sorty-Diagnostic.zip")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try await LogManager.shared.generateDiagnosticReport(config: config, at: zip, attachedToFeedback: true)
            guard Self.fileSize(zip) <= remainingAttachmentBytes else {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
            return zip
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    /// Product analytics for the submit: kind, destinations, and counts only, never the text.
    private func captureSubmit(outcome: String, sentry: Bool, github: Bool) {
        let properties: [String: Any] = [
            "feedback_kind": kind.rawValue,
            "sent_to_sentry": sentry,
            "opened_github": github,
            "attachment_count": attachments.count,
            "include_diagnostics": collectsDiagnostics,
            "has_email": !email.trimmingCharacters(in: .whitespaces).isEmpty,
            "report_area": area.rawValue,
        ]
        AnalyticsManager.shared.captureFeature(
            feature: "feedback",
            subfeature: kind.rawValue,
            action: "submit",
            outcome: outcome,
            properties: properties
        )
    }

    private func openIssue() async {
        guard !isSending else { return }
        // Decide before sending: a successful send sets `skipsSentry`, which
        // would otherwise flip `opensGitHub` on and open GitHub uninvited.
        let shouldOpenGitHub = opensGitHub
        let comment = trimmedDescription
        var didSubmitToSentry = false
        // An empty description opens the bare GitHub template below. There
        // is no text to send, so Sentry is skipped instead of failing.
        if sendToSentry, showsSentryOption, !comment.isEmpty {
            isSending = true
            let diagnosticsZIP = collectsDiagnostics ? await makeDiagnosticsZIP() : nil
            isSending = false
            defer {
                if let diagnosticsZIP {
                    try? FileManager.default.removeItem(at: diagnosticsZIP.deletingLastPathComponent())
                }
            }
            guard let eventID = ReliabilityManager.shared.submitBugFeedback(
                comment,
                area: area,
                kind: kind,
                email: email,
                attachmentURLs: attachments + (diagnosticsZIP.map { [$0] } ?? []),
                includeDiagnostics: collectsDiagnostics
            ) else {
                errorMessage = "Couldn't reach Sorty's developers. Press Open GitHub Issue to report it there instead."
                skipsSentry = true
                captureSubmit(outcome: "failed", sentry: true, github: false)
                return
            }
            sentryEventID = eventID
            skipsSentry = true // Retrying GitHub must not send a duplicate report.
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
        captureSubmit(outcome: "sent", sentry: didSubmitToSentry, github: shouldOpenGitHub)
        guard shouldOpenGitHub else {
            onClose()
            return
        }

        var components = URLComponents(string: "https://github.com/sorty-organizer/Sorty/issues/new")!
        if comment.isEmpty && kind == .bug && !collectsDiagnostics {
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
            if collectsDiagnostics {
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
            revealedForGitHub = true
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

private extension View {
    /// Inset surface shared by the message box and the options group.
    func feedbackCard() -> some View {
        background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            }
    }
}

/// Checkbox whose caption sits under the title, aligned with it, and toggles on click too.
private struct FeedbackOptionToggle: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool

    var body: some View {
        // Haptic in the setter so programmatic changes (switching kinds) stay silent.
        Toggle(isOn: Binding(
            get: { isOn },
            set: { isOn = $0; HapticFeedbackManager.shared.selection() }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.checkbox)
    }
}

/// Removable chip showing a Quick Look thumbnail (or file icon) and name.
private struct AttachmentChip: View {
    let url: URL
    let onRemove: () -> Void
    @State private var thumbnail: NSImage?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 130, alignment: .leading)
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                    countStyle: .file
                ))
                .foregroundStyle(.secondary)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(isHovered ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(url.lastPathComponent)")
        }
        .font(.caption)
        .padding(4)
        .padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(isHovered ? 0.18 : 0.12)))
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .help(url.path)
        .task(id: url) {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 28, height: 28),
                scale: scale,
                representationTypes: .thumbnail
            )
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumbnail = representation.nsImage
            }
        }
    }
}

/// Overlay shown while a drag hovers anywhere over the feedback box.
private struct FeedbackDropZone: View {
    let isFull: Bool
    let remainingBytes: Int

    var body: some View {
        let accent = isFull ? Color.secondary : SortyDesignSystem.Colors.resolvedAccent
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.92))
            RoundedRectangle(cornerRadius: 10)
                .fill(accent.opacity(0.08))
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            VStack(spacing: 6) {
                Image(systemName: isFull ? "nosign" : "arrow.down.doc.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(accent)
                Text(isFull ? "20 MB limit reached" : "Drop to attach")
                    .font(.headline)
                Text(isFull
                    ? "Remove a file to add another."
                    : "Images or files · \(ByteCountFormatter.string(fromByteCount: Int64(remainingBytes), countStyle: .file)) left")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .numericTextTransition(animationValue: remainingBytes)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Plain-text editor that grows with its content, scrolls past its max height,
/// and turns dropped files or images into attachments instead of inserted text.
private struct FeedbackTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    @Binding var isDropTargeted: Bool
    let onDropFiles: ([URL]) -> Void
    let onDropImage: (Data, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = DropTextView()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = FeedbackListEditing.bodyFont
        textView.textColor = .labelColor
        textView.typingAttributes = FeedbackListEditing.baseAttributes
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 5
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.string = text
        scrollView.documentView = textView
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            context.coordinator.measure(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        textView.string = text
        context.coordinator.measure(textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FeedbackTextView

        init(_ parent: FeedbackTextView) { self.parent = parent }

        /// Return continues a list (or ends it on an empty item); Tab and
        /// Shift-Tab indent and outdent list items.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                return FeedbackListEditing.continueList(in: textView)
            case #selector(NSResponder.insertTab(_:)):
                return FeedbackListEditing.indent(in: textView, outdent: false)
            case #selector(NSResponder.insertBacktab(_:)):
                return FeedbackListEditing.indent(in: textView, outdent: true)
            default:
                return false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            FeedbackListEditing.restyle(textView)
            parent.text = textView.string
            measure(textView)
        }

        func measure(_ textView: NSTextView) {
            guard let container = textView.textContainer,
                  let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height)
            if abs(height - parent.contentHeight) > 0.5 {
                parent.contentHeight = height
            }
        }

        func setTargeted(_ targeted: Bool) {
            if parent.isDropTargeted != targeted { parent.isDropTargeted = targeted }
        }
    }

    final class DropTextView: NSTextView {
        weak var coordinator: Coordinator?

        private static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

        override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
            super.acceptableDragTypes + [.fileURL] + Self.imageTypes
        }

        private func isAttachmentDrag(_ info: NSDraggingInfo) -> Bool {
            let pasteboard = info.draggingPasteboard
            return pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                || pasteboard.availableType(from: Self.imageTypes) != nil
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard isAttachmentDrag(sender) else { return super.draggingEntered(sender) }
            coordinator?.setTargeted(true)
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            isAttachmentDrag(sender) ? .copy : super.draggingUpdated(sender)
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            coordinator?.setTargeted(false)
            super.draggingExited(sender)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            coordinator?.setTargeted(false)
            super.draggingEnded(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard isAttachmentDrag(sender) else { return super.performDragOperation(sender) }
            coordinator?.setTargeted(false)
            let pasteboard = sender.draggingPasteboard
            if let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL], !urls.isEmpty {
                coordinator?.parent.onDropFiles(urls)
            } else if let data = pasteboard.data(forType: .png) {
                coordinator?.parent.onDropImage(data, "png")
            } else if let data = pasteboard.data(forType: .tiff),
                      let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                coordinator?.parent.onDropImage(png, "png")
            }
            HapticFeedbackManager.shared.success()
            return true
        }
    }
}

/// Markdown-style list editing (`- ` and `1. `), kept as plain text so the
/// report reads the same in Sentry and renders as lists on GitHub.
@MainActor
enum FeedbackListEditing {
    private struct ListPrefix {
        let indent: String
        let marker: String // "- " or "12. "
        var number: Int? { Int(marker.dropLast(2)) }
        var full: String { indent + marker }
    }

    private static func prefix(of line: String) -> ListPrefix? {
        let indent = String(line.prefix { $0 == " " })
        let rest = line.dropFirst(indent.count)
        for bullet in ["- ", "* ", "• "] where rest.hasPrefix(bullet) {
            return ListPrefix(indent: indent, marker: bullet)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3, rest.dropFirst(digits.count).hasPrefix(". ") {
            return ListPrefix(indent: indent, marker: digits + ". ")
        }
        return nil
    }

    static let bodyFont = NSFont.preferredFont(forTextStyle: .body)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor]
    }

    private static func replace(_ range: NSRange, with text: String, in textView: NSTextView) {
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(
            in: range,
            with: NSAttributedString(string: text, attributes: baseAttributes)
        )
        textView.didChangeText()
    }

    /// Styles list lines in place: markers dimmed and right-aligned in a fixed
    /// gutter, wrapped lines hang under the item text. Text itself is unchanged.
    static func restyle(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let string = storage.string as NSString
        let selection = textView.selectedRanges
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: string.length))
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length),
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, _ in
            let line = string.substring(with: lineRange)
            guard let prefix = prefix(of: line) else { return }
            let indentWidth = (prefix.indent as NSString).size(withAttributes: baseAttributes).width
            let markerWidth = (prefix.marker as NSString).size(withAttributes: baseAttributes).width
            let paragraph = NSMutableParagraphStyle()
            paragraph.headIndent = indentWidth + markerWidth
            paragraph.paragraphSpacing = 2
            storage.addAttribute(.paragraphStyle, value: paragraph, range: lineRange)
            let markerRange = NSRange(
                location: lineRange.location + (prefix.indent as NSString).length,
                length: (prefix.marker as NSString).length
            )
            storage.addAttributes([
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.monospacedDigitSystemFont(ofSize: bodyFont.pointSize, weight: .medium),
            ], range: markerRange)
        }
        storage.endEditing()
        textView.selectedRanges = selection
        textView.typingAttributes = baseAttributes
    }

    static func continueList(in textView: NSTextView) -> Bool {
        let string = textView.string as NSString
        let selection = textView.selectedRange()
        let lineRange = string.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = string.substring(with: lineRange).trimmingCharacters(in: .newlines)
        guard let prefix = prefix(of: line) else { return false }

        if line == prefix.full || line == prefix.full.trimmingCharacters(in: .whitespaces) {
            // Empty item: end the list instead of adding another marker.
            let contentRange = NSRange(location: lineRange.location, length: (line as NSString).length)
            replace(contentRange, with: "", in: textView)
            return true
        }
        let marker = prefix.number.map { "\($0 + 1). " } ?? prefix.marker
        textView.insertText("\n" + prefix.indent + marker, replacementRange: selection)
        return true
    }

    static func indent(in textView: NSTextView, outdent: Bool) -> Bool {
        let string = textView.string as NSString
        let lineRange = string.lineRange(for: NSRange(location: textView.selectedRange().location, length: 0))
        let line = string.substring(with: lineRange)
        guard prefix(of: line) != nil else { return false }
        if outdent {
            let spaces = min(line.prefix { $0 == " " }.count, 2)
            guard spaces > 0 else { return true }
            replace(NSRange(location: lineRange.location, length: spaces), with: "", in: textView)
        } else {
            replace(NSRange(location: lineRange.location, length: 0), with: "  ", in: textView)
        }
        return true
    }

}
