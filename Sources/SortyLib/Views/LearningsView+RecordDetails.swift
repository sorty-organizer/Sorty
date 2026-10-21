import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - RecordDetails
extension LearningsView {
    func learningRecordDetailView(
        title: String,
        systemImage: String,
        fields: [LearningRecordField]
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.label)
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(field.value)
                                .font(.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .accessibilityElement(children: .combine)
                        if index < fields.count - 1 {
                            Divider()
                        }
                    }
                }
                .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
            }
            .padding(20)
        }
        .navigationTitle("Record Details")
    }

    func recordDetailFields(
        summary: String?,
        date: Date?,
        additionalFields: [LearningRecordField]
    ) -> [LearningRecordField] {
        var fields = additionalFields
        if let summary, !summary.isEmpty, !fields.contains(where: { $0.value == summary }) {
            fields.insert(LearningRecordField(label: "Summary", value: summary), at: 0)
        }
        if let date {
            fields.append(
                LearningRecordField(
                    label: "Recorded",
                    value: date.formatted(date: .long, time: .standard)
                ))
        }
        return fields
    }

    func sessionRecordFields(_ session: OrganizationSession) -> [LearningRecordField] {
        var fields = [
            LearningRecordField(label: "Outcome", value: session.reaction.rawValue.capitalized),
            LearningRecordField(label: "Files Moved", value: "\(session.filesMoved.count)"),
            LearningRecordField(label: "Recorded Events", value: "\(session.events.count)"),
            LearningRecordField(label: "Corrections", value: "\(session.userCorrections.count)"),
            LearningRecordField(label: "Rename Feedback", value: "\(session.renameFeedback.count)"),
            LearningRecordField(label: "Patterns Used", value: "\(session.usedRuleIds.count)"),
            LearningRecordField(label: "Patterns That Failed", value: "\(session.failedRuleIds.count)"),
            LearningRecordField(label: "Reverted", value: session.wasReverted ? "Yes" : "No"),
        ]
        if let planSummary = session.planSummary, !planSummary.isEmpty {
            fields.insert(LearningRecordField(label: "Plan", value: planSummary), at: 1)
        }
        return fields
    }

    func patternRecordFields(_ rule: InferredRule) -> [LearningRecordField] {
        var fields = [
            LearningRecordField(label: "Status", value: ruleStateLabel(rule)),
            LearningRecordField(label: "Approval", value: ruleApprovalLabel(rule.status)),
            LearningRecordField(label: "Scope", value: rule.scope.displayName),
            LearningRecordField(label: "Pattern", value: rule.pattern),
            LearningRecordField(label: "Destination Template", value: rule.template),
            LearningRecordField(label: "Priority", value: "\(rule.priority)"),
            LearningRecordField(label: "Supporting Examples", value: "\(rule.exampleIds.count)"),
            LearningRecordField(label: "Evidence Records", value: "\(rule.evidenceIds.count)"),
            LearningRecordField(label: "Applied Successfully", value: "\(rule.successCount)"),
            LearningRecordField(label: "Corrected After Use", value: "\(rule.failureCount)"),
        ]
        if let evidence = rule.evidenceDescription, !evidence.isEmpty {
            fields.insert(LearningRecordField(label: "Evidence", value: evidence), at: 5)
        }
        if let lastAppliedAt = rule.lastAppliedAt {
            fields.append(
                LearningRecordField(
                    label: "Last Applied",
                    value: lastAppliedAt.formatted(date: .long, time: .standard)
                ))
        }
        return fields
    }

    func cancelledOrganizationFields(
        _ item: CancelledOrganization
    ) -> [LearningRecordField] {
        var fields = [
            LearningRecordField(label: "Cancelled During", value: item.cancelledAtStage),
            LearningRecordField(label: "Files", value: "\(item.fileCount)"),
            LearningRecordField(label: "Proposed Folders", value: "\(item.proposedFolderCount)"),
            LearningRecordField(label: "Regenerations", value: "\(item.regenerationCount)"),
        ]
        if let instructions = item.instructions, !instructions.isEmpty {
            fields.append(LearningRecordField(label: "Instructions", value: instructions))
        }
        if let summary = item.proposedStructureSummary, !summary.isEmpty {
            fields.append(LearningRecordField(label: "Proposed Structure", value: summary))
        }
        if let model = item.aiModel, !model.isEmpty {
            fields.append(LearningRecordField(label: "Model", value: model))
        }
        return fields
    }

    func regeneratedOrganizationFields(
        _ item: RegeneratedOrganization
    ) -> [LearningRecordField] {
        var fields = [
            LearningRecordField(label: "Regeneration Count", value: "\(item.regenerationCount)"),
            LearningRecordField(label: "Folder", value: safeFileName(item.folderPath)),
        ]
        if let instruction = item.guidingInstruction, !instruction.isEmpty {
            fields.append(LearningRecordField(label: "Guiding Instruction", value: instruction))
        }
        if let summary = item.previousPlanSummary, !summary.isEmpty {
            fields.append(LearningRecordField(label: "Previous Plan", value: summary))
        }
        return fields
    }

    func regenerationPreferenceFields(
        _ item: RegenerationPreferenceEvidence
    ) -> [LearningRecordField] {
        let changedFiles = Set(item.attempts.flatMap(\.fileChanges).map(\.fileID)).count
        var fields = [
            LearningRecordField(label: "Earlier Attempts", value: "\(item.attempts.count)"),
            LearningRecordField(label: "Files Changed", value: "\(changedFiles)"),
            LearningRecordField(label: "Accepted Version", value: "\(item.acceptedVersion)"),
        ]
        if let latest = item.attempts.last {
            fields.append(
                LearningRecordField(
                    label: "Folder Count",
                    value: "\(latest.rejectedFolderCount) → \(latest.acceptedFolderCount)"
                )
            )
            fields.append(
                LearningRecordField(
                    label: "Maximum Depth",
                    value: "\(latest.rejectedMaxDepth) → \(latest.acceptedMaxDepth)"
                )
            )
            fields.append(
                LearningRecordField(
                    label: "Unorganized Files",
                    value: "\(latest.rejectedUnorganizedCount) → \(latest.acceptedUnorganizedCount)"
                )
            )
        }
        return fields
    }

    func renameFeedbackFields(
        _ item: RenameFeedbackEvent
    ) -> [LearningRecordField] {
        var fields = [
            LearningRecordField(label: "Original Name", value: item.originalName),
            LearningRecordField(label: "Outcome", value: item.action.rawValue.capitalized),
        ]
        if let suggestedName = item.suggestedName, !suggestedName.isEmpty {
            fields.append(LearningRecordField(label: "Suggested Name", value: suggestedName))
        }
        if let finalName = item.finalName, !finalName.isEmpty {
            fields.append(LearningRecordField(label: "Final Name", value: finalName))
        }
        if let confidence = item.confidence {
            fields.append(
                LearningRecordField(
                    label: "Model Confidence",
                    value: confidence.formatted(.percent.precision(.fractionLength(0)))
                ))
        }
        return fields
    }

    func instructionRecordFields(_ item: UserInstruction) -> [LearningRecordField] {
        var fields = [
            LearningRecordField(label: "Instruction", value: item.instruction),
            LearningRecordField(
                label: "Folder",
                value: item.folderPath.map(safeFileName) ?? "All folders"
            ),
        ]
        if let context = item.context, !context.isEmpty {
            fields.append(LearningRecordField(label: "Context", value: context))
        }
        if let fileCount = item.fileCount {
            fields.append(LearningRecordField(label: "Files", value: "\(fileCount)"))
        }
        if item.isRegeneration == true {
            fields.append(LearningRecordField(label: "Used for Regeneration", value: "Yes"))
        }
        return fields
    }

    func sessionDetail(_ session: OrganizationSession) -> String {
        let reaction = session.reaction.rawValue.capitalized
        let fileSummary = "\(session.filesMoved.count) file\(session.filesMoved.count == 1 ? "" : "s")"
        let feedbackSummary = "\(session.events.count) event\(session.events.count == 1 ? "" : "s")"
        return "\(reaction) · \(fileSummary) · \(feedbackSummary)"
    }

    func safeFileName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "Folder" : name
    }

    var emptyLearningsPlaceholder: some View {
        VStack(spacing: 12) {
            Image("LearningsEmptyState")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 92, height: 92)
                .accessibilityIgnoresInvertColors()
                .opacity(emptyLearningsHasAppeared ? 1 : 0)
                .scaleEffect(emptyLearningsHasAppeared ? 1 : 0.8)
                .animation(
                    reduceMotion
                        ? .easeOut(duration: 0.12)
                        : .spring(response: 0.5, dampingFraction: 0.7).delay(0.1),
                    value: emptyLearningsHasAppeared
                )
                .accessibilityHidden(true)
            Text("No patterns learned yet")
                .font(.subheadline.bold())
                .opacity(emptyLearningsHasAppeared ? 1 : 0)
                .offset(y: emptyLearningsHasAppeared ? 0 : 8)
                .animation(
                    reduceMotion
                        ? .easeOut(duration: 0.12)
                        : .spring(response: 0.5, dampingFraction: 0.8).delay(0.2),
                    value: emptyLearningsHasAppeared)
            Text(
                "Organize some folders, and Sorty will pick up your preferences from corrections and feedback."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            .opacity(emptyLearningsHasAppeared ? 1 : 0)
            .offset(y: emptyLearningsHasAppeared ? 0 : 10)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.12)
                    : .spring(response: 0.5, dampingFraction: 0.8).delay(0.3),
                value: emptyLearningsHasAppeared)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No patterns learned yet. Organize folders to start learning.")
        .task {
            guard !emptyLearningsHasAppeared else { return }
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            emptyLearningsHasAppeared = true
        }
    }
}
