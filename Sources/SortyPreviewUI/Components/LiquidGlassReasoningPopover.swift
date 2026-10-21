//
//  LiquidGlassReasoningPopover.swift
//  Sorty
//
//  Liquid glass style popover for displaying AI reasoning and learned rule context.
//

import SwiftUI

package struct LiquidGlassReasoningButton: View {
    @SortyHotReload private var hotReload
    let suggestion: FolderSuggestion
    var learningsManager: LearningsManager?

    @State private var showPopover = false

    package init(suggestion: FolderSuggestion, learningsManager: LearningsManager? = nil) {
        self.suggestion = suggestion
        self.learningsManager = learningsManager
    }

    private var matchedRule: InferredRule? {
        guard let ruleId = suggestion.ruleId,
              let rules = learningsManager?.currentProfile?.inferredRules else { return nil }
        return rules.first { $0.id == ruleId }
    }

    private var hasContent: Bool {
        matchedRule != nil || !suggestion.reasoning.isEmpty
    }

    private var isRule: Bool {
        matchedRule != nil
    }

    package var body: some View {
        if hasContent {
            Button {
                showPopover.toggle()
            } label: {
                Image(systemName: isRule ? "sparkles" : "brain")
                    .font(.caption2)
                    .symbolReplaceTransition(animationValue: isRule)
                    .foregroundStyle(
                        showPopover
                            ? (isRule ? Color.orange : Color.purple)
                            : .secondary
                    )
            }
            .buttonStyle(.plain)
            .help(isRule ? "View learned rule" : "View AI reasoning")
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                LiquidGlassReasoningPopover(
                    suggestion: suggestion,
                    matchedRule: matchedRule
                )
                .systemLiquidGlassPopover(cornerRadius: 12)
            }
        }
    }
}

struct LiquidGlassReasoningPopover: View {
    @SortyHotReload private var hotReload
    let suggestion: FolderSuggestion
    let matchedRule: InferredRule?

    private var isRule: Bool {
        matchedRule != nil
    }

    private var accentColor: Color {
        isRule ? .orange : .purple
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: isRule ? "sparkles" : "brain")
                    .font(.caption)
                    .foregroundStyle(accentColor)
                    .symbolReplaceTransition(animationValue: isRule)

                Text(isRule ? "Learned Rule" : "AI Reasoning")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .numericTextTransition(animationValue: isRule)

                Spacer()

                Text(suggestion.folderName.hasPrefix("/")
                     ? URL(fileURLWithPath: suggestion.folderName).lastPathComponent
                     : suggestion.folderName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if let rule = matchedRule {
                FormattedReasoningText(
                    text: rule.explanation,
                    font: .callout,
                    secondaryFont: .caption,
                    foregroundStyle: .primary
                )

                if !suggestion.reasoning.isEmpty {
                    Text(FeatureFlags.privacyModeEnabled ? PrivacyPathMasker.redactedText(suggestion.reasoning) : suggestion.reasoning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            } else {
                FormattedReasoningText(
                    text: suggestion.reasoning,
                    font: .callout,
                    secondaryFont: .caption,
                    foregroundStyle: .primary
                )
            }
        }
        .padding(12)
        .frame(minWidth: 240, maxWidth: 340)
    }
}

#Preview("Liquid Glass - AI Reasoning") {
    let suggestion = FolderSuggestion(
        folderName: "Documents",
        reasoning: "These files share a common PDF format and appear to be work-related documents that belong together."
    )
    LiquidGlassReasoningButton(suggestion: suggestion)
        .padding()
}

#Preview("Liquid Glass - Empty") {
    let suggestion = FolderSuggestion(folderName: "Misc")
    LiquidGlassReasoningButton(suggestion: suggestion)
        .padding()
}
