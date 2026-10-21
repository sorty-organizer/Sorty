import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Dashboard
extension LearningsView {
    // MARK: - What Sorty Has Learned

    var whatSortyHasLearnedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("What Sorty Has Learned")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }

            if let profile = manager.currentProfile {
                let topRules = profile.inferredRules
                    .filter { $0.isEnabled }
                    .sorted { $0.priority > $1.priority }
                    .prefix(5)
                let profileSummary = LearningsProfileArchiveSummary(profile: profile)
                let metrics = learningDataMetrics(for: profileSummary)
                let totalRecordCount = profileSummary.totalRecordCount

                if totalRecordCount == 0 {
                    emptyLearningsPlaceholder
                } else {
                    learningDataSummary(
                        metrics: metrics,
                        totalRecordCount: totalRecordCount,
                        hasActivePatterns: !topRules.isEmpty
                    )

                    if !topRules.isEmpty {
                        activePatternsPane(topRules: Array(topRules))
                    }
                }
            } else {
                emptyLearningsPlaceholder
            }
        }
    }

    /// Collapsible liquid-glass pane listing the learned rules Sorty applies.
    func activePatternsPane(topRules: [InferredRule]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                HapticFeedbackManager.shared.light()
                withAnimation(
                    reduceMotion
                        ? .easeOut(duration: 0.12)
                        : .spring(response: 0.32, dampingFraction: 0.86)
                ) {
                    isActivePatternsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Active Patterns")
                        .font(.subheadline.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("\(topRules.count)")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isActivePatternsExpanded ? 0 : -90))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ActivePatternsDisclosureButton")
            .accessibilityHint(
                isActivePatternsExpanded
                    ? "Collapses the active patterns list"
                    : "Expands the active patterns list"
            )

            if isActivePatternsExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(topRules.enumerated()), id: \.element.id) { index, rule in
                        LearningInsightRow(rule: rule, manager: manager)
                            .animatedAppearance(delay: Double(index) * 0.05)
                        if index < topRules.count - 1 {
                            Divider().padding(.leading, 36)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .top))
                )
            }
        }
        .systemLiquidGlassBackground(cornerRadius: 12)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func learningDataMetrics(
        for summary: LearningsProfileArchiveSummary
    ) -> [LearningDataMetric] {
        return [
            LearningDataMetric(
                category: .patterns,
                count: summary.inferredRules
            ),
            LearningDataMetric(
                category: .sessions,
                count: summary.sessions
            ),
            LearningDataMetric(
                category: .feedback,
                count: summary.feedbackCount
            ),
            LearningDataMetric(
                category: .instructions,
                count: summary.instructionCount
            ),
            LearningDataMetric(
                category: .supportingData,
                count: summary.supportingDataCount
            ),
        ].filter { $0.count > 0 }
    }

    func learningDataSummary(
        metrics: [LearningDataMetric],
        totalRecordCount: Int,
        hasActivePatterns: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(totalRecordCount.formatted()) stored learning record\(totalRecordCount == 1 ? "" : "s")")
                    .font(.subheadline.bold())
                Text(
                    hasActivePatterns
                        ? "Sorty uses the active patterns below when organizing."
                        : "Sorty has learning evidence saved, but has not formed an active pattern from it yet."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 125), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(metrics) { metric in
                    Button {
                        HapticFeedbackManager.shared.light()
                        selectedLearningRecordsCategory = metric.category
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: metric.category.systemImage)
                                .foregroundStyle(metric.category.color)
                                .frame(width: 16)
                                .accessibilityHidden(true)
                            Text("\(metric.count.formatted()) \(metric.category.title(for: metric.count))")
                                .font(.caption.bold())
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption2.bold())
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .systemLiquidGlassBackground(cornerRadius: 9)
                    .accessibilityHint("Shows the stored \(metric.category.title.lowercased()) records")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
    }

    func learningRecordsDetailSheet(
        category: LearningRecordsCategory,
        profile: LearningsProfile
    ) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: category.systemImage)
                        .font(.title2)
                        .foregroundStyle(category.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title)
                            .font(.title2.bold())
                        Text("Stored locally in your Learnings profile")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done") {
                        selectedLearningRecordsCategory = nil
                    }
                    .buttonStyle(.sortyPrimary(size: .small))
                }
                .padding(20)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        learningRecordsList(category: category, profile: profile)
                    }
                    .padding(20)
                }
            }
            .navigationTitle(category.title)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(category.title) learning records")
    }
}
