//
//  TrafficLightStyling.swift
//  Sorty
//

import AppKit
import SwiftUI

/// Customizes the standard window traffic light buttons so they show
/// colored border rings (red / yellow / green) when the window is
/// not key, instead of the default plain-gray appearance.
public struct TrafficLightStyling: NSViewRepresentable {
    @SortyHotReload private var hotReload
    public func makeNSView(context: Context) -> NSView {
        let view = WindowAttachmentView()
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.observe(window: window)
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.observe(window: nsView.window)
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    public final class Coordinator: NSObject {
        private var observations: [NSObjectProtocol] = []
        private weak var observedWindow: NSWindow?
        private var borderViews: [NSView] = []

        func observe(window: NSWindow?) {
            guard let window else {
                stopObserving()
                return
            }
            guard observedWindow !== window else { return }
            stopObserving()
            observedWindow = window

            let nc = NotificationCenter.default

            observations.append(
                nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.removeBorders()
                    }
                }
            )

            observations.append(
                nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let window else { return }
                        self?.styleInactiveButtons(in: window)
                    }
                }
            )

            for name in [
                NSWindow.didChangeScreenNotification,
                NSWindow.didChangeBackingPropertiesNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ] {
                observations.append(
                    nc.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                        MainActor.assumeIsolated {
                            guard let self, let window, !window.isKeyWindow else { return }
                            self.styleInactiveButtons(in: window)
                        }
                    }
                )
            }

            if !window.isKeyWindow {
                styleInactiveButtons(in: window)
            }
        }

        func stopObserving() {
            removeBorders()
            for obs in observations {
                NotificationCenter.default.removeObserver(obs)
            }
            observations.removeAll()
            observedWindow = nil
        }

        // MARK: - Styling

        private static let buttonTypes: [(NSWindow.ButtonType, NSColor)] = [
            (.closeButton, .systemRed),
            (.miniaturizeButton, .systemYellow),
            (.zoomButton, .systemGreen),
        ]

        private func styleInactiveButtons(in window: NSWindow) {
            removeBorders()
            for (type, borderColor) in Self.buttonTypes {
                guard let button = window.standardWindowButton(type),
                      let container = button.superview else { continue }

                // AppKit owns the native button's backing layer, including its
                // hover and pressed rendering. Draw the ring in a sibling view.
                let border = TrafficLightBorderView(frame: button.frame)
                border.autoresizingMask = button.autoresizingMask
                border.wantsLayer = true
                border.layer?.cornerRadius = button.bounds.height / 2
                border.layer?.borderWidth = 1.0
                border.layer?.borderColor = borderColor.withAlphaComponent(0.78).cgColor
                border.setAccessibilityElement(false)
                container.addSubview(border, positioned: .above, relativeTo: button)
                borderViews.append(border)
            }
        }

        private func removeBorders() {
            for border in borderViews {
                border.removeFromSuperview()
            }
            borderViews.removeAll()
        }
    }
}

@MainActor
private final class TrafficLightBorderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class WindowAttachmentView: NSView {
    var windowDidChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowDidChange?(window)
    }
}

extension View {
    /// Adds colored border rings to the window's traffic light buttons
    /// when the window is inactive.
    public func trafficLightInactiveBorders() -> some View {
        background(TrafficLightStyling().frame(width: 0, height: 0))
    }
}
