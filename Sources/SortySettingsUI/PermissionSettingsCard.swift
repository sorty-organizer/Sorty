import AppKit
import SwiftUI
import UserNotifications
import Permiso

struct PermissionSettingsCard: View {
    @SortyHotReload private var hotReload
    let type: PermissionType
    let state: PermissionState
    let isRequired: Bool
    let isFeatured: Bool
    let grantAnimationTrigger: Int
    let onExplain: () -> Void
    let onRequest: (CGRect?) -> Void
    let removePermissionTitle: String
    let onRemovePermission: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var actionFrameInScreen: CGRect = .zero
    @State private var isHovering = false
    @State private var isHoveringRemove = false

    init(
        type: PermissionType,
        state: PermissionState,
        isRequired: Bool,
        isFeatured: Bool = false,
        grantAnimationTrigger: Int,
        onExplain: @escaping () -> Void,
        onRequest: @escaping (CGRect?) -> Void,
        removePermissionTitle: String = "Remove Permission…",
        onRemovePermission: (() -> Void)? = nil
    ) {
        self.type = type
        self.state = state
        self.isRequired = isRequired
        self.isFeatured = isFeatured
        self.grantAnimationTrigger = grantAnimationTrigger
        self.onExplain = onExplain
        self.onRequest = onRequest
        self.removePermissionTitle = removePermissionTitle
        self.onRemovePermission = onRemovePermission
    }

    var body: some View {
        Group {
            if isFeatured {
                HStack(spacing: 14) {
                    permissionIcon

                    VStack(alignment: .leading, spacing: 4) {
                        title

                        permissionDescription
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 16)

                    footer
                }
            } else {
                VStack(spacing: 7) {
                    permissionIcon

                    title

                    permissionDescription

                    Spacer(minLength: 2)

                    footer
                }
            }
        }
        .padding(.horizontal, isFeatured ? 16 : 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: isFeatured ? 76 : 148)
        .background(cardFill)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(cardStroke, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .scaleEffect(isHovering ? 1.006 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isHovering)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78), value: state)
        .onHover { hovering in
            if hovering && !isHovering {
                HapticFeedbackManager.shared.selection()
            }
            isHovering = hovering
        }
        .contextMenu {
            if canRemovePermission, let onRemovePermission {
                Button(role: .destructive) {
                    HapticFeedbackManager.shared.tap()
                    onRemovePermission()
                } label: {
                    Label(LocalizedStringKey(removePermissionTitle), systemImage: "minus.circle")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var permissionIcon: some View {
        PermissionAnimatedIcon(
            type: type,
            state: state,
            grantAnimationTrigger: grantAnimationTrigger,
            size: isFeatured ? 27 : 23
        )
            .foregroundStyle(isHovering ? type.color : .secondary)
            .frame(width: isFeatured ? 40 : nil, height: isFeatured ? 40 : 28)
            .accessibilityHidden(true)
    }

    private var title: some View {
        HStack(spacing: 5) {
            Text(LocalizedStringKey(type.rawValue))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .multilineTextAlignment(isFeatured ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)

            if isRequired {
                Text("Required")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.18), in: Capsule(style: .continuous))
                    .systemLiquidGlassBackground(cornerRadius: 999)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.red.opacity(0.38), lineWidth: 0.75)
                    )
            }
        }
    }

    private var permissionDescription: some View {
        Text(type.description(for: state))
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                maxWidth: isFeatured ? 420 : .infinity,
                minHeight: isFeatured ? nil : 26,
                alignment: isFeatured ? .leading : .top
            )
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: state.symbol)
                .font(.system(size: 10, weight: .bold))
                .symbolReplaceTransition(animationValue: state)

            Text(state.title(for: type))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .numericTextTransition(animationValue: state)
        }
        .foregroundStyle(state.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(state.tint.opacity(0.11), in: Capsule(style: .continuous))
        .accessibilityLabel(state.title(for: type))
    }

    @ViewBuilder
    private var footer: some View {
        if canRemovePermission, let onRemovePermission {
            HStack(spacing: 7) {
                statusBadge

                Button {
                    HapticFeedbackManager.shared.tap()
                    onRemovePermission()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isHoveringRemove ? .red : .secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            Color.red.opacity(isHoveringRemove ? 0.12 : 0),
                            in: Circle()
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(removePermissionTitle)
                .accessibilityLabel(removePermissionTitle)
                .onHover { hovering in
                    if hovering && !isHoveringRemove {
                        HapticFeedbackManager.shared.selection()
                    }
                    withAnimation(
                        reduceMotion
                            ? nil
                            : .spring(response: 0.24, dampingFraction: 0.82)
                    ) {
                        isHoveringRemove = hovering
                    }
                }
            }
            .fixedSize()
        } else {
            switch state {
            case .pending:
                statusBadge
                    .frame(height: 24)

            case .granted, .restartRequired:
                EmptyView()

            case .unknown, .denied:
                HStack(spacing: 8) {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        onExplain()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Learn why Sorty uses this permission")
                    .accessibilityLabel("Learn about \(type.rawValue)")

                    Button {
                        HapticFeedbackManager.shared.tap()
                        onRequest(actionFrameInScreen.isEmpty ? nil : actionFrameInScreen.integral)
                    } label: {
                        Text(LocalizedStringKey(actionTitle))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .frame(maxWidth: isFeatured ? 180 : .infinity)
                    }
                    .buttonStyle(.sortySecondary(size: .small, color: type.color))
                    .background(
                        ScreenFrameReader(frameInScreen: $actionFrameInScreen)
                            .allowsHitTesting(false)
                    )
                    .accessibilityLabel(actionTitle)
                }
                .frame(maxWidth: isFeatured ? 220 : .infinity)
            }
        }
    }

    private var actionTitle: String {
        guard state == .denied else { return type.compactActionTitle }

        switch type {
        case .notifications:
            return "Open Settings"
        case .automation:
            return "Try Again"
        default:
            return type.compactActionTitle
        }
    }

    private var canRemovePermission: Bool {
        state == .granted || state == .restartRequired
    }

    private var cardFill: Color {
        isHovering ? type.color.opacity(0.08) : Color.secondary.opacity(0.045)
    }

    private var cardStroke: Color {
        isHovering ? type.color.opacity(0.28) : Color.secondary.opacity(0.09)
    }
}
