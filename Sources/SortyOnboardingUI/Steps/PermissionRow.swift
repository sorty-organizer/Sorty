import AppKit
import AVFoundation
import SwiftUI
import UserNotifications
import Permiso

struct PermissionRow: View {
    @SortyHotReload private var hotReload
    let type: PermissionType
    let state: PermissionState
    let isRequired: Bool
    let onExplain: () -> Void
    let onRequest: (CGRect?) -> Void
    let removePermissionTitle: String
    let onRemovePermission: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @State private var grantFlash = false
    @State private var grantAnimationTrigger = 0

    init(
        type: PermissionType,
        state: PermissionState,
        isRequired: Bool,
        onExplain: @escaping () -> Void,
        onRequest: @escaping (CGRect?) -> Void,
        removePermissionTitle: String = "Remove Permission…",
        onRemovePermission: (() -> Void)? = nil
    ) {
        self.type = type
        self.state = state
        self.isRequired = isRequired
        self.onExplain = onExplain
        self.onRequest = onRequest
        self.removePermissionTitle = removePermissionTitle
        self.onRemovePermission = onRemovePermission
    }

    var body: some View {
        HStack(spacing: 14) {
            permissionIcon

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(LocalizedStringKey(type.rawValue))
                        .font(.headline)

                    if isRequired {
                        Text("Required")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(SortyDesignSystem.Colors.resolvedAccent.opacity(0.12), in: Capsule(style: .continuous))
                    }
                }

                Text(type.description(for: state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            trailingControl
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(rowFill)
        )
        .systemLiquidGlassBackground(cornerRadius: 14, interactive: false)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(rowStroke, lineWidth: state == .granted || grantFlash ? 1.2 : 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.12 : 0.05), radius: isHovering ? 12 : 7, x: 0, y: isHovering ? 6 : 3)
        .scaleEffect(grantFlash ? 1.012 : (isHovering ? 1.006 : 1))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: state)
        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86), value: isHovering)
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.82), value: grantFlash)
        .onHover { hovering in
            isHovering = hovering
        }
        .onChange(of: state) { _, newState in
            guard newState == .granted || newState == .restartRequired else { return }
            grantAnimationTrigger += 1
            playApprovalAnimation()
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

    private var canRemovePermission: Bool {
        state == .granted || state == .restartRequired
    }

    private var iconTint: Color {
        state == .granted || state == .restartRequired ? state.tint : type.color
    }

    private var rowFill: Color {
        if state == .granted {
            return Color.green.opacity(colorScheme == .dark ? 0.12 : 0.08)
        }

        return Color(nsColor: .controlBackgroundColor)
            .opacity(colorScheme == .dark ? (isHovering ? 0.82 : 0.68) : (isHovering ? 0.94 : 0.82))
    }

    private var rowStroke: Color {
        if grantFlash || state == .granted {
            return Color.green.opacity(grantFlash ? 0.72 : 0.34)
        }

        if isHovering {
            return type.color.opacity(0.30)
        }

        return Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08)
    }

    private var permissionIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(iconTint.opacity(state == .granted ? 0.18 : 0.13))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(iconTint.opacity(state == .granted ? 0.28 : 0.18), lineWidth: 1)
                }

            PermissionAnimatedIcon(
                type: type,
                state: state,
                grantAnimationTrigger: grantAnimationTrigger,
                size: 19
            )
                .foregroundStyle(iconTint)
        }
        .frame(width: 46, height: 46)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch state {
        case .granted, .pending, .restartRequired:
            statusChip
        case .denied:
            PermissionActionButton(title: deniedActionTitle, style: .bordered, action: onRequest)
                .fixedSize()
        case .unknown:
            HStack(spacing: 8) {
                Button {
                    HapticFeedbackManager.shared.tap()
                    onExplain()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        HapticFeedbackManager.shared.selection()
                    }
                }
                .help("Show what Sorty asks for")
                .accessibilityLabel("Learn about \(type.rawValue)")

                PermissionActionButton(
                    title: type.compactActionTitle,
                    style: isRequired ? .primary : .bordered,
                    action: onRequest
                )
                .fixedSize()
            }
        }
    }

    private var deniedActionTitle: String {
        switch type {
        case .automation:
            return "Try Again"
        case .notifications:
            return "Enable in Settings"
        default:
            return type.compactActionTitle
        }
    }

    private var statusChip: some View {
        HStack(spacing: 6) {
            Image(systemName: state.symbol)
                .font(.system(size: 11, weight: .bold))
                .symbolReplaceTransition(animationValue: state)
            Text(state.title(for: type))
                .font(.caption.weight(.semibold))
                .numericTextTransition(animationValue: state)
        }
        .foregroundStyle(state.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(state.tint.opacity(0.12), in: Capsule(style: .continuous))
        .accessibilityLabel(state.title(for: type))
    }

    private func playApprovalAnimation() {
        HapticFeedbackManager.shared.success()
        guard !reduceMotion else { return }

        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
            grantFlash = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            withAnimation(.easeOut(duration: 0.24)) {
                grantFlash = false
            }
        }
    }
}
