import Foundation
import AppKit
import SwiftUI

// MARK: - Instructions
extension ReadyToOrganizeView {
    var instructionsContent: some View {
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

    func improvePromptWithAI() async {
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

    var activeFileMention: InstructionMentionQuery? {
        InstructionMentionQuery.active(in: organizer.customInstructions, selectedRange: instructionSelection)
    }

    func shouldShowReferencePicker(for mention: InstructionMentionQuery) -> Bool {
        isTextFieldFocused && !mention.query.isEmpty && !referenceMatches(for: mention.query).isEmpty
    }

    func referenceMatches(for query: String) -> [InstructionFileReference] {
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

    func insertReference(_ reference: InstructionFileReference, replacing mention: InstructionMentionQuery) {
        var instructions = organizer.customInstructions

        let replacement = "@\(reference.displayToken)"
        instructions.replaceSubrange(mention.range, with: replacement)
        organizer.customInstructions = instructions
        instructionSelection = NSRange(location: mention.nsRange.location + (replacement as NSString).length, length: 0)
        HapticFeedbackManager.shared.selection()
    }

    func scheduleReferenceableFilesRefresh() {
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

    nonisolated static func loadReferenceableFiles(in directory: URL) async -> [InstructionFileReference] {
        await Task.detached(priority: .utility) {
            referenceableFiles(in: directory)
        }.value
    }

    nonisolated static func referenceableFiles(in directory: URL) -> [InstructionFileReference] {
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
