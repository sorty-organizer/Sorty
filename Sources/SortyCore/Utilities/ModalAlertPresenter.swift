import Foundation
import AppKit

/// Presents app-modal alerts from code that runs inside a main-actor `Task`.
///
/// Main-actor jobs run as blocks on the main dispatch queue, and that queue
/// does not drain again while one of its blocks is inside a nested run loop.
/// Calling `NSAlert.runModal()` directly from a `Task` therefore stalls every
/// other main-actor job and `DispatchQueue.main` block until the alert closes,
/// which Sentry reports as an app hang. Scheduling the alert on the main run
/// loop lets the current job finish first, so the queue keeps draining while
/// the alert is open. Synchronous button and menu handlers can keep calling
/// `runModal()` directly.
public enum ModalAlertPresenter {
    @MainActor
    public static func present(
        _ alert: NSAlert,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void = { _ in }
    ) {
        nonisolated(unsafe) let alert = alert
        nonisolated(unsafe) let completion = completion
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                completion(alert.runModal())
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
