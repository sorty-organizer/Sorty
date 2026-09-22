import AppKit
import SwiftUI

struct ScreenFrameReader: NSViewRepresentable {
    @SortyHotReload private var hotReload
    @Binding var frameInScreen: CGRect

    func makeCoordinator() -> Coordinator {
        Coordinator(frameInScreen: $frameInScreen)
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onFrameChange = context.coordinator.update(frameInScreen:)
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        // SwiftUI state updates do not imply that AppKit geometry changed.
        // Layout and window notifications below own frame measurement.
        context.coordinator.bind(frameInScreen: $frameInScreen)
    }

    @MainActor
    final class Coordinator {
        private var frameInScreen: Binding<CGRect>
        private var pendingFrame: CGRect?
        private var isUpdateScheduled = false

        init(frameInScreen: Binding<CGRect>) {
            self.frameInScreen = frameInScreen
        }

        func bind(frameInScreen: Binding<CGRect>) {
            self.frameInScreen = frameInScreen
        }

        func update(frameInScreen: CGRect) {
            guard self.frameInScreen.wrappedValue != frameInScreen else { return }
            pendingFrame = frameInScreen
            guard !isUpdateScheduled else { return }
            isUpdateScheduled = true

            DispatchQueue.main.async { @MainActor [weak self] in
                guard let self else { return }
                isUpdateScheduled = false
                guard let pendingFrame else { return }
                self.pendingFrame = nil
                if self.frameInScreen.wrappedValue != pendingFrame {
                    self.frameInScreen.wrappedValue = pendingFrame
                }
            }
        }
    }
}

final class ProbeView: NSView {
    var onFrameChange: ((CGRect) -> Void)?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installObservers()
        reportFrameIfNeeded()
    }

    override func layout() {
        super.layout()
        reportFrameIfNeeded()
    }

    deinit {
        MainActor.assumeIsolated {
            removeObservers()
        }
    }

    func reportFrameIfNeeded() {
        guard let window, !bounds.isEmpty else { return }
        let frameInWindow = convert(bounds, to: nil)
        onFrameChange?(window.convertToScreen(frameInWindow))
    }

    private func installObservers() {
        removeObservers()
        guard let window else { return }
        let notificationCenter = NotificationCenter.default
        let names: [NSNotification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didChangeBackingPropertiesNotification,
        ]

        observers = names.map { name in
            notificationCenter.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reportFrameIfNeeded()
                }
            }
        }
    }

    private func removeObservers() {
        let notificationCenter = NotificationCenter.default
        observers.forEach(notificationCenter.removeObserver)
        observers.removeAll()
    }
}
