import AppKit
import AVFoundation
import SwiftUI
import UserNotifications
import Permiso

struct PermissionActionButton: View {
    @SortyHotReload private var hotReload
    enum Style {
        case primary
        case bordered
    }

    let title: String
    let style: Style
    let action: (CGRect?) -> Void

    @State private var frameInScreen: CGRect = .zero
    @State private var isHovering = false

    var body: some View {
        Button {
            action(frameInScreen.isEmpty ? nil : frameInScreen.integral)
        } label: {
            Text(LocalizedStringKey(title))
                .frame(minWidth: style == .primary ? 74 : 96)
        }
        .buttonStyle(buttonStyle)
        .contentShape(Capsule())
        .background(
            ScreenFrameReader(frameInScreen: $frameInScreen)
                .allowsHitTesting(false)
        )
        .onHover { hovering in
            if hovering && !isHovering {
                HapticFeedbackManager.shared.selection()
            }
            isHovering = hovering
        }
        .accessibilityLabel(title)
    }

    private var buttonStyle: SortyPrimaryButtonStyle {
        switch style {
        case .primary:
            return .init(size: .small)
        case .bordered:
            return .init(isSecondary: true, size: .small)
        }
    }
}
