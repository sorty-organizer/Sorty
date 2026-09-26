import SwiftUI

// MARK: - Inline Notice

struct InlineNoticeAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String?
    let action: () -> Void

    init(title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }
}

enum NoticeSeverity {
    case info
    case warning
    case tip

    var color: Color {
        switch self {
        case .info: return .blue
        case .warning: return .orange
        case .tip: return .green
        }
    }

    var defaultIcon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .tip: return "lightbulb.fill"
        }
    }
}

struct InlineNotice: View {
    @SortyHotReload private var hotReload
    let icon: String?
    let title: String
    let message: String?
    let severity: NoticeSeverity
    var actions: [InlineNoticeAction]
    var isCentered: Bool

    init(
        icon: String? = nil,
        title: String,
        message: String? = nil,
        severity: NoticeSeverity = .info,
        actions: [InlineNoticeAction] = [],
        isCentered: Bool = false
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.severity = severity
        self.actions = actions
        self.isCentered = isCentered
    }

    private var effectiveIcon: String {
        icon ?? severity.defaultIcon
    }

    var body: some View {
        VStack(alignment: isCentered ? .center : .leading, spacing: 6) {
            InlineNoticeHeader(
                icon: effectiveIcon,
                title: title,
                color: severity.color,
                isCentered: isCentered
            )

            if let message = message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(isCentered ? .center : .leading)
                    .padding(.leading, isCentered ? 0 : 20)
            }

            if !actions.isEmpty {
                InlineNoticeActions(
                    actions: actions,
                    color: severity.color,
                    isCentered: isCentered
                )
                .padding(.leading, isCentered ? 0 : 20)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: isCentered ? .center : .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(severity.color.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(severity.color.opacity(0.15), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityHint(message ?? "")
    }
}

private struct InlineNoticeHeader: View {
    @SortyHotReload private var hotReload
    let icon: String
    let title: String
    let color: Color
    let isCentered: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isCentered {
                Spacer(minLength: 0)
            }

            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .accessibilityHidden(true)

            Text(LocalizedStringKey(title))
                .font(.caption)
                .fontWeight(.semibold)

            Spacer(minLength: 0)
        }
    }
}

private struct InlineNoticeActions: View {
    @SortyHotReload private var hotReload
    let actions: [InlineNoticeAction]
    let color: Color
    let isCentered: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isCentered {
                Spacer(minLength: 0)
            }

            ForEach(actions) { action in
                InlineNoticeActionButton(action: action, color: color)
            }

            if isCentered {
                Spacer(minLength: 0)
            }
        }
    }
}

private struct InlineNoticeActionButton: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let action: InlineNoticeAction
    let color: Color
    @State private var isHovering = false

    var body: some View {
        Button {
            HapticFeedbackManager.shared.tap()
            action.action()
        } label: {
            HStack(spacing: 4) {
                if let systemImage = action.systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2)
                }
                Text(action.title)
                    .font(.caption)
                    .fontWeight(.medium)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(isHovering ? 0.2 : 0.12))
        )
        .scaleEffect(reduceMotion ? 1 : (isHovering ? 1.03 : 1))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            if hovering != isHovering {
                isHovering = hovering
                if hovering {
                    HapticFeedbackManager.shared.selection()
                }
            }
        }
        .accessibilityLabel(action.title)
        .accessibilityIdentifier("InlineNoticeAction-\(action.title)")
        .accessibilityHint("Activates \(action.title.lowercased()) action")
    }
}

// MARK: - Insight Pill

struct InsightPill: View {
    @SortyHotReload private var hotReload
    let insight: AIInsight

    private var displayText: String {
        FeatureFlags.privacyModeEnabled
            ? PrivacyPathMasker.redactedText(insight.text) : insight.text
    }

    private var resolvedFinderIcon: NSImage? {
        if insight.category == .folder {
            return AnalysisIconProvider.icon(for: .folder)
        }

        if insight.category == .file {
            let text = insight.text
            if let dotIndex = text.lastIndex(of: ".") {
                let ext =
                    String(text[text.index(after: dotIndex)...])
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces).first ?? ""
                if !ext.isEmpty {
                    return AnalysisIconProvider.icon(forFileExtension: ext)
                }
            }
            return AnalysisIconProvider.icon(for: .data)
        }

        return nil
    }

    private var categoryColor: Color {
        switch insight.category {
        case .file: return .blue
        case .folder: return .orange
        case .constraint: return .yellow
        case .decision: return .green
        case .pattern: return .purple
        case .general: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let filePath = insight.filePath {
                let fileURL = URL(fileURLWithPath: filePath)
                if fileURL.hasDirectoryPath {
                    FolderThumbnailView(url: fileURL, size: CGSize(width: 14, height: 14))
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                } else {
                    FileThumbnailView(url: fileURL, size: CGSize(width: 14, height: 14))
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                }
            } else if let finderIcon = resolvedFinderIcon {
                AppKitImageView(image: finderIcon, size: CGSize(width: 14, height: 14))
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(categoryColor.opacity(0.3))
                    .overlay(
                        Circle().stroke(categoryColor.opacity(0.65), lineWidth: 1)
                    )
                    .frame(width: 8, height: 8)
                    .padding(.horizontal, 3)
                    .accessibilityHidden(true)
            }

            Text(displayText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.1))
        )
    }
}
