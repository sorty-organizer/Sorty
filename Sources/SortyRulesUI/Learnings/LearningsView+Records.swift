import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Records
extension LearningsView {
    @ViewBuilder
    func learningRecordsList(
        category: LearningRecordsCategory,
        profile: LearningsProfile
    ) -> some View {
        switch category {
        case .patterns:
            learningRecordSection(title: "Inferred Patterns", count: profile.inferredRules.count) {
                ForEach(profile.inferredRules.sorted { $0.priority > $1.priority }) { rule in
                    learningPatternRecordRow(rule)
                }
            }

        case .sessions:
            learningRecordSection(title: "Organization Sessions", count: profile.sessions.count) {
                ForEach(profile.sessions.sorted { $0.timestamp > $1.timestamp }) { session in
                    learningRecordRow(
                        title: URL(fileURLWithPath: session.folderPath).lastPathComponent,
                        detail: sessionDetail(session),
                        date: session.completedAt ?? session.timestamp,
                        systemImage: session.wasReverted ? "arrow.uturn.backward" : "folder",
                        fields: sessionRecordFields(session)
                    )
                }
            }

        case .feedback:
            feedbackRecordSections(profile: profile)

        case .instructions:
            instructionRecordSections(profile: profile)

        case .supportingData:
            supportingDataRecordSections(profile: profile)
        }
    }

    @ViewBuilder
    func feedbackRecordSections(profile: LearningsProfile) -> some View {
        learningRecordSection(title: "Observed Changes", count: profile.postOrganizationChanges.count) {
            ForEach(profile.postOrganizationChanges.sorted { $0.timestamp > $1.timestamp }) { change in
                learningRecordRow(
                    title: "Moved after organization",
                    detail: "\(safeFileName(change.originalPath)) → \(safeFileName(change.newPath))",
                    date: change.timestamp,
                    systemImage: "arrow.right",
                    fields: [
                        LearningRecordField(label: "Original Item", value: safeFileName(change.originalPath)),
                        LearningRecordField(label: "New Location", value: safeFileName(change.newPath)),
                        LearningRecordField(label: "Originally Organized by Sorty", value: change.wasAIOrganized ? "Yes" : "No"),
                    ]
                )
            }
        }
        learningRecordSection(title: "Cancelled Plans", count: profile.cancelledOrganizations.count) {
            ForEach(profile.cancelledOrganizations.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: safeFileName(item.folderPath),
                    detail: "Cancelled during \(item.cancelledAtStage) · \(item.fileCount) files",
                    date: item.timestamp,
                    systemImage: "xmark.circle",
                    fields: cancelledOrganizationFields(item)
                )
            }
        }
        learningRecordSection(title: "Regenerated Plans", count: profile.regeneratedOrganizations.count) {
            ForEach(profile.regeneratedOrganizations.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: safeFileName(item.folderPath),
                    detail: item.guidingInstruction ?? "Regenerated \(item.regenerationCount) time\(item.regenerationCount == 1 ? "" : "s")",
                    date: item.timestamp,
                    systemImage: "arrow.clockwise",
                    fields: regeneratedOrganizationFields(item)
                )
            }
        }
        learningRecordSection(
            title: "Accepted Regeneration Differences",
            count: profile.regenerationPreferenceEvidence.count
        ) {
            ForEach(profile.regenerationPreferenceEvidence.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: safeFileName(item.folderPath),
                    detail: "Compared the accepted plan with \(item.attempts.count) earlier attempt\(item.attempts.count == 1 ? "" : "s")",
                    date: item.timestamp,
                    systemImage: "arrow.clockwise.circle",
                    fields: regenerationPreferenceFields(item)
                )
            }
        }
        learningRecordSection(title: "Rename Feedback", count: profile.renameFeedbackHistory.count) {
            ForEach(profile.renameFeedbackHistory.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: item.originalName,
                    detail: "\(item.action.rawValue.capitalized): \(item.finalName ?? item.suggestedName ?? item.originalName)",
                    date: item.timestamp,
                    systemImage: "text.cursor",
                    fields: renameFeedbackFields(item)
                )
            }
        }
        learningRecordSection(title: "History Reverts", count: profile.historyReverts.count) {
            ForEach(profile.historyReverts.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: item.folderPath.map(safeFileName) ?? "Reverted organization",
                    detail: item.reason ?? "Reverted \(item.operationCount) operation\(item.operationCount == 1 ? "" : "s")",
                    date: item.timestamp,
                    systemImage: "arrow.uturn.backward",
                    fields: [
                        LearningRecordField(label: "Operations Reverted", value: "\(item.operationCount)"),
                        LearningRecordField(label: "Reason", value: item.reason ?? "No reason recorded"),
                    ]
                )
            }
        }
        labeledExampleSection(title: "Corrections", items: profile.corrections)
        labeledExampleSection(title: "Rejections", items: profile.rejections)
        labeledExampleSection(title: "Positive Examples", items: profile.positiveExamples)
        learningRecordSection(title: "Inline Answers", count: profile.inlineLearningMomentAnswers.count) {
            ForEach(profile.inlineLearningMomentAnswers.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: item.selectedOption,
                    detail: "Answer to an inline learning question",
                    date: item.timestamp,
                    systemImage: "checkmark.bubble",
                    fields: [
                        LearningRecordField(label: "Selected Answer", value: item.selectedOption),
                        LearningRecordField(label: "Question Record", value: item.momentId),
                    ]
                )
            }
        }
    }

    @ViewBuilder
    func instructionRecordSections(profile: LearningsProfile) -> some View {
        userInstructionSection(title: "Additional Instructions", items: profile.additionalInstructionsHistory)
        userInstructionSection(title: "Guiding Instructions", items: profile.guidingInstructionsHistory)
        learningRecordSection(title: "Steering Prompts", count: profile.steeringPrompts.count) {
            ForEach(profile.steeringPrompts.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: item.prompt,
                    detail: item.folderPath.map { "Folder: \(safeFileName($0))" },
                    date: item.timestamp,
                    systemImage: "arrow.triangle.turn.up.right.diamond",
                    fields: [
                        LearningRecordField(label: "Instruction", value: item.prompt),
                        LearningRecordField(label: "Folder", value: item.folderPath.map(safeFileName) ?? "All folders"),
                    ]
                )
            }
        }
    }

    @ViewBuilder
    func supportingDataRecordSections(profile: LearningsProfile) -> some View {
        learningRecordSection(title: "Applied Jobs", count: profile.jobHistory.count) {
            ForEach(profile.jobHistory.sorted { $0.timestamp > $1.timestamp }) { job in
                learningRecordRow(
                    title: job.projectName,
                    detail: "\(job.entries.count) operation\(job.entries.count == 1 ? "" : "s") · \(String(describing: job.status))",
                    date: job.timestamp,
                    systemImage: "tray.full",
                    fields: [
                        LearningRecordField(label: "Operations", value: "\(job.entries.count)"),
                        LearningRecordField(label: "Status", value: String(describing: job.status).capitalized),
                        LearningRecordField(label: "Backup", value: job.backupMode.displayName),
                    ]
                )
            }
        }
        learningRecordSection(title: "Learning Exclusions", count: profile.learningExclusionPatterns.count) {
            ForEach(profile.learningExclusionPatterns, id: \.self) { pattern in
                learningRecordRow(
                    title: safeFileName(pattern),
                    detail: "Excluded from learning",
                    date: nil,
                    systemImage: "eye.slash",
                    fields: [
                        LearningRecordField(label: "Folder", value: safeFileName(pattern)),
                        LearningRecordField(label: "Effect", value: "Sorty does not collect learning signals from this location."),
                    ]
                )
            }
        }
        learningRecordSection(title: "Rejected Pattern Cooldowns", count: profile.rejectedRuleCooldowns.count) {
            ForEach(profile.rejectedRuleCooldowns.sorted { $0.value > $1.value }, id: \.key) { ruleID, date in
                learningRecordRow(
                    title: "Pattern \(ruleID.prefix(8))",
                    detail: "Ignored until \(date.formatted(date: .abbreviated, time: .shortened))",
                    date: nil,
                    systemImage: "timer",
                    fields: [
                        LearningRecordField(label: "Pattern ID", value: ruleID),
                        LearningRecordField(label: "Ignored Until", value: date.formatted(date: .long, time: .standard)),
                    ]
                )
            }
        }
    }

    @ViewBuilder
    func labeledExampleSection(title: String, items: [LabeledExample]) -> some View {
        learningRecordSection(title: title, count: items.count) {
            ForEach(items.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: safeFileName(item.srcPath),
                    detail: "\(item.action.rawValue.capitalized): \(safeFileName(item.dstPath))",
                    date: item.timestamp,
                    systemImage: "arrow.right.circle",
                    fields: [
                        LearningRecordField(label: "Source", value: safeFileName(item.srcPath)),
                        LearningRecordField(label: "Destination", value: safeFileName(item.dstPath)),
                        LearningRecordField(label: "Outcome", value: item.action.rawValue.capitalized),
                    ]
                )
            }
        }
    }

    @ViewBuilder
    func userInstructionSection(title: String, items: [UserInstruction]) -> some View {
        learningRecordSection(title: title, count: items.count) {
            ForEach(items.sorted { $0.timestamp > $1.timestamp }) { item in
                learningRecordRow(
                    title: item.instruction,
                    detail: item.folderPath.map { "Folder: \(safeFileName($0))" } ?? item.context,
                    date: item.timestamp,
                    systemImage: "text.bubble",
                    fields: instructionRecordFields(item)
                )
            }
        }
    }

    @ViewBuilder
    func learningRecordSection<Content: View>(
        title: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if count > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(title) · \(count)")
                    .font(.subheadline.bold())
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    content()
                }
                .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
            }
        }
    }

    func learningRecordRow(
        title: String,
        detail: String?,
        date: Date?,
        systemImage: String,
        fields: [LearningRecordField] = []
    ) -> some View {
        NavigationLink {
            learningRecordDetailView(
                title: title,
                systemImage: systemImage,
                fields: recordDetailFields(summary: detail, date: date, additionalFields: fields)
            )
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                if let date {
                    Text(date, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.trailing)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows this record's details")
    }

    func learningPatternRecordRow(_ rule: InferredRule) -> some View {
        HStack(spacing: 10) {
            NavigationLink {
                learningRecordDetailView(
                    title: rule.explanation,
                    systemImage: "sparkles",
                    fields: patternRecordFields(rule)
                )
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: rule.isEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(rule.isEnabled ? .green : .secondary)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.explanation)
                            .font(.subheadline)
                        Text("\(ruleStateLabel(rule)) · \(rule.scope.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.bold())
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the pattern, evidence, and usage details")

            if rule.status == .pendingApproval {
                PendingRuleApprovalButton(rule: rule, manager: manager)
            }

            Toggle(
                "Enable \(rule.explanation)",
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
            .accessibilityLabel("Enable pattern")
            .accessibilityValue(rule.isEnabled ? "On" : "Off")
        }
        .padding(12)
    }
}
