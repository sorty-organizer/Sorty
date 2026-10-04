//
//  SortyDesignSystem.swift
//  Sorty
//
//  Centralized design system for consistent theming across the app
//

import SwiftUI

// MARK: - Design System Namespace
@MainActor
public enum SortyDesignSystem {

    // MARK: - Colors
    public enum Colors {
        /// Sorty brand rose accent.
        public static let accent = Color(red: 0.850, green: 0.235, blue: 0.353)

        // Brand colors
        public static var primary: Color { resolvedAccent }
        public static let purple = Color.purple
        public static let purpleLight = Color.purple.opacity(0.1)
        public static let blue = Color.blue
        public static let blueLight = Color.blue.opacity(0.1)
        public static let green = Color.green
        public static let greenLight = Color.green.opacity(0.1)
        public static let orange = Color.orange
        public static let orangeLight = Color.orange.opacity(0.1)
        public static let red = Color.red
        public static let redLight = Color.red.opacity(0.1)

        // Semantic colors
        public static let success = Color.green
        public static let warning = Color.orange
        public static let error = Color.red
        public static let info = Color.blue

        // Background colors (macOS adaptive)
        public static let backgroundPrimary = Color(NSColor.windowBackgroundColor)
        public static let backgroundSecondary = Color(NSColor.controlBackgroundColor)
        public static let backgroundTertiary = Color(NSColor.textBackgroundColor)

        // Text colors
        public static let textPrimary = Color.primary
        public static let textSecondary = Color.secondary
        public static let textTertiary = Color(NSColor.tertiaryLabelColor)

        // Overlay colors
        public static let glassBackground = Color.white.opacity(0.1)
        public static let glassBorder = Color.white.opacity(0.2)
        public static let overlayLight = Color.black.opacity(0.05)
        public static let overlayMedium = Color.black.opacity(0.1)

        /// Sorty's default accent. Prototype windows supply their own explicit
        /// tint, so the production app never inherits the macOS accent color.
        public static var resolvedAccent: Color {
            accent
        }
    }

    // MARK: - Typography
    public enum Typography {
        // Font sizes (referenced by the style helpers below)
        public static let sizeCaption2: CGFloat = 10
        public static let sizeSubheadline: CGFloat = 14
        public static let sizeBody: CGFloat = 14
        public static let sizeHeadline: CGFloat = 16
        public static let sizeTitle3: CGFloat = 18

        // Standard font styles
        public static func caption2(weight: Font.Weight = .regular) -> Font {
            .system(size: sizeCaption2, weight: weight)
        }

        public static func subheadline(weight: Font.Weight = .regular) -> Font {
            .system(size: sizeSubheadline, weight: weight)
        }

        public static func body(weight: Font.Weight = .regular) -> Font {
            .system(size: sizeBody, weight: weight)
        }

        public static func headline(weight: Font.Weight = .medium) -> Font {
            .system(size: sizeHeadline, weight: weight)
        }

        public static func title3(weight: Font.Weight = .medium) -> Font {
            .system(size: sizeTitle3, weight: weight)
        }
    }

    // MARK: - Spacing
    public enum Spacing {
        // Micro spacing
        public static let xxxs: CGFloat = 2
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 6

        // Standard spacing
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 24
        public static let xxxl: CGFloat = 32
        public static let xxxxl: CGFloat = 40

        public static let buttonHorizontalPadding: CGFloat = 16
        public static let buttonTextPadding: CGFloat = 4

        // Section spacing
        public static let sectionSmall: CGFloat = 20
        public static let sectionMedium: CGFloat = 28
        public static let sectionLarge: CGFloat = 36
    }

    // MARK: - Sizing
    public enum Sizing {
        // Icon sizes
        public static let iconSmall: CGFloat = 12
        public static let iconMedium: CGFloat = 16
        public static let iconLarge: CGFloat = 20
        public static let iconXLarge: CGFloat = 24
        public static let iconXXLarge: CGFloat = 32
        public static let iconHuge: CGFloat = 48

        public static let listIcon: CGFloat = 28

        // Button sizes
        public static let buttonHeightSmall: CGFloat = 24
        public static let buttonHeightMedium: CGFloat = 32
        public static let buttonHeightLarge: CGFloat = 44

        // Card sizes
        public static let cardCornerRadius: CGFloat = 12
        public static let cardPadding: CGFloat = 16
        public static let cardMinWidth: CGFloat = 200

        // Window sizes
        public static let windowMinWidth: CGFloat = 1000
        public static let windowMinHeight: CGFloat = 700
        public static let windowOnboardingWidth: CGFloat = 1100
        public static let windowOnboardingHeight: CGFloat = 720
    }

    // MARK: - Border Radius
    public enum Radius {
        public static let none: CGFloat = 0
        public static let small: CGFloat = 4
        public static let medium: CGFloat = 8
        public static let large: CGFloat = 12
        public static let xLarge: CGFloat = 16
        public static let circle: CGFloat = 9999
    }
}

// MARK: - Animation Extensions
public extension Animation {
    static var sortySpringStandard: Animation { .spring(response: 0.5, dampingFraction: 0.8) }
}

// Shared reading styles use SF Pro and scale with the user's text settings.
@MainActor
private struct SortyTypographyModifier: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var bodySize = SortyDesignSystem.Typography.sizeBody
    @ScaledMetric(relativeTo: .headline) private var headlineSize = SortyDesignSystem.Typography.sizeHeadline
    @ScaledMetric(relativeTo: .title3) private var titleSize = SortyDesignSystem.Typography.sizeTitle3
    @ScaledMetric(relativeTo: .body) private var leading: CGFloat = 4

    let style: Font.TextStyle
    let weight: Font.Weight

    func body(content: Content) -> some View {
        let size: CGFloat = switch style {
        case .title3: titleSize
        case .headline: headlineSize
        case .caption: bodySize * 12 / 14
        case .caption2: bodySize * 11 / 14
        default: bodySize
        }
        content
            .font(.system(size: size, weight: weight))
            .lineSpacing(leading)
    }
}

public extension View {
    /// Applies the app's 14, 16, or 18 point reading scale with four points of extra leading.
    @MainActor
    func sortyTypography(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> some View {
        modifier(SortyTypographyModifier(style: style, weight: weight))
    }
}
