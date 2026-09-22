//
//  WorkflowContainer.swift
//  Sorty
//
//  Shared container for consistent workflow layouts
//

import SwiftUI

/// Workflow step enum for progress indicator
public enum WorkflowStep: Int, CaseIterable {
    case selectFolder = 0
    case configure = 1
    case analyze = 2
    case preview = 3
    case complete = 4
    
    var title: String {
        switch self {
        case .selectFolder: return "Select"
        case .configure: return "Configure"
        case .analyze: return "Analyze"
        case .preview: return "Preview"
        case .complete: return "Complete"
        }
    }
    
    var icon: String {
        switch self {
        case .selectFolder: return "folder"
        case .configure: return "slider.horizontal.3"
        case .analyze: return "brain.head.profile"
        case .preview: return "eye"
        case .complete: return "checkmark.circle"
        }
    }
}

/// Environment flag: when `true`, `WorkflowContainer` suppresses its own
/// gradient background. Use this when an ancestor view is rendering a single
/// persistent `WorkflowGradientBackground` to avoid double-mounting (which
/// causes the gradient to flicker as views transition).
private struct WorkflowGradientHiddenKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var workflowGradientHidden: Bool {
        get { self[WorkflowGradientHiddenKey.self] }
        set { self[WorkflowGradientHiddenKey.self] = newValue }
    }
}

/// Shared container for workflow screens with consistent layout
struct WorkflowContainer<Content: View>: View {
    @SortyHotReload private var hotReload
    let currentStep: WorkflowStep?
    let showStepIndicator: Bool
    let allowsScrolling: Bool
    @ViewBuilder var content: Content
    @Environment(\.workflowGradientHidden) private var gradientHidden

    init(
        currentStep: WorkflowStep? = nil,
        showStepIndicator: Bool = false,
        allowsScrolling: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.currentStep = currentStep
        self.showStepIndicator = showStepIndicator
        self.allowsScrolling = allowsScrolling
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            if showStepIndicator, let step = currentStep {
                WorkflowStepIndicator(currentStep: step)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
            }

            GeometryReader { geometry in
                if allowsScrolling {
                    ScrollView {
                        workflowContent(minHeight: geometry.size.height)
                    }
                } else {
                    workflowContent(minHeight: geometry.size.height)
                }
            }
        }
        .background {
            if !gradientHidden {
                WorkflowGradientBackground()
            }
        }
    }

    private func workflowContent(minHeight: CGFloat) -> some View {
        VStack(spacing: 24) {
            content
        }
        .frame(maxWidth: 580)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .frame(minHeight: minHeight)
    }
}

struct WorkflowGradientBackground: View {
    @SortyHotReload private var hotReload
    var showsBaseColor = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workflowGradientHidden) private var gradientHidden

    var body: some View {
        if !gradientHidden {
            backgroundLayer
        }
    }

    /// Light mode needs more saturation for the gradient to read against the
    /// near-white window background; dark mode looks better with a softer
    /// wash so it doesn't compete with the foreground content.
    private var topOpacity: Double {
        colorScheme == .dark ? 0.28 : 0.44
    }

    private var midOpacity: Double {
        colorScheme == .dark ? 0.11 : 0.18
    }

    /// Top-of-stack soft bloom: a radial highlight that drifts horizontally,
    /// giving the wash a sense of light catching on it rather than a flat
    /// pulse.
    private var bloomOpacity: Double {
        colorScheme == .dark ? 0.22 : 0.30
    }

    /// Static workflow wash. Keep this free of timed transforms so the background
    /// never reads as a loading sweep behind the content.
    private var backgroundLayer: some View {
        ZStack(alignment: .bottom) {
            if showsBaseColor {
                Color(NSColor.windowBackgroundColor)
            }

            GeometryReader { proxy in
                LinearGradient(
                    stops: [
                        .init(color: Color.accentColor.opacity(topOpacity), location: 0.00),
                        .init(color: Color.accentColor.opacity(midOpacity), location: 0.38),
                        .init(color: Color.accentColor.opacity(midOpacity * 0.36), location: 0.72),
                        .init(color: Color.accentColor.opacity(midOpacity * 0.08), location: 0.92),
                        .init(color: Color.clear, location: 1.00)
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(height: proxy.size.height * 0.66)
                .frame(maxHeight: .infinity, alignment: .bottom)

                RadialGradient(
                    colors: [
                        Color.accentColor.opacity(bloomOpacity),
                        Color.accentColor.opacity(bloomOpacity * 0.35),
                        .clear
                    ],
                    center: UnitPoint(x: 0.5, y: 1.05),
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.70
                )
                .blendMode(.plusLighter)
                .opacity(0.50)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

private struct EmptyStateWorkflowGradientModifier: ViewModifier {
    let isVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                ZStack(alignment: .bottom) {
                    Color(NSColor.windowBackgroundColor)

                    WorkflowGradientBackground(showsBaseColor: false)
                        .opacity(isVisible ? 1 : 0)
                        .scaleEffect(
                            x: 1,
                            y: isVisible || reduceMotion ? 1 : 0.86,
                            anchor: .bottom
                        )
                        .animation(.easeInOut(duration: reduceMotion ? 0.01 : 0.45), value: isVisible)
                }
                .ignoresSafeArea()
            }
    }
}

extension View {
    func emptyStateWorkflowGradient(isVisible: Bool) -> some View {
        modifier(EmptyStateWorkflowGradientModifier(isVisible: isVisible))
    }

    func animatedEmptyStateIcon(
        tint: Color = SortyDesignSystem.Colors.resolvedAccent
    ) -> some View {
        modifier(AnimatedEmptyStateIconModifier(tint: tint))
    }

    func milestoneEmptyStateSliver(
        trigger: Int,
        tint: Color = SortyDesignSystem.Colors.resolvedAccent
    ) -> some View {
        modifier(MilestoneEmptyStateSliverModifier(trigger: trigger, tint: tint))
    }
}

private let emptyStateSliverDuration: TimeInterval = 1.25

private struct MilestoneEmptyStateSliverModifier: ViewModifier {
    let trigger: Int
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweepProgress: CGFloat = 1
    @State private var sweepTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .modifier(
                EmptyStateIconSweep(
                    progress: reduceMotion ? 0.5 : sweepProgress,
                    reduceMotion: reduceMotion,
                    tint: tint
                )
            )
            .onAppear {
                guard trigger > 0 else { return }
                runSweep()
            }
            .onChange(of: trigger) { oldTrigger, newTrigger in
                guard newTrigger > oldTrigger else { return }
                runSweep()
            }
            .onDisappear {
                sweepTask?.cancel()
            }
    }

    private func runSweep() {
        guard !reduceMotion else { return }
        sweepTask?.cancel()
        sweepProgress = 0
        sweepTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            HapticSequenceManager.shared.playShimmerWave(
                duration: emptyStateSliverDuration
            )
            withAnimation(.easeInOut(duration: emptyStateSliverDuration)) {
                sweepProgress = 1
            }
        }
    }
}

/// Standardized empty-state hero icon used across the History, Duplicates,
/// Watched Folders, and Exclusion Rules empty states.
///
/// Renders an accent-tinted circular backdrop behind an SF Symbol. By default
/// the symbol uses the accent gradient with the shared one-shot sweep animation
/// (matching the History empty state). Pass a `tint` to render a static colored
/// icon instead (e.g. a green success state).
struct EmptyStateHeroIcon: View {
    @SortyHotReload private var hotReload
    let systemName: String
    var tint: Color?
    var iconSize: CGFloat
    var circleSize: CGFloat
    var symbolBounceTrigger: Bool

    init(
        systemName: String,
        tint: Color? = nil,
        iconSize: CGFloat = 44,
        circleSize: CGFloat = 100,
        symbolBounceTrigger: Bool = false
    ) {
        self.systemName = systemName
        self.tint = tint
        self.iconSize = iconSize
        self.circleSize = circleSize
        self.symbolBounceTrigger = symbolBounceTrigger
    }

    var body: some View {
        ZStack {
            Circle()
                .fill((tint ?? SortyDesignSystem.Colors.resolvedAccent).opacity(0.1))
                .frame(width: circleSize, height: circleSize)

            if let tint {
                Image(systemName: systemName)
                    .font(.system(size: iconSize))
                    .foregroundStyle(tint.gradient)
                    .symbolEffect(.bounce, value: symbolBounceTrigger)
            } else {
                Image(systemName: systemName)
                    .font(.system(size: iconSize))
                    .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent.gradient)
                    .animatedEmptyStateIcon()
            }
        }
        .accessibilityHidden(true)
    }
}

private struct AnimatedEmptyStateIconModifier: ViewModifier {
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweepProgress: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .modifier(
                EmptyStateIconSweep(
                    progress: reduceMotion ? 0.5 : sweepProgress,
                    reduceMotion: reduceMotion,
                    tint: tint
                )
            )
            .onAppear {
                guard !reduceMotion else { return }
                sweepProgress = 0
                HapticSequenceManager.shared.playShimmerWave(
                    duration: emptyStateSliverDuration
                )
                withAnimation(.easeInOut(duration: emptyStateSliverDuration)) {
                    sweepProgress = 1
                }
            }
    }
}

/// Drives a single, non-repeating highlight sweep across the empty-state icon.
/// `progress` animates once from 0 to 1 on appear; intermediate frames are
/// produced via `animatableData`, then it settles into a calm resting state.
private struct EmptyStateIconSweep: ViewModifier, Animatable {
    var progress: CGFloat
    let reduceMotion: Bool
    let tint: Color

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let sweep = min(max(progress, 0), 1)
        // Glow peaks mid-sweep and fades to nothing at the start and end so the
        // animation resolves into a static icon instead of flickering off.
        // Squaring the sine gives a Hann-style envelope with zero slope at both
        // ends, so the highlight eases in and out smoothly rather than snapping.
        let envelope = sin(sweep * .pi)
        let glow = reduceMotion ? 0 : envelope * envelope
        let overlayOpacity = Double(glow)

        return
            content
            .overlay {
                LinearGradient(
                    stops: [
                        .init(
                            color: tint.opacity(0.25),
                            location: 0
                        ),
                        .init(
                            color: tint,
                            location: max(0, sweep - 0.16)
                        ),
                        .init(color: .white, location: sweep),
                        .init(
                            color: tint,
                            location: min(1, sweep + 0.16)
                        ),
                        .init(
                            color: tint.opacity(0.25),
                            location: 1
                        ),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .mask { content }
                .opacity(overlayOpacity)
                .shadow(
                    color: tint.opacity(glow * 0.8),
                    radius: glow * 13
                )
            }
            .shadow(
                color: tint.opacity(glow * 0.52),
                radius: glow * 11
            )
    }
}

/// Step indicator showing progress through workflow
struct WorkflowStepIndicator: View {
    @SortyHotReload private var hotReload
    let currentStep: WorkflowStep
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(WorkflowStep.allCases.enumerated()), id: \.element) { index, step in
                if step == .complete { EmptyView() } else {
                    HStack(spacing: 8) {
                        stepCircle(for: step)
                        
                        if step != .preview {
                            stepConnector(isCompleted: step.rawValue < currentStep.rawValue)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 40)
    }
    
    @ViewBuilder
    private func stepCircle(for step: WorkflowStep) -> some View {
        let isActive = step == currentStep
        let isCompleted = step.rawValue < currentStep.rawValue
        
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(isActive ? SortyDesignSystem.Colors.resolvedAccent : (isCompleted ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.2) : Color.secondary.opacity(0.1)))
                    .frame(width: 32, height: 32)
                
                Image(systemName: isCompleted ? "checkmark" : step.icon)
                    .font(.system(size: 12, weight: isCompleted ? .semibold : .medium))
                    .foregroundStyle(
                        isCompleted
                            ? SortyDesignSystem.Colors.resolvedAccent
                            : (isActive ? .white : .secondary)
                    )
                    .symbolReplaceTransition(animationValue: isCompleted)
            }
            
            Text(LocalizedStringKey(step.title))
                .font(.caption2)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundStyle(isActive ? .primary : .secondary)
        }
    }
    
    private func stepConnector(isCompleted: Bool) -> some View {
        Rectangle()
            .fill(isCompleted ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.3) : Color.secondary.opacity(0.15))
            .frame(width: 40, height: 2)
            .padding(.bottom, 20)
    }
}

/// A styled card section for grouping related content
struct WorkflowCard<Content: View>: View {
    @SortyHotReload private var hotReload
    let title: String?
    let icon: String?
    let verticalPadding: CGFloat
    @ViewBuilder var content: Content
    
    init(
        title: String? = nil,
        icon: String? = nil,
        verticalPadding: CGFloat = 16,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.verticalPadding = verticalPadding
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = title {
                HStack(spacing: 6) {
                    if let icon = icon {
                        Image(systemName: icon)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Text(LocalizedStringKey(title))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
            }
            
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .systemLiquidGlassBackground(cornerRadius: 14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
