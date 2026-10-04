import SwiftUI

struct ReadyToOrganizeTitle: View {
    @SortyHotReload private var hotReload
    let mode: OrganizationMode
    let showsWorkflowPicker: Bool
    let onSelectMode: (OrganizationMode) -> Void
    @State private var isShowingWorkflowChoices = false

    var body: some View {
        VStack(spacing: 6) {
            if showsWorkflowPicker {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Ready to")
                        .font(.title2.weight(.semibold))

                    Button {
                        isShowingWorkflowChoices.toggle()
                    } label: {
                        Text(mode.actionVerb)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .numericTextTransition(animationValue: mode)
                            .workflowNameSliver(
                                mode: mode,
                                isActive: showsWorkflowPicker
                            )
                            .overlay(alignment: .bottom) {
                                WorkflowDottedUnderline()
                                    .offset(y: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .popover(isPresented: $isShowingWorkflowChoices, arrowEdge: .bottom) {
                        workflowChoices
                    }
                    .help("Choose Organize, Organize & Rename, or Rename")
                    .accessibilityLabel("Workflow: \(mode.actionVerb)")
                    .accessibilityHint("Choose one of three workflows")
                }
            } else {
                Text("Ready to \(mode.actionVerb)")
                    .font(.title2.weight(.semibold))
            }

            Text(LocalizedStringKey(mode.description))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var workflowChoices: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(OrganizationMode.allCases, id: \.self) { workflow in
                Button {
                    onSelectMode(workflow)
                    isShowingWorkflowChoices = false
                } label: {
                    Label {
                        Text(workflow.actionVerb)
                    } icon: {
                        Image(systemName: workflow == mode ? "checkmark" : workflow.iconName)
                            .frame(width: 16)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
        }
        .padding(6)
        .frame(minWidth: 190)
    }
}

private struct WorkflowNameSliverModifier: ViewModifier {
    let mode: OrganizationMode
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweepProgress: CGFloat = 1
    @State private var sweepTask: Task<Void, Never>?

    private let sweepDuration: TimeInterval = 1.1

    private var colors: [Color] {
        switch mode {
        case .organize:
            return [
                .clear,
                .cyan.opacity(0.72),
                .blue.opacity(0.95),
                .white.opacity(0.92),
                .cyan.opacity(0.72),
                .clear
            ]
        case .organizeAndRename:
            return [
                .clear,
                .pink.opacity(0.72),
                .purple.opacity(0.95),
                .white.opacity(0.92),
                .pink.opacity(0.72),
                .clear
            ]
        case .renameOnly:
            return [
                .clear,
                .yellow.opacity(0.78),
                .orange.opacity(0.95),
                .white.opacity(0.92),
                .yellow.opacity(0.78),
                .clear
            ]
        }
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(
                        colors: colors,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 30, height: geometry.size.height * 2.4)
                    .rotationEffect(.degrees(-20))
                    .offset(x: -30 + sweepProgress * (geometry.size.width + 60))
                    .blur(radius: 0.8)
                }
                .mask(content)
            }
            .onAppear {
                runSweep()
            }
            .onChange(of: mode) { _, _ in
                runSweep()
            }
            .onDisappear {
                sweepTask?.cancel()
            }
    }

    private func runSweep() {
        guard isActive, !reduceMotion else { return }

        sweepTask?.cancel()
        sweepProgress = 0
        sweepTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }

            withAnimation(.smooth(duration: sweepDuration)) {
                sweepProgress = 1
            }
        }
    }
}

private extension View {
    func workflowNameSliver(mode: OrganizationMode, isActive: Bool) -> some View {
        modifier(WorkflowNameSliverModifier(mode: mode, isActive: isActive))
    }
}

private struct WorkflowDottedUnderline: View {
    @SortyHotReload private var hotReload
    var body: some View {
        Canvas { context, size in
            let diameter: CGFloat = 1.5
            let spacing: CGFloat = 2.5
            var x = diameter / 2

            while x <= size.width - diameter / 2 {
                let rect = CGRect(
                    x: x - diameter / 2,
                    y: (size.height - diameter) / 2,
                    width: diameter,
                    height: diameter
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(Color.secondary.opacity(0.9))
                )
                x += diameter + spacing
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

struct ReadyToOrganizeStartButton: View {
    @SortyHotReload private var hotReload
    let mode: OrganizationMode
    let isConnecting: Bool
    let hasAppeared: Bool
    let reduceMotion: Bool
    let compression: CGFloat
    let onStart: () -> Void

    private var horizontalScale: CGFloat {
        1 + compression * 0.025
    }

    private var verticalScale: CGFloat {
        1 - compression * 0.045
    }

    private var helpText: String {
        isConnecting
            ? "Connecting to AI provider. Start is enabled when connection is ready."
            : "Start \(mode.gerund) files using your current settings"
    }

    var body: some View {
        Button(action: onStart) {
            ReadyToOrganizeStartLabel(
                actionVerb: mode.actionVerb,
                isConnecting: isConnecting
            )
        }
        // Pause the Metal idle beam until the view has appeared so the first
        // frame renders statically without mounting a TimelineView.
        .buttonStyle(.metalFxPrimary(isPaused: isConnecting || !hasAppeared, usesSubtleIdleBeam: hasAppeared))
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: [])
        .disabled(isConnecting)
        .scaleEffect(x: horizontalScale, y: verticalScale, anchor: .center)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 10)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.45).delay(0.22),
            value: hasAppeared
        )
        .help(helpText)
        .accessibilityIdentifier("StartOrganizationButton")
        .accessibilityLabel(isConnecting ? "Connecting to provider" : "Start \(mode.gerund)")
        .accessibilityHint(isConnecting ? "Please wait until connection completes" : "Press Enter to start")
        .accessibilityValue(isConnecting ? "Connecting" : "Ready")
        .accessibilityAddTraits(.isButton)
    }
}

private struct ReadyToOrganizeStartLabel: View {
    @SortyHotReload private var hotReload
    let actionVerb: String
    let isConnecting: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isConnecting {
                SortyGradientCircularLoader(size: 12, lineWidth: 2.2)
                    .frame(width: 12, height: 12)
                Text("Connecting...")
            } else {
                Image(systemName: "play.fill")
                    .font(.caption)
                    .accessibilityHidden(true)
                Text("Start \(actionVerb)")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct ReadyToOrganizeKeyboardHint: View {
    @SortyHotReload private var hotReload
    let actionVerb: String
    let isConnecting: Bool
    let hasAppeared: Bool
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("⏎")
                .font(.caption2.weight(.medium))
            Text(isConnecting ? "Waiting..." : actionVerb)
                .font(.caption2)
                .numericTextTransition(animationValue: isConnecting)
        }
        .foregroundStyle(.quaternary)
        .opacity(hasAppeared ? 1 : 0)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.45).delay(0.28),
            value: hasAppeared
        )
        .accessibilityHidden(true)
    }
}
