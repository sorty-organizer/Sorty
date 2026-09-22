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
        private var originalLayerState: [ObjectIdentifier: (wantsLayer: Bool, cornerRadius: CGFloat)] = [:]

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
                nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let window else { return }
                        self?.restoreButtons(in: window)
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
            if let observedWindow {
                restoreButtons(in: observedWindow)
            }
            for obs in observations {
                NotificationCenter.default.removeObserver(obs)
            }
            observations.removeAll()
            observedWindow = nil
            originalLayerState.removeAll()
        }

        // MARK: - Styling

        private static let buttonTypes: [(NSWindow.ButtonType, NSColor)] = [
            (.closeButton, .systemRed),
            (.miniaturizeButton, .systemYellow),
            (.zoomButton, .systemGreen),
        ]

        private func styleInactiveButtons(in window: NSWindow) {
            for (type, borderColor) in Self.buttonTypes {
                guard let button = window.standardWindowButton(type) else { continue }
                let identifier = ObjectIdentifier(button)
                if originalLayerState[identifier] == nil {
                    originalLayerState[identifier] = (button.wantsLayer, button.layer?.cornerRadius ?? 0)
                }
                if button.layer == nil {
                    button.wantsLayer = true
                }
                guard let layer = button.layer else { continue }
                layer.cornerRadius = button.bounds.height / 2
                layer.borderWidth = 1.0
                layer.borderColor = borderColor.withAlphaComponent(0.78).cgColor
            }
        }

        private func restoreButtons(in window: NSWindow) {
            for (type, _) in Self.buttonTypes {
                guard let button = window.standardWindowButton(type) else { continue }
                button.layer?.borderWidth = 0
                button.layer?.borderColor = nil
                if let original = originalLayerState[ObjectIdentifier(button)] {
                    button.layer?.cornerRadius = original.cornerRadius
                    button.wantsLayer = original.wantsLayer
                }
            }
        }
    }
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
