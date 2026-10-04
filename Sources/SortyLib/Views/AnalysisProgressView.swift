import SwiftUI
import Beam

struct StreamingProgressBeam: View {
    @SortyHotReload private var hotReload
    let measuredProgress: MeasuredWorkProgress?
    let overallProgress: Double
    let stage: String
    let elapsedSeconds: Int
    let isEstablishingConnection: Bool
    let state: OrganizationState
    /// When true, the card expands to align with the live insights island below it.
    var matchesInsightsWidth: Bool = false

    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isWindowVisible = true

    /// Compact width used when the banner stands alone (removes empty space).
    private static let collapsedWidth: CGFloat = 440
    /// Width of the live insights island the banner expands to meet.
    private static let expandedWidth: CGFloat = 550
    private var targetWidth: CGFloat {
        matchesInsightsWidth ? Self.expandedWidth : Self.collapsedWidth
    }

    private var isAnimationActive: Bool {
        !reduceMotion && isWindowVisible && scenePhase == .active
            && controlActiveState != .inactive
    }

    private var percent: Int {
        Int((min(max(overallProgress, 0), 1) * 100).rounded())
    }

    private var milestone: Int {
        min(percent / 25, 4)
    }

    private var progressAccessibilityValue: String {
        guard showsDeterminateProgress else {
            return "In progress, stage \(displayedStage)"
        }
        guard let measuredProgress else {
            return "\(percent) percent complete, stage \(displayedStage)"
        }
        return "\(percent) percent, \(measuredProgress.completed) of \(measuredProgress.total) complete, stage \(displayedStage)"
    }

    private var showsDeterminateProgress: Bool {
        if measuredProgress != nil { return true }
        switch state {
        case .ready, .applying, .completed:
            return true
        case .idle, .scanning, .organizing, .error:
            return false
        }
    }

    private var displayedStage: String {
        let trimmed = stage.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return isEstablishingConnection ? "Establishing connection..." : "Working..."
        }
        if case .applying = state {
            return Self.applyingDisplayStage(from: trimmed)
        }
        return trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            progressCard
        }
        .frame(width: targetWidth)
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.82), value: matchesInsightsWidth)
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Organization progress")
        .accessibilityValue(progressAccessibilityValue)
        .accessibilityIdentifier("AnalysisPercentageText")
    }

    // MARK: - Progress card

    private var progressCard: some View {
        ZStack {
            HStack(alignment: .center, spacing: 10) {
                Text(displayedStage)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .numericTextTransition(
                        animationValue: displayedStage,
                        animation: .easeInOut(duration: 0.28)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showsDeterminateProgress {
                    Text("\(percent)%")
                        .monospacedDigit()
                        .numericTextTransition(
                            animationValue: percent,
                            animation: .easeInOut(duration: 0.3)
                        )
                        .milestoneEmptyStateSliver(trigger: milestone)
                        .frame(width: 54, alignment: .trailing)
                } else {
                    MinsangGlassLoader(
                        textChangeTrigger: displayedStage,
                        size: 54,
                        isActive: isAnimationActive
                    )
                        .frame(width: 54, alignment: .trailing)
                }
            }
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .background {
            beamSurface
        }
    }

    private var beamSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.clear)
                .systemLiquidGlassBackground(cornerRadius: 16, interactive: false)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
        .beam(
            .medium,
            palette: .colorful,
            theme: .dark,
            active: isAnimationActive,
            cornerRadius: 16,
            strength: 1.0
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func applyingDisplayStage(from stage: String) -> String {
        let lowercased = stage.lowercased()
        if lowercased.hasPrefix("renaming ") || lowercased.hasPrefix("organizing ") {
            return stage
        }
        if lowercased.hasPrefix("moving ") {
            let filename = String(stage.dropFirst("Moving ".count))
            return "Organizing \(filename)"
        }
        if lowercased.hasPrefix("applying changes") {
            return "Organizing files..."
        }
        return stage
    }
}

struct AIReasoningStatus: View {
    @SortyHotReload private var hotReload
    let state: OrganizationState
    let organizationStage: String
    let isStreaming: Bool
    let isEstablishingConnection: Bool
    let isRenameOnly: Bool
    let funnyMessage: String
    let funnyMessageOpacity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    /// Repeating symbol effects run only while motion is allowed and the
    /// window is active; otherwise a single non-repeating pass plays.
    private var symbolRepeatOptions: SymbolEffectOptions {
        reduceMotion || controlActiveState == .inactive ? .nonRepeating : .repeating
    }

    private var isAnalyzingStage: Bool {
        let stage = organizationStage.lowercased()
        return stage.contains("analyz") || stage.contains("analys")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            stageIcon
                .font(.system(size: 24))

            VStack(alignment: .leading, spacing: 2) {
                if isEstablishingConnection {
                    HStack(spacing: 6) {
                        Text(organizationStage)
                            .sortyTypography(.headline, weight: .medium)
                            .foregroundStyle(.primary)
                            .numericTextTransition(
                                animationValue: organizationStage,
                                animation: .easeInOut(duration: 0.28)
                            )
                            .textShimmer(isLoading: true, phaseOffset: 0.34, intensity: 1.65)

                        LoadingDotsView(dotCount: 3, dotSize: 5, color: .primary)
                    }
                    .transition(.opacity.animation(.spring(response: 0.4, dampingFraction: 0.85)))
                } else {
                    Text(organizationStage)
                        .sortyTypography(.headline, weight: .medium)
                        .foregroundStyle(.primary)
                        .numericTextTransition(
                            animationValue: organizationStage,
                            animation: .easeInOut(duration: 0.28)
                        )
                        .textShimmer(isLoading: isAnalyzingStage, phaseOffset: 0.08, intensity: 1.55)
                }

                if !isEstablishingConnection && isStreaming {
                    Text(isRenameOnly ? renameStatusMessage : funnyMessage)
                        .sortyTypography(.body)
                        .foregroundStyle(.secondary)
                        .numericTextTransition(
                            animationValue: isRenameOnly ? renameStatusMessage : funnyMessage,
                            animation: .easeInOut(duration: 0.28)
                        )
                        .textShimmer(isLoading: true, phaseOffset: 0.62, intensity: 1.65)
                        .opacity(funnyMessageOpacity)
                        .offset(y: funnyMessageOpacity > 0.5 ? 0 : 1)
                        .animation(.easeInOut(duration: 0.6), value: funnyMessageOpacity)
                        .transition(
                            .opacity.animation(.spring(response: 0.4, dampingFraction: 0.85)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current \(isRenameOnly ? "rename" : "organization") stage: \(organizationStage)")
        .accessibilityIdentifier("AnalysisStageInfo")
    }

    private var renameStatusMessage: String {
        if organizationStage.localizedCaseInsensitiveContains("model")
            || organizationStage.localizedCaseInsensitiveContains("provider") {
            return "Asking the model for better names..."
        }
        return "Preparing filename suggestions..."
    }

    @ViewBuilder
    private var stageIcon: some View {
        if case .scanning = state {
            Image(systemName: isRenameOnly ? "text.cursor" : "folder.badge.gearshape")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .symbolReplaceTransition(animationValue: isRenameOnly)
                .accessibilityLabel(isRenameOnly ? "Preparing names" : "Scanning files")
        } else if case .organizing = state {
            if isEstablishingConnection {
                Image(systemName: "network")
                    .foregroundStyle(.orange)
                    .symbolEffect(
                        .variableColor.iterative,
                        options: symbolRepeatOptions
                    )
            } else {
                Image(systemName: isRenameOnly ? "textformat" : "sparkles")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .symbolReplaceTransition(animationValue: isRenameOnly)
                    .symbolEffect(
                        .variableColor.iterative,
                        options: symbolRepeatOptions
                    )
                    .accessibilityLabel(isRenameOnly ? "Renaming files" : "Organizing files")
            }
        } else if case .applying = state {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.green)
                .accessibilityLabel("Applying changes")
        }
    }
}
