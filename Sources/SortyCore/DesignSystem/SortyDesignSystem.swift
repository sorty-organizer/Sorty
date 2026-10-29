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

        // Semantic colors
        public static let success = Color.green
        public static let warning = Color.orange
        public static let error = Color.red
        public static let info = Color.blue

        // Background colors (macOS adaptive)
        public static let backgroundPrimary = Color(NSColor.windowBackgroundColor)

        // Text colors
        public static let textPrimary = Color.primary
        public static let textSecondary = Color.secondary

        /// Sorty's default accent. Prototype windows supply their own explicit
        /// tint, so the production app never inherits the macOS accent color.
        public static var resolvedAccent: Color {
            accent
        }
    }

    // MARK: - Typography
    public enum Typography {
        // Font sizes (referenced by the style helpers below)
        public static let sizeSubheadline: CGFloat = 13
        public static let sizeHeadline: CGFloat = 15
        public static let sizeTitle3: CGFloat = 18

        // Standard font styles
        public static func subheadline(weight: Font.Weight = .regular) -> Font {
            .system(size: sizeSubheadline, weight: weight)
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
        public static let xxs: CGFloat = 4

        // Standard spacing
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 20
    }

    // MARK: - Sizing
    public enum Sizing {
        public static let windowOnboardingWidth: CGFloat = 1100
        public static let windowOnboardingHeight: CGFloat = 720
    }

    // MARK: - Border Radius
    public enum Radius {
        public static let xLarge: CGFloat = 16
    }
}

// MARK: - Animation Extensions
public extension Animation {
    static var sortySpringStandard: Animation { .spring(response: 0.5, dampingFraction: 0.8) }
}
