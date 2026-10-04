import Foundation
import AppKit
import SwiftUI

struct ReadyToOrganizeView: View {
    @SortyHotReload private var hotReload
    let onStart: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var organizer: FolderOrganizer
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var storageLocationsManager: StorageLocationsManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var automationManager: AutomationManager
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var customPersonaStore: CustomPersonaStore
    @StateObject private var sessionManager = AISessionManager.shared
    @StateObject private var steeringManager = SteeringPromptManager.shared
    @State private var hasAppeared = false
    @State private var isTextFieldFocused = false
    @State private var showStorageLocations = false
    @State private var showingFolderPicker = false
    @State private var suggestedLocationName: String? = nil
    @State private var addStorageLocationErrorMessage: String?
    @State private var showSavePromptDialog = false
    @State private var savePromptName = ""
    @State private var isImprovingPrompt = false
    @State private var showImprovePromptRequest = false
    @State private var improvePromptRequestMessage = ""
    @State private var showSavedPromptsSheet = false
    @State private var showStorageLocationsInfo = false
    @State private var referenceableFiles: [InstructionFileReference] = []
    @State private var instructionSelection: NSRange = NSRange(location: 0, length: 0)
    @State private var referenceRefreshTask: Task<Void, Never>?
    @State private var startCTACompression: CGFloat = 0

    init(onStart: @escaping () -> Void, startsVisible: Bool = false) {
        self.onStart = onStart
        _hasAppeared = State(initialValue: startsVisible)
    }

    private var mode: OrganizationMode {
        settingsViewModel.config.mode
    }

    private var instructionSuggestions: [String] {
        InstructionSuggestionCatalog.suggestions(
            for: mode,
            personaManager: personaManager,
            customPersonaStore: customPersonaStore
        )
    }

    private var isConnecting: Bool {
        sessionManager.prewarmingProvider != nil
    }

    private var selectedStorageLocationCount: Int {
        storageLocationsManager.locations.filter(\.isEnabled).count
    }

    private var unavailableSelectedStorageLocationCount: Int {
        max(0, selectedStorageLocationCount - storageLocationsManager.enabledLocations.count)
    }

    private var storageLocationSummaryID: String {
        if selectedStorageLocationCount > 0 {
            return unavailableSelectedStorageLocationCount > 0
                ? "selected-unavailable"
                : "selected-available"
        }

        return storageLocationsManager.locations.isEmpty ? "unconfigured" : "inactive"
    }

    private var storageLocationSummaryTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.94, anchor: .leading))
    }

    private var storageLocationTitle: String {
        selectedStorageLocationCount == 1 ? "Storage Location" : "Storage Locations"
    }

    private var storageLocationSelectionTint: Color {
        unavailableSelectedStorageLocationCount > 0 ? .orange : .green
    }

    private var storageLocationsVerticalPadding: CGFloat {
        if showStorageLocations {
            return 10
        }

        return storageLocationsManager.locations.isEmpty ? 4 : 6
    }

    private var storageLocationListIDs: [StorageLocation.ID] {
        storageLocationsManager.locations.map(\.id)
    }

    private var storageLocationInsertionAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.32, dampingFraction: 0.84)
    }

    private var storageLocationRowTransition: AnyTransition {
        .opacity
    }

    private var addStorageLocationErrorIsPresented: Binding<Bool> {
        Binding(
            get: { addStorageLocationErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    addStorageLocationErrorMessage = nil
                }
            }
        )
    }

    var body: some View {
        WorkflowContainer(currentStep: .configure) {
            // Compact header
            VStack(spacing: 16) {
                iconSection
                ReadyToOrganizeTitle(
                    mode: mode,
                    showsWorkflowPicker: appState.showsFinderWorkflowPicker,
                    onSelectMode: selectWorkflow
                )
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.96)
            .offset(y: hasAppeared ? 0 : 8)
            .animation(reduceMotion ? nil : .smooth(duration: 0.45).delay(0.04), value: hasAppeared)

            // Instructions card
            WorkflowCard(title: "Instructions", icon: "text.bubble") {
                instructionsContent
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 10)
            .animation(reduceMotion ? nil : .smooth(duration: 0.45).delay(0.10), value: hasAppeared)

            if mode != .renameOnly {
                WorkflowCard(verticalPadding: storageLocationsVerticalPadding) {
                    storageLocationsContent
                }
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 10)
                .animation(reduceMotion ? nil : .smooth(duration: 0.45).delay(0.16), value: hasAppeared)
            }

            ReadyToOrganizeStartButton(
                mode: mode,
                isConnecting: isConnecting,
                hasAppeared: hasAppeared,
                reduceMotion: reduceMotion,
                compression: startCTACompression,
                onStart: runStartCTAAnimation
            )

            ReadyToOrganizeKeyboardHint(
                actionVerb: mode.actionVerb,
                isConnecting: isConnecting,
                hasAppeared: hasAppeared,
                reduceMotion: reduceMotion
            )

            // Connection status indicator
            connectionStatusView
                .opacity(hasAppeared ? 1 : 0)
                .animation(reduceMotion ? nil : .smooth(duration: 0.45).delay(0.32), value: hasAppeared)
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderImport(result)
        }
        .alert(
            "Couldn't Add Storage Location",
            isPresented: addStorageLocationErrorIsPresented
        ) {
            Button("OK", role: .cancel) {
                addStorageLocationErrorMessage = nil
            }
        } message: {
            Text(addStorageLocationErrorMessage ?? "Please try selecting the folder again.")
        }
        .onAppear(perform: prepareForDisplay)
        .onChange(of: appState.selectedDirectory) { _, _ in
            scheduleReferenceableFilesRefresh()
        }
        .onDisappear(perform: stopReferenceRefresh)
    }

    private func handleFolderImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                HapticFeedbackManager.shared.success()
                do {
                    try withAnimation(storageLocationInsertionAnimation) {
                        try storageLocationsManager.addLocation(
                            url: url,
                            customName: suggestedLocationName
                        )
                    }
                } catch {
                    HapticFeedbackManager.shared.error()
                    addStorageLocationErrorMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            HapticFeedbackManager.shared.error()
            addStorageLocationErrorMessage = error.localizedDescription
        }
        suggestedLocationName = nil
    }

    private func prepareForDisplay() {
        scheduleReferenceableFilesRefresh()
        Task { await storageLocationsManager.refreshAccessStatus() }

        guard !hasAppeared else { return }
        guard !appState.hasPresentedReadyToOrganize else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                hasAppeared = true
            }
            return
        }

        appState.hasPresentedReadyToOrganize = true
        hasAppeared = true
    }

    private func stopReferenceRefresh() {
        referenceRefreshTask?.cancel()
        referenceRefreshTask = nil
    }

    private func runStartCTAAnimation() {
        HapticFeedbackManager.shared.tap()
        guard !reduceMotion else {
            onStart()
            return
        }

        withAnimation(.spring(response: 0.18, dampingFraction: 0.56)) {
            startCTACompression = 1
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(70))
            onStart()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                startCTACompression = 0
            }
        }
    }

    private func selectWorkflow(_ selectedMode: OrganizationMode) {
        guard selectedMode != mode else { return }
        HapticFeedbackManager.shared.selection()
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6)) {
            if selectedMode != .organize {
                settingsViewModel.config.enableSmartRename = true
            }
            settingsViewModel.config.mode = selectedMode
        }
    }

    private func toggleStorageLocations() {
        HapticFeedbackManager.shared.selection()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            showStorageLocations.toggle()
        }
    }

    private var storageLocationsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                Button(action: toggleStorageLocations) {
                    HStack(spacing: 6) {
                        Image(systemName: selectedStorageLocationCount > 0 ? "externaldrive.fill" : "externaldrive")
                            .font(.system(size: 12))
                            .foregroundStyle(
                                selectedStorageLocationCount > 0
                                    ? Color.accentColor
                                    : Color.secondary
                            )
                            .symbolReplaceTransition(
                                animationValue: selectedStorageLocationCount > 0
                            )
                            .frame(width: 22, height: 22)
                            .background {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.32))
                                    .frame(width: 18, height: 18)
                                    .blur(radius: 5)
                                    .opacity(selectedStorageLocationCount > 0 ? 1 : 0)
                            }

                        Text(storageLocationTitle)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .numericTextTransition(
                                animationValue: storageLocationTitle,
                                animation: .easeInOut(duration: 0.28)
                            )
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showStorageLocations ? "Hide organization locations" : "Show organization locations")
                .accessibilityLabel(showStorageLocations ? "Hide storage locations" : "Show storage locations")
                .accessibilityHint("Expand to manage local, cloud, and external organization locations")
                .accessibilityValue(showStorageLocations ? "Expanded" : "Collapsed")

                Button {
                    HapticFeedbackManager.shared.tap()
                    showStorageLocationsInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 44)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        HapticFeedbackManager.shared.selection()
                    }
                }
                .popover(isPresented: $showStorageLocationsInfo, arrowEdge: .bottom) {
                    StorageLocationsInfoPopover()
                        .systemLiquidGlassPopover(cornerRadius: 12)
                }
                .help("How storage locations work")
                .accessibilityLabel("About storage locations")
                .accessibilityIdentifier("StorageLocationsInfoButton")

                Button(action: toggleStorageLocations) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 8)

                        storageLocationSelectionSummary
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showStorageLocations ? "Hide organization locations" : "Show organization locations")
                .accessibilityLabel(showStorageLocations ? "Hide storage locations" : "Show storage locations")

                Button(action: toggleStorageLocations) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showStorageLocations ? 180 : 0))
                        .animation(
                            reduceMotion ? nil : .smooth(duration: 0.28),
                            value: showStorageLocations
                        )
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showStorageLocations ? "Hide organization locations" : "Show organization locations")
                .accessibilityLabel(showStorageLocations ? "Collapse storage locations" : "Expand storage locations")
                .accessibilityIdentifier("StorageLocationsDisclosureButton")
            }

            if showStorageLocations {
                VStack(alignment: .leading, spacing: 10) {
                    if !storageLocationsManager.locations.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(storageLocationsManager.locations) { location in
                                CompactStorageLocationRow(location: location)
                                    .transition(storageLocationRowTransition)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .animation(storageLocationInsertionAnimation, value: storageLocationListIDs)
                    }

                    HStack(alignment: .center, spacing: 14) {
                        if storageLocationsManager.locations.isEmpty {
                            Spacer()
                        }

                        Button {
                            HapticFeedbackManager.shared.tap()
                            suggestedLocationName = nil
                            showingFolderPicker = true
                        } label: {
                            Label {
                                Text("Add Custom Location")
                            } icon: {
                                Image(systemName: "plus")
                                    .rotationEffect(.degrees(showingFolderPicker ? 45 : 0))
                                    .animation(
                                        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72),
                                        value: showingFolderPicker
                                    )
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.sortyBordered)
                        .controlSize(.small)
                        .help("Add a folder that Sorty can organize with")
                        .accessibilityHint("Opens the folder picker to add an organization location")

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(
                        storageLocationInsertionAnimation,
                        value: storageLocationsManager.locations.isEmpty
                    )
                    .padding(.top, 2)
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var storageLocationSelectionSummary: some View {
        ZStack(alignment: .trailing) {
            Group {
                if selectedStorageLocationCount > 0 {
                    HStack(spacing: 8) {
                        Text("\(selectedStorageLocationCount) selected")
                            .font(.caption)
                            .foregroundStyle(storageLocationSelectionTint)
                            .numericTextTransition(animationValue: selectedStorageLocationCount)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .systemLiquidGlassBackground(cornerRadius: 999)

                        if unavailableSelectedStorageLocationCount > 0 {
                            Text("\(unavailableSelectedStorageLocationCount) unavailable")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .numericTextTransition(
                                    animationValue: unavailableSelectedStorageLocationCount
                                )
                        }
                    }
                } else if !storageLocationsManager.locations.isEmpty {
                    Text("No active locations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No locations configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .id(storageLocationSummaryID)
            .transition(storageLocationSummaryTransition)
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.26, dampingFraction: 0.86),
            value: storageLocationSummaryID
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var iconSection: some View {
        if let image = SortyResources.image(named: "ReadyToOrganizeIcon") {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .clipShape(Circle())
                .accessibilityLabel("Sorty is ready to \(mode.actionVerb.lowercased())")
        } else {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 104, height: 104)
                .accessibilityLabel("Sorty is ready to \(mode.actionVerb.lowercased())")
        }
    }

    @ViewBuilder
    private var connectionStatusView: some View {
        HStack(spacing: 6) {
            if sessionManager.prewarmingProvider != nil {
                SortyGradientCircularLoader(size: 12, lineWidth: 2.2)
                    .frame(width: 12, height: 12)
                Text("Connecting to \(settingsViewModel.config.provider.displayName)...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if sessionManager.isPrewarmed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text("Connected to \(settingsViewModel.config.provider.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let error = sessionManager.prewarmError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("Connection warning: \(error)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(minHeight: 16)
        .help(sessionManager.prewarmError ?? "Current AI connection state")
        .accessibilityLabel("Connection status")
        .accessibilityHint("Shows whether Sorty can reach the selected AI provider")
    }

    private var instructionsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            let mention = activeFileMention

            ZStack(alignment: .topLeading) {
                if isImprovingPrompt {
                    HStack {
                        Spacer()
                        SortyGradientCircularLoader(size: 13, lineWidth: 2.4)
                        Text("Improving...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 20)
                } else {
                    RotatingInstructionSuggestionEditor(
                        text: $organizer.customInstructions,
                        isFocused: $isTextFieldFocused,
                        selectedRange: $instructionSelection,
                        suggestions: instructionSuggestions,
                        onSubmit: onStart
                    )
                }
            }
            .frame(minHeight: 60, maxHeight: 80)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)

                FocusedInstructionBeamBorder(active: isTextFieldFocused)
            }
            .accessibilityIdentifier("CustomInstructionsTextField")
            .accessibilityLabel("Additional instructions for \(mode.gerund)")
            .accessibilityHint(
                organizer.customInstructions.isEmpty
                    ? "Press Tab to use the suggested instruction, Command+Enter to start \(mode.gerund), or Enter for a new line"
                    : "Press Command+Enter to start \(mode.gerund), or Enter for a new line"
            )
            .overlay(alignment: .bottomLeading) {
                if let mention, shouldShowReferencePicker(for: mention) {
                    InstructionFileReferencePicker(
                        matches: referenceMatches(for: mention.query),
                        query: mention.query,
                        onSelect: { reference in
                            insertReference(reference, replacing: mention)
                        }
                    )
                    .offset(y: 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
                    .zIndex(4)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: mention?.query)

            HStack(alignment: .center, spacing: 0) {
                // Improve with AI button
                if !organizer.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                    .accessibilityHint("Rewrites your prompt to be clearer and more specific")
                    .alert("Sorty needs more detail", isPresented: $showImprovePromptRequest) {
                        Button("Edit Instructions") {
                            isTextFieldFocused = true
                        }
                    } message: {
                        Text("\(improvePromptRequestMessage)\n\nEdit the instructions above, then click Improve again.")
                    }
                }

                // Save prompt button
                if !organizer.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                                    HapticFeedbackManager.shared.tap()
                                    showSavePromptDialog = false
                                }
                                .buttonStyle(.sortyBordered)
                                .accessibilityIdentifier("SavePromptCancelButton")

                                Spacer()

                                Button("Save") {
                                    let prompt = SavedSteeringPrompt(
                                        name: savePromptName.isEmpty ? "Untitled" : savePromptName,
                                        prompt: organizer.customInstructions
                                    )
                                    steeringManager.addPrompt(prompt)
                                    showSavePromptDialog = false
                                    HapticFeedbackManager.shared.success()
                                }
                                .buttonStyle(.sortyProminent)
                                .accessibilityIdentifier("SavePromptSaveButton")
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
                }

                // Manage saved prompts button
                Button {
                    showSavedPromptsSheet.toggle()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
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
                                Color.accentColor.opacity(0.18),
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
        .sheet(isPresented: $showSavedPromptsSheet) {
            SavedPromptsSheet(
                steeringManager: steeringManager,
                settingsConfig: settingsViewModel.config,
                onApplyPrompt: { prompt in
                    organizer.customInstructions = prompt
                    showSavedPromptsSheet = false
                    HapticFeedbackManager.shared.tap()
                }
            )
        }
    }

    private func improvePromptWithAI() async {
        let original = organizer.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return }
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
                originalInstructions: original,
                workflow: mode.gerund
            )

            switch outcome {
            case .replacement(let improved):
                organizer.customInstructions = improved
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

    private var activeFileMention: InstructionMentionQuery? {
        InstructionMentionQuery.active(in: organizer.customInstructions, selectedRange: instructionSelection)
    }

    private func shouldShowReferencePicker(for mention: InstructionMentionQuery) -> Bool {
        isTextFieldFocused && !mention.query.isEmpty && !referenceMatches(for: mention.query).isEmpty
    }

    private func referenceMatches(for query: String) -> [InstructionFileReference] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let matches: [InstructionFileReference]

        if normalizedQuery.isEmpty {
            matches = Array(referenceableFiles.prefix(8))
        } else {
            let prefixMatches = referenceableFiles.filter {
                $0.name.localizedLowercase.hasPrefix(normalizedQuery)
            }
            let containedMatches = referenceableFiles.filter {
                !$0.name.localizedLowercase.hasPrefix(normalizedQuery) &&
                $0.name.localizedLowercase.localizedStandardContains(normalizedQuery)
            }
            matches = Array((prefixMatches + containedMatches).prefix(8))
        }

        return matches
    }

    private func insertReference(_ reference: InstructionFileReference, replacing mention: InstructionMentionQuery) {
        var instructions = organizer.customInstructions

        let replacement = "@\(reference.displayToken)"
        instructions.replaceSubrange(mention.range, with: replacement)
        organizer.customInstructions = instructions
        instructionSelection = NSRange(location: mention.nsRange.location + (replacement as NSString).length, length: 0)
        HapticFeedbackManager.shared.selection()
    }

    private func scheduleReferenceableFilesRefresh() {
        referenceRefreshTask?.cancel()

        guard let directory = appState.selectedDirectory else {
            referenceableFiles = []
            return
        }

        referenceRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }

            let files = await Self.loadReferenceableFiles(in: directory)
            guard !Task.isCancelled else { return }
            referenceableFiles = files
            referenceRefreshTask = nil
        }
    }

    private nonisolated static func loadReferenceableFiles(in directory: URL) async -> [InstructionFileReference] {
        await Task.detached(priority: .utility) {
            referenceableFiles(in: directory)
        }.value
    }

    private nonisolated static func referenceableFiles(in directory: URL) -> [InstructionFileReference] {
        guard !Task.isCancelled else { return [] }

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: options
        ) else {
            return []
        }

        var files: [InstructionFileReference] = []
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { return [] }
            guard files.count < 400 else { break }
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
                  values.isRegularFile == true else { continue }

            files.append(
                InstructionFileReference(
                    url: url,
                    baseDirectory: directory,
                    fileSize: values.fileSize
                )
            )
        }

        return files.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

private struct InstructionMentionQuery: Equatable {
    let range: Range<String.Index>
    let nsRange: NSRange
    let query: String

    static func active(in text: String, selectedRange: NSRange) -> InstructionMentionQuery? {
        guard selectedRange.length == 0 else { return nil }
        guard selectedRange.location <= (text as NSString).length else { return nil }
        let cursor = String.Index(utf16Offset: selectedRange.location, in: text)
        let prefix = text[..<cursor]
        guard let atIndex = prefix.lastIndex(of: "@") else { return nil }
        let afterAt = text.index(after: atIndex)
        let query = String(text[afterAt..<cursor])

        guard !query.contains(where: \.isNewline) else { return nil }
        guard query.rangeOfCharacter(from: CharacterSet(charactersIn: ",;()[]{}")) == nil else { return nil }
        guard query.count <= 80 else { return nil }
        if let characterBeforeAt = text[..<atIndex].last,
           !characterBeforeAt.isWhitespace,
           !",;([{".contains(characterBeforeAt) {
            return nil
        }

        let range = atIndex..<cursor
        return InstructionMentionQuery(
            range: range,
            nsRange: NSRange(range, in: text),
            query: query
        )
    }
}

private struct InstructionFileReference: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let name: String
    let relativePath: String
    let fileSize: Int?

    init(url: URL, baseDirectory: URL, fileSize: Int?) {
        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.fileSize = fileSize

        let basePath = baseDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(basePath + "/") {
            self.relativePath = String(path.dropFirst(basePath.count + 1))
        } else {
            self.relativePath = url.lastPathComponent
        }
    }

    var displayToken: String {
        let token = relativePath
        return token.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;()[]{}"))) == nil ? token : "\"\(token)\""
    }

    var subtitle: String {
        let folder = URL(fileURLWithPath: relativePath).deletingLastPathComponent().path
        if folder == "." || folder == "/" || folder.isEmpty {
            return formattedSize
        }
        return "\(folder) • \(formattedSize)"
    }

    private var formattedSize: String {
        guard let fileSize else { return "File" }
        return ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }
}

private struct InstructionFileReferencePicker: View {
    @SortyHotReload private var hotReload
    let matches: [InstructionFileReference]
    let query: String
    let onSelect: (InstructionFileReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "at")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)
                Text("Reference a file")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("↩ to insert")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            ForEach(matches) { reference in
                Button {
                    onSelect(reference)
                } label: {
                    HStack(spacing: 10) {
                        FileThumbnailView(url: reference.url, size: CGSize(width: 24, height: 24))
                            .frame(width: 24, height: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            highlightedName(reference.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)

                            Text(reference.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        if !reference.url.pathExtension.isEmpty {
                            Text(".\(reference.url.pathExtension)")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.teal.opacity(0.12), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reference \(reference.name)")
                .accessibilityHint("Adds this file reference to the instructions")
            }
        }
        .padding(6)
        .frame(width: 360)
        .systemLiquidGlassPopover(cornerRadius: 12)
        .shadow(color: .black.opacity(0.14), radius: 18, x: 0, y: 10)
    }

    private func highlightedName(_ name: String) -> Text {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty,
              let range = name.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(name)
        }

        let prefix = String(name[..<range.lowerBound])
        let match = String(name[range])
        let suffix = String(name[range.upperBound...])
        return Text(prefix) + Text(match).foregroundStyle(.teal) + Text(suffix)
    }
}
