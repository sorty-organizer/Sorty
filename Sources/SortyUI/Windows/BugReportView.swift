import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit
import QuickLookThumbnailing

/// Collects one piece of feedback (bug, idea, praise, other) for a GitHub
/// draft and, when analytics are allowed, an optional Sentry report.
public struct BugReportView: View {
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
    @State private var isTextDropTargeted = false
    @State private var textHeight: CGFloat = 88
    @State private var textController = FeedbackTextController()

    private var showsDropZone: Bool { isDropTargeted || isTextDropTargeted }
    /// On for every new report; a one-off opt-out shouldn't stick for later reports.
    @State private var includeDiagnostics = true
    /// The user's choice; kept while internet is blocked so it returns when unblocked.
    @State private var wantsGitHub = false
    /// Set after Sentry succeeds (no duplicate on a GitHub retry) or fails (fall back to GitHub).
    @State private var skipsSentry = false
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
        canSubmitBugFeedback && !skipsSentry
    }

    /// GitHub is opt-in, but becomes the only route when Sentry can't be used.
    private var opensGitHub: Bool {
        wantsGitHub || !sendToSentry
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
                        controller: textController,
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
                    Divider()
                        .frame(height: 14)
                    FormatButton(symbol: "list.bullet", help: "Bulleted list (⌘⇧8)") {
                        textController.toggleList(numbered: false)
                    }
                    .keyboardShortcut("8", modifiers: [.command, .shift])
                    .accessibilityIdentifier("BugReportBulletListButton")
                    FormatButton(symbol: "list.number", help: "Numbered list (⌘⇧7)") {
                        textController.toggleList(numbered: true)
                    }
                    .keyboardShortcut("7", modifiers: [.command, .shift])
                    .accessibilityIdentifier("BugReportNumberedListButton")
                    Spacer()
                    Text("\(description.count)/2,000")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .numericTextTransition(animationValue: description.count)
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            }
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
                    VStack(alignment: .leading, spacing: 10) {
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
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        Text("Your text, attachments, and email (if given) go to Sorty's developers via Sentry. Nothing else is identified; IP addresses are discarded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    .accessibilityIdentifier("BugReportSentryTransparency")
                }

                if !canSubmitBugFeedback {
                    Text("Block Internet Connections is on, so feedback can only go to GitHub.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if sendToSentry {
                Toggle("Also open a public GitHub issue", isOn: $wantsGitHub)
                    .accessibilityIdentifier("BugReportAlsoGitHubToggle")
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
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(.sortyBordered)
                    .keyboardShortcut(.cancelAction)
                Button(sendToSentry ? "Send" : "Open GitHub Issue") { openIssue() }
                    .buttonStyle(.sortyProminent)
                    .disabled(sendToSentry && !wantsGitHub && trimmedDescription.isEmpty)
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
        .modifier(WindowGlassBackground())
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
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SortyFeedback-\(UUID().uuidString)", isDirectory: true)
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
                continue
            }
            let size = Self.fileSize(url)
            guard total + size <= Self.maxAttachmentBytes else {
                errorMessage = "\(url.lastPathComponent) doesn't fit. Attachments are limited to 20 MB in total."
                continue
            }
            total += size
            attachments.append(url)
        }
        if skippedDuplicate, errorMessage == nil {
            errorMessage = "That file is already attached."
        }
        HapticFeedbackManager.shared.light()
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

    /// Product analytics for the submit: kind, destinations, and counts only, never the text.
    private func captureSubmit(outcome: String, sentry: Bool) {
        let properties: [String: Any] = [
            "feedback_kind": kind.rawValue,
            "sent_to_sentry": sentry,
            "opened_github": opensGitHub,
            "attachment_count": attachments.count,
            "include_diagnostics": includeDiagnostics,
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

    private func openIssue() {
        let comment = trimmedDescription
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
                errorMessage = "Couldn't reach Sorty's developers. Press Open GitHub Issue to report it there instead."
                skipsSentry = true
                captureSubmit(outcome: "failed", sentry: true)
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
        captureSubmit(outcome: "sent", sentry: didSubmitToSentry)
        guard opensGitHub else {
            onClose()
            return
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Plain-text editor that grows with its content, scrolls past its max height,
/// and turns dropped files or images into attachments instead of inserted text.
private struct FeedbackTextView: NSViewRepresentable {
    let controller: FeedbackTextController
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
        controller.textView = textView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
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

/// Lets the SwiftUI toolbar reach the AppKit text view for list commands.
@MainActor
final class FeedbackTextController {
    weak var textView: NSTextView?

    func toggleList(numbered: Bool) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        FeedbackListEditing.toggleList(in: textView, numbered: numbered)
        HapticFeedbackManager.shared.selection()
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

    private static func replace(_ range: NSRange, with text: String, in textView: NSTextView) {
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
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

    /// Adds list markers to every selected line, or removes them when all
    /// lines already use that list style.
    static func toggleList(in textView: NSTextView, numbered: Bool) {
        let string = textView.string as NSString
        let selection = textView.selectedRange()
        let linesRange = string.lineRange(for: selection)
        var lines = string.substring(with: linesRange).components(separatedBy: "\n")
        let trailingNewline = lines.last == "" && lines.count > 1
        if trailingNewline { lines.removeLast() }

        let allMatch = lines.allSatisfy { line in
            guard let prefix = prefix(of: line) else { return false }
            return (prefix.number != nil) == numbered
        }
        var counter = 0
        let rewritten = lines.map { line -> String in
            let existing = prefix(of: line)
            let body = existing.map { String(line.dropFirst($0.full.count)) } ?? line
            let indent = existing?.indent ?? ""
            if allMatch { return indent + body }
            counter += 1
            return indent + (numbered ? "\(counter). " : "- ") + body
        }
        let replacement = rewritten.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        replace(linesRange, with: replacement, in: textView)
        let caret = linesRange.location + (replacement as NSString).length - (trailingNewline ? 1 : 0)
        textView.setSelectedRange(selection.length == 0 && lines.count == 1
            ? NSRange(location: caret, length: 0)
            : NSRange(location: linesRange.location, length: (replacement as NSString).length))
    }
}

private struct FormatButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(isHovered ? 0.15 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}
