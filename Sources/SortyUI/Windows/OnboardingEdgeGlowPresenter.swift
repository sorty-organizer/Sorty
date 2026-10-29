import AppKit
import QuartzCore
import SwiftUI

package struct OnboardingScreenEdgeGlowPresenter: NSViewRepresentable {
    @SortyHotReload private var hotReload
    let isVisible: Bool
    var strength = 0.55

    package init(isVisible: Bool, strength: Double = 0.55) {
        self.isVisible = isVisible
        self.strength = strength
    }

    package func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    package func makeNSView(context: Context) -> NSView {
        let view = ScreenTrackingView()
        view.onWindowChanged = { window in
            context.coordinator.attach(to: window)
        }
        context.coordinator.setStrength(strength)
        context.coordinator.setVisible(isVisible)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    package func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.setStrength(strength)
        context.coordinator.setVisible(isVisible)
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
        }
    }

    package static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    @MainActor
    package final class Coordinator: OnboardingScreenPanelLifecycle {
        private var isVisible = false

        private var strength = 0.55

        func setStrength(_ strength: Double) {
            guard self.strength != strength else { return }
            self.strength = strength
            (panel?.contentView as? OnboardingScreenEdgeGlowView)?.setStrength(strength)
        }

        func setVisible(_ isVisible: Bool) {
            guard self.isVisible != isVisible else { return }
            self.isVisible = isVisible
            showPanelIfPossible()
        }

        func attach(to window: NSWindow?) {
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

            if panel == nil {
                panel = makeGlowPanel()
            }

            let center = NotificationCenter.default
            observers = [
                center.addMainActorObserver(forName: NSWindow.didMoveNotification, object: window) { [weak self] in
                    self?.updatePanelFrame()
                },
                center.addMainActorObserver(forName: NSWindow.didChangeScreenNotification, object: window) { [weak self] in
                    self?.updatePanelFrame()
                },
                center.addMainActorObserver(forName: NSWindow.willEnterFullScreenNotification, object: window) { [weak self] in
                    self?.hidePanelImmediately()
                },
                center.addMainActorObserver(forName: NSWindow.didExitFullScreenNotification, object: window) { [weak self] in
                    self?.showPanelIfPossible()
                },
                center.addMainActorObserver(forName: NSWindow.didMiniaturizeNotification, object: window) { [weak self] in
                    self?.hidePanelImmediately()
                },
                center.addMainActorObserver(forName: NSWindow.didDeminiaturizeNotification, object: window) { [weak self] in
                    self?.showPanelIfPossible()
                },
                center.addMainActorObserver(forName: NSWindow.willCloseNotification, object: window) { [weak self] in
                    self?.hostWillClose()
                },
                center.addMainActorObserver(forName: NSApplication.didResignActiveNotification, object: nil) { [weak self] in
                    self?.hidePanelImmediately()
                },
                center.addMainActorObserver(forName: NSApplication.didBecomeActiveNotification, object: nil) { [weak self] in
                    self?.showPanelIfPossible()
                }
            ]

            showPanelIfPossible()
        }

        private func makeGlowPanel() -> NSPanel {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
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
            let glowView = OnboardingScreenEdgeGlowView(strength: strength)
            glowView.autoresizingMask = [.width, .height]
            panel.contentView = glowView
            return panel
        }

        private func updatePanelFrame() {
            guard let window = hostWindow,
                  window.isVisible,
                  !window.isMiniaturized,
                  !window.styleMask.contains(.fullScreen),
                  let screen = window.screen ?? NSScreen.main else {
                hidePanelImmediately()
                return
            }
            // Layer-backed gradients need no synchronous redraw; displaying
            // here would stall the reveal frame that orders the panel in.
            guard panel?.frame != screen.frame else { return }
            panel?.setFrame(screen.frame, display: false)
        }

        private func showPanelIfPossible() {
            guard isVisible,
                  // Read live app state instead of a value snapshotted at
                  // init, which can predate this runloop's activation.
                  NSApp.isActive,
                  let window = hostWindow,
                  window.isVisible,
                  !window.isMiniaturized,
                  !window.styleMask.contains(.fullScreen) else {
                hidePanelImmediately()
                return
            }
            updatePanelFrame()
            fadeInPanelIfNeeded()
        }

        private func fadeInPanelIfNeeded() {
            guard let panel, panel.alphaValue == 0 else { return }
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.8
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 1
            }
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
