import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import os

/// Shares the onboarding screen backdrop with guided skill setup, leaving the
/// host window clear while softening the rest of its screen.
struct OnboardingScreenBackdropBlurPresenter: NSViewRepresentable {
    @SortyHotReload private var hotReload
    let isVisible: Bool
    var opacity: CGFloat = 0.86

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = ScreenTrackingView()
        view.onWindowChanged = { window in
            context.coordinator.attach(to: window)
        }
        context.coordinator.setVisible(isVisible, opacity: opacity)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.setVisible(isVisible, opacity: opacity)
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    @MainActor
    final class Coordinator {
        private weak var hostWindow: NSWindow?
        private var backdropPanel: NSPanel?
        private var observers: [NSObjectProtocol] = []
        private var pendingDismissal: DispatchWorkItem?
        private var isHostClosing = false
        private var isVisible = false
        private var opacity: CGFloat = 0.86

        func setVisible(_ isVisible: Bool, opacity: CGFloat) {
            guard self.isVisible != isVisible || self.opacity != opacity else { return }
            self.isVisible = isVisible
            self.opacity = opacity
            updatePanelFrame()
        }

        func attach(to window: NSWindow?) {
            // Window notifications handle geometry changes; ordinary view updates must not re-order the screen panel.
            guard hostWindow !== window else { return }

            removeObservers()
            pendingDismissal?.cancel()
            pendingDismissal = nil
            isHostClosing = false
            hostWindow = window

            guard let window else {
                dismissPanel()
                return
            }

            if backdropPanel == nil {
                backdropPanel = makeBackdropPanel()
            }

            let center = NotificationCenter.default
            observers = [
                center.addMainActorObserver(forName: NSWindow.didMoveNotification, object: window) { [weak self] in
                    self?.updatePanelFrame()
                },
                center.addMainActorObserver(forName: NSWindow.didResizeNotification, object: window) { [weak self] in
                    self?.updatePanelFrame()
                },
                center.addMainActorObserver(forName: NSWindow.didChangeScreenNotification, object: window) { [weak self] in
                    self?.updatePanelFrame()
                },
                center.addMainActorObserver(forName: NSWindow.willEnterFullScreenNotification, object: window) { [weak self] in
                    self?.hidePanelImmediately()
                },
                center.addMainActorObserver(forName: NSWindow.didExitFullScreenNotification, object: window) { [weak self] in
                    self?.updatePanelFrame()
                },
                center.addMainActorObserver(forName: NSWindow.didMiniaturizeNotification, object: window) { [weak self] in
                    self?.hidePanelImmediately()
                },
                center.addMainActorObserver(forName: NSWindow.didDeminiaturizeNotification, object: window) { [weak self] in
                    self?.updatePanelFrame()
                },
                center.addMainActorObserver(forName: NSWindow.willCloseNotification, object: window) { [weak self] in
                    self?.hostWillClose()
                },
                center.addMainActorObserver(forName: NSApplication.didResignActiveNotification, object: nil) { [weak self] in
                    self?.hidePanelImmediately()
                },
                center.addMainActorObserver(forName: NSApplication.didBecomeActiveNotification, object: nil) { [weak self] in
                    self?.updatePanelFrame()
                }
            ]

            updatePanelFrame()
        }

        func dismiss() {
            dismiss(immediately: isHostClosing)
        }

        private func hostWillClose() {
            isHostClosing = true
            dismiss(immediately: true)
        }

        private func dismiss(immediately: Bool) {
            removeObservers()
            dismissPanel(immediately: immediately)
            hostWindow = nil
        }

        private func makeBackdropPanel() -> NSPanel {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = true
            panel.isReleasedWhenClosed = false
            panel.level = .normal
            panel.alphaValue = 0
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .ignoresCycle,
                .stationary
            ]

            // AppKit NSPanel cannot use the SwiftUI `systemLiquidGlassBackground`
            // modifier, so this uses the same sanctioned behind-window material
            // as `BehindWindowBackdropView` (the single allowed NSVisualEffectView bridge).
            let backdrop = NSVisualEffectView()
            backdrop.material = .underWindowBackground
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            panel.contentView = backdrop
            return panel
        }

        private func updatePanelFrame() {
            guard let window = hostWindow,
                  isVisible,
                  // Read live app state instead of a value snapshotted at
                  // init, which can predate this runloop's activation.
                  NSApp.isActive,
                  window.isVisible,
                  !window.isMiniaturized,
                  !window.styleMask.contains(.fullScreen),
                  let screen = window.screen ?? NSScreen.main else {
                hidePanelImmediately()
                return
            }

            // The material composites on the window server; a synchronous
            // display of a screen-sized view would stall this reveal frame.
            if backdropPanel?.frame != screen.frame {
                backdropPanel?.setFrame(screen.frame, display: false)
            }
            backdropPanel?.order(.below, relativeTo: window.windowNumber)
            fadeInPanelIfNeeded()
        }

        private func dismissPanel(immediately: Bool = false) {
            guard let backdropPanel else { return }
            pendingDismissal?.cancel()
            let duration = immediately || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.8

            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                backdropPanel.animator().alphaValue = 0
            }

            let dismissal = DispatchWorkItem { [weak backdropPanel] in
                guard self.backdropPanel === backdropPanel else { return }
                backdropPanel?.orderOut(nil)
                backdropPanel?.close()
                self.backdropPanel = nil
                self.pendingDismissal = nil
            }
            pendingDismissal = dismissal
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismissal)
        }

        private func hidePanelImmediately() {
            backdropPanel?.orderOut(nil)
            backdropPanel?.alphaValue = 0
        }

        private func fadeInPanelIfNeeded() {
            guard let backdropPanel, abs(backdropPanel.alphaValue - opacity) > 0.001 else { return }
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.9

            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                backdropPanel.animator().alphaValue = opacity
            }
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
        }
    }

    final class ScreenTrackingView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }
}
