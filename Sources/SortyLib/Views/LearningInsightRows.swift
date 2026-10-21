import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Pending Rule Approval

/// Low-confidence induced rules start as `.pendingApproval`: the model sees
/// them only as flagged candidates and they never apply on their own. Rule
/// rows use this to say so, and the Approve button promotes the rule to active.
func ruleStateLabel(_ rule: InferredRule) -> String {
    if rule.status == .pendingApproval {
        return rule.isEnabled ? "Awaiting approval" : "Awaiting approval, disabled"
    }
    return rule.isEnabled ? "Enabled" : "Disabled"
}

func ruleApprovalLabel(_ status: RuleStatus) -> String {
    switch status {
    case .active: return "Approved"
    case .pendingApproval: return "Awaiting approval"
    case .rejected: return "Rejected"
    case .cooldown: return "Cooling down"
    }
}

struct PendingRuleApprovalButton: View {
    let rule: InferredRule
    @ObservedObject var manager: LearningsManager

    var body: some View {
        Button("Approve") {
            Task {
                await manager.approveRule(ruleId: rule.id)
                HapticFeedbackManager.shared.success()
            }
        }
        .buttonStyle(.sortyPrimary(isSecondary: true, size: .small))
        .help("Let Sorty apply this pattern on its own")
        .accessibilityLabel("Approve pattern")
        .accessibilityIdentifier("ApprovePendingRuleButton")
    }
}

// MARK: - Learning Insight Row

struct LearningInsightRow: View {
    @SortyHotReload private var hotReload
    let rule: InferredRule
    @ObservedObject var manager: LearningsManager
    @State private var isHovered = false
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: rule.isEnabled ? "checkmark.circle.fill" : "circle")
                .font(.body.bold())
                .foregroundColor(rule.isEnabled ? confidenceColor : .gray)
                .frame(width: 24)
                .symbolReplaceTransition(animationValue: rule.isEnabled)

            VStack(alignment: .leading, spacing: 3) {
                Text(rule.explanation)
                    .font(.subheadline)
                    .foregroundColor(rule.isEnabled ? .primary : .secondary)

                HStack(spacing: 8) {
                    if rule.successCount > 0 {
                        Text("\(rule.successCount) applied")
                            .font(.caption2)
                            .foregroundColor(.green)
                            .numericTextTransition(animationValue: rule.successCount)
                    }
                    if rule.failureCount > 0 {
                        Text("\(rule.failureCount) corrected")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .numericTextTransition(animationValue: rule.failureCount)
                    }
                    if case .folder = rule.scope {
                        Text(rule.scope.displayName)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                if settingsViewModel.config.showStatsForNerds {
                    HStack(spacing: 8) {
                        Text("Used \(rule.successCount + rule.failureCount) times")
                        if rule.successCount + rule.failureCount > 0 {
                            Text("\(rule.successRate.formatted(.percent.precision(.fractionLength(0)))) accepted")
                        }
                        if let lastAppliedAt = rule.lastAppliedAt {
                            Text("Last used \(lastAppliedAt, format: .relative(presentation: .named))")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if rule.status == .pendingApproval {
                PendingRuleApprovalButton(rule: rule, manager: manager)
            }

            Toggle(
                "",
                isOn: Binding(
                    get: { rule.isEnabled },
                    set: { newValue in
                        Task {
                            HapticFeedbackManager.shared.selection()
                            await manager.setRuleEnabled(ruleId: rule.id, enabled: newValue)
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .scaleEffect(0.7)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(isHovered ? 0.06 : 0))
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            if hovering { HapticFeedbackManager.shared.selection() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rule.explanation). \(ruleStateLabel(rule))")
    }

    private var confidenceColor: Color {
        if rule.failureRate > 0.3 { return .red }
        if rule.failureRate > 0.15 { return .orange }
        return .green
    }
}
