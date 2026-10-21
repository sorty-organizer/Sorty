import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import os

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
    package final class Coordinator {
        private weak var hostWindow: NSWindow?
        private var glowPanel: NSPanel?
        private var observers: [NSObjectProtocol] = []
        private var pendingDismissal: DispatchWorkItem?
        private var isHostClosing = false
        private var isVisible = false

        private var strength = 0.55

        func setStrength(_ strength: Double) {
            guard self.strength != strength else { return }
            self.strength = strength
            (glowPanel?.contentView as? NSHostingView<OnboardingScreenEdgeGlow>)?.rootView =
                OnboardingScreenEdgeGlow(strength: strength)
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

            if glowPanel == nil {
                glowPanel = makeGlowPanel()
            }

            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.updatePanelFrame() }
                },
                center.addObserver(
                    forName: NSWindow.didChangeScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.updatePanelFrame() }
                },
                center.addObserver(
                    forName: NSWindow.willEnterFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.hidePanelImmediately() }
                },
                center.addObserver(
                    forName: NSWindow.didExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.showPanelIfPossible() }
                },
                center.addObserver(
                    forName: NSWindow.didMiniaturizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.hidePanelImmediately() }
                },
                center.addObserver(
                    forName: NSWindow.didDeminiaturizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.showPanelIfPossible() }
                },
                center.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.hostWillClose() }
                },
                center.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.hidePanelImmediately()
                    }
                },
                center.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.showPanelIfPossible()
                    }
                }
            ]

            showPanelIfPossible()
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
            let glowView = NSHostingView(rootView: OnboardingScreenEdgeGlow(strength: strength))
            glowView.sizingOptions = []
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
            glowPanel?.setFrame(screen.frame, display: true)
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
            guard let glowPanel, glowPanel.alphaValue == 0 else { return }
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.8
            glowPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                glowPanel.animator().alphaValue = 1
            }
        }

        private func dismissPanel(immediately: Bool = false) {
            guard let glowPanel else { return }
            pendingDismissal?.cancel()
            let duration = immediately || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.8

            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                glowPanel.animator().alphaValue = 0
            }

            let dismissal = DispatchWorkItem { [weak glowPanel] in
                guard self.glowPanel === glowPanel else { return }
                glowPanel?.orderOut(nil)
                glowPanel?.close()
                self.glowPanel = nil
                self.pendingDismissal = nil
            }
            pendingDismissal = dismissal
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismissal)
        }

        private func hidePanelImmediately() {
            glowPanel?.orderOut(nil)
            glowPanel?.alphaValue = 0
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
