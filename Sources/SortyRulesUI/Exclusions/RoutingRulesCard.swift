//
//  RoutingRulesCard.swift
//  Sorty
//
//  Write and manage routing rules in plain language (Labs: Routing Rules).
//

import SwiftUI

/// Turns a sentence like "bank statements go to Finance/Statements/{YYYY}"
/// into a saved rule. The AI runs once here; organizing later matches the
/// rule locally and skips the AI for those files.
struct RoutingRulesCard: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject private var store = RoutingRulesStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var request = ""
    @State private var isResolving = false
    @State private var draft: RoutingRule?
    @State private var errorMessage: String?
    @FocusState private var isRequestFocused: Bool

    var body: some View {
        SettingsCard(title: "Routing Rules", icon: "arrow.triangle.branch", color: .teal, count: store.rules.count) {
            VStack(alignment: .leading, spacing: 12) {
                if let draft {
                    draftPreview(draft)
                        .transition(.blurReplace.combined(with: .opacity))
                } else {
                    requestEditor
                }

                if let errorMessage {
                    InlineNotice(title: "Couldn't create the rule", message: errorMessage, severity: .warning)
                }

                if !store.rules.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(store.rules) { rule in
                            RoutingRuleRow(rule: rule)
                        }
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: draft)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: store.rules)
    }

    private var requestEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Say which files go where. Matching files skip the AI and always land in the same place.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField(
                    "Bank statements go to Finance/Statements/{YYYY}",
                    text: $request,
                    axis: .vertical
                )
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .focused($isRequestFocused)
                .onSubmit { Task { await resolve() } }
                .accessibilityIdentifier("RoutingRuleRequestField")

                Button {
                    Task { await resolve() }
                } label: {
                    if isResolving {
                        SortyGradientCircularLoader(size: 12, lineWidth: 2)
                    } else {
                        Label("Create", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.sortyPrimary(size: .small))
                .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResolving)
                .accessibilityIdentifier("RoutingRuleCreateButton")
            }
        }
    }

    private func draftPreview(_ rule: RoutingRule) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Files that match")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(rule.conditions) { condition in
                    Label(condition.displayDescription, systemImage: condition.aiToolIcon)
                        .font(.callout)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Go to")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Folder", text: Binding(
                    get: { draft?.destinationTemplate ?? "" },
                    set: { draft?.destinationTemplate = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("RoutingRuleDestinationField")
                Text("Relative to the folder being organized. {YYYY}, {MM}, {DD} and {Month} use each file's creation date.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                Button {
                    HapticFeedbackManager.shared.tap()
                    draft = nil
                    isRequestFocused = true
                } label: {
                    Label("Edit Request", systemImage: "pencil")
                }
                .systemLiquidGlassButton()

                Spacer()

                Button {
                    save()
                } label: {
                    Label("Save Rule", systemImage: "checkmark")
                }
                .buttonStyle(.sortyPrimary(size: .small))
                .disabled(RoutingRule.sanitizedTemplate(draft?.destinationTemplate ?? "").isEmpty)
                .accessibilityIdentifier("RoutingRuleSaveButton")
            }
        }
        .padding(12)
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
    }

    private func resolve() async {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResolving else { return }
        isResolving = true
        errorMessage = nil
        defer { isResolving = false }
        do {
            let client = try AIClientFactory.createClient(config: settingsViewModel.config)
            let resolution = try await NaturalLanguageExclusionResolver.resolveRouting(
                client: client,
                description: String(text.prefix(300))
            )
            draft = RoutingRule(
                sourceText: text,
                conditions: resolution.conditions,
                destinationTemplate: resolution.destinationTemplate
            )
            HapticFeedbackManager.shared.success()
        } catch {
            errorMessage = error.localizedDescription
            HapticFeedbackManager.shared.error()
        }
    }

    private func save() {
        guard var rule = draft else { return }
        rule.destinationTemplate = RoutingRule.sanitizedTemplate(rule.destinationTemplate)
        store.add(rule)
        draft = nil
        request = ""
        HapticFeedbackManager.shared.success()
    }
}

private struct RoutingRuleRow: View {
    @SortyHotReload private var hotReload
    let rule: RoutingRule
    @ObservedObject private var store = RoutingRulesStore.shared
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { isOn in
                    HapticFeedbackManager.shared.selection()
                    var updated = rule
                    updated.isEnabled = isOn
                    store.update(updated)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityLabel("Enable rule")

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.sourceText)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(rule.conditionSummary) → \(rule.destinationTemplate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .opacity(rule.isEnabled ? 1 : 0.55)

            Spacer()

            Button {
                HapticFeedbackManager.shared.tap()
                store.remove(id: rule.id)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovered ? 1 : 0)
            .accessibilityLabel("Delete rule")
        }
        .padding(10)
        .systemLiquidGlassBackground(cornerRadius: 10, clear: true, interactive: false)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityIdentifier("RoutingRuleRow")
    }
}
