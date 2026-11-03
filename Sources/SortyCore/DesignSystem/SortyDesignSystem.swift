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
    /// The spacing scale for padding and stack spacing. Stay on these steps
    /// instead of inventing in-between values.
    public enum Spacing {
        public nonisolated static let xxs: CGFloat = 4
        public nonisolated static let xs: CGFloat = 6
        public nonisolated static let sm: CGFloat = 8
        public nonisolated static let md: CGFloat = 12
        public nonisolated static let lg: CGFloat = 16
        public nonisolated static let xl: CGFloat = 20
        public nonisolated static let xxl: CGFloat = 24
        public nonisolated static let xxxl: CGFloat = 32
    }

    // MARK: - Sizing
    public enum Sizing {
        public static let windowOnboardingWidth: CGFloat = 1100
        public static let windowOnboardingHeight: CGFloat = 720
        /// Smallest main-window content size. Every screen is laid out to fit
        /// at least this, so the window must never shrink below it.
        public static let windowMinWidth: CGFloat = 960
        public static let windowMinHeight: CGFloat = 640
    }

    // MARK: - Corner Radius
    /// Corner radii, always drawn with `.continuous` corners.
    /// `xs` badges and tiny swatches, `sm` inline tokens and thumbnails,
    /// `md` rows, fields and compact tiles, `lg` cards and popovers,
    /// `xl` large panels and sheets, `xxl` hero surfaces.
    /// Use `Capsule()` (or `capsule` where an API needs a number) for pills.
    public enum Radius {
        public nonisolated static let xs: CGFloat = 4
        public nonisolated static let sm: CGFloat = 6
        public nonisolated static let md: CGFloat = 8
        public nonisolated static let lg: CGFloat = 12
        public nonisolated static let xl: CGFloat = 16
        public nonisolated static let xxl: CGFloat = 20
        public nonisolated static let capsule: CGFloat = 999
    }
}

// MARK: - Motion
/// Sorty's motion vocabulary. Pick by purpose, and pass `nil` instead when
/// Reduce Motion is on.
public extension Animation {
    /// Hover, press and other instant feedback.
    static var sortyQuick: Animation { .easeOut(duration: 0.15) }
    /// Cross-fades and state swaps.
    static var sortyFade: Animation { .easeInOut(duration: 0.2) }
    /// Slower fades for larger surfaces.
    static var sortySlowFade: Animation { .easeInOut(duration: 0.3) }
    /// Small toggles, chips, disclosure and row expansion.
    static var sortySnappy: Animation { .spring(response: 0.28, dampingFraction: 0.82) }
    /// Panels, cards and layout changes.
    static var sortySmooth: Animation { .spring(response: 0.4, dampingFraction: 0.84) }
    /// Large transitions such as page and sheet changes.
    static var sortySpringStandard: Animation { .spring(response: 0.5, dampingFraction: 0.8) }
    /// Celebratory pops that should overshoot.
    static var sortyBouncy: Animation { .spring(response: 0.35, dampingFraction: 0.65) }
}
