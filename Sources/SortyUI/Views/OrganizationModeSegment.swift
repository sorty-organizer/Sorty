import SwiftUI
import UniformTypeIdentifiers
import Beam

package struct OrganizationModeSegment: View {
    @SortyHotReload private var hotReload
    let mode: OrganizationMode
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    package init(mode: OrganizationMode, isSelected: Bool, action: @escaping () -> Void) {
        self.mode = mode
        self.isSelected = isSelected
        self.action = action
    }

    package var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .symbolReplaceTransition(animationValue: mode)
                Text(mode.displayName)
                    .font(.callout.weight(.semibold))
                    .fixedSize()
                    .numericTextTransition(animationValue: mode)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background {
                Capsule(style: .continuous)
                    .fill(
                        isSelected
                            ? SortyDesignSystem.Colors.resolvedAccent
                            : (isHovering ? Color.secondary.opacity(0.12) : Color.clear)
                    )
            }
            .foregroundColor(isSelected ? .white : .primary)
            .contentShape(Capsule())
            .animation(.sortySnappy, value: isSelected)
            .animation(.sortyFade, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering && !isHovering {
                HapticFeedbackManager.shared.selection()
            }
            isHovering = hovering
        }
        .help(mode.description)
        .accessibilityLabel(mode.displayName)
        .accessibilityHint(mode.description)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension UTType {
    static var fileURL: UTType {
        UTType(exportedAs: "public.file-url")
    }
}
