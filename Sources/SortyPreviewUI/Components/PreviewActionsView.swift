//
//  PreviewActionsView.swift
//  Sorty
//
//  Action buttons component with Apply, Cancel, Reset, and Regeneration controls
//

import SwiftUI

struct PreviewActionsView: View {
    @SortyHotReload private var hotReload
    let isApplying: Bool
    let hasEdits: Bool
    let hasCustomInstructions: Bool
    let isRedoingWithModel: Bool
    let shouldDisableButtons: Bool
    /// True while a file name field is open; Return then saves the name, not Apply.
    var isRenamingFile = false
    /// True while the instructions field has focus; Return then regenerates.
    var isEditingInstructions = false
    let mode: OrganizationMode
    
    let onCancel: () -> Void
    let onReset: () -> Void
    let onRegenerate: () -> Void
    let onChooseModel: () -> Void
    let onApply: () -> Void
    
    @State private var isHoveringCancel = false
    // Local pulse: driven by the count, not by a store-published Bool that
    // would invalidate the whole preview tree on every edit.
    
    var body: some View {
        HStack(spacing: 12) {
            // Left side: Cancel and Reset
            cancelAndResetSection
            
            Spacer()
            
            // Center: Regeneration controls
            regenerationSection
            
            Spacer()
            
            // Right side: Apply
            applyButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var cancelAndResetSection: some View {
        HStack(spacing: 8) {
            // Prominent Cancel Button with keyboard shortcut
            Button {
                HapticFeedbackManager.shared.tap()
                AnalyticsManager.shared.captureImportantButton(
                    "cancel_preview",
                    screen: "organize_preview",
                    feature: "organize"
                )
                onCancel()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Cancel")
                        .font(.caption.bold())
                }
            }
            .buttonStyle(.sortyBordered(size: .small))
            .keyboardShortcut(.cancelAction)
            .keyboardShortcut(".", modifiers: .command)  // Cmd+.
            .help("Cancel this \(mode.gerund) session")
            .accessibilityIdentifier("PreviewCancelButton")
            .accessibilityLabel("Cancel \(mode.gerund)")
            .accessibilityHint("Press Command+Period to cancel")
            
            if hasEdits {
                Button {
                    HapticFeedbackManager.shared.tap()
                    AnalyticsManager.shared.captureImportantButton(
                        "reset_preview_edits",
                        screen: "organize_preview",
                        feature: "organize"
                    )
                    onReset()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Reset")
                            .font(.caption.bold())
                    }
                }
                .buttonStyle(.sortyBordered(size: .small))
                .help("Discard manual preview edits and restore the original plan")
                .accessibilityIdentifier("ResetEditsButton")
                .accessibilityLabel("Reset all manual edits")
                .accessibilityHint("Restores the initial generated organization")
                .transition(TransitionStyles.scaleAndFade)
            }
        }
        .animation(.sortySnappy, value: hasEdits)
    }
    
    private var regenerationSection: some View {
        HStack(spacing: 6) {
            // Regenerate button
            Button {
                HapticFeedbackManager.shared.tap()
                AnalyticsManager.shared.captureImportantButton(
                    "regenerate_plan",
                    screen: "organize_preview",
                    feature: "organize"
                )
                onRegenerate()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Regenerate")
                        .font(.caption.bold())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if isEditingInstructions {
                        Text("↩")
                            .font(.caption2)
                            .opacity(0.75)
                    } else if hasCustomInstructions {
                        // White on the accent button so it reads as "uses your instructions".
                        Circle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 5, height: 5)
                            .help("Uses your guiding instructions")
                    }
                }
            }
            .buttonStyle(.sortyProminent(size: .small))
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(shouldDisableButtons || isRedoingWithModel)
            .help("Regenerate \(mode.gerund) plan with current instructions")
            .accessibilityIdentifier("RegenerateButton")
            .accessibilityLabel("Regenerate with current model")
            .accessibilityHint("Press Command+Shift+R to regenerate")
            
            // Choose Model button
            Button {
                HapticFeedbackManager.shared.tap()
                AnalyticsManager.shared.captureImportantButton(
                    "choose_regeneration_model",
                    screen: "organize_preview",
                    feature: "organize"
                )
                onChooseModel()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Model")
                        .font(.caption.bold())
                }
            }
            .buttonStyle(.sortyBordered(size: .small))
            .disabled(shouldDisableButtons || isRedoingWithModel)
            .help("Choose a different AI model and regenerate")
            .accessibilityIdentifier("ChooseModelButton")
            .accessibilityLabel("Choose a different model")
            .accessibilityHint("Opens model picker for regeneration")
            .modelSelectorTriggerBounds()
        }
    }
    
    private var applyButton: some View {
        Button {
            HapticFeedbackManager.shared.tap()
            AnalyticsManager.shared.captureImportantButton(
                "apply_plan",
                screen: "organize_preview",
                feature: "organize"
            )
            onApply()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                Text("Apply")
                if !isRenamingFile && !isEditingInstructions {
                    Text("↩")
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.8))
                }
            }
        }
        .buttonStyle(.sortyProminent)
        .keyboardShortcut(isRenamingFile || isEditingInstructions ? nil : .defaultAction)
        .disabled(shouldDisableButtons)
        .help(mode == .renameOnly ? "Apply suggested file names in place" : "Apply file moves and create the planned folder structure")
        .accessibilityIdentifier("ApplyOrganizationButton")
        .accessibilityLabel("Apply this \(mode.gerund) plan to your files")
        .accessibilityHint(mode == .renameOnly ? "This action renames files and can be undone from history" : "This action moves files and is not easily undone")
    }
}

// MARK: - Progress Actions View (shown during organization)

struct PreviewProgressView: View {
    @SortyHotReload private var hotReload
    let progress: Double
    let stage: String
    let estimatedTimeRemaining: TimeInterval?
    let onCancel: () -> Void
    /// Explicit AI-waiting flag.
    /// TODO(perf/rendering): source from FolderOrganizer (read-only hook) and
    /// drop the default. The organizer is intentionally not edited here.
    var isAIWaiting: Bool = false

    private var quantizedProgress: Double {
        (min(max(progress, 0), 1) * 100).rounded() / 100
    }

    private var progressPercentText: String {
        "\(Int((quantizedProgress * 100).rounded()))%"
    }

    var body: some View {
        VStack(spacing: 12) {
            PreviewProgressControls(
                progress: quantizedProgress,
                progressPercentText: progressPercentText,
                estimatedTimeText: estimatedTimeText,
                onCancel: cancel
            )

            PreviewProgressStatus(
                stage: stage,
                showsAILoadingIndicator: isAIWaiting
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Organization in progress")
        .accessibilityValue("\(progressPercentText) complete. \(stage)")
    }

    private var estimatedTimeText: String? {
        guard let estimatedTimeRemaining, estimatedTimeRemaining > 0 else { return nil }
        return formatTime(estimatedTimeRemaining)
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        if interval < 60 {
            return String(format: "%.0fs", interval)
        } else {
            let minutes = Int(interval / 60)
            let seconds = Int(interval.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(seconds)s"
        }
    }

    private func cancel() {
        HapticFeedbackManager.shared.tap()
        onCancel()
    }
}

private struct PreviewProgressControls: View {
    @SortyHotReload private var hotReload
    let progress: Double
    let progressPercentText: String
    let estimatedTimeText: String?
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ApplyProgressBar(progress: progress, height: 12)
                .frame(maxWidth: .infinity)

            // Reserved eta slot: opacity instead of conditional layout, so the
            // eta appearing or disappearing never shifts the percent and Stop.
            Text(estimatedTimeText ?? "0s")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
                .numericTextTransition(animationValue: estimatedTimeText ?? "")
                .help("Estimated time remaining")
                .opacity(estimatedTimeText == nil ? 0 : 1)
                .accessibilityHidden(estimatedTimeText == nil)

            Text(progressPercentText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .numericTextTransition(animationValue: progress)
                .help("Organization progress")

            cancelButton
        }
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Label("Stop", systemImage: "xmark.octagon.fill")
        }
        .buttonStyle(.sortyBordered(intent: .destructive, size: .small))
        .keyboardShortcut(.cancelAction)
        .keyboardShortcut(".", modifiers: .command)
        .accessibilityIdentifier("CancelOrganizationProgressButton")
        .accessibilityLabel("Stop organization")
        .accessibilityHint("Press Command+Period to stop the organization")
    }
}

private struct PreviewProgressStatus: View {
    @SortyHotReload private var hotReload
    let stage: String
    let showsAILoadingIndicator: Bool

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Text(stage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .numericTextTransition(animationValue: stage)

                if showsAILoadingIndicator {
                    LoadingDotsView(dotCount: 3, dotSize: 4, color: .secondary)
                }
            }

            Spacer()

            Text("⌘. to stop")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ApplyProgressBar: View {
    @SortyHotReload private var hotReload
    let progress: Double
    var height: CGFloat = 10

    private var clampedProgress: CGFloat {
        // Quantized to 1% with no implicit animation: the parent drives
        // progress in whole-percent steps, and each frame lands directly.
        CGFloat((min(max(progress, 0), 1) * 100).rounded() / 100)
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                if clampedProgress > 0 {
                    RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.xs, style: .continuous)
                        .fill(SortyDesignSystem.Colors.success.gradient)
                        .frame(width: max(geometry.size.width * clampedProgress - 1, 4))
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.1))
        )
    }
}

// MARK: - Compact Instructions Row

struct PreviewInstructionsRow: View {
    @SortyHotReload private var hotReload
    @Binding var instructions: String
    @FocusState var isFocused: Bool
    let onInstructionsChanged: (String) -> Void
    /// Return in the field regenerates with the typed instructions.
    var onSubmit: () -> Void = {}
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            
            TextField(
                "Guiding instructions for regeneration...",
                text: $instructions,
                axis: .horizontal
            )
            .textFieldStyle(.plain)
            .font(.callout)
            .focused($isFocused)
            .onSubmit(onSubmit)
            .onChange(of: instructions) { oldValue, newValue in
                if !newValue.isEmpty && newValue != oldValue {
                    onInstructionsChanged(newValue)
                }
            }
            .accessibilityIdentifier("CompactInstructionsTextField")
            .accessibilityLabel("Guiding instructions")
            .accessibilityHint("Enter instructions to guide Sorty regeneration")
            
            if !instructions.isEmpty {
                Button {
                    instructions = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear instructions")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
}

// MARK: - Previews

#Preview("Preview Actions - Standard") {
    PreviewActionsView(
        isApplying: false,
        hasEdits: false,
        hasCustomInstructions: false,
        isRedoingWithModel: false,
        shouldDisableButtons: false,
        mode: .organize,
        onCancel: {},
        onReset: {},
        onRegenerate: {},
        onChooseModel: {},
        onApply: {}
    )
    .frame(width: 800)
}

#Preview("Preview Actions - With Learnings") {
    PreviewActionsView(
        isApplying: false,
        hasEdits: false,
        hasCustomInstructions: true,
        isRedoingWithModel: false,
        shouldDisableButtons: false,
        mode: .organizeAndRename,
        onCancel: {},
        onReset: {},
        onRegenerate: {},
        onChooseModel: {},
        onApply: {}
    )
    .frame(width: 800)
}

#Preview("Preview Actions - Learning Paused") {
    PreviewActionsView(
        isApplying: false,
        hasEdits: true,
        hasCustomInstructions: false,
        isRedoingWithModel: false,
        shouldDisableButtons: false,
        mode: .renameOnly,
        onCancel: {},
        onReset: {},
        onRegenerate: {},
        onChooseModel: {},
        onApply: {}
    )
    .frame(width: 800)
}

#Preview("Preview Actions - With Edits Captured") {
    PreviewActionsView(
        isApplying: false,
        hasEdits: true,
        hasCustomInstructions: false,
        isRedoingWithModel: false,
        shouldDisableButtons: false,
        mode: .organize,
        onCancel: {},
        onReset: {},
        onRegenerate: {},
        onChooseModel: {},
        onApply: {}
    )
    .frame(width: 800)
}

#Preview("Preview Progress") {
    PreviewProgressView(
        progress: 0.45,
        stage: "Moving files...",
        estimatedTimeRemaining: 125,  // 2m 5s
        onCancel: {}
    )
    .frame(width: 800)
}

#Preview("Preview Instructions Row") {
    @Previewable @State var instructions = "Group by date"
    
    PreviewInstructionsRow(
        instructions: $instructions,
        onInstructionsChanged: { _ in }
    )
    .frame(width: 800)
}
