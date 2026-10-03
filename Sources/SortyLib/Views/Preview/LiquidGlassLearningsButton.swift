import SwiftUI

private struct LearningsInsightRow {
    let kind: LearningsAttributionKind
    let icon: String
    let title: String
    let detail: String
    let color: Color

    init(item: LearningsAttributionItem) {
        self.kind = item.kind
        self.title = item.title
        self.detail = item.detail

        switch item.kind {
        case .learnedRule:
            self.icon = "sparkles"
            self.color = .orange
        case .ruleEvidence:
            self.icon = "doc.text.magnifyingglass"
            self.color = .mint
        }
    }
}

struct LiquidGlassLearningsButton: View {
    @SortyHotReload private var hotReload
    let file: FileItem
    let suggestion: FolderSuggestion
    var learningsManager: LearningsManager? = nil

    @State private var showPopover = false

    private var attribution: FileLearningsAttribution {
        FileLearningsAttributionResolver.resolve(
            file: file,
            suggestion: suggestion,
            profile: learningsManager?.currentProfile
        )
    }

    private var displayFileName: String {
        FeatureFlags.privacyModeEnabled
            ? PrivacyPathMasker.redactedText(file.displayName)
            : file.displayName
    }

    var body: some View {
        let resolvedAttribution = attribution
        let rows = resolvedAttribution.items.map(LearningsInsightRow.init(item:))

        if resolvedAttribution.hasContent {
            Button {
                HapticFeedbackManager.shared.selection()
                showPopover.toggle()
            } label: {
                Image(systemName: "brain.head.profile")
                    .font(.caption2)
                    .foregroundStyle(showPopover ? .teal : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("WhyPlacedButton")
            .accessibilityLabel("Why placed here")
            .help("Why placed here — view learnings used for this file")
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile")
                            .font(.caption)
                            .foregroundStyle(.teal)

                        Text("Why placed here")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        Spacer()

                        Text(displayFileName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .numericTextTransition(animationValue: displayFileName)
                    }

                    if !rows.isEmpty {
                        sectionHeader("Learnings")
                        ForEach(rows.indices, id: \.self) { index in
                            insightRow(rows[index])
                        }
                    }

                    if let rule = resolvedAttribution.rule {
                        Divider().opacity(0.4)
                        Button {
                            HapticFeedbackManager.shared.tap()
                            showPopover = false
                            Task { await learningsManager?.setRuleEnabled(ruleId: rule.id, enabled: false) }
                            HapticFeedbackManager.shared.success()
                        } label: {
                            Label("Disable this pattern", systemImage: "eye.slash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("DisablePatternButton")
                        .accessibilityLabel("Disable this pattern")
                        .help("Stop applying this learned pattern")
                    }

                }
                .padding(12)
                .frame(minWidth: 240, maxWidth: 340)
                .systemLiquidGlassPopover(cornerRadius: 12)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(.caption2)
            .foregroundStyle(.quaternary)
            .textCase(.uppercase)
    }

    private func insightRow(_ row: LearningsInsightRow) -> some View {
        let displayDetail = FeatureFlags.privacyModeEnabled
            ? PrivacyPathMasker.redactedText(row.detail)
            : row.detail

        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: row.icon)
                .font(.caption2)
                .foregroundStyle(row.color)
                .frame(width: 12, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .numericTextTransition(animationValue: row.title)

                Text(displayDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .numericTextTransition(animationValue: displayDetail)
            }
        }
    }
}
