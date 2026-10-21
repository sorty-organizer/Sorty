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
            return .green
        case .undoing:
            return .blue
        case .completed:
            return .green
        case .redoing:
            return .blue
        case .failed:
            return .red
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

    // "Was this helpful?" card with optional reason and Undo/History actions on 👎.
    @ViewBuilder
    var completionFeedbackCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Was this helpful?")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    HapticFeedbackManager.shared.success()
                    feedbackDraft.outcome = .useful
                } label: {
                    Image(systemName: feedbackDraft.outcome == .useful ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.body)
                        .foregroundStyle(feedbackDraft.outcome == .useful ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("CompleteFeedbackUsefulButton")
                .accessibilityLabel("Mark as helpful")
                .disabled(feedbackSubmitted)
                Button {
                    HapticFeedbackManager.shared.tap()
                    feedbackDraft.outcome = .notUseful
                } label: {
                    Image(systemName: feedbackDraft.outcome == .notUseful ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.body)
                        .foregroundStyle(feedbackDraft.outcome == .notUseful ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("CompleteFeedbackNotUsefulButton")
                .accessibilityLabel("Mark as not helpful")
                .disabled(feedbackSubmitted)
            }

            if feedbackSubmitted {
                Label("Thanks — feedback recorded.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("CompleteFeedbackConfirmation")
            } else if feedbackDraft.outcome != nil {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                    ForEach(LearningsManager.sessionFeedbackReasonPresets, id: \.self) { chip in
                        Button {
                            HapticFeedbackManager.shared.selection()
                            feedbackDraft.selectedChip = (feedbackDraft.selectedChip == chip) ? nil : chip
                        } label: {
                            Text(chip)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(feedbackDraft.selectedChip == chip ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1))
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("CompleteFeedbackChip-\(chip)")
                    }
                }
                TextField("Tell us what went wrong (optional)", text: $feedbackDraft.freeText)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .accessibilityIdentifier("CompleteFeedbackReasonTextField")

                if isFeedbackStoragePaused {
                    Text("Learning is paused — feedback won't be stored.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CompleteFeedbackPausedNotice")
                } else if !canStoreFeedback {
                    Text("Enable Learning to save feedback for future runs.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button {
                    submitCompletionFeedback()
                } label: {
                    Text("Send feedback")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.sortyBordered(size: .small))
                .disabled(!feedbackDraft.canSubmit)
                .accessibilityIdentifier("CompleteFeedbackSubmitButton")

                if feedbackDraft.outcome == .notUseful {
                    Divider().opacity(0.4)
                    Text("Not quite right? Undo, or fix individual files in History — undone files teach Sorty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button {
                            HapticFeedbackManager.shared.tap()
                            undoLastOrganization()
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.sortyBordered(size: .small))
                        .disabled(undoState.isBusy || !canUndo)
                        .accessibilityIdentifier("CompleteFeedbackUndoButton")
                        Button {
                            HapticFeedbackManager.shared.selection()
                            appState.openRelatedView(.history)
                        } label: {
                            Label("Fix files in History", systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.sortyBordered(size: .small))
                        .accessibilityIdentifier("CompleteFeedbackHistoryButton")
                    }
                }
            } else if isFeedbackStoragePaused {
                Text("Learning is paused — feedback won't be stored.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("CompleteFeedbackPausedNotice")
            }
        }
        .padding(14)
        .systemLiquidGlassBackground(cornerRadius: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rate this organization")
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
                                ? .spring(response: 0.2, dampingFraction: 0.68)
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
                        animationValue: effectiveTimeSaved,
                        usesCompactVerticalLayout: usesCompactVerticalLayout
                    )
                    .padding(.top, usesCompactVerticalLayout ? 2 : 8)
                    .opacity(timeSavedAppeared ? 1 : 0)
                    .offset(y: timeSavedAppeared ? 0 : 10)
                }
            }
        }
    }

    func completionSummary(usesCompactVerticalLayout: Bool) -> some View {
        VStack(spacing: usesCompactVerticalLayout ? 12 : 18) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor)

                Text(undoState == .completed ? "Undo summary" : "Run summary")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            HStack(spacing: 0) {
                IconStatItem(
                    style: .completion,
                    icon: mode == .renameOnly ? "pencil.line" : "doc.on.doc.fill",
                    value: primaryStatValue,
                    label: primaryStatLabel,
                    color: .blue
                )

                IconStatDivider(height: 54)

                IconStatItem(
                    style: .completion,
                    icon: mode == .renameOnly ? "doc.text" : "folder.fill.badge.plus",
                    value: secondaryStatValue,
                    label: secondaryStatLabel,
                    color: .purple
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
        .padding(.horizontal, 22)
        .padding(.vertical, usesCompactVerticalLayout ? 13 : 18)
        .frame(maxWidth: 560)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
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
            .buttonStyle(.sortyPrimary(size: .large))
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
