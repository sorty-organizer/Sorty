import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import os

/// Immutable copy of the window chrome that onboarding replaced, applied back
/// when the configurator's coordinator goes away. `@unchecked Sendable` lets a
/// deinit that runs off the main thread hand the snapshot to the main actor;
/// every member is only touched there.
struct OnboardingWindowChromeSnapshot: @unchecked Sendable {
    let window: NSWindow
    let titleVisibility: NSWindow.TitleVisibility?
    let titlebarAppearsTransparent: Bool?
    let titlebarSeparatorStyle: NSTitlebarSeparatorStyle?
    let styleMask: NSWindow.StyleMask?
    let backgroundColor: NSColor?
    let isOpaque: Bool?
    let hasShadow: Bool?
    let alphaValue: CGFloat?
    let contentMinSize: NSSize?

    @MainActor
    func apply() {
        if let styleMask {
            window.styleMask = styleMask
        }
        if let titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = titlebarAppearsTransparent
        }
        if let titlebarSeparatorStyle {
            window.titlebarSeparatorStyle = titlebarSeparatorStyle
        }
        if let titleVisibility {
            window.titleVisibility = titleVisibility
        }
        if let backgroundColor {
            window.backgroundColor = backgroundColor
        }
        if let isOpaque {
            window.isOpaque = isOpaque
        }
        if let hasShadow {
            window.hasShadow = hasShadow
        }
        if let alphaValue {
            window.alphaValue = alphaValue
        } else {
            window.alphaValue = 1
        }
        if let contentMinSize {
            window.contentMinSize = contentMinSize
        }
    }
}

struct OnboardingWindowTitleConfigurator: NSViewRepresentable {
    @SortyHotReload private var hotReload
    let preserveWindowPosition: Bool
    let onConfigured: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowAttachedView()
        view.onWindowAttached = { window in
            context.coordinator.configure(window: window, preserveWindowPosition: preserveWindowPosition)
            notifyAfterWindowLayoutSettles()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Window attachment is handled once by WindowAttachedView. Ordinary
        // SwiftUI updates must not enqueue window work or configuration state.
    }

    private func notifyAfterWindowLayoutSettles() {
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                onConfigured()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        private weak var configuredWindow: NSWindow?
        private var originalTitleVisibility: NSWindow.TitleVisibility?
        private var originalTitlebarAppearsTransparent: Bool?
        private var originalTitlebarSeparatorStyle: NSTitlebarSeparatorStyle?
        private var originalStyleMask: NSWindow.StyleMask?
        private var originalBackgroundColor: NSColor?
        private var originalIsOpaque: Bool?
        private var originalHasShadow: Bool?
        private var originalAlphaValue: CGFloat?
        private var originalContentMinSize: NSSize?

        func configure(window: NSWindow, preserveWindowPosition: Bool) {
            guard configuredWindow !== window else { return }
            restore()

            configuredWindow = window
            originalTitleVisibility = window.titleVisibility
            originalTitlebarAppearsTransparent = window.titlebarAppearsTransparent
            originalTitlebarSeparatorStyle = window.titlebarSeparatorStyle
            originalStyleMask = window.styleMask
            originalBackgroundColor = window.backgroundColor
            originalIsOpaque = window.isOpaque
            originalHasShadow = window.hasShadow
            originalAlphaValue = window.alphaValue
            originalContentMinSize = window.contentMinSize

            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.isMovableByWindowBackground = true

            // Pin the window to the onboarding minimum content size before the
            // first paint so it never visibly resizes/reframes after appearing.
            let targetSize = NSSize(
                width: SortyDesignSystem.Sizing.windowOnboardingWidth,
                height: SortyDesignSystem.Sizing.windowOnboardingHeight
            )
            window.contentMinSize = targetSize
            if window.contentLayoutRect.width < targetSize.width
                || window.contentLayoutRect.height < targetSize.height
            {
                window.setContentSize(targetSize)
            }
            if !preserveWindowPosition, !window.styleMask.contains(.fullScreen) {
                window.center()
            }
            if !preserveWindowPosition, !window.styleMask.contains(.fullScreen),
               let screen = window.screen ?? NSScreen.main {
                let centeredOrigin = window.frame.origin
                let loweredY = max(screen.visibleFrame.minY + 24, centeredOrigin.y - 32)
                window.setFrameOrigin(NSPoint(x: centeredOrigin.x, y: loweredY))
            }

            // The intro's retained icon and phase-driven panels own the reveal.
            // A second whole-window fade completes out of sync with those
            // surfaces and produces a visible flash at the phase boundary.
            window.alphaValue = 1
            window.makeKey()
        }

        private func restore() {
            guard let window = configuredWindow else { return }
            OnboardingWindowChromeSnapshot(
                window: window,
                titleVisibility: originalTitleVisibility,
                titlebarAppearsTransparent: originalTitlebarAppearsTransparent,
                titlebarSeparatorStyle: originalTitlebarSeparatorStyle,
                styleMask: originalStyleMask,
                backgroundColor: originalBackgroundColor,
                isOpaque: originalIsOpaque,
                hasShadow: originalHasShadow,
                alphaValue: originalAlphaValue,
                contentMinSize: originalContentMinSize
            )
            .apply()
        }

        deinit {
            // Deinit is nonisolated and can run off the main thread. Capture a
            // value snapshot of the original chrome and apply it on the main
            // actor instead of assuming main-actor isolation here.
            guard let window = configuredWindow else { return }
            let snapshot = OnboardingWindowChromeSnapshot(
                window: window,
                titleVisibility: originalTitleVisibility,
                titlebarAppearsTransparent: originalTitlebarAppearsTransparent,
                titlebarSeparatorStyle: originalTitlebarSeparatorStyle,
                styleMask: originalStyleMask,
                backgroundColor: originalBackgroundColor,
                isOpaque: originalIsOpaque,
                hasShadow: originalHasShadow,
                alphaValue: originalAlphaValue,
                contentMinSize: originalContentMinSize
            )
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    snapshot.apply()
                }
            } else {
                Task { @MainActor in
                    snapshot.apply()
                }
            }
        }
    }

    final class WindowAttachedView: NSView {
        var onWindowAttached: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            onWindowAttached?(window)
        }
    }
}
