import Foundation
import AppKit
import SwiftUI
import Beam

public struct WhatsNewTourView: View {
    @SortyHotReload private var hotReload
    private let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var currentPage = 0
    @State private var isActionHovering = false
    @State private var interactionMonitor: Any?
    @State private var isPointerInside = false
    @State private var swipeAccumulatedTranslation: CGFloat = 0
    @State private var hasTriggeredSwipeForGesture = false
    /// True while the sample rename field has focus. Return and the arrow keys
    /// then belong to the field, not to page navigation.
    @State private var isEditingSampleName = false

    private let pageCount = 2
    private let swipeThreshold: CGFloat = 42
    private let maximumSwipeProgress: CGFloat = 0.14

    public init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    public var body: some View {
        tourFrame
        .overlay(alignment: .bottom) {
            actionButton
                .frame(height: 44)
                .padding(.bottom, 8)
        }
        .animation(pageTransitionAnimation, value: currentPage)
        .contentShape(Rectangle())
        .windowLinkHoverPillHost()
        .onHover { isInside in
            isPointerInside = isInside
            if !isInside {
                resetSwipeTracking()
            }
        }
        .onAppear {
            installInteractionMonitorIfNeeded()
        }
        .onDisappear {
            removeInteractionMonitor()
        }
    }

    private var pageTransitionAnimation: Animation {
        reduceMotion ? .sortyFade : .sortySpringStandard
    }

    private var swipeResetAnimation: Animation? {
        reduceMotion ? nil : .sortySmooth
    }

    /// Fraction of a page the current swipe has pulled, with more resistance
    /// when there is no page in that direction.
    private var swipeProgress: CGFloat {
        guard !reduceMotion else { return 0 }

        let limit = maximumSwipeProgress
        let progress = min(max(-swipeAccumulatedTranslation / 300, -limit), limit)
        let hasPageAhead = progress > 0 ? currentPage < pageCount - 1 : currentPage > 0
        return hasPageAhead ? progress : progress * 0.35
    }

    /// Fractional page position. Pages and the indicator both follow it.
    private var pagePosition: CGFloat {
        CGFloat(currentPage) + swipeProgress
    }

    private var isReleaseSummary: Bool {
        currentPage == pageCount - 1
    }

    /// Chrome stays in place while only the page content moves between pages.
    private var tourFrame: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    pageContent(index: 0) { releaseHighlights }
                    pageContent(index: 1) { releaseSummary }
                }
                .frame(height: 496, alignment: .top)

                VStack(spacing: 0) {
                    pageIndicator
                        .padding(.bottom, 8)

                    Spacer(minLength: 0)

                    Color.clear
                        .frame(height: 44)
                        .accessibilityHidden(true)
                }
                .frame(height: 72)
                .padding(.bottom, 8)
            }
            .frame(width: 640, height: 576, alignment: .top)

            topControls
                .padding(.horizontal, 12)
                .padding(.top, 12)
        }
        .frame(width: 640, height: 576, alignment: .top)
        .background {
            LinearGradient(
                stops: [
                    .init(
                        color: SortyDesignSystem.Colors.resolvedAccent.opacity(0.14),
                        location: 0
                    ),
                    .init(color: Color.purple.opacity(0.06), location: 0.34),
                    .init(color: Color(nsColor: .windowBackgroundColor), location: 0.82),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.xl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.xl, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    /// Both pages stay mounted so motion can run in either direction and the
    /// samples keep their state. Only the current page takes input.
    private func pageContent<Content: View>(
        index: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isCurrent = index == currentPage

        return content()
            .modifier(
                WhatsNewPageMotion(
                    distance: CGFloat(index) - pagePosition,
                    travel: reduceMotion ? 0 : 72,
                    shrink: reduceMotion ? 0 : 0.035
                )
            )
            .disabled(!isCurrent)
            .allowsHitTesting(isCurrent)
            .accessibilityHidden(!isCurrent)
    }

    /// Shared page heading. Trailing space keeps text clear of the close button.
    private func pageHeader(title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)

            Text(subtitle)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.trailing, 56)
    }

    private var releaseSummary: some View {
        VStack(alignment: .leading, spacing: 20) {
            pageHeader(
                title: "Everything New, Improved, and Fixed",
                subtitle: "Sorty 1.3.1 cleans up previews, Settings, onboarding, and completion screens, with fixes across providers, feedback, and file handling."
            )
            .padding(.leading, 44)

            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 12) {
                    releaseSection(
                        title: "New",
                        symbol: "sparkles",
                        color: SortyDesignSystem.Colors.resolvedAccent,
                        items: [
                            "Edit, regenerate, and revert names in preview",
                            "Expiring Files review in Sorty Labs",
                            "Feedback attachments and optional email"
                        ]
                    )
                    releaseSection(
                        title: "Improved",
                        symbol: "arrow.up.right.circle.fill",
                        color: SortyDesignSystem.Colors.success,
                        items: [
                            "Clearer preview and completion screens",
                            "Restrained haptics for actions and outcomes",
                            "Approve pending learned patterns",
                            "Free model filter for OpenCode"
                        ]
                    )
                    releaseSection(
                        title: "Fixed",
                        symbol: "wrench.and.screwdriver.fill",
                        color: SortyDesignSystem.Colors.warning,
                        items: [
                            "Codex crashes and AI session lifetime",
                            "AI response-limit recovery",
                            "Feedback attachment delivery",
                            "Finder icon updates and window controls",
                            "Onboarding minimum window size"
                        ]
                    )
                }
            }
            .scrollIndicators(.automatic)
        }
        .padding(24)
        .frame(width: 640, height: 496, alignment: .topLeading)
    }

    private func releaseSection(
        title: String,
        symbol: String,
        color: Color,
        items: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(.caption, design: .default, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)

                Text(LocalizedStringKey(title))
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(.caption2, design: .default, weight: .bold))
                            .foregroundStyle(color.opacity(0.86))
                            .frame(width: 12, height: 16)
                            .accessibilityHidden(true)

                        Text(item)
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(SortyDesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 348, alignment: .topLeading)
        .whatsNewCard(tint: color)
    }

    /// Each 1.3.1 highlight shows a working sample of the feature it describes.
    private var releaseHighlights: some View {
        VStack(alignment: .leading, spacing: 20) {
            pageHeader(
                title: "What's New in Sorty 1.3.1",
                subtitle: "Three new features give you more control over your files."
            )
                .padding(.leading, 4)

            WhatsNewHighlightsView(isEditingSampleName: $isEditingSampleName)
        }
        .padding(24)
        .frame(width: 640, height: 496, alignment: .topLeading)
    }

    private var topControls: some View {
        HStack {
            Button(action: navigateToPreviousPage) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.88))
                    .frame(width: 30, height: 30)
                    .systemLiquidGlassCircularButtonLabel()
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .systemLiquidGlassCircularButton()
            .opacity(currentPage == 0 ? 0 : 1)
            .disabled(currentPage == 0)
            .accessibilityLabel("Previous What's New page")

            Spacer()

            Button(action: onFinish) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.88))
                    .frame(width: 30, height: 30)
                    .systemLiquidGlassCircularButtonLabel()
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .systemLiquidGlassCircularButton()
            .accessibilityLabel("Close What's New")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private var pageIndicator: some View {
        GooeyPageIndicator(
            selectedIndex: pagePosition,
            pageCount: pageCount,
            accent: SortyDesignSystem.Colors.resolvedAccent
        )
        .animation(
            reduceMotion ? nil : .sortySpringStandard,
            value: currentPage
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(currentPage + 1) of \(pageCount)")
    }

    private var actionButton: some View {
        Button {
            if isReleaseSummary {
                onFinish()
            } else {
                navigateToNextPage()
            }
        } label: {
            Text(isReleaseSummary ? "Start using Sorty" : "See all changes")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .frame(width: 156, height: 24)
                .numericTextTransition(animationValue: currentPage)
        }
        .buttonStyle(.sortyProminent)
        .beam(
            .small,
            palette: .colorful,
            theme: .dark,
            active: !reduceMotion,
            shape: .capsule,
            strength: 1
        )
        .overlay {
            Capsule()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.24), location: 0),
                            .init(color: .white.opacity(0.09), location: 0.38),
                            .init(color: .clear, location: 0.78),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(reduceTransparency ? 0 : (isActionHovering ? 1 : 0.58))
                .blendMode(.screen)
                .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: isActionHovering)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .contentShape(Capsule())
        .offset(y: reduceMotion ? 0 : (isActionHovering ? -1 : 0))
        .animation(reduceMotion ? nil : .smooth(duration: 0.30), value: isActionHovering)
        .onHover { hovering in
            if hovering && !isActionHovering {
                HapticFeedbackManager.shared.selection()
            }
            isActionHovering = hovering
        }
        .keyboardShortcut(isEditingSampleName ? nil : .defaultAction)
    }

    private func navigateToPreviousPage() {
        guard currentPage > 0 else { return }
        HapticFeedbackManager.shared.selection()
        isEditingSampleName = false
        currentPage -= 1
    }

    private func navigateToNextPage() {
        guard currentPage < pageCount - 1 else { return }
        HapticFeedbackManager.shared.selection()
        isEditingSampleName = false
        currentPage += 1
    }

    private func installInteractionMonitorIfNeeded() {
        guard interactionMonitor == nil else { return }

        interactionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown.union(.scrollWheel)
        ) { event in
            switch event.type {
            case .keyDown:
                return handleKeyDownEvent(event)
            case .scrollWheel:
                return handleSwipeEvent(event)
            default:
                return event
            }
        }
    }

    private func removeInteractionMonitor() {
        if let monitor = interactionMonitor {
            NSEvent.removeMonitor(monitor)
            interactionMonitor = nil
        }
        isPointerInside = false
        resetSwipeTracking()
    }

    private func handleKeyDownEvent(_ event: NSEvent) -> NSEvent? {
        guard !isEditingSampleName else { return event }

        let navigationModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.modifierFlags.intersection(navigationModifiers).isEmpty else { return event }

        switch event.specialKey {
        case .leftArrow:
            navigateToPreviousPage()
            return nil
        case .rightArrow:
            navigateToNextPage()
            return nil
        default:
            return event
        }
    }

    private func handleSwipeEvent(_ event: NSEvent) -> NSEvent? {
        guard isPointerInside else { return event }

        let deltaX =
            event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 8
        let deltaY =
            event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8

        guard abs(deltaX) > abs(deltaY) else { return event }

        if event.phase == .began {
            resetSwipeTracking()
        }

        if event.momentumPhase != [] {
            if event.momentumPhase == .ended {
                resetSwipeTracking()
            }
            return nil
        }

        guard !hasTriggeredSwipeForGesture else {
            if event.phase == .ended || event.phase == .cancelled {
                resetSwipeTracking()
            }
            return nil
        }

        let physicalDeltaX = event.isDirectionInvertedFromDevice ? deltaX : -deltaX
        swipeAccumulatedTranslation += physicalDeltaX

        if swipeAccumulatedTranslation <= -swipeThreshold {
            hasTriggeredSwipeForGesture = true
            swipeAccumulatedTranslation = 0
            navigateToNextPage()
            return nil
        }

        if swipeAccumulatedTranslation >= swipeThreshold {
            hasTriggeredSwipeForGesture = true
            swipeAccumulatedTranslation = 0
            navigateToPreviousPage()
            return nil
        }

        if event.phase == .ended || event.phase == .cancelled {
            resetSwipeTracking()
        }

        return nil
    }

    private func resetSwipeTracking() {
        withAnimation(swipeResetAnimation) {
            swipeAccumulatedTranslation = 0
        }
        hasTriggeredSwipeForGesture = false
    }
}

/// Places a page by its signed distance from the visible position, where 0 is
/// on screen and 1 is a full page away. The outgoing page clears before the
/// incoming one resolves, so the two never read as a double exposure.
private struct WhatsNewPageMotion: ViewModifier, @MainActor Animatable {
    var distance: CGFloat
    let travel: CGFloat
    let shrink: CGFloat

    var animatableData: CGFloat {
        get { distance }
        set { distance = newValue }
    }

    func body(content: Content) -> some View {
        let magnitude = min(abs(distance), 1)
        let fade = min(max((magnitude - 0.08) / 0.54, 0), 1)
        let easedFade = fade * fade * (3 - 2 * fade)

        content
            .opacity(1 - easedFade)
            .scaleEffect(1 - magnitude * shrink)
            .offset(x: distance * travel)
    }
}

private struct GooeyPageIndicator: View, @MainActor Animatable {
    @SortyHotReload private var hotReload
    var selectedIndex: CGFloat
    let pageCount: Int
    let accent: Color

    private let dotDiameter: CGFloat = 7
    private let restingPillWidth: CGFloat = 22
    private let pageSpacing: CGFloat = 24

    var animatableData: CGFloat {
        get { selectedIndex }
        set { selectedIndex = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let centerX = size.width / 2
            let firstCenterX = centerX - CGFloat(pageCount - 1) * pageSpacing / 2

            for index in 0..<pageCount {
                let center = CGPoint(
                    x: firstCenterX + CGFloat(index) * pageSpacing,
                    y: size.height / 2
                )
                let dotRect = CGRect(
                    x: center.x - dotDiameter / 2,
                    y: center.y - dotDiameter / 2,
                    width: dotDiameter,
                    height: dotDiameter
                )
                context.fill(Path(ellipseIn: dotRect), with: .color(Color.secondary.opacity(0.45)))
            }

            let clampedIndex = min(max(selectedIndex, 0), CGFloat(pageCount - 1))
            let fractionalIndex = clampedIndex - floor(clampedIndex)
            let stretch = sin(fractionalIndex * .pi)
            let pillWidth = restingPillWidth + 12 * stretch
            let pillHeight = dotDiameter - stretch
            let pillCenterX = firstCenterX + clampedIndex * pageSpacing
            let pillRect = CGRect(
                x: pillCenterX - pillWidth / 2,
                y: (size.height - pillHeight) / 2,
                width: pillWidth,
                height: pillHeight
            )
            context.fill(
                Path(roundedRect: pillRect, cornerRadius: pillHeight / 2),
                with: .color(accent)
            )
        }
        .frame(width: 70, height: 8)
    }
}

#Preview {
    WhatsNewTourView {}
}
