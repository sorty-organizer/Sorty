import Foundation
import AppKit
import SwiftUI
import Beam

public struct WhatsNewTourView: View {
    @SortyHotReload private var hotReload
    private let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentPage = 0
    @State private var workflowImageIndex = 0
    @State private var isActionHovering = false
    @State private var interactionMonitor: Any?
    @State private var isPointerInside = false
    @State private var swipeAccumulatedTranslation: CGFloat = 0
    @State private var hasTriggeredSwipeForGesture = false
    @State private var navigationDirection: CGFloat = 1
    @State private var isWindowVisible = true

    private let swipeThreshold: CGFloat = 42
    private let maximumSwipeOffset: CGFloat = 14

    public init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    public var body: some View {
        ZStack {
            tourPage(page)
                .id(currentPage)
                .offset(x: reduceMotion ? 0 : resistedSwipeOffset)
                .transition(pageTransition)
        }
        .overlay(alignment: .bottom) {
            actionButton
                .frame(height: 44)
                .padding(.bottom, 8)
        }
        .animation(pageTransitionAnimation, value: currentPage)
        .task(
            id: ImageRotationTaskID(
                page: currentPage,
                reduceMotion: reduceMotion,
                isWindowVisible: isWindowVisible,
                controlActiveState: controlActiveState,
                scenePhase: scenePhase
            )
        ) {
            guard !reduceMotion, isWindowVisible, controlActiveState != .inactive,
                  scenePhase == .active, page.imageNames.count > 1 else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(8_000))
                guard !Task.isCancelled else { return }
                withAnimation(imageTransitionAnimation) {
                    workflowImageIndex = (workflowImageIndex + 1) % page.imageNames.count
                }
            }
        }
        .contentShape(Rectangle())
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
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

    private var imageTransitionAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.72)
    }

    private var pageTransitionAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.36)
    }

    private var swipeResetAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82)
    }

    private var resistedSwipeOffset: CGFloat {
        min(max(swipeAccumulatedTranslation * 0.20, -maximumSwipeOffset), maximumSwipeOffset)
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }

        return .asymmetric(
            insertion: .modifier(
                active: WhatsNewPageTransitionModifier(
                    opacity: 0,
                    horizontalOffset: navigationDirection * 28
                ),
                identity: WhatsNewPageTransitionModifier()
            ),
            removal: .modifier(
                active: WhatsNewPageTransitionModifier(
                    opacity: 0,
                    horizontalOffset: navigationDirection * -16
                ),
                identity: WhatsNewPageTransitionModifier()
            )
        )
    }

    private var page: WhatsNewPage {
        pages[currentPage]
    }

    private var pages: [WhatsNewPage] {
        [
            WhatsNewPage(
                imageName: "AppIcon-Release.png",
                title: "A refreshed Sorty icon",
                description: "Sorty 1.2.1 brings a new app icon, with the same tools you already know…"
            ),
            WhatsNewPage(
                title: "Less waiting, less background work",
                description: "Measured against 1.2.0 on the same Mac."
            ),
            WhatsNewPage(
                title: "Sorty 1.2.1",
                description: "A faster launch, live organization insights, clearer duplicate review, and stronger recovery across Sorty."
            ),
        ]
    }

    private var designSystemImages: [String] {
        [
            "whats-new-design-system-5.png",
            "whats-new-design-system-2.png",
            "whats-new-design-system-3.png",
            "whats-new-design-system-4.png",
            "whats-new-design-system-1.png",
        ]
    }

    private func tourPage(_ page: WhatsNewPage) -> some View {
        let isReleaseSummary = currentPage == pages.count - 1
        let isPerformancePage = currentPage == 1

        return ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // The release summary uses the copy space that the image pages
                // need. Both layouts still end at the same fixed action-button row.
                // Benchmark content fits within this region with room to spare,
                // so it never reaches the fixed navigation and copy below.
                Group {
                    if isReleaseSummary {
                        releaseSummary
                    } else if isPerformancePage {
                        performanceSummary
                    } else {
                        imageSection(page)
                    }
                }
                .frame(height: isReleaseSummary ? 496 : 416, alignment: .top)

                VStack(spacing: 0) {
                    pageIndicator
                        .padding(.bottom, isReleaseSummary ? 8 : 10)

                    if !isReleaseSummary {
                        if isPerformancePage {
                            performanceCopy
                        } else {
                            // Align the copy by its bottom edge. A wrapped description
                            // grows upward and keeps the same gap above the button.
                            VStack(spacing: 4) {
                                Text(page.title)
                                    .font(.system(size: 22, weight: .bold, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityAddTraits(.isHeader)

                                Text(page.description)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 28)
                            }
                            .frame(height: 64, alignment: .bottom)
                            .offset(y: -8)
                        }
                    }

                    Spacer(minLength: 0)

                    Color.clear
                        .frame(height: 44)
                        .accessibilityHidden(true)
                }
                .frame(height: isReleaseSummary ? 72 : 152)
                .padding(.bottom, 8)
            }
            .frame(width: 640, height: 576, alignment: .top)

            topControls
                .padding(.horizontal, 12)
                .padding(.top, 12)
        }
        .frame(width: 640, height: 576, alignment: .top)
        .background {
            if isReleaseSummary {
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
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    private var performanceSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Three hero cards plus two wide rows fit without scrolling, so
            // nothing collides with the dots and copy underneath. Full
            // benchmark tables live in the linked notes.
            VStack(spacing: 12) {
                ForEach(whatsNewSecondaryPerformanceMetrics) { metric in
                    horizontalPerformanceBar(metric)
                }
            }
            .accessibilityIdentifier("WhatsNewAdditionalPerformanceMetrics")

            HStack(alignment: .top, spacing: 12) {
                ForEach(whatsNewPerformanceMetrics) { metric in
                    heroPerformanceCard(metric)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .accessibilityIdentifier("WhatsNewPerformanceMetrics")
        }
        .padding(.horizontal, 20)
        .padding(.top, 68)
        .padding(.bottom, 10)
        .frame(width: 640, height: 416, alignment: .top)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                RadialGradient(colors: [.cyan.opacity(0.16), .clear], center: .topLeading, startRadius: 12, endRadius: 390)
                RadialGradient(colors: [.purple.opacity(0.11), .clear], center: .bottomTrailing, startRadius: 4, endRadius: 340)
            }
        }
    }

    private var benchmarkNotesURL: URL {
        URL(string: "https://github.com/sorty-organizer/Sorty/blob/main/docs/performance.md")!
    }

    private var performanceCopy: some View {
        VStack(spacing: 8) {
            Text(pages[1].title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            benchmarkNotesPill
        }
        .padding(.top, 8)
        .frame(height: 68, alignment: .top)
    }

    private var benchmarkNotesPill: some View {
        Button {
            HapticFeedbackManager.shared.tap()
            NSWorkspace.shared.open(benchmarkNotesURL)
        } label: {
            HStack(spacing: 5) {
                Text("See full benchmark notes")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
            .systemLiquidGlassBackground(cornerRadius: 999)
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("See full benchmark notes")
        .accessibilityHint("Opens the benchmark notes in your browser")
        .trackHoveredURL(benchmarkNotesURL)
        .onHover { hovering in
            if hovering {
                HapticFeedbackManager.shared.selection()
            }
        }
    }

    // One hero metric per card: big improvement value in its color,
    // a single after-bar, and a concrete before → after line.
    private func heroPerformanceCard(_ metric: WhatsNewPerformanceMetric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(metric.title)
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(metric.improvement)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(metric.color)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            WhatsNewComparisonBar(fraction: metric.afterFraction, color: metric.color, animates: true)
                .frame(height: 8)
            Text("\(metric.beforeLabel) → \(metric.afterLabel)")
                .font(.system(.caption, design: .rounded, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(metric.detail)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(metric.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(metric.color.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func horizontalPerformanceBar(_ metric: WhatsNewPerformanceMetric) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(metric.title)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Text(metric.improvement)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(metric.color)
                    .lineLimit(1)
            }
            WhatsNewComparisonBar(fraction: metric.afterFraction, color: metric.color, animates: true)
                .frame(height: 8)
            HStack(spacing: 12) {
                Text("\(metric.beforeLabel) → \(metric.afterLabel)")
                    .font(.system(.caption, design: .rounded, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(metric.detail)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(metric.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(metric.color.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var whatsNewPerformanceMetrics: [WhatsNewPerformanceMetric] {
        [
            .init(
                title: "Time to first window",
                improvement: "50% faster",
                color: .cyan,
                beforeLabel: "2,262 ms",
                afterLabel: "1,127 ms",
                afterFraction: 0.498,
                detail: "Median on the same Mac"
            ),
            .init(
                title: "Idle CPU at rest",
                improvement: "Near zero",
                color: .green,
                beforeLabel: "51.4%",
                afterLabel: "0%",
                afterFraction: 0,
                detail: "Settled, visible or minimized"
            ),
            .init(
                title: "Organization prompt tokens",
                improvement: "56–91% fewer",
                color: .purple,
                beforeLabel: "132,059",
                afterLabel: "11,961",
                afterFraction: 0.09,
                detail: "Tokens at 1,000 files"
            ),
        ]
    }

    private var whatsNewSecondaryPerformanceMetrics: [WhatsNewPerformanceMetric] {
        [
            .init(
                title: "Duplicate text-feature work",
                improvement: "86% less work",
                color: .orange,
                beforeLabel: "100% work",
                afterLabel: "14% work",
                afterFraction: 0.14,
                detail: "Identical groups in benchmark"
            ),
            .init(
                title: "Repeated batch manifest",
                improvement: "81% fewer",
                color: .blue,
                beforeLabel: "13,686 tokens",
                afterLabel: "2,627 tokens",
                afterFraction: 0.192,
                detail: "3 batches across 1,050 files"
            ),
        ]
    }

    private var releaseSummary: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sorty 1.2.1")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)

                Text("A refreshed app icon, a faster launch, live progress while organizing, clearer duplicate review, and stronger recovery.")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 44)
            .padding(.trailing, 56)

            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 12) {
                    releaseSection(
                        title: "New",
                        symbol: "sparkles",
                        color: SortyDesignSystem.Colors.resolvedAccent,
                        items: [
                            "Refreshed app icon",
                            "Live insights while Sorty organizes",
                            "Decision evidence and plan diffs in Preview",
                            "Watched-folder and Finder support checks",
                            "Unavailable files in duplicate review",
                            "Reasoning effort controls by provider and model"
                        ]
                    )
                    releaseSection(
                        title: "Improved",
                        symbol: "arrow.up.right.circle.fill",
                        color: .green,
                        items: [
                            "First window: 50% faster",
                            "Settled idle CPU: 51.4% to 0%",
                            "Large-folder prompts: 56–91% fewer tokens",
                            "Multi-batch AI context: 81% less repetition",
                            "Duplicate text-feature work: 86% lower",
                            "Progress parsing: 45% less work"
                        ]
                    )
                    releaseSection(
                        title: "Fixed",
                        symbol: "wrench.and.screwdriver.fill",
                        color: .orange,
                        items: [
                            "Overlapping organize, apply, and undo actions",
                            "Cancellation during AI and file operations",
                            "Finder actions open in the right window",
                            "Finder exclusions and permission recovery",
                            "Watched-folder recovery and failed-batch details",
                            "Provider errors and stale configuration status"
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
        .background {
            LinearGradient(
                colors: [
                    color.opacity(0.10),
                    Color.primary.opacity(0.025),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: SortyDesignSystem.Radius.xLarge,
                style: .continuous
            )
        )
        .systemLiquidGlassBackground(cornerRadius: SortyDesignSystem.Radius.xLarge, interactive: false)
        .overlay {
            RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.xLarge, style: .continuous)
                .strokeBorder(color.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func imageSection(_ page: WhatsNewPage) -> some View {
        ZStack {
            if currentPage == 0 {
                RadialGradient(
                    colors: [SortyDesignSystem.Colors.resolvedAccent.opacity(0.30), .clear],
                    center: .center,
                    startRadius: 24,
                    endRadius: 270
                )
                .accessibilityHidden(true)
            }
            if let imageName = page.activeImageName(at: imageIndex(for: page)) {
                bundledImage(imageName, fillsFrame: page.imageNames.count > 1)
                    .frame(width: 640, height: 400)
                    .clipped()
                    .id(imageName)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 1.006)),
                            removal: .opacity.combined(with: .scale(scale: 0.994))
                        )
                    )
            } else {
                finderIntegrationPreview
                    .frame(width: 640, height: 400)
            }

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.20), location: 0.45),
                    .init(color: Color(nsColor: .windowBackgroundColor), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .frame(width: 640, height: 400)
        .animation(imageTransitionAnimation, value: workflowImageIndex)
    }

    private func imageIndex(for page: WhatsNewPage) -> Int {
        page.imageNames.count > 1 ? workflowImageIndex : 0
    }

    @ViewBuilder
    private func bundledImage(_ name: String, fillsFrame: Bool) -> some View {
        if let image = WhatsNewImageLoader.image(named: name) {
            if fillsFrame {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        } else {
            missingImagePlaceholder(name)
        }
    }

    private func missingImagePlaceholder(_ name: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "photo")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(name)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var finderIntegrationPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 500, height: 276)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(Color.red.opacity(0.85)).frame(width: 10, height: 10)
                    Circle().fill(Color.yellow.opacity(0.85)).frame(width: 10, height: 10)
                    Circle().fill(Color.green.opacity(0.85)).frame(width: 10, height: 10)
                    Spacer()
                    Image(systemName: "folder")
                        .foregroundStyle(.cyan)
                }
                .padding(16)

                Divider()

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        finderSidebarRow("Downloads", icon: "arrow.down.circle", isActive: true)
                        finderSidebarRow("Desktop", icon: "desktopcomputer", isActive: false)
                        finderSidebarRow("Documents", icon: "doc.text", isActive: false)
                    }
                    .padding(14)
                    .frame(width: 160, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.primary.opacity(0.04))

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(["Invoices", "Screenshots", "Loose PDFs"], id: \.self) { folder in
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.cyan)
                                Text(folder)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.primary.opacity(0.88))
                                Spacer()
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(width: 500, height: 276)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                finderMenuItem("Organize with Sorty", icon: "sparkles", isPrimary: true)
                finderMenuItem("Watch with Sorty", icon: "eye", isPrimary: false)
                Divider()
                finderMenuItem("Repair Finder Extension", icon: "puzzlepiece.extension", isPrimary: false)
            }
            .padding(10)
            .frame(width: 220)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            .offset(x: 136, y: 58)
        }
    }

    private func finderSidebarRow(_ title: String, icon: String, isActive: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(isActive ? .cyan : .secondary)
            Text(LocalizedStringKey(title))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(isActive ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isActive ? Color.cyan.opacity(0.16) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func finderMenuItem(_ title: String, icon: String, isPrimary: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(isPrimary ? .cyan : .secondary)
            Text(LocalizedStringKey(title))
                .font(.system(size: 12, weight: isPrimary ? .semibold : .medium, design: .rounded))
                .foregroundStyle(isPrimary ? .primary : .secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(isPrimary ? Color.cyan.opacity(0.14) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        .overlay {
            if currentPage == 1 {
                Text("1.2.0  →  1.2.1")
                    .font(.system(.caption2, design: .rounded, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pageIndicator: some View {
        GooeyPageIndicator(
            selectedIndex: CGFloat(currentPage),
            pageCount: pages.count,
            accent: SortyDesignSystem.Colors.resolvedAccent
        )
        .animation(
            reduceMotion ? nil : .spring(response: 0.56, dampingFraction: 0.84),
            value: currentPage
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(currentPage + 1) of \(pages.count)")
    }

    private var actionButton: some View {
        Button {
            if currentPage == pages.count - 1 {
                onFinish()
            } else {
                navigateToNextPage()
            }
        } label: {
            Text(currentPage == pages.count - 1 ? "Start using Sorty" : "Continue")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .frame(width: 156, height: 24)
                .numericTextTransition(animationValue: currentPage)
        }
        .buttonStyle(.sortyPrimary)
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
        .keyboardShortcut(.defaultAction)
    }

    private func navigateToPreviousPage() {
        guard currentPage > 0 else { return }
        HapticFeedbackManager.shared.selection()
        navigationDirection = -1
        currentPage -= 1
    }

    private func navigateToNextPage() {
        guard currentPage < pages.count - 1 else { return }
        HapticFeedbackManager.shared.selection()
        navigationDirection = 1
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

private struct WhatsNewPageTransitionModifier: ViewModifier {
    var opacity: Double = 1
    var horizontalOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .offset(x: horizontalOffset)
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

private struct ImageRotationTaskID: Hashable {
    let page: Int
    let reduceMotion: Bool
    let isWindowVisible: Bool
    let controlActiveState: ControlActiveState
    let scenePhase: ScenePhase
}

private struct WhatsNewPage: Hashable {
    let imageNames: [String]
    let title: String
    let description: String

    init(imageName: String, title: String, description: String) {
        self.imageNames = [imageName]
        self.title = title
        self.description = description
    }

    init(title: String, description: String) {
        self.imageNames = []
        self.title = title
        self.description = description
    }

    init(imageNames: [String], title: String, description: String) {
        self.imageNames = imageNames
        self.title = title
        self.description = description
    }

    func activeImageName(at index: Int) -> String? {
        guard imageNames.indices.contains(index) else { return nil }
        return imageNames[index]
    }
}

private struct WhatsNewPerformanceMetric: Identifiable {
    let title: String
    let improvement: String
    let color: Color
    let beforeLabel: String
    let afterLabel: String
    let afterFraction: CGFloat
    let detail: String

    var id: String { title }
}

private struct WhatsNewComparisonBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    let fraction: CGFloat
    let color: Color
    let animates: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.14))
                Capsule()
                    .fill(color)
                    .frame(width: fillWidth(in: geometry.size.width))
                    .shadow(color: color.opacity(0.68), radius: 5)
            }
            .animation(animation, value: hasAppeared)
        }
        .clipShape(Capsule())
        .accessibilityHidden(true)
        .onAppear {
            hasAppeared = true
        }
    }

    private var animation: Animation? {
        guard animates, !reduceMotion else { return nil }
        return .easeOut(duration: 0.9).delay(0.18)
    }

    private func fillWidth(in availableWidth: CGFloat) -> CGFloat {
        let shouldShow = !animates || hasAppeared
        guard shouldShow else { return 0 }
        return max(3, availableWidth * min(max(fraction, 0), 1))
    }
}

private enum WhatsNewImageLoader {
    static func image(named name: String) -> NSImage? {
        let resourceName = (name as NSString).deletingPathExtension
        let resourceExtension = (name as NSString).pathExtension
        let fileExtension = resourceExtension.isEmpty ? "png" : resourceExtension
        // Never touch Bundle.module here: its generated accessor traps with
        // EXC_BREAKPOINT when the SPM bundle is absent from an Xcode-built app.
        if let url = appIconURL(resourceName: resourceName, fileExtension: fileExtension),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return SortyResources.image(named: resourceName, withExtension: fileExtension)
            ?? NSImage(named: name)
    }

    private static func appIconURL(resourceName: String, fileExtension: String) -> URL? {
        let fileName = "\(resourceName).\(fileExtension)"
        if let url = SortyResources.bundle.url(
            forResource: resourceName,
            withExtension: fileExtension,
            subdirectory: "AppIcons"
        ) {
            return url
        }
        if let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: fileExtension,
            subdirectory: "AppIcons"
        ) {
            return url
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let roots = [SortyResources.bundle.resourceURL, Bundle.main.resourceURL].compactMap { $0 }
        var candidates: [URL] = []
        for root in roots {
            candidates.append(root.appendingPathComponent("AppIcons/\(fileName)"))
            candidates.append(root.appendingPathComponent(fileName))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AppIcons/\(fileName)"))
        candidates.append(cwd.appendingPathComponent("Sources/SortyLib/Resources/AppIcons/\(fileName)"))

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }
}

#Preview {
    WhatsNewTourView {}
}
