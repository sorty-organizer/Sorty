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
        public static let sizeSubheadline: CGFloat = 13
        public static let sizeBody: CGFloat = 14
        public static let sizeHeadline: CGFloat = 15
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

        public static func headline(weight: Font.Weight = .semibold) -> Font {
            .system(size: sizeHeadline, weight: weight)
        }

        public static func title3(weight: Font.Weight = .semibold) -> Font {
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

        // Button sizes
        public static let buttonHeightSmall: CGFloat = 24
        public static let buttonHeightMedium: CGFloat = 32
        public static let buttonHeightLarge: CGFloat = 40

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
