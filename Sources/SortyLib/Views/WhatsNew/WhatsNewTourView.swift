import Foundation
import AppKit
import SwiftUI

/// The release tour shown once per build. Chapters live in `chapters`; update
/// that list and `WhatsNewIllustration` together for each release, using
/// CHANGELOG.md as the source of truth.
public struct WhatsNewTourView: View {
    @SortyHotReload private var hotReload
    private let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentPage = 0
    @State private var appIcon: NSImage?
    @State private var interactionMonitor: Any?
    @State private var tourWindow: NSWindow?
    @State private var isPointerInside = false
    @State private var swipeAccumulatedTranslation: CGFloat = 0
    @State private var hasTriggeredSwipeForGesture = false
    @State private var navigationDirection: CGFloat = 1

    private let swipeThreshold: CGFloat = 42
    private let maximumSwipeOffset: CGFloat = 14

    public init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    public var body: some View {
        HStack(spacing: 0) {
            chapterRail
            Divider()
            chapterDetail
        }
        .frame(width: 740, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            WhatsNewWindowReader { tourWindow = $0 }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .windowLinkHoverPillHost()
        .onHover { isInside in
            isPointerInside = isInside
            if !isInside {
                resetSwipeTracking()
            }
        }
        .onAppear {
            appIcon = WhatsNewImageLoader.image(named: "AppIcon-Release.png")
            installInteractionMonitorIfNeeded()
        }
        .onDisappear {
            removeInteractionMonitor()
        }
    }

    private var chapters: [WhatsNewChapter] {
        [
            WhatsNewChapter(
                railTitle: "Overview",
                symbol: "sparkles",
                title: "A huge pass of UI cleanup and bug fixes",
                summary: "Sorty 1.3.1 tidies the screens you use most and fixes problems across providers, feedback, and file handling.",
                points: [],
                illustration: .tidy
            ),
            WhatsNewChapter(
                railTitle: "Preview",
                symbol: "pencil.line",
                title: "Clearer preview and completion",
                summary: "Counts, AI Summary, and completion actions are simpler to read.",
                points: [
                    "Rename files directly in the preview, including files left unorganized.",
                    "Edit a name, regenerate a suggestion, or revert it before you apply the plan.",
                    "Notices explain how edited names inform Learnings.",
                ],
                illustration: .preview
            ),
            WhatsNewChapter(
                railTitle: "Settings and Onboarding",
                symbol: "slider.horizontal.3",
                title: "Refined Settings and onboarding",
                summary: "Settings, onboarding, segmented controls, and shared buttons have all been refined.",
                points: [
                    "Haptics are reserved for deliberate moments, like saving a rename or seeing cleanup results.",
                    "Approve pending learned patterns. Project detection now lives with Developer Mode.",
                    "Setup controls stay inside the window at the minimum onboarding size.",
                ],
                illustration: .settings
            ),
            WhatsNewChapter(
                railTitle: "Providers and Sessions",
                symbol: "wrench.and.screwdriver",
                title: "Provider, Codex, and session fixes",
                summary: "AI work recovers better when a provider or response misbehaves.",
                points: [
                    "Fixed Codex subprocess crashes and an AI session invalidation race.",
                    "Response limits now recover using smaller batches and partial JSON responses.",
                    "Fixed Gemini connection checks and OpenCode routing. OpenCode models can filter to free options.",
                ],
                illustration: .providers
            ),
            WhatsNewChapter(
                railTitle: "Labs and Feedback",
                symbol: "flask",
                title: "Expiring Files and feedback attachments",
                summary: "Review old files in Sorty Labs, and send fuller reports.",
                points: [
                    "Try Expiring Files to review old installers, archives, and screenshots before moving them to Trash.",
                    "Start a review from Clean Up in Watched Folders or the menu bar.",
                    "Attach files to feedback, add an optional email, and preview included diagnostics.",
                ],
                illustration: .labs
            ),
        ]
    }

    private var chapterRail: some View {
        VStack(alignment: .leading, spacing: SortyDesignSystem.Spacing.xxs) {
            HStack(spacing: SortyDesignSystem.Spacing.sm) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text("What's New")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                    Text(verbatim: "Sorty 1.3.1")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .padding(.horizontal, SortyDesignSystem.Spacing.xs)
            .padding(.bottom, SortyDesignSystem.Spacing.lg)

            ForEach(chapters.indices, id: \.self) { index in
                WhatsNewChapterRow(
                    title: chapters[index].railTitle,
                    symbol: chapters[index].symbol,
                    isSelected: index == currentPage
                ) {
                    navigate(to: index)
                }
                .accessibilityIdentifier("whatsNewChapter-\(index)")
            }

            Spacer(minLength: 0)

            Link("Full changelog", destination: URL(string: "https://sorty-organizer.github.io/Sorty/changelog/")!)
                .font(.caption)
                .padding(.horizontal, SortyDesignSystem.Spacing.xs)
                .padding(.bottom, SortyDesignSystem.Spacing.lg)
        }
        .padding(.horizontal, SortyDesignSystem.Spacing.md)
        .padding(.top, SortyDesignSystem.Spacing.xl)
        .frame(width: 212)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.035))
    }

    private var chapterDetail: some View {
        VStack(spacing: 0) {
            topBar

            ZStack {
                chapterContent(chapters[currentPage])
                    .id(currentPage)
                    .offset(x: reduceMotion ? 0 : resistedSwipeOffset)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: currentPage)

            footer
        }
    }

    private var topBar: some View {
        HStack {
            Text("Page \(currentPage + 1) of \(chapters.count)")
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Button(action: onFinish) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.88))
                    .frame(width: 30, height: 30)
                    .systemLiquidGlassCircularButtonLabel()
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .systemLiquidGlassCircularButton()
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close What's New")
            .accessibilityIdentifier("whatsNewClose")
        }
        .padding(.leading, 28)
        .padding(.trailing, SortyDesignSystem.Spacing.sm)
        .padding(.top, SortyDesignSystem.Spacing.xs)
    }

    private func chapterContent(_ chapter: WhatsNewChapter) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: SortyDesignSystem.Spacing.lg) {
                WhatsNewIllustration(kind: chapter.illustration)

                VStack(alignment: .leading, spacing: SortyDesignSystem.Spacing.xs) {
                    Text(chapter.title)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    Text(chapter.summary)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !chapter.points.isEmpty {
                    VStack(alignment: .leading, spacing: SortyDesignSystem.Spacing.xs) {
                        ForEach(chapter.points.indices, id: \.self) { index in
                            chapterPoint(chapter.points[index])
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, SortyDesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func chapterPoint(_ point: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SortyDesignSystem.Spacing.sm) {
            Image(systemName: "checkmark")
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                .accessibilityHidden(true)

            Text(point)
                .font(.system(.callout, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        let isLastPage = currentPage == chapters.count - 1

        return HStack {
            Button("Back", action: navigateToPreviousPage)
                .buttonStyle(.sortyBordered)
                .opacity(currentPage == 0 ? 0 : 1)
                .disabled(currentPage == 0)
                .accessibilityHidden(currentPage == 0)
                .accessibilityLabel("Previous What's New page")
                .accessibilityIdentifier("whatsNewBack")

            Spacer()

            Button {
                if isLastPage {
                    onFinish()
                } else {
                    navigateToNextPage()
                }
            } label: {
                Text(isLastPage ? "Start using Sorty" : "Continue")
            }
            .buttonStyle(.sortyProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("whatsNewContinue")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, SortyDesignSystem.Spacing.lg)
    }

    private var swipeResetAnimation: Animation? {
        reduceMotion ? nil : .sortySmooth
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

    private func navigateToPreviousPage() {
        navigate(to: currentPage - 1)
    }

    private func navigateToNextPage() {
        navigate(to: currentPage + 1)
    }

    /// Every route through the tour (rail, buttons, arrow keys, swipes) lands
    /// here so the transition direction always matches the page change.
    private func navigate(to index: Int) {
        guard chapters.indices.contains(index), index != currentPage else { return }
        navigationDirection = index > currentPage ? 1 : -1
        currentPage = index
    }

    private func installInteractionMonitorIfNeeded() {
        guard interactionMonitor == nil else { return }

        interactionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown.union(.scrollWheel)
        ) { event in
            guard let tourWindow, event.window === tourWindow else { return event }
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

private struct WhatsNewChapter {
    let railTitle: LocalizedStringKey
    let symbol: String
    let title: LocalizedStringKey
    let summary: LocalizedStringKey
    let points: [LocalizedStringKey]
    let illustration: WhatsNewIllustration.Kind
}

private struct WhatsNewChapterRow: View {
    @SortyHotReload private var hotReload
    let title: LocalizedStringKey
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    init(title: LocalizedStringKey, symbol: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.isSelected = isSelected
        self.action = action
    }

    private var rowFill: Color {
        if isSelected {
            return SortyDesignSystem.Colors.resolvedAccent.opacity(0.16)
        }
        return isHovering ? Color.primary.opacity(0.06) : .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: SortyDesignSystem.Spacing.sm) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(
                        isSelected ? SortyDesignSystem.Colors.resolvedAccent : Color.secondary
                    )
                    .frame(width: 20)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.system(.callout, design: .rounded, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, SortyDesignSystem.Spacing.sm)
            .padding(.vertical, 7)
            .background(
                rowFill,
                in: RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.md, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: isHovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Drawn release vignettes. They repeat what the chapter text already says, so
/// VoiceOver skips them. Names and counts in them are samples, not user data.
private struct WhatsNewIllustration: View {
    enum Kind {
        case tidy
        case preview
        case settings
        case providers
        case labs
    }

    @SortyHotReload private var hotReload
    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    private let panelShape = RoundedRectangle(
        cornerRadius: SortyDesignSystem.Radius.xl,
        style: .continuous
    )

    var body: some View {
        content
            .padding(SortyDesignSystem.Spacing.md)
            .frame(maxWidth: .infinity)
            .frame(height: kind == .tidy ? 260 : 176)
            .background(SortyDesignSystem.Colors.resolvedAccent.opacity(0.08), in: panelShape)
            .clipShape(panelShape)
            .overlay {
                panelShape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .tidy:
            WhatsNewTidyVignette()
        case .preview:
            previewVignette
        case .settings:
            settingsVignette
        case .providers:
            providersVignette
        case .labs:
            labsVignette
        }
    }

    private var previewVignette: some View {
        mockCard {
            VStack(spacing: SortyDesignSystem.Spacing.sm) {
                renameRow(symbol: "photo", from: "IMG_2041.heic", to: "Tram 28, Lisbon.heic", isEditing: true)
                renameRow(symbol: "doc.text", from: "Scan_0042.pdf", to: "Lease Renewal.pdf", isEditing: false)
                Divider()
                HStack(spacing: SortyDesignSystem.Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(SortyDesignSystem.Colors.success)
                    Text("12 files organized")
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                    Spacer(minLength: 0)
                    mockChip("Undo")
                }
            }
        }
    }

    private func renameRow(symbol: String, from: String, to: String, isEditing: Bool) -> some View {
        HStack(spacing: SortyDesignSystem.Spacing.xs) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(verbatim: from)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(verbatim: to)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, SortyDesignSystem.Spacing.xs)
                .padding(.vertical, 3)
                .overlay {
                    if isEditing {
                        RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.sm, style: .continuous)
                            .strokeBorder(SortyDesignSystem.Colors.resolvedAccent, lineWidth: 1.5)
                    }
                }
            Spacer(minLength: 0)
            if isEditing {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.uturn.backward")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var settingsVignette: some View {
        mockCard {
            VStack(spacing: SortyDesignSystem.Spacing.md) {
                HStack {
                    mockLabel("Provider", symbol: "cpu")
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        mockSegment("Cloud", isSelected: true)
                        mockSegment("Local", isSelected: false)
                    }
                    .padding(2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                }
                Divider()
                HStack {
                    mockLabel("Haptics", symbol: "hand.tap")
                    Spacer(minLength: 0)
                    mockChip("Rename saved")
                    mockChip("Cleanup results")
                }
                Divider()
                HStack {
                    mockLabel("Learned pattern", symbol: "brain")
                    Spacer(minLength: 0)
                    mockChip("Approve", isProminent: true)
                }
            }
        }
    }

    private var providersVignette: some View {
        VStack(spacing: SortyDesignSystem.Spacing.sm) {
            HStack(spacing: SortyDesignSystem.Spacing.sm) {
                providerTile("Codex", symbol: "terminal")
                providerTile("Gemini", symbol: "network")
            }
            HStack(spacing: SortyDesignSystem.Spacing.sm) {
                providerTile("OpenCode", symbol: "chevron.left.forwardslash.chevron.right")
                providerTile("AI sessions", symbol: "arrow.triangle.2.circlepath")
            }
        }
    }

    private func providerTile(_ title: LocalizedStringKey, symbol: String) -> some View {
        mockCard {
            HStack {
                mockLabel(title, symbol: symbol)
                Spacer(minLength: 0)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(SortyDesignSystem.Colors.success)
            }
        }
    }

    private var labsVignette: some View {
        HStack(spacing: SortyDesignSystem.Spacing.sm) {
            mockCard {
                VStack(alignment: .leading, spacing: SortyDesignSystem.Spacing.xs) {
                    mockLabel("Expiring Files", symbol: "hourglass")
                    expiringRow("Setup-2.4.dmg")
                    expiringRow("Backup-old.zip")
                    expiringRow("Screenshot.png")
                }
            }

            mockCard {
                VStack(alignment: .leading, spacing: SortyDesignSystem.Spacing.xs) {
                    mockLabel("Feedback", symbol: "paperplane")
                    attachmentRow("Screen Recording.mov", symbol: "paperclip")
                    attachmentRow("Diagnostics preview", symbol: "eye")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func expiringRow(_ name: String) -> some View {
        HStack {
            Text(verbatim: name)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "trash")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func attachmentRow(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(.caption, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func mockCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.lg, style: .continuous)

        return content()
            .padding(SortyDesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.04), in: shape)
            .systemLiquidGlassBackground(
                cornerRadius: SortyDesignSystem.Radius.lg,
                interactive: false
            )
    }

    private func mockLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(.callout, design: .rounded, weight: .semibold))
            .lineLimit(1)
    }

    private func mockChip(_ title: LocalizedStringKey, isProminent: Bool = false) -> some View {
        Text(title)
            .font(.system(.caption, design: .rounded, weight: .medium))
            .foregroundStyle(isProminent ? Color.white : Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, SortyDesignSystem.Spacing.sm)
            .padding(.vertical, 3)
            .background(
                isProminent ? SortyDesignSystem.Colors.resolvedAccent : Color.primary.opacity(0.07),
                in: Capsule()
            )
    }

    private func mockSegment(_ title: LocalizedStringKey, isSelected: Bool) -> some View {
        Text(title)
            .font(.system(.caption, design: .rounded, weight: .medium))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, SortyDesignSystem.Spacing.md)
            .padding(.vertical, 3)
            .background(isSelected ? Color.primary.opacity(0.12) : .clear, in: Capsule())
    }
}

/// Scattered file tiles settle into a grid once when the chapter appears, then
/// stay still. With Reduce Motion they start in the grid.
private struct WhatsNewTidyVignette: View {
    private struct Tile {
        let symbol: String
        let color: Color
        let scatter: CGSize
        let tilt: Double
    }

    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasSettled = false

    private let tiles: [Tile] = [
        Tile(symbol: "doc.fill", color: .blue, scatter: CGSize(width: -34, height: 30), tilt: -14),
        Tile(symbol: "photo.fill", color: .green, scatter: CGSize(width: 22, height: 44), tilt: 11),
        Tile(symbol: "film.fill", color: .purple, scatter: CGSize(width: -18, height: -8), tilt: -7),
        Tile(symbol: "music.note", color: .pink, scatter: CGSize(width: 30, height: 34), tilt: 16),
        Tile(symbol: "archivebox.fill", color: .orange, scatter: CGSize(width: 40, height: -6), tilt: -12),
        Tile(symbol: "tablecells.fill", color: .teal, scatter: CGSize(width: -44, height: -30), tilt: 13),
        Tile(symbol: "doc.text.fill", color: .indigo, scatter: CGSize(width: 18, height: -38), tilt: -16),
        Tile(symbol: "photo.fill", color: .mint, scatter: CGSize(width: -26, height: 12), tilt: 8),
        Tile(symbol: "folder.fill", color: .cyan, scatter: CGSize(width: 34, height: -34), tilt: -9),
        Tile(symbol: "doc.zipper", color: .brown, scatter: CGSize(width: 46, height: -20), tilt: 15),
    ]

    private var isTidy: Bool {
        hasSettled || reduceMotion
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(64), spacing: 12), count: 5),
            spacing: 12
        ) {
            ForEach(tiles.indices, id: \.self) { index in
                tileView(tiles[index])
                    .animation(
                        reduceMotion
                            ? nil
                            : .spring(duration: 0.6, bounce: 0.18).delay(0.25 + Double(index) * 0.03),
                        value: isTidy
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { hasSettled = true }
    }

    private func tileView(_ tile: Tile) -> some View {
        Image(systemName: tile.symbol)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(tile.color)
            .frame(width: 64, height: 64)
            .background(
                tile.color.opacity(0.14),
                in: RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.lg, style: .continuous)
            )
            .rotationEffect(.degrees(isTidy ? 0 : tile.tilt))
            .offset(isTidy ? .zero : tile.scatter)
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

/// Captures the actual sheet window so its event monitor leaves other windows alone.
private struct WhatsNewWindowReader: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void

    func makeNSView(context: Context) -> AttachedView {
        let view = AttachedView()
        view.onAttach = onAttach
        return view
    }

    func updateNSView(_ nsView: AttachedView, context: Context) {}

    final class AttachedView: NSView {
        var onAttach: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onAttach?(window) }
        }
    }
}
