//
//  StatComponents.swift
//  Sorty
//
//  Shared stat cells, dividers, and glass pill triggers
//

import SwiftUI

// MARK: - Icon Stat Item

struct IconStatItem: View {
    @SortyHotReload private var hotReload
    enum Style {
        case detail
        case completion
    }

    let style: Style
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: style.outerSpacing) {
            Image(systemName: icon)
                .font(style.iconFont)
                .foregroundStyle(color)
                .accessibilityHidden(true)

            VStack(spacing: style.innerSpacing) {
                Text(value)
                    .font(style.valueFont)
                    .monospacedDigit()
                    .numericTextTransition(animationValue: value)

                Text(label)
                    .font(style.labelFont)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

private extension IconStatItem.Style {
    var outerSpacing: CGFloat {
        self == .detail ? 3 : 8
    }

    var innerSpacing: CGFloat {
        self == .detail ? 1 : 2
    }

    var iconFont: Font {
        self == .detail ? .system(size: 18, weight: .semibold) : .title2
    }

    var valueFont: Font {
        self == .detail ? .system(size: 18, weight: .bold, design: .rounded) : .title2.bold()
    }

    var labelFont: Font {
        self == .detail ? .system(size: 11, weight: .medium, design: .rounded) : .caption
    }
}

struct IconStatDivider: View {
    @SortyHotReload private var hotReload
    var height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(width: 1, height: height)
            .accessibilityHidden(true)
    }
}

// MARK: - Glass Pill Trigger

struct GlassPillButton: View {
    @SortyHotReload private var hotReload
    let icon: String
    let title: String
    let tint: Color
    var count: Int? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)

                Text(title)
                    .font(.headline)

                if let count {
                    Text("\(count)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .numericTextTransition(animationValue: count)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(tint))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .systemLiquidGlassBackground(cornerRadius: 999)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.3),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
            .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Glass Popover Header

struct GlassPopoverHeader: View {
    @SortyHotReload private var hotReload
    let icon: String
    let title: String
    let tint: Color
    var subtitle: String? = nil
    var subtitleAnimationValue: String = ""

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 28, height: 28)

                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .numericTextTransition(animationValue: subtitleAnimationValue)
                }
            }

            Spacer()
        }
        .padding(.bottom, 10)
    }
}
