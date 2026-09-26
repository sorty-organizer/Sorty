import AppKit
import SwiftUI

struct HistoryHeader: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let totalSessions: Int
    @Binding var selectedFilter: HistoryView.HistoryFilter
    var showsControls: Bool = true
    let onClearHistory: () -> Void

    @State private var stacksRunCount = false

    // Includes the fixed-width navigator, compact Clear action, and both safety gaps.
    private nonisolated static let stackedRunCountThreshold: CGFloat = 780

    var body: some View {
        Group {
            if showsControls {
                populatedHeader
            } else {
                emptyStateTitleRow
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, showsControls ? 12 : 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History controls")
    }

    private var populatedHeader: some View {
        ViewThatFits(in: .horizontal) {
            populatedHeaderRow
            compactPopulatedHeader
        }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width < Self.stackedRunCountThreshold
        } action: { shouldStack in
            stacksRunCount = shouldStack
        }
    }

    private var populatedHeaderRow: some View {
        HStack(spacing: 12) {
            historyIdentity
                .layoutPriority(2)

            Spacer(minLength: 4)

            HistoryNavigatorControl(selection: $selectedFilter)
                .frame(width: HistoryNavigatorControl.preferredWidth)
                .layoutPriority(1)

            Spacer(minLength: 4)

            clearHistoryButton
                .fixedSize()
        }
    }

    private var compactPopulatedHeader: some View {
        HStack(spacing: 8) {
            adaptiveHistoryIdentity

            Spacer(minLength: 4)

            HistoryNavigatorControl(selection: $selectedFilter)
                .frame(width: HistoryNavigatorControl.preferredWidth)

            Spacer(minLength: 12)

            compactClearHistoryButton
                .fixedSize()
        }
    }

    private var historyIdentity: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.blue.gradient)
            Text("History")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .lineLimit(1)

            Text("\(totalSessions) runs")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .numericTextTransition(animationValue: totalSessions)
                .accessibilityLabel("\(totalSessions) runs recorded")
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("History, \(totalSessions) runs")
    }

    private var adaptiveHistoryIdentity: some View {
        let textLayout = stacksRunCount
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 1))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))

        return HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.blue.gradient)

            textLayout {
                Text("History")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .lineLimit(1)

                Text("\(totalSessions) runs")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .numericTextTransition(animationValue: totalSessions)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("History, \(totalSessions) runs")
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.2),
            value: stacksRunCount
        )
    }

    private var emptyStateTitleRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("History")
                    .font(.largeTitle.bold())

                Text("Review past runs, undo changes, and reapply plans when needed")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var clearHistoryButton: some View {
        Button {
            HapticFeedbackManager.shared.tap()
            onClearHistory()
        } label: {
            Label("Clear", systemImage: "trash")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .systemLiquidGlassBackground(cornerRadius: 999)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(totalSessions == 0)
        .accessibilityLabel("Clear all history")
        .accessibilityIdentifier("ClearHistoryButton")
    }

    private var compactClearHistoryButton: some View {
        Button {
            HapticFeedbackManager.shared.tap()
            onClearHistory()
        } label: {
            Label("Clear History", systemImage: "trash")
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 24, height: 24)
                .systemLiquidGlassBackground(cornerRadius: 999)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(totalSessions == 0)
        .help("Clear History")
        .accessibilityLabel("Clear all history")
        .accessibilityIdentifier("ClearHistoryButton")
    }
}

private struct HistoryNavigatorControl: NSViewRepresentable {
    @SortyHotReload private var hotReload
    static let preferredWidth: CGFloat = 520

    @Binding var selection: HistoryView.HistoryFilter

    private static func segmentWidth(for filter: HistoryView.HistoryFilter) -> CGFloat {
        switch filter {
        case .all: 55
        case .undoable: 82
        case .failed: 68
        case .skipped: 76
        case .cancelled: 88
        case .manual: 72
        case .watched: 79
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let filters = HistoryView.HistoryFilter.allCases
        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12,
            weight: .medium
        )
        let images = filters.map { filter in
            let symbol = NSImage(
                systemSymbolName: filter.systemImage,
                accessibilityDescription: filter.detailedLabel
            ) ?? NSImage()
            let image = symbol.withSymbolConfiguration(symbolConfiguration) ?? symbol
            image.isTemplate = true
            return image
        }

        let control = NSSegmentedControl(
            images: images,
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.filterChanged(_:))
        )
        control.font = .systemFont(ofSize: 11, weight: .medium)
        control.setAccessibilityLabel("Filter history sessions")
        control.setAccessibilityIdentifier("HistoryFilterPicker")

        if #available(macOS 26.0, *) {
            control.controlSize = .extraLarge
            control.borderShape = .capsule
        } else {
            control.controlSize = .large
        }

        // COMPAT (macOS 27 SDK): `role` becomes public API as
        // `NSSegmentedControl.Role.tabs`. Sorty builds against the macOS 26
        // SDK, so set it via KVC when the runtime supports it. Tabs role
        // gives the Xcode navigator-bar treatment: glass rail, morphing glass
        // thumb, and continuous drag tracking between tabs.
        // Adopt `control.role = .tabs` when CI moves to the macOS 27 SDK.
        if control.responds(to: NSSelectorFromString("setRole:")) {
            control.setValue(1, forKey: "role") // NSSegmentedControlRoleTabs
        }

        control.segmentDistribution = .fit

        for (index, filter) in filters.enumerated() {
            control.setWidth(Self.segmentWidth(for: filter), forSegment: index)
            control.setLabel(filter.rawValue, forSegment: index)
            control.setImageScaling(.scaleNone, forSegment: index)
            control.setToolTip(filter.detailedLabel, forSegment: index)
        }

        return control
    }

    func updateNSView(_ nsView: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let filters = HistoryView.HistoryFilter.allCases
        nsView.selectedSegment = filters.firstIndex(of: selection) ?? 0
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<HistoryView.HistoryFilter>

        init(selection: Binding<HistoryView.HistoryFilter>) {
            self.selection = selection
        }

        @objc
        func filterChanged(_ sender: NSSegmentedControl) {
            let filters = HistoryView.HistoryFilter.allCases
            guard filters.indices.contains(sender.selectedSegment) else { return }

            let newSelection = filters[sender.selectedSegment]
            guard newSelection != selection.wrappedValue else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                selection.wrappedValue = newSelection
            }
            HapticFeedbackManager.shared.selection()
        }
    }
}

// MARK: - History Summary Card (Dashboard Impact Stats)

struct HistorySummaryCard: View {
    @SortyHotReload private var hotReload
    let summary: HistoryImpactSummary

    private var filesOrganizedValue: String {
        "\(summary.filesOrganized)"
    }

    private var timeSavedValue: String {
        let seconds = summary.totalTimeSaved
        if seconds < 3600 {
            let minutes = seconds / 60.0
            return String(format: "%.1f", minutes)
        } else {
            let hours = seconds / 3600.0
            return String(format: "%.1f", hours)
        }
    }

    private var timeSavedLabel: String {
        summary.totalTimeSaved < 3600 ? "Minutes Saved" : "Hours Saved"
    }

    private var foldersCreatedValue: String {
        "\(summary.foldersCreated)"
    }

    private var totalSessionsValue: String {
        "\(summary.totalSessions)"
    }

    private var successRateValue: String {
        summary.totalSessions > 0
            ? "\(Int(summary.successRate * 100))%"
            : "—"
    }

    private var successRateLabel: String {
        summary.totalSessions > 0
            ? "\(Int(summary.successRate * 100)) percent"
            : "not available"
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 112), spacing: 10),
            count: 5
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Impact", systemImage: "chart.bar.xaxis.ascending")
                .font(.headline)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)

            LazyVGrid(columns: gridColumns, spacing: 10) {
                HistoryStatItem(
                    title: "Files Organized",
                    value: filesOrganizedValue,
                    icon: "doc.on.doc.fill",
                    color: .blue
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Files organized: \(filesOrganizedValue)")

                HistoryStatItem(
                    title: timeSavedLabel,
                    value: timeSavedValue,
                    icon: "clock.arrow.circlepath",
                    color: .orange,
                    isEmphasized: true
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(timeSavedLabel): \(timeSavedValue)")

                HistoryStatItem(
                    title: "Folders Created",
                    value: foldersCreatedValue,
                    icon: "folder.fill.badge.plus",
                    color: .green
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Folders created: \(foldersCreatedValue)")

                HistoryStatItem(
                    title: "Total Sessions",
                    value: totalSessionsValue,
                    icon: "list.bullet.rectangle.fill",
                    color: .accentColor
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Total sessions: \(totalSessionsValue)")

                HistoryStatItem(
                    title: "Success Rate",
                    value: successRateValue,
                    icon: "chart.line.uptrend.xyaxis.circle.fill",
                    color: .teal
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Success rate: \(successRateLabel)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .systemLiquidGlassBackground(cornerRadius: 18, clear: true, interactive: false)
    }
}

private struct HistoryStatItem: View {
    @SortyHotReload private var hotReload
    let title: String
    let value: String
    let icon: String
    let color: Color
    var isEmphasized = false

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: isEmphasized ? 20 : 19, weight: .semibold))
                .foregroundStyle(color.gradient)
                .frame(width: 28, height: 24)
                .accessibilityHidden(true)

            Text(value)
                .font(.system(size: isEmphasized ? 22 : 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .numericTextTransition(animationValue: value)

            Text(LocalizedStringKey(title))
                .font(.system(size: 12, weight: isEmphasized ? .semibold : .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 88)
        .background(
            Color.secondary.opacity(isEmphasized ? 0.085 : 0.06),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    Color.primary.opacity(isHovered ? 0.18 : (isEmphasized ? 0.12 : 0)),
                    lineWidth: 1
                )
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - History Session Card

struct HistorySessionCardHeader: View {
    @SortyHotReload private var hotReload
    let entry: HistorySessionRow
    let timestampText: String
    let statusColor: Color
    let showsStatus: Bool

    var body: some View {
        HStack(spacing: 12) {
            FolderThumbnailView(
                url: URL(fileURLWithPath: entry.directoryPath),
                size: CGSize(width: 32, height: 32),
                loadDelay: entry.thumbnailLoadDelay
            )
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(entry.folderName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 10) {
                    HistorySessionSummary(entry: entry)

                    Text(timestampText)
                        .lineLimit(1)

                    if let generationMetadata = entry.generationMetadata {
                        Label(generationMetadata, systemImage: "cpu")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if showsStatus {
                Text(entry.status.displayName)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.15))
                    .foregroundStyle(statusColor)
                    .clipShape(Capsule())
            }
        }
        .padding(12)
        .contentShape(Rectangle())
    }
}

private struct HistorySessionSummary: View {
    @SortyHotReload private var hotReload
    let entry: HistorySessionRow

    var body: some View {
        HStack(spacing: 4) {
            if entry.status == .duplicatesCleanup {
                metric("\(entry.duplicatesDeleted ?? 0) deleted", systemImage: "trash")
                if let recovered = entry.recoveredSpace {
                    metric(
                        ByteCountFormatter.string(fromByteCount: recovered, countStyle: .file),
                        systemImage: "externaldrive"
                    )
                }
            } else {
                metric("\(entry.filesOrganized)", systemImage: "doc")
                metric("\(entry.foldersCreated)", systemImage: "folder")
            }
        }
    }

    private func metric(_ value: String, systemImage: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(value)
                .monospacedDigit()
        }
    }
}

struct HistorySessionCard: View {
    @SortyHotReload private var hotReload
    let entry: HistorySessionRow
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    private var statusColor: Color {
        switch entry.status {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .gray
        case .skipped: return .secondary
        case .undo: return .orange
        case .partiallyUndone: return .yellow
        case .duplicatesCleanup: return .accentColor
        }
    }

    // Border/glow carries hover and selection. No scaleEffect: scaling cards
    // re-rasterizes the glass surface every hover frame.
    private var cardBorderColor: Color {
        if isSelected {
            return SortyDesignSystem.Colors.resolvedAccent.opacity(0.5)
        }
        return Color.white.opacity(isHovered ? 0.22 : 0.1)
    }

    var body: some View {
        let timestampText = entry.timestamp.formatted(date: .abbreviated, time: .shortened)

        HStack(spacing: 4) {
            Button {
                onSelect()
            } label: {
                HistorySessionCardHeader(
                    entry: entry,
                    timestampText: timestampText,
                    statusColor: statusColor,
                    showsStatus: true
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(entry.folderName), \(entry.status.displayName)\(entry.generationMetadata.map { ", model and cost \($0)" } ?? ""), \(entry.filesOrganized) files, \(entry.foldersCreated) folders, \(timestampText)"
            )
            .accessibilityHint("Open session details")
            .accessibilityIdentifier("HistorySessionCard-\(entry.id.uuidString)")

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.trailing, 12)
                .accessibilityHidden(true)
        }
        .systemLiquidGlassBackground(cornerRadius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(cardBorderColor, lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            guard hovering != isHovered else { return }
            isHovered = hovering
        }
    }
}

struct LoadMoreHistoryRow: View {
    @SortyHotReload private var hotReload
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Load More History", systemImage: "chevron.down.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Load more history entries")
        .accessibilityIdentifier("LoadMoreHistoryButton")
    }
}

// MARK: - Quick Feedback Buttons

/// Compact feedback buttons for session outcome (useful / not useful)
struct QuickFeedbackButtons: View {
    @SortyHotReload private var hotReload
    @Binding var feedbackGiven: LearningsManager.SessionOutcome?
    @Binding var showConfirmation: Bool
    let onFeedback: (LearningsManager.SessionOutcome) -> Void

    @State private var usefulHovered = false
    @State private var notUsefulHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if feedbackGiven == nil {
                Text("Helpful?")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                // Thumbs up
                Button {
                    HapticFeedbackManager.shared.success()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        feedbackGiven = .useful
                        showConfirmation = true
                    }
                    onFeedback(.useful)

                    // Auto-hide confirmation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showConfirmation = false
                        }
                    }
                } label: {
                    Image(systemName: "hand.thumbsup")
                        .font(.caption)
                        .foregroundStyle(usefulHovered ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .scaleEffect(usefulHovered ? 1.15 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: usefulHovered)
                .onHover { hovering in
                    usefulHovered = hovering
                }
                .accessibilityLabel("Mark as helpful")
                .accessibilityIdentifier("FeedbackUsefulButton")

                // Thumbs down
                Button {
                    HapticFeedbackManager.shared.tap()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        feedbackGiven = .notUseful
                        showConfirmation = true
                    }
                    onFeedback(.notUseful)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showConfirmation = false
                        }
                    }
                } label: {
                    Image(systemName: "hand.thumbsdown")
                        .font(.caption)
                        .foregroundStyle(notUsefulHovered ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .scaleEffect(notUsefulHovered ? 1.15 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: notUsefulHovered)
                .onHover { hovering in
                    notUsefulHovered = hovering
                }
                .accessibilityLabel("Mark as not helpful")
                .accessibilityIdentifier("FeedbackNotUsefulButton")
            } else {
                // Feedback confirmation
                HStack(spacing: 4) {
                    Image(systemName: feedbackGiven == .useful ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(feedbackGiven == .useful ? .green : .orange)
                        .symbolReplaceTransition(animationValue: feedbackGiven)

                    Text(feedbackGiven == .useful ? "Thanks!" : "Noted")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .numericTextTransition(animationValue: feedbackGiven)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.08))
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(feedbackGiven == nil ? "Rate this organization" : "Feedback recorded")
    }
}

// MARK: - History Search Empty State
