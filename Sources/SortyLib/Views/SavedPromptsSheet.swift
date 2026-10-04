import Foundation
import AppKit
import SwiftUI
import Combine

struct SavedPromptsSheet: View {
    @SortyHotReload private var hotReload
    @ObservedObject var steeringManager: SteeringPromptManager
    let settingsConfig: AIConfig
    let onApplyPrompt: (String) -> Void

    @State private var editingSession: SavedPromptEditingSession?
    @State private var isEmptyStateVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    init(
        steeringManager: SteeringPromptManager,
        settingsConfig: AIConfig,
        onApplyPrompt: @escaping (String) -> Void
    ) {
        self.steeringManager = steeringManager
        self.settingsConfig = settingsConfig
        self.onApplyPrompt = onApplyPrompt
        _isEmptyStateVisible = State(initialValue: steeringManager.prompts.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Saved Prompts")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    closeSheet()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close saved prompts")
            }
            .padding(20)

            Divider()

            ZStack {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(savedPromptRows) { row in
                            SavedPromptListRow(
                                row: row,
                                editingSession: editingSession?.prompt.id == row.id
                                    ? editingSession
                                    : nil,
                                steeringManager: steeringManager,
                                settingsConfig: settingsConfig,
                                showsPinControls: showsPinControls,
                                onAction: handleRowAction,
                                onCancelEditing: cancelEditing,
                                onSaveEditing: saveEditingPrompt
                            )
                            .transition(savedPromptTransition)
                        }

                        if let editingSession, editingSession.isDraft {
                            SavedPromptEditorCard(
                                session: editingSession,
                                steeringManager: steeringManager,
                                settingsConfig: settingsConfig,
                                onCancel: cancelEditing,
                                onSave: saveEditingPrompt
                            )
                            .transition(savedPromptTransition)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .scrollIndicators(.visible)

                if isEmptyStateVisible && editingSession?.isDraft != true {
                    VStack(spacing: 16) {
                        Spacer()

                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.1))
                                .frame(width: 72, height: 72)

                            Image(systemName: "text.badge.plus")
                                .font(.title)
                                .foregroundStyle(Color.accentColor)
                                .symbolRenderingMode(.hierarchical)
                                .accessibilityHidden(true)
                        }

                        VStack(spacing: 6) {
                            Text("No saved prompts yet")
                                .font(.headline)

                            Text("Save your instructions from the organize view to reuse them.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 300)
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96)),
                            removal: .opacity.combined(with: .scale(scale: 1.02))
                        )
                    )
                }
            }

            Divider()

            // Footer
            HStack {
                Button("Add New Prompt") {
                    addNewPrompt()
                }
                .buttonStyle(.sortyBordered)
                .disabled(editingSession != nil)

                Spacer()

                Button("Done") {
                    closeSheet()
                }
                .buttonStyle(.sortyProminent)
                .keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .frame(width: 520, height: 500)
        .onChange(of: steeringManager.prompts.isEmpty) { _, isEmpty in
            if isEmpty {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24).delay(0.16)) {
                    isEmptyStateVisible = true
                }
            } else {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                    isEmptyStateVisible = false
                }
            }
        }
    }

    private var showsPinControls: Bool {
        steeringManager.prompts.count > 10
    }

    private var savedPromptRows: [SavedPromptRowContent] {
        let rows = steeringManager.prompts.map(SavedPromptRowContent.init)
        guard showsPinControls else { return rows }
        return rows.filter(\.isPinned) + rows.filter { !$0.isPinned }
    }

    private var savedPromptTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.97, anchor: .top))
                .combined(with: .offset(y: -6)),
            removal: .opacity
                .combined(with: .scale(scale: 0.97, anchor: .top))
                .combined(with: .offset(y: -6))
        )
    }

    private func addNewPrompt() {
        guard editingSession == nil else { return }

        var name = "New Prompt"
        var suffix = 2
        while steeringManager.hasPrompt(named: name) {
            name = "New Prompt \(suffix)"
            suffix += 1
        }

        let newPrompt = SavedSteeringPrompt(name: name, prompt: "")
        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82)) {
            editingSession = SavedPromptEditingSession(prompt: newPrompt, isDraft: true)
            isEmptyStateVisible = false
        }
        HapticFeedbackManager.shared.tap()
    }

    private func closeSheet() {
        let didSaveDraft = saveDraftIfNeeded(editingSession)
        editingSession = nil
        dismiss()
        if didSaveDraft {
            HapticFeedbackManager.shared.success()
        }
    }

    @discardableResult
    private func saveDraftIfNeeded(_ session: SavedPromptEditingSession?) -> Bool {
        guard let session, session.isDraft else { return false }
        guard !session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        var prompt = session.prompt
        prompt.name = session.name
        prompt.prompt = session.text
        return steeringManager.addPrompt(prompt)
    }

    private func cancelEditing(_ session: SavedPromptEditingSession) {
        var didSaveDraft = false
        withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.9)) {
            didSaveDraft = saveDraftIfNeeded(session)
            editingSession = nil
            if steeringManager.prompts.isEmpty {
                isEmptyStateVisible = true
            }
        }
        if didSaveDraft {
            HapticFeedbackManager.shared.success()
        }
    }

    private func saveEditingPrompt(_ session: SavedPromptEditingSession) {
        var prompt = session.prompt
        prompt.name = session.name
        prompt.prompt = session.text

        var didSave = false
        withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.9)) {
            didSave = session.isDraft
                ? steeringManager.addPrompt(prompt)
                : steeringManager.updatePrompt(prompt)
            if didSave {
                editingSession = nil
            }
        }
        guard didSave else { return }
        HapticFeedbackManager.shared.success()
    }

    private func handleRowAction(_ action: SavedPromptRowAction) {
        switch action {
        case .use(let id):
            guard let prompt = steeringManager.prompt(id: id) else { return }
            onApplyPrompt(prompt.prompt)
        case .edit(let id):
            beginEditing(id: id)
        case .togglePin(let id):
            togglePin(id: id)
        case .delete(let id):
            deletePrompt(id: id)
        }
    }

    private func beginEditing(id: UUID) {
        guard let prompt = steeringManager.prompt(id: id) else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.9)) {
            editingSession = SavedPromptEditingSession(prompt: prompt)
        }
    }

    private func togglePin(id: UUID) {
        guard showsPinControls, let prompt = steeringManager.prompt(id: id) else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.9)) {
            steeringManager.setPinned(!prompt.isPinned, id: id)
        }
        HapticFeedbackManager.shared.selection()
    }

    private func deletePrompt(id: UUID) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
            steeringManager.deletePrompt(id: id)
        }
        HapticFeedbackManager.shared.tap()
    }
}

@MainActor
private final class SavedPromptEditingSession: ObservableObject {
    let prompt: SavedSteeringPrompt
    let isDraft: Bool

    @Published var name: String
    @Published var text: String
    @Published var isImproving = false
    @Published var showImprovePromptRequest = false
    @Published var improvePromptRequestMessage = ""

    init(prompt: SavedSteeringPrompt, isDraft: Bool = false) {
        self.prompt = prompt
        self.isDraft = isDraft
        name = prompt.name
        text = prompt.prompt
    }
}

private struct SavedPromptRowContent: Identifiable, Equatable {
    let id: UUID
    let name: String
    let preview: String
    let isPinned: Bool

    init(prompt: SavedSteeringPrompt) {
        id = prompt.id
        name = Self.bounded(prompt.name, maximumCharacterCount: 120)
        preview = Self.bounded(prompt.prompt, maximumCharacterCount: 360)
        isPinned = prompt.isPinned
    }

    private static func bounded(_ text: String, maximumCharacterCount: Int) -> String {
        guard let endIndex = text.index(
            text.startIndex,
            offsetBy: maximumCharacterCount,
            limitedBy: text.endIndex
        ), endIndex != text.endIndex else {
            return text
        }

        return String(text[..<endIndex]) + "…"
    }
}

private enum SavedPromptRowAction {
    case use(UUID)
    case edit(UUID)
    case togglePin(UUID)
    case delete(UUID)
}

private struct SavedPromptListRow: View {
    @SortyHotReload private var hotReload
    let row: SavedPromptRowContent
    let editingSession: SavedPromptEditingSession?
    let steeringManager: SteeringPromptManager
    let settingsConfig: AIConfig
    let showsPinControls: Bool
    let onAction: (SavedPromptRowAction) -> Void
    let onCancelEditing: (SavedPromptEditingSession) -> Void
    let onSaveEditing: (SavedPromptEditingSession) -> Void

    var body: some View {
        Group {
            if let editingSession {
                SavedPromptEditorCard(
                    session: editingSession,
                    steeringManager: steeringManager,
                    settingsConfig: settingsConfig,
                    onCancel: onCancelEditing,
                    onSave: onSaveEditing
                )
            } else {
                SavedPromptDisplayCard(
                    row: row,
                    showsPinControls: showsPinControls,
                    onAction: onAction
                )
            }
        }
    }
}

private struct SavedPromptDisplayCard: View {
    @SortyHotReload private var hotReload
    let row: SavedPromptRowContent
    let showsPinControls: Bool
    let onAction: (SavedPromptRowAction) -> Void
    @State private var hoveredButton: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if showsPinControls && row.isPinned {
                        Label("Pinned", systemImage: "pin.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                }

                Text(verbatim: row.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
            }

            HStack(spacing: 8) {
                rowButton(id: "Use", label: "Use \(row.name)", prominent: true) {
                    HapticFeedbackManager.shared.tap()
                    onAction(.use(row.id))
                } label: {
                    Text("Use")
                }

                rowButton(id: "Edit", label: "Edit \(row.name)", prominent: false) {
                    HapticFeedbackManager.shared.tap()
                    onAction(.edit(row.id))
                } label: {
                    Text("Edit")
                }

                if showsPinControls {
                    rowButton(
                        id: row.isPinned ? "Unpin" : "Pin",
                        label: "\(row.isPinned ? "Unpin" : "Pin") \(row.name)",
                        prominent: false
                    ) {
                        HapticFeedbackManager.shared.selection()
                        onAction(.togglePin(row.id))
                    } label: {
                        Text(row.isPinned ? "Unpin" : "Pin")
                    }
                }

                Spacer()

                rowButton(id: "Delete", label: "Delete \(row.name)", prominent: false, destructive: true) {
                    HapticFeedbackManager.shared.tap()
                    onAction(.delete(row.id))
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .savedPromptCardSurface()
    }

    private func rowButton<Label: View>(
        id: String,
        label: String,
        prominent: Bool,
        destructive: Bool = false,
        action: @escaping () -> Void,
        label labelView: () -> Label
    ) -> some View {
        Button(role: destructive ? .destructive : nil, action: action, label: labelView)
            .buttonStyle(SavedPromptRowButtonStyle(isProminent: prominent))
            .accessibilityLabel(label)
            .accessibilityIdentifier("SavedPrompt\(id)Button-\(row.id.uuidString)")
            .scaleEffect(hoveredButton == id ? 1.04 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: hoveredButton)
            .onHover { hovering in
                hoveredButton = hovering ? id : nil
                if hovering {
                    HapticFeedbackManager.shared.selection()
                }
            }
    }
}

private struct SavedPromptRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        let isDestructive = configuration.role == .destructive
        let foregroundColor: Color = if isProminent {
            .white
        } else if isDestructive {
            SortyDesignSystem.Colors.error
        } else {
            .primary
        }

        configuration.label
            .font(.caption.weight(isProminent ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        isProminent
                            ? Color.accentColor.opacity(configuration.isPressed ? 0.78 : 0.9)
                            : Color(NSColor.controlBackgroundColor).opacity(configuration.isPressed ? 0.7 : 0.42)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isProminent
                            ? Color.white.opacity(0.24)
                            : foregroundColor.opacity(0.22),
                        lineWidth: 1
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.52)
            .animation(
                reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82),
                value: configuration.isPressed
            )
    }
}

private struct SavedPromptEditorCard: View {
    @SortyHotReload private var hotReload
    @ObservedObject var session: SavedPromptEditingSession
    let steeringManager: SteeringPromptManager
    let settingsConfig: AIConfig
    let onCancel: (SavedPromptEditingSession) -> Void
    let onSave: (SavedPromptEditingSession) -> Void
    /// Injected for tests (MockAIClient); defaults to the factory in production.
    var injectedAIClient: (any AIClientProtocol)? = nil

    @FocusState private var isEditTextFocused: Bool
    @State private var improveTask: Task<Void, Never>?

    var body: some View {
        let hasDuplicateName = steeringManager.hasPrompt(
            named: session.name,
            excluding: session.prompt.id
        )

        VStack(alignment: .leading, spacing: 12) {
            TextField("Prompt name", text: $session.name)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline.weight(.medium))

            if hasDuplicateName {
                Text("A prompt with this name already exists.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            TextEditor(text: $session.text)
                .font(.body)
                .focused($isEditTextFocused)
                .frame(minHeight: 100, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )

            HStack(spacing: 8) {
                Button {
                    startImprovingInstructions()
                } label: {
                    if session.isImproving {
                        SortyGradientCircularLoader(size: 12, lineWidth: 2.2)
                    } else {
                        Label("Improve with Sorty", systemImage: "wand.and.stars")
                    }
                }
                .buttonStyle(.sortyBordered)
                .controlSize(.small)
                .disabled(
                    session.text.trimmingCharacters(in: .whitespaces).isEmpty
                        || session.isImproving
                )
                .alert(
                    "Sorty needs more detail",
                    isPresented: $session.showImprovePromptRequest
                ) {
                    Button("Edit Instructions") {
                        isEditTextFocused = true
                    }
                } message: {
                    Text(
                        "\(session.improvePromptRequestMessage)\n\nEdit the instructions above, then click Improve again."
                    )
                }

                Spacer()

                Button("Cancel") {
                    onCancel(session)
                }
                .controlSize(.small)

                Button("Save") {
                    onSave(session)
                }
                .buttonStyle(.sortyProminent)
                .controlSize(.small)
                .disabled(
                    session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || hasDuplicateName
                )
            }
        }
        .savedPromptCardSurface()
        .onDisappear {
            improveTask?.cancel()
        }
    }

    private func startImprovingInstructions() {
        improveTask?.cancel()
        improveTask = Task {
            await improveInstructions()
        }
    }

    private func improveInstructions() async {
        let original = session.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return }
        session.isImproving = true
        defer { session.isImproving = false }

        do {
            try Task.checkCancellation()
            let client: any AIClientProtocol
            if let injected = injectedAIClient {
                client = injected
            } else {
                client = try AIClientFactory.createClient(config: settingsConfig)
            }
            let outcome = try await ImproveInstructionsTool.run(
                client: client,
                originalInstructions: original,
                workflow: "organization"
            )
            try Task.checkCancellation()

            switch outcome {
            case .replacement(let replacement):
                session.text = replacement
                session.showImprovePromptRequest = false
                HapticFeedbackManager.shared.success()
            case .needsUserInput(let message):
                session.improvePromptRequestMessage = message
                session.showImprovePromptRequest = true
                HapticFeedbackManager.shared.tap()
            }
        } catch is CancellationError {
            return
        } catch {
            HapticFeedbackManager.shared.error()
        }
    }
}

private extension View {
    func savedPromptCardSurface() -> some View {
        padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
            )
    }

}
