import Foundation
import AppKit
import SwiftUI

struct FocusedInstructionBeamBorder: View {
    @SortyHotReload private var hotReload
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var isWindowVisible = true

    var body: some View {
        SwiftUI.TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: reduceMotion || !active || !isWindowVisible || controlActiveState == .inactive
                    || scenePhase != .active
            )
        ) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate / 1.96

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    AngularGradient(
                        stops: [
                            .init(color: .clear, location: 0.00),
                            .init(color: .clear, location: 0.08),
                            .init(color: Color(red: 0.08, green: 0.80, blue: 1.0).opacity(0.36), location: 0.16),
                            .init(color: Color(red: 0.92, green: 0.16, blue: 0.58).opacity(0.62), location: 0.25),
                            .init(color: .white.opacity(0.88), location: 0.32),
                            .init(color: Color(red: 1.0, green: 0.34, blue: 0.18).opacity(0.54), location: 0.39),
                            .init(color: Color(red: 0.40, green: 0.20, blue: 1.0).opacity(0.36), location: 0.48),
                            .init(color: .clear, location: 0.58),
                            .init(color: .clear, location: 1.00),
                        ],
                        center: .center,
                        angle: .degrees((phase.truncatingRemainder(dividingBy: 1)) * 360)
                    ),
                    lineWidth: 1.2
                )
                .opacity(active ? 0.95 : 0)
                .animation(.easeOut(duration: 0.2), value: active)
        }
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Custom Text Editor with Enter to Submit

/// A TextEditor that treats Cmd+Enter as submit and Enter as new line
struct RotatingInstructionSuggestionEditor: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var selectedRange: NSRange
    let suggestions: [String]
    let onSubmit: () -> Void

    @State private var suggestionIndex = 0
    @State private var isWindowVisible = true
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private struct SuggestionCycleID: Equatable {
        let suggestions: [String]
        let isEmpty: Bool
        let isVisible: Bool
        let isActive: Bool
        let reduceMotion: Bool
        let scenePhase: ScenePhase
    }

    private var currentSuggestion: String {
        suggestions.isEmpty ? "" : suggestions[suggestionIndex % suggestions.count]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SubmittableTextEditor(
                text: $text,
                isFocused: $isFocused,
                selectedRange: $selectedRange,
                onAcceptSuggestion: acceptCurrentSuggestion,
                onSubmit: onSubmit
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 2)

            if text.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Text(currentSuggestion)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .numericTextTransition(animationValue: suggestionIndex)

                    Spacer(minLength: 0)

                    Text("Tab")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Color.secondary.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .accessibilityHidden(true)
                }
                .padding(.leading, 18)
                .padding(.trailing, 10)
                .padding(.vertical, 9)
                .allowsHitTesting(false)
            }
        }
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .onChange(of: suggestions) { _, _ in suggestionIndex = 0 }
        .task(
            id: SuggestionCycleID(
                suggestions: suggestions,
                isEmpty: text.isEmpty,
                isVisible: isWindowVisible,
                isActive: controlActiveState != .inactive,
                reduceMotion: reduceMotion,
                scenePhase: scenePhase
            )
        ) {
            guard text.isEmpty,
                  !reduceMotion,
                  isWindowVisible,
                  controlActiveState != .inactive,
                  scenePhase == .active,
                  suggestions.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7))
                guard !Task.isCancelled else { return }
                suggestionIndex = (suggestionIndex + 1) % suggestions.count
            }
        }
    }

    private func acceptCurrentSuggestion() -> Bool {
        guard text.isEmpty else { return false }
        text = currentSuggestion
        selectedRange = NSRange(location: (currentSuggestion as NSString).length, length: 0)
        HapticFeedbackManager.shared.selection()
        return true
    }
}

struct SubmittableTextEditor: NSViewRepresentable {
    @SortyHotReload private var hotReload
    @Binding var text: String
    var isFocused: Binding<Bool>?
    var selectedRange: Binding<NSRange>?
    var onAcceptSuggestion: (() -> Bool)?
    var onSubmit: () -> Void

    init(
        text: Binding<String>,
        isFocused: Binding<Bool>? = nil,
        selectedRange: Binding<NSRange>? = nil,
        onAcceptSuggestion: (() -> Bool)? = nil,
        onSubmit: @escaping () -> Void
    ) {
        self._text = text
        self.isFocused = isFocused
        self.selectedRange = selectedRange
        self.onAcceptSuggestion = onAcceptSuggestion
        self.onSubmit = onSubmit
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 7)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        context.coordinator.selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: textView,
            queue: .main
        ) { [weak textView, weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated {
                guard let textView, let coordinator else { return }
                coordinator.updateFocusState(for: textView)
                coordinator.updateSelectedRange(from: textView)
            }
        }

        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak textView, weak coordinator = context.coordinator] event in
            guard let tv = textView else { return event }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    coordinator?.updateFocusState(for: tv)
                }
            }

            guard event.type == .keyDown else { return event }
            guard tv.window?.firstResponder === tv else { return event }

            let isReturn = event.keyCode == 36
            let isTab = event.keyCode == 48
            let hasCommand = event.modifierFlags.contains(.command)
            let hasTabModifier = !event.modifierFlags
                .intersection([.command, .option, .control, .shift])
                .isEmpty

            if isReturn && hasCommand {
                context.coordinator.onSubmit()
                return nil
            }

            if isTab, !hasTabModifier, context.coordinator.onAcceptSuggestion?() == true {
                return nil
            }

            return event
        }
        context.coordinator.eventMonitor = monitor

        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            let selectedRanges = selectedRange.map { [NSValue(range: $0.wrappedValue)] } ?? textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        } else if let selectedRange,
                  textView.selectedRange() != selectedRange.wrappedValue,
                  selectedRange.wrappedValue.location + selectedRange.wrappedValue.length <= (textView.string as NSString).length {
            textView.setSelectedRange(selectedRange.wrappedValue)
        }

        context.coordinator.onSubmit = onSubmit
        context.coordinator.onAcceptSuggestion = onAcceptSuggestion
        context.coordinator.isFocused = isFocused
        context.coordinator.selectedRange = selectedRange

        context.coordinator.updateFocusState(for: textView)
        context.coordinator.updateSelectedRange(from: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: isFocused,
            selectedRange: selectedRange,
            onAcceptSuggestion: onAcceptSuggestion,
            onSubmit: onSubmit
        )
    }

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>?
        var selectedRange: Binding<NSRange>?
        var onAcceptSuggestion: (() -> Bool)?
        var onSubmit: () -> Void
        var eventMonitor: Any?
        var selectionObserver: NSObjectProtocol?

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>?,
            selectedRange: Binding<NSRange>?,
            onAcceptSuggestion: (() -> Bool)?,
            onSubmit: @escaping () -> Void
        ) {
            self.text = text
            self.isFocused = isFocused
            self.selectedRange = selectedRange
            self.onAcceptSuggestion = onAcceptSuggestion
            self.onSubmit = onSubmit
        }

        deinit {
            // The coordinator is main-confined; clean up synchronously.
            MainActor.assumeIsolated {
                if let monitor = eventMonitor {
                    NSEvent.removeMonitor(monitor)
                }
                if let selectionObserver {
                    NotificationCenter.default.removeObserver(selectionObserver)
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            updateSelectedRange(from: textView)
        }

        func textDidBeginEditing(_ notification: Notification) {
            isFocused?.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isFocused?.wrappedValue = false
        }

        func updateFocusState(for textView: NSTextView) {
            guard let isFocused else { return }
            let currentlyFocused = textView.window?.firstResponder === textView
            if isFocused.wrappedValue != currentlyFocused {
                isFocused.wrappedValue = currentlyFocused
            }
        }

        func updateSelectedRange(from textView: NSTextView) {
            guard let selectedRange else { return }
            let currentRange = textView.selectedRange()
            if selectedRange.wrappedValue != currentRange {
                selectedRange.wrappedValue = currentRange
            }
        }
    }
}

enum InstructionSuggestionCatalog {
    @MainActor
    static func suggestions(
        for mode: OrganizationMode,
        personaManager: PersonaManager,
        customPersonaStore: CustomPersonaStore
    ) -> [String] {
        let personaSuggestions: [String]
        if let personaID = personaManager.selectedCustomPersonaId,
           let persona = customPersonaStore.customPersonas.first(where: { $0.id == personaID }) {
            personaSuggestions = persona.instructionSuggestions.suggestions(for: mode)
        } else {
            personaSuggestions = []
        }

        var seen = Set<String>()
        return (personaSuggestions + genericSuggestions(for: mode)).filter {
            seen.insert($0).inserted
        }
    }

    private static func genericSuggestions(for mode: OrganizationMode) -> [String] {
        switch mode {
        case .organize:
            return [
                "Use no more than 6 top-level folders and keep the hierarchy two levels deep.",
                "Group files by project, then by year; keep loose files in General.",
                "Separate RAW photos from edited images, then group both by event.",
                "Keep recent work in Active, and move completed projects into an Archive by year.",
                "Keep files with the same project or client name together, regardless of file type.",
                "Put ambiguous files in Review instead of guessing where they belong.",
            ]
        case .organizeAndRename:
            return [
                "Use no more than 6 top-level folders, group by client, and put confirmed dates first.",
                "Group by project in a two-level hierarchy, then rename files with clear dates.",
                "Separate invoices by client, then rename them with the date and vendor.",
                "Keep source files beside their exports, and add Final only when the content confirms it.",
                "Archive completed projects by year, and preserve version numbers when renaming files.",
                "Put ambiguous files in Review, and rename them only from confirmed metadata.",
            ]
        case .renameOnly:
            return [
                "Put dates first, use natural words, and preserve the original file extension.",
                "Rename invoices with the date, vendor, and invoice number.",
                "Use consistent names with spaces, and keep existing version numbers.",
                "Use YYYY-MM-DD for confirmed dates, and leave uncertain dates out.",
                "Remove filler such as copy, untitled, and repeated final labels.",
                "Keep paired RAW and sidecar files on the same base name.",
            ]
        }
    }
}
