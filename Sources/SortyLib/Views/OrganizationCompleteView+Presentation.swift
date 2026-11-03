import SwiftUI

extension OrganizationCompleteView {
    private var statusIcon: String {
        switch undoState {
        case .idle:
            return "checkmark"
        case .undoing:
            return "arrow.uturn.backward"
        case .completed:
            return "checkmark"
        case .redoing:
            return "arrow.uturn.forward"
        case .failed:
            return "exclamationmark"
        }
    }

    private var statusColor: Color {
        switch undoState {
        case .idle:
            return SortyDesignSystem.Colors.success
        case .undoing:
            return SortyDesignSystem.Colors.info
        case .completed:
            return SortyDesignSystem.Colors.success
        case .redoing:
            return SortyDesignSystem.Colors.info
        case .failed:
            return SortyDesignSystem.Colors.error
        }
    }

    private var statusTitle: String {
        switch undoState {
        case .idle:
            return mode.completionTitle
        case .undoing:
            return "Undoing Changes"
        case .completed:
            return "Undo Complete"
        case .redoing:
            return "Redoing Changes"
        case .failed:
            switch failedAction {
            case .undo: return "Undo Failed"
            case .redo: return "Redo Failed"
            case nil: return "Action Failed"
            }
        }
    }

    private var statusMessage: String {
        switch undoState {
        case .idle:
            return mode.completionMessage
        case .undoing:
            return "Restoring files to their previous locations..."
        case .completed:
            if undoRestoredCount == 0 && undoSkippedCount == 0 {
                return "Nothing to restore for this run."
            }
            return undoSkippedCount > 0
                ? "Restored what could be safely reverted. Review history for skipped items."
                : "Restored your files to their previous locations."
        case .redoing:
            return "Reapplying the organization plan..."
        case .failed:
            return failureMessage ?? "Sorty could not complete that action. Please review history for details."
        }
    }

    // Post-apply feedback: history entry backing this run, if already stored.
    var feedbackHistoryEntryID: String? {
        organizer.history.entries.first(where: { $0.directoryPath == directoryURL.path })?.id.uuidString
    }

    private var isFeedbackStoragePaused: Bool { learningsManager.sessionLearningPaused }

    private var canStoreFeedback: Bool { learningsManager.consentManager.canCollectData }

    // "Was this helpful?" thumbs in the footer. 👍 records right away; 👎 opens
    // a short "what went wrong" form below. After sending, the row says thanks.
    @ViewBuilder
    var completionFeedbackThumbs: some View {
        if feedbackSubmitted {
            Label("Thanks for the feedback", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(SortyDesignSystem.Colors.textSecondary)
                .accessibilityIdentifier("CompleteFeedbackConfirmation")
        } else {
            HStack(spacing: 8) {
                Text("Was this helpful?")
                    .font(.subheadline)
                    .foregroundStyle(SortyDesignSystem.Colors.textSecondary)
                Button {
                    feedbackDraft = SessionFeedbackDraft(outcome: .useful)
                    submitCompletionFeedback()
                } label: {
                    Image(systemName: "hand.thumbsup")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Helpful")
                .accessibilityIdentifier("CompleteFeedbackUsefulButton")
                .accessibilityLabel("Mark as helpful")
                Button {
                    HapticFeedbackManager.shared.tap()
                    feedbackDraft.outcome = feedbackDraft.outcome == .notUseful ? nil : .notUseful
                } label: {
                    Image(systemName: feedbackDraft.outcome == .notUseful ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.body)
                        .foregroundStyle(feedbackDraft.outcome == .notUseful ? SortyDesignSystem.Colors.warning : .secondary)
                }
                .buttonStyle(.plain)
                .help("Not helpful")
                .accessibilityIdentifier("CompleteFeedbackNotUsefulButton")
                .accessibilityLabel("Mark as not helpful")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Rate this organization")
        }
    }

    // Shown after 👎: pick a reason or type one, then send.
    @ViewBuilder
    var completionFeedbackDetails: some View {
        if !feedbackSubmitted && feedbackDraft.outcome == .notUseful {
            VStack(alignment: .leading, spacing: 10) {
                Text("What went wrong?")
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 6) {
                    ForEach(LearningsManager.sessionFeedbackReasonPresets, id: \.self) { chip in
                        Button {
                            feedbackDraft.selectedChip = (feedbackDraft.selectedChip == chip) ? nil : chip
                        } label: {
                            Text(chip)
                                .lineLimit(1)
                        }
                        .buttonStyle(.sortyChip(isSelected: feedbackDraft.selectedChip == chip))
                        .accessibilityIdentifier("CompleteFeedbackChip-\(chip)")
                    }
                }

                HStack(spacing: 8) {
                    TextField("Or describe it (optional)", text: $feedbackDraft.freeText)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                        .onSubmit(submitCompletionFeedback)
                        .accessibilityIdentifier("CompleteFeedbackReasonTextField")

                    Button("Send", action: submitCompletionFeedback)
                        .buttonStyle(.sortyBordered(intent: .primary, size: .small))
                        .disabled(!feedbackDraft.canSubmit)
                        .accessibilityIdentifier("CompleteFeedbackSubmitButton")
                }

                if isFeedbackStoragePaused {
                    Text("Learning is paused, so this won't be stored.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CompleteFeedbackPausedNotice")
                } else if !canStoreFeedback {
                    Text("Turn on Learning to keep feedback for future runs.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .sortyCard(padding: 14)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func timeSavedString(_ seconds: TimeInterval) -> String {
        if seconds >= 3600 {
            let hours = seconds / 3600
            return String(format: "%.1f hours", hours)
        } else if seconds >= 60 {
            let minutes = seconds / 60
            return String(format: "%.0f minutes", minutes)
        } else {
            return String(format: "%.0f seconds", seconds)
        }
    }

    func completionHero(usesCompactVerticalLayout: Bool) -> some View {
        VStack(spacing: usesCompactVerticalLayout ? 10 : 16) {
            ZStack {
                CompletionBadgeGlow(color: statusColor)
                    .phaseAnimator([false, true, false], trigger: glowPulseID) { content, isIntensified in
                        content
                            .scaleEffect(!reduceMotion && isIntensified ? 1.12 : 1)
                            .brightness(isIntensified ? 0.08 : 0)
                            .shadow(
                                color: statusColor.opacity(isIntensified ? 0.65 : 0),
                                radius: isIntensified ? 20 : 0
                            )
                    } animation: { isIntensified in
                        reduceMotion
                            ? .linear(duration: 0.01)
                            : isIntensified
                                ? .sortyBouncy
                                : .easeOut(duration: 0.48)
                    }
                    .scaleEffect(iconAppeared ? 1 : 0.7)
                    .opacity(iconAppeared ? 1 : 0)

                if showParticles {
                    ConfettiParticlesView()
                }

                ZStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 58, height: 58)

                    Image(systemName: statusIcon)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .symbolReplaceTransition(animationValue: statusIcon)
                }
                .scaleEffect(iconAppeared ? 1 : 0.3)
                .shadow(color: statusColor.opacity(0.42), radius: 12)
            }
            .scaleEffect(usesCompactVerticalLayout ? 0.84 : 1)
            .frame(height: usesCompactVerticalLayout ? 92 : 112)
            .contentShape(Circle())
            .onTapGesture {
                glowPulseID += 1
                HapticFeedbackManager.shared.light()
            }
            .help("Click to intensify the glow")
            .accessibilityHidden(true)

            VStack(spacing: usesCompactVerticalLayout ? 5 : 8) {
                Text(statusTitle)
                    .font(.title.bold())
                    .opacity(titleAppeared ? 1 : 0)
                    .offset(y: titleAppeared ? 0 : 10)
                    .numericTextTransition(animationValue: statusTitle)

                Text(statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .opacity(titleAppeared ? 1 : 0)
                    .offset(y: titleAppeared ? 0 : 10)
                    .numericTextTransition(animationValue: statusMessage)

                let effectiveTimeSaved: TimeInterval = {
                    if let stats = stats, stats.estimatedTimeSaved > 0 {
                        return stats.estimatedTimeSaved
                    }
                    return GenerationStats.estimatedTimeSaved(forFileCount: totalFiles)
                }()

                if effectiveTimeSaved > 0 && undoState == .idle {
                    TimeSavedHighlight(
                        value: timeSavedString(effectiveTimeSaved),
                        animationValue: effectiveTimeSaved
                    )
                    .padding(.top, 2)
                    .opacity(timeSavedAppeared ? 1 : 0)
                    .offset(y: timeSavedAppeared ? 0 : 10)
                }
            }
        }
    }

    func completionSummary(usesCompactVerticalLayout: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                IconStatItem(
                    style: .completion,
                    icon: mode == .renameOnly ? "pencil.line" : "doc.on.doc.fill",
                    value: primaryStatValue,
                    label: primaryStatLabel,
                    color: SortyDesignSystem.Colors.info
                )

                IconStatDivider(height: 54)

                IconStatItem(
                    style: .completion,
                    icon: mode == .renameOnly ? "doc.text" : "folder.fill.badge.plus",
                    value: secondaryStatValue,
                    label: secondaryStatLabel,
                    color: SortyDesignSystem.Colors.resolvedAccent
                )

                if mode == .organizeAndRename,
                   undoState != .completed,
                   let combinedModeHighlight {
                    IconStatDivider(height: 54)

                    IconStatItem(
                        style: .completion,
                        icon: combinedModeHighlight.icon,
                        value: combinedModeHighlight.value,
                        label: combinedModeHighlight.label,
                        color: combinedModeHighlight.color
                    )
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, usesCompactVerticalLayout ? 12 : 16)
        .sortyCard(padding: 0)
        .frame(maxWidth: 560)
        .opacity(summaryAppeared ? 1 : 0)
        .offset(y: summaryAppeared ? 0 : 30)
    }

    func completionActions(usesCompactVerticalLayout: Bool) -> some View {
        VStack(spacing: usesCompactVerticalLayout ? 8 : 12) {
            Button {
                HapticFeedbackManager.shared.tap()
                returnToStart()
            } label: {
                Label("Organise Another", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.sortyProminent(size: .large))
            .onHover { hovering in
                if hovering {
                    HapticFeedbackManager.shared.selection()
                }
            }
            .help("Return to the folder picker to organise another folder")
            .accessibilityHint("Returns to the folder picker to organise another folder")
            .disabled(undoState.isBusy)

            HStack(spacing: 12) {
                if canRedo || undoState.isRedoing {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        redoLastOrganization()
                    } label: {
                        if undoState.isRedoing {
                            Label("Redoing...", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Redo", systemImage: "arrow.uturn.forward")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.sortyBordered(intent: .primary, size: .regular))
                    .onHover { hovering in
                        if hovering {
                            HapticFeedbackManager.shared.selection()
                        }
                    }
                    .help("Reapply the organization you just undid")
                    .accessibilityHint("Reapplies the most recent organization plan")
                    .disabled(undoState.isRedoing || lastUndoneEntry == nil)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        undoLastOrganization()
                    } label: {
                        if undoState.isUndoing {
                            Label("Undoing...", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.sortyBordered(size: .regular))
                    .onHover { hovering in
                        if hovering {
                            HapticFeedbackManager.shared.selection()
                        }
                    }
                    .help("Undo the latest organization for this folder")
                    .accessibilityHint("Restores files from the most recent successful run")
                    .disabled(undoState.isBusy || !canUndo)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                Button {
                    HapticFeedbackManager.shared.tap()
                    NSWorkspace.shared.open(directoryURL)
                } label: {
                    Label(mode == .renameOnly ? "Show Renamed Files" : "View in Finder", systemImage: "folder.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.sortyBordered(size: .regular))
                .onHover { hovering in
                    if hovering {
                        HapticFeedbackManager.shared.selection()
                    }
                }
                .help(mode == .renameOnly ? "Open the folder containing renamed files" : "Open the organized folder in Finder")
                .accessibilityHint(mode == .renameOnly ? "Shows your renamed files in Finder" : "Shows your organized files in Finder")
                .disabled(undoState.isBusy)
            }
        }
        .frame(maxWidth: 560)
        .opacity(buttonsAppeared ? 1 : 0)
        .offset(y: buttonsAppeared ? 0 : 20)
    }
}
