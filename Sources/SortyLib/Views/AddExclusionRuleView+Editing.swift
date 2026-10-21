import SwiftUI
import UniformTypeIdentifiers

// MARK: - Editing
extension AddExclusionRuleView {
    var editorContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if isEmbedded, selectedIntent != nil {
                manualEditorControls
            }
            if relatedRules.count > 1 {
                linkedConditionsView
            }
            if let selectedIntent {
                configurationView(for: selectedIntent)
            } else {
                intentPicker
            }
        }
    }

    var manualEditorControls: some View {
        HStack {
            Button {
                HapticFeedbackManager.shared.selection()
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedIntent = nil
                    selectedFolderURL = nil
                }
            } label: {
                Label("Back", systemImage: "chevron.left")
            }

            Spacer()

            Button("Add Exclusion") {
                HapticFeedbackManager.shared.success()
                addRule()
            }
            .buttonStyle(.sortyPrimary(size: .small))
            .disabled(!isValidInput)
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    var header: some View {
        HStack {
            if selectedIntent == nil {
                Button("Cancel") {
                    HapticFeedbackManager.shared.tap()
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button {
                    HapticFeedbackManager.shared.selection()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedIntent = nil
                        selectedFolderURL = nil
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .keyboardShortcut(.escape, modifiers: [])
            }

            Spacer()

            Text(editingRule == nil ? (selectedIntent == nil ? "Add an Exclusion" : "Set Up Exclusion") : "Edit Exclusion")
                .font(.headline)

            Spacer()

            if selectedIntent != nil {
                Button(editingRule == nil ? "Add Exclusion" : "Save Changes") {
                    HapticFeedbackManager.shared.success()
                    addRule()
                }
                .buttonStyle(.sortyPrimary)
                .onboardingBeamBorder(variant: .warning, active: isValidInput)
                .disabled(!isValidInput)
                .keyboardShortcut(.return, modifiers: [.command])
            } else {
                Button("Cancel") {}
                    .hidden()
            }
        }
        .padding()
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
    }

    var intentPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What should Sorty exclude?")
                    .font(.title3.weight(.semibold))

                Text("Choose the closest match. You’ll only see the settings that apply.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)

            ForEach(ExclusionIntent.allCases) { intent in
                Button {
                    HapticFeedbackManager.shared.selection()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedIntent = intent
                        if let relatedRule = relatedRules.first(where: {
                            Self.intent(for: $0) == intent
                        }) {
                            loadCondition(relatedRule)
                        }
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: intent.icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                            .frame(width: 34, height: 34)
                            .background(SortyDesignSystem.Colors.resolvedAccent.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(intent.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(intent.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .systemLiquidGlassBackground(cornerRadius: 12)
            }
        }
    }

    var linkedConditionsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(displayedExceptionName)
                .font(.headline)
            Text("Sorty excludes an item only when every condition below matches.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(relatedRules) { condition in
                let displayedCondition = currentCondition(for: condition)

                Button {
                    selectLinkedCondition(displayedCondition)
                } label: {
                    HStack {
                        Image(systemName: displayedCondition.aiToolIcon)
                            .foregroundStyle(
                                displayedCondition.id == activeConditionID
                                    ? Color.accentColor
                                    : Color.secondary
                            )
                            .accessibilityHidden(true)
                        Text(displayedCondition.interpretedMatchDescription)
                            .foregroundStyle(.primary)
                        Spacer()
                        if displayedCondition.id == activeConditionID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    displayedCondition.id == activeConditionID
                        ? Color.accentColor.opacity(0.10)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
        .padding(14)
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
    }

    var displayedExceptionName: String {
        let name = relatedRules.compactMap(\.description).first
            ?? editingRule?.displayDescription
            ?? "Edit exclusion"
        guard let first = name.first else { return "Edit exclusion" }
        return first.uppercased() + name.dropFirst()
    }

    @ViewBuilder
    func configurationView(for intent: ExclusionIntent) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label(intent.title, systemImage: intent.icon)
                    .font(.title3.weight(.semibold))
                Text(intent.explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                switch intent {
                case .folder:
                    folderConfiguration
                case .finderTag:
                    finderTagConfiguration
                case .fileKind:
                    fileKindConfiguration
                case .name:
                    nameConfiguration
                case .properties:
                    propertyConfiguration
                case .advanced:
                    advancedConfiguration
                }
            }
            .padding(16)
            .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)

            if intent != .folder {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Label (optional)")
                        .font(.subheadline.weight(.semibold))
                    TextField("e.g. Old video exports", text: $description)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(16)
                .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
            }

            if supportsMatchingOptions {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Matching options")
                        .font(.subheadline.weight(.semibold))
                    Toggle("Match uppercase and lowercase separately", isOn: $caseSensitive)
                    Toggle("Exclude everything except matches", isOn: $negated)
                }
                .padding(16)
                .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
            }
        }
    }

    var supportsMatchingOptions: Bool {
        switch selectedRuleType {
        case .fileExtension, .fileName, .folderName, .pathContains, .regex:
            true
        default:
            false
        }
    }

    static func intent(for rule: ExclusionRule) -> ExclusionIntent {
        switch rule.type {
        case .pathContains where rule.isFolderTreePathRule:
            .folder
        case .finderTag:
            .finderTag
        case .fileType, .fileExtension:
            .fileKind
        case .fileName, .folderName:
            .name
        case .fileSize, .creationDate, .modificationDate:
            .properties
        case .hiddenFiles, .systemFiles, .pathContains, .regex, .customScript:
            .advanced
        }
    }

    /// Loads a linked condition, warning first when the active one has unsaved edits.
    func selectLinkedCondition(_ tappedCondition: ExclusionRule) {
        let condition = currentCondition(for: tappedCondition)
        guard condition.id != activeConditionID else { return }

        HapticFeedbackManager.shared.selection()
        if isActiveConditionDirty {
            pendingCondition = condition
            showingConditionSwitchConfirmation = true
        } else {
            switchCondition(to: condition)
        }
    }

    /// Reads the freshest saved copy so previously saved edits are not replaced
    /// by the snapshot captured when the editor opened.
    func currentCondition(for condition: ExclusionRule) -> ExclusionRule {
        rulesManager.rules.first { $0.id == condition.id } ?? condition
    }

    func switchCondition(to condition: ExclusionRule) {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedIntent = Self.intent(for: condition)
            loadCondition(condition)
        }
    }

    func saveActiveConditionAndSwitch() {
        guard let condition = pendingCondition,
              let rule = configuredRule()
        else {
            pendingCondition = nil
            return
        }

        HapticFeedbackManager.shared.success()
        persist(rule)
        pendingCondition = nil
        switchCondition(to: condition)
    }

    func discardActiveConditionChanges() {
        guard let condition = pendingCondition else { return }
        pendingCondition = nil
        switchCondition(to: condition)
    }

    var isActiveConditionDirty: Bool {
        guard let loadedConditionDraft else { return false }
        return currentConditionDraft != loadedConditionDraft
    }

    var currentConditionDraft: ExclusionConditionDraft {
        ExclusionConditionDraft(
            intent: selectedIntent,
            fileKindChoice: fileKindChoice,
            nameMatchChoice: nameMatchChoice,
            propertyChoice: propertyChoice,
            advancedChoice: advancedChoice,
            selectedFinderTag: selectedFinderTag,
            pattern: pattern,
            description: description,
            numericValue: numericValue,
            comparisonGreater: comparisonGreater,
            sizeUnit: sizeUnit,
            dateAgeUnit: dateAgeUnit,
            selectedFileTypeCategory: selectedFileTypeCategory,
            selectedFolderURL: selectedFolderURL,
            caseSensitive: caseSensitive,
            negated: negated
        )
    }

    /// Captures the values set up in `init` so the first tap on another condition
    /// can tell whether anything was edited.
    func captureInitialConditionDraftIfNeeded() {
        if loadedConditionDraft == nil {
            loadedConditionDraft = currentConditionDraft
        }
    }

    func loadCondition(_ rule: ExclusionRule) {
        activeConditionID = rule.id
        fileKindChoice = rule.type == .fileExtension ? .fileExtension : .category
        nameMatchChoice = rule.type == .folderName ? .folderName : .fileName
        propertyChoice = rule.type == .creationDate
            ? .creationDate
            : rule.type == .modificationDate ? .modificationDate : .fileSize
        advancedChoice = rule.type == .systemFiles
            ? .systemFiles
            : rule.type == .pathContains ? .pathContains : rule.type == .regex ? .regex : .hiddenFiles
        selectedFinderTag = Int(rule.pattern).flatMap(FinderTagColor.init(rawValue:)) ?? .red
        pattern = rule.pattern
        description = rule.description ?? ""
        sizeUnit = rule.sizeUnit ?? .megabytes
        dateAgeUnit = rule.ageUnit ?? .days
        if rule.type == .fileSize {
            numericValue = (rule.numericValue ?? 0) / sizeUnit.megabyteMultiplier
        } else if rule.type == .creationDate || rule.type == .modificationDate {
            numericValue = (rule.ageIntervalSeconds ?? 0) / dateAgeUnit.secondsMultiplier
        } else {
            numericValue = rule.numericValue ?? 100
        }
        selectedFileTypeCategory = rule.fileTypeCategory ?? .images
        selectedFolderURL = rule.isFolderTreePathRule
            ? URL(fileURLWithPath: rule.pattern)
            : nil
        caseSensitive = rule.caseSensitive
        negated = rule.negated
        loadedConditionDraft = currentConditionDraft
    }
}
