//
//  OrganizationStrategySettingsView.swift
//  Sorty
//
//  Organization Strategy settings section
//

import AppKit
import SwiftUI

struct OrganizationStrategySettingsView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var viewModel: SettingsViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var namingGenerator = NamingInstructionsGenerator()
    @StateObject private var presetManager = NamingPresetManager.shared
    @State private var namingPreferenceInput: String = ""
    @State private var showNamingInput: Bool = false
    @State private var presetNameInput: String = ""
    @State private var showingSavePresetAlert: Bool = false
    @State private var pendingPresetInstructions: String = ""
    @State private var editingPreset: NamingPreset? = nil
    @State private var showEditSheet: Bool = false
    @State private var showingRenamingInfo: Bool = false
    @State private var isRenamingInfoHovered: Bool = false
    @State private var isRenamingInfoPinned: Bool = false
    @State private var showingNamingInstructionsInfo: Bool = false
    @State private var namingReferenceFolderURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Scanning Options", icon: "doc.text.magnifyingglass", color: .blue) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        SettingsToggle(
                            isOn: Binding(
                                get: { isFastModeOn },
                                set: { newValue in
                                    guard viewModel.config.provider.supportsDeepScan else {
                                        viewModel.config.enableDeepScan = false
                                        return
                                    }
                                    viewModel.config.enableDeepScan = !newValue
                                }
                            ),
                            title: "Fast Mode",
                            description: "Uses names, basic metadata, and folder context; skips deep content analysis",
                            focusTarget: .strategyFastMode
                        )
                        .disabled(!viewModel.config.provider.supportsDeepScan)

                        if !viewModel.config.provider.supportsDeepScan {
                            Text("Required for \(viewModel.config.provider.displayName) because Apple on-device models have tighter context limits.")
                                .font(.caption2)
                                .foregroundColor(.orange)
                                .padding(.leading, 32)
                        }
                    }
                }
            }
            .animatedAppearance(delay: 0.05)
            .onAppear(perform: enforceProviderScanMode)
            .onChange(of: viewModel.config.provider) { _, _ in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    enforceProviderScanMode()
                }
            }

            // Vision AI Section
            SettingsCard(title: "AI Vision", icon: "eye", color: .teal) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsToggle(
                        isOn: Binding(
                            get: { viewModel.config.enableVision && isVisionSupportedByCurrentModel },
                            set: { viewModel.config.enableVision = $0 }
                        ),
                        title: "Use AI Vision for Images",
                        description: "Analyze image content for stronger visual grouping, even in Fast Mode",
                        focusTarget: .strategyVision
                    )
                    .disabled(!isVisionSupportedByCurrentModel)

                    if !isVisionSupportedByCurrentModel {
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle")
                                .font(.caption2)
                                .foregroundColor(.blue)
                            Text("Switch to a vision model (e.g., gpt-4o, claude-3-5-sonnet) to enable.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .animatedAppearance(delay: 0.1)

            // Renaming Section
            SettingsCard(
                title: "Renaming",
                icon: "textformat",
                color: .indigo
            ) {
                Button {
                    HapticFeedbackManager.shared.tap()
                    isRenamingInfoPinned.toggle()
                    showingRenamingInfo = isRenamingInfoHovered || isRenamingInfoPinned
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingRenamingInfo, arrowEdge: .bottom) {
                    Text("Controls how Sorty names files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(width: 300, alignment: .leading)
                        .systemLiquidGlassPopover(cornerRadius: 12)
                }
                .onHover { hovering in
                    isRenamingInfoHovered = hovering
                    if hovering {
                        HapticFeedbackManager.shared.selection()
                        showingRenamingInfo = true
                    } else if !isRenamingInfoPinned {
                        showingRenamingInfo = false
                    }
                }
                .onChange(of: showingRenamingInfo) { _, isShowing in
                    if !isShowing {
                        isRenamingInfoPinned = false
                    }
                }
                .help("About renaming files")
                .accessibilityLabel("Renaming information")
            } content: {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Template", selection: Binding(
                        get: { viewModel.config.selectedNamingPresetId },
                        set: { newId in
                            viewModel.config.selectedNamingPresetId = newId
                            if let id = newId, let preset = presetManager.preset(for: id) {
                                if preset.isBuiltIn {
                                    // Map built-in preset back to its NamingStyle
                                    if let style = presetManager.namingStyle(for: id) {
                                        viewModel.config.namingStyle = style
                                        viewModel.config.customNamingInstructions = nil
                                    }
                                } else {
                                    // Custom preset
                                    viewModel.config.namingStyle = .custom
                                    viewModel.config.customNamingInstructions = preset.instructions
                                }
                            }
                        }
                    )) {
                        Text("None").tag(nil as UUID?)

                        Section("Built-in") {
                            ForEach(presetManager.builtInPresets) { preset in
                                Text(preset.name).tag(preset.id as UUID?)
                            }
                        }

                        if !presetManager.customPresets.isEmpty {
                            Section("Custom") {
                                ForEach(presetManager.customPresets) { preset in
                                    Text(preset.name).tag(preset.id as UUID?)
                                }
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.primary)
                    .labelsHidden()
                    .settingsFocusableSetting(.strategyNamingTemplate)

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Picker("Separator", selection: $viewModel.config.renameNamingOptions.separator) {
                                ForEach(RenameSeparatorPreference.allCases, id: \.self) { separator in
                                    Text(separator.displayName).tag(separator)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.primary)
                            .settingsFocusableSetting(.strategyNamingSeparator)

                            Picker("Case", selection: $viewModel.config.renameNamingOptions.caseStyle) {
                                ForEach(RenameCaseStyle.allCases, id: \.self) { style in
                                    Text(style.displayName).tag(style)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.primary)
                            .settingsFocusableSetting(.strategyNamingCase)
                        }

                        Picker("Dates", selection: $viewModel.config.renameNamingOptions.datePolicy) {
                            ForEach(RenameDatePolicy.allCases, id: \.self) { policy in
                                Text(policy.displayName).tag(policy)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.primary)
                        .settingsFocusableSetting(.strategyNamingDatePolicy)

                        HStack {
                            Text("Max Length")
                                .font(.subheadline)
                            NoTickSlider(
                                value: Binding(
                                    get: { Double(viewModel.config.renameNamingOptions.maxFilenameLength) },
                                    set: { viewModel.config.renameNamingOptions.maxFilenameLength = Int($0) }
                                ),
                                in: 20...180,
                                step: 5
                            )
                            Text("\(viewModel.config.renameNamingOptions.maxFilenameLength)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .numericTextTransition(
                                    animationValue: viewModel.config.renameNamingOptions.maxFilenameLength
                                )
                                .frame(width: 32, alignment: .trailing)
                        }
                        .settingsFocusableSetting(.strategyMaxFilenameLength)

                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.purple)
                                .frame(width: 28, height: 28)
                                .background(.purple.opacity(0.12), in: Circle())
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Example filename")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.tertiary)

                                Text(viewModel.config.renameNamingOptions.exampleFilename)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .numericTextTransition(
                                        animationValue: viewModel.config.renameNamingOptions.maxFilenameLength
                                    )
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(.purple.opacity(0.16), lineWidth: 1)
                        )
                        .accessibilityElement(children: .combine)
                    }
                    .settingsFocusableSetting(.strategyNamingOptions)

                    // Preview of selected preset instructions
                    if let selectedId = viewModel.config.selectedNamingPresetId,
                       let selectedPreset = presetManager.preset(for: selectedId),
                       !selectedPreset.instructions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selectedPreset.instructions)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .numericTextTransition(
                                    animationValue: selectedPreset.instructions
                                )
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                                )
                        }
                    }

                    // Action buttons for custom presets
                    if let selectedId = viewModel.config.selectedNamingPresetId,
                       let selectedPreset = presetManager.preset(for: selectedId),
                       !selectedPreset.isBuiltIn {
                        HStack(spacing: 8) {
                            Button {
                                editingPreset = selectedPreset
                                showEditSheet = true
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .buttonStyle(.sortyPrimary(size: .small))

                            Button(role: .destructive) {
                                presetManager.deletePreset(id: selectedId)
                                // Reset to descriptive
                                viewModel.config.namingStyle = .descriptive
                                viewModel.config.customNamingInstructions = nil
                                viewModel.config.selectedNamingPresetId = presetManager.presetId(for: .descriptive)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .buttonStyle(.sortyPrimary(isSecondary: true, size: .small))

                            Spacer()
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(viewModel.config.namingStyle == .custom ? "Custom Naming Instructions" : "Additional Naming Instructions")
                                .font(.subheadline.weight(.medium))
                                .numericTextTransition(
                                    animationValue: viewModel.config.namingStyle
                                )

                            Button {
                                HapticFeedbackManager.shared.tap()
                                showingNamingInstructionsInfo.toggle()
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering {
                                    HapticFeedbackManager.shared.selection()
                                }
                            }
                            .popover(isPresented: $showingNamingInstructionsInfo, arrowEdge: .bottom) {
                                Text(
                                    viewModel.config.namingStyle == .custom
                                        ? "Describe exactly how Sorty should name files. These instructions define the Custom naming style."
                                        : "Add rules that refine the selected naming template, such as “Use camelCase for subject names.”"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(14)
                                .frame(width: 300, alignment: .leading)
                                .systemLiquidGlassPopover(cornerRadius: 12)
                            }
                            .help("About naming instructions")
                            .accessibilityLabel("Naming instruction information")
                        }

                        TextEditor(text: Binding(
                            get: { viewModel.config.customNamingInstructions ?? "" },
                            set: {
                                viewModel.config.customNamingInstructions = $0.isEmpty ? nil : $0
                                if $0.isEmpty && viewModel.config.namingStyle == .custom {
                                    viewModel.config.namingStyle = .descriptive
                                    viewModel.config.selectedNamingPresetId = presetManager.presetId(for: .descriptive)
                                }
                            }
                        ))
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 60)
                        .padding(4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                        if showNamingInput {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("Describe your naming preference...", text: $namingPreferenceInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body))

                                HStack(spacing: 8) {
                                    Button {
                                        chooseNamingReferenceFolder()
                                    } label: {
                                        Label(
                                            namingReferenceFolderURL == nil ? "Choose Reference Folder" : "Change Reference Folder",
                                            systemImage: "folder"
                                        )
                                    }
                                    .buttonStyle(.sortyPrimary(isSecondary: true, size: .small))

                                    if let namingReferenceFolderURL {
                                        Text(namingReferenceFolderURL.lastPathComponent)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .accessibilityLabel("Reference folder: \(namingReferenceFolderURL.lastPathComponent)")

                                        Button {
                                            self.namingReferenceFolderURL = nil
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Remove reference folder")
                                        .accessibilityLabel("Remove reference folder")
                                    }

                                    Spacer()
                                }

                                if namingReferenceFolderURL != nil {
                                    Text("Sorty sends representative filenames from this folder to your selected AI provider. It does not read file contents.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                HStack {
                                    Button("Generate") {
                                        Task {
                                            do {
                                                let instructions = try await namingGenerator.generateNamingInstructions(
                                                    from: namingPreferenceInput,
                                                    referenceFolderURL: namingReferenceFolderURL,
                                                    config: viewModel.config
                                                )
                                                pendingPresetInstructions = instructions
                                                showNamingInput = false
                                                namingPreferenceInput = ""
                                                namingReferenceFolderURL = nil
                                                presetNameInput = ""
                                                showingSavePresetAlert = true
                                            } catch {
                                                // Error is handled by namingGenerator.error
                                            }
                                        }
                                    }
                                    .buttonStyle(.sortyPrimary(size: .small))
                                    .disabled(
                                        (namingPreferenceInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                            && namingReferenceFolderURL == nil)
                                            || namingGenerator.isGenerating
                                    )

                                    if namingGenerator.isGenerating {
                                        SortyGradientCircularLoader(size: 12, lineWidth: 2.2)
                                            .padding(.leading, 4)
                                    }

                                    Spacer()

                                    Button("Cancel") {
                                        showNamingInput = false
                                        namingPreferenceInput = ""
                                        namingReferenceFolderURL = nil
                                    }
                                    .buttonStyle(.sortyPrimary(isSecondary: true, size: .small))
                                }

                                if let error = namingGenerator.error {
                                    Text(error.localizedDescription)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            }
                            .padding(.top, 4)
                        } else {
                            Button {
                                showNamingInput = true
                            } label: {
                                Label("Generate Naming Template", systemImage: "wand.and.stars")
                            }
                            .buttonStyle(.sortyPrimary(size: .small))
                            .padding(.top, 4)
                        }
                    }
                    .settingsFocusableSetting(.strategyNamingInstructions)
                }
            }
            .settingsFocusable(.strategyRenaming)
            .animatedAppearance(delay: 0.15)
            .alert("Save as Naming Preset", isPresented: $showingSavePresetAlert) {
                TextField("Preset name", text: $presetNameInput)
                Button("Save") {
                    let newPreset = NamingPreset(
                        name: presetNameInput.isEmpty ? "Custom Preset" : presetNameInput,
                        instructions: pendingPresetInstructions
                    )
                    presetManager.addPreset(newPreset)
                    viewModel.config.customNamingInstructions = newPreset.instructions
                    viewModel.config.namingStyle = .custom
                    viewModel.config.selectedNamingPresetId = newPreset.id
                    presetNameInput = ""
                    pendingPresetInstructions = ""
                }
                Button("Cancel", role: .cancel) {
                    // Still apply the instructions even if not saved as preset
                    viewModel.config.customNamingInstructions = pendingPresetInstructions
                    viewModel.config.namingStyle = .custom
                    pendingPresetInstructions = ""
                }
            } message: {
                Text("Enter a name for this naming preset so you can reuse it later.")
            }
            .sheet(isPresented: $showEditSheet) {
                if let preset = editingPreset {
                    EditPresetSheet(
                        preset: preset,
                        presetManager: presetManager,
                        viewModel: viewModel,
                        isPresented: $showEditSheet
                    )
                }
            }
        }
    }

    private var isFastModeOn: Bool {
        !viewModel.config.provider.supportsDeepScan || !viewModel.config.enableDeepScan
    }

    private func chooseNamingReferenceFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Reference Folder"
        panel.message = "Choose a folder with filenames that follow the style you want Sorty to learn."
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        namingReferenceFolderURL = url
        HapticFeedbackManager.shared.selection()
    }

    private func enforceProviderScanMode() {
        if !viewModel.config.provider.supportsDeepScan {
            viewModel.config.enableDeepScan = false
        }
    }

    /// Displays off while the current model lacks vision support, but the
    /// stored preference is left untouched so switching back to a vision
    /// model restores the previous choice.
    private var isVisionSupportedByCurrentModel: Bool {
        ModelCatalog.shared.supportsVision(modelId: viewModel.config.model, provider: viewModel.config.provider)
    }
}

// MARK: - Edit Preset Sheet

private struct EditPresetSheet: View {
    @SortyHotReload private var hotReload
    let preset: NamingPreset
    let presetManager: NamingPresetManager
    let viewModel: SettingsViewModel
    @Binding var isPresented: Bool

    @State private var editName: String
    @State private var editInstructions: String

    init(preset: NamingPreset, presetManager: NamingPresetManager, viewModel: SettingsViewModel, isPresented: Binding<Bool>) {
        self.preset = preset
        self.presetManager = presetManager
        self.viewModel = viewModel
        self._isPresented = isPresented
        self._editName = State(initialValue: preset.name)
        self._editInstructions = State(initialValue: preset.instructions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Naming Preset")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.subheadline.weight(.medium))
                TextField("Preset name", text: $editName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions")
                    .font(.subheadline.weight(.medium))
                TextEditor(text: $editInstructions)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .padding(4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.sortyPrimary(isSecondary: true, size: .small))

                Button("Save") {
                    var updated = preset
                    updated.name = editName
                    updated.instructions = editInstructions
                    presetManager.updatePreset(updated)
                    // Update the active config if this preset is currently selected
                    if viewModel.config.selectedNamingPresetId == preset.id {
                        viewModel.config.customNamingInstructions = editInstructions
                    }
                    isPresented = false
                }
                .buttonStyle(.sortyPrimary(size: .small))
                .disabled(editName.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 400, minHeight: 300)
    }
}

#Preview {
    OrganizationStrategySettingsView()
        .environmentObject(SettingsViewModel())
        .frame(width: 500, height: 600)
}
