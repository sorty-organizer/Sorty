import SwiftUI

// MARK: - Generate Persona Button

struct GeneratePersonaButton: View {
    @SortyHotReload private var hotReload
    enum Style {
        case expanded
        case compact
    }

    let style: Style
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var isHovered = false

    init(
        style: Style = .expanded,
        title: String = "Generate Your Own",
        subtitle: String = "Describe your ideal organization style",
        action: @escaping () -> Void
    ) {
        self.style = style
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }

    var body: some View {
        Button {
            action()
            HapticFeedbackManager.shared.selection()
        } label: {
            label
                .padding(.vertical, style == .expanded ? 14 : 10)
                .padding(.horizontal, style == .expanded ? 16 : 14)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.08 : 0.045))
                )
                .systemLiquidGlassBackground(cornerRadius: cornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(isHovered ? 0.18 : 0.09), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .shadow(
            color: Color.black.opacity(isHovered ? shadowHoverOpacity : shadowOpacity),
            radius: isHovered ? shadowHoverRadius : shadowRadius,
            x: 0,
            y: isHovered ? shadowHoverY : shadowY
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }

    @ViewBuilder
    private var label: some View {
        switch style {
        case .expanded:
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 50, height: 50)

                    Image(systemName: "sparkles")
                        .font(.system(size: 24))
                        .foregroundStyle(.primary)
                }

                VStack(spacing: 4) {
                    Text(LocalizedStringKey(title))
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(LocalizedStringKey(subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)

        case .compact:
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 38, height: 38)

                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(LocalizedStringKey(subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var cornerRadius: CGFloat { style == .expanded ? 16 : 14 }
    private var shadowOpacity: Double { style == .expanded ? 0.025 : 0.02 }
    private var shadowHoverOpacity: Double { style == .expanded ? 0.06 : 0.05 }
    private var shadowRadius: CGFloat { style == .expanded ? 7 : 5 }
    private var shadowHoverRadius: CGFloat { style == .expanded ? 14 : 10 }
    private var shadowY: CGFloat { style == .expanded ? 3 : 2 }
    private var shadowHoverY: CGFloat { style == .expanded ? 7 : 5 }
}

// MARK: - Capsule Badge

struct OnboardingCapsuleBadge: View {
    @SortyHotReload private var hotReload
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .systemLiquidGlassBackground(cornerRadius: 999)
    }
}
