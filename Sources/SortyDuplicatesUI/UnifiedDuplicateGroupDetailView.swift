import AppKit
import Foundation
import SwiftUI
import Beam

struct UnifiedDuplicateGroupDetailView: View {
    @SortyHotReload private var hotReload
    let group: UnifiedDuplicateGroup
    let settings: DuplicateSettings
    let onDelete: ([FileItem]) -> Void
    @State private var selectedKeepFileId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupOverview

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(sortedFiles, id: \.id) { file in
                        UnifiedFileDetailRow(
                            file: file,
                            isRecommended: file.id == effectiveKeepFileId,
                            recommendation: recommendationLabel(for: file),
                            onKeep: {
                                HapticFeedbackManager.shared.selection()
                                selectedKeepFileId = file.id
                            },
                            onDelete: {
                                onDelete([file])
                            }
                        )
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            selectedKeepFileId = preferredKeepFileId()
        }
        .onChange(of: group.id) { _, _ in
            selectedKeepFileId = preferredKeepFileId()
        }
        .onChange(of: settings.defaultKeepStrategy) { _, _ in
            selectedKeepFileId = preferredKeepFileId()
        }
    }

    private var groupOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                overviewTitle
                Spacer(minLength: 8)
            }

            HStack {
                primaryActionButton
                Spacer(minLength: 0)
            }

            metricsGrid

            if let recommendation = group.recommendation, recommendation == .manualReview {
                Text("This group needs manual review before Sorty will choose files to remove.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 104), spacing: 8)
            ],
            alignment: .leading,
            spacing: 8
        ) {
            DuplicateMetricTile(
                value: "\(group.files.count)", label: group.isExact ? "copies" : "versions",
                color: .primary)
            DuplicateMetricTile(
                value: ByteCountFormatter.string(
                    fromByteCount: group.potentialSavings, countStyle: .file), label: "recoverable",
                color: .green)
            DuplicateMetricTile(
                value: group.isExact ? "100%" : (group.similarityPercentage ?? "Review"),
                label: group.isExact ? "match" : "similarity",
                color: group.isExact ? .orange : .blue)
        }
    }

    private var overviewTitle: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !group.isExact || group.confidenceLevel == .low {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        overviewBadges
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        overviewBadges
                    }
                }
            }

            Text(group.displayName)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .layoutPriority(1)
    }

    @ViewBuilder
    private var overviewBadges: some View {
        if !group.isExact {
            Text(group.groupTypeLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1), in: Capsule())
        }

        if group.confidenceLevel == .low {
            confidenceBadge
        }
    }

    private var confidenceBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.orange)
                .frame(width: 6, height: 6)
            Text(group.confidenceLevel.rawValue)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if let recommendation = group.recommendation {
            Button {
                removeFilesExceptSelectedKeepFile()
            } label: {
                Text(compactButtonTitle(for: recommendation))
            }
            .buttonStyle(.sortyPrimary)
            .tint(.blue)
            .controlSize(.regular)
            .help(recommendation.description)
        } else {
            Button {
                removeFilesExceptSelectedKeepFile()
            } label: {
                Text("Clean Up Selected")
            }
            .buttonStyle(.sortyPrimary)
            .tint(.red)
            .controlSize(.regular)
            .help("Keep the first file and clean up the rest.")
        }
    }

    private var sortedFiles: [FileItem] {
        // Put recommended file first, then sort by date
        let recommendedId = effectiveKeepFileId
        return group.files.sorted { f1, f2 in
            if f1.id == recommendedId { return true }
            if f2.id == recommendedId { return false }
            let d1 = f1.creationDate ?? Date.distantPast
            let d2 = f2.creationDate ?? Date.distantPast
            return d1 < d2
        }
    }

    private func recommendationLabel(for file: FileItem) -> String? {
        guard file.id == effectiveKeepFileId else { return nil }

        if selectedKeepFileId == file.id {
            return "Selected"
        }

        switch group.recommendation {
        case .keepHighestResolution:
            return "Highest Res"
        case .keepNewest:
            return "Newest"
        case .keepOldest:
            return "Original"
        case .keepLargest:
            return "Largest"
        case .archiveOlderVersions:
            return "Latest Draft"
        case .manualReview, .none:
            return "Recommended"
        }
    }

    private func compactButtonTitle(
        for recommendation: SemanticDuplicateGroup.DuplicateRecommendation
    ) -> String {
        switch recommendation {
        case .keepHighestResolution:
            return "Clean Up Selected"
        case .keepNewest:
            return "Clean Up Selected"
        case .keepOldest:
            return "Clean Up Selected"
        case .keepLargest:
            return "Clean Up Selected"
        case .archiveOlderVersions:
            return "Archive Older"
        case .manualReview:
            return "Clean Up Selected"
        }
    }

    private var effectiveKeepFileId: UUID? {
        if let selectedKeepFileId,
           group.files.contains(where: { $0.id == selectedKeepFileId }) {
            return selectedKeepFileId
        }
        return preferredKeepFileId()
    }

    private func removeFilesExceptSelectedKeepFile() {
        guard let keepId = effectiveKeepFileId,
              group.files.contains(where: { $0.id == keepId }) else { return }
        let filesToRemove = group.files.filter { $0.id != keepId }
        guard !filesToRemove.isEmpty else { return }
        onDelete(filesToRemove)
    }

    private func preferredKeepFileId() -> UUID? {
        if group.isExact {
            return keepFile(using: settings.defaultKeepStrategy)?.id
        }
        if let recommended = group.recommendedFileId,
           group.files.contains(where: { $0.id == recommended }) {
            return recommended
        }

        return keepFile(using: settings.defaultKeepStrategy)?.id
    }

    private func keepFile(using strategy: KeepStrategy) -> FileItem? {
        switch strategy {
        case .newest:
            return group.files.max { comparableDate(for: $0) < comparableDate(for: $1) }
        case .oldest:
            return group.files.min { comparableDate(for: $0) < comparableDate(for: $1) }
        case .largest:
            return group.files.max { $0.size < $1.size }
        case .smallest:
            return group.files.min { $0.size < $1.size }
        case .shortestPath:
            return group.files.min { $0.path.count < $1.path.count }
        }
    }

    private func comparableDate(for file: FileItem) -> Date {
        file.modificationDate ?? file.creationDate ?? .distantPast
    }
}

struct DuplicateMetricTile: View {
    @SortyHotReload private var hotReload
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .numericTextTransition(animationValue: value)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .systemLiquidGlassBackground(cornerRadius: 10, interactive: false)
        .frame(minHeight: 50)
        .accessibilityElement(children: .combine)
    }
}
