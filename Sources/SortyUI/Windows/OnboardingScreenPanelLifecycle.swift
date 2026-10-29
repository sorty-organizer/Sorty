import AppKit
import QuartzCore

/// Shared lifetime for noninteractive onboarding screen panels. Subclasses
/// retain their own geometry, content, ordering, and fade-in policies.
@MainActor
package class OnboardingScreenPanelLifecycle {
    package weak var hostWindow: NSWindow?
    package var panel: NSPanel?
    package var observers: [NSObjectProtocol] = []
    package var pendingDismissal: DispatchWorkItem?
    package var isHostClosing = false

    package init() {}

    package final func dismiss() {
        dismiss(immediately: isHostClosing)
    }

    package final func hostWillClose() {
        isHostClosing = true
        dismiss(immediately: true)
    }

    package final func dismiss(immediately: Bool) {
        removeObservers()
        dismissPanel(immediately: immediately)
        hostWindow = nil
    }

    package final func dismissPanel(immediately: Bool = false) {
        guard let panel else { return }
        pendingDismissal?.cancel()
        let duration = immediately || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.8

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }

        let dismissal = DispatchWorkItem { [weak panel] in
            guard self.panel === panel else { return }
            panel?.orderOut(nil)
            panel?.close()
            self.panel = nil
            self.pendingDismissal = nil
        }
        pendingDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismissal)
    }

    package final func hidePanelImmediately() {
        panel?.orderOut(nil)
        panel?.alphaValue = 0
    }

    package final func removeObservers() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

}
