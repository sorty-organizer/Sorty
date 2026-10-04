//
//  PersonaPickerView.swift
//  Sorty
//
//  UI for selecting organization personas including custom ones
//

import SwiftUI

struct PersonaPickerView: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var customStore: CustomPersonaStore
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var appState: AppState
    @State private var hoveringPersona: PersonaType?
    @State private var hoveringCustom: String?
    @State private var showingIconPicker: Bool = false
    @State private var showingDeleteConfirmation: Bool = false
    @State private var personaPendingDeletion: CustomPersona?
    @State private var localPrompt: String = ""
    @State private var localName: String = ""
    @State private var localDescription: String = ""
    @State private var localIcon: String = "star.fill"
    @State private var showingInstructionsInfo: Bool = false
    @State private var isCustomExpanded: Bool = false
    @State private var polishError: String?
    @StateObject private var promptPolisher = PersonaGenerator()
    @FocusState private var focusedField: PersonaEditableField?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Default Organization Persona")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            LazyVGrid(columns: personaGridColumns, spacing: 8) {
                ForEach(PersonaType.allCases, id: \.self) { persona in
                    PersonaButton(
                        persona: persona,
                        isSelected: personaManager.selectedPersona == persona
                            && personaManager.selectedCustomPersonaId == nil,
                        isHovering: hoveringPersona == persona
                    ) {
                        saveChangesIfNeeded()
                        withAnimation(.spring(response: 0.3)) {
                            personaManager.selectPersona(persona)
                            updateLocalPrompt()
                        }
                        AnalyticsManager.shared.capturePersonaInventory(
                            action: "persona_selected",
                            customPersonaCount: customStore.customPersonas.count,
                            selectionKind: "built_in"
                        )
                    }
                    .onHover { hovering in
                        hoveringPersona = hovering ? persona : nil
                    }
                }
            }

            if !customStore.customPersonas.isEmpty {
                Divider()

                HStack {
                    Text("Custom Personas")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button(action: {
                        appState.personaGeneratorPresentationContext = .settings
                    }) {
                        Label("Generate Custom Persona", systemImage: "sparkles")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }

                LazyVGrid(columns: personaGridColumns, spacing: 8) {
                    ForEach(visibleCustomPersonas) { custom in
                        CustomPersonaButton(
                            persona: custom,
                            isSelected: personaManager.selectedCustomPersonaId == custom.id,
                            isHovering: hoveringCustom == custom.id,
                            onSelect: {
                                saveChangesIfNeeded()
                                withAnimation(.spring(response: 0.3)) {
                                    personaManager.selectCustomPersona(custom.id)
                                    updateLocalPrompt()
                                }
                                AnalyticsManager.shared.capturePersonaInventory(
                                    action: "persona_selected",
                                    customPersonaCount: customStore.customPersonas.count,
                                    selectionKind: "custom"
                                )
                            },
                            onDelete: {
                                requestDeletion(of: custom)
                            }
                        )
                        .onHover { hovering in
                            hoveringCustom = hovering ? custom.id : nil
                        }
                    }
                }

                if customStore.customPersonas.count > collapsedCustomLimit {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        withAnimation(.spring(response: 0.3)) {
                            isCustomExpanded.toggle()
                        }
                    } label: {
                        Label(
                            isCustomExpanded
                                ? "Show Less"
                                : "Show \(customStore.customPersonas.count - collapsedCustomLimit) More",
                            systemImage: isCustomExpanded ? "chevron.up" : "chevron.down"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("CustomPersonasToggle")
                }
            }

            if selectedCustomPersona == nil {
                Text(personaManager.selectedPersona.description)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut, value: personaManager.selectedPersona)
            }

            Divider()
                .padding(.vertical, 8)

            personaInstructionsEditor
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissPersonaGenerationHighlight()
            }
        )
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .alert("Delete Persona?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deletePendingPersona()
            }
            Button("Cancel", role: .cancel) {
                personaPendingDeletion = nil
            }
        } message: {
            Text("This permanently removes \(personaPendingDeletion?.name ?? "this persona").")
        }
        .onAppear {
            updateLocalPrompt()
            AnalyticsManager.shared.capturePersonaInventory(
                action: "inventory_viewed",
                customPersonaCount: customStore.customPersonas.count,
                selectionKind: selectedCustomPersona == nil ? "built_in" : "custom"
            )
        }
        .onChange(of: focusedField) { oldValue, newValue in
            if oldValue != nil, oldValue != newValue {
                saveChangesIfNeeded()
            }
        }
        .onChange(of: personaManager.selectedCustomPersonaId) { _, newValue in
            updateLocalPrompt()
            // Keep a hidden selection reachable: expand if it falls past the collapsed rows.
            if let newValue, !isCustomExpanded,
               !customStore.customPersonas.prefix(collapsedCustomLimit).contains(where: { $0.id == newValue }) {
                isCustomExpanded = true
            }
        }
        .onChange(of: customStore.customPersonas) { _, _ in
            updateLocalPrompt()
        }
        .onChange(of: customStore.customPersonas.count) { _, count in
            if count <= collapsedCustomLimit {
                isCustomExpanded = false
            }
            AnalyticsManager.shared.capturePersonaInventory(
                action: "inventory_changed",
                customPersonaCount: count
            )
        }
        .onDisappear {
            saveChangesIfNeeded()
        }
    }

    private func dismissPersonaGenerationHighlight() {
        guard appState.settingsFocusTarget == .rulesOrganizationStyle else { return }

        withAnimation(.easeOut(duration: 0.2)) {
            appState.settingsFocusTarget = nil
        }
    }

    @ViewBuilder
    private var personaInstructionsEditor: some View {
        if let custom = selectedCustomPersona {
            customPersonaEditor(custom)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Additional Instructions")
                        .font(.subheadline.weight(.medium))

                    instructionsInfoButton(
                        text: "These instructions are saved with \(personaManager.selectedPersona.displayName) and apply whenever you use this persona. Use them for preferences such as folder count, hierarchy depth, or grouping rules.",
                        accessibilityLabel: "Additional instruction information"
                    )

                    Spacer()

                    if personaManager.customPrompts[personaManager.selectedPersona] != nil {
                        Button {
                            HapticFeedbackManager.shared.tap()
                            personaManager.resetCustomPrompt(for: personaManager.selectedPersona)
                            updateLocalPrompt()
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }
                        .font(.caption)
                        .buttonStyle(.sortyBordered(intent: .destructive, size: .small))
                    }
                }

                TextEditor(text: $localPrompt)
                    .focused($focusedField, equals: .prompt)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(alignment: .topLeading) {
                        Text(localPrompt.isEmpty ? " " : localPrompt + " ")
                            .font(.system(.body, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .foregroundColor(.clear)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 70, maxHeight: 320)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .animation(.spring(response: 0.32, dampingFraction: 0.82), value: localPrompt)
            }
        }
    }

    private func customPersonaEditor(_ custom: CustomPersona) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    HapticFeedbackManager.shared.tap()
                    showingIconPicker = true
                } label: {
                    Image(systemName: localIcon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.purple)
                        .frame(width: 52, height: 52)
                        .symbolReplaceTransition(animationValue: localIcon)
                        .background(
                            Color.purple.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingIconPicker) {
                    iconPicker
                }
                .help("Choose a persona icon")
                .accessibilityLabel("Choose persona icon")

                VStack(spacing: 8) {
                    TextField("Persona name", text: $localName)
                        .focused($focusedField, equals: .name)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline.weight(.semibold))
                        .onChange(of: localName) { _, value in
                            if value.count > 20 {
                                localName = String(value.prefix(20))
                            }
                        }

                    TextField(
                        "Describe when and how to use this persona",
                        text: $localDescription,
                        axis: .vertical
                    )
                    .focused($focusedField, equals: .description)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                }

                Button(role: .destructive) {
                    requestDeletion(of: custom)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.sortyBordered(intent: .destructive, size: .small))
                .help("Delete persona")
                .accessibilityLabel("Delete \(custom.name)")
            }

            Divider()

            HStack(alignment: .center, spacing: 8) {
                Text("System Prompt")
                    .font(.subheadline.weight(.semibold))

                instructionsInfoButton(
                    text: "These editable instructions are saved with \(localName.isEmpty ? custom.name : localName). If you change the generated prompt, use the wand to turn your draft into clear, structured rules without changing what you want.",
                    accessibilityLabel: "\(custom.name) instruction information"
                )

                Spacer()

                if localPrompt != custom.promptModifier || promptPolisher.isGenerating {
                    if promptPolisher.isGenerating {
                        SortyGradientCircularLoader(size: 11, lineWidth: 2)
                            .accessibilityLabel("Cleaning up prompt")
                    }

                    Button {
                        polishPrompt()
                    } label: {
                        Label("Clean Up", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.sortyBordered(intent: .primary, size: .small))
                    .disabled(
                        localPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || promptPolisher.isGenerating
                    )
                    .help("Clean up and structure this prompt")
                }
            }

            ZStack(alignment: .topLeading) {
                if localPrompt.isEmpty {
                    Text("Write rough organization rules here, then use the wand to structure and improve them…")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $localPrompt)
                    .focused($focusedField, equals: .prompt)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .accessibilityLabel("\(custom.name) system prompt")
            }
            .frame(minHeight: 150, maxHeight: 340)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            }

            if let polishError {
                Label(polishError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Icon")
                .font(.headline)

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 40), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(personaIconOptions, id: \.self) { icon in
                        Button {
                            localIcon = icon
                            showingIconPicker = false
                            saveChangesIfNeeded()
                            HapticFeedbackManager.shared.selection()
                        } label: {
                            Image(systemName: icon)
                                .font(.system(size: 18, weight: .medium))
                                .frame(width: 38, height: 38)
                                .foregroundStyle(localIcon == icon ? Color.purple : Color.primary)
                                .background(
                                    localIcon == icon
                                        ? Color.purple.opacity(0.14)
                                        : Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(icon)
                        .accessibilityLabel(icon)
                    }
                }
            }
            .frame(maxHeight: 270)
        }
        .padding(16)
        .frame(width: 390)
        .systemLiquidGlassPopover(cornerRadius: 12)
    }

    private func instructionsInfoButton(
        text: LocalizedStringKey,
        accessibilityLabel: LocalizedStringKey
    ) -> some View {
        Button {
            HapticFeedbackManager.shared.tap()
            showingInstructionsInfo.toggle()
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
        .popover(isPresented: $showingInstructionsInfo, arrowEdge: .bottom) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(width: 300, alignment: .leading)
                .systemLiquidGlassPopover(cornerRadius: 12)
        }
        .help("About these instructions")
        .accessibilityLabel(accessibilityLabel)
    }

    private func updateLocalPrompt() {
        if let custom = selectedCustomPersona {
            localPrompt = custom.promptModifier
            localName = custom.name
            localDescription = custom.description
            localIcon = custom.icon
        } else {
            localPrompt = personaManager.customPrompts[personaManager.selectedPersona] ?? ""
            localName = ""
            localDescription = ""
            localIcon = "star.fill"
        }
        polishError = nil
    }

    private func saveChangesIfNeeded() {
        if let custom = selectedCustomPersona {
            let trimmedName = localName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = trimmedName.isEmpty ? custom.name : trimmedName
            guard custom.name != resolvedName
                    || custom.icon != localIcon
                    || custom.description != localDescription
                    || custom.promptModifier != localPrompt
            else {
                return
            }

            var updated = custom
            updated.update(
                name: resolvedName,
                icon: localIcon,
                description: localDescription,
                prompt: localPrompt,
                instructionSuggestions: custom.instructionSuggestions
            )
            customStore.updatePersona(updated)
            return
        }

        if (personaManager.customPrompts[personaManager.selectedPersona] ?? "") != localPrompt {
            personaManager.saveCustomPrompt(
                for: personaManager.selectedPersona,
                prompt: localPrompt
            )
        }
    }

    private func polishPrompt() {
        let draft = localPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty, !promptPolisher.isGenerating else { return }

        let personaID = selectedCustomPersona?.id
        polishError = nil
        saveChangesIfNeeded()
        HapticFeedbackManager.shared.tap()

        Task {
            do {
                let polished = try await promptPolisher.polishInstructions(
                    draft,
                    config: settingsViewModel.config
                )
                guard selectedCustomPersona?.id == personaID else { return }
                guard localPrompt.trimmingCharacters(in: .whitespacesAndNewlines) == draft else {
                    polishError = "The prompt changed while Sorty was working, so your newer draft was kept."
                    return
                }

                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    localPrompt = polished
                }
                saveChangesIfNeeded()
                HapticFeedbackManager.shared.success()
                NotificationManager.shared.showHUDInfo(
                    title: "Prompt Cleaned Up",
                    message: "Your intent was preserved and the rules were structured automatically.",
                    icon: "wand.and.stars",
                    iconColor: .purple,
                    identifier: "persona-prompt-polished"
                )
            } catch {
                polishError = error.localizedDescription
                HapticFeedbackManager.shared.error()
            }
        }
    }

    private func requestDeletion(of persona: CustomPersona) {
        personaPendingDeletion = persona
        showingDeleteConfirmation = true
        HapticFeedbackManager.shared.tap()
    }

    private func deletePendingPersona() {
        guard let persona = personaPendingDeletion else { return }

        let fallbackPersonaID = customStore.selectionAfterDeletingPersona(id: persona.id)
        customStore.deletePersona(id: persona.id)
        if personaManager.selectedCustomPersonaId == persona.id {
            if let fallbackPersonaID {
                personaManager.selectCustomPersona(fallbackPersonaID)
            } else {
                personaManager.selectPersona(personaManager.selectedPersona)
            }
        }
        personaPendingDeletion = nil
        HapticFeedbackManager.shared.error()
        NotificationManager.shared.showHUDInfo(
            title: "Persona Deleted",
            message: "\(persona.name) was removed.",
            icon: "trash.fill",
            iconColor: .red,
            identifier: "persona-deleted"
        )
    }

    private var selectedCustomPersona: CustomPersona? {
        guard let customId = personaManager.selectedCustomPersonaId else { return nil }
        return customStore.customPersonas.first(where: { $0.id == customId })
    }

    // ponytail: fixed 2-row cap (12 at 6 columns), expand to per-column rows if grid shape ever changes.
    private var collapsedCustomLimit: Int { 12 }

    private var visibleCustomPersonas: [CustomPersona] {
        guard !isCustomExpanded else { return customStore.customPersonas }
        return Array(customStore.customPersonas.prefix(collapsedCustomLimit))
    }

    private var personaGridColumns: [GridItem] {
        let columnCount = min(
            max(PersonaType.allCases.count, customStore.customPersonas.count),
            6
        )

        return Array(
            repeating: GridItem(.flexible(minimum: 10, maximum: .infinity), spacing: 8),
            count: columnCount
        )
    }
}

private enum PersonaEditableField: Hashable {
    case name
    case description
    case prompt
}

// MARK: - Custom Persona Button

struct CustomPersonaButton: View {
    @SortyHotReload private var hotReload
    let persona: CustomPersona
    let isSelected: Bool
    let isHovering: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            personaButtonLabel(name: persona.name, icon: persona.icon)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Delete \(persona.name)", onDelete)
        .contextMenu {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func personaButtonLabel(name: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.body)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text(name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 68, maxHeight: 68)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    isSelected ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.15) : Color.clear
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            isSelected
                                ? SortyDesignSystem.Colors.resolvedAccent
                                : Color.secondary.opacity(isHovering ? 0.5 : 0.2),
                            lineWidth: isSelected ? 2 : 1
                        )
                }
        )
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .scaleEffect(isHovering && !isSelected ? 1.02 : 1.0)
        .contentShape(Rectangle())
    }
}

struct PersonaButton: View {
    @SortyHotReload private var hotReload
    let persona: PersonaType
    let isSelected: Bool
    let isHovering: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: persona.icon)
                    .font(.body)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)

                Text(persona.displayName)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity, minHeight: 68, maxHeight: 68)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        isSelected ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.15) : Color.clear
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isSelected
                                    ? SortyDesignSystem.Colors.resolvedAccent
                                    : Color.secondary.opacity(isHovering ? 0.5 : 0.2),
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .scaleEffect(isHovering && !isSelected ? 1.02 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Compact inline picker for the ready-to-organize screen
struct CompactPersonaPicker: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var customStore: CustomPersonaStore
    @State private var isHovering = false

    var body: some View {
        Menu {
            Section("Built-in") {
                ForEach(PersonaType.allCases, id: \.self) { persona in
                    Button {
                        personaManager.selectPersona(persona)
                        AnalyticsManager.shared.capturePersonaInventory(
                            action: "persona_selected",
                            customPersonaCount: customStore.customPersonas.count,
                            selectionKind: "built_in"
                        )
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(persona.displayName)
                                Text(persona.description)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: persona.icon)
                        }
                    }
                }
            }

            if !customStore.customPersonas.isEmpty {
                Section("Custom") {
                    ForEach(customStore.customPersonas) { custom in
                        Button {
                            personaManager.selectCustomPersona(custom.id)
                            AnalyticsManager.shared.capturePersonaInventory(
                                action: "persona_selected",
                                customPersonaCount: customStore.customPersonas.count,
                                selectionKind: "custom"
                            )
                        } label: {
                            Label(custom.name, systemImage: custom.icon)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: currentIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                    .frame(width: 18)
                    .symbolReplaceTransition(animationValue: currentIcon)
                    .accessibilityHidden(true)

                Text(currentName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .numericTextTransition(animationValue: currentName)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .systemLiquidGlassBackground(cornerRadius: 12)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        SortyDesignSystem.Colors.resolvedAccent.opacity(isHovering ? 0.36 : 0.18),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: SortyDesignSystem.Colors.resolvedAccent.opacity(isHovering ? 0.16 : 0.05),
                radius: isHovering ? 9 : 4,
                y: isHovering ? 4 : 2
            )
            .scaleEffect(isHovering ? 1.015 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isHovering)
        }
        .menuStyle(.borderlessButton)
        .onHover { hovering in
            guard hovering != isHovering else { return }
            isHovering = hovering
            if hovering {
                HapticFeedbackManager.shared.light()
            }
        }
        .help("Organization style: \(currentName). \(currentDescription)")
        .accessibilityLabel("Organization style")
        .accessibilityValue(currentName)
    }

    private var currentIcon: String {
        if let customId = personaManager.selectedCustomPersonaId,
            let custom = customStore.customPersonas.first(where: { $0.id == customId })
        {
            return custom.icon
        }
        return personaManager.selectedPersona.icon
    }

    private var currentName: String {
        if let customId = personaManager.selectedCustomPersonaId,
            let custom = customStore.customPersonas.first(where: { $0.id == customId })
        {
            return custom.name
        }
        return personaManager.selectedPersona.displayName
    }

    private var currentDescription: String {
        if let customId = personaManager.selectedCustomPersonaId,
            let custom = customStore.customPersonas.first(where: { $0.id == customId })
        {
            return custom.description
        }
        return personaManager.selectedPersona.description
    }
}

#Preview("Persona Picker") {
    PersonaPickerView()
        .environmentObject(PersonaManager())
        .environmentObject(CustomPersonaStore())
        .environmentObject(SettingsViewModel())
        .environmentObject(AppState())
        .padding()
        .frame(width: 400)
}

#Preview("Compact Picker") {
    CompactPersonaPicker()
        .environmentObject(PersonaManager())
        .environmentObject(CustomPersonaStore())
        .padding()
}
