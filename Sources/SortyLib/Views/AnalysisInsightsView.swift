import Foundation
import AppKit
import SwiftUI
import Combine

@MainActor
final class AnalysisInsightViewState: ObservableObject {
    @Published var showDebugStream = false
    @Published var isExpanded = true
}

struct InsightHistorySection: View {
    @SortyHotReload private var hotReload
    let activity: AIAnalysisActivity
    let insights: (current: String, history: [AIInsight])
    let debugModeEnabled: Bool
    let streamPreview: String
    @Binding var liveInsightsEnabled: Bool
    @Binding var streamingModeEnabled: Bool

    @StateObject private var viewState = AnalysisInsightViewState()
    @State private var showPrivacyWarning = false
    @AppStorage("analysis.hideLiveInsightsPrivacyWarning") private var hidePrivacyWarning = false

    private var displayedStreamPreview: String {
        FeatureFlags.privacyModeEnabled
            ? PrivacyPathMasker.redactedText(streamPreview) : streamPreview
    }

    private var isActive: Bool { activity != .none }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewState.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if isActive {
                        BreatheWaveformIcon()
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }

                    Text(headerTitle)
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .numericTextTransition(
                            animationValue: headerTitle,
                            animation: .easeInOut(duration: 0.28)
                        )

                    Spacer()

                    let insightCount = insights.history.count
                    if insightCount > 0 {
                        Text("\(insightCount)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .numericTextTransition(animationValue: insightCount)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(SortyDesignSystem.Colors.resolvedAccent))
                    }

                    if FeatureFlags.privacyModeEnabled && !hidePrivacyWarning {
                        Button {
                            showPrivacyWarning.toggle()
                        } label: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Privacy warning for live AI insights")
                        .accessibilityIdentifier("LiveInsightsPrivacyWarningButton")
                        .popover(isPresented: $showPrivacyWarning, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text("Privacy Warning")
                                        .font(.headline)

                                    Spacer()

                                    Button {
                                        hidePrivacyWarning = true
                                        showPrivacyWarning = false
                                    } label: {
                                        Image(systemName: "xmark")
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                                    .accessibilityLabel("Dismiss privacy warning")
                                    .accessibilityIdentifier("DismissLiveInsightsPrivacyWarningButton")
                                }

                                Text(
                                    "Sorty masks username path segments in streamed text, but model-generated names can still appear before full parsing."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                                Button("Never show again") {
                                    hidePrivacyWarning = true
                                    showPrivacyWarning = false
                                }
                                .accessibilityIdentifier("HideLiveInsightsPrivacyWarningButton")
                            }
                            .padding(12)
                            .frame(width: 280)
                            .systemLiquidGlassPopover(cornerRadius: 12)
                        }
                    }

                    if debugModeEnabled {
                        Button {
                            withAnimation(.spring()) {
                                viewState.showDebugStream.toggle()
                            }
                        } label: {
                            Image(
                                systemName: viewState.showDebugStream ? "terminal.fill" : "terminal"
                            )
                            .font(.caption)
                            .foregroundStyle(
                                viewState.showDebugStream ? SortyDesignSystem.Colors.resolvedAccent : .secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!liveInsightsEnabled)
                        .opacity(liveInsightsEnabled ? 1 : 0.45)
                        .help(
                            liveInsightsEnabled
                                ? "Toggle Streaming Mode preview"
                                : "Enable Live Insights to preview Streaming Mode output")
                    }

                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(viewState.isExpanded ? 0 : -90))
                        .animation(
                            .spring(response: 0.3, dampingFraction: 0.8),
                            value: viewState.isExpanded)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: viewState.isExpanded ? 0 : 16)
                        .fill(
                            LinearGradient(
                                colors: [
                                    SortyDesignSystem.Colors.resolvedAccent.opacity(0.08),
                                    SortyDesignSystem.Colors.resolvedAccent.opacity(0.03),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: viewState.isExpanded ? 0 : 16))

            if viewState.isExpanded {
                LazyVStack(spacing: 14) {
                    liveInsightsPrimaryContent

                    if streamingModeEnabled && liveInsightsEnabled && viewState.showDebugStream
                        && debugModeEnabled
                    {
                        streamingPreview
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: 550)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(NSColor.separatorColor).opacity(0.8), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onChange(of: liveInsightsEnabled) { _, enabled in
            if !enabled {
                viewState.showDebugStream = false
            }
        }
        .onChange(of: streamingModeEnabled) { _, enabled in
            if !enabled {
                streamingModeEnabled = true
                viewState.showDebugStream = false
            } else if isActive && !liveInsightsEnabled {
                liveInsightsEnabled = true
            }
        }
    }

    private var headerTitle: String {
        switch activity {
        case .none: return "Analysis complete"
        case .preparingImages: return "Preparing images..."
        case .requesting: return "Sorty is reasoning..."
        case .validating: return "Finishing up..."
        }
    }

    private var loaderLabel: String {
        switch activity {
        case .preparingImages: return "Preparing images for analysis..."
        case .validating: return "Checking suggestions..."
        case .none, .requesting: return "Receiving AI response..."
        }
    }

    @ViewBuilder
    private var liveInsightsPrimaryContent: some View {
        let currentInsightItem = insights.history.last(where: { $0.text == insights.current })
        if !streamingModeEnabled {
            receivingResponseView
        } else if liveInsightsEnabled, !insights.current.isEmpty {
            currentInsightPill(
                insight: insights.current,
                detail: currentInsightItem,
                fallbackCategory: currentInsightItem?.category
            )
        } else if liveInsightsEnabled, let fallbackInsight = streamFallbackInsight {
            currentInsightPill(
                insight: fallbackInsight,
                detail: nil,
                fallbackCategory: inferredInsightCategory(for: fallbackInsight)
            )
        } else if isActive {
            receivingResponseView
        }

        if streamingModeEnabled && liveInsightsEnabled && insights.history.count > 1 {
            insightHistoryScroller(
                entries: Array(insights.history.dropLast().reversed()),
                markFirstAsLatest: false
            )
        }
    }

    private var receivingResponseView: some View {
        HStack(spacing: 12) {
            ThinkingOrbLoaderView()
                .frame(width: 36, height: 36)

            Text(loaderLabel)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .textSweep()

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(SortyDesignSystem.Colors.resolvedAccent.opacity(0.05))
                .overlay(
                    Capsule()
                        .stroke(SortyDesignSystem.Colors.resolvedAccent.opacity(0.15), lineWidth: 1)
                )
        )
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var streamFallbackInsight: String? {
        let content =
            displayedStreamPreview
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }

        if let assignment = extractJSONAssignmentSnippet(from: content) {
            return assignment
        }

        let plainLine =
            content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reversed()
            .first { line in
                let lower = line.lowercased()
                return line.count >= 12 && !line.contains("{") && !line.contains("}")
                    && !lower.hasPrefix("\"folders\"") && !lower.hasPrefix("\"files\"")
            }

        guard let plainLine else { return nil }
        return plainLine.count > 90 ? String(plainLine.prefix(90)) + "..." : plainLine
    }

    private func extractJSONAssignmentSnippet(from text: String) -> String? {
        let folderPattern = #""name"\s*:\s*"([^"\n]{2,80})""#
        let filePattern = #""([^"\n]{2,140}\.[a-zA-Z0-9]{1,12})""#

        guard
            let folderRegex = try? NSRegularExpression(
                pattern: folderPattern, options: [.caseInsensitive]),
            let fileRegex = try? NSRegularExpression(pattern: filePattern, options: [])
        else {
            return nil
        }

        let folderMatches = folderRegex.matches(
            in: text, options: [], range: NSRange(text.startIndex..., in: text))
        let fileMatches = fileRegex.matches(
            in: text, options: [], range: NSRange(text.startIndex..., in: text))

        guard let folderMatch = folderMatches.last,
            let folderRange = Range(folderMatch.range(at: 1), in: text)
        else {
            return nil
        }

        let folderName = String(text[folderRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLikelyInsightFolderName(folderName) else { return nil }

        if let fileMatch = fileMatches.last,
            let fileRange = Range(fileMatch.range(at: 1), in: text)
        {
            let fileName = URL(fileURLWithPath: String(text[fileRange])).lastPathComponent
            if isLikelyFileName(fileName) {
                return "Assigning \(fileName) to \(folderName)"
            }
        }

        return "Preparing folder \(folderName)"
    }

    private func isLikelyInsightFolderName(_ candidate: String) -> Bool {
        let normalized =
            candidate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?"))
            .lowercased()
        guard normalized.count >= 2, normalized.count <= 80 else { return false }
        guard !normalized.contains("{"), !normalized.contains("}"), !normalized.contains("/") else {
            return false
        }
        guard URL(fileURLWithPath: normalized).pathExtension.isEmpty else { return false }

        let blocked: Set<String> = [
            "a", "an", "and", "as", "at", "by", "for", "from", "gets", "in", "is", "it",
            "name", "of", "on", "or", "that", "the", "this", "to", "with", "folder",
            "folders", "file", "files", "filename", "json", "reasoning", "notes",
            "description", "content", "data", "true", "false", "null",
        ]
        return !blocked.contains(normalized)
    }

    private func isLikelyFileName(_ candidate: String) -> Bool {
        let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 3, normalized.count <= 220 else { return false }
        let ext = URL(fileURLWithPath: normalized).pathExtension
        return !ext.isEmpty
    }

    private func inferredInsightCategory(for text: String) -> AIInsight.Category {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("file:") || mentionedFileExtension(in: text) != nil {
            return .file
        }
        if trimmed.hasPrefix("folder:") || mentionsFolderContext(in: text) {
            return .folder
        }
        if trimmed.hasPrefix("pattern:") { return .pattern }
        if trimmed.hasPrefix("decision:") { return .decision }
        if trimmed.hasPrefix("constraint:") { return .constraint }
        return .general
    }

    private func currentInsightPill(
        insight: String, detail: AIInsight?, fallbackCategory: AIInsight.Category?
    ) -> some View {
        let displayInsight =
            FeatureFlags.privacyModeEnabled ? PrivacyPathMasker.redactedText(insight) : insight

        return HStack(spacing: 12) {
            insightIcon(for: detail, fallbackText: insight, fallbackCategory: fallbackCategory)
                .frame(width: 24, height: 24)

            Text(displayInsight)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .numericTextTransition(
                    animationValue: displayInsight,
                    animation: .easeInOut(duration: 0.28)
                )

            Spacer()

            if isActive {
                Circle()
                    .fill(SortyDesignSystem.Colors.resolvedAccent.opacity(0.4))
                    .frame(width: 6, height: 6)
                    .scaleEffect(isActive ? 1.3 : 1.0)
                    .animation(.default.speed(0.8), value: isActive)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(SortyDesignSystem.Colors.resolvedAccent.opacity(0.08))
                .overlay(
                    Capsule()
                        .stroke(SortyDesignSystem.Colors.resolvedAccent.opacity(0.15), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func insightIcon(
        for insight: AIInsight?, fallbackText: String, fallbackCategory: AIInsight.Category?
    ) -> some View {
        if let filePath = insight?.filePath {
            let url = URL(fileURLWithPath: filePath)
            if url.hasDirectoryPath {
                FolderThumbnailView(url: url, size: CGSize(width: 20, height: 20))
            } else {
                FileThumbnailView(url: url, size: CGSize(width: 20, height: 20))
            }
        } else if let category = insight?.category ?? fallbackCategory {
            if category == .folder {
                AppKitImageView(
                    image: AnalysisIconProvider.icon(for: .folder),
                    size: CGSize(width: 20, height: 20)
                )
                .frame(width: 20, height: 20)
            } else if category == .file {
                if let ext = mentionedFileExtension(in: fallbackText), !ext.isEmpty {
                    AppKitImageView(
                        image: AnalysisIconProvider.icon(forFileExtension: ext),
                        size: CGSize(width: 20, height: 20)
                    )
                    .frame(width: 20, height: 20)
                } else {
                    AppKitImageView(
                        image: AnalysisIconProvider.icon(for: .data),
                        size: CGSize(width: 20, height: 20)
                    )
                    .frame(width: 20, height: 20)
                }
            } else {
                categoryIndicator(for: category)
            }
        } else if let ext = mentionedFileExtension(in: fallbackText), !ext.isEmpty {
            AppKitImageView(
                image: AnalysisIconProvider.icon(forFileExtension: ext),
                size: CGSize(width: 20, height: 20)
            )
            .frame(width: 20, height: 20)
        } else if mentionsFolderContext(in: fallbackText) {
            AppKitImageView(
                image: AnalysisIconProvider.icon(for: .folder),
                size: CGSize(width: 20, height: 20)
            )
            .frame(width: 20, height: 20)
        } else {
            categoryIndicator(for: .general)
        }
    }

    @ViewBuilder
    private func categoryIndicator(for category: AIInsight.Category) -> some View {
        Circle()
            .fill(categoryColor(for: category).opacity(0.28))
            .overlay(
                Circle()
                    .stroke(categoryColor(for: category).opacity(0.55), lineWidth: 1)
            )
            .frame(width: 10, height: 10)
            .padding(6)
    }

    private func categoryColor(for category: AIInsight.Category) -> Color {
        switch category {
        case .file: return .blue
        case .folder: return .orange
        case .constraint: return .yellow
        case .decision: return .green
        case .pattern: return .purple
        case .general: return .secondary
        }
    }

    private func mentionedFileExtension(in text: String) -> String? {
        let pattern = #"(?:\"|')?([A-Za-z0-9_\-\(\) ]+\.([A-Za-z0-9]{1,12}))(?:\"|')?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
            let match = regex.matches(
                in: text, options: [], range: NSRange(text.startIndex..., in: text)
            ).last,
            let extRange = Range(match.range(at: 2), in: text)
        else {
            return nil
        }
        let ext = String(text[extRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ext.isEmpty ? nil : ext
    }

    private func mentionsFolderContext(in text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("folder") || lowered.contains("directory") {
            return true
        }
        return mentionedFileExtension(in: text) != nil && lowered.contains(" to ")
    }

    private func insightHistoryScroller(entries: [AIInsight], markFirstAsLatest: Bool) -> some View
    {
        ScrollView {
            FlowLayout(spacing: 6) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, insight in
                    HStack(spacing: 4) {
                        InsightPill(insight: insight)

                        if markFirstAsLatest, index == 0 {
                            Text("Latest")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(SortyDesignSystem.Colors.resolvedAccent.opacity(0.14))
                                )
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 170)
        .scrollIndicators(.visible)
        .accessibilityIdentifier("LiveInsightsHistoryScroll")
    }

    private var streamingPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.word.spacing")
                    .foregroundStyle(.purple)
                Text("AI Response")
                    .fontWeight(.medium)
            }
            .font(.caption)

            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(displayedStreamPreview)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                            .id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: streamPreview) { _, _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .frame(maxWidth: 550, maxHeight: 180)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
        )
        .accessibilityLabel(
            FeatureFlags.privacyModeEnabled
                ? "AI response preview hidden in Privacy Mode" : "AI response preview")
    }

}
