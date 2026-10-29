import AppKit
import SwiftUI

extension View {
    /// Uses the native interactive Liquid Glass button style on macOS 26,
    /// while preserving Sorty's compact secondary pill on older systems.
    @ViewBuilder
    package func systemLiquidGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .tint(nil)
        } else {
            self.buttonStyle(.sortyPrimary(isSecondary: true, size: .small))
        }
    }

    /// Keeps the button's visual treatment on its fixed-size label so the
    /// surrounding hit target does not enlarge the glass circle.
    package func systemLiquidGlassCircularButton() -> some View {
        buttonStyle(.plain)
    }

    @ViewBuilder
    package func systemLiquidGlassCircularButtonLabel() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                .regular
                    .tint(Color.primary.opacity(0.08))
                    .interactive(),
                in: Circle()
            )
            .clipShape(Circle())
        } else {
            self.background(Circle().fill(Color.primary.opacity(0.10)))
        }
    }

    /// Clips only the glass backdrop so its rectangular render bounds cannot
    /// leave dark patches outside rounded corners. Content stays unclipped.
    @ViewBuilder
    package func systemLiquidGlassBackground(
        cornerRadius: CGFloat,
        clear: Bool = false,
        interactive: Bool = true
    ) -> some View {
        if #available(macOS 26.0, *) {
            if clear {
                if interactive {
                    self.background {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.clear)
                            .glassEffect(.clear.interactive(), in: .rect(cornerRadius: cornerRadius))
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    }
                } else {
                    self.background {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.clear)
                            .glassEffect(.clear, in: .rect(cornerRadius: cornerRadius))
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    }
                }
            } else if interactive {
                self.background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            } else {
                self.background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            }
        } else {
            self
        }
    }

    /// Keeps the native popover surface; adding a second glass background here
    /// creates a visible inner edge where the two surfaces overlap.
    package func systemLiquidGlassPopover(cornerRadius: CGFloat) -> some View {
        presentationCornerRadius(cornerRadius)
    }
}
