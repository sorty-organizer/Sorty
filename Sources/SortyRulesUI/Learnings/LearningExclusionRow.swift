import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Learning Exclusion Row

struct LearningExclusionRow: View {
    @SortyHotReload private var hotReload
    let pattern: String
    @ObservedObject var manager: LearningsManager
    @EnvironmentObject private var exclusionRules: ExclusionRulesManager
    @State private var isHovered = false

    private var displayName: String {
        let lastComponent = URL(fileURLWithPath: pattern).lastPathComponent
        return lastComponent.isEmpty ? pattern : lastComponent
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.slash.fill")
                .font(.body.bold())
                .foregroundColor(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.subheadline.bold())
                PrivacySensitivePathText(path: pattern)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                HapticFeedbackManager.shared.tap()
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: pattern)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
                    .font(.caption.bold())
            }
            .buttonStyle(.sortyPrimary(isSecondary: true, size: .small))

            Button {
                HapticFeedbackManager.shared.tap()
                Task {
                    await manager.removeLearningExclusion(pattern)
                    exclusionRules.removeLegacyLearningsLinkedRules(
                        matchingLearningPattern: pattern)
                }
            } label: {
                Label("Remove", systemImage: "xmark")
                    .font(.caption.bold())
            }
            .buttonStyle(.sortyPrimary(isSecondary: true, size: .small))
            .accessibilityLabel("Remove learnings exclusion for \(displayName)")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(isHovered ? 0.08 : 0.03))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            if hovering { HapticFeedbackManager.shared.selection() }
        }
        .accessibilityElement(children: .contain)
    }
}
