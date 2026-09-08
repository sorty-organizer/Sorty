//
//  HUDNotificationOverlay.swift
//  Sorty
//
//  A subtle bottom-left HUD notification overlay with liquid glass styling
//

import SwiftUI

/// HUD notification overlay that appears at the bottom-left of the window
public struct HUDNotificationOverlay: View {
    @SortyHotReload private var hotReload
    @ObservedObject private var notificationManager: NotificationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    public init() {
        self._notificationManager = ObservedObject(wrappedValue: NotificationManager.shared)
    }
    
    public var body: some View {
        VStack {
            Spacer()
            
            HStack {
                if let notification = notificationManager.currentHUDNotification {
                    HUDNotificationCard(
                        notification: notification,
                        queuedCount: notificationManager.hudNotificationQueue.count,
                        onShowNext: {
                            notificationManager.showNextHUDNotification()
                        },
                        onDismissAll: {
                            notificationManager.dismissAllHUDNotifications()
                        }
                    ) {
                        notificationManager.dismissHUD()
                    }
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.92).combined(with: .opacity).combined(with: .offset(x: -20)),
                        removal: .scale(scale: 0.95).combined(with: .opacity).combined(with: .offset(x: -10))
                    ))
                }
                
                Spacer()
            }
            .padding(.leading, 20)
            .padding(.bottom, 20)
        }
        .allowsHitTesting(notificationManager.currentHUDNotification != nil)
        .animation(
            reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.78),
            value: notificationManager.currentHUDNotification?.id
        )
        .ignoresSafeArea()
        .zIndex(1000)
    }
}

/// Individual HUD notification card with liquid glass styling
struct HUDNotificationCard: View {
    @SortyHotReload private var hotReload
    let notification: HUDNotification
    let queuedCount: Int
    let onShowNext: () -> Void
    let onDismissAll: () -> Void
    let onDismiss: () -> Void
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var progressRemaining: CGFloat = 1.0
    
    private let autoDismissSeconds = NotificationManager.transientHUDDuration
    private var queuedSummary: String {
        queuedCount == 1 ? "1 more" : "\(queuedCount) more"
    }

    private var supportsLiquidGlass: Bool {
        if #available(macOS 26.0, *) {
            true
        } else {
            false
        }
    }
    
    var body: some View {
        HStack(spacing: 10) {
            Capsule(style: .continuous)
                .fill(notification.iconColor)
                .frame(width: 3)
                .padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 10) {
                HUDNotificationHeader(
                    notification: notification,
                    isHovered: isHovered,
                    showsInlineAction: supportsLiquidGlass,
                    onDismiss: onDismiss
                )

                if notification.actions.count > 1 || (!supportsLiquidGlass && !notification.actions.isEmpty) {
                    HUDNotificationActionGrid(actions: notification.actions)
                }

                if queuedCount > 0 {
                    HUDNotificationQueueControls(
                        summary: queuedSummary,
                        queuedCount: queuedCount,
                        onShowNext: onShowNext,
                        onDismissAll: onDismissAll
                    )
                }
            }
            .padding(.trailing, 12)
            .padding(.vertical, 10)
        }
        .padding(.leading, 12)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .systemLiquidGlassBackground(cornerRadius: 14)
        .hudFallbackBackground(cornerRadius: 14)
        .overlay(alignment: .bottom) {
            if !notification.isPersistent {
                HUDNotificationProgress(
                    color: notification.iconColor,
                    remaining: progressRemaining
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    Color.white.opacity(0.18),
                    lineWidth: 1
                )
        )
        .shadow(color: notification.iconColor.opacity(0.12), radius: 12, x: 0, y: 6)
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            activateCard()
        }
        .onAppear {
            startProgressAnimation()
        }
        .onChange(of: notification.id) { _, _ in
            startProgressAnimation()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(notification.title): \(notification.message)")
        .accessibilityHint(accessibilityHint)
        .accessibilityActions {
            if notification.defaultAction != nil || !notification.isPersistent {
                Button(notification.defaultAction != nil ? "Open notification" : "Dismiss notification") {
                    activateCard()
                }
            }
        }
    }

    private func activateCard() {
        if let defaultAction = notification.defaultAction {
            HapticFeedbackManager.shared.tap()
            defaultAction()
        } else if !notification.isPersistent {
            onDismiss()
        }
    }

    private func startProgressAnimation() {
        guard !notification.isPersistent else {
            progressRemaining = 1
            return
        }

        progressRemaining = 1
        withAnimation(reduceMotion ? nil : .linear(duration: autoDismissSeconds)) {
            progressRemaining = 0
        }
    }

    private var accessibilityHint: String {
        if queuedCount > 0 {
            return "\(queuedSummary) queued. Use the notification controls to show next or clear all."
        }
        if notification.defaultAction != nil {
            return "Opens the notification"
        }
        return notification.isPersistent ? "" : "Dismisses the notification"
    }
}

private struct HUDNotificationHeader: View {
    @SortyHotReload private var hotReload
    let notification: HUDNotification
    let isHovered: Bool
    let showsInlineAction: Bool
    let onDismiss: () -> Void

    private var inlineAction: HUDNotificationAction? {
        showsInlineAction && notification.actions.count == 1 ? notification.actions.first : nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notification.icon)
                .font(.title3)
                .foregroundStyle(notification.iconColor)
                .frame(width: 28, height: 28)
                .symbolReplaceTransition(animationValue: notification.icon)
                .systemLiquidGlassBackground(cornerRadius: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .numericTextTransition(animationValue: notification.title)

                Text(notification.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .numericTextTransition(animationValue: notification.message)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let inlineAction {
                Button(role: inlineAction.role) {
                    inlineAction.action()
                } label: {
                    HUDNotificationActionLabel(action: inlineAction, fillsWidth: false)
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
            }

            if isHovered && !notification.isPersistent {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
    }
}

private struct HUDFallbackBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else if reduceTransparency {
            content.background(
                Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content.background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }
}

private extension View {
    func hudFallbackBackground(cornerRadius: CGFloat) -> some View {
        modifier(HUDFallbackBackground(cornerRadius: cornerRadius))
    }
}

private struct HUDNotificationActionGrid: View {
    @SortyHotReload private var hotReload
    let actions: [HUDNotificationAction]

    // Pairs of actions per row; a trailing odd action (e.g. "Never show again"
    // below "Try Faster Model" + "Cancel") gets its own row and fills it.
    private var rows: [[HUDNotificationAction]] {
        stride(from: 0, to: actions.count, by: 2).map { start in
            Array(actions[start..<min(start + 2, actions.count)])
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row) { action in
                        actionButton(action)
                    }
                }
            }
        }
    }

    private func actionButton(_ action: HUDNotificationAction) -> some View {
        Button(role: action.role) {
            action.action()
        } label: {
            HUDNotificationActionLabel(action: action, fillsWidth: true)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

private struct HUDNotificationQueueControls: View {
    @SortyHotReload private var hotReload
    let summary: String
    let queuedCount: Int
    let onShowNext: () -> Void
    let onDismissAll: () -> Void

    var body: some View {
        Divider()
            .opacity(0.5)

        HStack(spacing: 8) {
            Label {
                Text(summary)
                    .numericTextTransition(animationValue: queuedCount)
            } icon: {
                Image(systemName: "rectangle.stack")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Spacer(minLength: 8)

            queueButton("Next", systemImage: "arrow.right", accessibilityLabel: "Show next HUD notification", action: onShowNext)
            queueButton("Clear all", systemImage: "xmark.circle", accessibilityLabel: "Clear all HUD notifications", action: onDismissAll)
        }
    }

    private func queueButton(
        _ title: String,
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.plain)
        .frame(width: 28, height: 28)
        .systemLiquidGlassBackground(cornerRadius: 8)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct HUDNotificationProgress: View {
    @SortyHotReload private var hotReload
    let color: Color
    let remaining: CGFloat

    var body: some View {
        Capsule()
            .fill(color.opacity(0.4))
            .frame(maxWidth: .infinity)
            .scaleEffect(x: remaining, anchor: .leading)
            .frame(height: 2)
            .padding(.horizontal, 6)
            .padding(.bottom, 3)
    }
}

private struct HUDNotificationActionLabel: View {
    @SortyHotReload private var hotReload
    let action: HUDNotificationAction
    let fillsWidth: Bool
    @Environment(\.isEnabled) private var isEnabled

    private var isDestructive: Bool {
        action.role == .destructive
    }

    private var accent: Color {
        isDestructive ? SortyDesignSystem.Colors.error : SortyDesignSystem.Colors.resolvedAccent
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage = action.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }

            Text(action.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .foregroundStyle(isDestructive ? Color.red : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 30, alignment: .center)
        .systemLiquidGlassBackground(cornerRadius: 8)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(accent.opacity(isDestructive ? 0.28 : 0.22), lineWidth: 1)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

#Preview("HUD Overlay") {
    ZStack {
        Color.gray.opacity(0.3)
        HUDNotificationOverlay()
    }
    .frame(width: 800, height: 600)
    .onAppear {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            NotificationManager.shared.showInfo(title: "Test Notification", message: "This is a preview notification to verify the HUD is working correctly!")
        }
    }
}
