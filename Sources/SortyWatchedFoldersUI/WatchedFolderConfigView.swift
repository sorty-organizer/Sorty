import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Watched Folder Config View

struct WatchedFolderConfigView: View {
    @SortyHotReload private var hotReload
    let folder: WatchedFolder
    let onOpenFullOrganization: (WatchedFolder) -> Void
    @EnvironmentObject var watchedFoldersManager: WatchedFoldersManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var customPersonaStore: CustomPersonaStore
    @EnvironmentObject var organizer: FolderOrganizer
    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    // Shared singleton: observed, never state-owned.
    @ObservedObject private var steeringManager = SteeringPromptManager.shared

    @State private var customPrompt: String
    @State private var useCustomModel: Bool
    @State private var selectedProvider: AIProvider
    @State private var selectedModel: String
    @State private var selectedMode: OrganizationMode
    @State private var selectedApplyPolicy: WatchedFolderApplyPolicy
    @State private var showModelPicker = false
    @State private var showFolderModelInfo = false
    @State private var showSavedPromptsSheet = false
    @State private var showSavePromptDialog = false
    @State private var savePromptName = ""
    @State private var isImprovingPrompt = false
    @State private var showImprovePromptRequest = false
    @State private var improvePromptRequestMessage = ""
    @State private var isPromptFocused = false
    @State private var instructionSuggestionIndex = 0
    @State private var instructionSelection = NSRange(location: 0, length: 0)
    @State private var showNerdStats = false
    @State private var isWindowVisible = true

    private var shouldCycleInstructionSuggestions: Bool {
        customPrompt.isEmpty && !reduceMotion && isWindowVisible
            && controlActiveState != .inactive && scenePhase == .active
    }

    struct InstructionSuggestionCycleID: Equatable {
        let suggestions: [String]
        let shouldCycle: Bool
    }

    init(
        folder: WatchedFolder,
        onOpenFullOrganization: @escaping (WatchedFolder) -> Void
    ) {
        self.folder = folder
        self.onOpenFullOrganization = onOpenFullOrganization
        _customPrompt = State(initialValue: folder.customPrompt ?? "")
        _useCustomModel = State(initialValue: folder.modelOverride != nil || folder.providerOverride != nil)
        _selectedProvider = State(initialValue: folder.providerOverride ?? .openAI)
        _selectedModel = State(initialValue: folder.modelOverride ?? "")
        _selectedMode = State(initialValue: folder.effectiveOrganizationMode)
        _selectedApplyPolicy = State(initialValue: folder.effectiveApplyPolicy)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            configurationHeader
            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    organizationModeCard
                    applyPolicyCard
                    // Actions Section
                    actionsCard
                    // Custom Instructions Section
                    instructionsCard
                    // AI Model Section
                    modelCard
                    SettingsCard(title: "Recent AI Actions", icon: "sparkles", color: .purple) {
                        WatchedFolderRecentActions(
                            folder: folder,
                            history: organizer.history
                        )
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 680)
        .background(Color(NSColor.windowBackgroundColor))
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .onAppear {
            primeModelSelectionFromGlobalDefaultsIfNeeded()
        }
        .onChange(of: useCustomModel) { _, useOverride in
            if useOverride && selectedModel.isEmpty {
                let defaults = globalAutomationSelection
                selectedProvider = defaults.provider
                selectedModel = defaults.model
            }
        }
        .modelSelectionOverlay(
            isPresented: $showModelPicker,
            currentProvider: selectedProvider,
            currentModel: selectedModel,
            settings: settingsViewModel,
            contextMessage: "Choose the provider and model used only for this watched folder.",
            onSelect: { provider, model, authMethod in
                if let authMethod {
                    settingsViewModel.config.setAuthMethod(authMethod, for: provider)
                }
                selectedProvider = provider
                selectedModel = model
            }
        )
        .sheet(isPresented: $showSavedPromptsSheet) {
            SavedPromptsSheet(
                steeringManager: steeringManager,
                settingsConfig: settingsViewModel.config,
                onApplyPrompt: { prompt in
                    customPrompt = prompt
                    showSavedPromptsSheet = false
                    HapticFeedbackManager.shared.tap()
                }
            )
        }
    }

    private var instructionActions: some View {
        HStack(alignment: .center, spacing: 0) {
            if !trimmedCustomPrompt.isEmpty {
                Button {
                    Task { await improvePromptWithAI() }
                } label: {
                    Label("Improve", systemImage: "wand.and.stars")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.teal)
                .disabled(isImprovingPrompt)
                .help("Improve instructions with Sorty")
                .accessibilityHint("Rewrites this watched folder's prompt to be clearer and more specific")
                .alert("Sorty needs more detail", isPresented: $showImprovePromptRequest) {
                    Button("Edit Instructions") {
                        isPromptFocused = true
                    }
                } message: {
                    Text("\(improvePromptRequestMessage)\n\nEdit the instructions above, then click Improve again.")
                }

                Button {
                    savePromptName = ""
                    showSavePromptDialog.toggle()
                } label: {
                    Label("Save", systemImage: "bookmark")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .help("Save current instructions for reuse")
                .accessibilityHint("Stores this prompt in your saved prompts list")
                .popover(isPresented: $showSavePromptDialog) {
                    savePromptPopover
                }
            }

            Button {
                showSavedPromptsSheet.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                        .frame(width: 18)
                        .accessibilityHidden(true)

                    Text(
                        steeringManager.prompts.isEmpty
                            ? "Saved Prompts"
                            : "Saved Prompts (\(steeringManager.prompts.count))"
                    )
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .systemLiquidGlassBackground(cornerRadius: 12)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            SortyDesignSystem.Colors.resolvedAccent.opacity(0.18),
                            lineWidth: 1
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Open your saved instruction prompts")
            .accessibilityHint("View, edit, and apply saved prompts")

            Spacer()

            CompactPersonaPicker()
        }
        .font(.caption2)
        .foregroundStyle(.quaternary)
    }

    private var savePromptPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Prompt")
                .font(.headline)

            TextField("Prompt name", text: $savePromptName)
                .textFieldStyle(.roundedBorder)

            if steeringManager.hasPrompt(named: savePromptName) {
                Text("A prompt with this name already exists.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    showSavePromptDialog = false
                }
                .buttonStyle(.sortyBordered)

                Spacer()

                Button("Save") {
                    steeringManager.addPrompt(
                        SavedSteeringPrompt(name: savePromptName, prompt: customPrompt)
                    )
                    showSavePromptDialog = false
                    HapticFeedbackManager.shared.success()
                }
                .buttonStyle(.sortyProminent)
                .disabled(
                    savePromptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || steeringManager.hasPrompt(named: savePromptName)
                )
            }
        }
        .padding(16)
        .frame(width: 280)
        .foregroundStyle(.primary)
        .systemLiquidGlassPopover(cornerRadius: 12)
    }

    private var trimmedCustomPrompt: String {
        customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var instructionSuggestions: [String] {
        InstructionSuggestionCatalog.suggestions(
            for: selectedMode,
            personaManager: personaManager,
            customPersonaStore: customPersonaStore
        )
    }

    private var currentInstructionSuggestion: String {
        instructionSuggestions[instructionSuggestionIndex % instructionSuggestions.count]
    }

    private var selectedModeManualAction: (title: String, description: String) {
        switch selectedMode {
        case .organize:
            return (
                "Run Organization",
                "Organize the files already in this folder without changing their names."
            )
        case .organizeAndRename:
            return (
                "Run Organization & Rename",
                "Organize the files already in this folder and improve their names."
            )
        case .renameOnly:
            return (
                "Run Rename",
                "Improve the names of files already in this folder without moving them."
            )
        }
    }

    private func acceptCurrentInstructionSuggestion() -> Bool {
        guard customPrompt.isEmpty else { return false }

        customPrompt = currentInstructionSuggestion
        instructionSelection = NSRange(
            location: (currentInstructionSuggestion as NSString).length,
            length: 0
        )
        HapticFeedbackManager.shared.selection()
        return true
    }

    private func improvePromptWithAI() async {
        guard !trimmedCustomPrompt.isEmpty else { return }
        isImprovingPrompt = true
        defer { isImprovingPrompt = false }

        do {
            // Prefer the Manager-owned client (injectable via
            // FolderOrganizer.setAIClientForTesting with MockAIClient).
            let client: any AIClientProtocol
            if let owned = organizer.aiClient {
                client = owned
            } else {
                client = try AIClientFactory.createClient(config: settingsViewModel.config)
            }
            let outcome = try await ImproveInstructionsTool.run(
                client: client,
                originalInstructions: trimmedCustomPrompt,
                workflow: selectedMode.gerund
            )

            switch outcome {
            case .replacement(let improved):
                customPrompt = improved
                showImprovePromptRequest = false
                HapticFeedbackManager.shared.success()
            case .needsUserInput(let message):
                improvePromptRequestMessage = message
                showImprovePromptRequest = true
                HapticFeedbackManager.shared.selection()
            }
        } catch {
            HapticFeedbackManager.shared.error()
        }
    }

    private var globalAutomationSelection: (provider: AIProvider, model: String) {
        // A stale .unavailableProvider (ex-Copilot placeholder) means "no override".
        let automationProvider =
            settingsViewModel.config.automationProvider == .unavailableProvider
            ? nil : settingsViewModel.config.automationProvider
        let provider = automationProvider ?? settingsViewModel.config.provider
        let configuredModel =
            automationProvider == nil
            ? settingsViewModel.config.model
            : (settingsViewModel.config.automationModel ?? "")
        return (provider, configuredModel)
    }

    private var isCustomModelInvalid: Bool {
        !selectedProvider.isAvailable || selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func primeModelSelectionFromGlobalDefaultsIfNeeded() {
        guard folder.modelOverride == nil && folder.providerOverride == nil else {
            return
        }

        let defaults = globalAutomationSelection
        selectedProvider = defaults.provider
        selectedModel = defaults.model
    }

    /// The live folder re-read at save time with only the fields this sheet
    /// edits applied. Writing back the open-time snapshot would silently revert
    /// concurrent changes such as pause, reauthorization, or bookmark refresh.
    private var folderWithSheetEdits: WatchedFolder? {
        guard var updated = watchedFoldersManager.folder(withID: folder.id) else { return nil }
        updated.organizationMode = selectedMode
        updated.applyPolicy = selectedApplyPolicy
        updated.customPrompt =
            customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : customPrompt

        if useCustomModel {
            updated.providerOverride = selectedProvider
            let trimmedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.modelOverride = trimmedModel.isEmpty ? nil : trimmedModel
        } else {
            updated.providerOverride = nil
            updated.modelOverride = nil
        }

        return updated
    }

    private func openFullOrganization() {
        HapticFeedbackManager.shared.tap()

        guard let updatedFolder = folderWithSheetEdits else {
            dismiss()
            return
        }
        watchedFoldersManager.updateFolder(updatedFolder)

        // The Organize window reads the global config when the run starts, and
        // there is no per-run mode override yet. Stage this folder's mode for
        // the handoff, then restore the previous global values instead of
        // persisting them for every future manual run. Tradeoff: the follow-up
        // run falls back to the previous global mode until FolderOrganizer
        // exposes a per-run mode.
        let previousConfig = settingsViewModel.config
        var stagedConfig = previousConfig
        stagedConfig.enableSmartRename = true
        stagedConfig.mode = updatedFolder.effectiveOrganizationMode
        settingsViewModel.config = stagedConfig
        defer { settingsViewModel.config = previousConfig }

        onOpenFullOrganization(updatedFolder)
        dismiss()
    }

    private func save() {
        guard let updatedFolder = folderWithSheetEdits else {
            // Folder was removed while the sheet was open.
            dismiss()
            return
        }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
            watchedFoldersManager.updateFolder(updatedFolder)
        }
        dismiss()
    }

    private var configurationHeader: some View {
        HStack {
            HStack(spacing: 12) {
                FolderThumbnailView(
                    url: URL(fileURLWithPath: folder.path),
                    size: CGSize(width: 32, height: 32)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.headline)
                    PrivacySensitivePathText(path: folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if settingsViewModel.config.showStatsForNerds {
                Button {
                    HapticFeedbackManager.shared.light()
                    showNerdStats.toggle()
                } label: {
                    Label("Stats for Nerds", systemImage: "chart.bar.doc.horizontal")
                }
                .buttonStyle(.sortyBordered)
                .controlSize(.small)
                .help("Show watched-folder diagnostics")
                .popover(isPresented: $showNerdStats, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Stats for Nerds")
                            .font(.headline)

                        Text("Live diagnostics for this watched folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        WatchedFolderNerdStats(
                            folder: folder,
                            activity: watchedFoldersManager.activityByFolder[folder.id]
                        )
                    }
                    .padding(16)
                    .frame(width: 420)
                    .systemLiquidGlassPopover(cornerRadius: 12)
                }
            }

            Button("Done") {
                HapticFeedbackManager.shared.success()
                save()
            }
            .buttonStyle(.sortyProminent)
            .disabled(useCustomModel && isCustomModelInvalid)
        }
        .padding()
        .systemLiquidGlassBackground(cornerRadius: 12)
    }

    private var organizationModeCard: some View {
        SettingsCard(title: "Action", icon: "slider.horizontal.3", color: .blue) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(OrganizationMode.allCases, id: \.self) { mode in
                        OrganizationModeSegment(
                            mode: mode,
                            isSelected: selectedMode == mode
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedMode = mode
                            }
                            HapticFeedbackManager.shared.selection()
                        }
                    }
                }
                .padding(4)
                .systemLiquidGlassBackground(cornerRadius: 999)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Watched folder action")

                Text(LocalizedStringKey(selectedMode.description))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .numericTextTransition(animationValue: selectedMode)
            }
        }
    }

    private var applyPolicyCard: some View {
        SettingsCard(title: "When a Plan Is Ready", icon: "checkmark.shield", color: .green) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Apply policy", selection: $selectedApplyPolicy) {
                    ForEach(WatchedFolderApplyPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Choose whether Sorty applies watched-folder plans or waits for your review")

                Text(selectedApplyPolicy == .autoApply
                    ? "Sorty applies the plan as soon as it is ready."
                    : "Sorty saves the plan and notifies you to review it. It stays ready until you apply or discard it, even if you close Sorty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionsCard: some View {
        SettingsCard(title: "Actions", icon: "play", color: .blue) {
            Button(action: openFullOrganization) {
                HStack {
                    Image(systemName: selectedMode.iconName)
                        .foregroundStyle(.blue)
                        .symbolReplaceTransition(animationValue: selectedMode)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(selectedModeManualAction.title))
                            .foregroundStyle(.primary)
                            .numericTextTransition(animationValue: selectedMode)
                        Text(LocalizedStringKey(selectedModeManualAction.description))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .numericTextTransition(animationValue: selectedMode)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var instructionsCard: some View {
        SettingsCard(title: "Custom Instructions", icon: "text.bubble", color: .purple)
        {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    SubmittableTextEditor(
                        text: $customPrompt,
                        isFocused: $isPromptFocused,
                        selectedRange: $instructionSelection,
                        onAcceptSuggestion: acceptCurrentInstructionSuggestion,
                        onSubmit: {}
                    )
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)

                    if customPrompt.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            Text(currentInstructionSuggestion)
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .numericTextTransition(
                                    animationValue: instructionSuggestionIndex
                                )

                            Spacer(minLength: 0)

                            Text("Tab")
                                .font(
                                    .system(
                                        size: 10,
                                        weight: .semibold,
                                        design: .rounded
                                    )
                                )
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
                        .task(id: InstructionSuggestionCycleID(suggestions: instructionSuggestions, shouldCycle: shouldCycleInstructionSuggestions)) {
                            instructionSuggestionIndex = 0
                            guard shouldCycleInstructionSuggestions else { return }

                            while !Task.isCancelled {
                                try? await Task.sleep(for: .seconds(8))
                                guard !Task.isCancelled,
                                      shouldCycleInstructionSuggestions else { return }
                                instructionSuggestionIndex =
                                    (instructionSuggestionIndex + 1)
                                    % instructionSuggestions.count
                            }
                        }
                    }
                }
                .frame(height: 80)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(NSColor.textBackgroundColor))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)

                    FocusedInstructionBeamBorder(active: isPromptFocused)
                }
                .accessibilityIdentifier("WatchedFolderCustomInstructionsTextField")
                .accessibilityLabel("Custom instructions for this watched folder")
                .accessibilityHint(
                    customPrompt.isEmpty
                        ? "Press Tab to use the suggested instruction"
                        : "Enter adds a new line"
                )

                instructionActions
            }
        }
    }

    private var modelCard: some View {
        SettingsCard(title: "AI Model", icon: "cpu", color: .purple) {
            VStack(spacing: 12) {
                Toggle(isOn: $useCustomModel) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use Custom Model")
                            .font(.subheadline)
                        Text("Override the global automation model for this folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .frame(maxWidth: .infinity, alignment: .leading)

                if useCustomModel {
                    SettingsSubsettingRow(
                        title: "Folder Model",
                        description: "Used only for this watched folder"
                    ) {
                        HStack(spacing: 8) {
                            ModelSelectorCompactButton(
                                provider: selectedProvider,
                                label: selectedModel.isEmpty
                                    ? "Choose model"
                                    : selectedModel,
                                onTap: { showModelPicker = true }
                            )
                            .modelSelectorTriggerBounds()

                            Button {
                                HapticFeedbackManager.shared.tap()
                                showFolderModelInfo.toggle()
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("About using a separate watched folder model")
                            .accessibilityLabel("Separate watched folder model information")
                            .onHover { hovering in
                                if hovering {
                                    HapticFeedbackManager.shared.selection()
                                }
                                showFolderModelInfo = hovering
                            }
                            .popover(isPresented: $showFolderModelInfo, arrowEdge: .trailing) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Separate Watched Folder Model")
                                        .font(.headline)

                                    Text(
                                        "The main Organize page keeps using the model selected under AI Provider. For faster, more responsive automation, try a smaller model such as GPT-5.6 Luna."
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(14)
                                .frame(width: 300, alignment: .leading)
                                .systemLiquidGlassPopover(cornerRadius: 12)
                            }
                        }
                    }

                    if isCustomModelInvalid {
                        Label("Choose an available provider and model before saving.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.leading, 36)
                    }
                }
            }
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.15)
                    : .easeInOut(duration: 0.25),
                value: useCustomModel
            )
        }
    }
}
