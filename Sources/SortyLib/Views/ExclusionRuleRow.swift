import SwiftUI
import UniformTypeIdentifiers

struct ExclusionRuleRow: View {
    @SortyHotReload private var hotReload
    let rule: ExclusionRule
    @ObservedObject var rulesManager: ExclusionRulesManager
    let isHighlighted: Bool
    let onEdit: () -> Void
    @State private var isHovered = false
    @State private var isShowingGroupedDeleteConfirmation = false
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    private var usage: ExclusionRuleUsage? {
        rulesManager.usageByRuleID[rule.id]
    }

    private static let systemFolderIcon: NSImage = {
        NSWorkspace.shared.icon(forFile: "/tmp")
    }()

    private var isFolderExclusion: Bool {
        rule.isFolderTreePathRule
    }

    private var isGroupedCondition: Bool {
        rule.conditionGroupID != nil
    }

    private var groupSize: Int {
        guard let groupID = rule.conditionGroupID else { return 0 }
        return rulesManager.rules.filter { $0.conditionGroupID == groupID }.count
    }

    private var groupedDeleteMessage: String {
        if groupSize > 1 {
            return "It is one of \(groupSize) conditions that must all match, so removing it loosens what this group excludes."
        }
        return "It is the last condition in its group, so removing it deletes the whole exclusion."
    }

    /// Deleting one member instantly loosens an AND group, so confirm first.
    private func requestDelete() {
        if isGroupedCondition {
            isShowingGroupedDeleteConfirmation = true
        } else {
            deleteRule()
        }
    }

    private func deleteRule() {
        HapticFeedbackManager.shared.tap()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            rulesManager.removeRule(rule)
        }
    }

    private var exclusionTitle: String {
        let value = rule.displayDescription
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }

    var body: some View {
        HStack(spacing: 12) {
            // Type icon - use system folder icon for folder rules
            ruleIcon
                .frame(width: 28, height: 28)
                .background((rule.isEnabled ? colorForType(rule.type) : .secondary).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            ruleDescription
            Spacer()

            if settingsViewModel.config.showStatsForNerds {
                ExclusionRuleUsageButton(usage: usage)
            }

            if isHovered {
                Button {
                    requestDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
                .help(isGroupedCondition ? "Remove this condition from its group" : "Remove rule")
            }

            Toggle(
                "",
                isOn: Binding(
                    get: { rule.isEnabled },
                    set: { newValue in
                        HapticFeedbackManager.shared.selection()
                        var updatedRule = rule
                        updatedRule.isEnabled = newValue
                        rulesManager.updateRule(updatedRule)
                    }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel(
                rule.isEnabled
                    ? "Disable rule: \(rule.displayDescription)"
                    : "Enable rule: \(rule.displayDescription)")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            HapticFeedbackManager.shared.selection()
            onEdit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
        .sortyFocusHighlight(
            isActive: isHighlighted,
            shape: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityValue(isHighlighted ? "Newly added" : "")
        .contextMenu {
            Button {
                HapticFeedbackManager.shared.selection()
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }

            Button(role: .destructive) {
                requestDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityAction(named: Text("Edit"), onEdit)
        .accessibilityAction(named: Text("Delete")) {
            requestDelete()
        }
        .confirmationDialog(
            "Remove this condition?",
            isPresented: $isShowingGroupedDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Condition", role: .destructive) {
                deleteRule()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(groupedDeleteMessage)
        }
    }

    @ViewBuilder
    private var ruleIcon: some View {
        if rule.type == .folderName || isFolderExclusion {
            AppKitImageView(
                image: Self.systemFolderIcon,
                size: CGSize(width: 16, height: 16),
                opacity: rule.isEnabled ? 1.0 : 0.5
            )
            .frame(width: 16, height: 16)
        } else if rule.type == .finderTag,
                  let labelNumber = Int(rule.pattern),
                  let tagColor = FinderTagColor(rawValue: labelNumber) {
            Image(systemName: "tag.fill")
                .font(.system(size: 14))
                .foregroundStyle(rule.isEnabled ? tagColor.color : .secondary)
        } else {
            Image(systemName: iconForType(rule.type))
                .font(.system(size: 14))
                .foregroundStyle(rule.isEnabled ? colorForType(rule.type) : .secondary)
        }
    }

    private func iconForType(_ type: ExclusionRuleType) -> String {
        switch type {
        case .fileExtension: return "doc.badge.gearshape"
        case .fileName: return "doc"
        case .folderName: return "folder"
        case .pathContains: return "arrow.triangle.branch"
        case .regex: return "text.magnifyingglass"
        case .fileSize: return "scalemass"
        case .creationDate: return "calendar.badge.plus"
        case .modificationDate: return "calendar.badge.clock"
        case .hiddenFiles: return "eye.slash"
        case .systemFiles: return "gearshape.2"
        case .finderTag: return "tag"
        case .fileType: return "doc.on.doc"
        case .customScript: return "applescript"
        }
    }

    private func colorForType(_ type: ExclusionRuleType) -> Color {
        switch type {
        case .fileExtension, .fileName, .folderName, .pathContains, .regex:
            return .blue
        case .fileSize, .creationDate, .modificationDate:
            return .orange
        case .hiddenFiles, .systemFiles, .finderTag, .fileType:
            return .purple
        case .customScript:
            return .green
        }
    }

    private var ruleDescription: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(exclusionTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(rule.isEnabled ? .primary : .secondary)

                if rule.isBuiltIn {
                    Text("Built-in")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else if rule.isAIGenerated == true {
                    Text("AI-created")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                if isGroupedCondition {
                    Text(groupSize > 1 ? "Group of \(groupSize)" : "Grouped")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .help("Every condition in this group must match before an item is excluded.")
                        .accessibilityLabel(
                            "Part of a group of \(max(groupSize, 1)) conditions that must all match"
                        )
                }

                if let validationIssue = rule.patternValidationIssue {
                    Label("Invalid pattern", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .help(validationIssue)
                        .accessibilityLabel("Invalid pattern. \(validationIssue)")
                }

            }

            HStack(spacing: 6) {
                Text(isFolderExclusion ? "Folder" : rule.type.friendlyName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !isFolderExclusion,
                   let description = rule.description,
                   !description.isEmpty {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(LocalizedStringKey(description))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

        }
    }
}
