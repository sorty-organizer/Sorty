import SwiftUI
import UniformTypeIdentifiers

// MARK: - Validation
extension AddExclusionRuleView {
    var categorySummary: String {
        let examples = selectedFileTypeCategory.extensions.prefix(6).map { ".\($0)" }
        guard !examples.isEmpty else {
            return "Files not covered by the standard categories."
        }
        return "Includes \(examples.joined(separator: ", "))\(selectedFileTypeCategory.extensions.count > 6 ? ", and more." : ".")"
    }

    var selectedRuleType: ExclusionRuleType? {
        switch selectedIntent {
        case .folder: .pathContains
        case .finderTag: .finderTag
        case .fileKind: fileKindChoice == .category ? .fileType : .fileExtension
        case .name: nameMatchChoice == .fileName ? .fileName : .folderName
        case .properties:
            switch propertyChoice {
            case .fileSize: .fileSize
            case .modificationDate: .modificationDate
            case .creationDate: .creationDate
            }
        case .advanced:
            switch advancedChoice {
            case .hiddenFiles: .hiddenFiles
            case .systemFiles: .systemFiles
            case .pathContains: .pathContains
            case .regex: .regex
            }
        case nil: nil
        }
    }

    var isValidInput: Bool {
        guard let selectedIntent, let selectedRuleType else { return false }

        if selectedIntent == .folder {
            return selectedFolderURL != nil
        }

        switch selectedRuleType {
        case .hiddenFiles, .systemFiles, .finderTag, .fileType:
            return true
        case .fileSize, .creationDate, .modificationDate:
            return numericValue > 0
        case .customScript:
            return false
        case .regex:
            guard !trimmedPattern.isEmpty else { return false }
            return ExclusionRulePatternValidator.regexIssue(
                trimmedPattern,
                caseSensitive: caseSensitive
            ) == nil
        default:
            return !trimmedPattern.isEmpty
        }
    }

    var trimmedPattern: String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Inline explanation for a regular expression the matcher cannot compile.
    var patternValidationIssue: String? {
        guard selectedRuleType == .regex, !trimmedPattern.isEmpty else { return nil }
        return ExclusionRulePatternValidator.regexIssue(
            trimmedPattern,
            caseSensitive: caseSensitive
        )
    }

    /// Builds the rule the editor currently describes, or nil when nothing is chosen.
    func configuredRule() -> ExclusionRule? {
        guard let selectedIntent, let selectedRuleType else { return nil }

        if selectedIntent == .folder, let selectedFolderURL {
            let normalizedPath = selectedFolderURL.standardizedFileURL.path
            let folderName = selectedFolderURL.lastPathComponent
            return ExclusionRule(
                type: .pathContains,
                pattern: normalizedPath,
                description: folderName.isEmpty ? "Protected folder" : folderName,
                pathMatchMode: .folderTree,
                caseSensitive: caseSensitive,
                negated: negated
            )
        }

        switch selectedRuleType {
        case .finderTag:
            return ExclusionRule(
                type: .finderTag,
                pattern: String(selectedFinderTag.rawValue),
                description: description.isEmpty
                    ? "\(selectedFinderTag.name) Finder tag"
                    : description
            )
        case .fileSize, .creationDate, .modificationDate:
            return ExclusionRule(
                type: selectedRuleType,
                description: description.isEmpty ? nil : description,
                numericValue: selectedRuleType == .fileSize
                    ? numericValue * sizeUnit.megabyteMultiplier
                    : numericValue * dateAgeUnit.secondsMultiplier / ExclusionAgeUnit.days.secondsMultiplier,
                comparisonGreater: comparisonGreater,
                sizeUnit: selectedRuleType == .fileSize ? sizeUnit : nil,
                ageUnit: selectedRuleType == .fileSize ? nil : dateAgeUnit,
                ageIntervalSeconds: selectedRuleType == .fileSize
                    ? nil
                    : numericValue * dateAgeUnit.secondsMultiplier,
                caseSensitive: caseSensitive,
                negated: negated
            )
        case .fileType:
            return ExclusionRule(
                type: .fileType,
                description: description.isEmpty ? nil : description,
                fileTypeCategory: selectedFileTypeCategory,
                caseSensitive: caseSensitive,
                negated: negated
            )
        default:
            return ExclusionRule(
                type: selectedRuleType,
                pattern: trimmedPattern,
                description: description.isEmpty ? nil : description,
                pathMatchMode: selectedRuleType == .pathContains ? .substring : nil,
                caseSensitive: caseSensitive,
                negated: negated
            )
        }
    }

    func addRule() {
        guard let rule = configuredRule() else { return }
        save(rule)
    }

    func save(_ rule: ExclusionRule) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            persist(rule)
        }
        dismiss()
    }

    /// Applies an editor-built rule to the active condition, or adds it as a new rule.
    func persist(_ rule: ExclusionRule) {
        if let editingRule,
           let conditionToUpdate = relatedRules.first(where: { $0.id == activeConditionID })
                ?? (relatedRules.count == 1 ? editingRule : nil) {
            let updatedRule = ExclusionRule(
                id: conditionToUpdate.id,
                type: rule.type,
                pattern: rule.pattern,
                isEnabled: conditionToUpdate.isEnabled,
                description: rule.description,
                isBuiltIn: conditionToUpdate.isBuiltIn,
                isAIGenerated: conditionToUpdate.isAIGenerated ?? false,
                conditionGroupID: conditionToUpdate.conditionGroupID,
                pathMatchMode: rule.pathMatchMode,
                numericValue: rule.numericValue,
                comparisonGreater: rule.comparisonGreater,
                sizeUnit: rule.sizeUnit,
                ageUnit: rule.ageUnit,
                ageIntervalSeconds: rule.ageIntervalSeconds,
                fileTypeCategory: rule.fileTypeCategory,
                caseSensitive: rule.caseSensitive,
                negated: rule.negated
            )
            rulesManager.updateRule(updatedRule)
        } else {
            rulesManager.addRule(rule)
        }
    }
}
