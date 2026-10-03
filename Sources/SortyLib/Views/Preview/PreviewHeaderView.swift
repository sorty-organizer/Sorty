//
//  PreviewHeaderView.swift
//  Sorty
//
//  Header component for the preview view with title, stats, and drag hints
//

import SwiftUI

struct PreviewHeaderView: View {
    @SortyHotReload private var hotReload
    let version: Int
    let hasEdits: Bool
    let notes: String
    let totalFiles: Int
    let totalFolders: Int
    let renameCount: Int
    var onBack: (() -> Void)? = nil
    var totalVersions: Int = 1
    var isViewingHistory: Bool = false
    var currentDiffSource: OrganizationPlanDiff.Source? = nil
    var previousDiffSource: OrganizationPlanDiff.Source? = nil
    var nextDiffSource: OrganizationPlanDiff.Source? = nil
    var onPreviousVersion: (() -> Void)? = nil
    var onNextVersion: (() -> Void)? = nil
    var qualityAssessment: PlanQualityAssessment? = nil
    var lowConfidenceRenameCount: Int = 0

    @State private var showNotesPopover = false
    @State private var showDropHelpPopover = false
    @State private var showQualityPopover = false
    @State private var activeDiff: OrganizationPlanDiff?

    var body: some View {
        HStack {
            if let onBack = onBack {
                GlassyBackButton(action: onBack)
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityIdentifier("PreviewBackButton")
                    .accessibilityHint("Press Escape to go back")
            }

            HStack(spacing: 6) {
                // Version navigation
                if totalVersions > 1 {
                    PreviewVersionNavigationButton(
                        systemImage: "chevron.left",
                        label: "Previous preview",
                        diffSource: previousDiffSource,
                        action: onPreviousVersion,
                        showDiff: showDiff
                    )
                    .disabled(version <= 1)
                }

                Button(action: { showDiff(currentDiffSource) }) {
                    Text(version == 1 ? "Preview" : "Preview \(version)")
                        .font(.headline)
                        .numericTextTransition(animationValue: version)
                }
                .buttonStyle(.plain)
                .disabled(currentDiffSource == nil)
                .help(currentDiffSource == nil ? "No other preview to compare" : "Compare with the adjacent preview")

                if totalVersions > 1 {
                    PreviewVersionNavigationButton(
                        systemImage: "chevron.right",
                        label: "Next preview",
                        diffSource: nextDiffSource,
                        action: onNextVersion,
                        showDiff: showDiff
                    )
                    .disabled(!isViewingHistory)
                }

                if isViewingHistory {
                    Text("(History)")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(4)
                }

                if hasEdits {
                    Button("Edited", action: { showDiff(currentDiffSource) })
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 4))
                        .buttonStyle(.plain)
                        .help("Compare edits with Preview \(version)")
                }

                if !notes.isEmpty {
                    Button {
                        showNotesPopover.toggle()
                    } label: {
                        ZStack {
                            Image(systemName: "brain")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(showNotesPopover ? Color.purple : Color.secondary)
                        }
                        .frame(width: 22, height: 22)
                        .systemLiquidGlassBackground(cornerRadius: 11)
                        .overlay(
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(showNotesPopover ? 0.5 : 0.3),
                                            Color.white.opacity(0.05)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.5
                                )
                        )
                        .shadow(color: Color.black.opacity(0.08), radius: 2, x: 0, y: 1)
                    }
                    .buttonStyle(.plain)
                    .help("View AI reasoning")
                    .accessibilityLabel("AI reasoning")
                    .accessibilityHint("Show plan reasoning popover")
                    .popover(isPresented: $showNotesPopover, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                ZStack {
                                    Circle()
                                        .fill(Color.purple.opacity(0.12))
                                        .frame(width: 28, height: 28)

                                    Image(systemName: "brain")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.purple)
                                }

                                Text("AI Reasoning")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.primary)

                                Spacer()
                            }
                            .padding(.bottom, 10)

                            Divider()
                                .opacity(0.4)
                                .padding(.bottom, 10)

                            FormattedReasoningText(
                                text: notes,
                                font: .callout,
                                secondaryFont: .caption,
                                foregroundStyle: .primary
                            )
                        }
                        .padding(14)
                        .frame(minWidth: 240, maxWidth: 340)
                        .systemLiquidGlassPopover(cornerRadius: 12)
                    }
                }
            }

            Spacer()

            // Drag hint
            Button {
                HapticFeedbackManager.shared.light()
                showDropHelpPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "hand.draw")
                        .font(.caption)
                    Text("Drop in a folder")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .systemLiquidGlassBackground(cornerRadius: 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Drop in a folder")
            .accessibilityHint("Explain how to move files between folders")
            .popover(isPresented: $showDropHelpPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.draw")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("Move files between folders")
                            .font(.caption.weight(.semibold))
                    }

                    Text("Drag any file in the preview and drop it onto another folder to move it there.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(width: 260)
                .systemLiquidGlassPopover(cornerRadius: 12)
            }

            Text("\(totalFiles) files • \(totalFolders) folders")
                .font(.caption)
                .foregroundColor(.secondary)
                .numericTextTransition(
                    animationValue: "\(totalFiles)-\(totalFolders)"
                )

            if renameCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars")
                    Text("\(renameCount) renames")
                        .numericTextTransition(animationValue: renameCount)
                }
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .systemLiquidGlassBackground(cornerRadius: 4, interactive: false)
            }

            if let qualityAssessment {
                Button {
                    HapticFeedbackManager.shared.selection()
                    showQualityPopover.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: qualityAssessment.passes ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        Text("Quality \(qualityAssessment.score)")
                            .numericTextTransition(animationValue: qualityAssessment.score)
                        if !qualityAssessment.issues.isEmpty {
                            Text("• \(qualityAssessment.issues.count)")
                        }
                    }
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(qualityColor(for: qualityAssessment.score))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .systemLiquidGlassBackground(cornerRadius: 4, interactive: false)
                }
                .buttonStyle(.plain)
                .help(qualityHelp(for: qualityAssessment))
                .accessibilityIdentifier("PlanQualityBadge")
                .accessibilityLabel("Plan quality score \(qualityAssessment.score) of 100 with \(qualityAssessment.issues.count) issues")
                .accessibilityHint("Show plan quality issues")
                .popover(isPresented: $showQualityPopover, arrowEdge: .bottom) {
                    PlanQualityPopoverContent(assessment: qualityAssessment)
                        .systemLiquidGlassPopover(cornerRadius: 12)
                }
            }

            if lowConfidenceRenameCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "eye.fill")
                    Text("\(lowConfidenceRenameCount) uncertain")
                        .numericTextTransition(animationValue: lowConfidenceRenameCount)
                }
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .systemLiquidGlassBackground(cornerRadius: 4, interactive: false)
                .help("\(lowConfidenceRenameCount) rename suggestions have medium or low AI confidence. They are flagged inline on each file — review them before applying.")
                .accessibilityLabel("\(lowConfidenceRenameCount) uncertain rename suggestions")
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview header showing \(totalFiles) files in \(totalFolders) folders")
        .popover(item: $activeDiff, arrowEdge: .bottom) { diff in
            PreviewDiffPopoverView(diff: diff)
        }
    }

    private func showDiff(_ source: OrganizationPlanDiff.Source?) {
        guard let source else { return }
        HapticFeedbackManager.shared.selection()
        activeDiff = source.makeDiff()
    }

    private func qualityColor(for score: Int) -> Color {
        if score >= PlanQualityAssessment.passingScore { return .green }
        if score >= 50 { return .orange }
        return .red
    }

    private func qualityHelp(for assessment: PlanQualityAssessment) -> String {
        if assessment.issues.isEmpty {
            return "Plan quality score \(assessment.score) of 100. No issues found."
        }
        return "Plan quality score \(assessment.score) of 100 with \(assessment.issues.count) issues. \(assessment.passes ? "Passing." : "Below passing (\(PlanQualityAssessment.passingScore)).") Review before applying."
    }
}

private struct PlanQualityPopoverContent: View {
    @SortyHotReload private var hotReload
    let assessment: PlanQualityAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: assessment.passes ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(assessment.passes ? .green : .orange)

                Text("Plan Quality — \(assessment.score)/100")
                    .font(.caption)
                    .fontWeight(.medium)

                Spacer()

                Text(assessment.passes ? "Passing" : "Needs review")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(assessment.passes ? .green : .orange)
            }

            Divider().opacity(0.4)

            if assessment.issues.isEmpty {
                Text("No quality issues found. This plan is safe to apply.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(assessment.issues) { issue in
                    HStack(alignment: .top, spacing: 6) {
                        Text("−\(issue.deduction)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.orange)
                            .monospacedDigit()
                            .frame(minWidth: 28, alignment: .trailing)
                        Text(issue.message)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 260, maxWidth: 360)
    }
}

private struct PreviewVersionNavigationButton: View {
    let systemImage: String
    let label: String
    let diffSource: OrganizationPlanDiff.Source?
    let action: (() -> Void)?
    let showDiff: (OrganizationPlanDiff.Source?) -> Void
    @State private var longPressHandled = false

    var body: some View {
        Button(action: navigate) {
            Image(systemName: systemImage)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint("Activate to navigate. Press and hold to compare previews.")
        .accessibilityAction(named: "Compare previews") { showDiff(diffSource) }
        .onLongPressGesture(minimumDuration: 0.45) {
            longPressHandled = true
            showDiff(diffSource)
        }
    }

    private func navigate() {
        if longPressHandled {
            longPressHandled = false
            return
        }
        HapticFeedbackManager.shared.selection()
        action?()
    }
}

// MARK: - Previews

#Preview("Preview Header - Standard") {
    PreviewHeaderView(
        version: 1,
        hasEdits: false,
        notes: "Organized by file type",
        totalFiles: 42,
        totalFolders: 5,
        renameCount: 0
    )
    .frame(width: 800)
}

#Preview("Preview Header - With History") {
    PreviewHeaderView(
        version: 3,
        hasEdits: true,
        notes: "Custom organization",
        totalFiles: 156,
        totalFolders: 12,
        renameCount: 8,
        totalVersions: 3,
        isViewingHistory: false
    )
    .frame(width: 800)
}
