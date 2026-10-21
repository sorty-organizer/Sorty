import AppKit
import SwiftUI

struct HistoryLiquidGlassLearningsCard: View {
    @SortyHotReload private var hotReload
    let fileContexts: [HistoryLearningsFileContext]

    @EnvironmentObject var learningsManager: LearningsManager
    @State private var showPopover = false
    @State private var hoveredFileID: UUID?

    var body: some View {
        if !fileContexts.isEmpty {
            GlassPillButton(
                icon: "brain.head.profile",
                title: "Learnings Applied",
                tint: .teal,
                count: fileContexts.count
            ) {
                showPopover.toggle()
            }
            .accessibilityLabel("Learnings applied to \(fileContexts.count) files")
            .accessibilityHint("Tap to view file-specific learnings")
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                learningsPopover
                    .systemLiquidGlassPopover(cornerRadius: 12)
            }
        }
    }

    private var learningsPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassPopoverHeader(
                icon: "brain.head.profile",
                title: "Learnings Applied",
                tint: .teal,
                subtitle: "\(fileContexts.count) file\(fileContexts.count == 1 ? "" : "s") with learnings context",
                subtitleAnimationValue: "\(fileContexts.count)"
            )

            Divider()
                .opacity(0.4)
                .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(fileContexts) { context in
                        learningsFileRow(context)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(14)
        .frame(minWidth: 320, maxWidth: 430)
    }

    private func learningsFileRow(_ context: HistoryLearningsFileContext) -> some View {
        HStack(spacing: 10) {
            FileThumbnailView(url: URL(fileURLWithPath: context.file.path), size: CGSize(width: 24, height: 24))

            VStack(alignment: .leading, spacing: 2) {
                Text(context.file.displayName)
                    .font(.callout)
                    .lineLimit(1)

                PrivacySensitivePathText(path: context.suggestion.folderName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            LiquidGlassLearningsButton(
                file: context.file,
                suggestion: context.suggestion,
                learningsManager: learningsManager
            )
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hoveredFileID == context.file.id ? Color.secondary.opacity(0.1) : Color.clear)
        )
        .onHover { isHovering in
            hoveredFileID = isHovering ? context.file.id : nil
        }
    }

}

struct HistoryLiquidGlassReasoningCard: View {
    @SortyHotReload private var hotReload
    let notes: String
    @State private var showPopover = false

    var body: some View {
        GlassPillButton(
            icon: "brain",
            title: "AI Reasoning",
            tint: SortyDesignSystem.Colors.resolvedAccent
        ) {
            showPopover.toggle()
        }
        .accessibilityLabel("AI Reasoning")
        .accessibilityHint("Tap to view AI reasoning details")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                GlassPopoverHeader(
                    icon: "brain",
                    title: "AI Reasoning",
                    tint: SortyDesignSystem.Colors.resolvedAccent
                )

                Divider()
                    .opacity(0.4)
                    .padding(.bottom, 10)

                FormattedReasoningText(
                    text: notes,
                    font: .callout,
                    secondaryFont: .caption,
                    foregroundStyle: .primary
                )
            }
            .padding(14)
            .frame(minWidth: 280, maxWidth: 400)
            .systemLiquidGlassPopover(cornerRadius: 12)
        }
    }
}
