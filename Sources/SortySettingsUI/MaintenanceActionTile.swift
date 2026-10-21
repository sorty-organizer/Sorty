import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Beam

struct MaintenanceActionTile: View {
    @SortyHotReload private var hotReload
    let title: String
    let description: String
    let detail: String?
    let icon: String
    let color: Color
    let buttonTitle: String
    let buttonIcon: String
    let focusTarget: SettingsFocusTarget
    var isBusy = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isHovered ? color : .secondary)
                    .frame(height: 24)
                    .accessibilityHidden(true)

                HStack(spacing: 6) {
                    Text(LocalizedStringKey(title))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isHovered ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    if let detail {
                        Text(detail)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .numericTextTransition(animationValue: detail)
                    }
                }

                Text(LocalizedStringKey(description))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 32, alignment: .center)

                Label(buttonTitle, systemImage: buttonIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isHovered ? color : .secondary)
                    .padding(.top, 1)
            }
            .frame(maxWidth: .infinity, minHeight: 124)
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .background(isHovered ? color.opacity(0.14) : Color.secondary.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isHovered ? color.opacity(0.32) : Color.secondary.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1)
        // Beam rendering suspends itself while faded out and pauses for
        // Reduce Motion / inactive windows, so this costs nothing at rest.
        .beam(.small, palette: .colorful, theme: .dark, active: isBusy, cornerRadius: 8)
        .settingsFocusable(
            focusTarget,
            shape: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering {
                HapticFeedbackManager.shared.selection()
            }
        }
    }
}
