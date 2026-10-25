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

    private var showsDropZone: Bool { isDropTargeted || isTextDropTargeted }
    @AppStorage("bugReportIncludeDiagnostics") private var includeDiagnostics = true
    /// The user's choice; kept while internet is blocked so it returns when unblocked.
    @State private var wantsSentry = true
    @State private var wantsGitHub = false
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
                Toggle("Send to Sorty's developers", isOn: Binding(
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
        var properties: [String: Any] = [
            "feedback_kind": kind.rawValue,
            "sent_to_sentry": sentry,
            "opened_github": opensGitHub,
            "attachment_count": attachments.count,
            "include_diagnostics": includeDiagnostics,
            "has_email": !email.trimmingCharacters(in: .whitespaces).isEmpty,
        ]
        if kind == .bug {
            properties["report_area"] = area.rawValue
        }
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
                errorMessage = "Sentry is unavailable right now. Turn off sending to developers to use GitHub instead."
                captureSubmit(outcome: "failed", sentry: true)
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
