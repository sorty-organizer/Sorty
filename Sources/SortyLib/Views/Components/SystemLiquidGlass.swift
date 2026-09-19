import AppKit
import SwiftUI

/// Backdrop that samples and displays content *behind the window* (desktop,
/// other apps), like Finder's sidebar. Liquid glass alone cannot do this:
/// `glassEffect` only samples content inside the window, so pair this backdrop
/// with a `.clear` glass effect layered above it.
/// This NSVisualEffectView is the single sanctioned AppKit bridge for
/// behind-window glass (used by `behindWindowLiquidGlassBackground` and the
/// Onboarding fullscreen backdrop panel, which cannot use a SwiftUI modifier).
/// Do not add other raw materials/blurs; use `systemLiquidGlassBackground`
/// or `.systemLiquidGlassPopover` instead.
private struct BehindWindowBackdropView: NSViewRepresentable {
    @SortyHotReload private var hotReload
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .underWindowBackground
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension View {
    /// Uses the native interactive Liquid Glass button style on macOS 26,
    /// while preserving Sorty's compact secondary pill on older systems.
    @ViewBuilder
    func systemLiquidGlassButton() -> some View {
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
    func systemLiquidGlassCircularButton() -> some View {
        buttonStyle(.plain)
    }

    @ViewBuilder
    func systemLiquidGlassCircularButtonLabel() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                .regular
                    .tint(Color.primary.opacity(0.08))
                    .interactive(),
                in: Circle()
            )
        } else {
            self.background(Circle().fill(Color.primary.opacity(0.10)))
        }
    }

    /// Liquid glass that shows through to content behind the window.
    /// Falls back to a plain behind-window material before macOS 26.
    @ViewBuilder
    func behindWindowLiquidGlassBackground(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.background {
                BehindWindowBackdropView()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .glassEffect(.clear.interactive(), in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self.background {
                BehindWindowBackdropView()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
    }

    @ViewBuilder
    func systemLiquidGlassBackground(
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
                    }
                } else {
                    self.background {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.clear)
                            .glassEffect(.clear, in: .rect(cornerRadius: cornerRadius))
                    }
                }
            } else if interactive {
                self.background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
                }
            } else {
                self.background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                }
            }
        } else {
            self
        }
    }

    /// Keeps the native popover surface; adding a second glass background here
    /// creates a visible inner edge where the two surfaces overlap.
    func systemLiquidGlassPopover(cornerRadius: CGFloat) -> some View {
        presentationCornerRadius(cornerRadius)
    }
}
