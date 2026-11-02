//
//  SortySurfaces.swift
//  Sorty
//
//  Shared surfaces, chips, badges, and empty states. Use these instead of
//  hand-rolling fills, strokes, and capsules in feature views.
//

import AppKit
import SwiftUI

// MARK: - Cards

extension View {
    /// The standard card: system glass at `Radius.lg`, matching `SettingsCard`.
    /// Pass `padding: 0` when the content manages its own insets.
    package func sortyCard(padding: CGFloat = SortyDesignSystem.Spacing.lg) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .systemLiquidGlassBackground(cornerRadius: SortyDesignSystem.Radius.lg, interactive: false)
    }

    /// A quiet surface for grouping content inside a card (glass should not
    /// sit on glass). Pass `tint` to mark the group with a semantic color,
    /// and `isHighlighted` for a selected or hovered state.
    package func sortyInsetSurface(
        tint: Color? = nil,
        isHighlighted: Bool = false,
        cornerRadius: CGFloat = SortyDesignSystem.Radius.md
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                shape.fill(
                    (tint ?? Color.primary).opacity(
                        tint == nil
                            ? (isHighlighted ? 0.08 : 0.04)
                            : (isHighlighted ? 0.16 : 0.08)
                    )
                )
            }
            .overlay {
                shape.strokeBorder((tint ?? Color.primary).opacity(tint == nil ? 0.08 : 0.22), lineWidth: 1)
            }
    }
}

// MARK: - Badges

extension View {
    /// A small non-interactive capsule label for counts, statuses, and tags.
    /// Leave `tint` nil for neutral counts.
    package func sortyBadge(tint: Color? = nil) -> some View {
        self
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint ?? Color.secondary)
            .padding(.horizontal, SortyDesignSystem.Spacing.xs)
            .padding(.vertical, 2)
            .background((tint ?? Color.secondary).opacity(tint == nil ? 0.12 : 0.14), in: Capsule())
    }
}

// MARK: - Chips

/// Selectable capsule chips for filters, presets, and quick answers.
/// Use `.buttonStyle(.sortyChip(isSelected:))`; for actions use `SortyButtonStyle`.
package struct SortyChipStyle: ButtonStyle {
    let isSelected: Bool
    let tint: Color?

    package init(isSelected: Bool, tint: Color? = nil) {
        self.isSelected = isSelected
        self.tint = tint
    }

    package func makeBody(configuration: Configuration) -> some View {
        SortyChipBody(configuration: configuration, isSelected: isSelected, tint: tint)
    }
}

private struct SortyChipBody: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let tint: Color?

    var body: some View {
        let color = tint ?? SortyDesignSystem.Colors.resolvedAccent

        configuration.label
            .font(.caption.weight(isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? AnyShapeStyle(color) : AnyShapeStyle(Color.primary))
            .padding(.horizontal, SortyDesignSystem.Spacing.md - 2)
            .padding(.vertical, SortyDesignSystem.Spacing.xs - 1)
            .background {
                Capsule().fill(
                    isSelected
                        ? color.opacity(configuration.isPressed ? 0.24 : 0.18)
                        : Color.primary.opacity(configuration.isPressed ? 0.12 : (isHovering ? 0.09 : 0.06))
                )
            }
            .overlay {
                Capsule().strokeBorder(isSelected ? color.opacity(0.4) : Color.clear, lineWidth: 1)
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .animation(reduceMotion ? nil : .sortyQuick, value: isHovering)
            .animation(reduceMotion ? nil : .sortySnappy, value: isSelected)
            .onHover { isHovering = $0 && isEnabled }
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { HapticFeedbackManager.shared.selection() }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension ButtonStyle where Self == SortyChipStyle {
    package static func sortyChip(isSelected: Bool = false, tint: Color? = nil) -> SortyChipStyle {
        SortyChipStyle(isSelected: isSelected, tint: tint)
    }
}

// MARK: - Empty states

/// The one empty-state layout. `.page` fills a window or pane with the hero
/// icon; `.inline` sits inside a card or list. Titles use sentence case.
package struct SortyEmptyState<Actions: View>: View {
    package enum Size {
        case page
        case inline
    }

    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    let tint: Color?
    let size: Size
    @ViewBuilder let actions: Actions

    package init(
        _ title: LocalizedStringKey,
        systemImage: String,
        message: LocalizedStringKey? = nil,
        tint: Color? = nil,
        size: Size = .page,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.tint = tint
        self.size = size
        self.actions = actions()
    }

    package var body: some View {
        VStack(spacing: size == .page ? SortyDesignSystem.Spacing.lg : SortyDesignSystem.Spacing.sm) {
            if size == .page {
                EmptyStateHeroIcon(systemName: systemImage, tint: tint)
            } else {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint ?? Color.secondary)
                    .accessibilityHidden(true)
            }

            VStack(spacing: size == .page ? SortyDesignSystem.Spacing.sm : SortyDesignSystem.Spacing.xxs) {
                Text(title)
                    .font(size == .page ? .title2.weight(.semibold) : .headline)
                if let message {
                    Text(message)
                        .font(size == .page ? .body : .callout)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: size == .page ? 400 : 320)

            actions
                .padding(.top, size == .page ? SortyDesignSystem.Spacing.xxs : 0)
        }
        .padding(size == .page ? SortyDesignSystem.Spacing.xxl : SortyDesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}
